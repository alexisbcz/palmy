# The installer

The installer's interfaces and behaviour. They are in addition to
`CONTRACT.md`. This file started as the contract the pieces were built
against. It now describes what was built, and it remains the reference. Where
the build differs from the original contract, the text says so ("*Built:*").
Each area's reasons are in `distro/notes/<area>.md`. How to use the installer,
and what was verified in QEMU, is under *Installing* in `README.md`.

## What a person does

Boot `distro/out/palmy-live.iso` in QEMU or from a USB stick. The ISO
boots under UEFI and under BIOS (limine's CD images plus `limine bios-install`
for hybrid USB boot). The live system runs entirely from RAM. It starts
straight into the graphical installer, which is `wm --drm --kiosk --exec
installer` as root, run through a live-only palm-init service. A root shell
is on the serial console. The installer has eight steps, shown in a rail:

1. **Language.** The UI switches immediately. The choices are English,
   Français, Deutsch, Español, العربية (right to left) and 日本語. Japanese
   is offered only when a CJK font is installed; otherwise it is listed as
   unavailable rather than drawn as tofu. The live system ships a CJK font subset,
   so Japanese is offered there. Choosing a language also preselects a
   keyboard layout and a time zone until the person picks those.
2. **Keyboard.** A layout and variant from xkeyboard-config's `base.lst`,
   with a test field. The compositor switches layout live.
3. **Time zone.** A region and city from tzdata's `zone1970.tab`, searchable,
   with the local time shown.
4. **Disk.** Every block device from `/sys/block`, with size and model.
   *Erase the whole disk* (GPT: 512 MiB ESP and an ext4 root) is the only
   mode, stated plainly, and needs an explicit confirmation naming the
   device. In the confirmation dialog Cancel has the focus.
5. **Account.** Full name, user name, password (twice) and hostname. The root
   password is the same as the user's unless changed.
6. **Summary**, then **Install**: progress with the current step, and a log
   view.
7. **Done**, then **Restart**.

*Built:* the rail counts Summary and Install as separate steps, so the GUI
shows eight steps. The disk step also offers a swap file. An installed
disk boots under UEFI and under a BIOS (see *Bootloader*).

## The pieces

| piece | where | language |
| --- | --- | --- |
| install core (library) | `distro/installer/core/`, package `install_core` | Odin |
| CLI front end `palm-install` | `distro/installer/cli/` | Odin |
| GUI front end `installer` | `apps/installer/` | Odin + palmy |
| translations library | `apps/kit/i18n.odin` (package kit) | Odin |
| catalogues | `distro/locale/<lang>/<domain>.msg` → `/usr/share/palm/locale/<lang>/<domain>.msg` | text |
| keyboard layouts for the wm | `apps/wm/keyboard.odin` | Odin |
| live image | `distro/live/` | shell |
| end-to-end test | `distro/live/test-install.py` (`make -C distro test-install`) | Python |

The installer is built with these collections: `-collection:palmy=palmy
-collection:kit=apps/kit -collection:shadcn=shadcn
-collection:install=distro/installer`, so the GUI imports
`import core "install:core"`.

## install_core API

