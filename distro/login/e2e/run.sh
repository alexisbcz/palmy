#!/bin/sh
# The real palm-login daemon, end to end, without root and without touching
# the host: a user namespace makes this process root over a range of subuids
# (so setuid(900) and setuid(1000) really happen), and a private mount
# namespace puts tmpfs over /run and /var/log and a recording script over
# /sbin/reboot. Nothing here can reach the host's login, its runtime
# directories or its power state.
#
#   distro/login/e2e/run.sh
#
# Three scenarios: a greeter that logs in (one wrong password, then the right
# one) and later presses Restart; palm.autologin; and a greeter that will not
# exit after start_session. Needs newuidmap and a subuid range (unshare
# --map-auto).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BIN="$ROOT/distro/out/bin/palm-login"
W="$ROOT/distro/build/login/e2e"

if [ "${PALM_E2E_INSIDE:-}" != 1 ]; then
	[ -x "$BIN" ] || { echo "build first: distro/login/build.sh" >&2; exit 1; }
	mkdir -p "$W"
	H="$("$BIN" --hash palm)"
	printf 'root:x:0:0:root:/root:/bin/sh\ngreeter:x:900:900:Greeter:/run/test/greeter-home:/sbin/nologin\npalm:x:1000:1000:Palm:/run/test/palm-home:/bin/sh\n' >"$W/passwd"
	printf 'root:%s:19000::::::\ngreeter:!:19000::::::\npalm:%s:19000::::::\n' "$H" "$H" >"$W/shadow"
	printf 'root:x:0:\nwheel:x:10:palm\naudio:x:63:palm\nvideo:x:39:palm,greeter\ninput:x:97:palm,greeter\ngreeter:x:900:\npalm:x:1000:\n' >"$W/group"
	cp "$BIN" "$W/palm-login"
	PALM_E2E_INSIDE=1 exec unshare --user --map-root-user --map-auto --mount --propagation private "$0"
fi

# --- inside the namespaces from here on ---
mount -t tmpfs -o mode=0755 none /run
mount -t tmpfs -o mode=0755 none /var/log
mkdir -p /run/test/greeter-home /run/test/palm-home
chmod 777 /run/test
chown 900:900 /run/test/greeter-home
chown 1000:1000 /run/test/palm-home
install -m 644 "$HERE/greeter-client.py" "$HERE/stuck-greeter.py" "$HERE/session-client.py" /run/test/
# busybox's who and last read the records palm-login writes, exactly as on
# the installed system.
install -m 755 "$ROOT/distro/out/busybox" /run/test/busybox
printf '#!/bin/sh\nid > /run/test/powered; echo "$0 $*" >> /run/test/powered\n' >/run/test/fake-reboot
chmod 755 /run/test/fake-reboot
mount --bind /run/test/fake-reboot "$(readlink -f /sbin/reboot)"
printf '#!/bin/sh\n{ echo autologin; id; } > /run/test/autologin.txt; sleep 1\n' >/run/test/autosession.sh
chmod 755 /run/test/autosession.sh
# A session hook (/etc/palm/session.d in the system): it records who it runs
# as and its process group, then outlives the session unless it is ended.
mkdir -p /run/test/session.d
printf '#!/bin/sh\necho "hook uid=$(id -u) pgid=$(cut -d" " -f5 /proc/$$/stat) xdg=$XDG_RUNTIME_DIR" > /run/test/hook.txt\necho $$ > /run/test/hook.pid\nexec sleep 60\n' >/run/test/session.d/50-hook
printf '#!/bin/sh\necho ran > /run/test/not-executable.txt\n' >/run/test/session.d/10-not-executable
chmod 755 /run/test/session.d/50-hook

daemon() {
	secs="$1"; shift
	env "$@" timeout -s TERM "$secs" "$W/palm-login" --passwd "$W/passwd" --shadow "$W/shadow" --group "$W/group" 2>&1 || true
}
fail=0
expect() { # expect <description> <command...>
	d="$1"; shift
	if "$@" >/dev/null 2>&1; then echo "pass  $d"; else echo "FAIL  $d"; fail=1; fi
}

