# palm-login and the greeter — notes

Owner: distro/login/, apps/greeter/, this file.

## What exists

- `distro/login/` — palm-login, in Odin. `distro/login/build.sh` writes
  `distro/out/bin/palm-login` and `distro/out/bin/greeter`.
  - greetd IPC on `/run/palm-login.sock` (`ipc.odin`), socket `root:greeter 0660`.
  - SHA-512 crypt written by hand on top of `core:crypto/sha2` (`crypt.odin`),
    checked against all of Drepper's vectors and against `openssl passwd -6`.
    The hashes already in `distro/base/root/etc/shadow` verify with it.
  - passwd / shadow / group parsers, initgroups without NSS (`accounts.odin`).
  - Sessions (`session.odin`): runtime dir `/run/user/<uid>` 0700 owned by the
    user, log `/var/log/session-<user>.log` 0600 owned by the user, then fork,
    setsid, setgroups, setgid, setuid (checked), chdir `$HOME`, execve. stdin is
    `/dev/null` (not a VT — see below).
  - The loop of the contract (`main.odin`): greeter session as `greeter`
    (`wm --drm --kiosk --exec greeter`, `GREETD_SOCK`, `PALM_LOGIN=1`,
    `XDG_RUNTIME_DIR=/run/user/900`), then the user's session, then back.
    `PALM_AUTOLOGIN` (or `palm.autologin=` read from /proc/cmdline as a fallback)
    skips the greeter for the first session only. A greeter that does not exit
    within 8 s of a successful `start_session` gets SIGTERM, then SIGKILL 3 s
    later. A greeter that dies within 3 s is restarted with a growing delay.
    SIGTERM to palm-login ends the running session's process group and removes
    the socket.
- `apps/greeter/` under palm-login (detected as `GREETD_SOCK` set **and**
  `PALM_LOGIN=1`; anywhere else the old stub behaviour is untouched):
  - Restart and Shut Down are real; Suspend is not offered (no suspend path).
  - The session list gets a built-in "Palmframe" entry (`wm --drm`) first,
    unless an installed `.desktop` entry already runs `wm`, and it is the
    default; no `bash -l` fallback (there is no bash, and no tty to put it on).
  - The layer surface asks for 0x0 anchored to all edges, so `wm` sizes it to
    the output; if layer-shell is missing it falls back to a fullscreen toplevel.

## Contract clarification: power actions

The contract says the greeter's power actions "run /sbin/poweroff /
/sbin/reboot (busybox, which signal PID 1)". They cannot be run *by the
greeter*: busybox's poweroff is `kill(1, SIGUSR2)`, and the unprivileged
`greeter` account may not signal PID 1 (EPERM). So the greeter asks palm-login
with one request greetd does not have,

    {"type":"power","action":"poweroff"|"reboot"}  ->  success | error

on a connection of its own, and palm-login (root) runs `/sbin/poweroff` or
`/sbin/reboot`. Refused while a user session is running. The net effect is
what the contract describes; verified in QEMU (Restart in the greeter ->
`palm-init: rebooting`).

## Extra knobs (for images and tests)

- `palm-login --hash PASSWORD [--salt S] [--rounds N]` prints a `$6$` hash —
  the image builder can write `/etc/shadow` with the same code that checks it.
- `PALM_GREETER_CMD` replaces the greeter session command line;
  `PALM_DEFAULT_SESSION` replaces the autologin session command (`wm --drm`).
  Both split on spaces.
- `palm-login --test --sock PATH --shadow F [--passwd F] [--group F]` serves the
  protocol unprivileged and reports, never starts, sessions.

## Tests (all run, all passing)

- `distro/login/build.sh --test`: `palm-login --selftest` (56 checks: crypt
  vectors, parsers, an IPC round trip against itself in --test mode), then the
  greeter's own `--selftest` pointed at palm-login --test (18 checks).
- `distro/login/e2e/run.sh`: the real daemon (not --test) in a user + mount
  namespace — setuid to 900/1000 really happens; tmpfs over /run and /var/log,
  a recording script bind-mounted over /sbin/reboot. Login, wrong password,
  session uid/groups/env/runtime dir/log, Restart, autologin, a greeter that
  will not exit.
- `distro/login/test-boot.sh`: an initramfs with palm-init + palm-login +
  greeter + wm + glibc + base fonts, booted in QEMU headless. Screendumps show
  the greeter fullscreen at 1280x800; a wrong password typed through QMP is
  refused on screen; `palm` starts `wm --drm` as palm with the contract
  environment; logging out returns to the greeter; Tab Tab Enter on Restart
  reboots the machine. Screenshots in `distro/build/login/boot/`.

## For the image builder

- Install `palm-login` and `greeter` to `/usr/bin` (the service file in
  `distro/base` already runs `/usr/bin/palm-login`), and `wm`.
- `/var/log` must exist; `/run` is palm-init's tmpfs; `/run/user` is created.
- The greeter account's home (`/var/lib/greeter`) is already in base/layout.

## Open points / for other areas

- Sessions get `/dev/null` as stdin, not a VT. The wm in QEMU works that way
  (KMS + evdev directly). If the wm ever wants a VT (KD_GRAPHICS, VT switching),
  palm-login can hand it `/dev/tty1` — ask here. It deliberately does not make
  the tty the session's controlling terminal, so ctrl-C on the console keyboard
  can never kill the session.
- The clock on the greeter shows UTC: Palmframe has no timezone setting yet.
- No utmp/wtmp, no lastlog, no account expiry (shadow fields beyond the hash
  are ignored), no rate limit beyond a 1.5 s delay per failed attempt.
