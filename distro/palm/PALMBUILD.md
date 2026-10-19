# PALMBUILD — the recipe format

A `PALMBUILD` is what `palm build <dir> -o <outdir>` reads. It is a
declaration, not a script: it names the package and says where every file
comes from and where it goes. palm builds the archive from that alone, with
no shell, no fakeroot and none of the build machine's owners leaking in.

A recipe packs files that already exist. Compiling them is the job of
whatever calls `palm build` (`distro/recipes`); keeping the two apart is what
lets the same tool build packages on the host and inside the distribution.

```
# distro/recipes/term/PALMBUILD
pkgname = term
pkgver  = 0.1.0
pkgrel  = 0
pkgdesc = The palmy terminal
license = MIT
url     = https://example.invalid/palmframe
depend  = glibc palmframe-fonts
provides = cmd:term
category = System
icon    = square-terminal
details = A terminal emulator with tabs, written with palmy.

file    = ${PALMY_OUT}/bin/term -> /usr/bin/term mode 0755
tree    = share -> /usr/share/term
dir     = /etc/term
symlink = /usr/bin/terminal -> term
owner   = /etc/term palm:palm
```

## Syntax

One `key = value` per line. Whitespace around the `=` and at either end of a
line is ignored. A line whose first character is `#` is a comment; a `#`
anywhere else is part of the value, so `pkgdesc = Says hi # loudly` keeps the
whole description. Blank lines are ignored. Unknown keys are an error, so a
typo is caught at build time rather than shipped.

## Package fields