echo "=== 1. login, user session, back to the greeter, Restart"
daemon 9 PALM_SESSION_D=/run/test/session.d PALM_GREETER_CMD="/usr/bin/python3 /run/test/greeter-client.py" | tee /run/test/daemon1.log
echo "--- what the greeter saw"; cat /run/test/greeter-runs.txt
echo "--- what the user session saw"; cat /run/test/user-session.txt
ls -ln /run/user /var/log
expect "greeter runs as 900 with video+input"   grep -q "uid=900 gid=900 groups=\[39, 97, 900\]" /run/test/greeter-runs.txt
expect "greeter gets GREETD_SOCK and PALM_LOGIN" grep -q "sock=/run/palm-login.sock palm_login=1" /run/test/greeter-runs.txt
expect "wrong password is auth_error"           grep -q "auth_error" /run/test/greeter-runs.txt
expect "session runs as palm with its groups"   grep -q "uid=1000.*groups=1000.*,10,39,63,97" /run/test/user-session.txt
expect "session env from the contract"          grep -q "XDG_CURRENT_DESKTOP=palmframe" /run/test/user-session.txt
expect "start_session env is passed"            grep -q "FROM_GREETER=yes" /run/test/user-session.txt
expect "XDG_RUNTIME_DIR is 0700, the user's"    sh -c 'ls -ldn /run/user/1000 | grep -q "^drwx------ [0-9]* 1000 1000"'
expect "session output is in its log"           grep -q to-the-log /var/log/session-palm.log
expect "Restart ran /sbin/reboot as root"       grep -q "uid=0" /run/test/powered
expect "the socket is removed on stop"          sh -c '! test -e /run/palm-login.sock'
echo "--- busybox who, from inside the session"; cat /run/test/who.txt
echo "--- busybox last, afterwards"; /run/test/busybox last | tee /run/test/last.txt
expect "who (utmp) lists palm on seat0 during the session" grep -q "^palm  *seat0" /run/test/who.txt
expect "last (wtmp) lists palm's session on seat0"  grep -q "^palm  *seat0" /run/test/last.txt
expect "last (wtmp) has this boot's reboot record"  grep -q "^reboot  *system boot" /run/test/last.txt
expect "utmp's seat0 slot is free again after logout" sh -c '! /run/test/busybox who | grep -q seat0'
expect "lastlog has palm's login (uid 1000's record)" sh -c 'test "$(od -An -tu4 -j $((1000 * 292)) -N4 /var/log/lastlog)" -gt 0'
expect "the wrong password was logged with its count" grep -q 'authentication failure for "palm" (1 in a row' /run/test/daemon1.log
echo "--- the session hook"; cat /run/test/hook.txt
expect "session.d hook ran as palm with the session env" grep -q "^hook uid=1000 .* xdg=/run/user/1000" /run/test/hook.txt
expect "session.d hook is in the session's process group" sh -c 'grep -q "pgid=$(sed -n "s/^session-pid=//p" /run/test/user-session.txt) " /run/test/hook.txt'
expect "session.d hook was ended with the session"   sh -c '! kill -0 "$(cat /run/test/hook.pid)" 2>/dev/null'
expect "session.d skips a file that is not executable" sh -c '! test -e /run/test/not-executable.txt'

echo "=== 2. palm.autologin"
daemon 3 PALM_AUTOLOGIN=palm PALM_DEFAULT_SESSION=/run/test/autosession.sh PALM_GREETER_CMD="/bin/sleep 30"
expect "autologin started the session as palm"  grep -q "uid=1000" /run/test/autologin.txt

echo "=== 3. a greeter that will not exit after start_session"
daemon 13 PALM_GREETER_CMD="/usr/bin/python3 /run/test/stuck-greeter.py"
expect "it was terminated and the session ran"  test -e /run/test/stuck-done

echo "=== 4. the session socket: unlock and power from the session, refusals from outside it"
rm -f /run/test/powered /run/test/session-ready /run/test/session-client.txt /run/test/outsider-*.txt
outsiders() {
	for _ in $(seq 50); do [ -e /run/test/session-ready ] && break; sleep 0.1; done
	# palm again, but not a process of the session (started from here).
	setpriv --reuid=1000 --regid=1000 --clear-groups /usr/bin/python3 /run/test/session-client.py outsider
	# Another user: the socket is palm's, 0600, while palm's session runs.
	setpriv --reuid=900 --regid=900 --clear-groups /usr/bin/python3 /run/test/session-client.py outsider
	ls -ln /run/palm-login.session.sock > /run/test/sock-during.txt
}
outsiders &
daemon 12 PALM_AUTOLOGIN=palm PALM_DEFAULT_SESSION="/usr/bin/python3 /run/test/session-client.py" PALM_GREETER_CMD="/bin/sleep 30" | tee /run/test/daemon4.log
wait
echo "--- what the session and the outsiders saw"; cat /run/test/session-client.txt /run/test/outsider-*.txt; cat /run/test/powered
expect "the session gets PALM_SESSION_SOCK, palm's, 0600"  grep -q "^sock=/run/palm-login.session.sock uid=1000 mode=600" /run/test/session-client.txt
expect "unlock: a wrong password is refused late"          grep -q "^unlock wrong: error auth_error after [1-9]" /run/test/session-client.txt
expect "unlock: the faillock tally is the one doas uses"   test -f /run/faillock/1000
expect "unlock: the right password is accepted"           grep -q "^unlock right: success" /run/test/session-client.txt
expect "power: a dry run from the session is allowed"     grep -q "^power dry run: success" /run/test/session-client.txt
expect "power: palm outside the session is refused"       grep -q "^outsider uid=1000: error only a process of the running session" /run/test/outsider-1000.txt
expect "power: another user cannot even connect"          grep -q "^outsider uid=900: no-connect" /run/test/outsider-900.txt
expect "power: reboot from the session is accepted"       grep -q "^power reboot: success" /run/test/session-client.txt
expect "once ending, the socket answers nothing more"     grep -q "^unlock once ending: error the session is already ending" /run/test/session-client.txt
expect "the session ended, then /sbin/reboot ran as root" sh -c 'grep -q "uid=0" /run/test/powered && grep -n "session of \"palm\" closed\|running /sbin/reboot" /run/test/daemon4.log | head -1 | grep -q closed'
expect "no greeter was started in between"                sh -c '! grep -q "started \[\"/bin/sleep\"" /run/test/daemon4.log'

exit $fail
