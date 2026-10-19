# Palmy: one account, several selves

The product principles and the information architecture for the Palmy
account and the apps on top of it. `research.md` is the evidence. `shell.md`
covers how identity appears in the window manager, the greeter and every app.
`roadmap.md` sets the order of work. The prototype of the hub is `apps/home`,
and its screenshots are in `img/`.

## The bet

Google and Microsoft built suites for one self, then bolted on extra accounts.
The seams show everywhere: the first account you signed into becomes the
default, `authuser=1`, "Pick an account", invites sent from the wrong calendar,
a work assistant that can read the CEO's mail because a SharePoint folder was
always open. We start where they ended up. **A person has one account and
several identities, and the identity is the main axis of everything:**
storage, search, the assistant's reach, notifications and colour. Two more
choices sit on top of that: everything is indexed and usable on the device,
and the database, not the interface, enforces the boundaries between
identities.

We win where the incumbents can't follow without breaking their own model:
separation you can rely on, search that is fast and works offline, an
assistant whose reach you can state in one sentence, and a calm day.

---

## 1. The model

```
Person ─── one Palmy account (auth.users)       "Camille Roux"
  │          owns devices, billing, the password, recovery
  │
  ├── Identity  Personal   camille@palm.test        teal    P
  ├── Identity  Northwind  camille.roux@northwind.coop  blue  N   (work)
  ├── Identity  Public     hello@camille.studio     amber   P
  └── Identity  Halcyon    camille@halcyon.dev      violet  H   (project)
          │
          └── objects, each owned by exactly one identity
                messages · threads · files · docs · sheets · slides
                events · calendars · contacts · tasks · notes · chats
                credentials (vault) · browsing state · assistant memory
```

**Every object belongs to exactly one identity.** That is the contract's
`identity_id not null` rule, said as a product rule. No object is shared
between identities. When two identities need the same thing, each holds its
own copy, or there is an explicit, recorded link (§5).

**The person is not an identity.** The account sits above the identities. It
owns devices, billing and recovery, and it can *see* all of its identities at
once (an unscoped session). It never *acts* as "all of them". Every send,
share, create, invite or assistant request happens as exactly one identity.

**Kinds of identity** (`public.identities.kind`) set defaults, not
permissions:

| kind | example | defaults |
| --- | --- | --- |
| personal | Personal | notifications: people only; assistant: on, local model |
| work | Northwind | quiet outside working hours; the organisation may require policies (retention, a server model, its own domain) |
| public | Public | used for sign-ups, shopping, talks and newsletters; a digest once a day; the Screener is on |
| project | Halcyon | for a side project or a company: its own domain, its own collaborators, archived when it ends |

### Names

What things are called in the interface. Short, plain, and never a brand
mascot.

| name | what it is | why this word |
| --- | --- | --- |
| **account** | the person's Palmy login | ordinary word, used only for login, devices and billing |
| **identity** | one self: an address, its data, its assistant | "profile" is taken by browsers, "space" sounds like a place rather than a self, and "persona" sounds fake. "Identity" matches what From: actually means |
| **All identities** | the mixed view in Home and the shell | says exactly what it is. Not "Unified" or "Everything" |
| **Home** | the hub app (`apps/home`) | where the day starts |
| **Today** | Home's default surface | a day, not a dashboard |
| **Commands** (Ctrl K) | the command palette, system-wide | |
| **New** (Ctrl N) | quick-create, always asking *as whom* | |
| **carry** | copy an object from one identity to another, recorded on both sides | a deliberate verb for a deliberate act. "Move" and "share" both suggest something softer |
| **carry log** | the per-identity record of everything carried in or out | answers "how did this get here?" |
| **link** | a standing, explicit connection between two of your identities, e.g. shared free/busy | narrow and listed (§5) |
| **quiet** | an identity's notification policy, said in words | "Quiet after 18:00", "Daily digest at 17:00" |
| **the Northwind assistant** | the assistant inside one identity | named after its identity, so its reach is in its name |

---

## 2. Principles

Each one is a rule with a reason and a test that would catch it being broken.

### P1. The identity is a property of the object and the window, never of sign-in order

*Why:* Google's "default account is the first one you signed into" and
`authuser` numbering, and Microsoft's "one email, two accounts", cause most of
the wrong-account and "you need access" failures (research §1).

*Rule:* every object address carries its identity —
`palm://northwind/doc/7f3c…` — and opening it lands in that identity. A link
to an object one of your other identities owns opens there, with one line
saying so. A link to something none of your identities can read says *which
identity it was shared with*, if the sharer allowed that, and never asks you
to switch accounts.

