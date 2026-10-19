#!/bin/sh
# publish.sh -- put the Palmframe repository on the public internet.
#
#   distro/repo-publish/publish.sh [--dry-run] [--no-vercel] [--no-github]
#
# Takes the packages `make -C distro repo` built (distro/out/repo/x86_64),
# signs a fresh index for them with the RELEASE key, and publishes:
#
#   1. Vercel (primary): a static deployment of
#        x86_64/PALMINDEX  x86_64/PALMINDEX.sig  x86_64/*.palm
#        palmframe-release.pub  index.html
#      at https://$VERCEL_PROJECT.vercel.app, replaced atomically.
#   2. GitHub Releases (mirror): the same files as assets of release
#      $GITHUB_TAG in $GITHUB_REPO, so the mirror line is
#      https://github.com/$GITHUB_REPO/releases/download/$GITHUB_TAG
#
# What is published is exactly the index, its signature, the public key and
# the packages. The private key is read from outside every checkout
# ($PALMFRAME_RELEASE_KEY, default ~/.config/palmframe/keys/
# palmframe-release.sec) and this script refuses to run if it sits under the
# repository or anywhere it would be uploaded. Before anything is uploaded,
# the staged repository is installed from (`palm update`) in a scratch root
# that trusts nothing but distro/recipes/palm/palmframe-release.pub, and
# after the upload the same is done against each public URL.
#
# Order matters for clients reading during an upload: packages go up before
# the index that names them, and old packages are deleted only after the new
# index is up. A client that catches the index and the signature from two
# different uploads sees a bad signature and moves on to its next mirror.
#
# Every index carries the time it was made (`# generated`); clients refuse an
# index older than one they have seen, so a publish is also how a security
# fix reaches people: rebuild the package with a higher pkgrel, run
# `make -C distro repo`, run this. distro/notes/palm.md has the whole path.

set -eu

DISTRO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(dirname "$DISTRO")
OUT=$DISTRO/out
PALM=${PALM:-$OUT/bin/palm}
SRC=${SRC:-$OUT/repo/x86_64}
KEY=${PALMFRAME_RELEASE_KEY:-$HOME/.config/palmframe/keys/palmframe-release.sec}
PUB=$DISTRO/recipes/palm/palmframe-release.pub
# The staging directory is outside every checkout on purpose: `vercel link`
# run inside a git repository connects the project to that repository, and
# Vercel then deploys the repository itself on every push -- which would
# replace the package repository with a build of the source tree.
STAGE=${STAGE:-${XDG_CACHE_HOME:-$HOME/.cache}/palmframe/publish}
VERCEL_PROJECT=${VERCEL_PROJECT:-palmframe-packages}
VERCEL_URL=${VERCEL_URL:-https://$VERCEL_PROJECT.vercel.app}
GITHUB_REPO=${GITHUB_REPO:-alexisbcz/palmframe-packages}
GITHUB_TAG=${GITHUB_TAG:-x86_64}
# Vercel takes files up to 100 MB per file through the CLI on the Hobby
# plan; GitHub release assets up to 2 GiB.
MAX_FILE=$((100 * 1000 * 1000))

dry=0
do_vercel=1
do_github=1
for a in "$@"; do
	case "$a" in
	--dry-run) dry=1 ;;
	--no-vercel) do_vercel=0 ;;
	--no-github) do_github=0 ;;
	-h | --help)
		sed -n '2,36p' "$0"
		exit 0
		;;
	*)
		echo "publish: unknown option $a" >&2
		exit 2
		;;
	esac
done

die() {
	echo "publish: $*" >&2
	exit 1
}
say() { echo "publish: $*"; }

