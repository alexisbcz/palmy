# The install core and palm-install — notes

Owner: `distro/installer/` (`core/`, `cli/`, `test-install.py`) and this file.

## Build and test

```
odin build distro/installer/cli -o:speed -collection:palmy=palmy -collection:kit=apps/kit \
    -collection:shadcn=shadcn -collection:install=distro/installer -out:distro/out/bin/palm-install
TMPDIR=distro/build/installer-core distro/out/bin/palm-install --selftest   # from the repo root
python3 -I distro/installer/test-install.py [--keep]                       # QEMU, ~2 min
```

The selftest must run from the repository root (it reads `distro/base/root/etc`
and, when present, `distro/out/bin/palm` + the signed repository for a full
install into a directory). It never opens a block device, never mounts and
never touches the host's efivars.

## The API as built

Everything in INSTALLER.md's `install_core API` block exists with exactly
those names, types and signatures. Additions (all optional for a front end):

| name | why |
| --- | --- |
| `default_plan() -> Plan` | language en_US, keyboard us, UTC, hostname palmframe, repo `file:///usr/share/palm/repo`, `efi_boot_entry` = `/sys/firmware/efi` exists |
| `Options`, `default_options()` | target dir, `disk_image` test path, `steps` subset, palm binary, keys dir, limine dir, efivars dir, log path, `dry_run`, `on_log` callback (log lines, for the GUI's log view) |
| `install_with(p, o, report, user)` | `install` is `install_with(p, default_options(), ...)` |
| `validate_with(p, o, disks)` | validate against a given disk list / for a disk image |
| `step_title(Step)`, `step_name(Step)` | "Installing packages" / "packages" |
| `list_disks_in`, `partition_path`, `disks_in_use`, `human_size` | testable pieces |
| `gpt_*`, `guid_*`, `crc32`, `efi_load_option`, `sha512_crypt`, `make_hash`, `verify_password`, `limine_conf`, `partuuid` | exported for the selftest |
| `validate_messages(p, o, disks) -> []Message`, `Progress.detail` | the problems and the progress detail as `Message`s (below) |
| `Msg`, `Message`, `MESSAGE_FORMAT`, `msg`, `message_text`, `message_code`, `message_format`, `message_clone` | `message.odin` |
| `keyboard_settings(k)`, `keyboard_needs_latin(layout)` | the body of `/etc/palm/keyboard`, shared with the GUI's live switch |
| `load_option_partition`, `boot_entry_description` | the UEFI entry's partition GUID and name |
| `Plan.swap_bytes`, `Zone.country_code`, `Options.limine_tool`, `Options.no_bios_boot` | swap file, translation key, BIOS boot |
| `Plan.no_firmware`, `firmware_for_repo`, `firmware_from_index` | the packages step adds `linux-firmware` when the repository lists it (or is a network one), else every firmware part it lists (the live medium's); `no_firmware` (palm-install `--no-firmware`) adds none; `distro/notes/kernel.md`, Firmware |

Semantics a front end should know:

- **`Progress.fraction` is the whole installation's progress (0..1), not the
  step's.** Spans: partition 0–4 %, format 4–10, mount 10–12, packages 12–82
  (per package, from palm's output), configure 82–88, bootloader 88–96,
  unmount 96–100. It never goes backwards within a run (selftest checks it).
- `report` is called on the thread that called `install`; one installation
  per process at a time (a mutex; a second concurrent call fails at once).
- On failure `err` is `"<Step title>: <reason> (log: /var/log/palm-install.log)"`
  and whatever this run mounted is unmounted again.
- `validate` returns every problem as an English sentence;
  `validate_messages` returns the same problems as `Message`s: a `Msg` id
  whose lower-cased name is a stable code (`disk_live_medium`), and up to
  four string arguments. `MESSAGE_FORMAT[id]` is the English format and the
  msgid a front end translates (`%s`/`%q` only; sizes and counts arrive as
  strings). `Progress.detail` is a `Message` too, valid during the `report`
  call; `Progress.message` stays its English text. The GUI translates both
  through `installer.msg`, whose selftest checks every `MESSAGE_FORMAT`
  entry; `palm-install --json` adds `"codes"` to `invalid` and `"code"` to
  `progress`. It refuses the live medium, read-only disks, disks < 4 GiB,
  disks with a mounted filesystem, disks it cannot find, and a swap file
  that would leave less than 4 GiB.
- `Plan.root_password == ""` means the user's password. `packages` empty
  means `{"palmframe"}`.

## Decisions the contract left open

- **GPT**: our own writer (`core/gpt.odin`), 128 entries, 512 MiB ESP at
  LBA 2048 (partition 1), root from the next MiB to the last whole MiB before
  the backup table (partition 2), and a BIOS boot partition (type
  21686148-6449-6E6F-744E-656564454649, partition 3) in the gap from the first
  usable LBA to 1 MiB (1007 KiB with 512-byte sectors, 1000 KiB with 4 KiB);
  names "EFI system partition", "Palmframe", "BIOS boot partition"; disk and
  partition GUIDs from getrandom (v4). Partition 3 comes first on the disk so
  that 1 and 2 keep their numbers, which fdisk notes as "not in disk order"
  and `sfdisk --verify` accepts. 4 KiB logical sectors are honoured
  (BLKSSZGET). The first and last MiB of the disk are zeroed first. The
  table is read back and CRC-verified (both copies) before formatting.
- **BIOS boot**: the bootloader step copies `limine-bios.sys` to the ESP's
  `boot/limine/` and runs `limine bios-install <disk> 3`: limine's stage 1
  goes into the protective MBR's boot code (the 0xEE entry is untouched) and
  stage 2 into partition 3; stage 2 finds `limine-bios.sys` and
  `limine.conf` on the FAT32 ESP. The tool is limine's own,
  `/usr/bin/limine` from the limine package (found in PATH; palm-install
  used to carry a private copy). A failure fails the install only when the machine
  itself booted through a BIOS; otherwise it is a warning. The protective
  MBR's entry is not marked active: UEFI says not to, and SeaBIOS does not
  need it. Some old BIOSes refuse a GPT disk without it (parted's
  `pmbr_boot`); none was at hand to test.
- **Paths the bootloader step writes**, for whoever moves the kernel
  (`ESP_KERNEL` in `boot.odin` is the one constant): `EFI/BOOT/BOOTX64.EFI`,
  `EFI/palmframe/BOOTX64.EFI`, `boot/limine/limine.conf`,
  `boot/limine/limine-bios.sys` and `vmlinuz`, all relative to the ESP,
  mounted at `/mnt/target/boot/efi`; `limine.conf` boots
  `boot():/vmlinuz`. fstab's ESP line is
  `PARTUUID=<esp> /boot/efi vfat rw,relatime,fmask=0077,dmask=0077 0 2`
  (`write_fstab` in `configure.odin`).
- **Swap**: `Plan.swap_bytes > 0` makes `/swapfile` on the root
  (fallocate(2), zeros where that fails, mode 0600, `mkswap`) and the fstab
  line `/swapfile none swap defaults 0 0`, which palm-init turns on. The GUI
  offers it on the disk page, on by default, half the memory in whole GiB,
  1 to 4 GiB; `palm-install --swap 2G`.
- **A layout with no Latin letters** (`NON_LATIN_LAYOUTS`: ara, ru, gr, il,
  th, ...) is written as `layout = us,<layout>`, `variant = ,<variant>`,
  `options = grp:alt_shift_toggle`, on the new disk and in the live
  session, as Debian does for Russian: user names are a-z, so with `ara`
  alone an Arabic speaker could not type one.
- **Kernel's root**: `root=PARTUUID=<root>` — no initramfs and no blkid needed.
  fstab uses PARTUUID too (root `0 1`, ESP at /boot/efi `vfat
  rw,relatime,fmask=0077,dmask=0077 0 2`), which palm-init mounts at boot
  (distro/init/fstab.odin).
- **ESP layout**: `EFI/BOOT/BOOTX64.EFI`, `EFI/palmframe/BOOTX64.EFI`,
  `boot/limine/limine.conf` (limine finds it from both binaries),
  `vmlinuz` (contract: "booting /vmlinuz"). Two entries: normal and
  `palm.single`. BOOTX64.EFI comes from the target's `/usr/share/limine`, else
  `Options.limine_dir` (default the live system's `/usr/share/limine`, which
  the `palm-install` package pulls in through `limine`).
- **UEFI entry**: short-form `HD(1,GPT,<esp guid>,start,size)/\EFI\palmframe\BOOTX64.EFI`,
  description "Palmframe", or "Palmframe (<host name>)" when the host name
  is not the default. An existing entry is reused only when its description
  starts with "Palmframe" *and* its hard-drive node names the new ESP (a
  rerun) or a partition of the table this installation erased (the
  partition step reads the old GPT first): a reinstall takes its entry
  back, and a second disk in the same machine gets its own entry instead of
  taking the first disk's. Otherwise the lowest free number, then prepended
  to BootOrder. palm-init does not mount efivarfs, so the core mounts it for
  the write and unmounts it after.
  Failing to write it is logged and reported but does **not** fail the
  install (the fallback path boots). A disk-image run never uses the host's
  efivarfs, whatever the options say, unless given a stand-in directory.
- **The demo user**: `palm` is removed from passwd/group/shadow and every
  member list; the new user gets uid/gid 1000 (or the next free), its own
  group, wheel/video/input/audio, `/bin/sh`, and a home copied from
  `/etc/skel` if the base system has one, else from `/home/palm`, which is
  then deleted. Shadow last-change is today; hashes are `$6$` with a random
  16-char salt.
- **`/etc/palm/repositories`** is rewritten only when the install came from an
  `http(s)://` repository; installing from the live medium's local
  repository keeps palmframe-base's network repository (the local one does
  not exist on the new disk).
- **`file://` repos**: palm takes a path, so `file://` is stripped.
- **Package progress**: palm's `--json` is one document at the end, so the
  core reads palm's text instead: `  install   <pkg>` plan lines give the
  total, `installing <pkg>` lines the progress.
- **SHA-512 crypt is a copy** of `distro/login/crypt.odin` (`core/crypt.odin`,
  header says so) — importing package `login` would need a collection for
  one file. The selftest runs Drepper's vectors on the copy and verifies the
  base shadow's hashes with it.
- **Dry run** writes nothing at all, not even the log file.
- **CLI**: passwords only from files or stdin (`--password` on the command
  line is refused: /proc/<pid>/cmdline is world-readable); `password =` is
  allowed inside an `--answers` file. Options override the answers file;
  `--package` options replace its package list. Exit codes as palm:
  0, 2 usage, 3 not found, 4 refused (invalid plan / no --yes / not root),
  7 failed. `--json` prints `{"event":"progress"|"log"|"invalid"|"done",...}`
  lines.

## Requests for other areas

*Integration, 2026-10-13: /etc/skel (palmframe-base, with the demo home moved
to a palmframe-demo package), the /etc symlink treatment in palm verify, and
`make -C distro test-installer` are done; see notes/integrate.md. An install
now verifies clean.*

- **palmframe-base (integrate)**: ship the new user's skeleton as
  `/etc/skel/...` instead of (or as well as) `/home/palm/...`. Today the
  installer deletes `/home/palm`, and `palm verify` on an installed system
  then reports 7 "missing" files under /home/palm (seen in QEMU, below).
  The core already prefers `/etc/skel` when it exists.
- **palm**: `/etc/localtime` is a symlink in palmframe-base; `palm verify`
  reports the installer's changed target as a problem
  (`points to ../usr/share/zoneinfo/Europe/Paris, not .../UTC`) instead of
  "modified (config)" as it does for regular /etc files. Symlinks under /etc
  should get the same config treatment. Optional: a `--progress` line format
  for `add` so front ends need not parse human text.
- **Makefile (integrate)**: `make -C distro test-installer` could run
  `palm-install --selftest` (from the repo root, `TMPDIR=distro/build/installer-core`)
  and `distro/installer/test-install.py`.
- **palm-init**: mounting efivarfs at boot would let `efibootmgr`-style tools
  work on the installed system; the installer copes without it.
- **GUI (apps/installer)**: the core compiles and its API matches
  INSTALLER.md; `backend_core.odin` can switch from its stand-ins to
  `core.list_*`, `core.validate`, `core.install` now. `Options.on_log` (via
  `install_with`) is the hook for a live log view.

## What was verified

All on the build host as an ordinary user, or inside QEMU:

- `palm-install --selftest`: 1522 checks, 0 failures, ~2.5 s. CRC32 check
  values and agreement with core:hash; the ESP type GUID's on-disk bytes;
  GPTs written into 8 GiB and odd-sized sparse **image files** read by
  `sfdisk --verify` ("No errors detected") and `sfdisk --dump` (label-id,
  first/last LBA, every start/size/type/uuid equal to ours); corrupted
  header/entry/backup bytes rejected by our reader; 4 KiB-sector layout;
  Drepper's crypt vectors; base.lst (fr, us, de:nodeadkeys, variants after
  their layout) and zone1970.tab (every zone has a TZif file, sorted,
  Buenos Aires city, UTC added) from the host's real files, plus the
  zone.tab fallback; languages (fr via fr/, ja only with a CJK font, unknown
  catalogue offered); disks from a fake /sys/block (loop/sr/zram/ram/empty
  skipped, nvme/SanDisk models, removable, ro); the EFI_LOAD_OPTION bytes
  against a hand-written hex string; ~40 validate cases; partition + format
  of an image (FAT32 boot sector and label, ext4 magic and label at the
  offsets, `mdir` reads the ESP, `e2fsck -fn` on the carved-out root
  passes); configure + bootloader into a scratch root with a stand-in
  efivarfs (every file's content, shadow 0600, hashes verify, Boot0001 bytes,
  BootOrder 0001,0000; a second run reuses Boot0001); the whole installation
  with the real palm and repository into a directory; and the CLI's exit
  codes, `--dry-run --json`, `--answers` precedence, `--list-*`.
- `distro/installer/test-install.py`, run 2026-10-13 against the image from
  bb73180 and the repository of 18:08; the last run printed "all passed"
  (29 checks). The two runs before it failed on the test's own bugs (its
  tools disk left out libcom_err, a regex tripped on ls colours), not on the
  installer:
  - machine 1 (shipped image + blank 8 GiB qcow2 as /dev/vdb + tools disk):
    `--list-disks` marked `/dev/vda` "running system"; `--disk /dev/vda`
    refused (exit 4); no `--yes` refused after the summary (exit 4);
    `--dry-run` left vdb blank; the real install exited 0 in 1–3 s: GPT,
    BLKRRPART, `/dev/vdb1 /dev/vdb2` appeared, mkfs.fat, mkfs.ext4, mount,
    palm installed 33 packages, configure, limine, `UEFI: Boot000A
    "Palmframe"`. Mounting vdb2/vdb1 showed the hostname, `LANG=fr_FR.UTF-8`,
    `layout = fr`, the localtime symlink, PARTUUID fstab, alex 1000:1000 in
    wheel/audio/video/input, home 0700 1000:1000, shadow root 0600, both
    limine copies, limine.conf and vmlinuz on the ESP.
  - machine 2 (**only** the qcow2, same OVMF vars): OVMF booted
    `BootCurrent = 000A`, first in BootOrder, the "Palmframe" entry;
    `palmtest login:`; root logs in with the user's password; `/proc/cmdline`
    has `root=PARTUUID=...`; `id alex` uid 1000 with wheel/audio/video/input;
    `date +%Z` = CEST. The greeter came up in French with the Paris time,
    host name palmtest and "Alex Tester" (`distro/build/installer-core/qemu/installed-greeter.png`);
    typing the password logged alex in to `wm --drm` with the FR layout
    indicator (`installed-desktop.png`); `poweroff` ended both machines.
  - `palm verify` on the new disk: the configured /etc files as
    "modified (config)", plus the /etc/localtime and /home/palm reports
    described under *Requests* (8 problems, exit 1).

