#!/bin/bash
# inside.sh <setup|a|b|c> -- the half of the integration run that executes in
# the Arch Linux ARM container, as the container's root. arch-container.sh
# copies it in and calls each phase; read that file first.
#
# Everything pkg does here is real: a real pacman against the ALARM mirrors, a
# real sudo, a real snapper on a real btrfs subvolume. The only stand-ins are
# the ones the container forces, and each is named where it happens.
#
# pkg always runs as the unprivileged user `palm`, exactly as it would on a
# desktop, and reaches root only through the `sudo` at the front of its own
# argv. Two witnesses that pkg does not control record what actually ran:
#   - sudo's own JSON event log (/var/log/sudo.json, `runargv` per command),
#   - pacman's log (/var/log/pacman.log, "Running '...'" per transaction).
# Every real run is compared against the argv pkg printed for the same
# command under --dry-run.
set -uo pipefail

PHASE=${1:?usage: inside.sh <setup|a|b|c>}
SHARED=/srv/it            # bind-mounted from the host's state directory
R=$SHARED/results         # PASS/FAIL lines, appended across phases
STATE=$SHARED/vars        # numbers carried from one container to the next
SUDOLOG=/var/log/sudo.json
PACLOG=/var/log/pacman.log
SIX=(cowsay sl figlet tree fortune-mod lolcat)
SIX_SORTED="cowsay figlet fortune-mod lolcat sl tree"
mkdir -p "$SHARED"; touch "$R" "$STATE"

# ---------------------------------------------------------------- assertions
ok()  { echo "  PASS  $*"; echo "PASS [$PHASE] $*" >> "$R"; }
bad() { echo "  FAIL  $*"; echo "FAIL [$PHASE] $*" >> "$R"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
eq() { if [ "$2" == "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
section() { echo; echo "== $*"; }
var() { grep "^$1=" "$STATE" | tail -1 | cut -d= -f2-; }
setvar() { echo "$1=$2" >> "$STATE"; }

# ---------------------------------------------------------------- running pkg
# No terminal: stdin is /dev/null, which is how an agent runs it.
pkg_agent() { runuser -u palm -- env -C /home/palm pkg "$@" </dev/null; }
# A person at a terminal: a pseudo-terminal from script(1), with a person who
# presses Enter a few times, i.e. takes pacman's default answer to whatever it
# asks. The answers are bounded and the line is then held open: the first
# version piped `yes` in, script(1) buffered the endless input once pkg had
# stopped reading, and grew to 4 GB until the VM's OOM killer took it.
pkg_person() {
	local q; q=$(printf '%q ' "$@")
	local fifo; fifo=$(mktemp -u /tmp/pkg-it-tty.XXXXXX); mkfifo -m 666 "$fifo"
	(sleep 2; for _ in $(seq 1 20); do echo; sleep 0.3; done; exec sleep 900) >"$fifo" &
	local feeder=$! rc
	runuser -u palm -- env -C /home/palm script -qec "pkg $q" /dev/null <"$fifo"; rc=$?
	kill "$feeder" 2>/dev/null; pkill -P "$feeder" 2>/dev/null; rm -f "$fifo"
	return $rc
}
# json <file> <jq filter>
json() { jq -r "$2" "$1" 2>/dev/null; }

# ---------------------------------------------------------------- witnesses
# sudo writes one JSON object with a repeated "accept" key per command, which
# a plain jq read collapses to the last one; the stream form keeps them all.
# One line per command sudo ran, as a JSON array of its argv.
sudo_ran() {
	[ -s "$SUDOLOG" ] || return 0
	jq -n -c --stream 'reduce (inputs | select(length == 2 and .[0][1] == "runargv")) as [$p, $v]
		([]; if $p[2] == 0 then . + [[$v]] else .[-1] += [$v] end) | .[]' "$SUDOLOG"
}
sudo_mark() { sudo_ran | wc -l; }
sudo_since() { sudo_ran | tail -n +$(($1 + 1)); }
pac_running() { grep -o "\[PACMAN\] Running '.*'" "$PACLOG" | sed "s/^\[PACMAN\] Running '//; s/'\$//"; }
pac_mark() { pac_running | wc -l; }
pac_since() { pac_running | tail -n +$(($1 + 1)); }
# The argv pkg planned, minus the leading sudo, one JSON array per step, which
# is the shape sudo logs. Steps that do not go through sudo are kept whole.
planned() { jq -c '.steps[] | .argv | if .[0] == "sudo" then .[1:] else . end' "$1"; }

# A partial upgrade, by the rule in plan.odin: a sync and a refresh without an
# upgrade, in short clusters or long flags, up to the `--` fence.
is_partial_upgrade() {
	local s=0 y=0 u=0 a
	for a in "$@"; do
		[ "$a" == "--" ] && break
		case "$a" in
		--sync) s=1 ;; --refresh) y=1 ;; --sysupgrade) u=1 ;;
		--*) ;;
		-*) [[ $a == *S* ]] && s=1; [[ $a == *y* ]] && y=1; [[ $a == *u* ]] && u=1 ;;
		esac
	done
	[ $s == 1 ] && [ $y == 1 ] && [ $u == 0 ]
}

