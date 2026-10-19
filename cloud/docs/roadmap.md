# Roadmap: from a prototype to something a person can switch to

Sequenced milestones, what to build and what to integrate, and the risks
stated plainly. "Credible" has a concrete meaning here: **a person can move
one real identity onto Palmy, live in it for a month, and leave again
with everything.** Each milestone ends in a test of that kind, not a feature
list.

The order follows one argument. Identity is the product, mail is where
identity bleed actually hurts, and search is the wedge (`research.md`). So
identity and mail come first, then the day (calendar, Today, notifications),
then search across everything. Files and documents follow, the assistant
comes only once there are scoped tokens and real data to scope, and
collaboration and organisations come last because they are the most
expensive.

## Where we are (October 2026)

- `cloud/CONTRACT.md`: identities, `can_access_identity`, the scoped-session
  claim, per-area share tables.
- Built in parallel right now: accounts and cloudkit (sign-in, the identities
  switcher), mail (a server with real local delivery, no internet), drive (the
  app and sync).
- `apps/home`: the hub prototype over fixtures, with the seam for real data.
- Apps that already exist and are good: mail and mailcore (MIME, IMAP),
  calendar, docs (writes PDF, .docx, .odt, .rtf), sheets, slides, notes,
  chat, call, vault, ai (a local model).
- No outbound mail, no CalDAV, no collaboration, no phone.

---

## M1. Two identities, real mail

*A person uses Palmy for their Personal and Public mail, with their own
domain, on one laptop.*

