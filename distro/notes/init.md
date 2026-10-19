# palm-init and palmy-base — notes for the other pieces

Owner of `distro/init/`, `distro/base/`, `distro/image/`, the palm-init and
palmy-base recipes, and this file.

## What exists

- `distro/init/` — palm-init, PID 1, in Odin. `distro/init/build.sh` builds
  `distro/out/bin/palm-init`, **statically linked** (static glibc,
  `-extra-linker-flags:-static`). It does not need the dynamic loader or
  `/usr/lib/libc.so.6` to start. `build.sh --test` also runs the selftest.
- `distro/init/test-boot.sh` — boots it in QEMU (headless) and drives the
  serial console. Scenarios: `login`, `single`, `disk`, `grow`, `all`.
  `KERNEL=<bzImage>` boots another kernel (one with zram, for instance).
- `distro/base/root/` — the files of the `palmy-base` package.
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

A `palmy-base` PALMBUILD should ship `distro/base/root/` plus `layout`'s
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

- `kill -HUP 1` re-reads `/etc/palm/services`: new files start; a changed
  definition (cmd, user, restart, after, tty, env — not comments or spacing)
  stops the service (SIGTERM to its group, SIGKILL after 3 s) and starts it
  with the new one; a removed or newly masked file stops it; a file that no
  longer parses leaves it running as it was. A `restart = never` service that
  has already finished takes the new definition without running again. The
  built-in `network` is replaced only by a file of that name. The console
  says `SIGHUP: N new, N changed, N removed, N unchanged`. In `palm.single`
  SIGHUP does nothing.
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
  palmy-live ships `services.off/palm-login` and `services.off/getty-ttyS0`
  instead of the live build deleting palmy-base's service files, so
  `palm verify` on the live system no longer reports them missing. Logged as
  `service X is masked by ...`. Selftest: 3 mask checks.

## Boot order, filesystems, swap, hooks (2026-10-19)

The order palm-init brings the machine up in (main.odin):

```
/proc /sys /dev /dev/pts /dev/shm /run /tmp      (/ may still be read-only)
fsck /       only if the kernel mounted it ro and its fstab pass is not 0
remount /    with its fstab options (rw unless they say ro)
grow-root    only while /etc/palm/grow-root exists
early hooks  /usr/lib/palm-init/early.d + /etc/palm/early.d, in name order
coldplug     device permissions
fstab        every other line: fsck (pass != 0), mount; swap lines swapon
zram         from /etc/palm/zram
/var, /etc/machine-id, hostname, lo
services
```

Shutdown: services stopped, then swapoff of everything in `/proc/swaps`, every
real filesystem unmounted in reverse order (remounted read-only if busy), `/`
read-only, `reboot(2)`.

### /etc/fstab (fstab.odin, probe.odin)

