# Notifications

One notification service for the whole system, so that no app has to invent
its own: `palm-notifyd` per session, `kit.notify` for Palmframe's apps,
`org.freedesktop.Notifications` for everything else, toasts and a center that
say whose a notification is, and a policy per identity written as a sentence
(product.md §8: "Northwind: quiet after 18:00").

What is built and verified, and what is only designed, is said in each
section; the short version is at the end ([Status](#status)).

```
 Palmframe apps                    third-party apps (libnotify, Firefox, Chromium)
 kit.notify({...})                 Notify(app, replaces_id, ..., hints)
      │ unix socket, one JSON           │ session bus
      │ object per line                 │ org.freedesktop.Notifications 1.2
      ▼                                 ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │ palm-notifyd  (notify daemon, per session, from session.d/60-notify) │
 │  identity: the sender's PALM_IDENTITY ▸ browser profile ▸ wm         │
 │  dedupe by key (+ tombstones) ▸ policy for that identity ▸ decision  │
 │  toast | center | digest   ·  sound via PipeWire  ·  digests on time │
 │  history.json  policies.json  $XDG_RUNTIME_DIR/palm/notify.state     │
 └───────┬───────────────────────────────┬─────────────────────────────┘
         │ starts, watches               │ watched by
         ▼                               ▼
   notify toasts                    notify center       wm bar (reads notify.state)
   layer shell, top right           layer shell, right edge
```

## Why it is shaped this way

**A socket for our own apps, the bus for everyone else.** Palmframe ships no
session bus by default (distro/notes/runtime.md: the system bus exists for
iwd and BlueZ), and a palmy app saying "you have mail" should not need one.
The socket gives the daemon the sender's pid through `SO_PEERCRED`, and with
it `/proc/<pid>/environ` and the sender's `PALM_IDENTITY`, without a bus round
trip; it speaks the same JSON `notify list --json` prints, so the CLI, the
surfaces and apps share one spelling of a notification. The freedesktop
interface is still served -- on a session bus that `session.d/45-dbus-session`
now starts -- because that is the only door Firefox, Chromium and libnotify
know. Both doors end in the same `deliver`: one dedupe, one policy, one
center.

**The daemon draws nothing.** Toasts are a separate process the daemon starts
when something must be shown and restarts if it dies. A crash in drawing never
loses a notification; the daemon runs, and is tested, with no compositor; and
it starts from `session.d` before the window manager exists.

**One binary, four faces.** `notify daemon`, `notify toasts`, `notify center`
and the CLI (`notify send|list|quiet|dnd|...`, docs/PALM-CLI.md). The CLI and
both surfaces are clients of the daemon over the same socket apps use, so
there is one implementation of what a notification is.

## A notification

| field | meaning |
| --- | --- |
| `key` | **stable, names the object**: `mail:<Message-ID>`, `event:<uid>@<start>`, `call:<call-id>`. The same key from any app is the same notification. Empty: `<app>:<id>`. |
| `app` | the app's command name (`mail`); third parties: their app name |
| `identity` | a handle. Empty means: the sender's `PALM_IDENTITY`, else the browser profile its process runs in, else the window manager's view (requested below) |
| `class` | `person` (someone wrote to you, a call), `time` (an event, a reminder, an alarm), `machine` (receipts, CI, sync, updates). Third parties: from the freedesktop `category`, else person (low urgency: machine) |
| `urgency` | `low`, `normal`, `critical`. Critical is what may break through, when allowed |
| `category` | freedesktop-style; `call.incoming` is a call, `alarm` an alarm, `x-palm.prompt` the answer to something the person just did |
| `title`, `body` | plain text (markup from third parties is stripped) |
| `link` | the deep link a click on the body runs: `mail open <id>` |
| `actions` | `key`, `label`, optional `run` (a deep link). Without `run`, the click goes to an app listening (`kit.notify_listen`) and, for third parties, `ActionInvoked` |
| `timeout_ms` | how long a toast stays; 0 is by class (person 8 s, time 10 s, machine 6 s, digest 12 s, critical until acted on) |

Every notification also carries `spoken`: its accessible text, in the order a
person would say it ("Incoming call from Call, Northwind identity, urgent.
Ines Roux. Design review. Actions: Answer, Decline."). Nothing on a toast
means something through colour alone: the identity's name is written next to
its colour, and the class is in the words as well as the icon.

**Deep links run as the notification's identity**, without a shell: argv is
split on spaces and quotes, and `PALM_IDENTITY` is set to the notification's
identity, so a work notification opens the work mail whoever clicked it.

## Policies: a sentence per identity

The sentence is the interface; the struct is how it is kept. `notify quiet`
parses a sentence, the daemon stores the structured policy
(`$XDG_CONFIG_HOME/palm/notify/policies.json`, with the rendered sentence
beside it for anyone who reads the file), and everything that shows a policy
shows the sentence rendered back. The two round-trip, and an unreadable
clause is refused and quoted, never guessed.

| clause | means |
| --- | --- |
| `Quiet after 18:00` | quiet hours until 08:00 |
| `Quiet after 18:00 until 07:30`, `Quiet 22:00–07:00`, `Quiet between 22:00 and 07:00` | quiet hours |
| `Quiet`, `Quiet until 14:00`, `Quiet for 2 hours` | a one-off quiet (`Quiet` alone: until 08:00) |
| `Not quiet until 08:00`, `Resume` | set the quiet hours aside until they end; end a one-off quiet |
| `Do not disturb`, `Focus until 15:30`, `Focus for 45 minutes` | this identity's do-not-disturb |
| `People only` | only people interrupt; reminders go to the center |
| `Daily digest at 17:00` | machines' notifications are batched into one, at that time |
| `Calls break through`, `Alarms break through`, `Calls and alarms break through` | what may interrupt a quiet identity or do-not-disturb |
| `Reminders wait`, `Nothing breaks through` | the opposite |
| `Forge in the digest`, `Mute Chromium`, `Chat always` | per-app rules |
| `Everything` | back to the default |

`notify quiet set` replaces the policy, `add` adds clauses, `check` parses
without saving, `clear` resets, `get`/`list` read. `set` takes the clause with
or without its leading "Quiet": `notify quiet set --identity work "after
18:00"`.

The **default** (no sentence; shown as "People and reminders"): people and
reminders interrupt, machines go to the center silently, nothing breaks
through do-not-disturb.

**The decision**, in the order a person would explain it (policy.odin:
`decide`, every outcome with its reason in words, shown in the center as
"why this did not interrupt"):

1. A muted app: the center, silently.
2. A prompt (`x-palm.prompt`): shown — the person asked seconds ago.
3. Do not disturb (the person's, `notify dnd on`, or the identity's): held.
   Only a call, if `Calls break through`, or an alarm, if `Alarms break
   through`, is shown.
4. Quiet (hours or one-off): held for the digest. A call is shown only with
   `Calls break through`; an alarm with `Alarms` (or reminders) allowed; a
   reminder with `Reminders` allowed (the default) unless `People only`.
5. Low urgency: the center. An app `in the digest`: the daily digest.
   An app `always`: shown.
6. Otherwise by class: a person is shown; a reminder is shown unless `People
   only`; a machine goes to the daily digest if there is one, else the
   center.

**Digests.** What quiet or do-not-disturb held goes out as one notification
the moment the hold lifts ("3 notifications while quiet": "Mail 2 · Forge 1",
then the first person by name). What waits for the daily digest goes at its
time; something that arrives at 17:05 for a 17:00 digest is tomorrow's, not a
digest of one. The digest is the one interruption that stands for all of them,
and the held notifications stay in the center under their apps.

**Sound.** Two tones are synthesised into the runtime directory at start (a
chime; a ring for calls) and played with `pw-play` when PipeWire's socket is
there, else `paplay`, else not at all. Only what is shown makes a sound: a
quiet identity is silent, and a call that breaks through rings.
`PALM_NOTIFY_SOUND=off` turns it off; freedesktop's `suppress-sound` is not
yet read.

## Delivered once, on this device

- **Same key, same notification.** A second send updates the words in place;
  it is not a second toast and not a second sound. `renotify` (the sender says
  this is news) puts it back on screen.
- **Withdrawn or cleared keys are remembered for a week** (tombstones), so a
  sender that repeats itself, or two apps that both know about the same
  message, are heard once.
- **Read stays read.** A read notification repeated stays read and off screen.
- **Third parties**: `replaces_id` maps to the key of what it replaces (from
  any connection: `notify-send -r` is a new process each time); the hint
  `x-palm-key` lets a third party name its object.

## The surfaces

**Toasts** (`notify toasts`, started by the daemon): one layer-shell surface,
top right, Overlay, 384 px wide, up to three toasts, newest on top, a call
pinned above everything, then "N more in the center". Each toast leads with
whose it is — a 3 px band and "● Northwind" in the identity's colour — then
the app, the sender, the words, why it broke through when it did ("Northwind
is quiet; calls break through"), and the actions as buttons (a call's Answer
is the primary one). A hairline along the bottom shows the time left; it stops
while the pointer is over the stack, and so does the countdown. Critical
toasts stay until acted on.

Keyboard: `notify focus` (the binding proposed below) re-creates the surface
with exclusive keyboard focus: ↑/↓ choose, Enter opens, 1–3 press an action,
Delete dismisses, Escape gives the keyboard back. With no toast up, `notify
focus` opens the center instead.

**The center** (`notify center`; `--window` for an ordinary window): a panel
down the right edge. A header with the unread count and the person's
do-not-disturb switch; an identity filter (All, then each identity with its
unread count); then per identity its sentence, what it is doing now ("Quiet
now, until 08:00"), and one switch — "Quiet Northwind until 08:00", which
during quiet hours turns them off until they end — followed by its
notifications grouped by app, each with an unread dot in the identity's
colour, why it did not interrupt, a "Held" badge while waiting for a digest,
and its actions. Mark all read, Clear read. Keyboard: ↑/↓, Enter, R (read),
Delete (clear), 0–9 (identity filter), D (do not disturb), Q (quiet the
identity in view), Escape.

Screenshots: `notify shots <dir>` (offscreen, light and dark, invented
identities) and `apps/notify/e2e.sh --shots <dir>` (the real surfaces on a
headless sway, Chromium included).

Two palmy limits shape the toasts, and are requests below: a layer surface
cannot change size after it is created, so the surface is re-created at the
stack's measured height whenever it changes (measured offscreen first, so it
is never drawn at the wrong size); and buffers are XRGB, so the stack is one
opaque panel with dividers rather than floating cards with shadows.

## The command line

```
notify send --identity work --class person "Priya Shah" "Q4 roadmap?"   # mutate
notify list --json [--unread --showing --held --app mail]                 # read
notify read <id|key|all> | dismiss <id|key> | withdraw <key|id>          # idempotent
notify invoke <id> [action]                                              # mutate
notify clear <id|key|all> --yes                                          # destructive
notify quiet set|add|check|clear|get|list --identity work "after 18:00"  # idempotent
notify dnd on|off|toggle|status [--minutes 45]                           # idempotent
notify status --json | digest --identity work | focus | center | daemon
```

Scope follows docs/PALM-CLI.md: `PALM_IDENTITY`, narrowed by `--identity`,
never widened — and the daemon applies it again from the caller's own
environment. Inside an identity, sending as another exits 5, listing shows
that identity alone, and changing another's policy or the person's
do-not-disturb is refused. Honestly: a process of the same user can start a
child with another environment, so this guards against mistakes and confused
agents; the boundary between identities is the cloud's (CONTRACT.md). Exit 6
means the daemon is not running.

## Files and protocol

| | |
| --- | --- |
| `$XDG_RUNTIME_DIR/palm/notify.sock` | the socket (0600, in a 0700 directory, same uid checked) |
| `$XDG_STATE_HOME/palm/notify/history.json` | notifications (≤ 400, read ones go after 14 days), tombstones |
| `$XDG_CONFIG_HOME/palm/notify/policies.json` | the policies, structured, with each sentence |
| `$XDG_RUNTIME_DIR/palm/notify.state` | for the bar: `unread N`, `showing N`, `dnd 0/1`, then `identity <handle>\t<none/quiet/dnd>\t<unread>\t<sentence>` per identity; rewritten only when it changes |
| `$XDG_CONFIG_HOME/palmframe/identities.json` | read, not written: `[{"handle","name","color"}]`, the seam apps/browser also reads; colour is a palette name or `#rrggbb` |

Socket requests, one JSON object per line, one reply per line: `send`,
`withdraw`, `read`, `dismiss`, `hide`, `invoke`, `clear`, `list`, `policies`,
`quiet`, `dnd`, `status`, `watch` (a stream of `{"ev":"rev"}`, `focus`,
`center`, and `action` for listeners), `focus`, `center`, `digest`, and
`clock` (only on a daemon started with `--clock`, for tests). The header of
apps/notify/ops.odin lists each with its fields.

## Once, across devices

product.md §8: "A notification goes to the device you are using … and its
read state syncs to the others. It never arrives on four devices at once."

**What crosses the network is small.** The notifications themselves never
leave the device: each device's mail, calendar and chat sync bring the same
objects to every device, and each device's daemon receives the same keys from
them. What the devices must agree on is, per identity and key: has it been
shown somewhere, and has it been read or withdrawn. That is
`cloud/supabase/migrations/20261020300000_notify.sql` (**built, tested**):

| | |
| --- | --- |
| `notify_state (identity_id, key, state, device_id, updated_at)` | `shown` < `read` < `withdrawn`; a state only ever moves forward |
| `notify_presence (identity_id, device_id, active_at)` | when each device was last used |
| `notify_here(identity, device)` | "this device was used just now" |
| `notify_claim(identity, key, device) → yours / elsewhere / read / withdrawn` | should this device put it on screen; the first claim wins (primary key) and the device in use within the last minute wins over the others |
| `notify_mark(identity, key, device, state)` | a read or a withdraw, carried to the other devices |

Everything goes through `can_access_identity`, and the device must be one of
the identity's own, live devices: a device holds one scoped session per
identity it carries (accounts' `devices`), so Northwind's session on the
laptop can neither see nor write Personal's state. `tests/notify_once.sql`
asserts it (24 assertions, among them the contract's scope test), and the
whole suite passes with the migration in (609/609).

**The daemon's half (designed, not built):**

1. On a notification for identity X whose key is shared (not `<app>:<id>`),
   before deciding, call `notify_claim(X, key, this device)` with X's scoped
   session (the delegated session accounts keeps for this device). `yours` →
   decide as today. `elsewhere` → the center only, no toast, no sound.
   `read`/`withdrawn` → store it read, or drop it. Offline or no session →
   decide as today: a notification must never be lost to a network.
2. On read, dismiss, invoke or withdraw → `notify_mark`.
3. Every 30 s (or on Realtime for `notify_state` filtered by identity), take
   down what other devices marked: off screen, read in the center.
4. Presence: the window manager writes the time of the last input (requested
   below); the daemon calls `notify_here` for each identity at most every
   15 s while it changes.

It needs a cloud client in the daemon (apps/cloudkit over PostgREST, one
scoped session per identity), a thread so a slow network never blocks the
socket, and the wm's input time. Those are the reasons it is not in this
round; the database half is, because it is where the guarantee lives.

## Adoption, app by app

Every app below does the same three things: `import kit "kit:."`, call
`kit.notify` with a **key that names the object**, and call
`kit.notify_read(key)` when the person sees the thing itself in the app (or
`kit.notify_withdraw(key)` when it stops being true). The identity is never
in the code: an app started inside an identity has `PALM_IDENTITY`, and the
daemon reads it. A missing daemon is `ok = false`; ignore it.
`apps/notify/demo/main.odin` is a complete, running example.

**mail** (apps/mail, mailcore) — when a message arrives in INBOX:

```odin
kit.notify({
	key = fmt.tprintf("mail:%s", msg.message_id),
	app = "mail",
	class = is_bulk(msg) ? .Machine : .Person, // List-Id, Precedence: bulk, no-reply senders
	category = "email.arrived",
	title = msg.from_name, body = msg.subject,
	link = fmt.tprintf("mail open %s", msg.message_id),
	actions = {{key = "reply", label = "Reply", run = fmt.tprintf("mail reply %s", msg.message_id)},
	           {key = "archive", label = "Archive", run = fmt.tprintf("mail archive %s", msg.message_id)}},
})
```

Opening the message → `kit.notify_read(key)`. Not for messages that arrive
already read, not for Sent, not for an unknown sender in Public until the
sender is accepted (product.md §8, screened). mailcore, which syncs headless,
is the one that should send, so mail notifies with the GUI closed.

**calendar** — at an alarm (VALARM) time, `key = "event:<uid>@<start>"`,
`class = .Time`, `title = event.title`, `body = "in 10 min · Room 2"`,
`link = "calendar open <uid>"`, actions Join (if there is a link) and Snooze.
An invitation: `key = "invite:<uid>"`, `class = .Person`, actions Accept and
Decline with `run = "calendar respond <uid> accept"`. A cancelled event:
`kit.notify_withdraw("event:<uid>@<start>")`. A critical alarm (an alarm the
person set as such): `urgency = .Critical, category = "alarm"`.

**chat** — a direct message or a mention: `key = "chat:<room>:<message-id>"`,
`class = .Person`, `category = "im.received"`, `title = sender`, `body =
text`, `link = "chat open <room>"`, action Reply. Channel traffic that does
not mention you: no notification at all. Reading the room →
`kit.notify_read` for each key shown, or one key per room
(`chat:<room>`) updated in place with the latest message — which is what a
person wants from a busy room, and what dedupe makes cheap.

**call** — incoming:

```odin
l := kit.notify_listen("call")            // once, at start; poll in the frame loop
kit.notify({key = fmt.tprintf("call:%s", call.id), app = "call", class = .Person,
	urgency = .Critical, category = "call.incoming",
	title = call.from, body = fmt.tprintf("Incoming call · %s", call.topic),
	actions = {{key = "answer", label = "Answer"}, {key = "decline", label = "Decline"}}})
// kit.notify_next_action(&l): "answer" -> answer the ringing call
```

Answered elsewhere, hung up, or timed out → `kit.notify_withdraw(key)`; then a
missed call is a new notification, `key = "call-missed:<id>"`, `class =
.Person`, normal urgency, action Call back (`run = "call dial <who>"`). Whether
the call rings through a quiet identity is the policy's ("Calls break
through"), never the app's.

**drive** — a sync conflict: `key = "drive:conflict:<path>"`, `class =
.Machine`, `title = "Sync conflict in <name>"`, `body` says both copies were
kept, action Resolve (`run = "drive resolve <path>"`); resolving withdraws it.
A share from a person the identity knows: `class = .Person`, `key =
"drive:share:<id>"`; from someone unknown: `.Machine` (research.md §4: share
notifications are a phishing channel).

**forge** — review requested of you, a mention, a comment on your change:
`class = .Person`, `key = "forge:review:<repo>#<n>"` (one key per change,
updated in place). CI: `class = .Machine`, `key = "forge:ci:<repo>@<sha>"`,
`urgency = .Low` when it passed, normal when it failed.

**palmd / palm** (updates) — one key for the whole state:
`key = "palm:updates"`, `class = .Machine`, `title = "3 updates are ready"`,
`link = "store"`, re-sent with the new count as it changes (an update in
place, never a pile), withdrawn when there are none. A reboot needed after an
update: `key = "palm:reboot"`, `.Machine`. palmd runs as root: it should not
notify itself; `palm` (or the store) in the session does, from palmd's state.

**vault** — pairing a browser for autofill is the answer to what the person
just did: `category = "x-palm.prompt"` (shown through quiet and do not
disturb), `key = "vault:pair:<code>"`, `title = "Pair Chromium (Northwind)?"`,
`body = "Code 4821 — check it matches"`, `timeout_ms = 60_000`, actions
Approve and Deny through `kit.notify_listen("vault")` (the click must reach
the running vault, not a new process), withdrawn when the pairing completes or
expires. Never put a secret in a notification.

**browser** — a finished download: `key = "download:<id>"`, `class =
.Machine`, `title = "<file> downloaded"`, `link = "files open <path>"`.
Web notifications already work without the browser doing anything: Chromium
and Firefox send them over `org.freedesktop.Notifications`, and the daemon
recovers the identity from the engine's profile path
(`…/palmframe/browser/<identity>/cef|gecko`) because Chromium overwrites its
own environment block. Keep that layout. If apps/browser hosts the engine
itself (CEF), pass the site's `tag` as the hint `x-palm-key` (`web:<origin>:<tag>`)
and `x-palm-identity`, so a site's repeated notification is delivered once.

**home** (rail: "NOTIFICATIONS · Northwind quiet18") — read the sentences from
`notify quiet list --json` (`policies[].sentence`, `.hold`, `.hold_ends`) or
`policies.json` directly; the command palette's "Hold Northwind notifications
until tomorrow 08:00" is `notify quiet add --identity camille.roux "quiet"`.
Today's count is `notify list --unread --json`.

**accounts / settings** — write `$XDG_CONFIG_HOME/palmframe/identities.json`
(`handle`, `name`, `color`) when identities change: it is how the toasts know
"Northwind" and its blue.

## Requests

**For SHELL (apps/wm):**

1. **The binding.** `bind = $mod SHIFT, N, spawn notify focus` (focus the
   toasts, or open the center when there are none) and `bind = $mod ALT, N,
   spawn notify dnd toggle`. `$mod N` is minimize today; both chords above
   are free in the default table. Add them to the cheat sheet.
2. **The bar.** Read `$XDG_RUNTIME_DIR/palm/notify.state` on the same
   once-a-second check as the config file: show `[🔔 N]` with N = `unread`
   (nothing when 0, no red), a bell-off icon when `dnd 1` or when the current
   identity's line says `quiet`/`dnd`; click runs `notify center`. Hover text:
   the current identity's sentence (fourth field).
3. **Window identity.** Write `$XDG_RUNTIME_DIR/palm/wm/clients`, one
   `pid<TAB>identity<TAB>app_id` per client, rewritten when it changes (the pid
   from the Wayland socket's `SO_PEERCRED`). The daemon already reads it
   (daemon.odin: `wm_identity`, walking the parent chain) for senders that do
   not carry `PALM_IDENTITY`. The windows a client started for an identity
   should also get `PALM_IDENTITY` in their environment when the wm launches
   them; that is what makes everything else automatic.
4. **Input time**, for "the device being looked at": touch
   `$XDG_RUNTIME_DIR/palm/wm/input` at most every 5 s while there is input.
5. **Layer order.** The toasts and the center are both Overlay; the toasts
   should stay above a fullscreen window, and the center should be allowed
   keyboard exclusivity (Escape closes it). The toasts ask for on-demand
   keyboard and become exclusive only after `notify focus`.
6. **Session environment.** If the wm (or palm-login) exports
   `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus`, programs that do
   not fall back to the per-user bus find it too.

**For palmy's owner:** a runtime `set_layer_size` (one `zwlr_layer_surface_v1
.set_size` + commit) so the toasts need not re-create their surface; an input
region, so a taller transparent surface could pass clicks through; and
ARGB8888 buffers, so toasts can be rounded floating cards with a shadow.

**For whoever owns default.list and the recipes:** add `notify` to
`distro/apps/default.list` (its recipe is then generated: `depend = glibc
fonts libxkbcommon`, with `dbus` and `pipewire` optional at run time). Not
done here: the file is SHELL's.

## Status

Built and verified: the daemon, both doors, policies as sentences, dedupe and
tombstones, digests, do not disturb, scope, sounds, the toasts, the center, the
CLI, `kit.notify`, the demo client, the session hooks, and the cross-device
tables with their tests.

| command | result |
| --- | --- |
| `notify --selftest` | 93 passed: grammar round-trips, every branch of the decision, dedupe, tombstones, digests, markup, spoken text, scope |
| `apps/notify/e2e.sh --shots DIR` | 60 passed, on the host with a private session bus and a headless sway: sentences stored and refused, scope refused by the kit and again by the daemon, dedupe across apps, quiet hours held then one digest at 08:01 and the daily one at 17:00, a call breaking through only with "Calls break through", do not disturb, the demo client (kit.notify, notify_listen, withdraw), notify-send (identity from PALM_IDENTITY, replace, low urgency, actions and ActionInvoked heard by notify-send itself), the toasts, the keyboard (notify focus, ↓, Delete), the center (Escape closes it), and Chromium 152 on Wayland: a page's `new Notification(...)` arrives labelled Northwind (from the profile path) and clicking it in Palmframe runs the page's `onclick` |
| `cloud/dev/up.sh --name notify --port-base 50521` then `cloud/dev/test.sh --name notify --port-base 50521` | the whole suite 609/609, `notify_once.sql` 24/24 |
| `python3 -I apps/notify/qemu-test.py` | on the disk image (notify added to the default set locally): session.d starts the session bus and palm-notifyd as palm; the daemon owns `org.freedesktop.Notifications`; a toast on wm --drm under its bar; a chime through PipeWire (`pw-play`); the keyboard; quiet holding a person while a call breaks through, then the digest; the center; the bar's state file — 20 passed |
| `python3 -I distro/image/test-boot.py` | all passed (27) on the same image |

Screenshots: `apps/notify/shots/` — offscreen light and dark (`toasts-*`,
`center-*`), live on headless sway (`live-*`, with Chromium), and on the image
in QEMU (`qemu-*`).

Designed, not built: the daemon's cloud half (above), freedesktop
`suppress-sound`/`sound-file` and images, AI summaries (product.md: always
marked, never alone — nothing here summarises), screening unknown senders
(mail's job, before it notifies).