| build | integrate |
| --- | --- |
| account sign-in on the device; the identity cache that `kit.identity_*` reads | **Resend** for outbound SMTP and inbound webhooks: no IP reputation to build up from zero |
| `apps/kit/identity.odin` (shell.md §3), adopted by mail, home and calendar | DNS for custom domains: SPF, DKIM (Resend signs), DMARC, guided setup with live checks |
| wm: pid → identity, the frame band, the bar switcher (shell.md §1) | **Rspamd** or the transport's own filtering for inbound spam, rather than writing a filter |
| mail: From card, Reply as…, refuse to send while the identity is ambiguous | **IMAP/SMTP submission** for third-party clients (P10), served by the mail area's server |
| Home over real data: mailcore's Maildir, per identity, through `store_load(.Device)` | |
| per-identity masked addresses for Public (Fastmail's best feature, research §7) | |

**Exit test.** For two weeks, send and receive through a custom domain on
Gmail-scale traffic (newsletters, receipts, real people) without a single
message sent from the wrong identity, and with DMARC passing on everything
sent. Then export the identity as mbox plus a contacts file and import it
into Fastmail.

**Risks.** *Deliverability* is the one most likely to kill the product, which
is why it is integrated rather than built. *Depending on Resend* is a
dependency like any other: keep transport behind an interface so SES or
Postmark can replace it. Confirm that Resend's inbound mail covers our volume
and attachment sizes before committing (**to verify**).

## M2. The day

*Today is real: events, people waiting, tasks, across both identities.*

| build | integrate |
| --- | --- |
| calendar and tasks tables per identity (the contract's rules); calendar app on them | **CalDAV / CardDAV** in both directions: serve them so phones and Thunderbird work; subscribe to Google and Outlook during migration |
| iTIP/iMIP invitations over our mail, sent from the event's identity | an existing CalDAV server library or service behind our auth, rather than writing RFC 4791 from scratch (**to choose**) |
| availability links between identities (busy only, product.md §5) | ICS import and export |
| the notification policy engine: person/time/machine classes, quiet sentences, one delivery per device | |
| the Screener for Public | |

**Exit test.** Invites sent and received with Google Calendar and Outlook
users. Accept, decline, reschedule and recurring events all round-trip
correctly. The Personal and Public calendars show each other's busy time and
nothing more. Notifications for a week arrive on one device only.

**Risks.** CalDAV interop is a long tail of quirks: Google drops task due
times, and New Outlook speaks no CalDAV at all (research §8). Budget for it
as ongoing work, not a milestone that finishes.

## M3. Search everything, offline

*The wedge. Typing in Home finds anything in any enrolled identity, in under
100 ms, unplugged.*

| build | integrate |
| --- | --- |
| a per-identity on-device index (one file per identity, so an identity can be removed from a device by deleting it) | possibly SQLite FTS5 as the index engine; this weighs speed of delivery against the three-library `ldd` (**decide**) |
| the query language and ranking prototyped in `apps/home/search.odin`, as a kit library every app calls | |
| the "N more in other identities" rule; the cloud fallback for identities not on this device, clearly labelled | |

**Exit test.** 200k messages and 20k files across four identities. Search
takes p95 < 100 ms with the network off. The selftest asserting that search
inside one identity returns only that identity runs in CI against the real
index, not only against fixtures.

## M4. Files and documents

*A person moves their Drive into Palmy.*

| build | integrate |
| --- | --- |
| drive sync daemon (drive area), conflict copies with history | **Office formats**: docs already writes .docx/.odt; import fidelity needs a reference: **LibreOffice headless** as a server-side converter and a fidelity oracle in CI, not as the editor |
| **carry**, with carry logs on both sides | WebDAV for third-party file managers |
| sharing within an identity: named people by default; public links expire and are listed | Google Takeout / OneDrive import, *resumable and with progress* (the complaint in research §8 is what to beat) |

**Exit test.** Import a real 30 GB Drive, edit .docx files that came from
Word and send them back without the recipient noticing, and carry 100 files
between identities with both carry logs complete.

**Risks.** Format fidelity never ends. Be honest in the interface: when a
.docx feature is not supported, say so on open rather than dropping it
silently.

## M5. The assistant, scoped

*"Ask the Northwind assistant" is real, and the scope test is the release
gate.*

| build | integrate |
| --- | --- |
| scoped token minting (accounts: access-token hook or token exchange, `palm_identity`) | the **local model** stays the default (ollama today, as a user process); a server model is opt-in per identity and labelled |
| tools exposed through `palm` with side-effect classes (`docs/PALM-CLI.md`); `read` runs freely, everything else becomes a proposal you approve | |
| the untrusted-content filter: strip hidden text, mark quoted material | |
| a prompt-injection test suite modelled on EchoLeak, the Gemini summary attack and Notion's lethal trifecta (research §6) | |

**Exit test.** The red-team suite fails to move data across identities or out
of the machine in 100% of cases, each area's pgTAP scope test passes against
the assistant's real tokens, and turning the assistant off for an identity
changes nothing else.

**Risks.** Local models on a laptop are weaker than server ones. That gap is
the honest cost of the privacy position. State it, and let an identity opt
into a server model knowingly, rather than pretending it isn't there.

## M6. Together: collaborative editing

*Two people edit one document at once, and offline edits merge.*

| build | integrate |
| --- | --- |
| a document model in docs/sheets/slides that maps onto a CRDT | **a CRDT library instead of writing one**: Yjs's Rust port through its C FFI (`yffi`) or Automerge's C API, both callable from Odin. Choose by document size, history compaction and how well rich text maps onto each (**decide with a spike**) |
| presence and comments, per identity | **Supabase Realtime** as the transport for updates, with the CRDT state stored per document in the owning identity's tables |

**Exit test.** Two people co-author a 40-page document across an
afternoon, one of them offline for an hour, with no lost edits and no merge
dialog.

**Risks.** This is the most expensive milestone, and the one where "from
scratch" pride costs the most. Integrate. Rich-text CRDTs are still young.

## M7. Devices

*The phone exists.*

- Android first (`ANativeWindow`, research and README "Beyond Linux"), with
  mail, calendar, Today and notifications once.
- Per-device, per-identity enrolment. A lost device is revoked in one action.
- Handoff of drafts and documents with cursor position, identity-scoped.

**Risks.** A software rasterizer on a phone battery. Measure before
promising. Touch is not a mouse.

## M8. Organisations

*Northwind, the company, adopts Palmy for its people.*

- A work identity may be attached to an organisation that can set domain,
  retention, device rules and assistant policy *for that identity only*,
  enforced in RLS, with a test that it can't reach the person's other
  identities (product.md, open question 1).
- SSO (OIDC, SAML), SCIM provisioning, admin console, billing.
- Migration from Google Workspace and Microsoft 365 at organisation scale,
  through the Gmail and Graph APIs, IMAP, and CalDAV where it exists.

**Risks.** Organisations will ask for powers over people that conflict with
the product's promise. Write the line down before the first sales
conversation.

---

## What we integrate and what we build, in one table

| area | decision | why |
| --- | --- | --- |
| mail transport | **Resend** (integrate) | deliverability and IP reputation can't be built quickly |
| spam | integrate (Rspamd or the transport's filtering) | an arms race we would lose |
| mail clients | build (apps/mail); serve IMAP for others | the identity UI is the product, and openness is P10 |
| calendar protocol | **CalDAV/CardDAV**, iTIP/iMIP (integrate a library) | interop is table stakes for switching |
| document formats | build writers (docs already does); **LibreOffice headless** as converter and oracle | fidelity needs a reference |
| collaboration | **CRDT library** (yffi or automerge-c) + Supabase Realtime | most expensive to get wrong |
| search | build on the device, possibly over SQLite FTS5 | it is the wedge, and it has to be local |
| auth | Supabase Auth + **passkeys** | phishing-resistant sign-in for an account that holds everything |
| AI | local model, our own tools and scope | scope is the product |
| calls with outsiders | integrate WebRTC (e.g. LiveKit) beside `apps/call`'s own protocol | strangers have browsers, not our app |

## Risks, plainly

1. **One account is one target.** Everything in one login makes it the most
   valuable credential a person owns. We need passkeys, device-bound
   sessions, a written threat model, and an answer to "what happens when this
   is phished?" before M1 ships to anyone but ourselves.
2. **Deliverability.** If our mail goes to spam, nothing else matters.
   Mitigated by integrating; not removed.
3. **Breadth against depth.** Forty-eight apps is a demo of the toolkit. A
   credible alternative needs about eight of them to be excellent: mail,
   calendar, files, docs, sheets, Home, chat and call. The roadmap above
   touches only those. The rest should freeze until M4.
4. **Supabase as the only backend.** RLS on every query is the security model
   and also a performance cost at scale. Keep the contract portable to plain
   Postgres. Nothing in it is Supabase-specific except auth claims.
5. **Odin's ecosystem.** No CRDT, no mature crypto beyond the basics, no
   CalDAV. Each gap is either a C library behind FFI (fine) or a rewrite
   (usually not). Decide per gap, on purpose.
6. **"Local first" against "works on the web".** The web build is Wasm over a
   sandboxed filesystem. Search and the assistant are weaker there. Say so in
   that build's interface.
7. **The identity model can be wrong for some people.** Some people want
   one inbox. All identities, with labels, is that inbox, and if it isn't good
   enough people will route around the whole product. Test it with people
   before M3.

## Decisions we need early

| decision | needed by |
| --- | --- |
| the identity-facing word ("identity") and the cross-identity verb ("carry") | M1 copy |
| does the wm own identity (pid-launched) or trust the app? (shell.md) | M1 |
| Resend inbound, or a self-hosted MX for inbound with Resend for outbound only | M1 |
| SQLite FTS5 or a hand-written index | M3 |
| yffi or automerge-c | spike before M6 |
| whether an organisation can attach to a work identity, and the written limit of its powers | before any business customer |
