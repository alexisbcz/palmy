# palm, the package manager — notes from the palm side

Owner of this file: the agent that built `distro/palm/`.

## Build and test

```
mkdir -p distro/out/bin
odin build distro/palm -o:speed -out:distro/out/bin/palm
distro/out/bin/palm --selftest        # from the repo root; ~500 assertions, < 1 s
```

Pure Odin; `ldd` shows libc, libm and the loader only. No collections needed
(it imports nothing from palmy/kit/shadcn), so the CONTRACT's standard build
line works too.

## The CLI as built

```
palm add <pkg>...         install, record in world. <pkg> is a name, a constraint
                          (foo>=1.2, foo=1.2, foo~1.2, foo<2) or a path to a .palm
                          (a local file needs --allow-untrusted)
palm del <pkg>...         drop from world; removes it and every orphan
palm update               fetch (http) and verify every repository index
palm upgrade              resolve the world preferring newest versions
palm search <text>...     case-insensitive, names and descriptions; exit 3 if nothing
palm info <pkg>...        details (installed record, else newest available)
palm info -L <pkg>        file list (reads the .palm if not installed)
palm info --who-owns <path>
palm list [--installed|--upgradable|--available]     default: everything, marked
palm verify [<pkg>...]    sha256/type/mode/link target of every recorded file; exit 1 on problems
palm fix [<pkg>...]       reinstall the same version of broken (or named) packages
palm build <dir> -o <outdir>          <dir>/PALMBUILD -> <outdir>/<name>-<ver>-r<rel>.palm
palm index <dir> --key <name>.sec     <dir>/PALMINDEX + PALMINDEX.sig (no --key: unsigned, warns)
palm keygen <name>                    <name>.sec (0600) and <name>.pub
palm --selftest | --version | help

global (anywhere on the line, --flag=value also accepted):
  --root <dir>        operate on another root (default /)
  --initdb            create /usr/lib/palm/db/installed, /etc/palm/world,
                      /etc/palm/keys, /var/cache/palm under --root if missing
  --repo <url|path>   repeatable; replaces /etc/palm/repositories entirely
  --keys-dir <dir>    trusted keys (default <root>/etc/palm/keys)
  --allow-untrusted   accept an unsigned/unverifiable index (NOT a sha256 mismatch)
  --no-cache          do not keep http-fetched packages in /var/cache/palm
  --json              one JSON document on stdout; progress lines suppressed;
                      errors as {"ok":false,"code":N,"error":"..."}
  --yes               skip the removal confirmation
  --dry-run           print the plan, change nothing
short aliases: -X (repo), -s (dry-run), -y, -L, -W (who-owns), -I -u -a (list filters)
```

Exit codes: 0 ok, 1 verify found problems, 2 usage, 3 not found, 4 refused
(signature, sha256, file conflict, not confirmed), 6 repository unreachable,
7 failed.

**Confirmation.** add/del/upgrade only ever ask when the plan removes
packages, stdin is a TTY, and neither `--yes` nor `--json` is given. Scripts
and the image builder never block. On the serial console (a TTY) `palm del x`
asks; pass `--yes` in scripts that run on one.

**Passthrough.** If argv[1] is not a flag and not one of the verbs above,
palm `execv`s `/usr/lib/palm/palm-surface` with the identical argv
(`PALM_SURFACE=<path>` overrides, used by the selftest). Verified against a
real build of apps/palm: `PALM_SURFACE=... palm commands` prints the surface's
index. distro/apps/build.sh ships apps/palm as `distro/out/bin/palm-apps` —
**the integrator should install that binary at `/usr/lib/palm/palm-surface`.**

## Formats (decisions the CONTRACT left open)

- **Repository layout.** A repository line names a base; palm uses
  `<base>/x86_64/` if it has a PALMINDEX, else `<base>/` itself (apk's
  convention, but tolerant). So `--repo distro/out/repo` and
  `--repo distro/out/repo/x86_64` both work, and over http
  `http://10.0.2.2:8000/repo` tries `/repo/x86_64/PALMINDEX` then
  `/repo/PALMINDEX`. Relative local paths are made absolute.
- **Keys.** `<name>.pub` = 32-byte ed25519 public key, 64 hex chars + newline
  (as CONTRACT says). `<name>.sec` = the 32-byte seed, same encoding, 0600.
- **PALMINDEX.sig** = the 64-byte ed25519 signature over the exact bytes of
  PALMINDEX, as 128 hex chars + newline. Any trusted key may verify it.
- **PALMINDEX** = `key = value` records separated by blank lines: pkgname,
  pkgver (`1.2-r0`), pkgdesc, arch, license, url, size, csize, sha256 (of the
  .palm), depend*, provides*, install_user*, filename.
- **.PKGINFO** `pkgver` carries the release (`1.2-r0`), as apk's does; the
  recipe keeps pkgver and pkgrel separate.
- **Installed database** `/usr/lib/palm/db/installed`: the same records plus
  one `file = <type>\t<mode>\t<uid>:<gid>\t<sha256|link target|->\t<path>` per
  entry. Rewritten atomically after every package of a transaction.
- **install_user** is recorded and checked (a warning if the target's
  /etc/passwd lacks the user); palm never creates users — there are no install
  scripts at all, by design.
