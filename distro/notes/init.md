# palm-init and palmframe-base — notes for the other pieces

Owner of `distro/init/`, `distro/base/` and this file.

## What exists

- `distro/init/` — palm-init, PID 1, in Odin. `distro/init/build.sh` builds
  `distro/out/bin/palm-init`, **statically linked** (static glibc,
  `-extra-linker-flags:-static`). It does not need the dynamic loader or
  `/usr/lib/libc.so.6` to start. `build.sh --test` also runs the selftest.
- `distro/init/test-boot.sh` — boots it in QEMU (headless) and drives the
  serial console. Scenarios: `login`, `single`, `disk`, `all`.
- `distro/base/root/` — the files of the `palmframe-base` package.
- `distro/base/layout` — what a plain file tree in git cannot hold: the
  merged-/usr symlinks, directory modes, non-root owners, `etc/shadow` 0600.
- `distro/base/apply-layout.sh <rootdir>` — copies `root/` and applies
  `layout`. Run it under fakeroot in the same session as whatever archives
  the result.

## For the image builder / recipes

Install palm-init as `/usr/bin/palm-init` and make `/usr/bin/init` a symlink
to it (`/sbin` → `usr/bin`, so the kernel finds `/sbin/init`). The kernel
command line needs nothing special: `root=... ro` is fine, palm-init remounts
`/` read-write itself (tested on an ext4 root on virtio-blk mounted `ro`).

Merged /usr symlinks (also in `distro/base/layout`):

```
bin       -> usr/bin
sbin      -> usr/bin
lib       -> usr/lib
lib64     -> usr/lib
usr/sbin  -> bin
usr/lib64 -> lib
var/run   -> ../run
var/lock  -> ../run/lock
etc/mtab  -> ../proc/self/mounts
```

Owners that are not root: `home/palm` 1000:1000 (0700), `home/palm/.profile`
1000:1000, `var/lib/greeter` 900:900 (0750). `etc/shadow` is 0600. `tmp` and
`var/tmp` are 1777.

busybox applets: one symlink per `busybox --list` name in `/usr/bin`. The
services use `/sbin/getty`, `/sbin/syslogd`, and palm-init looks up `udhcpc`
in `PATH` (`/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`). udhcpc's script is
`/usr/share/udhcpc/default.script` (in base; busybox is configured with that
path) — it sets the address, default route and `/etc/resolv.conf`.

A `palmframe-base` PALMBUILD should ship `distro/base/root/` plus `layout`'s
symlinks/dirs; whether palm records symlinks and per-file owners is the
recipes' and palm's call — `layout` is the list to honour.

`/etc/palm/repositories` currently says `/var/lib/palm/repo/x86_64`. That is a
guess; the image builder should overwrite it with wherever it puts the
on-disk repository (or an http:// URL).

## Services shipped in base

| file | what |
| --- | --- |
| `getty-ttyS0` | `/sbin/getty -L 115200 ttyS0 vt100`, `tty = /dev/ttyS0` |
| `palm-login` | `/usr/bin/palm-login`, user root, restart always |
| `syslog` | `/sbin/syslogd -n -O /var/log/messages` |
| (built-in) `network` | `udhcpc -i eth0 -b -t 5 -T 2`, one-shot, only if eth0 and udhcpc exist |

No getty on tty1: the window manager owns the display; a text getty on the
same VT would fight it. `after = network` on a service means "after udhcpc's
foreground run" (lease obtained, or backgrounded after 5 tries).

## For palm-login (distro/login)

- palm-init exports `PALM_AUTOLOGIN=<user>` to every service when the kernel
  command line has `palm.autologin=<user>` (verified in QEMU). palm-login may
  also read `/proc/cmdline` itself; both agree.
- palm-login runs as root with `HOME=/root USER=root PATH=... TERM=linux`; its
  stdout/stderr go to `/var/log/palm-login.log`, stdin is `/dev/null`. It is
  a session leader (palm-init calls `setsid()` for every service) but has no
  controlling tty. If it needs a VT for the wm, it opens one itself.
- On shutdown palm-init sends SIGTERM to the service's process group (so to
  the wm and greeter too if they stayed in it), waits 3 s, then SIGKILLs
  everything.
- `/dev/dri/*` is root:video 0660, `/dev/input/event*` root:input 0660 — at
  boot and on hotplug (verified with a QMP-hot-plugged USB keyboard).
- `/run` is a fresh tmpfs (0755) each boot; `/run/user/<uid>` is palm-login's
  to create.

## Behaviour worth knowing

- `kill -HUP 1` re-reads `/etc/palm/services` and starts services that are
  new. It does not stop removed ones or restart changed ones.
- A service whose binary is missing or whose user is unknown goes through the
  same restart backoff (1 s doubling to 30 s) instead of being dropped, so
  installing the package later makes it start.
- An unknown key in a service file is an error: the service is not started
  and the console says which line.
- `palm.single` gives a root shell on the console's real tty (from
  `/sys/class/tty/console/active`, so job control works) and starts nothing
  else.
- busybox `poweroff` / `reboot` / `halt` work (SIGUSR2 / SIGTERM / SIGUSR1).
  ctrl-alt-del is SIGINT → reboot.

## Changed by the installer integration (2026-10-13)

- **Masks** (`service.odin`): a service is not started while
  `/etc/palm/services.off/<name>` exists (also for the built-in `network`).
  palmframe-live ships `services.off/palm-login` and `services.off/getty-ttyS0`
  instead of the live build deleting palmframe-base's service files, so
  `palm verify` on the live system no longer reports them missing. Logged as
  `service X is masked by ...`. Selftest: 3 mask checks.
