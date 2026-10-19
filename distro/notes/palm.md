# palm, the package manager — notes from the palm side

Owner of this file: the agent that built `distro/palm/`.

## Build and test

```
mkdir -p distro/out/bin
odin build distro/palm -o:speed -out:distro/out/bin/palm
distro/out/bin/palm --selftest        # from the repo root; 623 assertions, ~2 s
```

The selftest needs `python3` (3.14: its http.server takes `-p HTTP/1.1` and
`--tls-cert`) and `openssl` for the http and https sections; without openssl
the https section is skipped and says so.

Pure Odin; `ldd` shows libc, libm and the loader only. No collections needed
(it imports nothing from palmy/kit/shadcn), so the CONTRACT's standard build
line works too.

## The CLI as built

```
palm add <pkg>...         install, record in world. <pkg> is a name, a constraint
                          (foo>=1.2, foo=1.2, foo~1.2, foo<2) or a path to a .palm
                          (a local file needs --allow-untrusted)
palm del <pkg>...         drop from world; removes it and every orphan
palm update               fetch (https/http) and verify every repository index;
                          prints each index's date and how many packages can be upgraded
palm upgrade [-U]         resolve the world preferring newest versions (-U: update first)
palm search <text>...     case-insensitive, names and descriptions; exit 3 if nothing (offline)
palm info <pkg>...        details (installed record, else newest available) (offline)
palm info -L <pkg>        file list (reads the .palm if not installed; downloads it
                          only if it is neither installed nor cached)
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
  -U, --update-cache  add/upgrade/fix: refresh the indexes first
environment: PALM_HTTP_TRACE=1 (print every request and status),
  PALM_CA_FILE=<pem> (trust exactly these CAs), SOURCE_DATE_EPOCH (palm index date)
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
palm keygen distro/build/keys/palmy          # once; keep the .sec out of git
palm build distro/recipes/<pkg> -o distro/out/repo/x86_64
palm index distro/out/repo/x86_64 --key distro/build/keys/palmy.sec
fakeroot -s <state> -- sh -c '
  palm --root <rootfs> --initdb --repo distro/out/repo \
       --keys-dir distro/build/keys add palmy-base ... &&
  cp distro/build/keys/palmy.pub <rootfs>/etc/palm/keys/ &&   # or ship it in a package
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

(Rewritten 2026-10-19; the 0.1 list -- no https, keep-alive, parallel
downloads, conflicts/replaces, a greedy resolver, packages in memory -- is
resolved below.)

- No progress bars for a person (JSON progress events exist), no proxies, no
  HTTP/2. TLS has no revocation checking (CRL/OCSP), no client certificates,
  no resumption, nothing before TLS 1.3, and refuses a HelloRetryRequest
  (X25519 and P-256 shares are both sent, so none has been seen).
- The resolver is a backtracking search with a step budget (200 000), not a
  SAT solver with clause learning: a pathological repository gives up with a
  message rather than searching forever.
- A package is fetched to disk, but still decompressed whole into memory to
  install (one at a time); the largest, fonts-cjk, is 15 MB compressed.
- `palm info -L` of a package neither installed nor cached downloads it: the
  file list is only in the package (Software uses this). Every other query
  is offline.
- Indexes do not expire: the rollback check stops an *older* index, but a
  mirror that keeps serving the newest index it ever had is visible only
  through the date `palm update` prints.
- `distro/recipes/palm/ca-certificates.crt` is a copy of the build host's
  Mozilla bundle (121 roots, October 2026). Refresh with
  `cp -L /etc/ssl/certs/ca-certificates.crt distro/recipes/palm/` and a
  pkgrel bump; a `ca-certificates` package of its own would be better.

## https, mirrors and the public repository (2026-10-19)

**TLS.** `tls.odin` is a TLS 1.3 client on core:crypto: X25519 or P-256,
TLS_AES_128_GCM_SHA256, TLS_CHACHA20_POLY1305_SHA256, TLS_AES_256_GCM_SHA384;
the server chain checked by core:crypto/x509 (hostname or IP SAN, serverAuth,
validity) against the first CA bundle found: `$PALM_CA_FILE`,
`/etc/ssl/certs/ca-certificates.crt`, `/etc/ssl/cert.pem`,
`/usr/share/palm/ca-certificates.crt` (shipped by the palm package);
CertificateVerify for ECDSA P-256/P-384, RSA-PSS and Ed25519; KeyUpdate and
NewSessionTicket handled. Weighed: dlopen of the system OpenSSL (Palmy
has none, and palm must work in an empty --root), BearSSL as a package (a C
library under the package manager that installs it), or our own client.
core:crypto already had every primitive and a strict X.509 validator, so
the protocol was ~800 lines and no new dependency. The index signature stays
the trust; TLS adds privacy and leaves only the mirror itself able to replay
an old index (which the freshness check below stops).

**HTTP.** One keep-alive pool per thread; redirects across hosts but never
https -> http; Range resume of `<file>.part`; bodies streamed to disk with
sha256 computed on the way; a package gets its name only once its sha256
matches the signed index (a mismatch on a resumed file retries once from
zero).

**Downloads.** A transaction fetches to `/var/cache/palm/<repo>/` four at a
time (`FETCH_WORKERS`), then stages, checks and installs one at a time,
re-checking each file's sha256 as it is read. `--no-cache`, or a cache the
user cannot write, downloads to `$TMPDIR/palm-<pid>/` and removes it after.

**Mirrors.** More URLs on a repository line are mirrors of it, tried in
order for the index; packages come from the mirror that served the index,
then the others. The cache key is the first URL.

**Freshness.** `palm index` writes `# generated = <unix seconds>` in the
signed header (`SOURCE_DATE_EPOCH` > 0 overrides; `make` exports 0, meaning
now). `palm update` refuses an index older than the one already verified for
that repository, trying the next mirror.