## palm-install's questions

`palm-install` with no options on a terminal, or `palm-install
--interactive`, asks for the disk (numbered; unusable disks shown with the
reason), the language, the layout (`?text` searches), the time zone
(`?text` searches city, zone and country), the computer name, full name,
user name (suggested from the full name), the password twice without echo,
whether root shares it, and a swap size. Each answer is checked with the
core's own rules as it is given (`check_user_name`, `check_hostname`, the
lists). Then the summary, and the disk's name must be typed back
(`again` starts over with the answers as defaults). Choosing Japanese adds
`fonts-cjk`. The questions are English: the serial console has no font
for the other scripts.

## Encryption: a design, not built

Full-disk encryption is in reach but larger than the rest of this round
together, and half of it is outside the installer, so it is written down
here instead.

- **What it needs from others.** The kernel: `CONFIG_DM_CRYPT=y`,
  `CONFIG_BLK_DEV_DM=y`, `CONFIG_CRYPTO_XTS=y`, `CONFIG_CRYPTO_AES_NI_INTEL=y`
  (and the generic AES), `CONFIG_CRYPTO_USER_API_SKCIPHER=y` (cryptsetup
  benchmarks through AF_ALG). All of them are set, built in, since the
  integration round. A `cryptsetup` package,
  copied from the build host like e2fsprogs: `cryptsetup` plus
  libcryptsetup, libdevmapper, libjson-c, libargon2, libcrypto (OpenSSL),
  libpopt, libuuid, libblkid — about 6 MB, every library glibc-only.
