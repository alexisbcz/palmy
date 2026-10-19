# Sourced by distro/recipes/generate.sh (inside its "runtime" block), which
# provides HERE, DISTRO, ROOT, OWN_VER, header, emit and host_version.
#
# The runtime dependencies the applications need beyond glibc: the system
# bus, Wi-Fi, audio, Bluetooth, media, TLS and archives
# (distro/notes/runtime.md). Two kinds of package are written here:
#
#   src   built from a pinned, checksummed upstream tarball by
#         runtime/src/build.sh into distro/out/src/<name>/ (ffmpeg, opus,
#         dbus, iwd, libarchive).
#   host  copied from the build host's Arch packages, file list from
#         `pacman -Ql`, version, licence and URL from `pacman -Qi`
#         (pipewire, wireplumber, bluez, openssl, wl-clipboard, ...).
#
# Every ELF file's DT_NEEDED is resolved against what the packages (these and
# every other recipe) install. A library nobody installs is pulled in from
# the host package that owns it, as a package of the same name holding just
# the libraries asked for -- so the closure is complete by construction, and
# no two packages ever claim the same file. Libraries another recipe already
# ships (glibc's, e2fsprogs' libblkid) are depended on, not copied.
#
# Hand-written files a package adds (service definitions, configuration,
# small wrappers) live in runtime/files/<package>/ under their target path.

RT="$HERE/runtime"
RT_MARK="from the runtime manifest (distro/recipes/runtime)"
RT_SRC_OUT="$DISTRO/out/src"

# Build what is missing or out of date (a no-op when every stamp matches).
if [ "${PALMFRAME_SKIP_SRC:-0}" != 1 ]; then
	"$RT/src/build.sh"
fi

# --- the manifest -------------------------------------------------------------
# host_pkg <name> <arch packages> <keep regex> <drop regex>
# src_pkg  <name> <runtime/src/*.build name>
declare -A RT_KIND RT_FROM RT_KEEP RT_DROP RT_DEPEND RT_DESC RT_CAT RT_ICON RT_DETAILS RT_VER RT_LIC RT_URL
RT_PKGS=()
host_pkg() { RT_PKGS+=("$1"); RT_KIND[$1]=host; RT_FROM[$1]="$2"; RT_KEEP[$1]="${3:-.}"; RT_DROP[$1]="${4:-^$}"; }
src_pkg() { RT_PKGS+=("$1"); RT_KIND[$1]=src; RT_FROM[$1]="$2"; }

src_pkg dbus dbus
src_pkg iwd iwd
src_pkg opus opus
src_pkg ffmpeg ffmpeg
src_pkg libarchive libarchive

# PipeWire as the audio server, WirePlumber as its session manager, the
# PulseAudio protocol (pipewire-pulse) for pactl, which the mixer reads.
# Left out: the plugins that pull large codec, filter and network stacks
# (Bluetooth audio codecs beyond SBC, the filter graph and its FFT and
# loudness libraries, WebRTC echo cancellation, LV2, SOFA,
# AVB/AES67, RTP, ROC, JACK, libcamera, Vulkan) and journald/systemd glue.
host_pkg pipewire "pipewire libpipewire pipewire-audio" . \
	'/libspa-(journal|aec-webrtc|avb|filter-graph|codec-bluez5-(aac|aptx|ldac|lc3|hfp-lc3|hfp-msbc|opus|faststream|g722))|/filter-graph/|module-(avb|netjack2|rtp-|vban-|roc|raop|echo-cancel|filter-chain|parametric-equalizer)|/pipewire-(aes67|avb)|/pw-(container|dsdplay|encplay|midi|sysex)|/spa-(acp-tool|resample)|/alsa-lib/|/etc/alsa/|/usr/share/alsa/'
host_pkg pipewire-pulse "pipewire-pulse libpulse" . \
	'/padsp|/libpulsedsp|/libpulse-mainloop-glib|/pacat$|/pamon$|/paplay$|/parec$|/parecord$|/glib-2.0/schemas/|/media-session.d/'
