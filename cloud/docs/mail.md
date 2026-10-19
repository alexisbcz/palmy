# Palmframe mail

One Palmframe account owns several identities; each identity has its own
mailbox, `<handle>@<domain>`, and the separation between them is enforced by
Postgres row-level security through `can_access_identity()`
(`cloud/CONTRACT.md`). This file describes what is built, and then — clearly
marked — the plan for mail to and from the internet through Resend, which is
**designed, not built**.

> **There is no outbound delivery to the internet.** Nothing in this
> repository connects to another mail server or to Resend. Mail between
> identities on the configured domain (`palm.test` in development) is
> delivered for real; mail to anyone else is held in the sender's Outbox with
> the status `held — outbound delivery is not enabled`, and the UI says so.

## What is built

```
cloud/supabase/migrations/20261019200000_mail_schema.sql     tables, RLS
cloud/supabase/migrations/20261019200100_mail_delivery.sql   delivery, submission, import
cloud/supabase/tests/mail_rls.sql                            pgTAP: 48 assertions
cloud/mail/                                                  palm-maild (Odin)
cloud/mail/dev/                                              host-network dev stack, demo
apps/mailcore/palm.odin                                      mailcore palm login | sync
apps/mail/palm*.odin                                         sign-in, identity views
```

### Schema