snap_num_by_desc() { snapper --config root list --columns number,description | awk -F'|' -v d="$1" '{gsub(/^ +| +$/,"",$1); gsub(/^ +| +$/,"",$2); n=$1; gsub(/[-+*]$/,"",n); if ($2==d) print n}' | tail -1; }

# run_real <name> <dry-run json> <real json> <real exit>: the argv sudo saw
# since <mark> must be exactly the planned argv, in order, and nothing else.
argv_matches() {
	local what=$1 plan=$2 mark=$3
	local want got
	want=$(planned "$plan")
	got=$(sudo_since "$mark")
	if [ "$got" == "$want" ]; then
		ok "$what: sudo ran exactly the planned argv ($(echo "$want" | wc -l) command(s))"
	else
		bad "$what: sudo ran something else"
		echo "      planned: $want"; echo "      ran:     $got"
	fi
	echo "$got" | sed 's/^/      ran: /'
}

# ============================================================================
setup() {
	section "setup (the harness, as root -- not pkg)"
	pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinuxarm >/dev/null 2>&1
	check "pacman keyring initialised" test -d /etc/pacman.d/gnupg

	# The container never boots its kernel, so the kernel and firmware are held
	# with IgnorePkg (a standard pacman.conf setting) rather than downloaded.
	sed -i 's/^#\?IgnorePkg *=.*/IgnorePkg = linux-aarch64 linux-firmware/' /etc/pacman.conf

	# A leaf package with an update is held back, so that pkg's own `upgrade`
	# later has real work to do. The update check uses a throwaway database
	# path, as pacman-contrib's checkupdates does, so the real database is never
	# refreshed without an upgrade -- not even by the harness.
	local tmpdb=/tmp/checkupdates-db
	rm -rf "$tmpdb"; mkdir -p "$tmpdb"; ln -s /var/lib/pacman/local "$tmpdb/local"
	pacman -Sy --dbpath "$tmpdb" --logfile /dev/null >/dev/null 2>&1
	local updates; updates=$(pacman -Qqu --dbpath "$tmpdb" 2>/dev/null)
	local leaf=""
	for p in nano dhcpcd openssh less which vi; do
		if echo "$updates" | grep -qx "$p"; then leaf=$p; break; fi
	done
	setvar LEAF "$leaf"
	echo "  held back for pkg upgrade: ${leaf:-<none; the mirror and the image agree>}"
	echo "  $(echo "$updates" | grep -c .) package(s) behind the mirror in the shipped image"

	local ignore=(); [ -n "$leaf" ] && ignore=(--ignore "$leaf")
	pacman -Syu --noconfirm --needed "${ignore[@]}" sudo snapper jq base-devel git gettext \
		limine libnotify inotify-tools xxhash libarchive >/var/log/pkg-it-setup.log 2>&1
	check "setup's full upgrade and tools installed (sudo snapper jq)" pacman -Q sudo snapper jq
	[ -n "$leaf" ] && setvar LEAF_OLD "$(pacman -Q "$leaf" | cut -d' ' -f2)"

	# sudo: passwordless for `palm`, inside this container only. There is no
	# password anywhere in this run; pkg's exec gives sudo the terminal and
	# never reads, stores or passes one, and with no rule like this sudo would
	# stop at "a terminal is required" (checked in phase a).
	id palm >/dev/null 2>&1 || useradd -m palm
	printf 'Defaults logfile=%s\nDefaults log_format=json\npalm ALL=(root) NOPASSWD: ALL\n' "$SUDOLOG" >/etc/sudoers.d/palm
	chmod 440 /etc/sudoers.d/palm
	check "sudoers parses" visudo -c -q

	# snapper on / -- which here is a real btrfs subvolume (@run) of a loopback
	# filesystem, mounted as the container's root.
	check "/ is btrfs" test "$(stat -f -c %T /)" == btrfs
	if [ ! -f /etc/snapper/configs/root ]; then
		snapper --config root create-config / || bad "snapper create-config /"
	fi
	sed -i 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="no"/; s/^NUMBER_LIMIT=.*/NUMBER_LIMIT="100"/' /etc/snapper/configs/root
	check "snapper config root exists on /" snapper --config root list
	check "/.snapshots is a subvolume" bash -c "btrfs subvolume show /.snapshots >/dev/null"

	# limine-snapper-sync: AUR only, built from its PKGBUILD as palm (or taken
	# from the cache of a previous run), installed with pacman -U.
	local cached; cached=$(ls "$SHARED"/cache/limine-snapper-sync-*.pkg.tar.* 2>/dev/null | tail -1)
	if [ -z "$cached" ]; then
		mkdir -p "$SHARED/cache"; chown palm "$SHARED/cache"
		echo "  building limine-snapper-sync from the AUR (several minutes) ..."
		runuser -u palm -- env -C /home/palm bash /usr/local/bin/build-limine-snapper-sync.sh "$SHARED/cache" \
			>/var/log/pkg-it-lss-build.log 2>&1
		cached=$(ls "$SHARED"/cache/limine-snapper-sync-*.pkg.tar.* 2>/dev/null | tail -1)
	fi
	if [ -n "$cached" ]; then
		pacman -U --noconfirm --needed "$cached" >/dev/null 2>&1
	fi
	if pacman -Q limine-snapper-sync >/dev/null 2>&1; then
		ok "limine-snapper-sync installed: $(pacman -Q limine-snapper-sync)"
		# No ESP in a container: /boot is a plain directory holding the kernel
		# and initramfs the image shipped, which is all the tool reads. The
		# entry points at the real filesystem UUID of the loopback btrfs.
		cat >/boot/limine.conf <<-EOC
		timeout: 5

		/Arch Linux ARM
		    //linux-aarch64
		    protocol: linux
		    kernel_path: boot():/Image
		    module_path: boot():/initramfs-linux.img
		    kernel_cmdline: rw rootflags=subvol=/@run root=UUID=${PKG_IT_FSUUID:-unknown}

		    //Snapshots
		EOC
		# /boot is on the same btrfs as everything else here, so the usage limit
		# that guards a small FAT32 partition is lifted, and every entry is kept.
		printf 'ESP_PATH=/boot\nSNAPSHOT_FORMAT_CHOICE=7\nENABLE_NOTIFICATION=no\nLIMIT_USAGE_PERCENT=99\nMAX_SNAPSHOT_ENTRIES=100\n' >/etc/default/limine
		systemctl enable --now limine-snapper-sync.service >/dev/null 2>&1
		check "limine-snapper-sync.service is running" systemctl is-active -q limine-snapper-sync.service
	else
		bad "limine-snapper-sync could not be built or installed (see /var/log/pkg-it-lss-build.log)"
	fi
	# The AUR build above used sudo; the witness log starts empty for pkg.
	rm -f "$SUDOLOG"
	echo "  pacman $(pacman -Q pacman | cut -d' ' -f2), sudo $(pacman -Q sudo | cut -d' ' -f2), snapper $(pacman -Q snapper | cut -d' ' -f2), kernel package $(pacman -Q linux-aarch64 | cut -d' ' -f2)"
}

