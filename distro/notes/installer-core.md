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

Semantics a front end should know:

- **`Progress.fraction` is the whole installation's progress (0..1), not the
  step's.** Spans: partition 0–4 %, format 4–10, mount 10–12, packages 12–82
  (per package, from palm's output), configure 82–88, bootloader 88–96,
  unmount 96–100. It never goes backwards within a run (selftest checks it).
- `report` is called on the thread that called `install`; one installation
  per process at a time (a mutex; a second concurrent call fails at once).
- On failure `err` is `"<Step title>: <reason> (log: /var/log/palm-install.log)"`
  and whatever this run mounted is unmounted again.
- `validate` returns every problem, as plain English sentences (the GUI can
  `tr()` them). It refuses the live medium, read-only disks, disks < 4 GiB,
  disks with a mounted filesystem, and disks it cannot find.
- `Plan.root_password == ""` means the user's password. `packages` empty
  means `{"palmframe"}`.

## Decisions the contract left open

- **GPT**: our own writer (`core/gpt.odin`), 128 entries, 512 MiB ESP at
  LBA 2048, root from the next MiB to the last whole MiB before the backup
  table; names "EFI system partition" and "Palmframe"; disk and partition
  GUIDs from getrandom (v4). 4 KiB logical sectors are honoured (BLKSSZGET).
  The first and last MiB of the disk are zeroed first. The table is read back
  and CRC-verified (both copies) before formatting.
- **Kernel's root**: `root=PARTUUID=<root>` — no initramfs and no blkid needed.
  fstab uses PARTUUID too (root `0 1`, ESP at /boot/efi `vfat
  rw,relatime,fmask=0077,dmask=0077 0 2`). palm-init does not run `mount -a`,
  so the ESP is not mounted on the installed system yet (same gap as the image).
- **ESP layout**: `EFI/BOOT/BOOTX64.EFI`, `EFI/palmframe/BOOTX64.EFI`,
  `boot/limine/limine.conf` (limine finds it from both binaries),
  `vmlinuz` (contract: "booting /vmlinuz"). Two entries: normal and
  `palm.single`. BOOTX64.EFI comes from the target's `/usr/share/limine`, else
  `Options.limine_dir` (default the live system's `/usr/share/limine`, which
  the `palm-install` package pulls in through `limine`).
- **UEFI entry**: short-form `HD(1,GPT,<esp guid>,start,size)/\EFI\palmframe\BOOTX64.EFI`,
  description "Palmframe", reusing an existing "Palmframe" Boot#### or the
  lowest free number, then prepended to BootOrder. palm-init does not mount
  efivarfs, so the core mounts it for the write and unmounts it after.
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

## Gaps

- No installed-system resize, swap, encryption, or dual boot: erase-the-disk
  only, as the contract says.
- BIOS boot of the installed disk is not set up (no BIOS boot partition,
  no `limine bios-install`): the contract's layout is UEFI-only.
- The kernel on the ESP is a copy, as on the image: `palm upgrade linux`
  does not update it, and the ESP is not mounted at boot (no `mount -a`).
- Not tested here: NVMe/MMC partition naming (`p1`) on real devices (only the
  naming function), 4 KiB-sector devices (only the layout in a file), the
  live ISO path (`palm-install` from the package, limine from
  `/usr/share/limine`) — the QEMU test brings its own tools disk instead.
