# palm-login, the greeter, doas and passwd — notes

Owner: distro/login/ (and distro/login/auth/), distro/doas/, distro/passwd/,
distro/recipes/{palm-login,doas,passwd}/, apps/greeter/, this file.

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
- busybox's own `login` on ttyS0 ignores shadow aging; only palm-login,
  doas and passwd honour it.

## Privilege and authentication (doas, passwd, auth/)

`distro/login/auth/` is one Odin package imported by palm-login
(`import "auth"`) and by doas and passwd (`import "../login/auth"`):

- `crypt.odin`, `accounts.odin` — moved from palm-login, plus the whole shadow
  line (`Shadow`, all nine fields) and `parse_passwd_uid`.
- `aging.odin` — shadow-utils' isexpired rules: account expiry, `lastchg = 0`,
  max/inactive/warn, and `min` for passwd.
- `ratelimit.odin` — failures counted per key; the first two cost the base
  delay (1.5 s), then the wait doubles (3, 6, ... 60 s) and an attempt inside
  it is refused unchecked; a success or 15 quiet minutes clear it.
  CLOCK_BOOTTIME, so the wall clock cannot shorten it. palm-login keeps counts
  in memory (per name, and per seat after 8); doas and passwd in
  `/run/faillock/<uid>` (root 0700), flock'd, and written *before* the check so
  parallel copies all count.
- `shadow_write.odin` — `/etc/shadow+` written, fsynced and renamed over
  `/etc/shadow`, `/etc/shadow-` kept as a hard link; under `/etc/.pwd.lock`
  (fcntl, lckpwdf's) and `/etc/shadow+` itself (O_EXCL, busybox's lock; one
  older than a minute is a crash's leftover and is removed). Every signal is
  blocked during the write.
- `utmp.odin` — glibc's 384-byte `struct utmp`, so busybox `who`/`users`/`w`
  read `/run/utmp` and `last` reads `/var/log/wtmp`; lastlog is written too
  (292-byte records at uid*292) though nothing on the system reads it yet.
- `syslog.odin` — glibc syslog(3), facility authpriv; user-supplied strings
  have control characters replaced so they cannot forge a line.
- `harden.odin` — the setuid prologue (fds 0-2 reopened if closed,
  RLIMIT_FSIZE lifted, RLIMIT_CORE 0, not dumpable, umask 022) and the no-echo
  prompt on `/dev/tty` that restores the terminal on ctrl-C.
- `quality.odin` — at least 6 characters, not the old one, not the name.

palm-login now: backoff and syslog (`accounts.odin`), the expired-password
conversation (`ipc.odin`: secret "New password:", secret "Retype...", an
`error` auth_message for a refused one, `info` for "expires in N days"),
utmp/wtmp/lastlog for user sessions on line `seat0` (`main.odin`), and a
"reboot" record once per boot (marker `/run/palm-login.boot`).

doas (`distro/doas`) follows OpenBSD's doas.conf(5) — permit/deny, nopass,
nolog, persist, keepenv, setenv { }, `as`, `cmd`, `args`, last match wins —
and the caller's own password. `doas -C file [cmd]` checks a policy with all
privileges dropped. Commands come only from the safe PATH; a missing command
is reported only to a caller some rule permits, so doas is not an oracle for
root-only paths. persist keys are uid + tty + session id + the session
leader's start time, in `/run/doas` (root 0700), five minutes.

passwd (`distro/passwd`): see the comment at the top of `main.odin`. It
makes its real uid root before writing, so the caller can no longer signal it.

### Tests

- `distro/login/build.sh --test`: palm-login `--selftest` (81 checks: the 64
  before, plus aging — expired account, warning, the whole change-at-login
  conversation and its shadow line — and the rate limit), the greeter's
  selftest against it (18), `odin test distro/login/auth` (7 tests: aging,
  shadow lines, names, quality, backoff, update_shadow on a temp file with
  stale-lock and refusal cases, utmp/wtmp/lastlog records), `odin test
  distro/doas` (4 tests: parser accepts/rejects, matching, environment).
  Test code lives in `*_test.odin`, which only `odin test` compiles.
- `distro/doas/e2e/run.sh`: the setuid binaries run for real in a user+mount
  namespace with a fixture /etc, a listening syslog and a pty driver — 64
  checks: grant, wrong password, non-wheel, backoff, environment, PATH
  hijack, closed fds, unsafe/foreign/symlinked/broken doas.conf, persist and
  -L, nopass cmd args, -n, no tty; passwd change/refusals/lock/unlock/expire,
  shadow+ lock fresh and stale, file-size limits, then doas with the new and
  expired passwords.
- `distro/login/e2e/run.sh` now also checks busybox `who` inside the session,
  `last` afterwards, the reboot record, lastlog and the logged failure (18).
- `distro/doas/test-qemu.py`: the disk image in QEMU — see below for results.

### Needs from other areas

- `distro/Makefile`: rules for `$(BIN)/doas` and `$(BIN)/passwd`
  (`odin build distro/doas` / `distro/passwd`, depending on their sources
  and `distro/login/auth`), both left out of APP_BINS and added to
  `binaries` and `check-libs`.
- `distro/recipes/generate.sh`: `passwd` in BB_SKIP (busybox's applet would
  claim /usr/bin/passwd), and `doas passwd` in palmframe's first depend line.