# ============================================================================
phase_a() {
	local t=/tmp/pkg-it; rm -rf $t; mkdir -p $t; chmod 777 $t

	section "a1. reads, against the real pacman"
	pkg_agent list --json >$t/list.json; eq "pkg list exits 0" $? 0
	eq "pkg list counts what pacman counts" "$(json $t/list.json .installed)" "$(pacman -Qq | wc -l)"
	eq "and the explicit set" "$(json $t/list.json .explicit)" "$(pacman -Qqe | wc -l)"
	pkg_agent search cowsay --json >$t/search.json
	check "pkg search finds extra/cowsay" test "$(json $t/search.json '.results[] | select(.name=="cowsay") | .repo')" == extra
	for p in "${SIX[@]}"; do
		pkg_agent info "$p" --json >$t/info.json
		eq "$p is in the repos and not installed (pkg info)" "$(json $t/info.json '"\(.name) \(.installed)"')" "$p false"
	done

	section "a2. install: the plan, then refusal without --yes"
	local m0 p0; m0=$(sudo_mark); p0=$(pac_mark)
	pkg_agent install "${SIX[@]}" --dry-run --yes --json >$t/install.plan; eq "install --dry-run exits 0" $? 0
	eq "the plan's install argv" "$(jq -c '.steps[1].argv' $t/install.plan)" \
		'["sudo","pacman","-S","--needed","--noconfirm","--","cowsay","figlet","fortune-mod","lolcat","sl","tree"]'
	eq "the plan's snapshot argv, named for the operation" "$(jq -c '.steps[0].argv' $t/install.plan)" \
		"[\"sudo\",\"snapper\",\"--config\",\"root\",\"create\",\"--type\",\"single\",\"--cleanup-algorithm\",\"number\",\"--description\",\"palm pkg install $SIX_SORTED\",\"--print-number\"]"
	pkg_agent install "${SIX[@]}" --json >$t/noyes.json; local c=$?
	eq "install without --yes is refused, exit 4" $c 4
	eq "nothing reached sudo" "$(sudo_mark)" "$m0"
	eq "nothing reached pacman's log" "$(pac_mark)" "$p0"

	section "a3. install, for real, the way an agent runs it (no terminal)"
	m0=$(sudo_mark); p0=$(pac_mark)
	pkg_agent install "${SIX[@]}" --yes --json >$t/install.json 2>$t/install.err; c=$?
	eq "pkg install --yes exits 0" $c 0
	eq "and reports both steps run" "$(json $t/install.json '"\(.executed) \(.steps_run)"')" "true 2"
	argv_matches "install" $t/install.plan "$m0"
	eq "pacman's log shows the same transaction" "$(pac_since "$p0")" "pacman -S --needed --noconfirm -- $SIX_SORTED"
	for p in "${SIX[@]}"; do check "$p is installed ($(pacman -Q $p 2>/dev/null))" pacman -Q "$p"; done
	for p in "${SIX[@]}"; do check "$p is explicitly installed" bash -c "pacman -Qqe | grep -qx $p"; done
	check "cowsay runs" bash -c "cowsay moo | grep -q '< moo >'"
	check "figlet runs" bash -c "figlet palm | grep -q '_'"
	check "fortune runs" bash -c "fortune -s | grep -q ."
	check "tree runs" bash -c "tree --version | grep -q '^tree v'"
	check "lolcat runs" bash -c "echo palm | lolcat -f | grep -q 'm'"
	check "sl is on PATH (it needs a terminal to run)" test -x /usr/bin/sl
	local sn; sn=$(snap_num_by_desc "palm pkg install $SIX_SORTED")
	check "snapper has a snapshot named for the install (#$sn)" test -n "$sn"
	setvar SNAP_INSTALL "$sn"
	check "pkg printed snapper's number on stderr (#$sn)" grep -qx "$sn" $t/install.err

	section "a4. install again: idempotent, nothing runs"
	m0=$(sudo_mark)
	pkg_agent install "${SIX[@]}" --yes --json >$t/again.json; c=$?
	eq "exit 0" $c 0
	eq "class idempotent, all six skipped" "$(json $t/again.json '"\(.class) \(.skipped|length) \(.steps|length)"')" "idempotent 6 0"
	eq "sudo was not reached" "$(sudo_mark)" "$m0"

	section "a5. -Sy without -u stays impossible"
	m0=$(sudo_mark); p0=$(pac_mark)
	pkg_agent install tmux --refresh --yes --json >$t/sy.json; c=$?
	eq "install --refresh is refused, exit 4" $c 4
	eq "by name" "$(json $t/sy.json .reason)" partial-upgrade
	pkg_agent install -- -Sy --yes --json >$t/sy2.json; c=$?
	eq "a flag smuggled in as a name is a usage error, exit 2" $c 2
	pkg_agent install 'tmux -Sy' --yes --json >$t/sy3.json; c=$?
	eq "and so is a name with a flag inside it" $c 2
	eq "none of it reached sudo" "$(sudo_mark)" "$m0"
	eq "or pacman" "$(pac_mark)" "$p0"
	check "tmux was not installed" bash -c "! pacman -Q tmux >/dev/null 2>&1"

	section "a6. without a sudo rule, sudo stops and so does the plan"
	# The real host's case: sudo needs a password and pkg has none to give.
	mv /etc/sudoers.d/palm /root/palm.sudoers
	printf 'Defaults logfile=%s\nDefaults log_format=json\n' "$SUDOLOG" >/etc/sudoers.d/zz-log; chmod 440 /etc/sudoers.d/zz-log
	pkg_agent install tmux --yes --json >$t/nosudo.json 2>$t/nosudo.err; c=$?
	eq "with no password to give, pkg install --yes fails with exit 7" $c 7
	eq "after the first step, the snapshot" "$(json $t/nosudo.json .steps_run)" 0
	check "sudo said why, on the person's stderr" grep -q -i "password\|terminal" $t/nosudo.err
	check "tmux was not installed" bash -c "! pacman -Q tmux >/dev/null 2>&1"
	rm -f /etc/sudoers.d/zz-log; mv /root/palm.sudoers /etc/sudoers.d/palm

	section "a7. the five protected classes, against packages really installed"
	# ly is installed first so the display-manager class has something real
	# to protect. Installing a protected package is allowed; removing is not.
	m0=$(sudo_mark)
	pkg_agent install ly --yes --json >$t/ly.json; eq "install ly (a display manager) for real" $? 0
	check "ly is installed" pacman -Q ly
	local boot=mkinitcpio; pacman -Q limine-snapper-sync >/dev/null 2>&1 && boot="mkinitcpio limine limine-snapper-sync"
	declare -A CLASS=([linux-aarch64]=kernel [linux-firmware]=kernel [ly]=display-manager [systemd]=init [dbus]=init [pacman]=core [glibc]=core [sudo]=core [snapper]=core [btrfs-progs]=core)
	for b in $boot; do CLASS[$b]=bootloader; done
	for p in "${!CLASS[@]}"; do
		pacman -Q "$p" >/dev/null 2>&1 || { echo "      (skipped $p: not installed in this image)"; continue; }
		m0=$(sudo_mark)
		pkg_agent remove "$p" --yes --json >$t/prot.json; c=$?
		eq "remove $p --yes: refused as protected:${CLASS[$p]} (exit $c)" "$(json $t/prot.json .reason) $c" "protected:${CLASS[$p]} 4"
		eq "  nothing reached sudo, and $p is still installed" "$(sudo_mark) $(pacman -Qq $p)" "$m0 $p"
	done
	m0=$(sudo_mark)
	pkg_agent remove linux-aarch64 --yes --allow-protected init --json >$t/prot2.json
	eq "allowing a different class does not unlock the kernel" "$(json $t/prot2.json .reason)" protected:kernel
	pkg_agent remove ly --allow-protected display-manager --json >$t/prot3.json; c=$?
	eq "allowing the class without --yes does not either: the class refusal stands" "$c $(json $t/prot3.json .reason)" "4 protected:display-manager"
	eq "nothing reached sudo" "$(sudo_mark)" "$m0"
	pkg_agent remove ly --yes --allow-protected display-manager --dry-run --json >$t/ly-rm.plan
	m0=$(sudo_mark)
	pkg_agent remove ly --yes --allow-protected display-manager --json >$t/ly-rm.json; c=$?
	eq "with its own --allow-protected and --yes, the door opens: exit 0" $c 0
	argv_matches "remove ly" $t/ly-rm.plan "$m0"
	check "ly is gone" bash -c "! pacman -Q ly >/dev/null 2>&1"

	section "a8. dependants, read from the real pacman -Qi"
	m0=$(sudo_mark)
	pkg_agent remove ruby --json >$t/dep.json; c=$?
	eq "remove ruby without --yes: exit 4, has-dependants" "$c $(json $t/dep.json .reason)" "4 has-dependants"
	check "and names lolcat among them ($(json $t/dep.json .detail))" grep -q lolcat <<<"$(json $t/dep.json .detail)"
	eq "nothing reached sudo" "$(sudo_mark)" "$m0"
	pkg_agent remove ruby --yes --dry-run --json >$t/dep.plan
	pkg_agent remove ruby --yes --json >$t/dep2.json 2>$t/dep2.err; c=$?
	eq "with --yes pkg runs -R, and pacman itself refuses to break lolcat: exit 7" $c 7
	argv_matches "remove ruby" $t/dep.plan "$m0"
	check "pacman said it would break a dependency" grep -q "breaks dependency" $t/dep2.err
	check "ruby is still installed" pacman -Q ruby

	section "a9. remove, for real"
	pkg_agent remove sl cowsay --yes --dry-run --json >$t/rm.plan
	m0=$(sudo_mark); p0=$(pac_mark)
	pkg_agent remove sl cowsay --yes --json >$t/rm.json; c=$?
	eq "remove sl cowsay --yes: exit 0" $c 0
	eq "the plan" "$(jq -c '.steps[1].argv' $t/rm.plan)" '["sudo","pacman","-R","--noconfirm","--","cowsay","sl"]'
	argv_matches "remove" $t/rm.plan "$m0"
	eq "pacman's log agrees" "$(pac_since "$p0")" "pacman -R --noconfirm -- cowsay sl"
	check "cowsay and sl are gone" bash -c "! pacman -Q cowsay >/dev/null 2>&1 && ! pacman -Q sl >/dev/null 2>&1"
	check "snapper has 'palm pkg remove cowsay sl'" test -n "$(snap_num_by_desc 'palm pkg remove cowsay sl')"
	pkg_agent remove lolcat --recursive --yes --dry-run --json >$t/rs.plan
	m0=$(sudo_mark)
	pkg_agent remove lolcat --recursive --yes --json >$t/rs.json; c=$?
	eq "remove lolcat --recursive --yes: exit 0" $c 0
	argv_matches "remove -Rs" $t/rs.plan "$m0"
	check "lolcat is gone, and ruby with it as an orphan" bash -c "! pacman -Q lolcat >/dev/null 2>&1 && ! pacman -Q ruby >/dev/null 2>&1"

	section "a10. sync toward a declaration"
	local d=/home/palm/.config/palm/packages; local f=$d/it.pkgs
	runuser -u palm -- mkdir -p $d; rm -f $f
	pkg_agent declare cowsay sl tree --file $f --json >/dev/null
	check "declare wrote the file and installed nothing" bash -c "test -f $f && ! pacman -Q cowsay >/dev/null 2>&1"
	pkg_agent diff --file $f --json >$t/diff.json
	eq "diff: cowsay and sl are missing" "$(json $t/diff.json '.missing|join(" ")')" "cowsay sl"
	pkg_agent sync --file $f --dry-run --json >$t/sync.plan
	eq "the sync plan installs exactly what is missing" "$(jq -c '.steps[1].argv' $t/sync.plan)" '["sudo","pacman","-S","--needed","--noconfirm","--","cowsay","sl"]'
	m0=$(sudo_mark)
	pkg_agent sync --file $f --yes --json >$t/sync.json; c=$?
	eq "sync --yes: exit 0" $c 0
	argv_matches "sync" $t/sync.plan "$m0"
	check "cowsay and sl are back" pacman -Q cowsay sl
	m0=$(sudo_mark)
	pkg_agent sync --file $f --yes --json >$t/sync2.json
	eq "sync again: idempotent, nothing reached sudo" "$(json $t/sync2.json .class) $(sudo_mark)" "idempotent $m0"
	pkg_agent sync --file $f --prune --yes --json >$t/prune.json; c=$?
	eq "sync --prune against a 3-package declaration is refused, protected:kernel first" "$c $(json $t/prune.json .reason)" "4 protected:kernel"
	eq "nothing reached sudo" "$(sudo_mark)" "$m0"
	# A declaration of everything explicit except figlet: prune removes figlet.
	local f2=$d/all-but-figlet.pkgs; rm -f $f2
	pkg_agent declare $(pacman -Qqe | grep -vx figlet) --file $f2 --json >/dev/null
	pkg_agent sync --file $f2 --prune --yes --dry-run --json >$t/prune.plan
	eq "the prune plan removes figlet and nothing else" "$(jq -c '[.steps[] | select(.what=="remove") | .argv]' $t/prune.plan)" '[["sudo","pacman","-R","--noconfirm","--","figlet"]]'
	m0=$(sudo_mark)
	pkg_agent sync --file $f2 --prune --yes --json >$t/prune2.json; c=$?
	eq "sync --prune --yes: exit 0" $c 0
	argv_matches "sync --prune" $t/prune.plan "$m0"
	check "figlet is gone" bash -c "! pacman -Q figlet >/dev/null 2>&1"

	section "a11. upgrade: refused to an agent, run for a person"
	m0=$(sudo_mark)
	pkg_agent upgrade --yes --json >$t/up.json; c=$?
	eq "no terminal: refused with exit 4 even with --yes" "$c $(json $t/up.json .reason)" "4 needs-a-person"
	eq "nothing reached sudo" "$(sudo_mark)" "$m0"
	local leaf; leaf=$(var LEAF)
	pkg_person upgrade >$t/up.tty 2>&1; c=$?
	eq "at a terminal, pkg upgrade exits 0" $c 0
	local got; got=$(sudo_since "$m0")
	eq "sudo ran the snapshot, then pacman -Syu, and nothing else" "$got" \
		"$(printf '%s\n%s' '["snapper","--config","root","create","--type","single","--cleanup-algorithm","number","--description","palm pkg upgrade","--print-number"]' '["pacman","-Syu"]')"
	if [ -n "$leaf" ]; then
		check "the held-back $leaf was upgraded ($(var LEAF_OLD) -> $(pacman -Q $leaf | cut -d' ' -f2))" test "$(pacman -Q $leaf | cut -d' ' -f2)" != "$(var LEAF_OLD)"
	fi
	check "nothing is left to upgrade but the ignored kernel" bash -c "! pacman -Qu 2>/dev/null | grep -v '\[ignored\]' | grep -q ."
	check "snapper has 'palm pkg upgrade'" test -n "$(snap_num_by_desc 'palm pkg upgrade')"

	section "a12. rollback on this layout (/ is the plain subvolume @run)"
	local si; si=$(var SNAP_INSTALL)
	m0=$(sudo_mark)
	pkg_agent rollback "$si" --yes --json >$t/rb.json; c=$?
	eq "no terminal: refused, needs-a-person" "$c $(json $t/rb.json .reason)" "4 needs-a-person"
	pkg_person rollback "$si" --yes --json >$t/rb2.json 2>&1; c=$?
	check "palm cannot read snapper's list, so the mount table decides: rollback-layout" grep -q '"reason": "rollback-layout"' $t/rb2.json
	check "and the refusal names the snapshot" grep -q "\"$si\"" $t/rb2.json
	eq "nothing reached sudo" "$(sudo_mark)" "$m0"
	snapper --config root rollback "$si" >$t/snapper-rb.out 2>&1; c=$?
	eq "snapper itself, asked directly, agrees: it exits 1 on this layout" $c 1
	check "with 'Cannot detect ambit'" grep -q "Cannot detect ambit" $t/snapper-rb.out

	section "a13. snapshots: a read that needs snapper's permission"
	pkg_agent snapshots --json >$t/snaps.json; c=$?
	eq "as palm with no ALLOW_USERS: unavailable, exit 6 (what the old host saw)" $c 6
	snapper --config root set-config ALLOW_USERS=palm
	pkg_agent snapshots --json >$t/snaps.json; c=$?
	eq "with ALLOW_USERS=palm: exit 0" $c 0
	eq "the install snapshot is listed as palm's" "$(json $t/snaps.json ".snapshots[] | select(.number==$si) | \"\(.from_palm) \(.description)\"")" "true palm pkg install $SIX_SORTED"
	eq "palm took these" "$(json $t/snaps.json '[.snapshots[] | select(.from_palm) | .description] | join("; ")')" \
		"$(snapper --config root list --columns description | grep '^palm pkg ' | sed 's/ *$//' | paste -sd';' | sed 's/;/; /g')"
	pkg_person rollback 999 --yes --json >$t/rb3.json 2>&1
	check "now that palm can read the list, an unknown snapshot is refused by name" grep -q '"reason": "unknown-snapshot"' $t/rb3.json
	pkg_person rollback "$si" --yes --json >$t/rb4.json 2>&1
	check "and the list decides the layout: rollback-layout" grep -q '"reason": "rollback-layout"' $t/rb4.json

	section "a14. limine-snapper-sync and palm-named snapshots"
	if pacman -Q limine-snapper-sync >/dev/null 2>&1; then
		sleep 3
		local n
		for desc in "palm pkg install $SIX_SORTED" "palm pkg remove cowsay sl" "palm pkg sync cowsay sl" "palm pkg upgrade"; do
			n=$(snap_num_by_desc "$desc")
			check "a Limine boot entry exists for #$n '$desc'" grep -q "///$n│$desc\$" /boot/limine.conf
			check "  and boots that snapshot's subvolume" grep -q "rootflags=subvol=/@run/.snapshots/$n/snapshot " /boot/limine.conf
		done
		grep -E '^ *///' /boot/limine.conf | sed 's/^ */      /'
		pkg_agent remove limine-snapper-sync --yes --json >$t/lss.json
		eq "pkg will not remove limine-snapper-sync: protected:bootloader" "$(json $t/lss.json .reason)" protected:bootloader
	else
		bad "limine-snapper-sync is not installed; its half was not checked"
	fi

	section "a15. across everything that ran: no partial upgrade"
	local n=0 e=0 line
	while read -r line; do
		[ -z "$line" ] && continue
		mapfile -t argv < <(echo "$line" | jq -r '.[]')
		n=$((n + 1))
		if is_partial_upgrade "${argv[@]}"; then bad "partial upgrade reached sudo: $line"; e=$((e + 1)); fi
		[ "${argv[0]}" == pacman ] || [ "${argv[0]}" == snapper ] || { bad "sudo ran something that is not pacman or snapper: $line"; e=$((e + 1)); }
	done < <(sudo_ran)
	eq "$n commands reached sudo in phase a; none was a partial upgrade, all were pacman or snapper" "$e" 0
	local m=0
	e=0
	while read -r line; do
		m=$((m + 1))
		# shellcheck disable=SC2086
		if is_partial_upgrade $line; then bad "partial upgrade in pacman's log: $line"; e=$((e + 1)); fi
	done < <(pac_running)
	eq "$m transactions in pacman's log (setup included); none was a partial upgrade" "$e" 0
	check "the self-check can fail: it flags 'pacman -S -y -- x'" is_partial_upgrade pacman -S -y -- x

	section "a16. preparing the openSUSE layout for phase b"
	# snapper rollback needs the default subvolume to be a snapper snapshot.
	# A writable snapshot of this system becomes the default, and the next
	# container boots from it, as openSUSE boots from @/.snapshots/1/snapshot.
	local base; base=$(snapper --config root create --read-write --type single --description "palm-it: boot base" --print-number)
	setvar BASE "$base"
	btrfs subvolume set-default "/.snapshots/$base/snapshot" >/dev/null
	check "the default subvolume is now snapshot #$base" bash -c "btrfs subvolume get-default / | grep -q '.snapshots/$base/snapshot'"
}