# --- preconditions -----------------------------------------------------------
[ -x "$PALM" ] || die "$PALM is missing (make -C distro repo)"
[ -f "$PUB" ] || die "$PUB is missing"
ls "$SRC"/*.palm >/dev/null 2>&1 || die "no packages in $SRC (make -C distro repo)"
[ -f "$KEY" ] || die "no release key at $KEY (PALMFRAME_RELEASE_KEY); \`palm keygen\` one outside the checkout and put its .pub in $PUB"
key_abs=$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")
case "$STAGE" in
"$ROOT" | "$ROOT"/*) die "STAGE ($STAGE) is inside the checkout; see the comment at STAGE" ;;
esac
mkdir -p "$STAGE"
if (cd "$STAGE" && command -v git >/dev/null && git rev-parse --show-toplevel >/dev/null 2>&1); then
	die "STAGE ($STAGE) is inside a git repository; see the comment at STAGE"
fi
case "$key_abs" in
"$ROOT"/* | "$STAGE"/* | "$OUT"/*) die "the release key $key_abs is inside the checkout; keep it outside (it must never be committed or uploaded)" ;;
esac
case "$(stat -c %a "$key_abs")" in
600 | 400) ;;
*) die "$key_abs is readable by others; chmod 600 it" ;;
esac

# --- stage --------------------------------------------------------------------
site=$STAGE/site
mkdir -p "$site"
# Keep .vercel (the project link) between runs; everything else is rebuilt.
find "$site" -mindepth 1 -maxdepth 1 ! -name .vercel -exec rm -rf {} +
mkdir -p "$site/x86_64"
cp "$SRC"/*.palm "$site/x86_64/"
# palmframe-base carries /etc/palm/keys/palmframe.pub, which a checkout's
# build fills with its own throwaway build key. The public copy must not
# trust a key that only ever signed one developer's local repository, so it
# is rebuilt here with the release key in that place.
keys_tmp=$(mktemp -d)
cp "$PUB" "$keys_tmp/palmframe.pub"
rm -f "$site"/x86_64/palmframe-base-*.palm
PALMFRAME_ROOT=$ROOT PALMFRAME_OUT=$OUT PALMFRAME_KEYS=$keys_tmp SOURCE_DATE_EPOCH=0 \
	"$PALM" build "$DISTRO/recipes/palmframe-base" -o "$site/x86_64" >/dev/null
rm -rf "$keys_tmp"
# Dated now, whatever the environment says: clients refuse an older index.
env -u SOURCE_DATE_EPOCH "$PALM" index "$site/x86_64" --key "$key_abs"
cp "$PUB" "$site/palmframe-release.pub"

# Nothing but what should be public.
for f in $(find "$site" -type f ! -path '*/.vercel/*'); do
	case "$f" in
	*/x86_64/PALMINDEX | */x86_64/PALMINDEX.sig | */x86_64/*.palm | */palmframe-release.pub) ;;
	*) die "unexpected file staged: $f" ;;
	esac
	if grep -qF "$(cat "$key_abs")" "$f" 2>/dev/null; then
		die "$f contains the private key"
	fi
	size=$(stat -c %s "$f")
	[ "$size" -le "$MAX_FILE" ] || die "$f is $size bytes, over the per-file limit"
done

