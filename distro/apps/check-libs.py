"""Every library a shipped binary links must come with the package.

    python3 -I distro/apps/check-libs.py        (make -C distro check-libs)

For each distro/out/bin/<name> a recipe installs, the libraries it names in
DT_NEEDED must be glibc's (libc, libm, the loader) or provided (`so:<name>`)
by a package the recipe depends on, directly or through its dependencies.
Most palmy programs link only glibc; call (libopus), mailcore and ocr
(OpenSSL) depend on the runtime packages that ship theirs.
"""

import os
import re
import subprocess
import sys

DISTRO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECIPES = os.path.join(DISTRO, "recipes")
BIN = os.path.join(DISTRO, "out", "bin")
GLIBC = {"libc.so.6", "libm.so.6", "ld-linux-x86-64.so.2"}

depends, provides, bins = {}, {}, {}
for name in sorted(os.listdir(RECIPES)):
    path = os.path.join(RECIPES, name, "PALMBUILD")
    if not os.path.isfile(path):
        continue
    deps, provs = [], set()
    for line in open(path, encoding="utf-8"):
        key, _, val = line.partition("=")
        key = key.strip()
        if key == "pkgname":
            name = val.strip()
        elif key == "depend":
            deps += val.split()
        elif key == "provides":
            provs |= {p[3:] for p in val.split() if p.startswith("so:")}
        elif key == "file":
            m = re.match(r"\s*\$\{PALMY_OUT\}/bin/(\S+)\s+->", val)
            if m:
                bins[m.group(1)] = name
    depends[name], provides[name] = deps, provs


def closure(pkg):
    seen, todo = set(), [pkg]
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        todo += depends.get(p, [])
    return seen


bad = 0
for binary, pkg in sorted(bins.items()):
    path = os.path.join(BIN, binary)
    if not os.path.isfile(path):
        continue
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    needed = re.findall(r"\(NEEDED\).*\[(.*)\]", out)
    allowed = set(GLIBC)
    for p in closure(pkg):
        allowed |= provides.get(p, set())
    for lib in needed:
        if lib not in allowed:
            print(f"check-libs: {binary} ({pkg}) needs {lib}, which no package it depends on provides")
            bad = 1
print("check-libs: every binary's libraries come with its dependencies" if not bad else "check-libs: FAILED")
sys.exit(bad)
