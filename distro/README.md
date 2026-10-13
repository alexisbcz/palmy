# Palmframe, the distribution

A small Linux distribution built from this checkout: a kernel, a static
busybox userland, an init, a login daemon and a package manager written in
Odin, and the palmy window manager and applications on top. It builds into one
GPT disk image and boots in QEMU from UEFI firmware to a graphical login and a
working desktop.

It is modelled on Alpine. Like Alpine it is small, uses busybox for the
userland, and has a package manager with a world file and signed indexes.
Unlike Alpine it uses glibc rather than musl, because every palmy binary links
glibc, and that glibc is copied from the build host rather than built.

![limine's boot menu](docs/limine.png)

![The greeter, running as user greeter inside wm --drm --kiosk](docs/greeter.png)

![The desktop after logging in as palm: two term windows tiled by the window manager](docs/desktop.png)

These are QMP screendumps from the verification run described under
*What has been verified*, not mock-ups.

`CONTRACT.md` is the set of interfaces every piece was built against. This
file describes what was built; where the two disagree, the notes in `notes/`
say why.

## Building and running

```sh
make distro                  # from the repository root; same as make -C distro
distro/run-qemu.sh           # boot it in a QEMU window, UEFI firmware
```

`make distro` builds the kernel (Linux 6.18.56) and busybox (1.37) only if
`distro/out/bzImage` or `distro/out/busybox` is missing, because those take
minutes. Then it builds the Odin binaries, generates the recipes, builds 36
packages into `distro/out/repo/x86_64/`, signs the index, and assembles
`distro/out/palmframe.img`. Once the kernel exists, the rest takes about five
seconds. The image is 1.2 GB sparse and 84 MB on disk.

Nothing needs root. palm installs the system into an empty directory under
`fakeroot`, and `mkfs.ext4 -d` runs in the same fakeroot session, so the
owners palm records (root, palm 1000, greeter 900) and the 0600 `/etc/shadow`
are what land in the ext4 image even though every file on the host belongs to
the builder. The disk is partitioned with `sfdisk` on a plain file, with mtools
for the FAT partition. No loop device is used.

Other targets:

| command | |
| --- | --- |
| `make -C distro repo` | stop after the signed repository |
| `make -C distro image` | rebuild the image from the repository |
| `make -C distro run` | `distro/run-qemu.sh` |
| `make -C distro test` | the headless boot test (`image/test-boot.py`); screenshots in `distro/out/shots/` |
| `make -C distro serve` | serve the repository on :8080 for the guest's `palm update` |
| `make -C distro check-libs` | fail if a shipped binary needs anything but libc, libm and the loader |
| `make -C distro clean` | remove the packages, root and image; keeps the kernel, busybox and the signing key |

`distro/run-qemu.sh` options:

| flag | |
| --- | --- |
| (none) | a gtk window, OVMF firmware, serial console logged to `distro/out/serial.log` |
| `--serial` | the serial console on this terminal too (ctrl-a x quits) |
| `--headless` | no window; QMP on `distro/out/qmp.sock` |
| `--serial-socket P`, `--qmp-socket P` | for scripts |
| `--direct` | skip firmware and limine: `-kernel`/`-append` |
| `--bios` | SeaBIOS instead of OVMF |
| `-- <args>` | passed to QEMU unchanged |
| `IMG=<file>` | boot a different image, e.g. a copy |

The image is used in place: what the guest installs stays installed. Run
`make -C distro image` to start again from a clean image.

### Logging in

| user | password | |
| --- | --- | --- |
| `palm` | `palm` | the graphical login; uid 1000, groups palm, wheel, video, audio, input |
| `root` | `palm` | the serial console getty (`--serial`) |
| `greeter` | locked | runs the login screen, uid 900 |

In the session, SUPER+Return opens `term`, SUPER+D the launcher, and
SUPER+SHIFT+E ends the session and returns to the greeter. The rest of the key
bindings are in `apps/wm/config.odin`.

## The boot chain

```
OVMF (UEFI)                      or SeaBIOS with --bios
└─ limine 12.8                   partition 1, FAT: BOOTX64.EFI, limine.conf, a copy of the kernel
   └─ Linux 6.18.56              everything built in, no modules, no initramfs
      └─ /sbin/init = palm-init  root=/dev/vda2 rw (ext4, partition 2)
         ├─ network              udhcpc on eth0, a built-in one-shot service
         ├─ getty-ttyS0          busybox getty + login on the serial port
         ├─ syslog               busybox syslogd -> /var/log/messages
         └─ palm-login           the greetd-protocol login daemon
            ├─ wm --drm --kiosk --exec greeter     as greeter
            └─ wm --drm                             as the user who logged in
```

limine's menu has three entries: the normal boot, one that adds
`palm.autologin=palm`, and one that adds `palm.single` for a root shell with
no services. The disk also carries a 1 MiB BIOS boot partition, physically
first but numbered 3 so the root stays `/dev/vda2`, which is what lets the
same image boot under legacy BIOS.

## The pieces

| directory | what | language |
| --- | --- | --- |
| `kernel/` | the kernel config and build script | config, shell |
| `busybox/` | the static busybox build | shell |
| `init/` | palm-init, PID 1, statically linked | Odin |
| `login/` | palm-login, the login daemon | Odin |
| `palm/` | palm, the package manager | Odin |
| `base/` | `/etc`, the users, the service files, and `layout` (what git cannot hold: symlinks, owners, modes) | text |
| `apps/` | builds the applications; `default.list`, `fonts.list`, `.desktop` files, `apps.tsv` | shell, text |
| `recipes/` | one `PALMBUILD` per package, and `generate.sh` | text, shell |
| `image/` | `build.sh` assembles the disk; `test-boot.py` boots and checks it | shell, Python |
| `notes/` | each area's decisions, requests to other areas, and gaps | |

The window manager's bare-metal backend is in `apps/wm` (`bare.odin`,
`drm.odin`, `evdev.odin`, `xkbmap.odin`) and the greeter is `apps/greeter`.

