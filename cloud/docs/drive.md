# Drive

Every identity has its own drive. Alice's work drive and Alice's personal
drive are two drives, not two folders in one: the database will not let a
session scoped to one read, write or even count the other's files. Crossing
between them is a share, made by the owning identity, recorded as a row,
and revocable.

This document is the model, the sync rules, and what is not done. The code:

| | |
| --- | --- |
| `cloud/supabase/migrations/20261019300000_drive.sql` | tables, Storage policies, RPCs |
| `cloud/supabase/tests/drive_*.sql` | pgTAP: isolation (31) and shares/links (34) |
| `cloud/drive/core/` | Odin: API calls, chunking, the sync engine, inotify |
| `cloud/drive/palm-drive/` | the sync daemon |
| `apps/drive/` | the app and its `drive` CLI |
| `cloud/drive/dev/` | `stack.sh` (cloud/dev on ports 56500+), `seed.sh`, `demo.sh` |
| `cloud/drive/tests/` | `sync-scenarios.sh` (44 checks), `account-e2e.sh` (9) |

## The model

```
drive_items      id, identity_id, parent_id, name, kind (folder|file),
                 version_id, size, content_hash, mime, starred,
                 trashed_at, trashed_root, modified_at, accessed_at,
                 seq, device
drive_versions   id, identity_id, item_id, size, content_hash,
                 chunk_size, chunks text[], device, created_at
drive_shares     identity_id (owner), item_id, grantee_identity,
                 role (viewer|editor), expires_at, revoked_at
drive_links      identity_id, item_id, token_hash, expires_at,
                 revoked_at, opened
drive_quotas     identity_id, bytes_limit       (written by billing only)
Storage          bucket "drive", private:  <identity id>/chunks/<sha256>
```

**A tree per identity.** A parent must be in the same identity's drive, and
that is a composite foreign key `(parent_id, identity_id)`, not a check in
code. An item's `identity_id` cannot change (a trigger refuses it), so a file
moves between identities only by being shared or copied.

**Content-addressed.** A file's bytes are cut into fixed 4 MiB chunks, each
stored once per identity under its SHA-256. A version is the ordered chunk
list plus the whole-file hash. Two files with the same content, every
version of a file whose middle did not change, and a file and its copy in the
trash all share chunks. Deduplication is **within an identity only**:
deduplicating across identities would let one identity learn that another
holds a given file by uploading it and seeing it skipped, which is exactly the
leak the separation is for.

Why fixed 4 MiB rather than content-defined chunking: it is simple, it is what
Dropbox settled on, a dropped connection costs at most 4 MiB, and it dedupes
copies, appends and in-place rewrites. It does not dedupe an insertion near
the start of a large file. FastCDC (~1 MiB average) would, and changes
nothing in the schema — `chunk_size` is per version and the chunk list is
just a list.

**Versions** are kept: committing new content inserts a version and moves the
item's pointer. Nothing prunes them yet (see *Not done*).

**Trash** is a flag with a memory. `drive_trash(item)` marks the item and
everything under it with `trashed_at` and `trashed_root = item`, so
`drive_restore(item)` brings back exactly what that trashing took. A restored
item whose folder is itself in the trash comes back at the root; one whose
name is taken comes back as `name (restored).ext`. Emptying the trash deletes
rows; the chunks go in a separate GC pass (`drive gc`) through the Storage
API, which is the only way the blob is removed too.

**Recent** is `accessed_at`, set by `drive_touch` when a file is opened; it
does not count as a change. **Starred** is a column. **Search** is an
`ilike` on names with a trigram index; content search is *Not done*.

**The change feed** is `seq`, from one sequence, bumped on every insert and on
every update that moves, renames, edits, stars or trashes an item. A device
asks for `seq > cursor` and gets every change since, in order, including
deletions (as trashings). Opening a file does not bump it.

### Access: every rule goes through `can_access_identity`

| table / bucket | read | write |
| --- | --- | --- |
| `drive_items` | own identity, or a live share reaches it | own identity, or an editor share reaches the folder |
| `drive_versions` | own, or the current version of a shared item | own, or editor |
| `drive_shares` | owner side or grantee side | owner side only |
| `drive_links` | owner | owner |
| `storage.objects` (drive) | own prefix, or a chunk of a shared current version | own prefix or an editor share into it, under quota, chunk-shaped names only |

