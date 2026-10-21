# pkg against a real pacman

`pkg --selftest` proves what pkg *would* run, using fake `pacman`, `sudo` and
`snapper` on `PATH`. This directory runs pkg against the real tools: a real
pacman on Arch Linux ARM, a real sudo, and a real snapper on a real btrfs
filesystem. The Arch host pkg was written for no longer exists, so the run
happens in containers in the arm64 build VM.

    bash apps/pkg/integration/arch-container.sh            # in the VM
    bash apps/pkg/integration/arch-container.sh --keep     # keep @run to inspect

The first run takes about 15 minutes, because it builds limine-snapper-sync
from the AUR. Later runs take about 5 minutes, because the package is cached.
Each run starts from a fresh copy of the official ALARM rootfs.
`arch-container.sh` explains the layout. `inside.sh` holds the assertions.
`last-run.log` is the full log of the run recorded below.

## Result (2026-10-21, branch agent/pkg-real)

**175 passed, 0 failed** (run 3, after rebasing onto main; `last-run.log`). The run used ALARM aarch64 (rootfs
2026-10, 76 packages behind the mirror), pacman 7.1.0, sudo 1.9.17p2,
snapper 0.13.2, and limine-snapper-sync 1.32.1 built from the AUR.

What ran for real, as the unprivileged user `palm`, through pkg's own `sudo`:

- **install** of cowsay, sl, figlet, tree, fortune-mod and lolcat, with no
  terminal (as an agent runs it). The argv that sudo logged was exactly the
  argv from `--dry-run`. pacman's log shows the same transaction. All six run.
  A second install is idempotent and reaches sudo zero times.
- **remove** (`-R`, then `-Rs`, which also removed ruby as an orphan) and
  **sync** (installing what a declaration lacks, then `--prune` removing the
  one undeclared package). Each was checked against its dry-run argv in the
  same way.
- **upgrade**: refused without a terminal, even with `--yes`. Run at a
  pseudo-terminal, sudo ran exactly the snapshot and then `pacman -Syu`. The
  leaf package held back during setup (nano) was upgraded.
- **`-Sy` without `-u`**: `--refresh` is refused. A flag passed as a name is a
  usage error. Of the 23 commands that reached sudo and the 11 pacman
  transactions, none was a partial upgrade. The check that proves this was
  shown to fail on `pacman -S -y`.
- **The five protected classes**, each against a package that was really
  installed: linux-aarch64 and linux-firmware (kernel); mkinitcpio, limine and
  limine-snapper-sync (bootloader); ly (display manager, installed for the
  test); systemd and dbus (init); pacman, glibc, sudo, snapper and btrfs-progs
  (core). Each was refused by name, nothing reached sudo, and the package was
  still installed afterwards. `--allow-protected` for the wrong class does not
  unlock a package. The right class without `--yes` does not unlock it
  either. The right class with `--yes` really removed ly.
- **Dependants**: `remove ruby` names lolcat, read from the real `pacman -Qi`.
  With `--yes`, pkg runs `-R`, pacman refuses to break lolcat, and pkg exits 7
  with ruby still installed. `--yes` never turns into `-Rc`.
- **No sudo rule** (the old host's case, where sudo needs a password and pkg
  has none): sudo stops at the first step. pkg exits 7 and nothing is
  installed.
- **Snapshots**: every mutation created a real snapper snapshot named
  `palm pkg <op> <targets>`. These are the first real palm-named snapshots.
  `pkg snapshots` as palm returns exit 6 until snapper's `ALLOW_USERS`
  includes palm, which is what the old host saw. After that, it lists every
  snapshot palm took.
- **limine-snapper-sync**: with its service running, every palm-named snapshot
  got a Limine boot entry within about a second, for example
  `///1│palm pkg install cowsay figlet fortune-mod lolcat sl tree`. Each entry
  boots `rootflags=subvol=/@run/.snapshots/N/snapshot`. pkg refuses to remove
  limine-snapper-sync, because it is in the bootloader class.