*Test:* opening a Northwind link from a Personal mail opens it in Northwind,
with a one-line notice. It never returns an access error.

### P2. The identity is always visible: label when mixed, tint when single, colour never alone

*Why:* bleed happens when people can't see which self they are acting as
(research §2).

*Rule:*
- **Mixed views** (All identities, search results, the shell's notification
  list): every item carries a small label, a coloured dot plus the identity's
  name.
- **Single-identity windows**: the labels go and the *window* is tinted
  instead. That means a 3 px band across the top, the identity chip in the
  title area, and the identity colour on the primary action.
- **Colour is never the only signal.** Every colour comes with a name or a
  monogram letter, so the distinction survives colour blindness, greyscale and
  a screenshot pasted into a chat.
- Composing, inviting and sharing show the identity *before* you type: a From
  card at the top, in the identity's colour, with its address.

`img/01-today-all-light.png` shows the labels and `img/02-today-work-light.png`
shows the tint. `shell.md` specifies both for every app.

### P3. Nothing defaults across identities; when it is ambiguous, ask

*Why:* Outlook chooses the sender "from context" and sometimes switches
silently, and calendars choose the organiser from whatever the browser has
(research §2).

*Rule:* an action takes its identity from, in order, (1) the object you are
acting on (a reply goes out as the identity that received the mail), then
(2) the window's identity. If neither settles it, as in the All identities
view, the system **asks** and does not guess. Home's New refuses Enter until
an identity is chosen (`img/06-create-choose-light.png`). Replying as a
different identity than the one that received the message is allowed, but it
is a separate command, **Reply as…**, that shows the change in both colours.

*Test:* `home --selftest` asserts that Ctrl N in the mixed view refuses to
create until an identity is chosen.

### P4. Crossing between identities is a named, recorded act

*Why:* identities are only worth having if the boundary holds. Ambient
convenience is how the boundary disappears without anyone noticing.

*Rule:* there are exactly three ways across (§5): **carry**, **link** and
**Reply as / Forward to my…**. Each is explicit, each is shown in both
identities' colours, and each writes a row both sides can read
(`cloud/CONTRACT.md`, Sharing). Nothing else crosses: no shared clipboard
between identities by default, no "recent files" mixing work and personal
inside an app, and no assistant that reads across.

### P5. Local first: the device holds a working copy, the cloud is where it converges

*Why:* Linear and Superhuman are loved for speed, which comes from local data
(research §3). Proton is held back by the server being unable to search what
it can't read. A machine should work unplugged.

*Rule:* mail, files, events, contacts, tasks and notes for every identity
enrolled on the device are stored and indexed on it. Search, Today and the
assistant read the local index first. The cloud stores, delivers and
converges. "Synced 2 min ago · Everything here works offline" is a sentence
the interface can always truthfully say, or it says what is not available.

### P6. Search is the front door: just type

*Why:* search is the most-cited reason to leave Outlook, Teams and Gmail
(research §3).

*Rule:* in Home, typing anything searches; there are no single-letter
shortcuts to collide with it. Results are grouped by kind, ranked inside each
group, and every result is labelled with its identity. Spec in §6.

### P7. A calm day, not a dashboard

*Why:* 275 interruptions a day (research §5). A grid of widgets is one more
place to look.

*Rule:* Today is one column of reading order split into two: the date, one
sentence that sums up the day, the next event, then Agenda, Tasks, Waiting on
you, and Recently opened. It has no charts, no unread-count badges beyond a
quiet number beside a section title, no "insights", and nothing that animates
on its own. Spec in §7.

### P8. Notifications: people over machines, once, under a policy written in words

Spec in §8.

### P9. The assistant lives inside one identity, enforced by the database

*Why:* EchoLeak, the hidden-text attack on Gemini summaries, the Notion
"lethal trifecta" and Copilot surfacing overshared files all share one shape
(research §6).

*Rule:* spec in §9. In one sentence: the Northwind assistant holds a session
scoped to Northwind, the database refuses everything else, and anything it
wants to send out needs your yes.

### P10. Leaving is a feature

*Why:* Takeout failures, New Outlook with no CalDAV, and .docx fidelity
(research §8), at a time when both incumbents are raising prices to pay for
AI (§9).

*Rule:* IMAP and SMTP for mail, CalDAV and CardDAV, WebDAV or a plain sync
folder for files, `.docx`/`.xlsx`/`.pptx` and ODF in and out, and a full
export per identity that resumes, shows progress, and is useful without us.
An identity can be exported and deleted on its own without touching the
others.

