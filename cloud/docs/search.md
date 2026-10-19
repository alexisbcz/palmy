# Search: the local index, per identity

Search is where the incumbents are weakest (`research.md` §3): new Outlook
has no local index, Teams loses the context, and Gmail's search is
"remarkably awful" on anything older than last week. Linear and Superhuman
are loved because they answer from local data before a key is released.
Palmframe's answer is one index per identity, kept on the device and
updated within a second of a change. Home, the shell and the assistant
all read that index first.

```
apps/index/core     the engine: segments, query language, ranking, snippets (package indexcore)
apps/index/feed     identities, sources, text extraction, the daemon loop (package indexfeed)
apps/index          `index` — the CLI (docs/PALM-CLI.md), and its self-test
apps/index/indexd   `palm-indexd` — the daemon, the same loop as `index daemon`
apps/index/bench    `index-bench` — the evidence below, against SQLite FTS5
apps/home           Today and search, read from the index (device.odin)
```

## The decision: a hand-written index, not SQLite FTS5

`product.md` flagged the choice. SQLite would add a dependency to a list
that is otherwise `libc` and `libm`. To settle it, both were measured on the
same corpus with the same queries. The corpus is deterministic
(`bench/corpus.odin`): 100,000 mails, 20,000 files, 3,333 notes, 2,500
events and 1,000 people, 126,833 documents in all and 168 MB of text. Word
frequencies follow Zipf's law over 55k words. Mail lengths are log-normal.
Invoice numbers, dates, amounts, links and phone numbers are mixed in, as
real mail has them, which gives about 290k distinct terms. Both indexes
store the full text (for snippets) and both rank with BM25 using the same
field weights plus the same recency term. FTS5 runs with prefix indexes
`2 3` and `remove_diacritics 2`.

Run on a Ryzen 9 6900HX shared with other jobs (load average about 11 on
16 threads), so the absolute numbers are pessimistic. The two engines ran
back to back, so the ratios hold.

| | hand-written | SQLite 3.53 FTS5 |
| --- | --- | --- |
| index size | **320 MB** (1.90× the text) | 478 MB (2.84×) |
| full build | **6.7 s** | 20.1 s (17.7 s inserts + 2.4 s optimize) |
| query p50 / p99, all classes | **1.05 / 41.5 ms** | 14.5 / 643 ms |
| common word | **1.5 / 2.1 ms** | 143 / 215 ms |
| mid-frequency word | **0.23 / 0.46 ms** | 6.8 / 20 ms |
| rare word | **0.26 / 0.43 ms** | 1.3 / 3.9 ms |
| two words | **1.7 / 2.7 ms** | 6.7 / 12 ms |
| `type:mail is:unread` + word | **0.32 / 0.55 ms** | 22 / 29 ms |
| `from:` + word | **0.73 / 1.4 ms** | 8.2 / 18 ms |
| "phrase" (lifted from a body) | **1.3 / 48 ms** | 3.6 / 493 ms |
| "phrase" of the two commonest words | **9.7 / 42 ms** | 77 / 264 ms |
| typo (`roadmpa`) | 0.76 / 1.4 ms, **found** | 0.1 ms, **nothing**: FTS5 has no typo tolerance |
| as-you-type, every prefix of 8 words | **1.2 / 3.4 ms** | 30 / 779 ms |
| cold: open, map, query, close (one CLI call) | **2.8 / 25 ms** | 17 / 353 ms |
| add 1 mail, visible | 1.0 ms | 0.3 ms |
| update 100 mails (marked read) | 7.9 ms | 13 s* |
| remove 1 | 0.3 ms | — |

\* FTS5 keeps no index on the stored `key` column, so every update scans
the table. A side table mapping key to rowid would make this milliseconds.
It is listed so the comparison is honest, not counted against FTS5.