### palm-init

PID 1. It remounts `/` read-write, mounts `/proc`, `/sys`, `/dev`, `/dev/pts`,
`/dev/shm`, `/run` and `/tmp`, sets the hostname, brings `lo` up, and runs
`udhcpc` on `eth0` as a built-in one-shot service called `network`. Device
groups and modes (`/dev/dri/*` video, `/dev/input/event*` input, `/dev/snd/*`
audio, ttys tty) are set by walking `/dev` at boot and again from netlink
uevents on hotplug. It reaps orphans.

Services are files in `/etc/palm/services/`, one `key = value` per line:

```
cmd     = /usr/bin/palm-login          # required; split on spaces, no shell
user    = root                         # default root
restart = always                       # always | never
after   = network                      # optional
tty     = /dev/ttyS0                   # optional: setsid + controlling tty
env     = KEY=value                    # repeatable
```

Each service's output goes to `/var/log/<name>.log`. A service that exits is
restarted after 1 s, doubling up to 30 s; a service whose binary is missing
keeps retrying, so installing its package later makes it start. `kill -HUP 1`
starts services newly added to the directory; it does not stop removed ones or
restart changed ones.

Signals follow busybox's convention so busybox's `reboot`, `poweroff` and
`halt` work unchanged: SIGTERM and SIGINT (ctrl-alt-del) reboot, SIGUSR2 powers
off, SIGUSR1 halts. Shutdown sends SIGTERM to every service, waits 3 s, sends
SIGKILL, syncs, remounts `/` read-only and calls `reboot(2)`.

It is statically linked so it does not depend on the loader to start, and
because a static glibc has no NSS it reads `/etc/passwd` and `/etc/group`
itself. `palm-init --selftest` runs its parser checks; `notes/init.md` has the
rest.

### palm-login

Speaks the greetd IPC protocol on `/run/palm-login.sock` (root:greeter 0660),
so `apps/greeter` talks to it the same way it talks to greetd. It checks
passwords against `/etc/shadow` with SHA-512 crypt written in Odin. Wrong
passwords, locked accounts and unknown users get the same error, after a delay.

It loops: the greeter session (`wm --drm --kiosk --exec greeter` as
`greeter`), then the session the greeter asked for (`wm --drm` by default) as
the user, with `/run/user/<uid>` created 0700 and the session's output in
`/var/log/session-<user>.log`, then the greeter again. `palm.autologin=<user>`
skips the greeter for the first session only.

One addition to greetd's protocol: `{"type":"power","action":"poweroff"|"reboot"}`.
The greeter runs unprivileged and busybox's `poweroff` works by signalling
PID 1, which an ordinary user may not do, so palm-login runs it as root. It
refuses while a user session is running. `notes/login.md` has the detail.

### palm

The package manager, modelled on Alpine's apk. There is a world file
(`/etc/palm/world`), and every `add`, `del` or `upgrade` resolves the world
again from scratch, so `del` also removes dependencies nothing needs any more.
Packages run no install scripts.