---

## 3. Information architecture

```
┌───────────────────────────── the shell (apps/wm) ─────────────────────────────┐
│ bar: [identity switcher ● Northwind ▾]  clock  [notifications]  [Commands]    │
│                                                                               │
│   ┌─ Home ─────────────┐  ┌─ Mail ●Northwind ───┐  ┌─ Docs ●Personal ──┐      │
│   │ Today              │  │  one identity per   │  │                   │      │
│   │ Search (just type) │  │  window; tinted     │  │                   │      │
│   │ New (Ctrl N)       │  └─────────────────────┘  └───────────────────┘      │
│   │ Commands (Ctrl K)  │                                                      │
│   └────────────────────┘                                                      │
└───────────────────────────────────────────────────────────────────────────────┘

 Home        the person's window: sees every identity, acts as one at a time
 Apps        Mail, Calendar, Files/Drive, Docs, Sheets, Slides, Notes, Chat,
             Call, Tasks, Contacts, Vault, AI: each window is in one identity
             (or in All identities for viewing only: Mail's unified inbox,
             Calendar's combined day)
 Shell       the switcher, notifications, Commands, the greeter
 Account     Settings → Account: identities, devices, links, carry logs, export
```

**Windows have an identity.** A Mail window is in Northwind or in Personal.
Opening an object opens a window in that object's identity. A window may show
All identities for *reading* (Calendar overlaying every calendar, Mail's
combined inbox), but any action in it resolves its identity under P3. The
window's identity is what the shell bar shows when that window is focused.

**The switcher changes where new things go, not what exists.** Switching the
shell to Personal changes the default identity for new windows, for New, and
for the assistant. Windows already open keep their own identity and tint.

### Home's surfaces

| surface | key | does |
| --- | --- | --- |
| Today | (default) | the day across the identities in view (§7) |
| Search | type anything | results across kinds, grouped and labelled (§6) |
| New | Ctrl N | mail, event, task, note or document, as a chosen identity |
| Commands | Ctrl K | switch identity, create as…, ask an identity's assistant, quiet an identity, carry, open an app |
| Carry | Ctrl Shift C | copy the selected object to another identity |
| Identity rail | Ctrl 0–4 | All identities, or one, each with what is waiting there |

---

## 4. Making the identity visible

`shell.md` holds the full component spec. In brief:

- **Colour.** Each identity has a palette colour (`public.identities.color`)
  with a light-theme and a dark-theme value, both checked for text contrast.
  There are eight hues, assigned so that no two of a person's identities share
  one.
- **Monogram.** The first letter of the identity's name on a 15% wash of its
  colour. It appears wherever an identity is chosen (switcher, From, carry).
- **Label** (`●  Northwind`): a dot and the name in muted text, for rows in
  mixed lists. **Chip**: the same on a 10% wash, for headers and the one place
  in a view that states the scope.
- **Window tint.** A 3 px band at the top edge of every window in that
  identity's colour. In All identities, every identity's colour side by side.
- **From card.** In compose, invite and share: monogram, name and address, in
  the identity's colour, above the first field.

```
Mixed list row                         Single-identity window
┌──────────────────────────────────┐   ┌██████████████████████████████████┐ ← 3px tint
│ 10:00 ▌Weekly design review  ● Northwind │   │ 10:00 ▌Weekly design review      │
│ 12:30 ▌Lunch with Théo       ● Personal  │   │ 14:00 ▌Lumen Health call         │
└──────────────────────────────────┘   └──────────────────────────────────┘
        ▌ = identity colour bar              no labels: the window says it
```

---

## 5. Crossing between identities

| act | what happens | recorded |
| --- | --- | --- |
| **carry** | a *copy* is created in the target identity and owned there. The source keeps the original. No thread, share link or history comes along. | a row in both identities' carry logs: who, what, when, from, to, content hash |
| **link: availability** | one identity's calendar shows another's busy blocks, as "Busy (Personal)" with no title | listed in Account → Links, revocable, and shown on both calendars |
| **link: forward** | mail to one identity is forwarded to another, with a banner on each forwarded message | listed, revocable |
| **Reply as…** | reply from a different identity than the one that received the message | the outgoing message records it; compose shows both colours |
| **Forward to my…** | send a message to another of your own identities, i.e. carry for mail | carry log |

