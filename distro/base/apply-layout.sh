#!/bin/sh
# Install the palmy-base skeleton into a root directory:
#
#	distro/base/apply-layout.sh <rootdir>
#
# copies distro/base/root/ into <rootdir>, then applies distro/base/layout —
# the directories, merged-/usr symlinks, modes and owners that a plain file
# tree in git cannot carry. Run it under fakeroot (in the same fakeroot
# session as whatever archives <rootdir>) so the owners stick.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest=${1:?usage: apply-layout.sh <rootdir>}
mkdir -p "$dest"

# Layout first, so the merged-/usr symlinks exist before anything is copied
# through them.
while read -r kind path a b; do
	case "$kind" in
	'' | '#'*) continue ;;
	dir)
		mkdir -p "$dest/$path"
		chmod "$a" "$dest/$path"
		if [ -n "${b:-}" ]; then chown "$b" "$dest/$path"; fi
		;;
	symlink)
		if [ ! -L "$dest/$path" ]; then
			mkdir -p "$(dirname "$dest/$path")"
			ln -s "$a" "$dest/$path"
		fi
		;;
	mode | owner) ;; # after the copy
	*) echo "apply-layout: unknown line: $kind $path" >&2; exit 1 ;;
	esac
done < "$here/layout"

cp -R --no-preserve=ownership "$here/root/." "$dest/"
chown -R 0:0 "$dest/etc" "$dest/usr" 2>/dev/null || true

while read -r kind path a b; do
	case "$kind" in
	mode) chmod "$a" "$dest/$path" ;;
	owner) chown "$a" "$dest/$path" ;;
	dir) if [ -n "${b:-}" ]; then chown "$b" "$dest/$path"; fi ;;
	*) ;;
	esac
done < "$here/layout"

# The demo user's home, as the palmy-demo package makes it on the disk
# image: a copy of /etc/skel owned by palm (1000). The boot tests built on
# this script log in as palm.
if [ ! -d "$dest/home/palm" ]; then
	cp -R "$dest/etc/skel" "$dest/home/palm"
	chmod 0700 "$dest/home/palm"
	chown -R 1000:1000 "$dest/home/palm" 2>/dev/null || true
fi