**Offline queries.** `list`, `info`, `search` read only cached and local
indexes and open no connection (the selftest counts connections); a
repository never fetched is silently absent.

**conflicts and replaces** (PALMBUILD.md) and the resolver: depth-first with
backtracking, candidates by name then by provides, refusing a candidate that
clashes with something chosen; the deepest failure is the error
(`no version of libz satisfies libz>=2 (wanted by app2)`, `conflict: world
wants rival, but rival-1-r0 conflicts with newtool-2.0-r0 (required by
world)`). `replaces` has pacman's meaning: `palm upgrade` installs the
replacement and renames the world entry.

**upgrade.** Prints the plan, a total (`upgrade 3, install 1, remove 1;
download 2.1 MiB, disk +340 KiB`) and the result (`OK: upgraded 3, ...`), or
`nothing to upgrade`. It reads cached indexes like apk and notes when they
are over a day old; `-U` refreshes first.

**The public repository.** `https://palmy-packages.vercel.app/x86_64`
(Vercel static, project `palmy-packages`), mirrored at
`https://github.com/alexisbcz/palmy-packages/releases/download/x86_64`
(release assets of a public repository); both on the one line in
`distro/base/root/etc/palm/repositories`. Signed with
`palmy-release.pub` (`distro/recipes/palm/`, installed into
`/etc/palm/keys/` by the palm package); the secret lives at
`~/.config/palmy/keys/palmy-release.sec` on the publishing machine,
never in a checkout. `distro/repo-publish/publish.sh` stages under
`~/.cache/palmy/publish` (outside any git repository: `vercel link`
inside one connects the project to it, and Vercel then deploys the source
tree on every push -- this happened once and was undone), rebuilds
palmy-base with the release key as its `palmy.pub`, signs a fresh
index, checks it with palm in a root trusting only the release key, deploys,
uploads packages before the index, deletes stale assets after, and checks
each public URL with palm. Limits: Vercel takes up to 100 MB per file from
the CLI (largest package 15 MB, repository 63 MB); GitHub assets 2 GiB.

## How a security update reaches a system

1. Fix the source or recipe, bump `pkgrel` (or `pkgver`).
2. `make -C distro repo`, then `distro/repo-publish/publish.sh`: a new index
   dated now, signed with the release key; Vercel switches atomically, the
   GitHub mirror follows.
3. On every system palmd runs `palm update` two minutes after boot and every
   six hours, so the cached index is at most six hours old and Software's
   Updates page (`palm list --upgradable --json`, offline) shows the fix.
4. A person applies it: Update all in Software (palmd, wheel) or
   `palm upgrade -U` as root. Nothing installs unasked.
5. A mirror or network serving the previous index to hold the fix back is
   refused; a mirror that stops updating shows its date in `palm update`.

## setuid files

palm installs setuid/setgid/sticky bits as recorded: chown, then chmod (chown
clears setuid), through libc so fakeroot records both for the image. A recipe
says `file = <src> -> /usr/bin/doas mode 4755` (or `mode = /usr/bin/doas
4755`); the owner defaults to root:root. `palm verify` compares all twelve
mode bits, so a lost setuid bit is a problem `palm fix` repairs. Verified as
real root in the QEMU image (a 4755 package came out `4755 root:root`) and in
the selftest as a user.

## Verified 2026-10-19

- `palm --selftest`: 623 assertions, 0 failures (was 523). `palmd
  --selftest`: 117, 0 failures (adds the scheduled refresh).
- TLS from the host to example.com, vercel.com, google.com, cloudflare.com,
  api.github.com and Alpine's CDN; TLS 1.2-only servers (badssl.com) refused
  with alert 40.
- `publish.sh` run twice: deployed to Vercel and GitHub, both checked with
  palm. A fresh root trusting only the release key: `palm add track
  fonts-emoji` from Vercel (6 packages, 15 MiB, 2.3 s); with
  `https://nonexistent.invalid/palm` before the GitHub mirror on the line, it
  fell through and installed.
- QEMU, a fresh `make -C distro image` from this worktree, serial root shell:
  `palm list`/`info` said nothing about the network; `palm update` ->
  `https://palmy-packages.vercel.app/x86_64: 48 packages, signed by
  palmy-release.pub`; `palm add --yes track` in 0.76 s; `palm verify` OK
  over 37 packages; `palm upgrade --dry-run`: nothing to upgrade; the setuid
  package as above.

## Changed by the installer integration (2026-10-13)

- **Symlinks under /etc are configuration** (`install.odin`, `main.odin`).
  `/etc/localtime` is palmy-base's link to UTC until the installer points
  it at the chosen zone. `palm verify` now reports a retargeted /etc link as
  `modified (config): points to X, not Y` (soft, exit 0), like an edited
  file, instead of a hard problem. On install/upgrade/fix a link under /etc
  that was retargeted locally (on-disk target differs from both the new and
  the previously recorded one) is kept, with a message; there is no
  `.palm-new` for a link. Selftest: the test package gained
  `/etc/hello/current -> hello.conf`; verify, fix and upgrade all keep a
  retargeted copy (498 assertions, 0 failures).