```odin
Disk :: struct { path: string, name: string, model: string, size_bytes: u64, removable: bool, readonly: bool, has_partitions: bool, is_live_medium: bool }
list_disks :: proc(allocator := context.allocator) -> []Disk

Keyboard :: struct { layout: string, variant: string, description: string }
list_layouts :: proc(xkb_root := "/usr/share/X11/xkb") -> []Keyboard     // from rules/base.lst, layouts + variants
Zone :: struct { name: string, region: string, city: string, country: string }
list_zones :: proc(zoneinfo := "/usr/share/zoneinfo") -> []Zone          // from zone1970.tab (fallback zone.tab)
Language :: struct { code: string, native_name: string, english_name: string, rtl: bool, available: bool }
list_languages :: proc(locale_root := "/usr/share/palm/locale") -> []Language

Plan :: struct {
	disk:       string,   // /dev/vda
	language:   string,   // fr_FR
	keyboard:   Keyboard, // {layout="fr", variant=""}
	timezone:   string,   // Europe/Paris
	hostname:   string,
	full_name:  string,
	user:       string,
	password:   string,   // hashed with SHA-512 crypt before it touches disk
	root_password: string, // empty = same as user
	repo:       string,   // default: the live medium's repository, file:///usr/share/palm/repo
	packages:   []string, // default: {"palmy"}
	efi_boot_entry: bool, // write a UEFI Boot#### variable via efivarfs (default true when /sys/firmware/efi exists)
	swap_bytes:     u64,  // built: a /swapfile of this size; 0 = none
}
validate :: proc(p: Plan) -> (ok: bool, problems: []string)     // user name rules, hostname rules, disk exists & is not the live medium, size >= 4 GiB
Step :: enum { Partition, Format, Mount, Packages, Configure, Bootloader, Unmount, Done }
Progress :: struct { step: Step, fraction: f32, message: string }
// Runs on a worker thread; calls `report` from that thread. Returns the log path on failure.
install :: proc(p: Plan, report: proc(Progress, rawptr), user: rawptr) -> (ok: bool, err: string)
```

*Built:* every name above exists with these types. The semantics a front end
needs:

- `Progress.fraction` is the whole installation's progress, from 0 to 1, not
  the current step's, and it never goes backwards. Each step has a fixed span:
  partition 0–4 %, format 4–10, mount 10–12, packages 12–82, configure
  82–88, bootloader 88–96, unmount 96–100.
- `report` is called on the thread that called `install`. Only one
  installation runs per process at a time.
- On failure `err` is `"<Step title>: <reason> (log: /var/log/palm-install.log)"`,
  and whatever the run mounted is unmounted again.
- `validate` returns every problem as an English sentence.
  `validate_messages(p, o, disks) -> []Message` returns the same problems
  as `Message`s: a `Msg` id (its lower-cased name is a stable code such as
  `disk_live_medium`) and up to four string arguments.
  `MESSAGE_FORMAT[id]` is the English format and the msgid a front end
  translates; `message_text` fills it in English. `Progress.detail` is the
  progress line as a `Message` (`Progress.message` stays its English text).
  The GUI translates both. Besides the rules above, it refuses read-only
  disks, disks with a mounted filesystem, disks it cannot find and a swap
  file that would leave less than 4 GiB.
- `keyboard_settings(k)` is the body of `/etc/palm/keyboard` for a choice.
  A layout with no Latin letters (`keyboard_needs_latin`: ara, ru, gr, ...)
  becomes `layout = us,<layout>`, `variant = ,<variant>`, `options =
  grp:alt_shift_toggle`, so a user name can be typed.
- `Zone.country` is the country's name (`France`), from `iso3166.tab`, and
  `Zone.country_code` its code. `list_zones` includes `UTC`.
- Language codes are `en_US`, `fr_FR`, `de_DE`, `es_ES`, `ar` and `ja_JP`.
  Any other catalogue directory under `locale_root` is offered by its code.
- `Plan.packages` empty means `{"palmy"}`. The GUI passes
  `{"palmy", "fonts-cjk"}` for Japanese.

Additions, all optional for a front end:

| name | what |
| --- | --- |
| `default_plan() -> Plan` | en_US, us, UTC, hostname palmy, the medium's repository, `efi_boot_entry` if `/sys/firmware/efi` exists |
| `Options`, `default_options()` | target directory (default `/mnt/target`), `disk_image` (the disk is a plain file; refused for `/dev/*`), a subset of `steps`, palm binary, keys dir, limine dir, efivars dir, log path, `dry_run`, `on_log` (each log line, used for the GUI's log view and the CLI's `--verbose`) |
| `install_with(p, o, report, user)` | `install` is `install_with(p, default_options(), ...)` |
| `validate_with(p, o, disks)` | validate against a given disk list, or for a disk image |
| `step_title(Step)`, `step_name(Step)` | "Installing packages" and "packages" |

What `install` does, in order:

