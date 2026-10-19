# Palmframe forge

A git forge whose repositories belong to **identities**, not to accounts. Ada's
personal repositories, her work identity's repositories and anything shared
between them follow the same rule as the rest of the Palmframe cloud: rows in
Postgres, separated by row-level security through `can_access_identity()`
(`cloud/CONTRACT.md`). The forge server never decides who may see what; it
forwards each request's credentials to PostgREST and Storage, and the
database answers.

This file is what is built, how it fits together, and — clearly marked —
what is not.

## What is built

```
cloud/supabase/migrations/20261019500000_forge.sql   schema, the access rule, RLS, Storage policies
cloud/supabase/tests/forge_rls.sql                   pgTAP: 66 assertions
cloud/forge/server/                                  forge-server (Odin): smart HTTP, LFS, JSON API
cloud/forge/wire/                                    per-call-bearer Supabase calls over cloudkit, JSON helpers
cloud/forge/demo.sh                                  end to end: accounts + forge + stock git + curl
cloud/forge/demo-transcript.txt                      its last run, 53 of 53
apps/forge/                                          the app: a palmy window and a CLI, one core
apps/forge/shots/                                    light and dark screenshots of the window
```

Numbers: pgTAP 66/66 (and 184/184 for every area's tests together under
`cloud/dev/test.sh`), `forge-server --selftest` 41/41, `forge --selftest` 86/86,
`demo.sh` 53/53.

```sh
cloud/dev/up.sh --name forge --port-base 58521
odin build cloud/forge/server -collection:forge=cloud/forge -out:bin/forge-server
odin build apps/forge -collection:palmy=palmy -collection:shadcn=shadcn \
    -collection:kit=apps/kit -collection:forge=cloud/forge -out:bin/forge
odin build apps/accounts -collection:palmy=palmy -collection:shadcn=shadcn \
    -collection:kit=apps/kit -out:bin/accounts
printf 'API_URL=http://127.0.0.1:58521\nANON_KEY=...\nJWT_SECRET=...\n' > forge.env
FORGE_ROOT=/var/tmp/forge bin/forge-server --env forge.env &      # :58580
bash cloud/forge/demo.sh bin
```

## Architecture

```
  git (stock)          forge CLI / window (apps/forge)          git-lfs, curl
      │ Basic: token        │ Bearer: session or token session        │
      ▼                     ▼                                         ▼
 ┌──────────────────────── forge-server (Odin, :58580) ─────────────────────────┐
 │ route ─ authenticate ─ resolve repo (forge_resolve, as the caller)           │
 │   smart HTTP: info/refs, upload-pack, receive-pack   ── git --stateless-rpc ─┼─► bare repos on disk
 │   LFS batch + objects                                ── Storage (as caller) ─┼─► forge-lfs bucket
 │   JSON: tree, blob, commits, commit, compare, merge  ── git plumbing ────────┤
 │   after a push: which refs moved ─ forge_record_push (as the pusher)         │
 └─────────────────────────────┬────────────────────────────────────────────────┘
                               │ the caller's own bearer token, every time
                               ▼
        PostgREST / Storage ── Postgres: forge_repo_role() → can_access_identity()
                               ▲
  forge CLI / window ──────────┘  rows directly: repos, issues, PRs, reviews,
                                  comments, grants, tokens, activity
```

Two rules shape it:

1. **The database is the only judge.** The server has no access table of
   its own and no service-role key in its request path. It calls
   `forge_resolve(handle, name)` *as the caller*; no row means 404 (or 401
   for an anonymous caller, so `git` asks for a token). It records a push
   with `forge_record_push` *as the pusher*, so even the record of a push is
   refused if the pusher could not write.
2. **Rows go straight to PostgREST.** Issues, pull requests, reviews,
   comments, labels, grants, tokens and the activity feed are tables and
   functions the clients call with their own session. The server only
   handles what needs the repository on disk.

## Protocol choices

**Smart HTTP, v0/v1 and v2.** `GET info/refs?service=git-upload-pack|
git-receive-pack` and `POST git-upload-pack|git-receive-pack`. The client's
`Git-Protocol: version=2` header is passed through as `GIT_PROTOCOL`, so fetch
and clone use v2 (`ls-refs`, then `fetch` — visible in the server log as two
POSTs). Push is v0/v1, as it is everywhere. The dumb protocol is refused.

