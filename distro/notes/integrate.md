# Integration — from the pieces to a bootable Palmframe

Owner: distro/recipes/, distro/image/, distro/Makefile, distro/run-qemu.sh,
this file (and the one `distro` target in the root Makefile).

## Use it

```
make distro                      # = make -C distro: kernel/busybox if missing,
                                 #   Odin binaries, recipes, packages, signed
                                 #   repository, distro/out/palmframe.img
make -C distro run               # boot it in a QEMU window (UEFI)
distro/run-qemu.sh --serial      # same, with the serial getty on this terminal
make -C distro serve             # repository on :8080 for the guest's palm update
make -C distro test              # headless boot test with screenshots
make -C distro check-libs        # every shipped binary links only glibc
```

Log in as `palm` / `palm` (greeter) or `root` / `palm` (serial getty).
In the session: SUPER+Return is term, SUPER+D the launcher, SUPER+SHIFT+E
logs out (back to the greeter).

## What is built, in order

1. `distro/out/bzImage`, `distro/out/busybox`: only when missing.
2. Odin binaries into `distro/out/bin/`: palm, palm-init (static), palm-login,
   wm, and every application a recipe names (via `distro/apps/build.sh`).
   Rebuilt when their sources (or palmy/kit/shadcn) change.
3. `distro/build/keys/palmframe.{sec,pub}`: `palm keygen`, once per checkout.
4. `distro/recipes/generate.sh` rewrites the recipes whose contents live
   elsewhere (see below), then `palm build` every recipe into
   `distro/out/repo/x86_64/`, then `palm index --key` signs it.
5. `distro/image/build.sh`: under one fakeroot session,
   `palm --root distro/out/rootfs --initdb --repo distro/out/repo/x86_64
   --keys-dir distro/build/keys add palmframe`, then `mkfs.ext4 -d`. Then a
   GPT image: partition 1 a 128 MiB FAT ESP (limine BOOTX64.EFI,
   limine-bios.sys, `/boot/limine/limine.conf`, a copy of `/boot/vmlinuz`),
   partition 2 the ext4 root (`root=/dev/vda2`), partition 3 a 1 MiB BIOS
   boot partition (physically first) for `limine bios-install`. Rootless:
   truncate, sfdisk on the file, mtools, dd.

The whole package + image step takes ~5 s; the image is 1.2 GB sparse
(84 MB on disk).

## Packages (36 in the repository, 31 installed by `palmframe`)

| package | from | notes |
| --- | --- | --- |
| palmframe-base | generated from distro/base/root + distro/base/layout | merged-/usr symlinks, /etc, users, services, XDG dirs in /home/palm, the repository's public key in /etc/palm/keys |
| linux | hand-written | /boot/vmlinuz, /boot/config |
| busybox | generated from `busybox --list` | binary + one symlink per applet, minus `chat` (clashes with the chat app) |
| glibc | generated, host files | libc.so.6, libm.so.6, ld-linux-x86-64.so.2 — the complete `ldd` set (`make check-libs`) |
| libxkbcommon, xkeyboard-config | generated, host files | versions from pacman |
| palm-init | hand-written | + /usr/bin/init -> palm-init |
| palm | hand-written | + apps/palm (palm-apps) as /usr/lib/palm/palm-surface |
| palm-login, greeter, palmy-wm | hand-written | |
| fonts, fonts-emoji | generated from distro/apps/fonts.list | `fonts-emoji` is not in the default set |
| term launcher files editor notes calc sysmon image docs sheets slides calendar reader photoshop maps money torrent | generated from distro/apps/default.list | binary + .desktop |
| prose | generated | docs depends on it (runs it as a subprocess) |
| shop track pickdemo emoji | generated (EXTRA_APPS) | in the repository, not installed: what `palm add` has to choose from |
| palmframe | generated | the meta-package |

Every package depends (directly or through glibc) on palmframe-base, so palm
installs it first and later owners resolve by name against its /etc/passwd.