Measured through Home's own keystroke path (`home --bench`), on the same
126,833 documents, every prefix typed letter by letter, 4 repetitions: the
p99 per keystroke is **4.9 to 13 ms** across queries ("quarterly roadmap",
"budget review from:priya", "the", "invoice for the contract", "lunch with
theo", "type:mail is:unread meeting"), and the slowest single keystroke
was 17 ms. That clears the target of 30 ms at p99.

What decided it:

- **Latency where people feel it.** Typing a word starts with a one-, two-
  or three-letter prefix. FTS5 expands a prefix to every matching term and
  ranks every candidate, which costs up to 0.8 s here. The hand-written
  engine bounds what a short prefix completes to (below), so the first
  keystrokes cost the same as the last.
- **Typo tolerance** would need spellfix1 or a vocabulary walk on top of
  FTS5. Here it is a bounded edit-distance scan over a slice of a sorted,
  memory-mapped dictionary.
- **Size and build time:** 0.67× the disk and 0.33× the build time, which
  matters for a laptop indexing a large mailbox on first sign-in.
- **The dependency list stays `libc` and `libm`.** The engine is about
  1,600 lines of Odin, and the self-test covers it.

What FTS5 would have given that this does not: transactional writes, and a
query planner for arbitrary SQL filters. Neither is needed. There is one
writer (the daemon). Its unit of atomicity is a rename of the manifest, and
the filters are fixed (kind, flags, time, identity).

Reproduce: `odin build apps/index/bench -o:speed -out:/tmp/ib &&
/tmp/ib --dir /tmp/ib-data` (it links SQLite only for the comparison;
nothing that ships does). `--query "<text>" --dir …` profiles one query's
phases on an index a previous run left.

## The engine

**Segments** are immutable files. A reader maps one with `mmap` and
answers from it without building anything in memory:

```
header     counts and section offsets
docs       48 bytes each: key hash, source signature, time, kind, flags, token count, stored-field offset
terms      40 bytes each, sorted: df, postings and positions offsets, spelling offset
blob       the term spellings
postings   per term, per document: uvarint doc delta, one tf byte (title 2 bits, people 2, body 4)
positions  per term, per document: byte length + position deltas; read only by phrase queries
store      per document: key, title, who, detail, uri, app, body (≤ 64 KiB)
```

**Updates:** the daemon puts changed documents into a pending builder. A
flush writes them as a new small segment, writes tombstone lists for the
copies they replace, and renames a new `manifest` over the old one. A reader
re-reads the manifest when its mtime changes, which costs one `stat` per
identity. Small segments are merged in tiers (powers of 8 of live
documents, more than 6 in a tier). A segment more than a quarter dead is
rewritten. Merges rebuild from stored text, and no segment exceeds 32,000
documents, so building or merging never holds more than about 80 MB of
postings in memory.

**Ranking.** BM25 runs over a field-weighted term frequency (title ×3,
people ×2, body ×1). Each matching term also gets a bonus: +1.2 for a title
hit, or +0.6 for a people hit. Then, in order:

- an exact phrase in the title adds 3, or 1.5 in the body;
- recency adds 1.6 × 0.5^(days/30), measured from now in either direction,
  so upcoming events count too;
- a small boost by kind (people +0.5, documents +0.3);
- unread adds 0.5, and a person waiting on you adds 0.4.

A completion of a word still being typed counts for 0.55 to 0.95 of the
word itself, more as more of it is typed. A typo correction counts for 0.7.
Results are capped per kind, so one kind can't bury the others, and grouped
by kind in Home.

**Prefixes.** The last word is a prefix while typing. It completes to its
commonest completions, but only `3 / 6 / 16 / 48` of them for prefixes of
`1 / 2 / 3 / 4+` letters. A letter or two matches thousands of words, and
decoding the commonest dozens of their lists is what made the first
keystrokes slow; those results were noise anyway.

**Typos.** A word found nowhere in an identity's index (4 letters or more)
matches dictionary words within one edit, or two from 8 letters. Edits are
Damerau-Levenshtein (adjacent transpositions count as one). The candidate
must start with the same letter. People rarely mistype the first letter,
and that bound limits the scan to one slice of the sorted dictionary. The
correction is reported (`corrections`, and "Showing results for…" in Home).

**Tokens.** A term is a run of letters and digits, lowercased, with Latin
diacritics folded (`Théo` → `theo`, `ß` → `ss`). An address splits into its
parts. Han, kana and hangul are indexed one character per term: unigrams
work, but they are crude. Terms over 40 bytes are dropped (hashes, base64).

## The query language

Plain words must all match, in any field. Everything below narrows.

| | |
| --- | --- |
| `"two words"` | an exact phrase (positions); an unclosed quote while typing matches the last word as a prefix |
| `-word` | must not match |
| `in:northwind` `in:work` | identities by name, handle or kind prefix; repeated means either. An `in:` naming nothing in scope is reported, never widened |
| `type:mail` | mail event task doc file note chat person page issue, plus plurals and synonyms (email, meeting, todo, contact, bookmark, pr…); repeatable |
| `is:unread` `is:read` `is:waiting` `is:flagged` `is:done` `is:open` `is:sent` | flags |
| `has:attachment` | |
| `from:priya` `with:priya` | the word must be in the people field: sender and recipients, organiser and attendees, author |
| `before:` `after:` | `YYYY-MM-DD`, `YYYY-MM`, `today`, `yesterday`, `tomorrow`, `Nd` `Nw` `Nm` `Ny` (that long ago) |

Unknown operators are reported (`unknown` in the JSON, a line in Home) and
the search runs without them. A word that only looks like an operator
(`10:30`, `https://…`) is a plain word.

## Isolation

- **One directory per identity**, `0700`, under `$PALM_INDEX_DIR` (default
  `$XDG_DATA_HOME/palm/index/<handle>/`). Deleting the directory removes
  the identity from this device's search. No file mixes two identities.
- **Writers:** a source is handed one identity's writer and one identity's
  folders. The writer takes that directory's `flock`.
- **Readers:** with `$PALM_IDENTITY` set, `index search`, Home and the
  library's `identities_visible` open that identity's directory and nothing
  else. They don't list the index root and don't read the other
  identities' `identity` files. `--identity` may narrow the scope but never
  widen it: exit 5, with `{"error":"out of scope"}`.
- **Tested:** `index --selftest` sets an inotify watch on the other
  identity's index directory, for opens and reads, while a scoped search
  runs in-process and while the real binary runs with `PALM_IDENTITY`. The
  kernel reports nothing. The library also records every path it opens, and
  Home's self-test asserts the same for a scoped Home.
- **The All view** fans out: one search per identity's index, merged and
  ranked. Every result carries the handle of the index it came from. There
  is no code path that produces a result without one, and the self-tests
  assert it for the CLI JSON and for Home's rows.
- **Encryption at rest: none at the application level, by choice.** Index
  files hold the same plaintext as the Maildir, Drive and Notes folders
  beside them, under the same user, mode `0700`. Encrypting only the index
  would protect nothing those folders don't already expose, and it would
  cost the zero-copy `mmap` that keeps a cold query under 3 ms. The right
  layer is the disk (LUKS) or per-identity fscrypt on `~/.local/share`,
  which covers the sources too. A per-identity key for fscrypt policies is
  a decision for the accounts area.
- **Never indexed:** the vault, and what the browser was told to forget.

## The daemon: palm-indexd

One per person, started by the session. If no index exists and nothing is
running, Home starts it once.

- **Priority:** nice 19 and the idle I/O class (`ioprio_set`).
- **Battery:** read from `/sys/class/power_supply`. On battery, first builds
  and rebuilds wait for mains power. Live changes are still indexed, in
  batches every 30 s instead of 300 ms. Set `PALM_INDEX_ON_BATTERY=run` to
  index anyway.
- **Watching:** inotify on every folder a source reads, plus the parents
  (a new identity folder, a Maildir that `palm sync` swaps whole) and each
  index directory (a `rebuild` request). An event marks (identity, source)
  dirty, and it is rescanned 300 ms later. A rescan skips anything whose
  signature hasn't changed without opening it, so it costs a directory
  listing. If inotify reports a queue overflow, everything is rescanned.
- **Status:** written after every scan to `<index>/<handle>/status` as
  JSON: state, documents per kind, and per source the last scan's seen,
  indexed, removed, unchanged and errors.

## Sources

| source | where | what is indexed | key / change signal |
| --- | --- | --- | --- |
| mail | `palmframe.conf` maps identity → `<palmy-mail>/<address>/` (Maildir++) | subject, sender and recipients, the plain text (HTML only when no plain part; quoted history dropped), attachment names, text and office attachments under 5 MB; unread, flagged, sent, attachment, **waiting** | `.palm-ids` server id (a sync renames every file); signature = folder + flags + waiting |
| drive | `~/Drive/<handle>/` | name, folder, text of .md .txt .csv .html and other plain text, .docx .xlsx .pptx .odt .ods .odp (zip + XML), .pdf via `pdftotext` when installed | relative path; size + mtime |
| notes | `~/Notes/<handle>/` (cloud/docs/notes.md) | title (first line), body without front matter, notebook, `Shared/<owner>` | relative path; size + mtime |
| calendar | DAV cache `<handle>/calendar/<col>/*.ics` | events (recurrences expanded 30 days back and 120 ahead, re-expanded daily), VTODOs as tasks with their due date | file; size + mtime + day |
| contacts | DAV cache `<handle>/addressbook/<col>/*.vcf` | name, emails, phones, organisation, title, note | file; size + mtime |
| browser | `<palmframe/browser>/<handle>/` | bookmarks, and the newest visit of the 5,000 most recent pages; forgotten pages are skipped | id / URL |
| tasks | `<palmy-track>/<handle>/*.md` | track issues: id, title, state, project, assignee, body | file; size + mtime |

**Waiting on you** is computed from mail alone. A mail waits on you when it
is in the Inbox and addressed to the identity. It must be from a person,
not a machine: no `List-Id`, `List-Unsubscribe` or bulk `Precedence`, no
auto-submission, and not a no-reply or notifications address. It must not
come from any of the person's own addresses, and must be under 14 days
old. It stops waiting when a sent mail carries its Message-ID in
`In-Reply-To` or `References`.

**Office text** comes from reading the zip and its XML directly
(`feed/office.odin`). The office apps' importers are `package main` and
can't be imported. Running `docs --convert` for every file would start a
GUI-capable binary per document.

## The CLI

Every command takes `--json`, `--schema` and `--help`, and uses the exit
codes from `docs/PALM-CLI.md`.

```
index search <query…> [--limit 20] [--per-kind 0] [--order relevance|newest|oldest] [--typing] [--no-snippets] --json
index status --json          daemon, per identity: docs, bytes, segments, state, kinds, sources; unclaimed folders
index identities --json      the identities with an index on this device, in scope
index rebuild --identity H   asks the running daemon (a request file), or rebuilds in-process
index daemon [--once]        the daemon in the foreground
```

**`index search --json` is the assistant's tool (apps/ai), and its shape is
stable.** Fields may be added; none will be renamed or removed.

```json
{
  "query": "invoice", "scope": "all",
  "identities": [{"handle": "alice.work", "name": "Alice Martin (Acme)", "kind": "work", "color": "emerald"}],
  "results": [{
    "identity": "alice.work", "identity_name": "Alice Martin (Acme)",
    "kind": "mail", "title": "Invoice INV-2041 from Northwind", "title_marks": [[0, 7]],
    "who": "Bob Lefèvre bob@palm.test, …", "detail": "Inbox",
    "snippet": "Alice, Northwind sent invoice INV-2041 (4,800 EUR), due 31 October. …", "marks": [[22, 29]],
    "time": 1792419274, "date": "2026-10-19T14:14:34Z", "flags": ["unread", "waiting"],
    "key": "mail:4cf9f4ac-…", "uri": "palm://alice.work/mail/invoice-1@palm.test", "app": "mail",
    "open": ["env", "PALM_IDENTITY=alice.work", "mail", "--maildir=…"], "open_exact": false,
    "score": 7.78
  }],
  "count": 1, "matched": 1, "searched": 47,
  "per_kind": {"mail": 1}, "per_identity": {"alice": 0, "alice.work": 1},
  "corrections": [], "unknown": [], "took_ms": 0.03
}
```

`marks` are `[start, end)` byte offsets into `snippet` (or into `title`
for `title_marks`). `open` is the argv that opens the result in its own
identity. An assistant must run it as given and must not change the
`PALM_IDENTITY`. `open_exact` is false where the application can't yet be
told which item (see below).

**The assistant should always run with `PALM_IDENTITY` set.** Then
`identities` holds one entry, every result is that identity's, and
`per_identity` lists only it. The other identities' match counts are not
computed at all.

## Home

Home's `store_load(.Device)` reads the index (`apps/home/device.odin`);
the invented persona is `--fixtures` or `PALM_HOME_FIXTURES=1`.

- **Today:** all of it comes from index queries per identity, merged into
  one timeline.
  - Events from today and tomorrow give the agenda, the now line and Next
    (tomorrow's first event when today is done; *Join* when the event names
    a call, otherwise *Open*).
  - Mail flagged waiting fills Waiting on you, at most five per identity.
  - Tasks are dated tasks due by tonight (overdue in red, the only red on
    the page), then open tracker issues.
  - Recently changed is the newest files, documents and notes. The index
    knows modification times, not opens, so the heading says "changed".
  - The index is re-read every 2 s, at one `stat` per identity, so changes
    appear without input.
- **Search:** as you type, over every identity in scope (or the one the
  window is in). The chips show what each identity would find. Results are
  grouped by kind with highlighted snippets. The honesty line gives the
  item count and the time taken.
- **Enter** opens the item with `feed.open_command`, as its own identity.
- **New:** Task runs `track new`, Event runs `calendar add` (at the next
  whole hour) and Note runs `notes new`, each with `PALM_IDENTITY`.
  Document creates `~/Drive/<h>/<title>.md` and opens it in docs. Mail
  opens mail as the identity, because mail can't be told to start a draft.
- **Palette:** opening an app, and asking an identity's assistant (`ai`),
  both launch with `PALM_IDENTITY`. *Quiet* asks `notify quiet`, and says
  so if it doesn't answer.
- **Carry** still says it is not wired.
- **Local-only mode** is the same path. The identities come from the index
  directories, which palm-indexd creates from local data folders when there
  is no account. Nothing needs the network.

## End to end, on real data

The real stack was `cloud/dev/up.sh --name search --port-base 49521`, with
palm-maild and palm-davd running against it. One person, `alice@example.test`,
has two identities: `alice` and `alice.work`. Mail was delivered between
people and synced with `mailcore palm sync`. Drive files were uploaded and
mirrored by `palm-drive sync` (including a real .xlsx from sheets and a
.docx from docs). Events and contacts went through `calendar add` and
`contacts`, then CalDAV/CardDAV sync. Notes are in the layout from
cloud/docs/notes.md.

- **First build** of both identities, 47 items: about 0.1 s.
- **A new mail:** Bob writes to alice@palm.test. palm-maild delivers it,
  and `mailcore palm sync` swaps the Maildir in (5.5 s, all of it the
  sync). It was searchable **11 ms** after the sync ended. Home, rendered
  afterwards, lists it first under Waiting on you (Home re-reads the index
  every 2 s; that refresh was not timed separately).
- **A Drive file edit** showed up in **0.35 s**, and a deleted then
  restored note in **0.34 s** each. All three are the 300 ms debounce plus
  the rescan.
- **Queries:**
  - `budget` found the mail, the event, the xlsx, the note and the csv,
    each labelled with Alice Martin (Acme).
  - `is:waiting` listed four. The mail Alice sent from her personal
    address to her work one is not among them.
  - `type:event after:today before:tomorrow`, `from:carol`,
    `contract type:doc`, `"contract draft"`, `in:work budget`, and
    `lunc --typing` (lunch: the event, two mails, Bob's contact) all
    returned what they should.
  - `invocie` gave the invoice mail, with "searched for invoice".
  - `budget foo:bar` reported the unknown operator and still searched.
- **Scope:** `PALM_IDENTITY=alice index search budget` found nothing,
  because the budget is work's. With `--identity alice.work` added it
  exited 5 with `out of scope`.
- **Screenshots** of real data, light and dark, are in `apps/home/shots/`
  (`device-01-today-all`, `device-02-today-one`, `device-03-search`).

## Gaps, and what each source app would need

| | gap | what would close it |
| --- | --- | --- |
| chat | not indexed: cloud mode keeps nothing on the device | `chat sync <ch> --since <rev> --json` exists. Chat should keep a per-identity cache (`<data>/palm/chat/<handle>/<channel>.jsonl`, append-only) that the index would watch like the browser history. Indexing over the network instead would break P5 |
| forge | not indexed: nothing local | the same: a per-identity cache of issues and PRs written by `forge` (`issue list --json` as JSONL per repo) |
| mail, open | `open_exact: false`: mail opens at the Maildir, not the message | `mail --open <message-id>` (and `--compose --from <address>` for quick-create) |
| calendar, contacts, notes, open | open the app, not the item | `calendar --date YYYY-MM-DD`, `contacts --show <uid>`, `notes --open <id>` |
| calendar, local | `~/.local/share/palmy-calendar/events.tsv` belongs to no identity: not indexed (P3) | write device-only events into an identity's local calendar |
| notes, "local" | the notes app's `local` notebook names no identity: not indexed; `index status` lists it | binding it to an identity when the person signs in (notes already plans this) |
| tasks | track issues have no due date, so Today shows open issues, not due ones; dated tasks come only from CalDAV VTODOs | a `due:` front matter field in track |
| recently opened | the index knows modification times; atime (relatime) is a weak signal | an "opened" feed from the apps, or the shell (a line per open, per identity) |
| PDFs | text needs `pdftotext`, which the image doesn't ship (poppler) | ship poppler, or a text-only PDF reader in Odin |
| scanned images | no OCR | `apps/ocr` is network-bound (Mistral); a local model would be needed |
| notifications policy | Home shows the kind's default and labels it "(default)" | `notify` publishing each identity's policy sentence |
| carry | Home's sheet says it is not wired | each app writing the copy and both carry logs (`product.md` §5) |
| big bodies | the first 64 KiB of a document's text is indexed | raise `MAX_BODY` if people miss matches in long documents |
| distro | `palm-indexd` is not in `distro/apps/build.sh`'s extras, and the session doesn't start it | `EXTRAS="… index/indexd=palm-indexd"`, and a session entry starting it at login (shell area) |

## Decisions for the person

1. **Encryption at rest:** the index relies on disk or fscrypt encryption,
   the same as the data it indexes. A per-identity fscrypt key, so that a
   locked identity's mail, files and index are all unreadable, is the
   design worth deciding on.
2. **Short prefixes are deliberately coarse** (3 completions for one
   letter). The alternative is slow first keystrokes on large mailboxes.
3. **Other identities' counts in Home** ("5 more in your other
   identities") are computed only in the unscoped Home, which is the
   person's own window. The assistant and every scoped caller never compute
   them (`product.md` open question 5).