- **rollback**, on two layouts:
  - **Plain-subvolume root** (`/` = `@run`, the usual Arch layout): pkg
    refuses with `rollback-layout` (exit 5), before running anything. Run
    directly, snapper itself exits 1 with "Cannot detect ambit".
  - **openSUSE layout** (`/` = a snapper snapshot that is the btrfs default):
    `pkg rollback 1 --yes` at a terminal ran exactly
    `snapper --config root rollback 1`. The btrfs default moved to the new
    writable copy of #1. A third container booted from that subvolume (the
    "reboot") has none of the six packages, and pkg plans to install cowsay
    again.

## Bugs the real run found (each fixed, with assertions)

1. **pacman asked a second time and read the empty answer as no.**
   `pkg install … --yes` with no terminal created the snapshot. pacman then
   asked "Proceed with installation? [Y/n]", read end-of-file, and exited 1.
   So pkg exited 7 after it had already changed the machine. Now install and
   remove pass `--noconfirm` (see `PACMAN_NOCONFIRM` in `plan.odin`). upgrade
   and the AUR build do not. The fake sudo in the self-test now answers the
   way the real pacman did. 20 assertions fail without the fix.
2. **`snapper rollback` cannot roll back the usual Arch layout.** pkg ran it
   anyway and reported snapper's error as exit 7. Now `plan_rollback` checks
   the layout before it plans anything. It uses snapper's own rule (the
   default subvolume must be a snapshot), read from `snapper list` when pkg
   can read the list, or from `/proc/self/mountinfo` when it cannot. The
   refusal names `limine-snapper-restore`, which is how limine-snapper-sync
   restores this layout. pkg also refuses an unknown snapshot number with
   exit 3.
3. **`snapper list` marks rows, and the parser dropped marked rows.** On a
   layout that can roll back, `1*` (default and active) is the snapshot the
   machine is running. That row was dropped. Now the parser reads the marks,
   and `snapshots --json` reports `default` and `active`.
4. **Refusal subjects pointed into a dead stack frame.** pkg printed an empty
   subject for a refused rollback. With the new assertion, the self-test
   segfaulted before the fix.

## sudo: the decision

pkg has no special path for sudo, and this run did not add one. Every step
that needs root starts with `sudo`, and the child inherits the terminal. pkg
never reads, stores or passes a password. In the container, `palm` has a
passwordless rule (`palm ALL=(root) NOPASSWD: ALL`) in
`/etc/sudoers.d/palm`. That rule exists only inside the container, so no
password exists anywhere in the run. Running pkg as root was not chosen,
because then `sudo` would be a no-op and the run would not show what reaches
it. Section a6 removes the rule and shows the old host's behaviour: sudo
stops and the plan stops with it. On a real machine, the rule stays as
TODO.md has it: an agent never caches, embeds or prompts for a password.

## What this does not prove

- **No real boot.** Containers share the VM's kernel. The rollback "reboot" is
  a new container rooted at the subvolume that snapper made the default. That
  proves what the next boot would mount, not that Limine boots it. Limine
  entries were checked as text in `limine.conf`.
- **Not the old host.** The old host's layout (ESP, `subvol=` on the kernel
  command line, its own snapper config) is unknown. Bug 2 means
  `pkg rollback` is now refused there unless its root is a snapper snapshot.
- **AUR through yay.** yay is not in the ALARM repos, so the `yay` steps have
  never run. limine-snapper-sync was built with makepkg instead. ALARM has no
  gradle package, so the build uses a downloaded Gradle 9.2.1 and
  `makepkg --nodeps` for that one makedepend.
- **`limine-snapper-restore` was not run.** It is interactive and expects to
  run from a booted snapshot.
- **Harness choices:** the kernel and firmware are held with `IgnorePkg`,
  because the container never boots them. A person at the terminal is played
  by script(1) and a few presses of Enter, which accept pacman's defaults.

## Incidents while building this (both in the shared VM, both fixed)

- The first container ran systemd with `--network host`. Its networkd took the
  VM's eth0 DHCP lease when it stopped. The VM had no IPv4 for about a minute
  (19:55–19:56), until `networkctl reconfigure eth0` restored it. The harness
  now gives every container its own network namespace and masks networkd,
  resolved, timesyncd and dhcpcd before boot.
- The first full run piped `yes` into script(1). script grew to 4 GB, and the
  VM's OOM killer ran twice (20:36, 20:37). Besides the two script processes,
  it killed one `dbus-daemon` owned by uid 501. The harness now sends a few
  bounded answers. Run 2 caused no OOM.