| key | | |
| --- | --- | --- |
| `pkgname` | required | lowercase letters, digits and `+-._`, starting with a letter or digit |
| `pkgver` | required | the upstream version, apk-style: `1.2.10`, `2.0_rc1`, `1.0a`. No `-r` here |
| `pkgrel` | default `0` | the packaging release; the package version becomes `<pkgver>-r<pkgrel>` |
| `pkgdesc` | | one line |
| `license` | | free text, SPDX identifiers preferred |
| `url` | | |
| `arch` | default `x86_64` | |
| `depend` | repeatable | space-separated constraints: `glibc`, `libgui>=2`, `foo<3`, `bar=1.2`, `baz~1.2` |
| `provides` | repeatable | space-separated virtual names other packages may depend on: `cmd:sh`, `so:libc.so.6`, optionally versioned `so:libc.so.6=6` |
| `conflicts` | repeatable | space-separated constraints no package installed beside this one may meet, by name or by what it provides: `mta-other`, `foo<2` |
| `replaces` | repeatable | space-separated constraints naming packages this one takes over: `oldname`, `oldname<3` |
| `install_user` | repeatable | a user the package expects to exist (see below) |
| `category` | | one of `Accessories`, `Development`, `Graphics`, `Internet`, `Office`, `System`, `Multimedia`, `Games` |
| `icon` | | an icon name for a graphical front end: lowercase letters, digits and `-` (a [lucide](https://lucide.dev) name, which is what `apps/store` draws) |
| `details` | repeatable | longer prose than `pkgdesc`, one paragraph per line |

`category`, `icon` and `details` exist for Software (`apps/store`): the
category is the shelf a package sits on in Discover, `pkgdesc` is the one-line
summary under its name, and `details` is the text on its page. All three are
optional. They are copied into `.PKGINFO`, `PALMINDEX` and the installed
database like every other field, and palm has always skipped keys it does not
know when it reads any of those, so an index with these fields is still read
by an older palm, and an older index simply has none of them. The category
list is closed so that a typo fails `palm build` instead of opening a shelf of
one.

`conflicts` and `replaces` are read by the resolver (`distro/palm/resolve.odin`),
which never chooses two packages where either names the other. `replaces`
means what it means in pacman: the named package was renamed or merged into
this one. It implies the conflict, and `palm upgrade` installs the replacement
in place of an installed package it replaces, renaming the entry in
`/etc/palm/world` too; `palm add` leaves an installed package alone. For a
rename to be seamless the new package should also `provides` the old name
(`provides = oldname=<version>`), so whatever depended on the old name is met
by the new one. Its files may be the old package's: the old package is removed
in the same transaction, and paths the new one brings are kept while it goes.
A package may not name itself in either field. Both fields are copied into
`.PKGINFO`, `PALMINDEX` and the installed database; an older palm skips them,
as it skips every key it does not know.

Constraint operators are `>=`, `<=`, `>`, `<`, `=` and `~`. `=1.2` matches any
release of 1.2 (`1.2-r0`, `1.2-r7`) unless a release is given (`=1.2-r3`);
`~1.2` matches any version that starts with 1.2 as a whole component — 1.2,
1.2.5, 1.2-r3, but not 1.20.

Versions compare as apk compares them: numbers numerically (`1.2.10 > 1.2.9`),
then a letter (`1.0a > 1.0`), then suffixes (`_alpha _beta _pre _rc` sort below
the release, `_p _cvs _svn _git _hg` above it), then the release `-rN`.

`install_user` is a declaration, not an action. palm runs no install scripts
of any kind, so it never creates accounts; it warns at install time if the
named user is missing from the target's `/etc/passwd`. Accounts come from the
base system (the users table in CONTRACT.md).

## File mapping

Destinations are absolute paths in the installed system. A destination may
not contain `..`, a tab or a newline. Sources are paths on the build machine:
absolute, or relative to the directory holding the PALMBUILD, and may use
`${NAME}` to substitute an environment variable (an unset variable is an
error, not an empty string).

| line | means |
| --- | --- |
| `file = <src> -> /dest [mode 0755]` | one regular file. Without `mode`, 0755 if the source has any execute bit, else 0644 |
| `tree = <srcdir> -> /dest` | a whole directory, recursively. Directories become 0755; files 0755 if the source is executable, else 0644; symlinks are kept as symlinks with their targets unchanged. Anything else (devices, sockets) is an error |
| `dir = /dest [mode 0750]` | an empty directory (default 0755) |
| `symlink = /dest -> target` | a symbolic link. The target is written as given; relative targets are relative to the link's directory, as always |

Every parent of every destination is added as a directory entry (0755,
root:root) unless the recipe declares it, so a package carries its own
skeleton and removing it knows which directories were its own. Directories are
shared between packages; regular files and symlinks are not — two packages
claiming the same file path is refused at install time.

Declaring the same destination twice is an error, except a directory, where
the later mode wins.

Merged /usr is the layout (CONTRACT.md): `/bin`, `/sbin`, `/lib` and `/lib64`
are symlinks into `/usr`, owned by the base package. Recipes should install to
the canonical `/usr/...` paths — palm resolves symlinked parent directories
correctly, but ownership and conflicts are tracked by the path the package
names.

## Modes and owners

Applied after all the mappings, in any order, so they may come before or after
the lines they modify. Naming a path that is not in the package is an error.

| line | means |
| --- | --- |
| `mode = /path 4755` | set the full mode, including setuid (4000), setgid (2000) and sticky (1000) |
| `owner = /path user:group` | owner of that one path |
| `owner = /path/** user:group` | that path and everything beneath it |

`user` and `group` are each one of:

- a name from CONTRACT.md's tables — users `root` 0, `greeter` 900, `palm`
  1000; groups `root` 0, `tty` 5, `wheel` 10, `video` 39, `audio` 63, `input`
  97, `greeter` 900, `palm` 1000;
- a number, `1234`;
- `name=number`, for anything else: `owner = /srv/db postgres=70:postgres=70`.

The default for every entry is `root:root`. Owners go into the archive both
numerically and by name. At install time the name wins if the target's
`/etc/passwd` or `/etc/group` knows it, and the number is used otherwise —
which is what happens while the base system's passwd is not yet installed.
Ownership is applied when palm runs as root, or under `fakeroot`, which is how
the image is assembled from the host; as an ordinary user palm writes files as
that user and ignores ownership.

## What comes out

`palm build <dir> -o <outdir>` writes `<outdir>/<pkgname>-<pkgver>-r<pkgrel>.palm`:
a gzip-compressed ustar archive whose first member is `.PKGINFO`

```
pkgname = term
pkgver = 0.1.0-r0
pkgdesc = The palmy terminal
arch = x86_64
license = MIT
category = System
icon = square-terminal
details = A terminal emulator with tabs, written with palmy.
size = 1843200
depend = glibc
depend = palmframe-fonts
provides = cmd:term
```

followed by every entry sorted by path. `size` is the sum of the file sizes.
Timestamps are `SOURCE_DATE_EPOCH`, or zero, and the gzip header carries no
name or time, so building the same recipe over the same files twice gives the
same bytes, and the same sha256 in the index.

Then `palm index <outdir> --key <name>.sec` writes `PALMINDEX` over every
`.palm` in the directory and signs it into `PALMINDEX.sig`. A repository is
that directory, served over plain http or read as a local path.
