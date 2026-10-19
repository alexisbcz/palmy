#!/usr/bin/env bash
# Build packages from pinned upstream source into clean staging prefixes.
#
#	distro/recipes/runtime/src/build.sh [name...]     (default: every *.build)
#
# Each <name>.build next to this script pins one upstream release: its URL,
# the sha256 of the tarball, its licence, the other source builds it needs at
# build time, and a build() function. The driver
#
#   1. downloads the tarball once into distro/build/src/dl/ and refuses it
#      unless its sha256 is the pinned one;
#   2. unpacks it into an empty distro/build/src/work/<name>/;
#   3. merges the staging trees of its build dependencies into a private
#      sysroot (deps/), rewriting their .pc files to point there, so nothing
#      from an earlier build of anything else leaks in;
#   4. runs build() under `env -i` with a fixed PATH, LC_ALL=C, TZ=UTC,
#      SOURCE_DATE_EPOCH and -ffile-prefix-map, installing with DESTDIR into
#      distro/build/src/stage/<name>/ (headers and all: what dependants link
#      against);
#   5. copies the runtime subset (no headers, static libraries, pkg-config,
#      libtool archives, manuals) into distro/out/src/<name>/, stripped, which
#      is what the generated PALMBUILD packs.
#
# `auto=no` in a .build keeps it out of the default set (build it by name).
# A build is skipped when its stamp matches the sha256 of its .build file and
# of every dependency's stamp, so editing a .build rebuilds it and everything
# downstream, and nothing else. The compiler is the build host's (gcc and
# binutils from Arch); building the toolchain itself is the next step, not
# this one (distro/notes/runtime.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO="$(cd "$HERE/../../.." && pwd)"
BUILD="${PALMFRAME_SRC_BUILD:-$DISTRO/build/src}"
OUT="${PALMFRAME_SRC_OUT:-$DISTRO/out/src}"
JOBS="${JOBS:-8}"
mkdir -p "$BUILD/dl" "$BUILD/work" "$BUILD/stage" "$OUT"

say() { echo "src: $*" >&2; }

# spec <name> <var>: one variable from a .build file, read in a subshell so
# specs cannot see each other.
spec() { (set +u; source "$HERE/$1.build"; eval "printf '%s' \"\${$2:-}\""); }

stamp_of() { # the stamp a fresh build of <name> would write
	local n="$1" d s
	s="$(sha256sum "$HERE/$n.build" | cut -d' ' -f1)"
	for d in $(spec "$n" builddeps); do
		s="$s $(cat "$BUILD/stage/$d.stamp" 2>/dev/null || echo missing)"
	done
	printf '%s' "$s" | sha256sum | cut -d' ' -f1
}

fetch() { # fetch <name>: the verified tarball's path on stdout
	local n="$1" url sum file
	url="$(spec "$n" url)"
	sum="$(spec "$n" sha256)"
	file="$BUILD/dl/$(spec "$n" distfile)"
	[ "$file" != "$BUILD/dl/" ] || file="$BUILD/dl/${url##*/}"
	if [ ! -f "$file" ] || ! echo "$sum  $file" | sha256sum -c --quiet >/dev/null 2>&1; then
		say "$n: downloading $url"
		curl -fL --retry 3 -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	if ! echo "$sum  $file" | sha256sum -c --quiet >/dev/null 2>&1; then
		say "$n: sha256 mismatch for $file (want $sum, got $(sha256sum "$file" | cut -d' ' -f1))"
		rm -f "$file"
		exit 1
	fi
	echo "$file"
}

