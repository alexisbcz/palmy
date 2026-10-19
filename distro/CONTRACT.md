# Palmy distribution — the contract

Every piece of the distribution is built by a different hand. This file is the
set of interfaces they agree on. Change it only by saying so in
`distro/notes/<you>.md`; anything here is what the other pieces were built
against.

## Shape

An Alpine-inspired distribution: a small static busybox userland, an init and a
package manager written in Odin, glibc (taken from the build host) because
every palmy binary links it, and the palmy window manager and applications on
top. It boots in QEMU from a real disk image.

```
Linux 6.18 LTS (distro/kernel: storage built in, no initramfs; drivers are
                modules loaded by palm-modules; notes/kernel.md)
└─ /sbin/init          palm-init        (distro/init, Odin)
   ├─ coldplug + hotplug device permissions
   ├─ services from /etc/palm/services/
   │  ├─ getty on ttyS0 (busybox getty/login)      serial console shell
   │  └─ palm-login    (distro/login, Odin)        greetd-protocol daemon
   │       ├─ greeter session:  wm --drm --kiosk --exec greeter   (as user greeter)
   │       └─ user session:     wm --drm                          (as the user)
   └─ /sbin/palm       the package manager      (distro/palm, Odin)
```

## Filesystem layout

Merged /usr, like Arch: `/bin -> usr/bin`, `/sbin -> usr/bin`,
`/lib -> usr/lib`, `/lib64 -> usr/lib`, `/usr/sbin -> bin`. glibc's loader is
therefore found at `/lib64/ld-linux-x86-64.so.2`.

