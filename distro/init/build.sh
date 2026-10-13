#!/bin/sh
# Build palm-init into distro/out/bin/palm-init, statically linked.
#
# Static, because PID 1 should not depend on the dynamic loader and a glibc
# that `palm upgrade` can replace underneath it. palm-init reads /etc/passwd
# and /etc/group itself, so a static glibc's missing NSS costs nothing.
#
#	distro/init/build.sh            build
#	distro/init/build.sh --test     build, then run the parser selftest
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
mkdir -p distro/out/bin

odin build distro/init -o:speed \
	-collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn \
	-extra-linker-flags:-static \
	-out:distro/out/bin/palm-init

if [ "${1:-}" = "--test" ]; then
	distro/out/bin/palm-init --selftest
fi
