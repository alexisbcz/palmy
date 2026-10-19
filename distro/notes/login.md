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

## The session socket: Lock, Restart and Shut down from the session

The greeter's socket is the way *into* a session and belongs to the greeter
group. A running session needs palm-login for two things it cannot do as
the user: check the user's password for the lock screen (the wm must never
read /etc/shadow) and power the machine off. So palm-login listens on a
second socket, `/run/palm-login.session.sock` (`session_ipc.odin`), same
greetd framing, and tells the session where it is in `PALM_SESSION_SOCK`.
It answers two requests and nothing else:

    unlock{password}                       success | error{auth_error|error}
    power{action, dry_run?, password?}     success | error{auth_required|auth_error|error}

### Policy, and why

What a logind desktop does for the one local seat, written down without
polkit:

| who asks | unlock | power |
| --- | --- | --- |
| a process of the running session, its VT in front, nobody else logged in | password checked | **allowed, no password** |
| ...nobody else logged in, but the VT switched away | password checked | refused ("not the one on screen") |
| ...someone else logged in (root on ttyS0, say) | password checked | `auth_required`: the password of a member of `wheel` overrides |
| ...same, but the user is not in wheel | password checked | refused |
| the session's user, from outside the session (a serial login, anything not below the session leader) | refused | refused |
| another user, the greeter, root | cannot connect (socket is the user's, 0600); refused anyway | same |
| anyone, while no user session runs, or while one is ending | refused | refused |

- **Who is "the session".** The socket file is chown'd to the session's
  user (0600) when palm-login starts the session and back to root when it
  ends, so nobody else can even connect. Then each request is checked again
  with SO_PEERCRED: the peer's uid must be the uid palm-login itself started
  the session as, and the peer's pid must be the session leader palm-login
  forked or a descendant of it (walked through /proc/<pid>/stat). That is
  logind's "process of the session" (its cgroup) without cgroups. A process
  that got reparented to init is out — it is no longer reliably the
  session's. Root is not special: root can run poweroff itself.
- **No password for power, alone at the seat.** logind's default for the
  active local session (`org.freedesktop.login1.power-off`: yes for active
  sessions), and what every desktop does: the person at the keyboard can
  pull the plug anyway.
- **Active means on screen.** The session's VT (tty1) must be the active one
  (`/sys/class/tty/tty0/active`), as logind's `active`; a session that was
  switched away from is not the person at the keyboard.
- **Others logged in.** logind's `power-off-multiple-sessions` needs an
  admin's authentication; here: a live USER_PROCESS in utmp on a line other
  than seat0 (dead pids do not count — a crashed login leaves its record) and
  the request must carry the password of a member of `wheel` (the group
  doas.conf permits by default). Shutting down under someone else's shell is
  not for the person at the seat to decide alone. Remote sessions: Palmframe
  ships no sshd; one added later writes utmp and is counted the same way.
- **Unlock is rate limited** with the shared `auth/` package, on the same
  `/run/faillock/<uid>` tally as doas and passwd (counted *before* the check,
  so parallel attempts all count), and a wrong answer is held 1.5 s like the
  greeter's. A malicious process inside the session could use unlock as a
  password oracle — exactly as it could use doas — and it gets the same
  budget, shared. Expired or inactive accounts (shadow aging) do not unlock;
  a password that merely has to be changed does (that happens at the next
  login).
- **Power ends the session first.** palm-login replies, records
  `power_after`, and waits for the session to exit (the wm leaves by itself
  once its windows are closed); after 10 s it sends SIGTERM, 3 s later
  SIGKILL. `session_ended` then does the usual teardown — utmp/wtmp logout,
  the tty back to root, the session's process group SIGHUP+SIGTERM, the
  socket back to root — and only then runs `/sbin/poweroff` or
  `/sbin/reboot`. No greeter is started in between (it would, after a
  minute, if the power program failed).

The greeter's own `power` request is unchanged and still refused while a
user session runs.

### The wm's side

`apps/wm/login.odin` (the client, non-blocking: the socket is in the main
loop's poll set), `apps/wm/locker.odin` (the lock screen) and
`apps/wm/power.odin` (the confirmation). The start menu's power button
offers Lock, Log out…, Restart…, Shut down… when `PALM_SESSION_SOCK` is set,
and the old "Restart or shut down from the login screen" otherwise. Restart
and Shut down ask palm-login with `dry_run` as the dialog opens, so a
refusal shows before anything is closed; then a 10 s countdown (Enter now,
Esc cancels), every window gets `xdg_toplevel.close`, the wm waits up to
8 s, names the windows that did not close ("may be asking whether to save")
and offers Cancel or "anyway"; then the real request, and the wm exits.

The lock: Super+L (the default `movefocus right` on Super+L gave way, see
below), Lock in the power menu, `lock_after` in wm.conf (default 10m; a
client idle inhibitor holds it off), and before a suspend (there is no
suspend yet; the intent locks). While locked the compositor draws only the
lock and returns before the desktop, so nothing of the windows is drawn, and
`set_kbd_focus`/`set_ptr_focus` refuse every surface that is not a lock
surface, so no client sees a key. VT switches work while locked and come
back to the lock (it is compositor state). A client locker
(ext_session_lock_v1) still works; if it dies, this prompt unlocks the
abandoned lock. On bare metal Ctrl+Alt+Q no longer works while locked (it
would end the locked person's session); nested it still does.

### Tests

- `palm-login --selftest` 83 -> 107: the session socket in --test mode with
  a pretend session (`--session-user/--session-uid/--session-leader`,
  `--vt-active`, `--utmp`): unlock right/wrong/late/empty, the rate limit,
  power dry run, refusal off-screen, others logged in (auth_required, wrong
  and right wheel password, then logged out), greetd requests refused on
  the session socket and unlock refused on the greeter's, another uid, a
  process outside the session (a reparented grandchild, and a leader that
  is not an ancestor), no session at all, socket mode 0600.
- `odin test distro/login/auth` 7 -> 8: `utmp_logins` (seat0 skipped, dead
  pids and logged-out lines dropped).
- `distro/login/e2e/run.sh` 22 -> 33: the real daemon, autologin palm runs
  `session-client.py`: PALM_SESSION_SOCK, palm's 0600; wrong unlock refused
  after 1.5 s and `/run/faillock/1000` written; right unlock; dry run; palm
  from outside the session (setpriv) refused; uid 900 cannot connect;
  reboot accepted, the socket refuses once ending; the session closed, then
  `/sbin/reboot` ran as root, no greeter in between.
- `wm --selftest` 327 -> 387 (locker_test.odin: lock_after parsing, no lock
  without palm-login, focus refused while locked, the field, wrong/late/
  rate-limited/unreachable answers, an abandoned client lock, idle and its
  inhibitor, the power dialog's dry run, countdown, password override,
  refusal, cancel, lock cancelling a dialog); `wm --shots` 20–29 are the
  lock and the dialog, dark and light.
- `apps/wm/lock-qemu.py` on the built image, three boots of one disk, 29
  checks, all passing: the socket handed to the session; Super+L locks with
  nothing of the desktop drawn; text typed while locked never reaches the
  focused terminal; a wrong password refused after palm-login's hold, the
  failures in palm-login's log; the right one unlocks; Ctrl+Alt+F2 and back
  lands on the lock; `lock_after = 12s` locks; Restart left to its countdown
  reboots (QEMU exits), and the next boot's logs show the terminal asked to
  close, the session ended and closed, then /sbin/reboot, in that order;
  with root on ttyS0, Shut down asks for palm's password, refuses a wrong
  one, takes the right one and powers off, and the next boot's log shows it.
  `apps/wm/shell-qemu.py` 43/43 and `distro/image/test-boot.py` 27/27 on
  the same image.

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

## Session hooks and the VT (integration round)

- **`/etc/palm/session.d/`.** Before a user session's command is exec'd,
  every executable there (regular file with an x bit, not hidden, not `~`,
  `.new` or `.bak`), in name order, is forked from the session's child after
  setgroups/setgid/setuid and chdir: as the user, with the session's
  environment, stdin `/dev/null`, output in the session log, and in the
  session's process group, so the SIGHUP/SIGTERM palm-login sends that group
  when the session ends reach them too. Nobody waits for them: the session
  program inherits them (wm reaps), palm-init adopts what outlives it. Not
  for the greeter's session. `PALM_SESSION_D` replaces the directory (the e2e
  test). PipeWire's `50-pipewire` is the first user.
- **The VT for wm.** Both sessions (greeter and user) run on VT 1: before
  each, `/dev/tty1` is chown'd to the session's user, group tty, 0620, and
  `XDG_VTNR=1` goes into its environment; `setsid()` is kept, so wm opens the
  tty and it becomes its controlling terminal, which the VT ioctls require.
  When the session ends the tty goes back to root:tty 0620. Where the chown
  is refused (the e2e namespace) nothing is lent and nothing changes. On the
  image: the greeter's wm logs `vt: tty1 in graphics mode, VT_PROCESS`, the
  user's has `XDG_VTNR=1` and `/dev/tty1` is `palm:tty`; Ctrl+Alt+F2 made
  tty2 the active console (`/sys/class/tty/tty0/active`), Ctrl+Alt+F1 came
  back and typing in term worked; after SUPER+SHIFT+E the next greeter had
  the tty. tty2 has no getty, so it is a blank console.
- Tests: `palm-login --selftest` 81 -> 83 (session.d listing), `login/e2e`
  18 -> 22 (a hook runs as palm with the session environment, in the
  session's process group, is ended with it; a non-executable is skipped).

## Open points / for other areas

- The session socket has no CLI client yet: `palm power reboot|lock`
  (docs/PALM-CLI.md) would be one more client of it, and is refused from a
  terminal only if that terminal is not below the session leader.
- No suspend path exists; the `suspend` intent locks the screen and stops
  there.
- The lock screen shows no per-identity counts (cloud/docs/shell.md): there
  is no notification store to count yet.

- Sessions get `/dev/null` as stdin. palm-login lends `/dev/tty1` to wm
  (above) but deliberately does not make it the session's controlling
  terminal itself, so ctrl-C on the console keyboard can never kill the
  session; wm takes it when it opens the VT.
- A SIGKILLed PipeWire leaves its socket in `/run/user/<uid>`, and the next
  session's `50-pipewire` then starts nothing: palm-login does not empty the
  runtime directory between sessions.
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
- `distro/doas/test-qemu.py`: the disk image in QEMU, 22 checks, all passing
  (with the Makefile, generate.sh and syslog changes below applied): doas and
  passwd installed 4755 root, `palm verify` clean; on the serial console as
  palm `doas id` -> uid 0, a wrong password refused, `doas palm --repo
  http://10.0.2.2:PORT/x86_64 add shop` installs it; `passwd` to a new
  password, then busybox login refuses the old one and takes the new one, and
  the greeter (typed over QMP) starts `wm --drm` as palm with it; `who` shows
  palm on seat0 and ttyS0, `last` the sessions and the boot; doas, passwd and
  palm-login lines in /var/log/messages.

### Needs from other areas

- `distro/Makefile`: rules for `$(BIN)/doas` and `$(BIN)/passwd`
  (`odin build distro/doas` / `distro/passwd`, depending on their sources
  and `distro/login/auth`), both left out of APP_BINS and added to
  `binaries` and `check-libs`.
- `distro/recipes/generate.sh`: `passwd` in BB_SKIP (busybox's applet would
  claim /usr/bin/passwd), and `doas passwd` in palmframe's first depend line;
  then regenerate the busybox and palmframe recipes.
- `distro/base/root/etc/palm/services/syslog`: add `-L`. busybox 1.37.0's
  syslogd sets "log locally" in `option_mask32` when no `-R` is given but its
  receive loop tests a copy taken earlier (`opts`), so without `-L` it logs
  nothing but its own start and exit lines — `/var/log/messages` on the image
  has been empty of every program's messages, `logger` included. With `-L`
  everything arrives (checked on the host in a namespace and in QEMU).
  /var/log/messages is now 0600 root: syslogd runs from
  `/usr/lib/palmframe/syslog` (palmframe-base), which sets umask 077 and
  fixes an older file's mode (test-runtime.py checks it).