What **cannot** cross: credentials (the vault has no cross-identity verb at
all, `docs/PALM-CLI.md`), browsing state, assistant memory, and the
clipboard, unless you explicitly paste across, which the shell shows as a
carry (`shell.md`).

`img/08-carry-light.png` shows the carry sheet: the object with its current
label, the destination chosen with its colour, the crossing stated in colour
(`● Personal → ● Northwind · a copy, not a link`) and in words.

---

## 6. Universal search

**Where:** Home (type anything), the shell's Commands (results appear below
the commands), and each app's own search box, which is the same engine
limited to that app's kinds.

**Scope:** the identities the window can see. In Home's All identities view
that means all of them, each result labelled. Inside one identity it means
only that one, plus a single line: *"7 more in your other identities. Ctrl 0
shows them, each labelled."* Home is the person's window, so it may say that
other identities have matches. An assistant never may, and it never learns
that count.

**Query language:** plain words must all match. `in:northwind` (or
`in:work`), `type:mail|event|task|doc|file|chat|person`, `is:unread`, and
later `from:`, `with:`, `before:`/`after:`, `has:attachment`. Unknown
operators are reported, never silently ignored.

**Ranking:** a title hit beats a person hit beats a body hit. Then unread,
then recency. Results are grouped by kind (Mail, Events, Tasks, Documents,
Files, Chat, People), and each group is ranked on its own, so one kind of
result can't bury the others.

**Index:** on the device, per identity, one index file per identity, so an
identity can be removed from a device by deleting its index. Mail bodies,
document text, file names and paths, event titles and places, contacts, chat
lines. Never the vault.

**Honesty line:** results end with *"Searched 36 items on this device, in
every identity. Nothing left the machine."* When a cloud search is needed
(an identity not enrolled on this device), the line says so.

`img/03-search-light.png` shows search across identities and
`img/04-search-halcyon-light.png` shows search inside one.

---

## 7. Today

