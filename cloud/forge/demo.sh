#!/usr/bin/env bash
# The forge end to end, against a running cloud/dev stack and forge server.
#
#   cloud/dev/up.sh --name forge --port-base 58521
#   forge-server --env <file with API_URL, ANON_KEY, JWT_SECRET>   # :58580
#   bash cloud/forge/demo.sh <bin dir with accounts, forge> [transcript]
#
# One person, Ada, with two identities: `ada` (personal) and a work identity.
# A private repository is created as `ada`, pushed to with a personal access
# token and stock git, given an issue and a pull request, reviewed and merged;
# the work identity is shown to see nothing of it until `ada` grants it, and
# nothing again once the grant is revoked; a public repository is cloned with
# no credentials at all; tokens are capped by scope and die when revoked; an
# LFS object goes through Storage under the same rules.
#
# Every step prints the command, its exit code and its output, and checks the
# exit code it should have. Tokens and JWTs are redacted in the output.
set -uo pipefail
bin=${1:?usage: demo.sh <bin dir> [transcript]}
out=${2:-/dev/stdout}
forge="$bin/forge"
accounts="$bin/accounts"
export FORGE_URL=${FORGE_URL:-http://127.0.0.1:58580}
export PALM_CLOUD_URL=${PALM_CLOUD_URL:-http://127.0.0.1:58521}
export PALM_CLOUD_DIR=${FORGE_DEMO_STORE:-$(mktemp -d /tmp/forge-demo-store.XXXXXX)}
mkdir -p "$PALM_CLOUD_DIR"
work=$(mktemp -d /tmp/forge-demo-work.XXXXXX)
trap 'rm -rf "$work"; [ -n "${FORGE_DEMO_STORE:-}" ] || rm -rf "$PALM_CLOUD_DIR"' EXIT
unset PALM_IDENTITY FORGE_TOKEN
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 HOME="$work"
git config --global user.name "Ada Lovelace"
git config --global user.email "ada@palm.test"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

tag=$(date +%s | tail -c 5)
A="ada$tag"            # personal identity
B="northwind$tag"      # work identity, same account
pass=0 fail=0
exec 3>"$out"

redact() { sed -E 's/Basic [A-Za-z0-9+/=]{16,}/Basic ••••/g; s/palmforge_[0-9a-f]{6}[0-9a-f]+/palmforge_••••/g; s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<jwt>/g'; }

step() { # want-exit description command...
	local want=$1 what=$2; shift 2
	local o code
	o=$("$@" 2>&1); code=$?
	if [ "$code" = "$want" ]; then pass=$((pass + 1)); printf '\n### ok   %s\n' "$what" >&3
	else fail=$((fail + 1)); printf '\n### FAIL %s (exit %s, wanted %s)\n' "$what" "$code" "$want" >&3; fi
	printf '$ %s\n' "$(printf '%q ' "$@" | redact)" >&3
	printf '%s\n' "$o" | redact | head -40 >&3
	printf '[exit %s]\n' "$code" >&3
	LAST="$o"
}

note() { printf '\n## %s\n' "$*" >&3; }

clone_url() { # token handle repo
	local hostport=${FORGE_URL#http://}
	if [ -n "$1" ]; then echo "http://x:$1@$hostport/$2/$3.git"; else echo "$FORGE_URL/$2/$3.git"; fi
}

note "1. One account, two identities (apps/accounts, the shared cloudkit token store)"
step 0 "sign up Ada; her first identity is the personal one" \
	"$accounts" signup "ada$tag@palm.test" --name "Ada Lovelace" --handle "$A" --password "forge demo $tag" --json
step 0 "a work identity on the same account" \
	"$accounts" create "$B" --name "Ada at Northwind" --kind work --color sky --json
step 0 "scoped sessions for each, on this machine" "$accounts" switch "$A" --json
step 0 "" "$accounts" switch "$B" --json
step 0 "the forge sees two identities from the unscoped session" "$forge" whoami --json

note "2. A private repository, created as $A"
step 0 "create it, scoped to $A, with a README commit made on the server" \
	env PALM_IDENTITY="$A" "$forge" repo create notes --description "Field notes and the tools that sort them" --readme --json
step 0 "a write token for $A, for git" env PALM_IDENTITY="$A" "$forge" token create laptop --scope write --json
TA=$(sed -n 's/.*"token": "\(palmforge_[0-9a-f]*\)".*/\1/p' <<<"$LAST")
step 0 "a read-only token for $A" env PALM_IDENTITY="$A" "$forge" token create reader --scope read --json
TR=$(sed -n 's/.*"token": "\(palmforge_[0-9a-f]*\)".*/\1/p' <<<"$LAST")
TR_ID=$(sed -n 's/.*"id": "\([0-9a-f-]*\)".*/\1/p' <<<"$LAST" | head -1)

note "3. git push over smart HTTP with the token"
step 0 "clone the server-made README commit" git clone "$(clone_url "$TA" "$A" notes)" "$work/notes"
cd "$work/notes"
mkdir -p src
cat > src/sort.odin <<'EOF'
package notes

import "core:slice"
import "core:strings"

Note :: struct {
	title: string,
	tags:  []string,
	words: int,
}

// by_title sorts notes alphabetically, ignoring case.
by_title :: proc(notes: []Note) {
	slice.sort_by(notes, proc(a, b: Note) -> bool {
		return strings.to_lower(a.title, context.temp_allocator) < strings.to_lower(b.title, context.temp_allocator)
	})
}
EOF
printf '# notes\n\nField notes, and the tools that sort them.\n\n- `src/sort.odin` orders notes\n' > README.md
step 0 "commit" git add -A
step 0 "" git commit -qm "Sort notes by title"
step 0 "push main" git push -q origin main
git switch -qc word-count
cat >> src/sort.odin <<'EOF'

// by_length puts the longest notes first, so the ones worth editing surface.
by_length :: proc(notes: []Note) {
	slice.sort_by(notes, proc(a, b: Note) -> bool {
		return a.words > b.words
	})
}
EOF
step 0 "a feature branch" git commit -qam "Sort by length, longest first"
step 0 "push it" git push -q origin word-count
cd "$work"
step 0 "the push is in the database: branches, commits, activity" "$forge" log "$A/notes" --json
step 0 "" "$forge" activity "$A/notes" --limit 5

note "4. An issue, a pull request, a review, a merge"
step 0 "open an issue as $A" env PALM_IDENTITY="$A" "$forge" issue create "$A/notes" "Sorting ignores accents" --body "Émile sorts after Zoé." --json
step 0 "open a pull request from word-count" env PALM_IDENTITY="$A" "$forge" pr create "$A/notes" "Sort notes by length" --head word-count --body "Longest first, so the notes worth editing surface." --json
step 0 "the pull request: mergeable, one commit ahead, can fast-forward" "$forge" pr show "$A/notes" 2 --json
step 0 "the read token can read" env FORGE_TOKEN="$TR" "$forge" repo show "$A/notes" --json
step 128 "but git refuses a push with it (HTTP 403)" git -C "$work/notes" push -q "$(clone_url "$TR" "$A" notes)" main:refs/heads/ro-test

note "5. $B, the other identity of the same person, sees none of it"
step 3 "$B cannot see the repository (exit 3: not found)" env PALM_IDENTITY="$B" "$forge" repo show "$A/notes" --json
step 0 "nor list it" env PALM_IDENTITY="$B" "$forge" repo list --json
step 0 "a write token for $B" env PALM_IDENTITY="$B" "$forge" token create desktop --scope write --json
TB=$(sed -n 's/.*"token": "\(palmforge_[0-9a-f]*\)".*/\1/p' <<<"$LAST")
step 128 "git clone with $B's token: the repository does not exist for it" git clone -q "$(clone_url "$TB" "$A" notes)" "$work/b1"
step 128 "anonymous git clone: asked for credentials, gets none" git clone -q "$(clone_url "" "$A" notes)" "$work/anon1"
step 5 "$B's token cannot pretend to be $A (exit 5, before anything is sent)" env FORGE_TOKEN="$TB" "$forge" issue list "$A/notes" --identity "$A" --json

note "6. A grant from $A to $B gives exactly what it says"
step 0 "grant $B write on $A/notes" env PALM_IDENTITY="$A" "$forge" collab add "$A/notes" "$B" --role write --json
step 0 "now $B sees it, with role write" env PALM_IDENTITY="$B" "$forge" repo show "$A/notes" --json
step 0 "and can clone it with its own token" git clone -q "$(clone_url "$TB" "$A" notes)" "$work/b2"
step 0 "$B reviews the pull request, with a comment on a line" env PALM_IDENTITY="$B" "$forge" pr review "$A/notes" 2 --state approve --body "by_length reads well; consider a tie-break on title." --path src/sort.odin --line 21 --json
step 0 "$B comments on the issue" env PALM_IDENTITY="$B" "$forge" issue comment "$A/notes" 1 "Seen at work too: a collation step before compare would fix it." --json
step 5 "but a write grant does not let $B change settings (exit 5)" env PALM_IDENTITY="$B" "$forge" repo set "$A/notes" --visibility public --json
step 5 "nor grant others" env PALM_IDENTITY="$B" "$forge" collab add "$A/notes" "$A" --role admin --json

note "7. Merge on the server"
step 0 "merge with a merge commit" env PALM_IDENTITY="$A" "$forge" pr merge "$A/notes" 2 --method merge-commit --json
step 0 "the pull request is merged; the issue is still open" "$forge" pr list "$A/notes" --state all
step 0 "main now carries the merge" "$forge" log "$A/notes" --limit 3
step 0 "close the issue" env PALM_IDENTITY="$A" "$forge" issue close "$A/notes" 1 --json

note "8. Revoking the grant and the tokens"
step 0 "revoke $B's grant" env PALM_IDENTITY="$A" "$forge" collab remove "$A/notes" "$B" --json
step 3 "$B sees nothing again" env PALM_IDENTITY="$B" "$forge" repo show "$A/notes" --json
step 128 "and its token no longer clones" git clone -q "$(clone_url "$TB" "$A" notes)" "$work/b3"
step 0 "revoke the read token" env PALM_IDENTITY="$A" "$forge" token revoke "$TR_ID" --yes --json
step 5 "a revoked token is refused at once (exit 5)" env FORGE_TOKEN="$TR" "$forge" repo list --json

note "9. A public repository, readable by anyone"
step 0 "create it" env PALM_IDENTITY="$A" "$forge" repo create field-guide --visibility public --description "The public half of the notes" --readme --json
step 0 "anonymous git clone, no credentials at all" git clone -q "$(clone_url "" "$A" field-guide)" "$work/public"
step 0 "" cat "$work/public/README.md"
echo "a change" >> "$work/public/README.md"; git -C "$work/public" commit -qam "an anonymous change"
step 128 "anonymous push is refused" git -C "$work/public" push -q origin main
step 0 "anonymous listing shows only public repositories" env PALM_CLOUD_DIR="$work/empty-store" "$forge" repo list --json

note "10. LFS: an object through the batch API into Storage"
blob="$work/model.bin"; head -c 200000 /dev/urandom > "$blob"
oid=$(sha256sum "$blob" | cut -d' ' -f1); size=$(stat -c %s "$blob")
lfs() { curl -s -w '\nHTTP %{http_code}' "$@"; }
step 0 "batch upload: the forge hands back an upload action" \
	lfs -X POST -H 'Accept: application/vnd.git-lfs+json' -H 'Content-Type: application/vnd.git-lfs+json' -u "x:$TA" \
	--data "{\"operation\":\"upload\",\"transfers\":[\"basic\"],\"objects\":[{\"oid\":\"$oid\",\"size\":$size}]}" "$FORGE_URL/$A/notes.git/info/lfs/objects/batch"
step 0 "PUT the object (verified against its oid, stored in Storage as $A)" \
	lfs -X PUT -u "x:$TA" --data-binary "@$blob" "$FORGE_URL/$A/notes.git/info/lfs/objects/$oid"
step 0 "GET it back, byte for byte" bash -c "curl -s -u 'x:$TA' '$FORGE_URL/$A/notes.git/info/lfs/objects/$oid' | sha256sum | cut -c1-64 | grep -qx '$oid' && echo identical"
step 0 "$B's token is refused the private object (401/404)" bash -c "curl -s -o /dev/null -w '%{http_code}\n' -u 'x:$TB' '$FORGE_URL/$A/notes.git/info/lfs/objects/$oid' | grep -E '^(401|404)$'"

note "11. The activity feed"
step 0 "everything $A did, newest first" env PALM_IDENTITY="$A" "$forge" activity --limit 25

printf '\n%d passed, %d failed\n' "$pass" "$fail" >&3
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
