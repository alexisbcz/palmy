# The live installer image and the installer's packages

Owner: `distro/live/`, the recipes `tzdata`, `e2fsprogs`, `dosfstools`,
`limine`, `fonts-cjk`, `palm-locale`, `palm-install`, `installer`,
`palmframe-live`, their part of `distro/recipes/generate.sh`, the `iso` /
`run-iso` targets and installer rules in `distro/Makefile`, `--iso` / `--disk`
in `distro/run-qemu.sh`, and this file.

## Use it

```
make -C distro iso                       # distro/out/palmframe-live.iso
distro/run-qemu.sh --iso                 # boot it (OVMF), blank 8G target
                                         # distro/out/target.qcow2 made if absent
distro/run-qemu.sh --iso --bios          # the same under SeaBIOS
distro/run-qemu.sh --iso --disk D.qcow2  # another target disk
distro/run-qemu.sh --disk distro/out/target.qcow2   # boot what was installed
python3 -I distro/live/test-boot.py [--bios] [--serial-only] [--expect installer|term]
LIVE_WITHOUT_INSTALLER=1 distro/live/build.sh       # test ISO without the front ends
```

With `--iso` or `--disk`, OVMF's variable store is `<disk>.OVMF_VARS.fd`
beside that disk, so the `Boot####` entry the installer writes stays with the
disk it installed onto and survives into the `--disk` boot.

## What the ISO is

- limine 12.8 on an ISO 9660 image (xorriso): BIOS El Torito
  `limine-bios-cd.bin`, UEFI El Torito `limine-uefi-cd.bin`, protective MBR,
  then `limine bios-install` for raw USB-stick boot. Menu, 5 s timeout:
  - **Install Palmframe** — `console=tty0 console=ttyS0,115200 quiet loglevel=3`
  - **Install Palmframe (serial console only)** — `console=ttyS0,115200 palm.live.serial`
- `boot/vmlinuz` and `boot/initramfs.zst` (limine `module_path`). No `root=`,
  so the kernel keeps the initramfs as `/` on tmpfs; nothing is read from the
  medium after boot. The initramfs `/init` is a symlink to `usr/bin/palm-init`
  (owned by palmframe-live); `/dev/console` and `/dev/null` are in the cpio.
- The root is `palm --root … --initdb add palmframe-live` under fakeroot, cpio
  in the same session (owners and 0600 shadow preserved), zstd -19.
- **Sizes (last build): ISO 102 MB; initramfs 84 MB compressed, ~133 MiB
  unpacked in RAM; 40 packages.** After boot with the installer up, `free -m`
  in a 2 GiB guest said 118 MiB used, ~1.7 GiB available. The compressed size
  is dominated by the repository copy (62 MB of already-gzipped `.palm`), which
  zstd cannot shrink.

## The live system's services

palmframe-live ships `/etc/palm/services/installer` and
`/etc/palm/services/getty-live`. palm-init has no disable mechanism and a
package cannot remove another package's files (palm runs no scripts), so
`distro/live/build.sh` **deletes** palmframe-base's `palm-login` and
`getty-ttyS0` service files from the live root after palm installs it. On the
live system `palm verify` would therefore report those two files missing;
nothing else is touched. (A `disabled = true` key or a mask directory in
palm-init would let the package do it instead — a nice-to-have for
`distro/init`, not needed.)

- `installer`: `/usr/lib/palm-live/installer-session`, root, restart always.
  The script creates `/run/user/0` (0700), sets `XDG_RUNTIME_DIR`,
  `XDG_SESSION_TYPE=wayland`, `LANG` (C.UTF-8, or `/etc/locale.conf` if one
  exists), and execs `wm --drm --kiosk --exec installer`. Its output is
  `/var/log/installer.log`. Kernel switches: `palm.live.serial` (sleep, no
  session), `palm.live.exec=<cmd>` (run `<cmd>` instead of `installer`,
  e.g. `term` to debug). If the client is not installed it falls back to
  `term`.
- `getty-live`: `getty -n -l /usr/lib/palm-live/autologin -L 115200 ttyS0
  vt100`; the autologin script is `exec /bin/login -f root`, so it is a real
  login shell (reads `/etc/profile`, `/etc/profile.d/palm-live.sh` prints a
  hint about palm-install).
- `/etc/palm/live` exists only on the live system (marker, `repo = …`).

## For install_core / palm-install / the GUI

- **Repository on the medium**: `/usr/share/palm/repo/` flat — `PALMINDEX`,
  `PALMINDEX.sig`, every `.palm` of the build's repository (all 45, not only
  what palmframe needs). `palm --repo /usr/share/palm/repo` reads it (palm
  falls back to `<base>` when `<base>/x86_64/PALMINDEX` is absent); the key is
  palmframe-base's `/etc/palm/keys/palmframe.pub`. Checked in the guest:
  `palm --repo /usr/share/palm/repo --no-cache search tzdata` works offline.