```
palm add <pkg|constraint|./file.palm>...   install and record in world
palm del <pkg>...                          remove, and orphans
palm update                                fetch and verify every index
palm upgrade                               upgrade everything
palm search <text>...
palm info <pkg>... [-L] [--who-owns <path>]
palm list [--installed|--upgradable|--available]
palm verify [<pkg>...]                     check installed files against recorded sha256
palm fix [<pkg>...]                        reinstall broken or missing files
palm build <dir> -o <outdir>               build a package from <dir>/PALMBUILD
palm index <dir> --key <secret>            write and sign <dir>/PALMINDEX
palm keygen <name>                         write <name>.sec and <name>.pub
palm --selftest | --version | help

global: --root <dir> --initdb --repo <url|path> --keys-dir <dir>
        --allow-untrusted --no-cache --json --yes --dry-run
exit:   0 ok, 1 verify found problems, 2 usage, 3 not found,
        4 refused, 6 unavailable, 7 failed
```

Any other first word is passed to `/usr/lib/palm/palm-surface`, which is
`apps/palm`, the command surface for the applications, installed under that
name because the two share a name.

**Formats.** A package, `<name>-<ver>-r<rel>.palm`, is a gzip-compressed ustar
archive whose first member is `.PKGINFO` (`key = value`: `pkgname`, `pkgver`,
`pkgdesc`, `arch`, `size`, `license`, `depend`, `provides`, `install_user`),
followed by the files with their modes and owners. `PALMINDEX` is a text file
with one stanza per package, including the sha256 of its `.palm`, and
`PALMINDEX.sig` is its detached ed25519 signature. Packages are trusted
because the index lists their sha256; the index is trusted because of the
signature. That is why plain `http://` is enough, as it is for apk. palm writes
its own tar, gzip encoder and HTTP client; sha256 and ed25519 come from
`core:crypto`.

**Recipes.** A `PALMBUILD` is a declaration, not a script: package fields,
then `file`, `tree`, `dir` and `symlink` lines mapping build-machine paths to
installed paths, and `mode` and `owner` overrides. The format is specified in
[`palm/PALMBUILD.md`](palm/PALMBUILD.md). Builds are reproducible. Six recipes
are written by hand (linux, palm-init, palm, palm-login, greeter, palmy-wm);
`recipes/generate.sh` writes the rest from what they package (busybox's applet
list, the host's glibc, libxkbcommon and keyboard data, `base/`, the font list,
the applications). `make` runs it on every build and its output is committed.

**The repository.** The build makes a signing key once per checkout in
`distro/build/keys/` (git-ignored), and its public half is installed in
`/etc/palm/keys/`, so a built machine trusts exactly the repository it was
built from. `/etc/palm/repositories` names `http://10.0.2.2:8080/x86_64`,
which is the build host as QEMU's user network shows it, so
`make -C distro serve` on the host is the guest's repository. The repository
has 36 packages; the `palmframe` meta-package installs 31 of them. `shop`,
`track`, `pickdemo`, `emoji` and `fonts-emoji` are in the repository but not
installed, so `palm add` has something to fetch.

`notes/palm.md` has the decisions the contract left open and the image
builder's command lines.

## What has been verified

Everything below was run inside QEMU and observed. The window manager's DRM
backend was never run on the build host. The last verification started from a
clean build (`make -C distro` after deleting the repository, root and image),
then booted a copy of that image through OVMF firmware, headless, driven over
QMP and the serial console. Screenshots are in `distro/out/shots/`
(git-ignored; the three above are copies).

- **Build.** `make -C distro` exited 0 in 4.8 s: 36 packages, a signed index,
  31 packages installed, the image written. `make -C distro check-libs`
  reported that every binary links only glibc.
- **Firmware to services.** OVMF started limine 12.8.0, which showed its three
  entries and booted the first after 3 s (`verify-r1-00-ovmf.png`,
  `verify-r1-00-limine.png`). palm-init mounted everything, set permissions on
  73 device nodes, and started network, getty-ttyS0, palm-login and syslog;
  network finished with status 0 and the serial login prompt appeared. The
  root was ext4 on `/dev/vda2`, read-write.
- **Greeter.** `verify-r1-01-greeter.png`: clock, date, hostname, the Palm
  account with a password field, the Palmframe session, Restart and Shut Down.
  `ps` showed `wm --drm --kiosk --exec greeter` and `greeter` running as user
  greeter.
- **Login.** Typing `palm` and Enter through QMP replaced the greeter with
  `wm --drm` as palm (`verify-r1-02-desktop.png`): the bar with workspaces 1 to
  9 and the hint to press SUPER+Return.
- **Terminal.** SUPER+Return opened term. `echo hello-verify; id; uname -r`
  printed `hello-verify`, `uid=1000(palm)` with groups wheel, video, audio,
  input and palm, and `6.18.56-palmframe` (`verify-r1-03-term.png`). A second
  SUPER+Return tiled two terminals with focus on the new one
  (`verify-r1-04-two-terms.png`).
- **Pointer.** An absolute pointer move and click on the left window moved
  focus there, and typed text landed in it (`verify-r1-05-pointer-left.png`);
  clicking the right window moved focus back, and `ls /usr/bin | wc -l`
  printed 424 there (`verify-r1-06-focus-typing.png`).