## Verified (all inside QEMU, headless; screenshots in distro/out/shots/)

`make -C distro test` (distro/image/test-boot.py), last run: **all passed**.

- UEFI (OVMF) → limine → kernel from the ESP → ext4 root on /dev/vda2 rw →
  palm-init in ~4.6 s; palm-login, getty, syslog, network started.
- 01-greeter.png: the greeter fullscreen, running as `greeter` inside
  `wm --drm --kiosk`.
- `palm` typed through QMP + Enter → `wm --drm` as palm. 02-desktop.png.
- SUPER+Return → term as palm; typed `uname -a; id; palm list --installed |
  head -8; palm verify | tail -1` runs in it (uid 1000, groups wheel video
  audio input palm; "OK: 31 packages verified"). 03-term.png.
- SUPER+D → launcher listing the 16 shipped .desktop entries. 04-launcher.png.
- Serial root shell: `palm list --installed` = 31 packages; `palm verify`
  exit 0 (only `/etc/resolv.conf: modified (config)`, written by udhcpc);
  `palm update` from http://10.0.2.2:8080/x86_64 ("36 packages, signed by
  palmframe.pub"); `palm add --yes shop` downloads and installs it;
  verify still clean.
- `poweroff` → "palm-init: powering off", QEMU exits.
- Also booted: `run-qemu.sh --bios` (SeaBIOS → limine BIOS stages) and
  `--direct` (-kernel/-append) both reach palm-init and the getty.
- In the image (debugfs): /etc/shadow 0600 root, /home/palm 0700 1000:1000,
  /var/lib/greeter 0750 900:900.

## Small changes outside my directories

- `distro/base/root/etc/palm/repositories`: was the guess
  `/var/lib/palm/repo/x86_64`; now `http://10.0.2.2:8080/x86_64` (the host's
  `make -C distro serve` as QEMU user networking sees it).
- `distro/base/layout`: added `home/palm/{.config,.cache,.local,.local/share,
  .local/state}` owned 1000:1000 — apps/notes needs ~/.local/share to exist
  (distro/notes/apps.md).
- Root `Makefile`: a `distro` target delegating to `distro/Makefile`.

## Known gaps

- The kernel on the ESP is a copy made at image time. `palm upgrade linux`
  updates /boot/vmlinuz on the root, not the ESP (limine cannot read ext4,
  and the ESP is not mounted). A later fix: mount the ESP and have the linux
  package (or a post-upgrade step — palm has no hooks by design) copy it.
- `su`/`passwd` do not work for palm: busybox is not setuid. Package
  management is done as root on the serial console.
- The gtk-window path of run-qemu.sh (`make -C distro run`) was not opened
  during testing (headless only); it is the same machine with `-display gtk`.
- glibc, libxkbcommon and xkeyboard-config are taken from the build host
  (Arch), not built.
- No ESP entry in /etc/fstab; no swap; root fs is grown to installed size +
  1 GiB (ROOT_EXTRA_MIB), no resize-on-first-boot.
- palm itself, palm-init, palm-login, wm gaps are in their own notes.

## The installer, end to end (2026-10-13)

```
make -C distro                   # from scratch (kernel/busybox kept): 46 packages, image
make -C distro iso               # distro/out/palmframe-live.iso
make -C distro test-installer    # palm-install --selftest + installer --selftest (no disks)
make -C distro test-install      # iso, then distro/live/test-install.py (QEMU only)
python3 -I distro/live/test-install.py [--only gui|cli]
```

`distro/live/test-install.py` does what a person does, over QMP keys, with a
screendump per step in `distro/out/shots/install-NN-<step>.png`; scratch
disks and serial transcripts in `distro/build/integrate/qemu/`:

