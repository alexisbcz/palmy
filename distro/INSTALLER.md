# The installer — contract

The interfaces the installer's pieces are built against, in addition to
`CONTRACT.md`. Notes on deviations go in `distro/notes/<area>.md`.

## What a person does

Boot `distro/out/palmframe-live.iso` (UEFI, also BIOS where limine allows) in
QEMU or from a USB stick. The live system runs entirely from RAM and starts
straight into the graphical installer — `wm --drm --kiosk --exec installer` as
root, through a live-only palm-init service — with a shell on the serial
console. The installer walks through:

1. **Language** — the UI switches immediately. English, Français, Deutsch,
   Español, العربية (right to left, palmy has bidi), 日本語 (if a CJK font is
   shipped; otherwise listed as unavailable rather than rendering tofu).
2. **Keyboard** — layout + variant from xkeyboard-config's `base.lst`, with a
   test field; the compositor switches layout live.
3. **Time zone** — region/city from `/usr/share/zoneinfo` (tzdata's
   `zone1970.tab`), searchable, with the local time shown.
4. **Disk** — every block device from `/sys/block` with size and model;
   *erase the whole disk* (GPT: 512 MiB ESP + ext4 root) is the only mode,
   stated plainly, with an explicit confirmation naming the device.
5. **Account** — full name, user name, password (twice), hostname; the root
   password is the same unless changed.
6. **Summary → Install** — progress with the current step, and a log view.
7. **Done → Restart**.

## The pieces

| piece | where | language |
| --- | --- | --- |
| install core (library) | `distro/installer/core/` package `install_core` | Odin |
| CLI front end `palm-install` | `distro/installer/cli/` | Odin |
| GUI front end `installer` | `apps/installer/` | Odin + palmy |
| translations library | `apps/kit/i18n.odin` (package kit) | Odin |
| catalogues | `distro/locale/<lang>/<domain>.msg` → `/usr/share/palm/locale/<lang>/<domain>.msg` | text |
| keyboard layouts for the wm | `apps/wm/` | Odin |
| live image | `distro/live/` | shell + Odin as needed |

Collections for building the installer: `-collection:palmy=palmy
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
	packages:   []string, // default: {"palmframe"}
	efi_boot_entry: bool, // write a UEFI Boot#### variable via efivarfs (default true when /sys/firmware/efi exists)
}
validate :: proc(p: Plan) -> (ok: bool, problems: []string)     // user name rules, hostname rules, disk exists & is not the live medium, size >= 4 GiB
Step :: enum { Partition, Format, Mount, Packages, Configure, Bootloader, Unmount, Done }
Progress :: struct { step: Step, fraction: f32, message: string }
// Runs on a worker thread; calls `report` from that thread. Returns the log path on failure.
install :: proc(p: Plan, report: proc(Progress, rawptr), user: rawptr) -> (ok: bool, err: string)
```

What `install` does, in order:

1. **Partition**: write a fresh GPT itself (protective MBR, primary + backup
   headers, CRC32s) — partition 1 ESP (type C12A7328-F81F-11D2-BA4B-00A0C93EC93B,
   512 MiB, aligned 1 MiB), partition 2 Linux root (0FC63DAF-8483-4772-8E79-3D69D8477DE4,
   rest of disk); then `BLKRRPART` and wait for the partition nodes.
2. **Format**: `mkfs.fat -F32 -n PALMEFI` and `mkfs.ext4 -F -L palmroot`
   (dosfstools and e2fsprogs, shipped in the live image as packages).