- **palm, offline.** On the serial root shell, `palm list --installed` listed
  31 packages, `palm verify` printed `OK: 31 packages verified` (its one note:
  `/etc/resolv.conf` modified, which udhcpc writes), and `palm info palmy-wm`
  showed the package.
- **palm, with the repository.** With `make -C distro serve` running,
  `palm update` reported 36 packages signed by `palmframe.pub`.
  `palm add --yes track` installed `/usr/bin/track`; `palm verify` then
  reported 32 packages. `palm del --yes track` removed it and verify was back
  to 31. `/etc/palm/world` still held only `palmframe`.
- **palm refuses tampering.** An index with one changed line under the original
  signature: `palm update` and `palm add` refused, exit 4. A package with one
  byte flipped and the index untouched: `palm add` refused on the sha256
  mismatch, exit 4, and nothing was installed.
- **Persistence.** Files written as root and as palm survived `reboot` (which
  stopped each service and remounted `/` read-only first) and, later, a
  power-off and a fresh QEMU start.
- **Power.** Clicking Shut Down on the greeter powered the machine off cleanly
  and QEMU exited by itself (`verify-r1-07-greeter-hover-shutdown.png` is the
  pointer over the button). `poweroff` on the serial console did the same.

Not checked in that run: the windowed gtk display, `--bios`, `--direct`, the
launcher, logging out, and Restart from the greeter. The integration agent's
own runs covered some of these on an earlier build of the same image:
`make -C distro test` passed on its last three runs, including the launcher
listing the 16 installed applications (`distro/out/shots/04-launcher.png`),
and `--bios` and `--direct` both reached palm-init and the serial login.
Logging out and Restart were tested by the login agent in its own initramfs,
not in this image.

Each component also has its own tests: `palm --selftest`, `palm-init
--selftest`, `palm-login --selftest`, `init/test-boot.sh`,
`login/test-boot.sh`, `login/e2e/run.sh`, `apps/wm/qemu-test.sh` and
`wm --drm-probe` inside the guest. Their results are in each area's notes.

## What is missing

The system boots, logs in and installs packages. It is not something to run
on real hardware yet.

- **Only QEMU.** It has never booted on real hardware. The kernel
  config (`kernel/palmframe.config`) was written for QEMU's machine: virtio
  devices, and virtio-gpu, bochs and simpledrm for the display.
- **The kernel limine boots is a copy.** It is copied into the FAT partition
  when the image is built. `palm upgrade linux` updates `/boot/vmlinuz` on the
  root, not that copy: the FAT partition is not mounted, and palm has no hooks
  to copy it.
- **No su or passwd for palm.** busybox is not setuid, so palm cannot become
  root. Package management is done as root on the serial console.
- **glibc, libxkbcommon and xkeyboard-config come from the build host** (Arch),
  not from source.
- **The window manager on bare metal** has no VT switching (Ctrl+Alt+Fn does
  nothing, the console is not put into graphics mode), enumerates input
  devices once at startup so hotplugged keyboards and mice are ignored, has
  only ever run one monitor, and repaints the whole screen on the CPU every
  frame. Clients see keys as press and release pairs, so none can see a key
  held down. `notes/wm.md`.
- **No clipboard.** palmy copies through `wl-copy`, which Palmframe does not
  ship.
- **Applications.** 22 of the 47 programs work on the bare system, 9 partly,
  16 not at all: those need ffmpeg, PipeWire, NetworkManager, BlueZ, ollama,
  pacman or OpenSSL (`apps/apps.tsv`). `files` and the launcher still offer
  `foot` as the terminal. The `chat` app is not packaged, and busybox's `chat`
  applet is left out because the names clash.
- **No timezone.** The greeter's clock shows UTC.
- **The system is fixed-size.** No swap, no `/etc/fstab` entry for the FAT
  partition, and the root filesystem is the installed size plus 1 GiB, with no
  resize on first boot.
- **palm** has a greedy resolver with repair, not a SAT solver, and no
  `conflicts` or `replaces` fields; no https, keep-alive or parallel
  downloads; and holds each transaction's packages in memory. `list` and `info`
  print a connection warning when no repository is reachable, although both
  are local queries.
- **palm-login** keeps no utmp, wtmp or lastlog, ignores shadow's aging fields,
  and limits guessing only by a 1.5 s delay per failed attempt.
- **palm-init** reloads only by adding: `kill -HUP 1` does not stop removed
  services or restart changed ones.
- **Small visual faults** seen in the verification screenshots: a single left
  click in term leaves a one-cell selection, and the greeter's Shut Down
  button shows no hover state.