# runtime_tree <stage> <out>: what a package ships out of a staging tree.
runtime_tree() {
	local stage="$1" out="$2" f
	rm -rf "$out"
	mkdir -p "$out"
	cp -a "$stage/." "$out/"
	rm -rf "$out/usr/include" "$out/usr/lib/pkgconfig" "$out/usr/share/pkgconfig" \
		"$out/usr/share/man" "$out/usr/share/doc" "$out/usr/share/info" \
		"$out/usr/share/aclocal" "$out/usr/lib/cmake" "$out/usr/share/gtk-doc" \
		"$out/usr/lib/systemd" "$out/usr/lib/sysusers.d" "$out/usr/lib/tmpfiles.d" \
		"$out/usr/share/bash-completion" "$out/usr/share/zsh" "$out/usr/share/fish" \
		"$out/usr/share/xml/dbus-1" "$out/usr/share/locale" "$out/usr/share/ffmpeg/examples"
	find "$out" \( -name '*.a' -o -name '*.la' \) -delete
	# Development symlinks (libfoo.so -> libfoo.so.1): only the soname is
	# what the loader asks for.
	find "$out" -type l -name 'lib*.so' -delete
	find "$out" -type f | while read -r f; do
		if head -c4 "$f" | grep -q 'ELF'; then
			strip --strip-unneeded "$f" 2>/dev/null || true
		fi
	done
	# Empty directories left by the deletions.
	find "$out" -mindepth 1 -type d -empty -delete
}

build_one() {
	local n="$1" want have tarball work deps d
	[ -f "$HERE/$n.build" ] || { say "no $n.build"; exit 1; }
	for d in $(spec "$n" builddeps); do build_one "$d"; done
	want="$(stamp_of "$n")"
	have="$(cat "$BUILD/stage/$n.stamp" 2>/dev/null || true)"
	if [ "$want" = "$have" ] && [ -d "$BUILD/stage/$n" ]; then
		# Up to date. The runtime tree is cheap, so it is always made
		# again: a change to runtime_tree applies without a rebuild.
		package_one "$n"
		return 0
	fi
	tarball="$(fetch "$n")"
	work="$BUILD/work/$n"
	say "$n $(spec "$n" version): building in $work"
	rm -rf "$work" "$BUILD/stage/$n" "$BUILD/stage/$n.stamp"
	mkdir -p "$work/src" "$work/deps" "$BUILD/stage/$n"
	tar -xf "$tarball" -C "$work/src" --strip-components=1

	# The private sysroot: hard links to the dependencies' staging trees,
	# with pkg-config files copied and pointed at it.
	deps="$work/deps"
	for d in $(spec "$n" builddeps); do
		cp -al "$BUILD/stage/$d/." "$deps/" 2>/dev/null || cp -a "$BUILD/stage/$d/." "$deps/"
	done
	if [ -d "$deps/usr/lib/pkgconfig" ]; then
		for pc in "$deps"/usr/lib/pkgconfig/*.pc; do
			sed "s|^prefix=/usr|prefix=$deps/usr|" "$pc" >"$pc.new"
			rm -f "$pc"
			mv "$pc.new" "$pc"
		done
	fi

	local flags="-O2 -pipe -fstack-protector-strong -fno-plt -ffile-prefix-map=$work=."
	(
		cd "$work/src"
		env -i \
			HOME="$work" TMPDIR="$work" LC_ALL=C TZ=UTC \
			PATH="$deps/usr/bin:/usr/bin" \
			SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}" \
			CFLAGS="$flags" CXXFLAGS="$flags" \
			CPPFLAGS="-I$deps/usr/include" \
			LDFLAGS="-L$deps/usr/lib -Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now" \
			PKG_CONFIG_PATH="$deps/usr/lib/pkgconfig" \
			JOBS="$JOBS" DESTDIR="$BUILD/stage/$n" DEPS="$deps" \
			bash -euo pipefail -c "source '$HERE/$n.build'; build" \
			>"$work/build.log" 2>&1
	) || {
		say "$n: build failed; last lines of $work/build.log:"
		tail -30 "$work/build.log" >&2
		exit 1
	}
	echo "$want" >"$BUILD/stage/$n.stamp"
	package_one "$n"
	say "$n: done"
}

package_one() {
	local n="$1"
	[ "$(spec "$n" package)" != no ] || return 0
	runtime_tree "$BUILD/stage/$n" "$OUT/$n"
	spec "$n" version >"$OUT/$n.version"
}

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
	# Everything but the prototypes marked auto=no (glibc), which are built
	# only when named.
	for f in "$HERE"/*.build; do
		n="$(basename "$f" .build)"
		[ "$(spec "$n" auto)" = no ] || names+=("$n")
	done
fi
for n in "${names[@]}"; do build_one "$n"; done