host_pkg wireplumber "wireplumber libwireplumber" . '/module-(modem-manager|mpris|logind|portal-permissionstore)\.so$|/wpexec$'
host_pkg alsa-card-profiles "alsa-card-profiles"
host_pkg alsa-lib "alsa-lib" . '/usr/lib/alsa-lib/'
# BlueZ: bluetoothd and bluetoothctl; the rest of bluez-utils is test tooling.
host_pkg bluez "bluez bluez-utils" '^/etc/|/bluetoothd$|/bluetoothctl$|/btmgmt$|/usr/share/dbus-1/system\.d/|/licenses/' '/modprobe\.d/|/modules-load\.d/'
# rfkill from util-linux: the bluetooth applet runs `rfkill list bluetooth`.
host_pkg rfkill "util-linux" '^/usr/bin/rfkill$'
host_pkg openssl "openssl" . '/etc/ssl/misc/|\.dist$|/c_rehash$|/engines-3/(capi|padlock)\.so$'
# The bundle is generated on the host by update-ca-trust (owned by no
# package); version and licence are those of the Mozilla trust store it is
# made from.
host_pkg ca-certificates "ca-certificates-mozilla" '^$'
host_pkg wl-clipboard "wl-clipboard"
# ollama, for ai and chatbot. Optional: 66 MB without a model, and not in
# palmframe-runtime. CPU backends only (the host has no GPU ones installed).
host_pkg ollama "ollama"

declare -A RT_DIRS RT_HOSTFILES
# Host files outside any package's file list: "<host path>:<target path>",
# symlinks followed.
RT_HOSTFILES[ca-certificates]="/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt"
RT_DIRS[iwd]="/var/lib/iwd:0700"
RT_DIRS[bluez]="/var/lib/bluetooth:0700"

RT_DEPEND[pipewire]="alsa-card-profiles alsa-lib"
RT_DEPEND[pipewire-pulse]="pipewire"
RT_DEPEND[wireplumber]="pipewire"
RT_DEPEND[bluez]="dbus"
RT_DEPEND[iwd]="dbus"
RT_DEPEND[openssl]="ca-certificates"

RT_DESC[pipewire]="Audio and video server: the daemon, its ALSA backend and pw-cat/pw-play/pw-record"
RT_DESC[pipewire-pulse]="PulseAudio server on PipeWire, and pactl"
RT_DESC[wireplumber]="Session manager for PipeWire, and wpctl"
RT_DESC[bluez]="Bluetooth daemon (bluetoothd) and bluetoothctl"
RT_DESC[rfkill]="Enable and disable wireless devices (from util-linux)"
RT_DESC[ca-certificates]="Mozilla's CA certificate bundle, as one PEM file"
RT_DESC[wl-clipboard]="Command-line copy and paste for Wayland: wl-copy, wl-paste"
RT_CAT[pipewire]=Multimedia; RT_ICON[pipewire]=audio-lines
RT_CAT[wireplumber]=Multimedia; RT_ICON[wireplumber]=sliders-horizontal
RT_CAT[pipewire-pulse]=Multimedia; RT_ICON[pipewire-pulse]=volume-2
RT_CAT[ffmpeg]=Multimedia; RT_ICON[ffmpeg]=film
RT_CAT[bluez]=System; RT_ICON[bluez]=bluetooth
RT_CAT[iwd]=System; RT_ICON[iwd]=wifi
RT_CAT[dbus]=System; RT_ICON[dbus]=network
RT_CAT[wl-clipboard]=Accessories; RT_ICON[wl-clipboard]=clipboard
RT_CAT[libarchive]=System; RT_ICON[libarchive]=archive
RT_DETAILS[pipewire]="The sound server. palm-login starts it in every graphical session (/etc/palm/session.d/50-pipewire), and it starts WirePlumber and the PulseAudio server itself."
RT_DETAILS[iwd]="Wi-Fi: scans, connects and runs DHCP on wireless interfaces itself. iwctl is the command line; the configuration is in /etc/iwd/main.conf."
RT_DETAILS[dbus]="The system message bus that iwd and BlueZ register on. Built from source without systemd."
RT_DETAILS[bluez]="The Bluetooth stack's daemon, bluetoothd, and bluetoothctl to pair and connect devices."
RT_DETAILS[ffmpeg]="Decodes nearly every audio and video format, encodes H.264, AAC, Opus, PNG and more. The audio, video and video editing applications use it. Built from source with its own codecs plus libx264 and libopus."