- **GUI** — live ISO under OVMF + blank 8 GiB virtio disk: Arabic (RTL shot),
  Français (UI French), keyboard fr followed live (physical `q w e r t y`
  types `azerty` in the test field), Europe/Paris, `/dev/vda` erase
  confirmed, Ada Lovelace / ada / analytical / palmframe typed on AZERTY,
  install (≈4 s from the in-RAM repository), Done, Restart. Then the disk
  alone with the same OVMF variable store: OVMF prints
  `BdsDxe: starting Boot0009 "Palmframe" from HD(1,GPT,...)/\EFI\palmframe\BOOTX64.EFI`,
  BootCurrent = 0009 = first in BootOrder, limine, palm-init; the serial
  getty says `analytical login:` and root takes the user's password;
  `date` CEST, LANG fr_FR, layout fr, localtime -> Europe/Paris; ada uid
  1000 in wheel/audio/video/input; `palm verify` exit 0 (only soft config
  lines); `palm list --installed` 33 packages, no palmframe-demo;
  `/dev/root` 7.3G (vda2 = 15724544 of 16777216 sectors); /home holds only
  `ada`; the greeter French with the Paris clock and "Ada Lovelace · ada";
  `palmframe` typed on AZERTY logs ada in to `wm --drm`; in term physical
  `q w e r t y` gives `azerty`, `date` says CEST, `hostname` analytical.
- **CLI** — a second live boot with two blank disks, from the serial root
  shell (busybox sh has no `<(...)`, so the password comes on stdin):
  `echo gracehopper | palm-install --disk /dev/vdb --language de_DE --keyboard de --timezone America/New_York --hostname cli-test --user grace --full-name 'Grace Hopper' --password-file - --yes`
  exits 0 in ~1 s. vdb booted alone (the live machine's OVMF vars copied
  beside it): the Palmframe entry starts, `cli-test login:`, LANG de_DE,
  layout de, EDT, verify clean, the greeter in German with New York time,
  grace logs in, term types `qwertz` for physical `q w e r t y`.

Last full run: **all passed** (`distro/build/integrate/full-run.log`).

### Changes made for it

- **/etc/skel and palmframe-demo** (requests in notes/installer-core.md):
  palmframe-base no longer owns `/home/palm`; it ships `/etc/skel` (.profile
  and the XDG dirs). A new hand-written package `palmframe-demo` makes
  `/home/palm` from the same skeleton; `distro/image/build.sh` installs
  `palmframe palmframe-demo`, the installer only `palmframe` (so `palm verify`
  on an installed disk is clean). `distro/base/apply-layout.sh` still creates
  /home/palm for the init/login boot tests.
- **palm**: retargeted symlinks under /etc are configuration (notes/palm.md).
- **palm-init**: `/etc/palm/services.off/<name>` masks a service
  (notes/init.md); palmframe-live masks palm-login and getty-ttyS0 instead of
  `distro/live/build.sh` deleting them. On the live system `palm verify` now
  reports only `/boot/vmlinuz: missing`, which build.sh leaves out of the
  initramfs on purpose (the kernel is on the ISO beside it);
  `distro/live/test-boot.py` checks exactly that.
- **Makefile**: palm-install and installer now build like every other
  binary (a failure stops make; no more stale-binary packaging); their
  recipes are no longer skipped. New targets `test-installer` and
  `test-install`.

### Seen, not fixed (other owners)

- **palmy**: a text field reached with Tab keeps its caret at 0, so tabbing
  into the prefilled "Computer name" (`palmframe`) and typing gives
  `analyticalpalmframe`. The first GUI run did exactly that; the test now
  presses End first. A person would hit it: palmy should put the caret at the
  end (or select all) when a field gains focus from the keyboard.
- **installer/core**: the progress line under the step name is the core's
  English message ("Mounting") in a French UI; the step names are
  translated.
- **wm**: the bar's date ("Tue 13 Oct") and the empty-desktop hint are
  English in a French session (wm has no catalogue).
- The ESP is still not mounted on the installed system (`df /boot/efi` shows
  the root), as noted by the core.
- Only keyboard input was used in QEMU, no pointer.