- **Layout.** Partition 2 becomes a LUKS2 container
  (`cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode
  --key-file -`, the passphrase on stdin, never argv), opened as
  `/dev/mapper/palmroot`, formatted ext4 inside. The ESP and the BIOS boot
  partition stay plain: limine cannot read LUKS, so the kernel, an
  initramfs and `limine.conf` live on the ESP, as the kernel already does.
  The swap file is inside the root, so it is encrypted with it.
- **Boot.** Today the kernel mounts the root itself (`root=PARTUUID=`, no
  initramfs). Encryption needs an initramfs: `boot():/initramfs.zst` beside
  the kernel, named in `limine.conf` with `module_path`, holding static
  busybox, cryptsetup with its libraries and glibc's loader, and an `/init`
  that mounts proc/sys/dev, finds the partition by PARTUUID
  (`/sys/class/block/*/uevent` carries `PARTUUID=`), asks for the
  passphrase on `/dev/console` (three tries), `cryptsetup open`s it,
  mounts `/dev/mapper/palmroot` at `/sysroot` and `switch_root`s into
  palm-init. Since every driver is built in, the initramfs does not depend
  on the kernel's version; it would be built once by the installer and
  rebuilt only when cryptsetup or busybox change, which palm has no hook
  for — the cryptsetup package would have to carry a `palm-initramfs`
  command and a note. The kernel command line becomes
  `root=/dev/mapper/palmroot palm.crypt=PARTUUID=<p2>`; `/etc/crypttab`
  names the container for the record.