count=$(ls "$site"/x86_64/*.palm | wc -l)
total=$(du -sh "$site/x86_64" | cut -f1)

# A page for people who open the URL in a browser.
{
	cat <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Palmframe packages</title>
<style>
:root{color-scheme:light dark;--fg:#1c1917;--muted:#78716c;--bg:#fafaf9;--line:#e7e5e4}
@media (prefers-color-scheme:dark){:root{--fg:#f5f5f4;--muted:#a8a29e;--bg:#1c1917;--line:#44403c}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:32px 16px}
h1{font-size:22px;margin:0 0 4px}p{color:var(--muted);margin:0 0 16px}
code{font:13px ui-monospace,monospace}
table{width:100%;border-collapse:collapse;font-size:14px}
td,th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:500}td.n{white-space:nowrap}
.wrap{overflow-x:auto}
</style></head><body><main>
<h1>Palmframe packages</h1>
<p>The x86_64 repository for <code>palm</code>: $count packages ($total), index signed with
<a href="palmframe-release.pub"><code>palmframe-release.pub</code></a>. On a Palmframe system:
<code>palm update &amp;&amp; palm upgrade</code>.</p>
<div class="wrap"><table><thead><tr><th>package</th><th>version</th><th>description</th></tr></thead><tbody>
EOF
	awk -F' = ' '
		function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
		/^pkgname = / { n = $2 }
		/^pkgver = / { v = $2 }
		/^pkgdesc = / { d = $2 }
		/^filename = / { printf "<tr><td class=\"n\"><a href=\"x86_64/%s\">%s</a></td><td class=\"n\">%s</td><td>%s</td></tr>\n", esc($2), esc(n), esc(v), esc(d); d = "" }
	' "$site/x86_64/PALMINDEX"
	echo "</tbody></table></div>"
	echo "<p style=\"margin-top:16px\">Index generated $(date -u '+%Y-%m-%d %H:%M UTC').</p>"
	echo "</main></body></html>"
} >"$site/index.html"

cat >"$site/vercel.json" <<'EOF'
{
  "headers": [
    { "source": "/x86_64/PALMINDEX", "headers": [{ "key": "Content-Type", "value": "text/plain; charset=utf-8" }, { "key": "Cache-Control", "value": "public, max-age=0, must-revalidate" }] },
    { "source": "/x86_64/PALMINDEX.sig", "headers": [{ "key": "Content-Type", "value": "text/plain; charset=utf-8" }, { "key": "Cache-Control", "value": "public, max-age=0, must-revalidate" }] },
    { "source": "/x86_64/(.*)\\.palm", "headers": [{ "key": "Content-Type", "value": "application/octet-stream" }] },
    { "source": "/palmframe-release.pub", "headers": [{ "key": "Content-Type", "value": "text/plain; charset=utf-8" }] }
  ]
}
EOF

# --- verify before anything leaves the machine ---------------------------------
# A root that trusts the release key and nothing else must accept the staged
# repository and install from it.
check_repo() { # <repo url or path> <label>
	scratch=$(mktemp -d)
	mkdir -p "$scratch/keys"
	cp "$PUB" "$scratch/keys/"
	# A CDN takes a little while to serve a new deployment everywhere.
	tries=0
	until "$PALM" --root "$scratch/root" --initdb --keys-dir "$scratch/keys" --repo "$1" update; do
		tries=$((tries + 1))
		if [ $tries -ge 12 ]; then
			rm -rf "$scratch"
			die "$2: palm update against $1 failed"
		fi
		sleep 5
	done
	pkg=$(awk -F' = ' '/^pkgname = /{print $2; exit}' "$site/x86_64/PALMINDEX")
	if ! "$PALM" --root "$scratch/root" --initdb --keys-dir "$scratch/keys" --repo "$1" add --dry-run "$pkg" >/dev/null; then
		rm -rf "$scratch"
		die "$2: palm cannot plan an install from $1"
	fi
	rm -rf "$scratch"
	say "$2: verified with palm against $1"
}
check_repo "$site" "staged repository"
say "staged $count packages ($total) in $site"

if [ $dry = 1 ]; then
	say "dry run: nothing uploaded"
	exit 0
fi

# --- Vercel -------------------------------------------------------------------
if [ $do_vercel = 1 ]; then
	command -v vercel >/dev/null || die "the vercel CLI is not installed"
	if [ ! -f "$site/.vercel/project.json" ]; then
		(cd "$site" && vercel link --yes --project "$VERCEL_PROJECT" >/dev/null)
	fi
	# Belt and braces for the STAGE comment: the project must never build
	# from a repository.
	(cd "$site" && vercel git disconnect --yes >/dev/null 2>&1) || true
	say "deploying to Vercel project $VERCEL_PROJECT"
	(cd "$site" && vercel deploy --prod --yes)
	check_repo "$VERCEL_URL" "Vercel"
fi

# --- GitHub Releases ------------------------------------------------------------
if [ $do_github = 1 ]; then
	command -v gh >/dev/null || die "the gh CLI is not installed"
	if ! gh repo view "$GITHUB_REPO" >/dev/null 2>&1; then
		say "creating $GITHUB_REPO"
		gh repo create "$GITHUB_REPO" --public --add-readme \
			--description "Palmframe package repository mirror (signed PALMINDEX and .palm packages as release assets)" >/dev/null
	fi
	if ! gh release view "$GITHUB_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
		gh release create "$GITHUB_TAG" --repo "$GITHUB_REPO" --title "Palmframe x86_64 repository" \
			--notes "The x86_64 package repository. palm reads it as https://github.com/$GITHUB_REPO/releases/download/$GITHUB_TAG; the index is signed with palmframe-release.pub." >/dev/null
	fi
	old_assets=$(gh release view "$GITHUB_TAG" --repo "$GITHUB_REPO" --json assets --jq '.assets[].name')
	say "uploading $count packages to $GITHUB_REPO release $GITHUB_TAG"
	gh release upload "$GITHUB_TAG" --repo "$GITHUB_REPO" --clobber "$site"/x86_64/*.palm "$site/palmframe-release.pub"
	gh release upload "$GITHUB_TAG" --repo "$GITHUB_REPO" --clobber "$site/x86_64/PALMINDEX.sig" "$site/x86_64/PALMINDEX"
	for a in $old_assets; do
		case "$a" in PALMINDEX | PALMINDEX.sig | palmframe-release.pub) continue ;; esac
		[ -f "$site/x86_64/$a" ] || gh release delete-asset "$GITHUB_TAG" "$a" --repo "$GITHUB_REPO" --yes
	done
	check_repo "https://github.com/$GITHUB_REPO/releases/download/$GITHUB_TAG" "GitHub"
fi

say "done: $VERCEL_URL/x86_64 (mirror https://github.com/$GITHUB_REPO/releases/download/$GITHUB_TAG)"