3. **Mount** root at `/mnt/target`, ESP at `/mnt/target/boot/efi`.
4. **Packages**: `palm --root /mnt/target --initdb --repo <repo> --keys-dir /etc/palm/keys --yes add palmframe <extra>` — progress from palm's `--json` output if available.
5. **Configure**: `/etc/hostname`, `/etc/hosts`, users in passwd/group/shadow (the new user in wheel, video, input, audio; `palm` demo user removed), `/etc/locale.conf` (`LANG=fr_FR.UTF-8`), `/etc/palm/keyboard` (see below), `/etc/localtime` → `../usr/share/zoneinfo/<zone>` symlink and `/etc/timezone`, `/etc/fstab` (root by UUID / PARTUUID, ESP at /boot/efi), `/etc/palm/repositories` pointing at the network repository.
6. **Bootloader**: limine `BOOTX64.EFI` at `EFI/BOOT/BOOTX64.EFI` *and* `EFI/palmframe/BOOTX64.EFI`, `limine.conf` booting `/vmlinuz` (copied onto the ESP) with `root=PARTUUID=<root> rw`; if `efi_boot_entry`, a `Boot####` variable "Palmframe" pointing at `\EFI\palmframe\BOOTX64.EFI` plus `BootOrder`, written through efivarfs (`/sys/firmware/efi/efivars`, attributes NV|BS|RT, `chattr -i` equivalent via FS_IOC_SETFLAGS where needed).
7. **Unmount**, sync.

## System configuration files the installed system honours

- `/etc/palm/keyboard`: `layout = fr`, `variant =`, `options =` (key = value).
  The wm (`--drm`) compiles that keymap from `/usr/share/X11/xkb` with its own
  XKB compiler at start, and re-reads it on SIGHUP or when the file changes —
  the live installer relies on that to switch layout as the user picks it.
  `XKB_DEFAULT_LAYOUT`/`XKB_DEFAULT_VARIANT` override it.
- `/etc/locale.conf`: `LANG=fr_FR.UTF-8`. palm-login exports `LANG` to the
  greeter and to user sessions; palm-init exports it to services.
  `kit.i18n` reads `LANGUAGE`, then `LC_ALL`, `LC_MESSAGES`, `LANG`.
- `/etc/localtime` (TZif symlink): glibc reads it; palmy apps that show time
  (greeter clock, wm bar) must use local time, not UTC.

## i18n library (`apps/kit/i18n.odin`)

```odin
i18n_init :: proc(domain: string, lang := "")     // "" = from environment; loads <root>/<lang>/<domain>.msg, falling back fr_FR -> fr -> source string
tr  :: proc(msgid: string) -> string               // returns the translation or msgid itself
trf :: proc(msgid: string, args: ..any) -> string  // tr then fmt with the translated format
trn :: proc(singular, plural: string, n: int) -> string
i18n_set_language :: proc(lang: string)            // switch live (the installer's language step)
i18n_is_rtl :: proc() -> bool
```

Catalogue format (`.msg`): UTF-8, `msgid = translation` lines would break on
`=` in text, so it is gettext-like but simpler:

```
# comment
msgid "Install Palmframe"
msgstr "Installer Palmframe"

msgid "%d package"
msgid_plural "%d packages"
msgstr[0] "%d paquet"
msgstr[1] "%d paquets"
```

Plural rule per language in the catalogue header line `plural = n > 1` /
`n != 1` / `0` (no plurals, e.g. Japanese) / Arabic's six forms may be
simplified to `n != 1` with a note.

## Live image (`distro/live/`)

- Rootfs assembled with `palm --root` under fakeroot from the same signed
  repository: `palmframe` + `palm-install` + `installer` + `e2fsprogs` +
  `dosfstools` + `tzdata` + `xkeyboard-config`; the repository itself copied to
  `/usr/share/palm/repo` (so installing needs no network); a live-only
  `palmframe-live` package with the installer service (`wm --drm --kiosk --exec
  installer`, user root, replacing palm-login) and a root autologin getty on
  ttyS0.
- Packed as a zstd cpio initramfs (`CONFIG_RD_ZSTD=y`), booted by limine from
  an ISO 9660 image built with `xorriso` (rootless wrapper in `~/.local/bin`):
  UEFI El Torito with `limine-uefi-cd.bin`, BIOS with `limine-bios-cd.bin`,
  then `limine bios-install` for hybrid USB boot.
- Output `distro/out/palmframe-live.iso`; `make -C distro iso`;
  `distro/run-qemu.sh --iso [--disk <blank.qcow2>]` boots it with a blank
  target disk attached as virtio.