# ============================================================================
phase_b() {
	local t=/tmp/pkg-it; rm -rf $t; mkdir -p $t; chmod 777 $t
	local base si; base=$(var BASE); si=$(var SNAP_INSTALL)
	section "b1. booted from snapshot #$base (the openSUSE layout)"
	check "/ is mounted from .snapshots/$base/snapshot" bash -c "findmnt -no FSROOT / | grep -q '/.snapshots/$base/snapshot\$'"
	snapper --config root list | tail -n +3 | sed 's/^/      /'
	pkg_agent snapshots --json >$t/snaps.json; eq "pkg snapshots exits 0" $? 0
	eq "snapper's marked row (#$base) is read, as default and active" \
		"$(json $t/snaps.json ".snapshots[] | select(.number==$base) | \"\(.default) \(.active)\"")" "true true"

	section "b2. rollback to before the install, for real"
	local m0; m0=$(sudo_mark)
	pkg_person rollback "$si" --yes >$t/rb.out 2>&1; local c=$?
	eq "pkg rollback $si --yes at a terminal exits 0" $c 0
	eq "sudo ran exactly snapper rollback $si" "$(sudo_since "$m0")" "[\"snapper\",\"--config\",\"root\",\"rollback\",\"$si\"]"
	sed 's/^/      /' $t/rb.out | grep -v '^\s*$' | tail -8
	local def; def=$(btrfs subvolume get-default / | grep -o '.snapshots/[0-9]*/snapshot' | cut -d/ -f2)
	check "the default subvolume moved to a new snapshot (#$def)" test -n "$def" -a "$def" != "$base"
	check "which snapper describes as a writable copy of #$si" bash -c "snapper --config root list --columns number,description | grep -q 'writable copy of #$si'"
	setvar ROLLED "$def"
	check "the running system is untouched until the next boot (tree, installed after #$si, is still here)" pacman -Q tree
}