| path | what |
| --- | --- |
| `/etc/palm/repositories` | one repository per line: an `https://` or `http://` URL or an absolute path; further URLs on a line are mirrors of it |
| `/etc/palm/keys/*.pub` | trusted ed25519 public keys (raw 32 bytes, hex encoded, one line) |
| `/etc/palm/world` | the packages the user asked for, one per line (apk's world) |
| `/etc/palm/services/<name>` | service definitions for palm-init |
| `/usr/lib/palm/db/installed` | the installed-package database (palm owns the format) |
| `/var/cache/palm/` | downloaded packages and indexes |
| `/var/log/<service>.log` | each service's stdout+stderr |
| `/usr/share/fonts/` | TTF/OTF fonts; palmy scans this |
| `/run/user/<uid>` | XDG_RUNTIME_DIR, 0700, created by palm-login |

## palm-init (PID 1)

- Mounts `/proc`, `/sys`, `/dev` (devtmpfs), `/dev/pts`, `/dev/shm`, `/run`,
  `/tmp`; checks `/` (`fsck.<type> -p`, when `/` is read-only and its fstab
  pass is not 0) and remounts it with its `/etc/fstab` options (read-write
  unless they say `ro`); mounts the rest of `/etc/fstab` and turns on its swap
  lines (`mount -a` and `swapon -a`, devices by path, `UUID=`, `LABEL=`,
  `PARTUUID=`, `PARTLABEL=`); sets up zram swap from `/etc/palm/zram`; writes
  `/etc/machine-id` when it is missing; sets the hostname from
  `/etc/hostname`; brings up `lo`, and `eth0` with DHCP via `udhcpc` when
  present.
- **Early hooks** (the interface for loading kernel modules and anything
  else that must happen before devices are looked at): every executable in
  `/usr/lib/palm-init/early.d/` (packages) and `/etc/palm/early.d/` (the
  administrator; a name here replaces the packaged one, and a non-executable
  file of that name disables it) runs once per boot, in name order, to
  completion (30 s limit), as root with stdout/stderr on the console and
  `PALM_INIT_STAGE=early`. They run after the pseudo-filesystems are mounted
  and `/` is read-write, and before the device-permission walk, the other
  fstab mounts, swap, the network and every service, also in `palm.single`.
  On hotplug, a uevent's `MODALIAS` is passed to `modprobe -b -q` when
  `/proc/modules` exists and `modprobe` is in PATH.
- `/etc/palm/grow-root`: while it exists, palm-init grows `/`'s GPT
  partition to its disk's end and the ext4 on it online, then deletes it.
  The disk image ships it; installed disks do not need it.
- Device permissions, at boot (walk) and on hotplug (netlink uevents):
  `/dev/dri/*` root:video 0660, `/dev/input/event*` root:input 0660,
  `/dev/snd/*` root:audio 0660, `/dev/tty[0-9]*` root:tty 0620.
- Signals follow the busybox convention so busybox's `reboot`, `poweroff` and
  `halt` work unchanged: **SIGTERM → reboot, SIGUSR2 → poweroff,
  SIGUSR1 → halt, SIGINT (ctrl-alt-del) → reboot, SIGHUP → re-read
  `/etc/palm/services` (start new, restart changed, stop removed or masked).**
  Shutdown is: stop services (SIGTERM, wait 3 s, SIGKILL), sync, swapoff,
  unmount every real filesystem (read-only if busy), remount `/` read-only,
  `reboot(2)`.
- Reaps every orphan.
- Service file format (`/etc/palm/services/<name>`), one `key = value` per line,
  `#` comments:

  ```
  cmd     = /usr/bin/palm-login          # required; split on spaces, no shell
  user    = root                         # default root
  restart = always                       # always | never   (default always)
  after   = network                      # optional, another service name
  tty     = /dev/ttyS0                   # optional: stdin/out/err on that tty, setsid + TIOCSCTTY
  env     = KEY=value                    # repeatable
  ```
- Kernel command line: `palm.single` starts `/bin/sh` on the console instead of
  services; `palm.autologin=<user>` is passed through to palm-login (see below).

## Users

| user | uid | groups | password |
| --- | --- | --- | --- |
| root | 0 | root | `palm` |
| palm | 1000 | palm, wheel, video, input, audio | `palm` |
| greeter | 900 | greeter, video, input | locked (`!`) |

Groups: root 0, wheel 10, tty 5, audio 63, video 39, input 97, greeter 900,
palm 1000. `/etc/shadow` holds SHA-512 crypt (`$6$`) hashes.

## palm-login and the session

palm-login speaks the **greetd IPC protocol** (`greetd-ipc(7)`: native-endian
u32 length, then a JSON object) on `/run/palm-login.sock`, so the existing
`apps/greeter` works against it unchanged. It sets `GREETD_SOCK` to that path
for the greeter session.

1. palm-login starts the greeter session as user `greeter`:
   `wm --drm --kiosk --exec greeter`, with `XDG_RUNTIME_DIR=/run/user/900`.
2. The greeter authenticates (`create_session`, `post_auth_message_response`)
   — palm-login checks the password against `/etc/shadow` itself (SHA-512
   crypt implemented in Odin) — then `start_session{cmd, env}`.
3. When the greeter session exits, palm-login starts `cmd` (default `["wm",
   "--drm"]`) as that user: `setgid`, `initgroups`, `setuid`, in `$HOME`, with
   `HOME USER LOGNAME SHELL PATH XDG_RUNTIME_DIR XDG_SESSION_TYPE=wayland
   XDG_CURRENT_DESKTOP=palmy` set.
4. When the user session exits, back to 1.

`palm.autologin=<user>` on the kernel command line skips 1–2.
Greeter power actions run `/sbin/poweroff` / `/sbin/reboot` (busybox, which
signal PID 1 as above).

The running session talks to palm-login on a second socket,
`/run/palm-login.session.sock` (same framing), named to the session in
`PALM_SESSION_SOCK`. It is the session user's (0600) while their session
runs and root's otherwise, and every request is checked with SO_PEERCRED:
the peer must have the uid palm-login started the session as and be the
session leader or one of its descendants. Two requests only:

- `unlock{password}` — the wm's lock screen; palm-login checks the password
  (rate limited on `/run/faillock/<uid>`, shared with doas and passwd).
- `power{action: "poweroff"|"reboot", dry_run?, password?}` — refused while
  the session's VT is not in front; while someone else is logged in (a live
  utmp login on another line) it needs the password of a member of `wheel`;
  otherwise no password. On success palm-login ends the session as for any
  logout, then runs `/sbin/poweroff` / `/sbin/reboot`.

The policy and its reasons are in `distro/notes/login.md`.

## The window manager on bare metal

`apps/wm` gains, without losing the nested mode it has today:

- `--drm`: the bare-metal backend — KMS on `/dev/dri/card0` (dumb buffers,
  page flip), evdev input from `/dev/input/event*`, its own XKB keymap. When
  logind is not running (Palmy has none) it opens the devices directly; it
  needs only membership of `video` and `input`. Selected automatically when
  neither `WAYLAND_DISPLAY` nor `DISPLAY` is set and `/dev/dri/card0` exists.