"A live share reaches it" is `drive_shared_role(item, parent)`: a share on the
item or on any folder above it, not revoked, not expired, whose grantee
identity passes `can_access_identity`. That last clause is what makes a share
mean exactly what it says. A share to `bob.chen` is visible to a session of
Bob's that is unscoped or scoped to `bob.chen`, and to nothing scoped to Bob's
other identities; a share from work to personal is visible to Alice's
personal scope and invisible to an assistant scoped to some third identity.

Editors can add, rename and edit inside the shared folder, trash things, and
upload chunks into the owner's prefix; they cannot delete for good, move
anything out of the share, re-share, mint links, or change their own role.
A direct share on a single file lets an editor rename it, not move it.

Two listing functions are `security definer` because the other side's
identity row is otherwise invisible: `drive_shares_of(item)` names the
grantees for the owner, `drive_shared_with(identity)` names the owner for the
grantee. They return a handle and a display name, which the sharer typed and
the grantee is being told about anyway.

The pgTAP files assert, among others: scoped to A, B's items, versions and
chunks are invisible; inserting into B, hanging an item under B's folder,
moving an item into B, trashing, committing into or minting a link to B's
items all fail; A's owner's *other* identity is just as invisible to a session
scoped to A; anon has no table access; a viewer cannot write, re-share or
mint; an editor can do exactly the editor list above; revocation and expiry
remove read and write, including on chunks.

### Read-only links

`drive_link_mint(item, expires_in)` returns a random 192-bit token once and
stores only its SHA-256. `drive_link_resolve(token)` is callable by `anon`
and answers, for a live link to an item not in the trash, with what a
download needs: each file's path under the linked item, size, hash and chunk
list. It counts opens. Revoking sets `revoked_at`; a revoked or expired token
resolves to nothing.

**How it would be served.** A link is `https://drive.<domain>/s/<token>`,
served by a small gateway — a Supabase Edge Function is the natural home —
that:

1. calls `drive_link_resolve(token)` with the anon key (the database decides
   whether the link is good, so the gateway holds no access logic);
2. for a single file, streams its chunks in order from Storage with the
   service role and sends `Content-Disposition: attachment`; for a folder,
   renders a listing, and streams a zip on request;
3. sets `Cache-Control: private, no-store`, rate-limits by IP, and never logs
   the token.

The service role is confined to the gateway and to reading chunks the resolve
call just named. That is built as far as the RPC and its tests; the gateway
itself is not. `drive resolve <token>` shows what a link exposes.

Link previews (rendering a document in the browser) are a product question
with a security edge: anything that renders user content on the drive's
domain needs a separate origin.

## Sync

