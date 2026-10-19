#!/bin/sh
# doas and passwd, setuid root for real, without root and without touching
# the host: a user namespace makes this script root over a range of subuids,
# so a file it owns with mode 4755 really runs as (namespace) root when uid
# 1000 executes it; a private mount namespace puts a tmpfs over /run and a
# fixture /etc over /etc. A small syslog (syslog.py) listens where glibc's
# syslog(3) sends, and a pty driver (pty.py) types the passwords.
#
#   distro/doas/e2e/run.sh
#
# Needs distro/out/bin/{doas,passwd,palm-login} (distro/login/build.sh),
# newuidmap and a subuid range (unshare --map-auto), setpriv and python3.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BIN="$ROOT/distro/out/bin"

if [ "${PALM_E2E_INSIDE:-}" != 1 ]; then
	for b in doas passwd palm-login; do
		[ -x "$BIN/$b" ] || { echo "build first: distro/login/build.sh" >&2; exit 1; }
	done
	export PALM_HASH="$("$BIN/palm-login" --hash palm)"
	export PALM_E2E_INSIDE=1
	exec unshare --user --map-root-user --map-auto --mount --propagation private "$0"
fi

# --- inside the namespaces from here on ---
mount -t tmpfs -o mode=0755 none /run
E=/run/e2e
mkdir -p $E/etc $E/bin $E/home/palm $E/home/guest
cp "$BIN/doas" "$BIN/passwd" $E/bin/
cp "$HERE/pty.py" "$HERE/syslog.py" $E/
chmod 4755 $E/bin/doas $E/bin/passwd
chown 1000:1000 $E/home/palm
chown 1001:1001 $E/home/guest
chmod 755 $E $E/bin $E/home

H="$PALM_HASH"
cat >$E/etc/passwd <<EOF
root:x:0:0:root:/root:/bin/sh
palm:x:1000:1000:Palm:$E/home/palm:/bin/sh
guest:x:1001:1001:Guest:$E/home/guest:/bin/sh
EOF
cat >$E/etc/group <<EOF
root:x:0:root
wheel:x:10:root,palm
palm:x:1000:
guest:x:1001:
EOF
cat >$E/etc/shadow <<EOF
root:$H:19000:0:99999:7:::
palm:$H:19000:0:99999:7:::
guest:$H:19000:0:99999:7:::
EOF
chmod 600 $E/etc/shadow
cp "$ROOT/distro/doas/doas.conf" $E/etc/doas.conf
chmod 644 $E/etc/passwd $E/etc/group $E/etc/doas.conf
mount --bind $E/etc /etc

LOG=/run/syslog.txt
# /dev/log is usually a symlink into /run (systemd); listen where it points.
DEVLOG=/dev/log
[ -L /dev/log ] && DEVLOG="$(readlink /dev/log)"
python3 -I $E/syslog.py "$DEVLOG" $LOG &
SYSLOG=$!
trap 'kill $SYSLOG 2>/dev/null || true' EXIT
for _ in $(seq 50); do [ -e $LOG ] && break; sleep 0.1; done