- **The keyboard at the prompt** is the kernel console's, US: a passphrase
  typed on AZERTY would not match. The installer would either warn and
  show the passphrase as US keys, or put busybox's `loadkmap` and a binary
  keymap of the chosen layout into the initramfs (busybox `dumpkmap` can
  produce one from a console keymap, which Palmframe does not ship).
- **The installer.** `Plan.encrypt` and `Plan.passphrase`; Format opens
  the container before mkfs and Unmount closes it; the GUI puts a checkbox
  and two passphrase fields on the disk page, says that a forgotten
  passphrase loses everything, and the summary repeats it; palm-install
  takes `--encrypt` with `--passphrase-file`. Validate refuses an empty or
  mismatched passphrase.
- **Cost.** One new host package, four kernel options, an initramfs
  builder (shell, ~60 lines), ~150 lines in the core, the GUI fields and
  their 5 translations, and a QEMU test that types the passphrase at the
  console under OVMF and SeaBIOS.

## Gaps

- No installed-system resize, encryption (above) or dual boot:
  erase-the-disk only, as the contract says.
- The kernel on the ESP is a copy, as on the image: `palm upgrade linux`
  does not update it. The ESP is mounted at boot now (palm-init reads
  fstab).
- MMC partition naming is tested only as a function; 4 KiB-sector devices
  only as a layout in a file. NVMe ran in QEMU (see the README's
  *Installing*).
- A SeaBIOS machine boots an NVMe disk only when the disk has a boot index
  (chosen in the BIOS menu); QEMU's SeaBIOS never tries it otherwise. Real
  BIOSes vary; few boot NVMe in legacy mode at all.