- **/etc protection** (apk-style): an upgrade that would overwrite an /etc file
  the user edited writes `<path>.palm-new` instead; removal keeps an edited
  /etc file; `verify` reports an edited /etc file as "modified (config)"
  without failing.
- Versions follow apk; additionally `-r0` compares equal to no release.

## For the image builder

```
palm keygen distro/build/keys/palmframe          # once; keep the .sec out of git
palm build distro/recipes/<pkg> -o distro/out/repo/x86_64
palm index distro/out/repo/x86_64 --key distro/build/keys/palmframe.sec
fakeroot -s <state> -- sh -c '
  palm --root <rootfs> --initdb --repo distro/out/repo \
       --keys-dir distro/build/keys add palmframe-base ... &&
  cp distro/build/keys/palmframe.pub <rootfs>/etc/palm/keys/ &&   # or ship it in a package
  mkfs.ext4 -d <rootfs> ...'                      # same fakeroot session
```

- A fresh `--root` has no trusted keys, so pass `--keys-dir` (or pre-place the
  .pub in `<rootfs>/etc/palm/keys/`). Ship the public key in the base package
  so the installed system trusts the repository.
- palm calls **chown/lchown/chmod/geteuid/unlink/rename/rmdir through libc**,
  so fakeroot intercepts them: under fakeroot palm believes it is root and the
  owners from the packages are recorded (verified: a `palm:palm` 0750 dir shows
  as 1000:1000 inside the fakeroot session). The mkfs must run in the same
  fakeroot session (or `-s`/`-i` state file) to see them.
- Owner names resolve against `<root>/etc/passwd` / `group` first, then the
  number in the archive. If the base package carrying passwd is installed
  first (it will be, if other packages depend on it), names win.
- `/etc/palm/repositories` in the image: one line, e.g.
  `http://10.0.2.2:8000/repo` for QEMU's user network serving
  `distro/out/repo` from the host (`python3 -m http.server 8000 --directory distro/out`).
- Packages should install to canonical `/usr/...` paths (merged /usr). palm
  resolves symlinked parents inside `--root` safely (absolute link targets are
  re-rooted, never followed onto the host), but conflicts are tracked by the
  path a package names.
- Install `distro/out/bin/palm` at `/usr/bin/palm` (CONTRACT's `/sbin/palm`
  is the same file via `/sbin -> usr/bin`).

## What was verified, and how

- `palm --selftest`: 507 assertions, 0 failures — tar round trip (prefix
  field, pax long path/linkpath, setuid, named owners, hard links), a GNU-tar
  archive with long names, header-checksum and `../` refusals; gzip round
  trips on 9 inputs (empty, 1 byte, runs, noise via stored blocks, this binary,
  source text, mixed) each checked by Odin's decoder **and** `gzip -t` /
  `gzip -dc`, plus system-gzip output read back; sha256 vectors; ed25519
  RFC 8032 test 1 and palm's keygen/sign/verify; a 14-version ordering matrix
  and constraint cases; resolver order, provides, cycles, upgrade vs keep, the
  conflict-pin restart, genuine conflicts; HTTP parser (chunked, sized,
  truncated, 404, Location); recipe errors; then by argv:
  build→index→add (--dry-run, --json)→verify→break→verify→fix→conflict refusal
  →upgrade (dropped file removed, edited /etc kept + .palm-new)→del (orphan
  removal, dirs removed); swapped package refused (sha256) even with
  --allow-untrusted; edited index refused; unsigned index refused/accepted with
  --allow-untrusted; untrusted key refused; local .palm needs
  --allow-untrusted; an http repository served by `python3 -m http.server`
  (update, add, cache, tampered served index refused, flat layout, unreachable
  → exit 6); passthrough argv/exit code via a fake surface.
- Inside QEMU (distro/out/bzImage, a throwaway initramfs with busybox, the
  host glibc and palm, run as real root, not part of the image): `palm update`
  / `add` from a host `python3 -m http.server` over 10.0.2.2, owners applied
  for real (an /etc/hello dir declared `palm:palm` came out 1001:1001 because
  the target's passwd said palm=1001 — name wins over number), verify → tamper
  → verify (exit 1) → fix → verify → del --yes, all as expected.
- Speed: a 126 MiB package (Noto + Adwaita fonts + libc) builds in 4.8 s
  (output 65.5 MB, gzip -6 gives 65.2 MB in 5.8 s), installs in 3.7 s,
  verifies in 0.16 s.

## Not done / known limits

- No `palm` progress bars, no parallel downloads, no HTTP keep-alive, no
  proxies, no https (by design: the signature is the trust).
- The resolver is greedy with a pin-and-restart repair, not a SAT solver; it
  handles "upgrade X because Y needs a newer X" but not every possible
  combination of alternatives among multiple providers.
- No `conflicts`/`replaces` fields; moving a file between packages needs both
  packages upgraded in the same transaction (supported: the old owner leaving
  is excluded from the conflict check).
- Packages are held in memory while installing (compressed for all, one
  decompressed at a time).
- Not exercised inside the real Palmframe image (that image is the
  integrator's); exercised in a minimal initramfs under QEMU as above.