# --- what the other recipes already install --------------------------------------
# dest path -> package, from every PALMBUILD this block did not write.
declare -A RT_OWNER
for r in "$HERE"/*/PALMBUILD; do
	grep -q "$RT_MARK" "$r" && continue
	p="$(basename "$(dirname "$r")")"
	while IFS= read -r line; do
		case "$line" in
		file*=*'->'*)
			d="${line##*-> }"; d="${d%% mode *}"; RT_OWNER[$d]="$p" ;;
		symlink*=*'->'*)
			d="${line#*= }"; d="${d%% -> *}"; RT_OWNER[$d]="$p" ;;
		esac
	done < <(grep -E '^(file|symlink) ' "$r")
done

# --- collecting the files -----------------------------------------------------------
# RT_ENT["pkg|dest"] = "f|<src>|<mode>" or "l|<target>"; RT_LIST[pkg] = dests.
declare -A RT_ENT RT_LIST RT_PULLED_SONAMES
RT_DEV_RE='^/usr/include/|^/usr/share/(man|doc|info|locale|gtk-doc|bash-completion|zsh|fish|vala|gir-1\.0|aclocal|pkgconfig|installed-tests)/|^/usr/lib/(pkgconfig|cmake|systemd|sysusers\.d|tmpfiles\.d|udev|girepository-1\.0)/|\.a$|\.la$|^/usr/lib/[^/]*\.so$'

rt_add() { # rt_add <pkg> <dest> <host path to read>
	local p="$1" d="$2" s="$3"
	[ -n "${RT_ENT[$p|$d]:-}" ] && return 0
	if [ -L "$s" ]; then
		RT_ENT[$p|$d]="l|$(readlink "$s")"
	elif [ -f "$s" ]; then
		if [ ! -r "$s" ]; then
			echo "recipes: runtime: $p: $s is not readable, left out" >&2
			return 0
		fi
		RT_ENT[$p|$d]="f|$s|$(stat -c %a "$s")"
	else
		return 0
	fi
	RT_LIST[$p]+="$d"$'\n'
	RT_OWNER[$d]="$p"
}

rt_meta() { # rt_meta <pkg> <arch pkg>: version, licence, url from pacman
	local info
	info="$(LC_ALL=C pacman -Qi "$2")"
	# The version as palm accepts it: Arch's "1:0.9rc3-2" -> 0.9 (the
	# numeric prefix), where host_version would give up.
	RT_VER[$1]="${RT_VER[$1]:-$(pacman -Q "$2" | awk '{print $2}' | sed 's/^[0-9]*://; s/-[^-]*$//' | grep -oE '^[0-9]+(\.[0-9]+)*')}"
	# pacman separates licences by two spaces; one licence may itself
	# contain single spaces ("GPL-3.0-or-later WITH GCC-exception-3.1").
	RT_LIC[$1]="${RT_LIC[$1]:-$(echo "$info" | sed -n 's/^Licenses *: *//p' | sed -E 's/ {2,}/ AND /g')}"
	RT_URL[$1]="${RT_URL[$1]:-$(echo "$info" | sed -n 's/^URL *: *//p')}"
	RT_DESC[$1]="${RT_DESC[$1]:-$(echo "$info" | sed -n 's/^Description *: *//p')}"
}

for p in "${RT_PKGS[@]}"; do
	if [ "${RT_KIND[$p]}" = src ]; then
		n="${RT_FROM[$p]}"
		t="$RT_SRC_OUT/$n"
		[ -d "$t" ] || { echo "recipes: runtime: $t missing (runtime/src/build.sh $n)" >&2; exit 1; }
		while IFS= read -r f; do rt_add "$p" "${f#"$t"}" "$f"; done < <(find "$t" ! -type d | LC_ALL=C sort)
		RT_VER[$p]="$(cat "$RT_SRC_OUT/$n.version")"
		RT_LIC[$p]="$( (source "$RT/src/$n.build"; echo "$license") )"
		RT_URL[$p]="$( (source "$RT/src/$n.build"; echo "${upstream:-$url}") )"
		RT_DESC[$p]="${RT_DESC[$p]:-$( (source "$RT/src/$n.build"; echo "$pkgdesc") )}"
	else
		for a in ${RT_FROM[$p]}; do
			rt_meta "$p" "$a"
			while IFS= read -r f; do
				rt_add "$p" "$f" "$f"
			done < <(pacman -Qlq "$a" | grep -v '/$' | grep -Ev "$RT_DEV_RE" |
				grep -E "${RT_KEEP[$p]}" | grep -Ev "${RT_DROP[$p]}" | LC_ALL=C sort)
		done
	fi
	for hf in ${RT_HOSTFILES[$p]:-}; do
		rt_add "$p" "${hf#*:}" "$(readlink -f "${hf%%:*}")"
	done
	if [ -d "$RT/files/$p" ]; then
		while IFS= read -r f; do
			d="${f#"$RT/files/$p"}"
			unset "RT_ENT[$p|$d]"
			rt_add "$p" "$d" "$f"
		done < <(find "$RT/files/$p" ! -type d | LC_ALL=C sort)
	fi