- **Block devices in the guest** (`/sys/block`): `loop0`–`loop7`, `sr0` (the
  ISO on q35's AHCI CD), `vda` (the target, 16777216 sectors for 8G). When the
  ISO is written to a USB stick (tested as a raw virtio disk), it is a disk
  with an ISO 9660 signature — install_core's `has_iso9660` covers that.
- **limine** is packaged (`/usr/share/limine/BOOTX64.EFI`,
  `limine-bios.sys`) and installed on the live system, which is where
  `boot.odin`'s `limine_dir` fallback finds it. It is not in the default
  `palmframe` set; add it to the target's packages if you want the target to
  carry its own copy.
- **mkfs**: `mkfs.ext4` (mke2fs under that name; `/etc/mke2fs.conf` from the
  host) and `mkfs.fat` are real e2fsprogs/dosfstools binaries. busybox owns
  `mke2fs`, `mkfs.ext2`, `mkfs.vfat`, `mkdosfs`, `chattr`, `lsattr` as
  applets, so those names stay busybox's (palm refuses two owners of a path).
  e2fsprogs also carries `e2fsck`/`fsck.ext4`, `tune2fs`/`e2label`,
  `resize2fs`, `dumpe2fs`, and libext2fs, libe2p, libcom_err, libblkid,
  libuuid (whatever `ldd` lists beyond glibc).

## Japanese: available

`fonts-cjk` = the host's `NotoSansCJK-Regular.ttc` (19 MB raw, a collection
whose first face is Japanese; palmy loads `.ttc` and lists
`NotoSansCJK-Regular` first in `FALLBACK_CANDIDATES`). No subset: the host has
no fonttools or hb-subset. **It is installed on the live system, so the GUI
should list 日本語 as available** — the installer's first screen in QEMU
renders 日本語 and العربية correctly (`distro/build/live/shots/installer-first-screen.png`).

It is **not** in the default `palmframe` meta-package: every palmy process
loads its fallback faces, and 19 MB per process is a lot for a machine that
never shows a kanji. Suggestion for install_core / the GUI: when the chosen
language is `ja` (or `zh`/`ko` later), add `fonts-cjk` to `Plan.packages` so
the installed system can render its own UI language. The package is in the
repository on the medium, so this works offline.

## Packages added to `palmframe`

`tzdata` and `palm-locale` are now dependencies of the `palmframe`
meta-package (33 packages installed into the disk image instead of 31;
`make -C distro image` checked after the change).

- `tzdata` (version from pacman, e.g. `2026c`): every top-level entry of
  `/usr/share/zoneinfo` except `right/` and `posix/`; 240 KB compressed.
- `palm-locale`: every `distro/locale/<lang>/<domain>.msg` →
  `/usr/share/palm/locale/<lang>/<domain>.msg`, listed file by file by
  generate.sh (only `.msg` files ship). An empty `distro/locale` gives a
  package with just the directory.

## Makefile behaviour

- `palm-install` (`distro/installer/cli`) and `installer` (`apps/installer`)
  are built with `-collection:install=distro/installer` when their source
  directories exist. A failed build is reported (`warning: … did not build`)
  but **not fatal** (`-` prefix), because both were being written while
  everything else had to keep building; their recipes are skipped while the
  binary is missing. A stale binary from an earlier successful build would be
  packaged — the warning says so.
- `make iso` requires the `palm-install`, `installer` and `palmframe-live`
  packages in the repository and refuses otherwise (or use
  `LIVE_WITHOUT_INSTALLER=1` for a test ISO).
- `check-libs` now covers the installer binaries too.
- `clean` removes the ISO and `distro/build/live/{rootfs,iso}`.

## Verified (inside QEMU only; nothing touched a host device)

`distro/live/test-boot.py`, headless, blank scratch qcow2 in distro/build/live:

- **UEFI (OVMF), real build** (`make -C distro iso` with the other agents'
  installer and palm-install): limine menu with both entries
  (`shots/uefi-limine.png`), palm-init from the initramfs, root shell on
  ttyS0 in ~8 s, `/` is rootfs, services `installer` + `getty-live` + syslog
  (+ built-in network), no palm-login/getty-ttyS0, offline palm search of the
  medium's repository, mkfs.ext4/mkfs.fat/limine present, tzdata without
  right/posix, catalogues + CJK font, vda 8G + sr0,
  `wm --drm --kiosk --exec installer` running as root, and the installer's
  first screen (`shots/uefi-session.png` = `installer-first-screen.png`):
  the language list with all six languages rendered. `poweroff` ended QEMU.
- **BIOS (SeaBIOS), real build**: the same checks, all passed
  (`shots/bios-limine.png`, `shots/bios-session.png`).
- **Serial-only entry** (Down + Enter in limine, test ISO): `palm.live.serial`
  on the command line, root shell, no wm running.
- **Kiosk with term** (`LIVE_WITHOUT_INSTALLER=1`, before the installer
  existed): term fullscreen at a root prompt, UEFI and BIOS.
- **Hybrid USB**: the ISO attached as a raw virtio disk (a copy), no CD: both
  OVMF and SeaBIOS booted it to `palm-init: started installer`.

Not done: an actual install from the ISO through to booting the target disk
(that is the core/GUI agents' end-to-end), the gtk window path of
`run-qemu.sh --iso`, real hardware.

## Integration follow-up (2026-10-13)

- palm-login and getty-ttyS0 are now masked through
  `/etc/palm/services.off/` (palm-init, notes/init.md), shipped by
  palmframe-live; build.sh no longer deletes them.
- The installer binaries' Makefile rules are fatal again, and their recipes
  always built (no stale packaging).
- The end-to-end install from the ISO is `distro/live/test-install.py`
  (notes/integrate.md).