| table | what it holds |
| --- | --- |
| `mail_domains` | the domains this server is the destination for (configuration; RLS on, no policy) |
| `mail_mailboxes` | folders *and* labels: a message belongs to a set of them (JMAP's model) |
| `mail_threads` | conversation ids, per identity |
| `mail_blobs` | the raw RFC 5322 bytes, `bytea`, deduplicated by SHA-256 within an identity |
| `mail_messages` | header summary, keywords (flags), mailbox set, thread, size, preview |
| `mail_submissions` | each act of sending (JMAP EmailSubmission) |
| `mail_outbox` | one row per non-local recipient: `held` today; `queued → sent / bounced / complained / failed` once outbound exists |
| `mail_changes` | append-only change log; JMAP state strings and `/changes` come from it |

Every table holding a person's mail has `identity_id` and policies through
`can_access_identity(identity_id)` only. Composite foreign keys
(`(identity_id, thread_id)`, `(identity_id, blob_id)`…) and a trigger on
`mailbox_ids` make it impossible to point a row of one identity at an object
of another, even for someone who learned the other's ids.

**Raw messages live in Postgres (`bytea`), not in a Storage bucket.** Delivery
is then one transaction — blob, thread and message commit together or not at
all — and the blob sits behind the same RLS policy as the row naming it, so
there is no orphaned object and no second policy language to keep in step.
Mail is small (median tens of kilobytes; the SMTP receiver caps a message at
25 MiB) and the blob table is separate so listing never touches TOAST. When
attachments make the database the wrong place, the plan is a `storage_path`
column beside `raw` (exactly one set), with the Storage policy keyed on the
identity id as the first path segment, checked by the same function.

**Drafts are messages** with `$draft` in the Drafts mailbox, as in JMAP and
IMAP, not a separate table: a client sees one object type, and sending a draft
is a state change.

**Delivery is a definer function, not a policy.** `mail_deliver` (service role
only: the MX path) and `mail_submit` (a person sending as an identity their
token can reach) are the only way mail crosses from one identity to another,
and it crosses in one direction: an insert into the recipient's inbox. The
sender gains no read access, the recipient's copy never carries the Bcc list,
and `mail_submit` refuses a `From` that is not the identity's own address.
Submissions are limited to 200 per identity per hour (`mail_submit_limit()`).

### palm-maild

One Odin binary (`cloud/mail`), hand-rolled like the rest of the repository,
no dependencies beyond Odin's core library:

| port (dev) | role | auth |
| --- | --- | --- |
| 55525 | SMTP MX (RFC 5321 subset): local domains only, refuses relaying (`550 5.7.1`) and unknown mailboxes (`550 5.1.1`) | none (it is an MX) |
| 55587 | SMTP submission (RFC 6409 subset): delivers locally, holds everything else | `AUTH PLAIN`/`LOGIN`: user = identity address, password = Supabase access token |
| 55580 | JMAP over HTTP (RFC 8620 core, RFC 8621 mail + submission subset) | `Authorization: Bearer <Supabase access token>` |

All three bind 127.0.0.1; the only outgoing connections are to PostgREST and
GoTrue on 127.0.0.1. There is no DNS lookup and no SMTP client in it.

Every read and write for a person goes through **PostgREST with that person's
token**, so Postgres runs it as `authenticated` with their claims and RLS
decides what it touches. The server also verifies the token itself (HS256
signature and expiry) so an unauthenticated request is a 401 at the door.
The MX path uses a service-role token the server mints for itself, and only
ever calls `mail_deliver`.

**One JMAP account is one identity.** The session object lists, as accounts,
exactly the identities the token can reach (`mail_identities()`, through RLS):
all of a person's identities for an ordinary token, one for a token scoped
with `palm_identity`. Each account carries a `urn:palmframe:params:jmap:identity`
capability with its handle, kind and colour, which is how a client labels it.
A request naming any other account gets `accountNotFound` — and would find
nothing anyway.

JMAP methods: `Core/echo`; `Mailbox/get`, `/changes`, `/set`; `Email/query`
(AND filters on mailbox, keywords, dates, size, attachment and text; sort by
receivedAt, sentAt, size, subject; `collapseThreads`; `calculateTotal`),
`Email/get` (all RFC 8621 default properties, `bodyStructure`, `bodyValues`
with truncation), `Email/set` (create from JSON for drafts, keyword and
mailbox patches, destroy), `Email/changes`, `Email/import`; `Thread/get`,
`/changes`; `Identity/get`; `EmailSubmission/set` (with
`onSuccessDestroyEmail` / `onSuccessUpdateEmail`), `/get`, `/changes`;
upload and download endpoints; result references and creation-id references.

Not implemented, each failing with the RFC's own error: `*/queryChanges`,
`Mailbox/query`, `SearchSnippet/get`, `VacationResponse`,
`EmailSubmission/query`, `Email/copy`, push (EventSource, WebSocket), `OR`/`NOT`
filters, `anchor`, `header:*` properties. SMTP lacks STARTTLS (terminated in
front, see below), CHUNKING, SMTPUTF8 and DSN.

### Clients

`mailcore palm login` signs in to GoTrue and keeps the session (mode 0600);
`mailcore palm sync` pushes local flag changes, submits what apps/mail queued
in an identity's Outbox, and re-downloads every identity into its own Maildir
under the mail data directory, writing `palmframe.conf` for the UI. apps/mail
has no network code and still has none: it runs mailcore for sign-in and sync,
shows one identity at a time (`1`–`9`, `0` for all), and prototypes a unified
inbox behind `Shift+I`, with every conversation carrying the identity it came
to. Whether the unified view should exist is a product question — it is the
one view that puts two identities side by side — so it is off by default.

### Running it

```sh
cloud/mail/dev/demo.sh        # fresh stack, pgTAP, two people exchanging mail,
                              # isolation checks, sync, UI screenshots
cloud/mail/dev/stack.sh test  # the pgTAP RLS test alone
```

The dev stack is Postgres, GoTrue and PostgREST with `--network host` on
ports 555xx (`cloud/mail/dev/env.sh`). It should give way to the accounts
area's `cloud/dev` stack, and `cloud/mail/rest.odin` to `apps/cloudkit`, when
those land.

---

## Internet mail through Resend — DESIGN, NOT BUILT

> **Status: not built.** No code in the repository talks to Resend, holds a
> Resend API key, or accepts a Resend webhook. Everything below is a plan,
> written against Resend's public documentation as read on 2026-10-19
> (sources at the end). Prices and limits change; re-check before building.

### What Resend offers (as documented)

**Sending.** `POST https://api.resend.com/emails` with `Authorization: Bearer
re_…`; `from`, `to` (≤ 50), `subject`, `html`/`text`, `cc`, `bcc`,
`reply_to`, `headers`, `attachments` (≤ 40 MB after base64), `tags`,
`scheduled_at`. An `Idempotency-Key` header (≤ 256 chars, kept 24 h) makes a
retry safe. `POST /emails/batch` sends up to 100 messages per call but does
not take attachments. SMTP relay also exists: `smtp.resend.com`, user
`resend`, password = API key, SMTPS on 465/2465 or STARTTLS on 25/587/2587.

**Domains.** `POST /domains` with `name`, `region` (`us-east-1`, `eu-west-1`,
`sa-east-1`, `ap-northeast-1`), `custom_return_path` (default `send`),
`tls` (`opportunistic` | `enforced`), `capabilities: {sending, receiving}`.
It returns the DNS records to publish: an MX and an SPF TXT on the
return-path subdomain (`send.<domain>`, pointing at Amazon SES), a DKIM TXT at
`resend._domainkey.<domain>`, and — when receiving is on — an MX for inbound.
Resend recommends sending from subdomains to isolate reputation. DMARC is
the domain owner's: start `v=DMARC1; p=none; rua=mailto:…`, then
`quarantine`, then `reject` once every source passes.

**Receiving.** Mail to a receiving-enabled domain (or a `<id>.resend.app`
address) is parsed by Resend and announced with an `email.received` webhook.
The webhook carries metadata only (`email_id`, from, to, cc, bcc,
`received_for`, `message_id`, subject, attachment metadata) — never the
body. `GET /emails/receiving/{id}` returns html, text, headers,
`authentication` (SPF/DKIM/DMARC results computed by Resend), attachment
metadata, and `raw.download_url`: a signed, expiring URL to the original
message. Inbound mail counts against the sending quota.

**Webhooks.** Events: `email.sent`, `email.delivered`,
`email.delivery_delayed`, `email.bounced` (Permanent / Transient /
Undetermined, with subtypes), `email.complained`, `email.failed`,
`email.suppressed`, `email.opened`, `email.clicked`, `email.received`,
`email.scheduled`, plus domain, contact, suppression and topic events.
Signed with Svix: headers `svix-id`, `svix-timestamp`, `svix-signature`;
signature = base64(HMAC-SHA256(key = base64-decoded secret after `whsec_`,
message = `id.timestamp.body`)), compared in constant time against each
`v1,` entry; reject stale timestamps.

**Limits and price.** 10 API requests/second per team (shared by every key;
raisable on request), `429` with `ratelimit-*` and `retry-after` headers;
`daily_quota_exceeded` (free plan) and `monthly_quota_exceeded`. Free: 3,000
emails/month, 100/day, 3 domains. Pro: $20 for 50k or $35 for 100k, $0.90
per extra 1,000, 10 domains. Scale: $90–$1,150 for 100k–2.5M, 1,000 domains,
dedicated IP add-on $30/month. 30-day data retention below Enterprise.
Sent and received both count.

### Architecture

```
          ┌───────────── Palmframe ─────────────────────────────────────┐
 person ─▶│ JMAP / SMTP submission ─▶ mail_submit ─▶ local inboxes       │
          │                                     └─▶ mail_outbox (queued) │
          │  outbound worker ◀── claims rows ───────────┘               │
          │     │  POST /emails  (Idempotency-Key = outbox id)          │──▶ Resend ──▶ internet
          │     ▼                                                       │
          │  mail_outbox.provider_id, status = sending                  │
          │                                                             │
          │  webhook receiver ◀── email.* (Svix-signed) ────────────────│◀── Resend
          │     ├─ delivered/bounced/complained/failed ─▶ mail_outbox   │
          │     │                                  └─▶ mail_suppressions│
          │     └─ received ─▶ GET /emails/receiving/{id}               │
          │                    └─▶ raw.download_url ─▶ mail_deliver     │◀── internet
          └─────────────────────────────────────────────────────────────┘
```

Both new pieces are modes of palm-maild (`palm-maild outbound`, and a
`/hooks/resend` route on a separate public listener), so the parsing,
summarising and delivery code is the code already tested by the local path.
Inbound mail enters the schema through the **same `mail_deliver`** the MX
port uses today; the only new thing is how the raw bytes arrive.

### Outbound

1. `mail_submit` stops writing `held` for non-local recipients and writes
   `queued` instead — but only for identities whose `From` domain has
   outbound enabled (below) and only within the abuse limits. Everything else
   keeps `held`, with a reason the person can read.
2. The worker claims rows with `update … set status = 'sending' where id in
   (select id from mail_outbox where status = 'queued' order by created_at
   for update skip locked limit 20) returning …`, running as the service
   role. It groups rows of the same submission into one message with up to
   50 recipients per `to`.
3. It sends the stored raw message's parts: Resend's API takes structured
   fields, not raw RFC 5322, so the worker re-renders from the parsed blob
   (subject, from, to/cc, text, html, attachments, `In-Reply-To` and
   `References` in `headers`). Bcc recipients go in `bcc`. The SMTP relay is
   the alternative that sends the raw bytes unchanged and preserves
   Message-ID and threading exactly; it is the better fit for a mail server
   and should be measured against the API before choosing.
4. `Idempotency-Key` = the outbox row id (or the submission id for a grouped
   send), so a crash between "Resend accepted" and "we recorded it" cannot
   send twice within 24 hours. The returned id goes in `provider_id`.
5. A token bucket in the worker keeps under 10 requests/second; `429` with
   `retry-after` reschedules; `monthly_quota_exceeded` stops the worker and
   flips new submissions back to `held` with "sending quota reached".
6. Transient failures retry with backoff for 24 hours, then `failed`, and the
   sender gets a bounce message (a generated DSN delivered to their inbox
   through `mail_deliver`) — which is what a person expects from mail.

### Inbound

1. Each Palmframe mail domain is created in Resend with
   `capabilities.receiving = enabled`, and its MX points at Resend. For the
   shared domain (`palm.app` or whatever it becomes), that is one domain;
   for custom domains, one per domain (below).
2. The webhook receiver verifies the Svix signature (reject on mismatch or a
   timestamp more than 5 minutes off), stores `svix-id` in a
   `mail_inbound_events` table with a unique constraint (Svix redelivers;
   the second copy is a no-op), and answers `200` immediately.
3. A worker processes the event: `GET /emails/receiving/{email_id}`, then
   fetches `raw.download_url` before `expires_at`, then calls `mail_deliver`
   with the raw bytes and the envelope recipients from `to`/`cc`/`bcc`/
   `received_for` filtered to local domains. That is the same function and
   the same per-recipient refusal the MX port has today.
4. Resend's `authentication` result (SPF, DKIM, DMARC) is recorded on the
   message (a new `auth_results jsonb` column) and decides placement: DMARC
   `fail` with `p=reject` from the sender → not delivered; `fail` otherwise →
   Junk. This is the spam and spoofing filter we do not have to write.
5. A message for an archived identity or an unknown handle is refused per
   recipient by `mail_deliver`, as today; the event is marked done, not
   retried.

### Bounces and complaints

New table `mail_suppressions (identity_id, address, reason, source,
created_at)`, RLS through `can_access_identity`, readable and deletable by the
person (so they can un-suppress a fixed address).

| webhook | effect |
| --- | --- |
| `email.delivered` | outbox row `sent`; `EmailSubmission.deliveryStatus` says `yes` |
| `email.delivery_delayed` | outbox row stays `sending`; status text updated |
| `email.bounced` Permanent | row `bounced`; address suppressed for that identity; DSN to the sender's inbox |
| `email.bounced` Transient / Undetermined | row note updated; no suppression |
| `email.complained` | row `complained`; address suppressed; identity's complaint counter +1 |
| `email.failed` / `email.suppressed` | row `failed` with Resend's reason; DSN to sender |

`mail_submit` checks `mail_suppressions` and holds a recipient on it with the
reason, instead of letting Resend reject it later. Opens and clicks are not
subscribed to: tracking pixels are exactly what apps/mail refuses to load, and
Palmframe should not add them to other people's mail.

### Per-identity custom domains

A person can bring a domain for an identity (`alice@alicemartin.fr` for her
personal identity, `alice@acme.example` for work):

- `mail_domains` gains `identity_id uuid null` (null = a shared Palmframe
  domain), `resend_domain_id`, `status` (`pending | verified | failed`),
  `capabilities`, `records jsonb`, `verified_at`. A row with an `identity_id`
  is that person's data and gets a `can_access_identity(identity_id)` policy;
  shared rows stay policy-less configuration.
- `mail_addresses (identity_id, local_part, domain)` replaces "handle @
  default domain" as the resolver's source, so an identity can have its handle
  address and its custom-domain address, and `mail_submit` accepts any of its
  own addresses as `From`.
- Adding a domain calls `POST /domains` (sending + receiving, region chosen
  near the person, `tls: enforced`), stores the returned records and shows
  them to copy into DNS; a background check calls the verify endpoint until
  `verified`, then enables outbound for that domain. Until then mail from it
  is `held` with "domain not verified".
- DMARC guidance is shown with the records: start at `p=none` with a
  Palmframe-hosted `rua` address (an identity-owned mailbox that the
  assistant can summarise), then tighten.
- A domain is unique across Palmframe; claiming one already verified by
  another identity is refused.
- Plan limits make this a paid feature (10 domains on Pro, 1,000 on Scale).

### Abuse limits

Outbound is the one capability here that can hurt people outside Palmframe,
so it is off by default and earned:

- **Per identity**: new identities start with outbound disabled; enabling it
  needs a verified account (email + a second factor) and is logged. Caps:
  50 external recipients/day for the first two weeks, then 500/day, 100
  recipients per message (today's hard limit), 200 submissions/hour (today's
  limit, all destinations).
- **Per account**: the sum across identities is capped too, so five
  identities are not five times the allowance.
- **Reputation**: complaint rate > 0.1 % or hard-bounce rate > 4 % over the
  last 500 external recipients suspends outbound for that identity and tells
  the person why. Resend suspends whole teams at similar thresholds; this
  keeps one identity from costing every user their mail.
- **Content**: messages to more than 20 external recipients with identical
  bodies within an hour are held for review; attachments with executable
  types are refused.
- **Kill switch**: a single `mail_settings.outbound_enabled` row the worker
  reads every batch.
- **Quotas**: the worker tracks `x-resend-monthly-quota` and stops at 90 %,
  holding instead of failing.

### TLS and the public edge

palm-maild speaks plaintext on loopback. In production the MX (if Palmframe
ever receives directly rather than through Resend), submission and JMAP
listeners sit behind a TLS-terminating proxy; the webhook receiver is the
only route that must be public in the Resend design, and it is a separate
listener with only `/hooks/resend` on it.

### Order of building

1. `mail_addresses` and the resolver change (no internet needed).
2. Inbound: domain with receiving only (`capabilities.sending = disabled`),
   webhook receiver, raw download, `mail_deliver`. Receiving is lower risk
   than sending and proves the domain/DNS flow.
3. Outbound for the shared domain behind the kill switch, Palmframe staff
   identities only, `held → queued` gated on the per-identity flag.
4. Bounce/complaint handling and suppressions, before anyone else gets
   outbound.
5. Custom domains.

### Sources

- Send email: https://resend.com/docs/api-reference/emails/send-email
- Batch: https://resend.com/docs/api-reference/emails/send-batch-emails
- SMTP: https://resend.com/docs/send-with-smtp
- Domains: https://resend.com/docs/api-reference/domains/create-domain,
  https://resend.com/docs/dashboard/domains/introduction,
  https://resend.com/docs/dashboard/domains/dmarc
- Receiving: https://resend.com/docs/dashboard/receiving/introduction,
  https://resend.com/docs/dashboard/receiving/custom-domains,
  https://resend.com/docs/webhooks/emails/received,
  https://resend.com/docs/api-reference/emails/retrieve-received-email
- Webhooks: https://resend.com/docs/dashboard/webhooks/event-types,
  https://resend.com/docs/dashboard/webhooks/verify-webhooks-requests,
  https://docs.svix.com/receiving/verifying-payloads/how-manual
- Bounces: https://resend.com/docs/dashboard/emails/email-bounces
- Limits: https://resend.com/docs/api-reference/rate-limit
- Pricing: https://resend.com/pricing