`mount -a` + `swapon -a`, in Odin. Devices: a path, `UUID=`, `LABEL=`
(ext2/3/4, FAT and swap superblocks are read), `PARTUUID=`, `PARTLABEL=`
(from the partition's uevent). A missing device is waited for, 3 s per boot in
all. Options: kernel flags become mount flags, `noauto nofail user _netdev
x-* comment= pri= sw defaults` are fstab's, the rest is the filesystem's data
string. Lines for the mount points palm-init mounts itself are skipped.

fsck: `fsck.<type> -p`, or `e2fsck` / `fsck.fat` for the ext and FAT
families. Exit 2/3 on `/` reboots; 4+ leaves `/` read-only (and a non-root
filesystem unmounted) with a console line. No checker: one console line, no
check. The disk image installs e2fsprogs and dosfstools so both run; on the
console fsck.fat prints three harmless lines about codepage 850 (glibc has
no gconv modules in the image).

The ESP line the image uses (the installer's is the same minus the last three
options): `LABEL=PALMESP /boot/efi vfat
rw,relatime,fmask=0077,dmask=0077,shortname=mixed,utf8,errors=remount-ro 0 2`.

### zram (zram.odin, base/root/etc/palm/zram)

`size = 50%` of MemTotal, `max = 4G`, `algorithm = zstd`, `priority = 100`;
`size = 0` turns it off. palm-init writes `comp_algorithm` and `disksize`,
puts a mkswap header on `/dev/zram0`, `swapon`s it and sets
`vm.page-cluster = 0`. **The shipped kernel has no `CONFIG_ZRAM`**: palm-init
says `zram: this kernel has no zram; no swap`. Verified with a kernel built
from the same config plus

```
CONFIG_ZSMALLOC=y  CONFIG_ZRAM=y  CONFIG_ZRAM_BACKEND_ZSTD=y
CONFIG_ZRAM_BACKEND_LZ4=y  CONFIG_ZRAM_DEF_COMP_ZSTD=y  CONFIG_CRYPTO_ZSTD=y
```

(`zram: 484 MiB of swap on /dev/zram0 (zstd, priority 100)` with 1 GiB of
RAM; `/proc/swaps` showed it at priority 100 above a swap file at 5).

### grow-root (growroot.odin)

While `/etc/palm/grow-root` exists: find `/`'s partition from `stat("/")`
and sysfs, read the disk's GPT (header and entry CRC32s checked), require `/`
to be the last partition, move the backup GPT to the disk's end, extend the
entry to the last whole MiB, rewrite both headers and the protective MBR's
size (backup first), `BLKPG_RESIZE_PARTITION`, then `EXT4_IOC_RESIZE_FS` (what
resize2fs does online). Then the file is deleted. A step with nothing to do
is skipped, so `touch /etc/palm/grow-root` and a reboot after enlarging the
disk again works too. A non-GPT disk, a root that is not last, or a non-ext4
root: one console line, file deleted.

### Early hooks (hooks.odin) — the interface for kernel modules

For the kernel (or anyone else) that needs something done before devices,
filesystems and services:

- Install an executable as `/usr/lib/palm-init/early.d/<NN-name>` (the
  palm-init package owns the directory). Suggested: `10-modules`.
- It runs once per boot, in byte order of names merged with
  `/etc/palm/early.d/` (a name there replaces the packaged hook; a
  non-executable file there turns it off), to completion with a 30 s limit.
- Environment: root, cwd `/`, no arguments, stdin `/dev/null`, stdout and
  stderr on the console (keep it quiet on success), `PATH HOME=/root
  TERM=linux PALM_INIT_STAGE=early` and the locale.
- At that point: `/proc /sys /dev /run /tmp` are mounted, `/` is writable,
  the hotplug socket is open (so devices a module creates get their
  permissions), and nothing else has happened — no other fstab mount, no
  swap (so zram can be a module), no network, no service.
- A `10-modules` hook would load `/etc/modules-load.d/*.conf` and
  `/usr/lib/modules-load.d/*.conf`, then coldplug: `modprobe -abq` every
  `/sys/devices/**/modalias`. Devices that appear later are palm-init's: it
  runs `modprobe -b -q <MODALIAS>` for every `add` uevent that has one, when
  `/proc/modules` exists and `modprobe` is in PATH (busybox's modprobe-small,
  which is how busybox is configured, accepts `-b -q`, as kmod's does).

### The image (distro/image/build.sh)

- `palm add palmy palmy-demo e2fsprogs dosfstools` (PACKAGES=).
- Kernel command line `ro` (was `rw`) so `/` can be checked.
- fstab gets `LABEL=palmy /` and `LABEL=PALMESP /boot/efi`; the root
  gets `/etc/palm/grow-root`; `/etc/localtime` and `/etc/timezone` from
  `TIMEZONE=` (UTC; `host` = the build host's zone); no `/etc/machine-id`.
  `palm verify` reports the fstab edit as `modified (config)`, which is not
  an error.
- `distro/image/test-boot.py` enlarges its copy to 6 GiB first (`--grow`)
  and checks fsck, grow-root, df, `/boot/efi`, the time zone, the machine id
  and zram (or the reason there is none).

### Base additions

`/etc/palm/zram`, `/etc/timezone` (UTC), short `/etc/protocols` and
`/etc/services`, `/etc/palm/early.d/`. `/etc/machine-id` is not shipped:
palm-init writes it.

### CONTRACT changes

The palm-init section of `CONTRACT.md` now lists the fstab, zram,
machine-id, early-hook and grow-root behaviour, SIGHUP's meaning and the
longer shutdown. Nothing that was there before changed meaning, except that
`/` is remounted with its fstab options rather than plainly read-write (an
fstab without a `/` line gives the old behaviour).

### Verified (2026-10-19)

- `distro/init/build.sh --test`: 111 checks pass (48 before).
- `distro/init/test-boot.sh all`: 78 checks pass with the shipped kernel (41
  before); `KERNEL=distro/build/kz/bzImage-zram` (the config above): 79. The
  `grow` scenario builds a 160 MiB GPT disk (ESP FAT16 `TESTESP` + ext4
  `palmroot`, last), enlarges it to 1 GiB and boots `root=/dev/vda2 ro`:
  `grow-root: vda2 now ends at 1023 MiB (was 159 MiB)`, `/ grown from 128 MiB
  to 992 MiB`, ESP mounted by label, a swap file made in the guest and on at
  priority 5 on the next boot, swap off and `/boot/efi` unmounted at
  poweroff; on the host `sfdisk --verify` says `No errors detected` with the
  backup GPT at the end, and `e2fsck -fn` is clean.
- The disk image (palm-init and palmy-base rebuilt into a copy of the
  repository, `distro/image/build.sh`, `python3 -I distro/image/test-boot.py`):
  27 checks pass. The 1223 MiB image enlarged to 6 GiB booted through OVMF and
  limine: `checking / (/dev/vda2)` (`palmy: clean`), `grow-root: vda2 now
  ends at 6143 MiB (was 1222 MiB)`, `/ grown from 1092 MiB to 6013 MiB`, df
  5887 MiB for `/`, `/dev/vda1 /boot/efi vfat`, `/etc/localtime ->
  ../usr/share/zoneinfo/UTC`, greeter, login, term, launcher, `palm verify`
  (fstab and resolv.conf `modified (config)`), `palm add shop` over http,
  poweroff. Afterwards on the host: `sfdisk --verify` clean, `e2fsck -fn` and
  `fsck.fat -n` on the partitions clean.