- `--exec <cmd>`: spawn that client once the Wayland socket is listening, with
  `WAYLAND_DISPLAY` set. Repeatable.
- `--kiosk`: no bar, no workspace UI, the first client fullscreen, and exit
  when the first `--exec` client exits.
- In QEMU the pointer is a **virtio-tablet** (absolute `EV_ABS` X/Y, scaled to
  the output) and the keyboard is virtio-keyboard; both must work.
- The default terminal binding launches `term` (apps/term), not `foot`.

## palm, the package manager

Alpine's apk is the model: small, fast, a world file, signed indexes, `--root`
for building images from the host.

```
palm add <pkg>...         install (and record in world)
palm del <pkg>...         remove (and drop from world), and orphans
palm update               fetch and verify every repository index
palm upgrade              upgrade everything to the newest available
palm search <text>        search names and descriptions
palm info <pkg>           details; -L lists files
palm list [--installed|--upgradable|--available]
palm verify               check installed files against recorded sha256
palm fix [<pkg>]          reinstall broken/missing files
palm build <dir> -o <outdir>          build a package from <dir>/PALMBUILD
palm index <outdir> --key <secret>    write and sign <outdir>/PALMINDEX
palm keygen <name>                    write <name>.sec and <name>.pub
global: --root <dir>  --initdb  --repo <url|path> (repeatable, overrides repositories)
        --keys-dir <dir>  --allow-untrusted  --no-cache  --json  --yes  --dry-run
```

- A package is `<name>-<ver>-r<rel>.palm`: a gzip-compressed ustar archive
  whose first member is `.PKGINFO` (`key = value` lines: `pkgname`, `pkgver`,
  `pkgdesc`, `arch`, `size`, `license`, `depend` (repeatable), `provides`,
  `install_user`), followed by the files, with modes and **owner recorded as
  root unless the recipe says otherwise** (so no fakeroot is needed to build).
- `PALMINDEX` is a text index of every package (name, version, deps, size,
  sha256 of the `.palm`) plus a detached ed25519 signature `PALMINDEX.sig`.
  Package integrity is the index's sha256; the index's integrity is the
  signature.
- HTTP repositories are plain `http://` — the signature is what makes that
  safe, exactly as with apk.
- `--root <dir> --initdb` creates the database in an empty directory, which is
  how the image is assembled from the host without root: palm writes files
  with the recorded owner when running as root and as the invoking user
  otherwise, and the image builder runs it under `fakeroot`.

## Build outputs

Everything is under `distro/out/` (git-ignored); sources downloaded into
`distro/build/` (git-ignored).

| output | built by |
| --- | --- |
| `distro/out/bzImage`, `kernel.config`, `kernel.release`, `modules/<release>/` | `distro/kernel/build.sh` |
| `distro/out/busybox` | `distro/busybox/build.sh` |
| `distro/out/bin/<name>` | Odin binaries |
| `distro/out/repo/x86_64/*.palm`, `PALMINDEX`, `PALMINDEX.sig` | `distro/recipes` |
| `distro/out/palmy.img` | the bootable disk: GPT, ESP with limine, ext4 root |

Odin binaries are built with
`odin build <dir> -o:speed -collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn`
from the repository root.

## QEMU

`qemu-system-x86_64` on this host is a rootless wrapper in `~/.local/bin`
(KVM works; display backends `gtk`, `sdl`, `none`). The standard machine:

```
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -smp 4 \
  -device virtio-vga -device virtio-keyboard-pci -device virtio-tablet-pci \
  -nic user,model=virtio-net-pci -serial mon:stdio
```

Headless verification uses `-display none -qmp unix:<sock>,server,nowait` and
the QMP `screendump` command with `"format": "png"`; input can be injected with
QMP `input-send-event`. Read the PNG to see what the machine shows.

## Rules for everyone building this

- **Never run the window manager's DRM or seat backends on the host.** Bare
  metal means inside QEMU. The host is the user's live desktop.
- No `sudo` (it needs a password). Rootless tools only; `fakeroot` exists.
- Do not `git commit`; the tree is shared and is committed at the end.
- Stay inside the directories you own. If you need something changed elsewhere,
  write it in `distro/notes/<your-name>.md`.