**Pack negotiation and generation are git's.** The server runs
`git upload-pack --stateless-rpc` and `git receive-pack --stateless-rpc`, the
same split Gitea and Forgejo make (`routers/web/repo/githttp.go`,
`serviceRPC`) and the one `git http-backend` makes internally. That is the
forge's one external dependency, and it is documented as such: writing pack
negotiation, delta compression and fsck natively (JGit, gitoxide) is a
project of its own, and git's implementation is the reference everyone else
is measured against. What is the forge's own: routing, authentication, the
access decision (the database's), the ref policy, and the record of what was
pushed. Running the services directly rather than `git http-backend` as CGI
keeps the server in control of the environment and of what happens around
the pack exchange, without a CGI layer to translate.

**HTTP/1.1, by hand, in Odin.** Request bodies with `Content-Length` or
`Transfer-Encoding: chunked` (git chunks pushes larger than `http.postBuffer`)
and `Content-Encoding: gzip` (git compresses large negotiations). Pack
responses are streamed from git's stdout to the socket until close. Every
response closes the connection; git reconnects without complaint. One thread
per connection.

**Hooks.** None are installed in the repositories. Before `receive-pack`
runs, the server reads the push's command list (`<old> <new> <ref>`) out of
the request and applies its ref policy: only branches and tags, no `..`, and
the default branch cannot be deleted. After it runs, the server checks with
`rev-parse` which refs actually moved (a rejected update is not recorded),
lists the commits each one brought in (`git log new ^old`, or for a new ref
`new --not --exclude=<ref> --glob=refs/*`; at most 100 per ref) and calls
`forge_record_push`, which updates the mirrored refs, inserts the commits and
the push, moves open pull requests' head and base shas, and writes the
activity event. Gitea and Forgejo do this with installed hook scripts that
call back into an internal API; reading the commands in-process does the
same with less moving machinery, at the cost noted under the gaps (no
content checks inside the pack).

**Merges happen on the server without a working tree.** `git merge-tree
--write-tree base head` computes the result (exit 1 means conflicts),
`git commit-tree` writes the merge commit authored as the acting identity
(`<display name> <handle@palm.test>`), and `git update-ref <ref> <new> <old>`
moves the base branch only if it has not moved meanwhile — two merges racing
cannot lose a commit. Fast-forward is `update-ref` to the head when the base
is its ancestor. Then `forge_record_push` and `forge_record_merge`.

**LFS: the batch API with the basic adapter.** `POST info/lfs/objects/batch`
answers with upload or download actions pointing back at the forge, which
proxies `PUT`/`GET` to Supabase Storage *with the caller's bearer token*, so
Storage's own policies decide. An upload is hashed and refused unless it
matches its oid. Objects are recorded in `forge_lfs_objects`.

## Storage layout

**Bare repositories on disk**, by id, not by name:

```
$FORGE_ROOT/<first two hex digits of the repo id>/<repo id>.git
```

A rename, or a transfer to another identity, changes a row and moves nothing
on disk (GitLab's hashed storage makes the same choice; Gitea and Forgejo use
`owner/name.git` and have to move directories). A repository is initialised
lazily the first time the server is asked about a row that exists, with
`uploadpack.allowFilter` (partial clone), `receive.fsckObjects` and the repo id
in its config.

**Supabase Storage**, two private buckets, the repository id as the first
path segment so one policy reads it:

```
forge-releases/<repo id>/<release id>/<asset name>
forge-lfs/<repo id>/<oid[0:2]>/<oid[2:4]>/<oid>
```

`select` needs `forge_can_read(repo)`, `insert`/`update` need
`forge_can_write(repo)`. A public repository's assets are readable
anonymously, like its code.

**Postgres** holds everything that is not file content: see the schema below.
The refs and commits are *mirrored* there at push time, so the window can show
branches, history summaries and the activity feed without touching the disk.

## Authentication

Every request carries one of three things, and each becomes a bearer token
that PostgREST and Storage verify:

| presented | becomes | sees |
| --- | --- | --- |
| nothing | the anon key | public repositories |
| a Supabase access token (Bearer, or the password of Basic) | itself, passed through | what that session sees: the whole account, or one identity for a scoped session (`palm_identity`, minted by `accounts switch` / `mint_scoped_session`) |
| a personal access token `palmforge_…` (Basic password or username, or Bearer) | a 10-minute JWT the server signs: `role: forge_pat`, `palm_identity: <token's identity>`, `forge_token: <token id>` | that identity's repositories, capped at the token's scope |

**Personal access tokens** belong to exactly one identity and are `read` or
`write`. Only their SHA-256 is stored (`forge_tokens.token_hash`); the
plaintext is returned once by `forge_token_create`. `forge_token_resolve`
turns a presented token into what the server needs to sign a session; it
reveals nothing for a wrong, revoked or expired token.

**A token never becomes a general session.** The JWT carries the Postgres
role `forge_pat`, which has grants on forge tables and Storage and nothing
else: such a session cannot read the identity's mail or drive rows even though
it is scoped to an identity that owns them (pgTAP asserts `identities` and
`forge_tokens` are `permission denied` to it). And the token row is checked
on *every statement* (`forge_token_cap()`), so revoking a token ends the
sessions made from it at once — not when the JWT expires.

**Account passwords are not accepted over Basic auth.** Credential helpers
store whatever they are given; what they store should be a revocable token
scoped to one identity, not the key to every identity of the account.

**Existence is not disclosed.** An authenticated caller gets 404 for a
repository that is missing and for one that is merely not theirs. An
anonymous caller gets 401 with `WWW-Authenticate`, so `git clone` of a private
repository prompts for a token rather than claiming it does not exist.

How Forgejo maps the same thing, for comparison: Basic auth with a password or
a token (`services/auth/basic.go`), OAuth2, and scoped tokens with per-area
scopes; repository access from units and team permissions computed in Go. The
difference here is where the decision lives — in the database, behind the
same function every other Palmframe table uses.

The client side is cloudkit's: `forge` reads the person's session, or the
scoped session for `PALM_IDENTITY` / `--identity` (never falling back from a
scope to the full account), from the shared token store; `FORGE_TOKEN` takes a
personal access token instead and never touches the store.

## The access rule

```
forge_repo_role(repo) =
  'admin'   the caller can act as the owning identity          (can_access_identity)
  role      an unrevoked forge_collaborators grant names an identity the caller can act as
  'read'    visibility 'shared' and the caller can act as another identity of the same account
  'read'    visibility 'public' (anonymous included)
  then: capped at 'read' by a read token; null for a revoked or expired token;
        'write' becomes 'read' on an archived repository (the owner keeps admin,
        and can still push: archive stops collaborators, not the owner)
```

`forge_can_read / forge_can_write / forge_can_admin` wrap it, and every forge
policy goes through them (or through `can_access_identity` directly, for
tokens and grants). Writes signed by an identity — an issue's author, a
comment's, a review's — also require `forge_can_act(author)`: you can open an
issue on a public repository, but only as yourself.

**Cross-identity access is always a row the owner made.** A grant
(`forge_collaborators`) is the contract's share row: created by the owning
identity (only it can insert or update one — a writer cannot grant), revoked
rather than deleted. Visibility `public` and `shared` are likewise explicit
settings on the owner's row. Nothing crosses identities ambiently.

Every table carries `identity_id` = the identity that **owns the repository**
the row belongs to, filled by a trigger from the repository and never taken
from the client. The acting identity is a separate column
(`author_identity_id`, `pusher_identity_id`, `actor_identity_id`).

## Schema

| table | what it holds |
| --- | --- |
| `forge_repos` | name, description, visibility (`private`/`shared`/`public`), default branch, issue counter, archived |
| `forge_collaborators` | grants: grantee identity, role `read`/`write`/`admin`, revoked_at |
| `forge_tokens` | personal access tokens: identity, name, sha-256, prefix, scope, expiry, last use, revoked_at |
| `forge_refs` | branches and tags as of the last push (mirror of the disk) |
| `forge_pushes` | each accepted ref update: pusher, old, new, commit count |
| `forge_commits` | commits brought in by pushes: author, date, summary |
| `forge_issues` | issues and pull requests, one numbering per repository (`is_pull`) |
| `forge_pulls` | head/base refs and shas, merge method, merged sha, by, at |
| `forge_reviews` | `commented` / `approved` / `changes_requested`, at a commit |
| `forge_comments` | on an issue or pull request; with `path` + `line`, on a line of the diff |
| `forge_labels`, `forge_issue_labels` | labels per repository |
| `forge_events` | the activity feed, written by triggers and the record functions |
| `forge_webhooks`, `forge_webhook_deliveries` | outbound hooks: **disabled by default and never sent** — a matching event records a delivery with status `disabled` (or `held` if the hook is switched on) |
| `forge_releases`, `forge_release_assets` | releases and their files in the `forge-releases` bucket |
| `forge_lfs_objects` | LFS objects in the `forge-lfs` bucket |

Views that resolve handles the caller's own RLS on `identities` would hide,
each filtered by the same functions: `forge_repo_list`, `forge_issue_list`,
`forge_comment_list`, `forge_event_list`, `forge_collaborator_list`.
Functions: `forge_resolve`, `forge_identity_card` (handle, display name,
colour — nothing that links an identity to its account's other identities),
`forge_my_identities`, `forge_token_create/revoke/resolve`, `forge_grant`,
`forge_revoke`, `forge_pull_open`, `forge_record_push`, `forge_record_merge`.

The pgTAP file asserts: a session scoped to one identity sees none of another
identity's private repositories, issues, refs, activity or tokens (including
the same person's other identity) and cannot write them; a public repository,
its issues and its release assets are readable anonymously and nothing else
is; a grant gives exactly its role — write can push and open pull requests but
not change settings, grant others or see webhooks; read cannot push;
revocation removes everything; nobody can sign an issue as someone else; a
read token is capped at read; a revoked token's session sees nothing at all,
not even public repositories; a token session cannot read `identities` or
`forge_tokens`; Storage paths follow the repository; a webhook records a
disabled delivery.

## The server's JSON API

```
GET  /api/repos/<h>/<r>/branches
GET  /api/repos/<h>/<r>/tree?ref=&path=
GET  /api/repos/<h>/<r>/blob?ref=&path=[&raw=1]
GET  /api/repos/<h>/<r>/commits?ref=&path=&limit=&skip=
GET  /api/repos/<h>/<r>/commit/<sha>
GET  /api/repos/<h>/<r>/compare?base=&head=      ahead, behind, merge base, mergeable, conflicts, diff
POST /api/repos/<h>/<r>/init {"readme": true}     an initial commit written into the bare repository
POST /api/repos/<h>/<r>/pulls/<n>/merge {"method": "merge-commit" | "fast-forward"}
POST /api/token/exchange                         a personal access token for a 10-minute session
GET  /api/whoami
```

## The app

`apps/forge` is one core (`session.odin`, `client.odin`) with two front ends.

**The window** — identities and their repositories in the sidebar (owned,
shared with you, public); the acting identity's colour as a band across the
top and in the "Acting as" pill, with how the session was scoped (account,
scoped session, read/write token); per repository: code (tree, README,
files highlighted with the editor's lexer), commits and commit diffs,
issues, pull requests (conversation, reviews, a merge box that knows whether
the branch is clean and whether it can fast-forward, and a files view whose
line comments sit under their lines), activity, and settings (visibility,
grants, clone URL); access tokens; a new-repository form. Keyboard: 1–6 tabs,
j/k, Enter, Backspace, r, n, t, q.

**The CLI** (`forge --help`, `forge --schema`) on the kit convention:

```
forge whoami
forge repo list|create|show|set|delete       forge clone-url
forge tree|cat|log|show|branches
forge issue list|create|show|comment|close|reopen
forge pr list|create|show|diff|review|merge
forge collab list|add|remove
forge token list|create|revoke
forge activity
```

`--json` everywhere; `repo delete` and `token revoke` refuse without
`--yes` (exit 4); a token asked to act for another identity is refused
before anything is sent (exit 5); not found is 3.

## The end-to-end demo

`cloud/forge/demo.sh` runs against `cloud/dev` and the server: Ada signs up
(`accounts signup`), adds a work identity (`accounts create`), and takes a
scoped session for each (`accounts switch`). As her personal identity she
creates a private repository with a README commit, makes a write token and a
read token, clones and pushes `main` and a feature branch with stock git,
opens an issue and a pull request (mergeable, one ahead, can fast-forward).
The read token reads but `git push` with it gets 403. Her work identity — the
same person — cannot see the repository (exit 3), cannot list it, and its
own token's `git clone` gets "repository not found". A grant of `write` from
personal to work changes exactly that: work sees it with role `write`, clones,
approves the pull request with a comment on line 21 of `src/sort.odin`, and
comments on the issue, but cannot change visibility or grant anyone (exit 5).
Ada merges with a merge commit, closes the issue, revokes the grant (work sees
nothing again, its clone fails), and revokes the read token (refused at
once). A public repository clones with no credentials; an anonymous push is
refused; an anonymous listing shows only it. An LFS object goes up through
the batch API, comes back byte for byte, and is 404 to the work identity's
token. The activity feed shows all of it, with each actor.

## Built, partial, planned

| | state |
| --- | --- |
| smart HTTP clone/fetch/push, protocol v2 fetch | built |
| personal access tokens, scoped sessions, anonymous public read | built |
| issues, comments, pull requests, reviews, line comments, merge (merge commit, fast-forward) | built |
| grants, visibility, archive | built (archive: CLI only) |
| activity feed | built |
| LFS (batch, basic adapter) | built; no `/locks` |
| releases | schema and Storage policies only; no CLI or window yet |
| labels | schema only; no CLI or window to set them |
| webhooks | schema; deliveries recorded as `disabled`/`held`; **nothing is ever sent** |
| SSH transport | planned, below |
| CI runners | planned, below |
| code search | planned, below |
| mirroring to GitHub | planned, below |
| signed commits | planned, below |
| federation (ForgeFed) | planned, below |

**SSH.** The pragmatic path is the one Gitea, Forgejo and gitolite share:
OpenSSH with `AuthorizedKeysCommand` asking the forge for the key's identity,
and a forced command (`forge-shell`) that resolves the repository *as that
identity* (a short `forge_pat`-style session minted for the key) and then
execs `git-upload-pack` / `git-receive-pack`, recording pushes exactly as
the HTTP path does. Keys would be a `forge_ssh_keys` table, one identity each.
A native Odin SSH server (Soft Serve's approach in Go) is the alternative and
is much larger.

**CI runners.** A `forge_jobs` table filled from push and pull request
events, runners that claim jobs with a token scoped to one repository, logs
and artifacts in Storage under the same repo-id prefix. Forgejo Actions'
runner protocol is worth matching rather than inventing.

**Code search.** At push time, index changed text blobs per repository
(`pg_trgm` over a blob table for small installations, zoekt for real ones);
search is then a query under the same RLS.

**Mirroring to GitHub.** Push mirrors are outbound network calls, so they
belong behind the same switch as mail's outbound delivery and webhooks:
designed, disabled, and recorded rather than sent until that switch exists.

**Signed commits.** Verify GPG and SSH signatures at push
(`git verify-commit` against keys registered to the identity), record the
result on `forge_commits`, show it, and optionally require it per branch.

**ForgeFed.** Federation (ActivityPub for forges, as Forgejo is building)
would make an identity's public repositories followable from other forges.
The activity table is already shaped like an outbox; nothing more is built.

## Honest gaps

- **The server holds the project's JWT secret** to sign token sessions
  (HS256). Supabase's newer asymmetric signing keys would need the server to
  hold a private key the gateway trusts, or the exchange to move into an
  Edge Function or GoTrue hook. The person's own sessions are ES256 from
  GoTrue and are passed through untouched.
- **No content checks on a push.** The ref policy sees ref names and shas,
  not objects: file-size limits, secret scanning or required signatures need
  a quarantine pre-receive hook. Branch protection is limited to "the default
  branch cannot be deleted"; force-pushes are allowed.
- **Bodies are held in memory** (a push is capped at 1 GiB), one thread per
  connection with no limit, no timeout on a git child, no keep-alive, no TLS
  (put a terminator in front), no rate limit on token exchange (tokens are
  160 random bits, so guessing is not the risk; load is).
- **At most 100 commits per ref** are recorded per push; history beyond that
  is still in git and in `forge log`, just not mirrored.
- **Deleting a repository deletes its rows, not its directory**; there is no
  garbage collection of orphaned bare repositories or Storage objects yet.
- **`forge_identity_card` answers for any identity**: handle, display name
  and colour, so grants and authorship can be shown. It never reveals the
  account or the identity's siblings. If accounts publishes a directory of
  public identity cards, this should use it.
- **The window calls the network on the UI thread**; on loopback that is
  milliseconds, against a real deployment it would stutter.
- **The `shared` visibility is an interpretation**: readable by the other
  identities of the same account, by an explicit setting on the owner's row.
  A per-identity grant is the precise tool; `shared` is the convenience.
- **The forge exchanges its own tokens** rather than using accounts'
  `mint_scoped_session`, because a git credential needs to be a long-lived,
  revocable secret confined to the forge; accounts' sessions are GoTrue
  sessions good for every table of the identity.