```
┌ rail ─────────────┬──────────────────────────────────────────────────────────┐
│ (CR) Camille Roux │ [⌕ Search mail, files, events, people…  just type]  ⌘ Commands  [+ New] │
│                   │                                                          │
│ IDENTITIES        │  Monday 19 October                                       │
│ ▣ All identities 5│  Good morning, Camille. Six events, five people waiting  │
│ P Personal      1 │  on you, three tasks due.                                │
│ N Northwind     2 │                                                          │
│ P Public        1 │  ┌ NEXT · in 20 min ─────────────────────────────────┐   │
│ H Halcyon       1 │  │▌Weekly design review   10:00–10:45 · Room 2  ●N [Join]│
│                   │  └───────────────────────────────────────────────────┘   │
│                   │  AGENDA 6                   WAITING ON YOU 5             │
│                   │  07:30 ▌Run…      ● Personal (PS) Priya Shah ● Northwind │
│                   │  09:40 ●───────── now        Q4 roadmap: sign-off…       │
│                   │  10:00 ▌Design review ● Northwind  (IR) Ines Roux …      │
│ NOTIFICATIONS     │  …                          …                            │
│ Personal  people  │  TASKS 4                    RECENTLY OPENED              │
│ Northwind quiet18 │  ○ Sign off Q4 roadmap      ▦ Q4 Roadmap  ● Northwind    │
│ ☁ Synced 2 min ago│  [✦ The assistant works inside one identity. Ctrl 1–4]   │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

Rules:

- **The sentence beats the widgets.** "Six events, five people waiting on
  you, three tasks due" replaces three counters.
- **Next** is the one emphasised element: the next event, in its identity's
  colour, with its single most useful action (Join, Directions, Open).
- **Agenda** is today only, with a *now* line. Finished events are dimmed,
  not hidden. It shows events from every identity in view, which is how a
  clash between a work call and a personal appointment becomes visible
  without either calendar reading the other.
- **Waiting on you** means a *person* is waiting: a thread addressed to you
  with no reply from you, or a review request. Never newsletters, never
  notifications from machines. At most five per identity, oldest first
  after anything that is time-critical.
- **Tasks** are those due today or overdue. Overdue is the only red on the
  page.
- **Recently opened** lists objects, not apps.
- **The assistant line** says where the assistant can look (§9).

---

## 8. Notifications

Three classes, decided by *who* is behind the notification:

| class | example | default |
| --- | --- | --- |
| **person → you** | a message addressed to you, a mention, a call | interrupts, unless the identity is quiet |
| **time** | an event starting, a task due at a time | interrupts at that time, even when quiet (configurable) |
| **machine** | newsletters, receipts, CI, shares from people you don't know | never interrupts: it goes to Today and the identity's digest |

- **A policy per identity, written as a sentence**: "People only", "Quiet
  after 18:00", "Daily digest at 17:00". The sentence appears in Home's rail
  and in the shell, so nobody has to open a settings page to learn what will
  happen.
- **Delivered once.** A notification goes to the device you are using (the
  one with input in the last minute), and its read state syncs to the others.
  It never arrives on four devices at once.
- **Summaries are marked.** An AI summary is labelled as one, sits beside
  the original, and is never shown alone. There are no summaries of news
  sources.
- **Unknown senders are screened** in Public by default, HEY-style: the first
  message from a new sender waits until you accept the sender.
- **No badge on the dock and no red dots on apps.** Today is where the count
  lives.

---

## 9. The assistant

- **One assistant per identity**, named after it: "the Northwind assistant".
  It is the same local model with a different scope, which means a different
  session, a different memory, and different tools.
- **Scope is enforced by the database.** The assistant's session carries
  `palm_identity` (`cloud/CONTRACT.md`). Asked for another identity's data, it
  gets nothing, and the pgTAP test asserts it. On the device, the CLI applies
  the same rule (`PALM_IDENTITY`, exit 5, `docs/PALM-CLI.md`).
- **In All identities it asks first.** Home says "The assistant works inside
  one identity. Choose one to ask it." There is no "ask all of my
  identities" command. Answering across identities would be the very ambient
  access the design exists to prevent. The person can ask each identity in
  turn, and see that they did.
- **Incoming content is untrusted.** Before a model sees a mail or document,
  invisible text (zero-size, same-colour, off-page) is stripped, and the
  content is marked as quoted material, not instructions.
- **Anything outbound needs approval.** Sending, sharing, inviting, fetching a
  URL, or calling an external tool is a proposal you confirm, shown in the
  identity's colour. Read-only work inside its own identity needs no approval.
- **Off by default per identity, and nothing else depends on it.** Turning the
  Northwind assistant off leaves search, Today, sorting and spelling as they
  were.
- **The local model is the default.** A server model is opt-in per identity
  and labelled as such wherever it answers, because a server model can read
  what it is given (`README.md`, "The parts that are genuinely hard").

---

## 10. Offline first

- Every identity enrolled on a device syncs its data down and indexes it
  there. Enrolment is per device and per identity, so a work laptop can carry
  only Northwind.
- Writes go to the device first and sync when they can, with one conflict rule
  per kind: CRDT merge for documents (`roadmap.md`), last-writer-wins with
  history for files, and server ordering for mail.
- The interface never shows a spinner where cached data exists. Staleness is
  stated ("Synced 2 min ago"), not hidden.

---

## 11. What we deliberately won't do

- **No "default account".** Every action has an identity chosen by P3, or it
  asks.
- **No ambient cross-identity access.** That rules out a unified "recent
  files" in apps, cross-identity clipboard history, an assistant that reads
  everything, and "people you may know" drawn from another identity's
  contacts.
- **No dashboard of widgets** on Today: no charts, streaks, productivity
  scores or "insights".
- **No AI that is on by default and can't be removed**, and none bundled as a
  reason to raise prices.
- **No public link sharing by default.** Public links expire, are always
  labelled public, and are listed per identity.
- **No ads, and no reading content for anything except the person's own
  features.**
- **No feature that only works online when it could work offline.**
- **No notification on more than one device**, and no red badges.
- **No proprietary-only formats.** Every object has an open export.
- **No guessing the sender.**

---

## 12. Open questions

1. **Can a work identity be controlled by an organisation?** Northwind may
   want its own domain, retention, device policy and a say over the assistant.
   That makes a work identity partly *theirs*. The model has room for it (an
   identity with an organisation attached), but the account must never let an
   organisation reach the person's other identities. That needs a written
   rule and a test.
2. **Identity-to-identity links for availability** need a shape that is
   useful without leaking titles. The proposal is busy blocks only, but
   "Busy (Personal)" is itself information.
3. **Shared objects with other people.** A Northwind doc shared with a
   colleague is ordinary sharing within one identity. A doc shared with a
   colleague's *personal* identity is a policy question for the organisation.
4. **How much of the identity colour may an app use?** `shell.md` proposes
   the tint band, the chip, and the primary action only.
5. **Does Home's "N more in other identities" line pass the threat model?**
   Home is the person's window, and the person may know. A shoulder-surfer
   learns that a match exists. That is acceptable for a person's own screen;
   it is a setting for a shared screen.