`palm-drive` keeps `~/Drive/<handle>/` and each identity's drive the same, in
both directions. Each identity syncs with **its own scoped token**, so a bug
that mixed two folders up would be refused by the database rather than
carried out (scenario 13 checks exactly that: a device handed the wrong
identity's token uploads nothing).

```sh
palm-drive sync          # one reconciling pass per identity, until nothing is left
palm-drive watch         # the daemon: inotify, and a poll of the server
palm-drive status        # what a pass would do, changing nothing; offline: what is queued
palm-drive identities    # which drives this device mirrors, and where
```

Configuration comes from the Palmy account through `apps/cloudkit`: the
identities from the person's session, and for each a session scoped to it
(this machine's `scoped/<handle>.json`, minted with `mint_scoped_session` the
first time, refreshed before use). With `PALM_IDENTITY` set, only that
identity is synced and the person's session is never opened. A
`drive.conf` (what `cloud/drive/dev/seed.sh` writes, with dev-minted tokens)
overrides all of this for tests.

### The rules

A pass is a three-way merge per path, of

- **base**: what this device and the server last agreed on (persisted in
  `~/.local/state/palm-drive/<handle>.state`),
- **local**: the folder now,
- **remote**: the server now (the feed, applied to a persisted mirror).

A side has *changed* when it differs from base. Nothing is decided by
timestamps.

| local | remote | result |
| --- | --- | --- |
| changed | unchanged | upload, as a new version, guarded by the seq base saw |
| unchanged | changed | download |
| changed | changed, same content | agree; nothing moves |
| changed | changed, differently | **conflict: keep both** |
| deleted | unchanged | trash on the server |
| unchanged | trashed | delete locally (the server's trash still has it) |
| edited | trashed | **edit wins**: uploaded again as a new file |
| deleted | edited | **edit wins**: downloaded again |
| new | — | upload / create the folder |
| — | new | download / create the folder |

**Renames and moves** are recognised, not inferred as delete-plus-create: a
base path gone locally whose content (or, for a folder, at least half of its
contents) has appeared at an unknown path is sent as `drive_move`, so the item
keeps its id, history, shares and links. A remote move whose local copy is
unchanged is applied with `rename(2)`. Folder renames and file renames inside
them in the same offline stretch both come through as moves (scenario 5).

**Conflicts keep both.** The server's version keeps the name, because every
other device already has it under that name. This device's version is set
aside beside it and uploaded as a new file:

```
report.txt
report (conflicted copy, laptop, 2026-10-19 14.03).txt
```

The name says what it is, from which device, and when, and sorts next to the
original. The server never merges; neither does the daemon. An upload that
loses a race (the item's `seq` moved since base) is refused with `PT409`,
and the next pass sees both sides changed and keeps both.

**Safety checks** that make "never lose an edit" true rather than intended:
a download goes to a temporary file, is checked chunk by chunk and as a whole
against the version's hashes, and only then renamed into place; before
overwriting or deleting a local file the daemon re-stats it and leaves it for
the next pass if it changed during this one; each chunk is re-hashed as it is
read for upload, and an upload stops if the bytes no longer match the name.

**Offline and resumption fall out of the design.** There is no operation
queue to lose. What is pending is exactly "local differs from base",
recomputed every pass, so a week of offline edits across reboots is applied
by the first pass that reaches the server; `palm-drive status` lists it
(scenario 9). Uploads resume at the chunk: chunks are content-addressed and
`drive_missing_chunks` is asked before sending, so a cut-off upload re-sends
only what is missing, and nothing is committed until every chunk is there
(scenario 10: dropped after 3 of 5 chunks, the retry sent 2 and skipped 3,
and the server never had a half file).

**inotify is a doorbell.** It says "something under here changed" and a pass
works out what from the files. Events are not replayed, because inotify
drops them under load, knows nothing of what happened while the daemon was
stopped, and splits a rename in two. A save reaches the server in about a
second (scenario 12); changes made elsewhere arrive on the poll (15 s by
default). Server push (Realtime on `drive_items`, filtered by identity) would
remove the poll; it is not built.

Not synced: symlinks, devices, sockets. An empty file is one empty chunk.

### Test results

`cloud/drive/tests/sync-scenarios.sh`, two "devices" on the same identity
against the real stack: **44 / 44**.

1. first upload and download, an empty folder, a 9 MiB file as 3 chunks
2. a copy uploads 0 chunks; 6 chunks stored for 5 files
3. an edit travels; both versions kept on the server
4. both sides edit: one conflict, named for device-B, both devices end with both
5. a file rename and a folder rename offline: 2 moves, 0 uploads, same item id; the other device moves rather than downloads
6. a delete goes to the server's trash; restoring brings it back everywhere
7. a folder delete is one trashing, not one per file
8. edit beats delete
9. offline: exits 6, `status` lists 4 queued changes; reconnected: 2 uploads, 1 delete, 1 folder
10. connection dropped after 3 of 5 chunks: nothing committed; the retry sends 2 and skips 3; byte-identical on the other device
12. the watcher uploads a save within ~2 s and pulls the other device's file on the poll
13. a device holding the wrong identity's token uploads nothing (`AccessDenied` from Storage)

`cloud/drive/tests/account-e2e.sh`, a real sign-up through GoTrue with the
Accounts CLI: **9 / 9** — two identities found with no drive.conf, a scoped
session minted for each, sync into both, `drive` scoped to work cannot see
the personal file and exits 5 when asked for the personal drive, and after an
explicit share the personal identity sees the folder.

## The app and the CLI

`apps/drive` is the cloud view of one identity at a time: My Drive, Shared
with me, Recent, Starred, Trash, and live search; list and grid (thumbnails
come from the synced copy, so nothing is downloaded to draw them); an
inspector with who has access, links, versions and the local path; the share
dialog; an identity switcher that re-tints the window in the identity's
colour. Files open in the system's own apps — Docs, Sheets, Slides, Image,
Video, Reader — from the synced copy when it matches, otherwise from a
verified download into `~/.cache/palm-drive/open/`.

The `drive` CLI follows `docs/PALM-CLI.md`: `ls stat find recent starred
shared usage mkdir upload download open mv trash restore empty-trash star
share unshare link links unlink resolve versions gc shots`, each with a
declared effect class (`empty-trash` and `gc` refuse without `--yes`), JSON
on stdout, the documented exit codes. Scope is `PALM_IDENTITY` narrowed by
`--identity`; asking for another identity exits 5 — and if that check were
missing, the scoped token would make the database refuse anyway.

## Not done

**End-to-end encryption.** Today the server can read every file: Storage
holds plaintext chunks. The options, and what each costs:

- *Per-identity key, files encrypted client-side.* Each identity has a
  symmetric key (wrapped by a key derived from the account, recoverable via a
  recovery key). Chunks are encrypted before hashing for storage — the
  storage name must be a keyed hash (HMAC with an identity key), or the
  content hash leaks "you have this file" to the server. Costs: server-side
  search and previews go (both would have to run on devices); dedupe stays
  within an identity (as now), which is the only place it was allowed anyway.
- *Sharing* then means wrapping a per-file (or per-folder) key for the
  grantee identity's public key. Revocation becomes key rotation: the grantee
  had the key, so revoking only stops *future* versions; that should be said
  in the UI, not hidden. Link sharing puts the key in the URL fragment
  (`#k=…`), which the gateway never sees, and the gateway serves ciphertext
  to a page that decrypts in the browser — a web client we do not have.
- *The assistant.* A local model reading the drive is fine (it runs on the
  device, with the scoped key); a server-side assistant is impossible by
  construction. That is a feature for a product built on "your assistant
  cannot read what it is not scoped to".
- Recommendation: make E2E a per-identity choice (personal on, work as the
  organisation decides), with the trade-offs on the switch.

**Collaborative editing.** Drive stores files; `apps/docs` edits them. Today
two people editing the same document produce a conflicted copy, which is
honest and annoying. The path: an editable document opened from the drive
becomes a live session — a CRDT document (Yjs/Automerge-shaped, or the docs
model's own operations) in a `drive_sessions` table keyed by item, synced
over Realtime among the identities with access (the same `drive_shared_role`
decides who may join). The session periodically commits a normal version, so
the drive, sync, versions and sharing see an ordinary file and need no
change. Presence and cursors are Realtime broadcast. The sync daemon must
then *not* treat the session's commits as a conflict with a local copy that
was open in Docs — Docs should edit through the session, not the file.

**Quotas and billing.** `drive_quotas` holds a per-identity limit (15 GB
default) that only the service role writes; Storage inserts are refused once
`drive_stored_bytes` reaches it. Not done: the check is "under quota before
this chunk", so one chunk can overshoot by up to 4 MiB; summing
`storage.objects` per insert is O(objects) and wants a maintained counter;
quota is per identity while billing is per account (a work identity paid by an
organisation is the obvious exception), so the real unit is probably an
account pool with per-identity caps; versions and trash count against quota,
and nothing yet prunes them (keep 30 days or 100 versions, empty trash after
30 days — a `pg_cron` job and a GC run).

**Also not built:** the link gateway (above); Realtime instead of polling;
content search (text extracted on the device, embedded per identity); a
`files` integration (below); conflict UI beyond the named copy; selective
sync (every file is mirrored); case-insensitive filesystems (two names
differing only in case would collide on macOS/Windows); per-chunk
verification on the server (a client could store garbage under a hash name —
it only harms its own identity, but a server-side check on upload would make
the content addressing a guarantee rather than a convention).

## What apps/files should do (another area's)

- Show **Drive** in the sidebar, one entry per mirrored identity, coloured
  like the identity, pointing at `~/Drive/<handle>` — `palm-drive identities
  --json` lists them with their roots.
- Badge files with sync state from `palm-drive status --json` (synced,
  queued, conflict); a `(conflicted copy, …)` name is a conflict.
- A context-menu **Share…** and **Copy link** on anything under `~/Drive/`
  that shells out to `PALM_IDENTITY=<handle> drive share <path>` / `drive link
  <path>`, where `<path>` is the file's path with `~/Drive/<handle>/` removed.
- Never move a file between two `~/Drive/<handle>` folders with a plain
  rename: across identities that is a share or an explicit copy, and Files
  should say so, the same way the database would.