fail=0
pass=0
expect() { # expect <description> <command...>
	d="$1"; shift
	if "$@" >/dev/null 2>&1; then echo "pass  $d"; pass=$((pass + 1)); else echo "FAIL  $d"; fail=1; fi
}
# as <user> <answers...> -- <command...>: run on a pty as that user; the
# transcript is in /run/out.txt.
as() {
	u="$1"; shift
	setpriv --reuid="$u" --regid="$u" --init-groups -- python3 -I $E/pty.py "$@" >/run/out.txt 2>&1 || true
	sed 's/^/    | /' /run/out.txt
}
out() { grep -q -- "$1" /run/out.txt; }
noout() { ! grep -q -- "$1" /run/out.txt; }
logged() { grep -q -- "$1" $LOG; }
reset_tally() { rm -f /run/faillock/*; }
field() { awk -F: -v u="$1" -v n="$2" '$1 == u { print $n }' /etc/shadow; }
locked() { case "$(field "$1" 2)" in "!"*) return 0 ;; esac; return 1; }
unlocked() { ! locked "$1"; }
TODAY=$(( $(date +%s) / 86400 ))

echo "=== doas"
as palm -a palm -- $E/bin/doas id
expect "palm (wheel) runs id as root with the right password" out "uid=0(root) gid=0(root)"
expect "it asked once, as 'doas (palm@host) password:'" out "prompts=1"
expect "the grant is logged to authpriv" logged "palm ran command as root from .*: id"

as palm -a wrong -- $E/bin/doas id
expect "a wrong password is refused" out "Authentication failed"
expect "...and the command did not run" noout "uid=0"
expect "...and the failure is logged" logged "authentication failure for palm (1 in a row"

as guest -a palm -- $E/bin/doas id
expect "guest (not wheel) is refused without being asked" out "prompts=0"
expect "...with Operation not permitted" out "Operation not permitted"
expect "...and logged" logged "command not permitted for guest as root: id"
mkdir -p /run/rootonly && touch /run/rootonly/x && chmod 755 /run/rootonly/x && chmod 700 /run/rootonly
as guest -- $E/bin/doas /run/rootonly/x
r1=$(grep doas: /run/out.txt)
as guest -- $E/bin/doas /run/rootonly/nothere
r2=$(grep doas: /run/out.txt)
expect "guest cannot use doas to probe which root-only paths exist" test "$r1" = "$r2"

reset_tally
as palm -a wrong -- $E/bin/doas id
as palm -a wrong -- $E/bin/doas id
as palm -a wrong -- $E/bin/doas id
as palm -a palm -- $E/bin/doas id
expect "after three failures the right password is refused unasked" out "too many failed attempts; try again in"
expect "...without even asking" out "prompts=0"
expect "...and the refusal is logged" logged "refused palm unchecked"
sleep 2
as palm -a palm -- $E/bin/doas id
expect "once the wait is over it works" out "uid=0(root)"
reset_tally

as palm -a palm -- env FOO=bar LD_PRELOAD=/nonexistent.so PATH=/tmp/evil:/usr/bin TERM=xterm $E/bin/doas env
expect "env: the caller's FOO is dropped" noout "^FOO="
expect "env: LD_PRELOAD is dropped" noout "LD_PRELOAD"
expect "env: PATH is the safe one" out "^PATH=/usr/local/bin:/usr/bin:/bin"
expect "env: HOME, USER are root's; DOAS_USER is palm" sh -c 'grep -q "^HOME=/root" /run/out.txt && grep -q "^USER=root" /run/out.txt && grep -q "^DOAS_USER=palm" /run/out.txt'
expect "env: TERM is kept" out "^TERM=xterm"

mkdir -p /run/evil && printf '#!/bin/sh\necho PLANTED\n' >/run/evil/id && chmod 755 /run/evil/id
as palm -a palm -- env PATH=/run/evil:/usr/bin $E/bin/doas id
expect "a planted id earlier in the caller's PATH is not what runs" sh -c 'grep -q "uid=0" /run/out.txt && ! grep -q PLANTED /run/out.txt'

as palm -a palm -- $E/bin/doas -u guest id
expect "-u guest runs as guest, with guest's groups" out "uid=1001(guest) gid=1001(guest) groups=1001(guest)"

as palm -- $E/bin/doas -n id
expect "-n refuses when a password would be needed" out "Authentication required"
expect "...without asking" out "prompts=0"

setpriv --reuid=1000 --regid=1000 --init-groups -- $E/bin/doas -n id </dev/null >/run/out.txt 2>&1 || true
expect "no terminal, no password: refused" out "Authentication required"
setpriv --reuid=1000 --regid=1000 --init-groups -- sh -c "$E/bin/doas id </dev/null" >/run/out.txt 2>&1 || true
expect "no controlling terminal: refused, not read from stdin" out "none could be read from a terminal"

as palm -a palm -- sh -c "$E/bin/doas true >&- 2>&-; echo rc=\$?"
expect "stdout and stderr closed: still runs (fds 0-2 are reopened)" out "rc=0"

cp /etc/doas.conf /run/doas.conf.good
chmod 666 /etc/doas.conf
as palm -a palm -- $E/bin/doas id
expect "a doas.conf others may write is refused" out "writable by group or others"
chmod 644 /etc/doas.conf
chown 1000 /etc/doas.conf
as palm -a palm -- $E/bin/doas id
expect "a doas.conf not owned by root is refused" out "not owned by root"
chown 0 /etc/doas.conf
mv /etc/doas.conf /etc/doas.conf.real && ln -s doas.conf.real /etc/doas.conf
as palm -a palm -- $E/bin/doas id
expect "a symlinked doas.conf is refused" sh -c 'grep -q ELOOP /run/out.txt && ! grep -q uid=0 /run/out.txt'
rm /etc/doas.conf && mv /etc/doas.conf.real /etc/doas.conf
printf 'permit :wheel\npermit nonsense here\n' >/etc/doas.conf
as palm -a palm -- $E/bin/doas id
expect "a syntax error anywhere refuses everything" out "syntax error at line 2"

printf 'permit persist :wheel\n' >/etc/doas.conf
as palm -a palm -- sh -c "$E/bin/doas id -u; $E/bin/doas id -u; $E/bin/doas -L; $E/bin/doas id -u"
expect "persist: a second doas in the same session does not ask; -L forgets" out "prompts=2"
as palm -a palm -- sh -c "$E/bin/doas true"
as palm -- sh -c "$E/bin/doas -n id -u"
expect "persist: another terminal session must authenticate itself" out "Authentication required"

printf 'permit nopass palm cmd id args -u\ndeny guest\n' >/etc/doas.conf
as palm -- $E/bin/doas id -u
expect "nopass + cmd + args: allowed without a password" sh -c 'grep -q "^0$" /run/out.txt && grep -q prompts=0 /run/out.txt'
as palm -- $E/bin/doas id
expect "...but not with other arguments" out "Operation not permitted"
cp /run/doas.conf.good /etc/doas.conf

echo "=== passwd"
reset_tally
as palm -a wrong -- $E/bin/passwd
expect "passwd: a wrong current password is refused" out "Authentication failed"
expect "...and changes nothing" test "$(field palm 2)" = "$H"
as palm -a palm -a abc -a newpass1 -a newpass1 -- $E/bin/passwd
expect "passwd: too short is refused, then a good one is set" sh -c 'grep -q "too short" /run/out.txt && grep -q "password updated" /run/out.txt'
expect "passwd: the shadow line has a new hash and today's date" test "$(field palm 3)" = "$TODAY" -a "$(field palm 2)" != "$H"
expect "...a fresh SHA-512 crypt hash" sh -c "awk -F: '\$1 == \"palm\" && \$2 ~ /^\\\$6\\\$/' /etc/shadow | grep -q ."
expect "passwd: root's line is untouched" grep -qxF "root:$H:19000:0:99999:7:::" /etc/shadow
expect "passwd: guest's line is untouched" grep -qxF "guest:$H:19000:0:99999:7:::" /etc/shadow
expect "passwd: shadow stays root's, 0600" sh -c 'stat -c "%a %u" /etc/shadow | grep -qx "600 0"'
expect "passwd: the old file is kept as shadow-" grep -qF "palm:$H:" /etc/shadow-
expect "passwd: no shadow+ is left behind" test ! -e /etc/shadow+
expect "passwd: logged" logged "password of palm changed by palm"
as palm -a palm -- $E/bin/doas true
expect "the old password no longer works for doas" out "Authentication failed"
reset_tally
as palm -a newpass1 -- $E/bin/doas id -u
expect "the new one does" out "^0"

as palm -a newpass1 -- $E/bin/passwd guest
expect "passwd: palm may not change guest's password" out "only root may change another user's password"
as palm -- $E/bin/passwd -l guest
expect "passwd: palm may not lock an account" out "only root may"

as palm -a newpass1 -a short -a short -a short -- $E/bin/passwd
expect "passwd: three refused new passwords give up, unchanged" sh -c 'grep -q "password unchanged" /run/out.txt'

as palm -a newpass1 -a another1 -a another2 -a another1 -a another1 -- $E/bin/passwd
expect "passwd: a mismatched retype asks again" sh -c 'grep -q "did not match" /run/out.txt && grep -q "password updated" /run/out.txt'

# A hard limit can only be raised by real root (CAP_SYS_RESOURCE in the
# initial namespace), which namespace root is not: here it shows the other
# half, that a write cut short is caught and the old file stays whole.
cp /etc/shadow /run/shadow.before
as palm -a another1 -a newpass2 -a newpass2 -- sh -c "ulimit -f 0; $E/bin/passwd"
expect "passwd: a file-size limit it cannot lift: refused, shadow intact" sh -c 'grep -q "write failed" /run/out.txt && cmp -s /etc/shadow /run/shadow.before && ! test -e /etc/shadow+'
as palm -a another1 -a newpass2 -a newpass2 -- sh -c "ulimit -S -f 0; $E/bin/passwd"
expect "passwd: a soft file-size limit of 0 is lifted" sh -c 'grep -q "password updated" /run/out.txt && test "$(wc -l </etc/shadow)" = 3'

touch /etc/shadow+
as palm -a newpass2 -a newpass3 -a newpass3 -- $E/bin/passwd
expect "passwd: a fresh shadow+ (busybox at work) is waited for, then refused" sh -c 'grep -q "another program is changing it" /run/out.txt && test -e /etc/shadow+'
touch -d '5 minutes ago' /etc/shadow+
as palm -a newpass2 -a newpass3 -a newpass3 -- $E/bin/passwd
expect "passwd: a stale shadow+ (a crash) is cleared" sh -c 'grep -q "password updated" /run/out.txt && ! test -e /etc/shadow+'

as root -a rootpass1 -a rootpass1 -- $E/bin/passwd guest
expect "passwd: root sets guest's password without the old one" sh -c 'grep -q "password updated" /run/out.txt && grep -q prompts=2 /run/out.txt'
as root -- $E/bin/passwd -l guest
expect "passwd -l: guest is locked" locked guest
as guest -a rootpass1 -- $E/bin/passwd
expect "passwd: a locked account cannot change its password" out "Authentication failed"
as root -- $E/bin/passwd -S guest
expect "passwd -S: shows L" out "^guest L "
as root -- $E/bin/passwd -u guest
expect "passwd -u: unlocked" unlocked guest

as root -- $E/bin/passwd -e palm
expect "passwd -e: palm must change at next login" test "$(field palm 3)" = 0
reset_tally
as palm -a newpass3 -- $E/bin/doas id
expect "doas refuses an expired password" out "your password has expired"
as palm -a newpass3 -a newpass4 -a newpass4 -- $E/bin/passwd
expect "...and passwd lets it be changed" out "password updated"
as palm -a newpass4 -- $E/bin/doas id -u
expect "...after which doas works again" out "^0"

echo "=== $pass passed, $fail failed (as a flag: 1 means at least one FAIL)"
exit $fail