1. **Partition.** The core writes a fresh GPT itself: a protective MBR, the
   primary and backup headers, and CRC32s. Partition 1 is the ESP (type
   C12A7328-F81F-11D2-BA4B-00A0C93EC93B, 512 MiB, aligned to 1 MiB).
   Partition 2 is the Linux root (0FC63DAF-8483-4772-8E79-3D69D8477DE4,
   the rest of the disk). Then `BLKRRPART`, and a wait for the partition
   nodes.
   *Built:* the table has 128 entries, and GUIDs are version 4 from
   getrandom. Partition 3 is a BIOS boot partition
   (21686148-6449-6E6F-744E-656564454649) in the gap from the first usable
   LBA to 1 MiB. The old table is read first, to know which UEFI entry
   pointed at this disk. The first and last MiB are zeroed first. 4 KiB
   logical sectors are honoured. Both copies of the table are read back and
   CRC-checked before formatting. `BLKRRPART` is retried on EBUSY.
2. **Format.** `mkfs.fat -F 32 -n PALMEFI` and `mkfs.ext4 -F -L palmroot`.
   These come from dosfstools and e2fsprogs, shipped in the live image as
   packages. busybox keeps the `mke2fs` and `mkfs.vfat` names.
3. **Mount.** The root goes at `/mnt/target` and the ESP at
   `/mnt/target/boot/efi`.