# ============================================================================
phase_c() {
	local rolled si; rolled=$(var ROLLED); si=$(var SNAP_INSTALL)
	section "c1. the 'reboot': booted from the rolled-back snapshot #$rolled"
	check "/ is mounted from .snapshots/$rolled/snapshot" bash -c "findmnt -no FSROOT / | grep -q '/.snapshots/$rolled/snapshot\$'"
	for p in "${SIX[@]}"; do check "$p is not installed: the system is as it was before 'palm pkg install'" bash -c "! pacman -Q $p >/dev/null 2>&1"; done
	check "the tools installed before that snapshot are still here" pacman -Q sudo snapper jq
	local t=/tmp/pkg-it; mkdir -p $t; chmod 777 $t
	# This snapshot predates ALLOW_USERS, so the list is read as root.
	pkg snapshots --json >$t/snaps.json </dev/null
	eq "pkg snapshots marks #$rolled default and active" "$(json $t/snaps.json ".snapshots[] | select(.number==$rolled) | \"\(.default) \(.active)\"")" "true true"
	pkg_agent install cowsay --dry-run --yes --json >$t/plan.json
	eq "and pkg plans from this machine's state: cowsay is missing again" "$(jq -c '.steps[1].argv' $t/plan.json)" '["sudo","pacman","-S","--needed","--noconfirm","--","cowsay"]'
}

case "$PHASE" in
setup) setup ;;
a) phase_a ;;
b) phase_b ;;
c) phase_c ;;
*) echo "unknown phase $PHASE" >&2; exit 2 ;;
esac
exit 0