done

# --- closing over DT_NEEDED ---------------------------------------------------------
# rt_elf_needed <file>: "<soname> <runpath dirs...>" lines, nothing for non-ELF.
rt_is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }
declare -A RT_DEPS
rt_pkg_for_arch() { # the palm name a pulled Arch package gets
	local a="$1"
	if [ -f "$HERE/$a/PALMBUILD" ] && ! grep -q "$RT_MARK" "$HERE/$a/PALMBUILD"; then
		echo "$a-libs"
	else
		echo "$a"
	fi
}
rt_queue=("${RT_PKGS[@]}")
declare -A RT_SCANNED
while [ ${#rt_queue[@]} -gt 0 ]; do
	p="${rt_queue[0]}"
	rt_queue=("${rt_queue[@]:1}")
	while IFS= read -r d; do
		[ -z "$d" ] && continue
		[ -n "${RT_SCANNED[$p|$d]:-}" ] && continue
		RT_SCANNED[$p|$d]=1
		e="${RT_ENT[$p|$d]}"
		[ "${e%%|*}" = f ] || continue
		s="${e#f|}"; s="${s%|*}"
		rt_is_elf "$s" || continue
		dyn="$(LC_ALL=C readelf -d "$s" 2>/dev/null)" || continue
		runpath="$(echo "$dyn" | sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p' | tr ':' ' ')"
		runpath="${runpath//\$ORIGIN/$(dirname "$d")}"
		for so in $(echo "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
			found=""
			for dir in $runpath /usr/lib; do
				if [ -n "${RT_OWNER[$dir/$so]:-}" ]; then found="${RT_OWNER[$dir/$so]}"; break; fi
			done
			if [ -z "$found" ]; then
				for dir in $runpath /usr/lib; do
					[ -e "$dir/$so" ] || continue
					a="$(pacman -Qqo "$dir/$so" 2>/dev/null | head -1)"
					[ -n "$a" ] || continue
					found="$(rt_pkg_for_arch "$a")"
					if [ -z "${RT_KIND[$found]:-}" ]; then
						RT_KIND[$found]=pulled
						RT_FROM[$found]="$a"
						RT_PKGS+=("$found")
						rt_meta "$found" "$a"
						RT_DESC[$found]="${RT_DESC[$found]} (libraries only)"
					fi
					real="$(readlink -f "$dir/$so")"
					rt_add "$found" "$real" "$real"
					rt_add "$found" "$dir/$so" "$dir/$so"
					rt_queue+=("$found")
					break
				done
			fi
			if [ -z "$found" ]; then
				echo "recipes: runtime: $p: $d needs $so, which nothing provides" >&2
				exit 1
			fi
			[ "$found" != "$p" ] && RT_DEPS[$p]+=" $found"
		done
	done <<<"${RT_LIST[$p]:-}"
done

# --- writing the recipes --------------------------------------------------------------
for p in "${RT_PKGS[@]}"; do
	deps="$(echo ${RT_DEPS[$p]:-} ${RT_DEPEND[$p]:-} | tr ' ' '\n' | { grep -v '^$' || true; } | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
	[ -n "$deps" ] || deps=glibc
	provides=""
	while IFS= read -r d; do
		[ -z "$d" ] && continue
		case "$d" in
		/usr/bin/*) provides+=" cmd:${d#/usr/bin/}" ;;
		/usr/lib/*.so*)
			# A library on the loader's path provides its SONAME when the
			# package also installs that name (the file or its link).
			case "${d#/usr/lib/}" in */*) continue ;; esac
			e="${RT_ENT[$p|$d]}"
			[ "${e%%|*}" = f ] || continue
			s="${e#f|}"; s="${s%|*}"
			soname="$(LC_ALL=C readelf -d "$s" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')" || true
			if [ -n "$soname" ] && [ -n "${RT_ENT[$p|/usr/lib/$soname]:-}" ]; then
				provides+=" so:$soname"
			fi
			;;
		esac
	done <<<"${RT_LIST[$p]:-}"
	{
		header " $RT_MARK"
		case "${RT_KIND[$p]}" in
		src) echo "#"; echo "# Built from source: distro/recipes/runtime/src/${RT_FROM[$p]}.build, packed from"; echo "# distro/out/src/${RT_FROM[$p]}." ;;
		host) echo "#"; echo "# Copied from the build host's Arch packages: ${RT_FROM[$p]}." ;;
		pulled) echo "#"; echo "# Libraries from the build host's Arch package ${RT_FROM[$p]}, only those another"; echo "# runtime package links (pulled in by DT_NEEDED)." ;;
		esac
		echo "pkgname  = $p"
		echo "pkgver   = ${RT_VER[$p]}"
		echo "pkgrel   = 0"
		if [ "${RT_KIND[$p]}" = src ]; then
			echo "pkgdesc  = ${RT_DESC[$p]}"
		else
			echo "pkgdesc  = ${RT_DESC[$p]} (from the build host)"
		fi
		echo "license  = ${RT_LIC[$p]:-unknown}"
		[ -n "${RT_URL[$p]:-}" ] && echo "url      = ${RT_URL[$p]}"
		echo "category = ${RT_CAT[$p]:-System}"
		echo "icon     = ${RT_ICON[$p]:-package}"
		[ -n "${RT_DETAILS[$p]:-}" ] && echo "details  = ${RT_DETAILS[$p]}"
		echo "depend   = $deps"
		[ -n "$provides" ] && echo "provides =$provides"
		echo
		for dm in ${RT_DIRS[$p]:-}; do echo "dir      = ${dm%%:*} mode ${dm#*:}"; done
		while IFS= read -r d; do
			[ -z "$d" ] && continue
			e="${RT_ENT[$p|$d]}"
			if [ "${e%%|*}" = l ]; then
				echo "symlink  = $d -> ${e#l|}"
			else
				s="${e#f|}"; m="${s##*|}"; s="${s%|*}"
				case "$s" in
				"$RT_SRC_OUT"/*) s="\${PALMFRAME_OUT}/src/${s#"$RT_SRC_OUT"/}" ;;
				"$ROOT"/*) s="\${PALMFRAME_ROOT}/${s#"$ROOT"/}" ;;
				esac
				printf 'file     = %s -> %s mode %04o\n' "$s" "$d" "0$m"
			fi
		done < <(printf '%s' "${RT_LIST[$p]:-}" | LC_ALL=C sort -u)
	} | emit "$p"
done

# --- the applications these make work --------------------------------------------------
# Packaged here because nothing else packages them yet; an application whose
# recipe another block already writes is left to it. Each depends on the
# runtime packages it runs (they are subprocesses, not links, so the
# DT_NEEDED closure cannot see them). Binaries are distro/out/bin/<app>,
# which distro/Makefile builds for every recipe that names one -- on the
# make run after the recipe first appears.
declare -A RT_APP_DEPS=(
	[audio]="ffmpeg pipewire" [video]="ffmpeg pipewire" [videoedit]="ffmpeg pipewire"
	[mixer]="wireplumber pipewire-pulse" [bluetooth]="bluez rfkill"
	[archive]="libarchive" [call]="opus ffmpeg pipewire wireplumber pipewire-pulse"
	[mail]="mailcore" [mailcore]="openssl" [ocr]="openssl"
	[clipboard]="wl-clipboard" [vault]="wl-clipboard" [ai]="ollama"
)
declare -A RT_APP_DESC=(
	[audio]="Music and audio player" [video]="Video player" [videoedit]="Video editor"
	[mixer]="Volume control" [bluetooth]="Bluetooth devices" [archive]="Archive manager"
	[call]="Audio and video calls" [mail]="Email" [mailcore]="IMAP and SMTP engine behind mail"
	[ocr]="Text from images and PDFs (Mistral OCR)" [clipboard]="Clipboard history"
	[vault]="Password store" [ai]="Chat with a local model through ollama"
)
declare -A RT_APP_CAT=(
	[audio]=Multimedia [video]=Multimedia [videoedit]=Multimedia [mixer]=Multimedia
	[bluetooth]=System [archive]=Accessories [call]=Internet [mail]=Internet
	[mailcore]=Internet [ocr]=Office [clipboard]=Accessories [vault]=Accessories [ai]=Accessories
)
declare -A RT_APP_ICON=(
	[audio]=music [video]=clapperboard [videoedit]=scissors [mixer]=volume-2
	[bluetooth]=bluetooth [archive]=archive [call]=phone [mail]=mail [mailcore]=mail
	[ocr]=scan-text [clipboard]=clipboard [vault]=key-round [ai]=bot
)
RT_APPS=()
for app in $(printf '%s\n' "${!RT_APP_DEPS[@]}" | LC_ALL=C sort); do
	if [ -f "$HERE/$app/PALMBUILD" ] && ! grep -q "$RT_MARK" "$HERE/$app/PALMBUILD"; then
		continue
	fi
	RT_APPS+=("$app")
	desktop=""
	if [ -f "$DISTRO/apps/desktop/$app.desktop" ]; then
		desktop="\${PALMFRAME_ROOT}/distro/apps/desktop/$app.desktop"
	elif [ -f "$RT/desktop/$app.desktop" ]; then
		desktop="\${PALMFRAME_ROOT}/distro/recipes/runtime/desktop/$app.desktop"
	fi
	{
		header " $RT_MARK"
		cat <<EOF
#
# Built by distro/apps/build.sh into distro/out/bin/$app.
pkgname  = $app
pkgver   = $OWN_VER
pkgrel   = 0
pkgdesc  = ${RT_APP_DESC[$app]}
license  = MIT
category = ${RT_APP_CAT[$app]}
icon     = ${RT_APP_ICON[$app]}
depend   = glibc fonts libxkbcommon ${RT_APP_DEPS[$app]}
provides = cmd:$app

file     = \${PALMFRAME_OUT}/bin/$app -> /usr/bin/$app mode 0755
EOF
		if [ -n "$desktop" ]; then
			echo "file     = $desktop -> /usr/share/applications/$app.desktop mode 0644"
		fi
	} | emit "$app"
done

# --- palmframe-runtime: the services a desktop expects --------------------------------
{
	header " $RT_MARK"
	cat <<EOF
#
# The system bus, Wi-Fi, sound, Bluetooth, media, TLS and archives: what the
# applications beyond the default set run. Not the applications themselves,
# and not ollama.
pkgname  = palmframe-runtime
pkgver   = $OWN_VER
pkgrel   = 0
pkgdesc  = System services and runtime libraries: D-Bus, iwd, PipeWire, BlueZ, FFmpeg, OpenSSL
license  = MIT
category = System
icon     = layers
details  = Installs and starts the system bus, Wi-Fi (iwd), Bluetooth (bluetoothd) and, in each graphical session, the sound server (PipeWire with WirePlumber and the PulseAudio protocol). Brings FFmpeg, OpenSSL with the CA certificates, bsdtar and wl-clipboard for the applications that use them.
depend   = dbus iwd bluez rfkill pipewire wireplumber pipewire-pulse
depend   = ffmpeg opus openssl ca-certificates libarchive wl-clipboard
EOF
} | emit palmframe-runtime

# A package this manifest no longer produces (a plugin dropped, a library no
# longer linked) loses its recipe, so the repository does not keep it.
declare -A RT_WROTE
for p in "${RT_PKGS[@]}" "${RT_APPS[@]}" palmframe-runtime; do RT_WROTE[$p]=1; done
for r in "$HERE"/*/PALMBUILD; do
	grep -q "$RT_MARK" "$r" || continue
	p="$(basename "$(dirname "$r")")"
	[ -n "${RT_WROTE[$p]:-}" ] && continue
	rm -f "$r"
	rmdir "$(dirname "$r")" 2>/dev/null || true
	echo "recipes: removed $p"
done