4. **Packages.** `palm --root /mnt/target --initdb --repo <repo> --keys-dir
   /etc/palm/keys --yes add palmy <extra>`.
   *Built:* palm's `--json` is a single document printed at the end, so
   progress comes from palm's text output instead: the plan lines give the
   total and the `installing <pkg>` lines give progress. `file://` is
   stripped from the repository, because palm takes a path. 33 packages
   are installed; `palmy-demo` (the disk image's `/home/palm`) is not
   among them.
5. **Configure.** The core writes:
   - `/etc/hostname` and `/etc/hosts`.
   - The users in passwd, group and shadow. The `palm` demo user is removed
     from every file and member list. The new user gets uid/gid 1000 (or the
     next free number), wheel, video, input and audio, `/bin/sh`, and a home
     copied from `/etc/skel` with mode 0700. Hashes are `$6$` with a random
     16-character salt.
   - `/etc/locale.conf`, for example `LANG=fr_FR.UTF-8`.
   - `/etc/palm/keyboard` (see below).
   - The `/etc/localtime` → `../usr/share/zoneinfo/<zone>` symlink, and
     `/etc/timezone`.
   - `/etc/fstab`, naming the root and the ESP at `/boot/efi` by PARTUUID.
   - `/etc/palm/repositories`, pointing at the network repository.
   *Built:* `repositories` is rewritten only when the install came from an
   `http(s)://` repository. An install from the medium keeps
   palmy-base's network repository.
6. **Bootloader.** limine's `BOOTX64.EFI` goes at `EFI/BOOT/BOOTX64.EFI`
   *and* at `EFI/palmy/BOOTX64.EFI`. A `limine.conf` boots `/vmlinuz`,
   copied onto the ESP, with `root=PARTUUID=<root> rw`. If `efi_boot_entry`
   is set, a `Boot####` variable named "Palmy" points at
   `\EFI\palmy\BOOTX64.EFI`, and `BootOrder` is updated. Both are written
   through efivarfs (`/sys/firmware/efi/efivars`, attributes NV|BS|RT, with
   the immutable flag cleared through FS_IOC_SETFLAGS).
   *Built:*
   - `limine.conf` is at `boot/limine/limine.conf`, where both binaries find
     it. It has two entries: the normal boot, and a single-user root shell
     (`palm.single`).
   - `BOOTX64.EFI` comes from the target's `/usr/share/limine` if present,
     and otherwise from the live system's.
   - The device path is the short form `HD(1,GPT,<esp guid>,start,size)/\EFI\palmy\BOOTX64.EFI`.
   - The description is "Palmy (<host name>)", or "Palmy" for the
     default host name. An existing entry is reused only when it is ours
     and points at the new ESP or at a partition of the erased table;
     otherwise the lowest free number is taken, so each disk keeps its own
     entry. The entry is then put first in `BootOrder`.
   - palm-init does not mount efivarfs, so the core mounts it for the write
     and unmounts it afterwards.
   - A failed write is logged but does not fail the install, because the
     disk still boots through `EFI/BOOT/BOOTX64.EFI`.
   - `limine-bios.sys` is copied to `boot/limine/` on the ESP and `limine
     bios-install <disk> 3` puts limine's stage 1 into the MBR and stage 2
     into the BIOS boot partition. The tool is `/usr/lib/palm-install/limine`
     (palm-install's package) unless `limine` is in PATH. A failure is fatal
     only when the machine booted through a BIOS.
   - `Plan.swap_bytes` makes `/swapfile` (configure step) and its fstab line.
7. **Unmount**, then sync.

## palm-install

`palm-install --help` lists every option: `--disk`, `--language`,
`--keyboard layout[:variant]`, `--timezone`, `--hostname`, `--user`,
`--full-name`, `--password-file <file|->`, `--root-password-file`, `--repo`,
`--package` (repeatable), `--swap <size>`, `--no-efi-entry`,
`--no-bios-boot`, `--answers <file>`, `--yes`, `--dry-run`, `--json`,
`--verbose`, and `--list-disks|layouts|zones|languages`. *Built:* with no
options on a terminal, or `--interactive`, it asks each question instead.

Passwords are never accepted as command-line arguments, because
`/proc/<pid>/cmdline` is world-readable. `password =` is allowed in an
answers file, and command-line options override the answers file.
`palm-install` refuses without `--yes`. Exit codes follow palm's: 0, 2
usage, 3 not found, 4 refused (invalid plan, no `--yes`, not root), 7
failed. `--json` prints one `{"event":"progress"|"log"|"invalid"|"done",...}`
object per line.

The build-host test paths are `--disk-image <file>` (implies no mounting),
`--target <dir>`, `--steps a,b,...`, `--efivars <dir>` (a directory standing
in for efivarfs), `--palm`, `--keys-dir`, `--limine-dir`, `--log` and
`--selftest`. A disk image never uses the host's efivarfs.

## System configuration files the installed system honours

- **`/etc/palm/keyboard`**: `layout = fr`, `variant =`, `options =`, and
  optionally `model =`, as `key = value` lines. The wm (`--drm`) compiles
  that keymap from `/usr/share/X11/xkb` with its own XKB compiler at start.
  It re-reads the file on SIGHUP, at once through inotify on the directory,
  and through a 1 s stat check. Each reload sends the new keymap to every
  client. The live installer relies on this to switch layout as the user
  picks it; the GUI signals only a process whose `comm` is `wm`.
  `XKB_DEFAULT_LAYOUT` and `XKB_DEFAULT_VARIANT` override the file. A layout
  that cannot be compiled falls back to `us`, and the reason is logged.
  Several layouts (`us,ru` with `grp:alt_shift_toggle`) work.
- **`/etc/locale.conf`**: `LANG=fr_FR.UTF-8`. palm-login exports `LANG`, and
  `LANGUAGE` and `LC_*` when set, to the greeter and to user sessions.
  palm-init exports them to services, re-reading the file before each start.
  Only those keys are taken from the file. `kit.i18n` reads `LANGUAGE`, then
  `LC_ALL`, `LC_MESSAGES`, `LANG`.
- **`/etc/localtime`** (a TZif symlink): glibc reads it. The greeter clock
  and the wm bar clock show local time from it (or from `TZ`). palm-login
  exports `TZ` from `/etc/timezone` only when `/etc/localtime` is missing or
  dangling. The disk image's default is `UTC`.
- `palm verify` counts a changed regular file or retargeted symlink under
  `/etc` as "modified (config)", not as a problem. An installed system
  therefore verifies clean.

## i18n library (`apps/kit/i18n.odin`)

```odin
i18n_init :: proc(domain: string, lang := "")     // "" = from environment; loads <root>/<lang>/<domain>.msg, falling back fr_FR -> fr -> source string
tr  :: proc(msgid: string) -> string               // returns the translation or msgid itself
trf :: proc(msgid: string, args: ..any) -> string  // tr then fmt with the translated format
trn :: proc(singular, plural: string, n: int) -> string
i18n_set_language :: proc(lang: string)            // switch live (the installer's language step)
i18n_is_rtl :: proc() -> bool
```

*Built:* the library also has `trnf`, `i18n_language`, `i18n_shutdown`,
`i18n_parse`, `i18n_load_file`, `i18n_lookup` and `i18n_catalog_destroy`.

- The fallback is `fr_FR.UTF-8@euro` → `fr_FR.UTF-8` → `fr_FR@euro` →
  `fr_FR` → `fr` → msgid. Every catalogue found along the way is kept, so a
  string missing from `fr_FR` is looked up in `fr`.
- The root is `/usr/share/palm/locale`. `PALM_LOCALE_DIR` overrides it.
- Odin's explicit argument indices (`%[0]s`) start at 0. Translations use
  them to reorder arguments.
- `apps/kit/i18n_test` tests the library and lints every
  `distro/locale/*/*.msg`.

Catalogue format (`.msg`): UTF-8, gettext-like but simpler. Lines of the form
`msgid = translation` would break on an `=` in the text, so the format does
not use them:

```
# comment
plural = n > 1

msgid "Install Palmy"
msgstr "Installer Palmy"

msgid "%d package"
msgid_plural "%d packages"
msgstr[0] "%d paquet"
msgstr[1] "%d paquets"
```

The header has `key = value` lines. `plural` takes a full gettext C
expression. `language`, `name` and `english` name the catalogue's language,
and `direction = rtl|ltr` overrides the default, which is right to left for
ar, he, fa and ur. Arabic uses its real six-form rule, and Japanese uses
`plural = 0`. An empty `msgstr` means untranslated. `distro/locale/README.md`
is the translators' guide.

## Live image (`distro/live/`)

- The root filesystem is assembled with `palm --root ... --initdb add
  palmy-live` under fakeroot, from the same signed repository.
  *Built:* `palmy-live` depends on the base system, the kiosk wm,
  `term`, `palm-install`, `installer`, `e2fsprogs`, `dosfstools`, `limine`,
  `tzdata`, `xkeyboard-config` and `palm-locale`, 19 packages in all, and
  carries a 100 KB Japanese subset of Noto Sans CJK instead of `fonts-cjk`.
  The packages of `palmy` and `fonts-cjk` with their dependencies (36)
  are copied flat to `/usr/share/palm/repo` with a newly signed index, so
  installing needs no network.
- `palmy-live` provides:
  - the `installer` service, running `/usr/lib/palm-live/installer-session`
    as root, which runs `wm --drm --kiosk --exec installer`. The kernel
    option `palm.live.serial` starts no session, and `palm.live.exec=<cmd>`
    runs another program instead.
  - a root autologin getty on ttyS0 (`getty-live`).
  - the `/etc/palm/live` marker and the `/init` symlink to palm-init.
  - `/etc/palm/services.off/palm-login` and `getty-ttyS0`, which mask
    palmy-base's services.
- `/boot/vmlinuz` is left out of the initramfs to save RAM, because the
  kernel is on the ISO beside it. `palm verify` on the live system reports
  exactly that one file as missing.
- The root is packed as a zstd cpio initramfs (`CONFIG_RD_ZSTD=y`), booted by
  limine from an ISO 9660 image built with `xorriso`: UEFI El Torito with
  `limine-uefi-cd.bin`, BIOS with `limine-bios-cd.bin`, then `limine
  bios-install` for hybrid USB boot. The limine menu has two entries,
  *Install Palmy* and *Install Palmy (serial console only)*.
- The output is `distro/out/palmy-live.iso`, built by `make -C distro iso`:
  about 74 MB, with a 57 MB initramfs that unpacks to about 81 MiB.
  `distro/run-qemu.sh --iso [--disk <target.qcow2>]` boots it with a target
  disk attached as virtio. Without `--disk`, it makes
  `distro/out/target.qcow2` (8 GiB) if the file is missing. OVMF's variable
  store is kept as `<disk>.OVMF_VARS.fd` beside the disk.
