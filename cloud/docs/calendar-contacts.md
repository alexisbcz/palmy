# Calendars and contacts

Every identity (`cloud/CONTRACT.md`) has its own calendars and address books,
served over CalDAV and CardDAV so that the clients people already use —
Apple Calendar and Contacts, Thunderbird, DAVx5 on Android, GNOME/Evolution,
khal and khard — work against them unchanged, and the Palmy apps use the
same protocol. Separation between identities is enforced by Postgres RLS, the
same rule as everything else: a session scoped to one identity cannot read or
write another's calendars, and crossing over is always an explicit row — a
share (`dav_grants`) or a scheduling message (`dav_itip`).

This note describes what is built and tested, then what is designed and not
built. Every claim in "built" has a command in [Running it](#running-it) that
shows it.

## What is built

```
cloud/supabase/migrations/20261019600000_dav.sql   schema, RLS, the functions the server calls
cloud/supabase/tests/dav_isolation.sql             pgTAP: 68 assertions
cloud/dav/                                         palm-davd, the server (Odin)
cloud/dav/ical/                                    iCalendar, zones, RRULE, expansion (odin test: 13 groups)
cloud/dav/vcard/                                   vCard 3.0/4.0 read/write/convert (odin test: 3 groups)
cloud/dav/xml/                                     namespace-aware XML (odin test: 3 groups)
cloud/dav/web/                                     HTTP/1.1 server and client, HS256
cloud/dav/client/                                  davclient: the apps' CalDAV/CardDAV client + local cache
cloud/dav/tests/                                   third-party client checks (python-caldav, vdirsyncer, khard, khal)
apps/calendar/                                     the calendar app, synced per identity
apps/contacts/                                     the contacts app
```

### Architecture

```
 Apple Calendar, Thunderbird,          apps/calendar, apps/contacts
 DAVx5, khal/khard (vdirsyncer)        (davclient + cloudkit session)
          │ Basic: handle + app password          │ Bearer: GoTrue access token
          └──────────────────┐   ┌────────────────┘
                             ▼   ▼
                     palm-davd (cloud/dav)          127.0.0.1:59580 in development
           routing · PROPFIND/REPORT · iCalendar/vCard · expansion · scheduling
                             │  PostgREST, always as the caller
                             ▼
                 Postgres: dav_* tables, RLS through can_access_identity()
```

The server holds no data and no privileged session. Each request runs as the
person or as one identity:

- **Bearer** — a GoTrue access token, verified (HS256) so the server can route
  by `sub` and `palm_identity`, then passed through to PostgREST, which
  verifies it again. An unscoped token sees all of the person's identities; a
  token scoped by the accounts area sees one.
- **Basic** — the identity's handle (or `handle@palm.test`) and one of its
  **app passwords**. The server asks `dav_app_password_check` (the only call
  made with the service key) and mints a five-minute token carrying
  `palm_identity` for that identity. Every request is checked again, so
  revoking an app password is immediate. App passwords are 32 random
  characters stored as SHA-256 (they have a key's entropy, so a slow hash buys
  nothing and would make every request slow); only an unscoped session may
  create one. Twenty failed Basic sign-ins from one address within a minute
  earn it a 429 for the rest of that minute.

Every row the server touches is touched under RLS. A bug in the server can
show a client the wrong *view* of its own data; it cannot show it someone
else's, because the database never returns it.

### Why CalDAV for the Palmy apps, not direct table access

The apps could write `dav_objects` rows through PostgREST. They do not:
iCalendar validation, the time-range index (computed in Odin, where the time
zone logic is), Schedule-Tag and implicit scheduling all happen on the
server's write path. An app writing rows directly would have to reimplement
all of it or skip it, and the two writers would drift. So the apps are
CalDAV/CardDAV clients like any other — better integrated (identity-aware,
signed in with the account) but with no private door. This also keeps the
protocol honest: the apps exercise exactly what Apple and Thunderbird use.

### URLs and discovery

```
/.well-known/caldav, /.well-known/carddav        301 -> /dav/            (RFC 6764)
/dav/                                            current-user-principal
/dav/principals/<handle>/                        one principal per identity
/dav/calendars/<handle>/                         calendar-home-set
/dav/calendars/<handle>/<slug>/                  a calendar the identity owns
/dav/calendars/<handle>/<owner>~<slug>/          a calendar shared with it
/dav/calendars/<handle>/inbox/  outbox/          scheduling (RFC 6638)
/dav/addressbooks/<handle>/<slug>/               an address book
```

An identity gets a `default` calendar and address book, in the identity's
colour, the first time it is seen. An unscoped session's principal lists
every identity's home in `calendar-home-set`, which is how the Palmy apps
overlay identities; a stock client signed in with an app password sees one
identity and nothing else.

### Storage model

| table | holds |
| --- | --- |
| `dav_collections` | a calendar or address book: owner identity, slug, name, colour (`#RRGGBB[AA]`), order, components, IANA zone, `public_freebusy` opt-in, `sync_seq`, `min_seq` |
| `dav_objects` | one resource: the **canonical text** the client wrote, its ETag (MD5 of the text), Schedule-Tag, and index columns |
| `dav_changes` | the change log: `(collection, seq, name, deleted)`; deletes are tombstones |
| `dav_grants` | a collection shared with another identity, `read` or `read-write` |
| `dav_itip` | a scheduling message sent by an identity, to a local identity or queued for outside |
| `dav_app_passwords` | per-identity app passwords (hash, label, last used, revoked) |

Index columns on `dav_objects`: for calendars `uid`, `component`, `dtstart`,
`dtend`, `first_start`, `last_end` (UTC; `last_end` is null for an unbounded
recurrence), `all_day`, `rrule`, `overrides`, `summary`, `location`,
`status`, `organizer`, `attendees[]`; for contacts `fn`, `given_name`,
`family_name`, `org`, `emails[]`, `phones[]` (normalised), `card_kind`,
`members[]`. The text is the truth; the columns are derived by the server on
every write and exist only so the database can answer "which objects might
overlap this range" or "who has this address" without parsing anything.

`identity_id` on an object is always its collection's owner — even when a
grantee with read-write access wrote it — set by a trigger.

Policies: the owner (through `can_access_identity`) does everything; a
grantee reaches a collection and its objects through `dav_has_grant`, which
itself goes through `can_access_identity(grantee)`, so a session scoped to
another identity of the same person gets nothing from a grant. The pgTAP file
asserts all of this, including that a session scoped to Alice's *work*
identity cannot see her personal calendar.

### Sync semantics

- **ETag**: `"<md5 of the text>"`. `If-Match` and `If-None-Match: *` are
  evaluated inside the same SQL statement as the write (`dav_put_object`), so
  there is no window between check and write. When the server changes what it
  stores (stripping `METHOD`, stamping `SCHEDULE-STATUS`), the PUT response
  carries no ETag, as RFC 4791 5.3.4 asks, and the client refetches.
- **Sync tokens** (RFC 6578): `https://palmy.dev/ns/sync/<collection>/<seq>`.
  Every insert, update or delete of an object bumps the collection's
  `sync_seq` and appends to `dav_changes` (one trigger, security definer, so
  that a read-write grantee can write objects without being able to edit the
  collection). A token from another collection, from the future, or older than
  `min_seq` gets `403 DAV:valid-sync-token` and the client resyncs fully.
- **CTag** (`CS:getctag`) is `sync_seq`, for clients that still poll it.
- **Tombstones** are kept until `dav_compact(interval)` (default 90 days,
  service role only) removes them and raises `min_seq`.
- **UID uniqueness** per collection (`no-uid-conflict`, 403 with the href of
  the existing resource).
- **davclient** (the apps): a collection is a directory of files plus a state
  file. Edits are written locally and marked dirty; `sync` pushes them with
  `If-Match` (a 412 means the server's copy wins and the local edit is kept as
  `<name>.conflict`), then pulls with the sync token. The apps work offline and
  converge when they reconnect.

### Time zones

- A `TZID` is resolved, in order: the system IANA database
  (`/usr/share/zoneinfo`, read directly as TZif with the POSIX footer rule,
  which is the only source for future dates in "slim" tzdata), after
  stripping the prefixes clients add (`/mozilla.org/20050126_1/Europe/Paris`);
  a table of Windows zone names (Outlook's `Romance Standard Time`); the
  `VTIMEZONE` in the object itself, evaluated with the same RRULE engine; and
  finally UTC, with the object still stored. IANA wins over an embedded
  VTIMEZONE because clients send truncated ones.
- Recurrence is expanded on **wall-clock time** in the event's zone and each
  instance converted separately, so a 09:30 weekly meeting stays at 09:30
  across a DST change (07:30Z in October, 08:30Z after). In a gap the time is
  pushed forward; in a fold the first occurrence wins (RFC 5545 3.3.5).
- All-day and floating times are read in the calendar's zone
  (`calendar-timezone-id`, default UTC) or the zone a `calendar-query` sends;
  the index widens their bounds by ±14 hours so a query in any zone finds them.
- `odin test cloud/dav/ical` checks conversions against known transitions
  (Paris, New York in 2090, Sydney, Kolkata) and the RFC 5545 RRULE examples.

### Recurrence

RRULE (every FREQ, INTERVAL, COUNT, UNTIL, BYxxx including BYSETPOS, BYWEEKNO
and WKST), RDATE (dates and periods), EXDATE, and overridden instances
(`RECURRENCE-ID`). `calendar-query` with a `time-range` prefilters in SQL on
`first_start`/`last_end` and then expands in Odin; `CALDAV:expand` returns
the instances as standalone components in UTC with `RECURRENCE-ID`.
`RANGE=THISANDFUTURE` is read as a single-instance override.

### Scheduling inside the platform (RFC 6638, iTIP RFC 5546)

Implicit scheduling: storing an event is sending it.

1. Alice stores an event with `ORGANIZER:mailto:alice@palm.test` and
   attendees. For each attendee the server writes a `dav_itip` row **as
   Alice's identity**: `REQUEST` on creation or a significant change (time,
   recurrence, title, place, description, status, attendee list), `CANCEL` to
   anyone removed. The database routes it: a local address resolves (through
   mail's `mail_resolve`, so addressing is defined once) to the attendee's
   identity; anything else gets `status = 'not sent: outbound not enabled'`.
   Each `ATTENDEE` in Alice's copy is stamped `SCHEDULE-STATUS=1.2`
   (delivered) or `5.1` (could not be delivered).
2. Nothing writes into Bob's calendar on Alice's behalf. The next time Bob's
   identity looks at its calendars (PROPFIND or REPORT on its home, a calendar
   or its inbox), the server claims Bob's unprocessed messages and applies
   them **as Bob**: a REQUEST becomes an event in his default calendar with
   `PARTSTAT=NEEDS-ACTION` (an update keeps his answer unless the event
   moved), a CANCEL marks it `STATUS:CANCELLED`. The message also stays in
   his `schedule-inbox` until a client deletes it.
3. Bob accepts by setting his own `PARTSTAT` and storing his copy, as Apple
   Calendar and Thunderbird do. The server sends a `REPLY` row to Alice; when
   Alice's identity next looks, her copy's `ATTENDEE` for Bob is updated —
   only for the address that actually sent the reply. An attendee deleting the
   event sends a `DECLINED` reply (unless `Schedule-Reply: F`, or the event was
   already cancelled).
4. **Schedule-Tag** changes only when the organizer's content does, so an
   attendee's client can use `If-Schedule-Tag-Match` across PARTSTAT updates.
5. **Free/busy**: `POST` of a `VFREEBUSY` request to the outbox answers for
   local identities from calendars that opted in (`palm:public-freebusy`,
   PROPPATCH-able) — periods only, never titles. `free-busy-query` REPORT on a
   calendar answers for that calendar.

Delegates writing into a shared calendar do not trigger scheduling: a grant
lets someone edit your events, not speak for you.

### Protocol coverage

What palm-davd implements, against what clients use. "Tested" names the
check that exercises it.

| area | status | tested by |
| --- | --- | --- |
| RFC 6764 well-known, `current-user-principal` | built | caldav_client.py, vdir.sh |
| RFC 4918 PROPFIND (Depth 0/1; infinity answered as 1), PROPPATCH | built | all |
| allprop/propname | built | curl_checks.sh (allprop) |
| GET/HEAD/PUT/DELETE with `If-Match`/`If-None-Match` | built | khard_khal.sh (412) |
| MOVE of a resource between collections (same kind) | built | curl_checks.sh |
| COPY, LOCK/UNLOCK (DAV class 2) | not offered | — |
| RFC 3744 `current-user-privilege-set` (owner / read-write / read) | built | caldav-server-tester |
| ACL method, `principal-property-search`, `principal-search-property-set` | not offered: an identity is not a way to enumerate people; the reports answer empty | caldav-server-tester (principal-search: unsupported) |
| RFC 4791 MKCALENDAR, extended MKCOL (RFC 5689) | built | caldav_client.py, curl_checks.sh |
| `calendar-query`: comp-filter, prop-filter, param-filter, text-match, time-range, is-not-defined | built | caldav_client.py, caldav-server-tester |
| `calendar-query` time-range on VALARM | not built | caldav-server-tester (unsupported) |
| `calendar-multiget`, `free-busy-query` | built | caldav-server-tester |
| `calendar-data` with `expand` | built | caldav_client.py |
| `calendar-data` with `limit-recurrence-set`, partial `comp`/`prop` selection | not built (full data returned) | — |
| `supported-calendar-component-set`, `calendar-timezone-id` (RFC 7809) | built | curl_checks.sh |
| `calendar-timezone` (full VTIMEZONE) | not returned; accepted on MKCALENDAR/PROPPATCH | — |
| RFC 6352 CardDAV: `addressbook-query` (anyof/allof, match-type, limit), `addressbook-multiget` | built | khard_khal.sh |
| `address-data` version negotiation (3.0 ↔ 4.0), `Accept: text/vcard;version=` | built | curl_checks.sh, vcard tests |
| RFC 6578 `sync-collection`, tombstones, invalid-token handling | built | caldav_client.py, vdirsyncer |
| `DAV:limit` on sync-collection | ignored (everything in one reply — allowed) | caldav-server-tester |
| RFC 6638 implicit scheduling, inbox, outbox free/busy, SCHEDULE-STATUS, Schedule-Tag | built for local identities | scheduling.py, caldav-server-tester |
| iTIP to external addresses | queued, not sent | scheduling.py |
| Apple `calendar-color` (hex and CSS names), `calendar-order`, `CS:getctag`, `CS:email-address-set` | built | caldav-server-tester |
| Dead properties | acknowledged by PROPPATCH, not stored | — |
| Calendar subscription (`GET` on a calendar returns one `.ics`) | built | curl_checks.sh |
| Apple calendar sharing/proxy (`CS:invite`, `calendar-proxy-*`), RFC 7953 availability | not built | — |
| JMAP for Calendars / Contacts | not built — see below | — |

**caldav-server-tester 1.5.0** (python-caldav's compatibility checker), run
with two users: **89 of 103 features "full"**. The rest: principal search
(three entries; deliberate), VALARM time-range search, `DAV:limit`
(two; harmless by the tool's own description), a comp-type-less text search
(the RFC-correct answer), `create-calendar.auto`, three unknowns that do not
apply on localhost, and `@` in collection names (refused by the slug rule).
Scheduling — auto-schedule, inbox delivery, free/busy, calendar-user-address-set,
Schedule-Tag including stable-across-PARTSTAT — is all "full".

### Client compatibility

| client | how it was checked | result |
| --- | --- | --- |
| python-caldav 3.5 | `tests/caldav_client.py`, `tests/scheduling.py`, caldav-server-tester | all checks pass |
| vdirsyncer 0.21 | `tests/vdir.sh`: discover + sync, calendars and address books, metadata (colour, name) | works both ways |
| khard 0.22 | `tests/khard_khal.sh`: contact made in khard reaches the server; a server-side edit reaches khard | works |
| khal 0.14 | `tests/khard_khal.sh`: event made in khal is found by a server time-range query | works |
| Apple Calendar / Contacts, Thunderbird, DAVx5, GNOME | **not run** — no GUI or Android on this host | expected to work: they use exactly the surface above (well-known, principal, home-set, sync-collection or getctag+multiget, Schedule-Tag, calendar-color, 3.0 vCards with X-ADDRESSBOOKSERVER groups); unverified until someone points one at it |

Two things will matter for real devices: TLS (the server speaks plain HTTP on
loopback and is meant to sit behind the gateway's TLS terminator), and
`/.well-known` on the bare domain, which Apple and DAVx5 probe first.

### Why not JMAP for Calendars and Contacts (yet)

The mail server speaks JMAP, and the storage here would support it: the text
is canonical, the indexes are what a JMAP query needs, and `dav_changes` is
exactly JMAP's `/changes` state. It is not built, for three reasons:

1. **The clients people have speak CalDAV and CardDAV.** Apple, Thunderbird,
   DAVx5, GNOME and every phone. A JMAP endpoint today would serve only our
   own apps, which already have CalDAV.
2. **JMAP Calendars is still a draft.** `draft-ietf-jmap-calendars` is at
   revision 33 (October 2026) and has changed shape repeatedly; JMAP for
   Contacts is RFC 9610 (December 2024) with JSContact (RFC 9553). Building
   against a moving draft means building twice.
3. **The data model differs.** JMAP uses JSCalendar (RFC 8984), not
   iCalendar; a faithful JMAP layer means a JSCalendar ↔ iCalendar mapping
   with its own edge cases (recurrence overrides as patches, time zones as
   IANA ids only).

When it is worth doing: JMAP Contacts first (it is an RFC, and mail clients
want the address book in the same session as mail — the mail agent's JMAP
endpoint is the natural home, reading `dav_objects` where `component =
'VCARD'`). JMAP Calendars once the draft is an RFC. Neither needs a schema
change.

### The apps

Both apps sign in with the Palmy account (cloudkit's session — the one
Accounts makes — or an in-app sheet), sync through davclient, work offline
from the local copy, and carry a `kit.cli` command surface per
`docs/PALM-CLI.md` (`--json`, `--yes` for destructive verbs, exit 5 when a
request is out of the `PALM_IDENTITY` scope). Screenshots, light and dark, are
in `apps/calendar/shots/` and `apps/contacts/shots/`.

**apps/calendar** (`--selftest`: 96 checks; 61 before this work, all kept)
- Not signed in, the device calendar (`events.tsv`) works exactly as before.
- Signed in, a sidebar lists every identity with its own and shared calendars
  in their colours; read-only shares carry a lock and the owner. All of them
  overlay in one month grid; Space hides or shows one.
- Events are iCalendar: local TZID, an optional repeat (RRULE), attendees.
  Recurring events are expanded with `ical.expand`. Deleting offers "only this
  one" (EXDATE) or the series; editing a recurring event edits the series.
- Invitations (V): every unanswered invitation across identities; accept,
  maybe or decline sets PARTSTAT on the identity's own copy and stores it —
  the server sends the REPLY — then dismisses the inbox item.
- CLI: `status signin sync list events next add delete invitations accept
  decline share unshare app-password`.

**apps/contacts** (`--selftest`: 50 checks)
- Identities and their address books (own and shared) in a sidebar; "All
  identities" overlays them, each card tagged with its identity.
- List with sections and search (name, email, phone digits, company), detail,
  edit (emails and phones with types), groups (vCard 4 `KIND:group` +
  `MEMBER`; Apple's 3.0 `X-ADDRESSBOOKSERVER-*` on the way in and out),
  duplicates (same email, phone or name) and merge (union of fields, group
  memberships moved to the survivor), import and export of `.vcf` (3.0 and
  4.0). Properties the app does not show — and Apple's `itemN.` pairings —
  survive an edit.
- CLI: `signin books list show add edit delete groups group group-delete
  duplicates merge import export sync`.

### The end-to-end demo

`cloud/dav/tests/e2e.sh` builds everything, starts a fresh stack and
server, and runs the whole story with two people; its last run is
`cloud/dav/tests/e2e.txt` (13 checks, all passed):

1. Maya's calendar app adds a dentist appointment and a weekly stand-up in
   her work identity, and deletes Wednesday's occurrence.
2. python-caldav, on app passwords, adds a ceramics class to her personal
   calendar and moves Friday's stand-up to 11:00 (a `RECURRENCE-ID`
   override). The app sees both after `sync`; python-caldav sees the app's
   events and the deleted occurrence.
3. Maya invites Noah from her work identity; Noah's app lists the invitation
   and accepts; Maya's copy shows Noah `ACCEPTED`.
4. Maya shares her personal calendar read-only with Noah; Noah reads it, and
   both the app and the server (403) refuse his write.
5. Maya's work app password cannot see her personal calendar (404); the app
   refuses `--identity noah` with exit 5.
6. A contact made in the contacts app reaches khard through vdirsyncer; an
   edit made on khard's side comes back to the app.

## Designed, not built

### Invitations to people outside Palmy (Resend)

Rows with `status = 'not sent: outbound not enabled'` are the outbound queue.
The transport is the one mail designs in `cloud/docs/mail.md`: Resend. A
worker (service role) would take queued rows, build an RFC 6047 iMIP message
(`text/calendar; method=REQUEST` part plus a readable text part), send it from
`<handle>@<domain>` through Resend, and set the status to `sent` with
Resend's id. Inbound replies arrive through mail's inbound path; a message
with a `text/calendar; method=REPLY` part addressed to an identity becomes a
`dav_itip` row from the external address (the sender's address is checked
against the reply's ATTENDEE, as for local replies, plus DKIM/DMARC from the
inbound pipeline). `SCHEDULE-STATUS` would then read `1.1` (sent). Nothing
here sends mail today, and nothing in this repository talks to Resend.

### Importing from Google and Microsoft

- **One-off import**: both export `.ics`; `GET`-style import is a PUT per
  event, which the calendar app can already do from a file. Google's export
  uses IANA zones; Outlook's uses Windows zone names, which the zone table
  resolves.
- **Continuing sync**: Google Calendar has a CalDAV endpoint (OAuth 2, not
  app passwords) and Microsoft only Graph. Both would be a pull worker per
  linked account writing into a dedicated read-only collection, storing OAuth
  refresh tokens per identity (in the vault area, not here). Google Contacts
  is CardDAV; Microsoft contacts is Graph.

### Push notifications

Clients poll (sync-collection makes polling cheap). Push options, in order of
value: WebDAV-Push (draft, used by DAVx5) driven by a trigger on
`dav_changes` through Supabase Realtime or `pg_notify`; Apple's APNs-based
push needs Apple credentials and is out of reach for a self-hosted server;
the Palmy apps can subscribe to Realtime on `dav_changes` directly (RLS
already filters it per identity).

### Free/busy across organisations

Inside the platform, free/busy works for local identities that opted in. Across
organisations the options are iSchedule (an abandoned draft), publishing a
VFREEBUSY URL per identity (simple, opt-in, what Google and Fastmail offer),
or answering iMIP `VFREEBUSY` requests through the Resend path above. The
published URL is the cheap one: an unauthenticated `GET` on
`/dav/freebusy/<handle>.ifb` backed by `dav_freebusy`, which already exists
and already returns periods only.

### Smaller gaps

- Editing a single instance of a recurring event in the Palmy calendar
  app (it can delete one; the server and stock clients handle overrides).
- The apps sync on the window thread: instant against a local server, a
  visible pause against a slow one. A background sync thread is the fix.
- TLS: the server and davclient speak plain HTTP. davclient rides on
  cloudkit's transport, so it gets TLS when cloudkit does; the server is meant
  to sit behind the gateway's terminator.
- VALARM time-range queries; `limit-recurrence-set`; partial `calendar-data`.
- Apple's sharing UI protocol (`CS:invite`); shares are created by the
  Palmy apps (a `dav_grants` row) and appear in stock clients as ordinary
  calendars, read-only ones with read-only privileges.
- A directory (principal search) — deliberately absent until there is a
  policy for which identities are discoverable by whom.

## Running it

The commands below are the ones the demo was run with. Ports: the stack is
`--name dav --port-base 59540` (gateway 59540, Postgres 59541), the server
listens on 59580.

```sh
cloud/dev/up.sh   --name dav --port-base 59540
cloud/dev/test.sh --name dav --port-base 59540 dav_      # pgTAP: 68/68

odin test cloud/dav/ical  ; odin test cloud/dav/vcard ; odin test cloud/dav/xml
odin build cloud/dav -out:/tmp/palm-davd
PALM_CLOUD_URL=http://127.0.0.1:59540 PALM_DAV_PORT=59580 /tmp/palm-davd serve

# third-party clients (python venv with caldav, caldav-server-tester, vdirsyncer, khal, khard)
cloud/dav/tests/caldav_client.py http://127.0.0.1:59580/ alice <app password>
cloud/dav/tests/scheduling.py    http://127.0.0.1:59580/ http://127.0.0.1:59540 <alice pw> <alice-work pw> <bob pw>
cloud/dav/tests/vdir.sh /tmp/vd http://127.0.0.1:59580/ alice <app password> <venv>/bin
cloud/dav/tests/khard_khal.sh /tmp/vd http://127.0.0.1:59580/ alice <app password> <venv>/bin
cloud/dav/tests/curl_checks.sh   http://127.0.0.1:59580 alice <app password>
caldav-server-tester --config-section alice --config-section bob

# the whole story on its own fresh stack (ports 59560-59579, server 59585)
cloud/dav/tests/e2e.sh /tmp/e2e <venv>/bin
```

App passwords come from the calendar app (`calendar app-password create
--identity alice --label Thunderbird`) or directly:
`rpc dav_app_password_create(target => <identity id>, label => ...)` with the
person's unscoped session.
