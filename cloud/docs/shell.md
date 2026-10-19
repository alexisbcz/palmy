# Identity in the shell, the greeter and every app

A proposal. `apps/wm`, `apps/greeter` and `apps/kit` belong to other agents;
nothing here edits them. It describes what product needs from each, and
offers a concrete API so the work can be picked up as written or argued with.
The principles behind it are in `product.md`, chiefly P2: *label when mixed,
tint when single, colour never alone.*

## The one idea

**The compositor decides which identity a window belongs to, not the app.**
A tint is only worth something if a window can't fake it. A phishing page
dressed in Northwind blue is the attack. So the window manager learns a
window's identity from how it was *launched*: it started the process with a
scoped session and knows the client's pid (`SO_PEERCRED` on the Wayland
socket). The app is told its identity and draws its own labels. The frame,
the band and the taskbar entry come from the compositor, which an app can't
draw over.

```
launch (Home, launcher, palm app launch --identity northwind)
   │  wm spawns the process with PALM_IDENTITY=<identity id> and a scoped token
   │  and records pid → identity
   ▼
client connects ── wm reads SO_PEERCRED pid ── looks up identity ── tints the frame
   │
   └─ the app reads PALM_IDENTITY through kit, draws labels, chips and its From card
```

An app the wm did not launch with an identity (a terminal, a foreign app)
gets no tint and no label. "No identity" is a state of its own, never a
default identity.

---

## 1. The window manager

### The bar

Today (`apps/wm/taskbar.odin`):

```
[◆ Palmframe] [1 2 3 … 9] [layout]  [▣ Terminal] [▣ gallery] …  [kbd] [clock]
```

Proposed:

```
[N Northwind ▾] [1 2 3 … 9] [layout]  [▣ ● Mail] [▣ ● Docs] [▣ Terminal] …  [🔕 2] [kbd] [clock]
 └ the switcher  └ unchanged          └ taskbar entries carry a dot in       └ notifications,
   monogram in the                      their window's identity colour;        count only
   current identity's                   no dot = no identity
   colour, its name, a caret
```

- **The switcher** replaces the brand mark at the left of the bar. It shows
  the *current identity*, the one new windows, New and the assistant default
  to. Click it, or press **Super+I**, to get a menu:

  ```
  ┌──────────────────────────────┐
  │ ▣ All identities       Super 0│
  │ P Personal             Super 1│
  │ N Northwind  ✓         Super 2│
  │ P Public               Super 3│
  │ H Halcyon              Super 4│
  │──────────────────────────────│
  │ Quiet Northwind until 08:00   │
  │ Account settings…             │
  └──────────────────────────────┘
  ```

  Switching changes defaults. It never moves, hides or re-tints windows
  that are already open.
- **Taskbar entries** get a 6 px dot in their window's identity colour,
  before the title. Hovering shows "Mail · Northwind". Entries are not
  grouped by identity, because the workspace is the grouping people chose.
- **A band across the bar's bottom edge** in the current identity's colour,
  3 px. In All identities, each identity's colour side by side, as Home draws
  it (`img/01-today-all-light.png`).
- **Notifications** show a count only, with a bell-off icon when the current
  identity is quiet. Opening the list shows each notification labelled.

### Window frames

- A **3 px band at the top edge of the title bar** in the window's identity
  colour. It sits inside the frame the wm draws, where a client can't reach.
- The **title** reads `Mail — Northwind`, with the identity name in its
  colour at the focused weight. If the title is too long, the window title is
  shortened before the identity name is.
- **Unfocused** windows keep the band at 50% opacity, so a glance across the
  screen still tells you which window belongs to which identity.
- No identity means no band and no name: the frame looks exactly as it does
  today.

### The switcher (Alt+Tab) and the overview

Each thumbnail carries the same band on its top edge and the identity name
under the title. The overview gets one more key: **Super+0–4** filters the
overview to one identity's windows, for "show me everything work".

### Clipboard across identities

`apps/wm/clipboard.odin` owns the selection. Proposed: the wm records which
identity the selection was copied from. Pasting into a window of a *different*
identity shows a small inline banner the first time in a session: "Paste from
Northwind into Personal? [Paste once] [Always for this pair today]". Text with
no identity, from a terminal for example, pastes freely. This is a **carry**
for the clipboard (`product.md` §5), and the carry log records it with a
content hash, not the content.

### Notifications

A toast carries the identity label (`●  Northwind`) before the sender. A quiet
identity's notifications go to its digest and never to a toast. Each
notification is delivered to one device (`product.md` §8), so the wm needs to
know whether this device is the one being used. Input in the last 60 seconds
is enough.

---

## 2. The greeter and the lock screen

The greeter signs in the **person** (the Palmframe account), not an identity.
Proposed changes to `apps/greeter`:

```
            ┌─────────────────────────────────────────────┐
            │                 (CR)                        │
            │             Camille Roux                    │
            │         [ password ••••••••   → ]           │
            │                                             │
            │   Start in   (P) (N) (P) (H)  ▣ All         │
            │              last used: Northwind           │
            └─────────────────────────────────────────────┘
```

- **Start in** shows the identities as monograms, defaulting to the last one
  used. It only sets the current identity. It does not limit what the session
  can open.
- The lock screen shows the time, the person and, per identity, *a count*:
  "Northwind · 2 waiting". It never shows sender, subject or preview text,
  because lock screens are seen by other people.
- A device enrolled with only some identities shows only those. A work laptop
  carrying only Northwind never shows that a Personal identity exists.
  Whether a device even knows about the other identities is part of
  enrolment.

---

## 3. Every app: the kit component

### What every app does with it

| place | single-identity window | mixed view (All identities) |
| --- | --- | --- |
| window frame | tinted by the wm | the wm's multi-colour band |
| app header | identity **chip** beside the title, e.g. `Mail ● Northwind` | `All identities` |
| list rows | nothing (the window already says it) | identity **label** on every row |
| compose, invite, share | **From card** at the top, before any field | From card in "choose" state; won't send until one is chosen |
| primary action | in the identity colour | neutral |
| empty state | names the identity: "Nothing in Northwind's inbox." | |

An app should use the identity colour in **those places only**. Painting
backgrounds or sidebars with it makes it decoration, and once it is
decoration nobody reads it as a signal.

### The API

Proposed as `apps/kit/identity.odin`. The prototype in `apps/home/ui.odin` has
working versions of `id_chip`, `id_label`, `monogram`, the From card and the
tint band, and they would become these.

```odin
package kit

Identity_Kind :: enum { Personal, Work, Public, Project }

// Identity is what an app needs to draw an identity: a public.identities row
// as cached on the device, plus the address it sends as.
Identity :: struct {
	id:      string,   // public.identities.id
	handle:  string,
	name:    string,   // display_name
	address: string,
	kind:    Identity_Kind,
	color:   string,   // a palette name: "teal", "blue", "amber", ...
	slot:    int,      // stable 0..7 per account, for the colour tokens
}

// --- Which identity am I? ---------------------------------------------------

// identity_current is the window's identity: PALM_IDENTITY as the wm or
// `palm` set it, resolved against the device's account cache. ok = false
// means no identity, a state of its own and never a default.
identity_current :: proc() -> (id: Identity, ok: bool)

// identities lists the identities enrolled on this device, in slot order.
// An app running inside one identity's scope gets just that one, which is
// the same rule the database applies.
identities :: proc(allocator := context.allocator) -> []Identity

// --- Colours ----------------------------------------------------------------

// identity_register_colors registers the tokens apps write in class strings:
//
//   identity            the window's identity          bg-identity/10
//   identity-<slot>     each identity by slot          text-identity-2
//
// with the light or dark value of each palette colour. Call it after
// kit.start and again on a theme change. An app with no identity gets
// `identity` = muted-foreground, so class strings never fail.
identity_register_colors :: proc(dark: bool)

// identity_color is the raw colour, for code drawing inside p.pixels.
identity_color :: proc(id: Identity, dark: bool) -> p.Color

// --- Drawing ----------------------------------------------------------------

Mark :: enum {
	Label,     // ●  Northwind        dot + muted name; rows in mixed lists
	Chip,      // (● Northwind)       dot + coloured name on a 10% wash; headers
	Monogram,  // [N]                 letter on a 15% wash; pickers, avatars
	Dot,       // ●                   only where the name is already adjacent
}

// identity_mark draws one of the four marks. `text` overrides the name
// ("in Northwind", "as Northwind"). Returns the node index for p.apply.
identity_mark :: proc(ui: ^p.Ctx, id: Identity, mark := Mark.Label, text := "", size := 0) -> int

// identity_band draws the 3 px band: one colour, or every identity's side by
// side when `all` is true. For surfaces the wm doesn't frame: layer-shell
// panels, the greeter, a fullscreen app.
identity_band :: proc(ui: ^p.Ctx, ids: []Identity, current: int, all := false)

// identity_from draws the From card that leads every compose, invite and
// share sheet: monogram, name, address, in the identity's colour. With
// `id_ok = false` it draws the "Choose an identity" state instead.
// Returns true when activated (open the picker).
identity_from :: proc(ui: ^p.Ctx, id: Identity, id_ok: bool, verb := "From") -> (activate: bool)

// identity_picker is the inline choice under a From card: one chip per
// identity, Ctrl+1..n to choose, Tab to cycle. `sel` is -1 for none chosen,
// and the caller must refuse to proceed while it is -1 (product.md P3).
identity_picker :: proc(ui: ^p.Ctx, ids: []Identity, sel: ^int) -> (changed: bool)

// --- Crossing -----------------------------------------------------------------

// identity_crossing draws "● Personal → ● Northwind · a copy, not a link"
// for carry, Reply as… and Forward to my…, so every crossing looks the same
// wherever it happens.
identity_crossing :: proc(ui: ^p.Ctx, from, to: Identity, what: string)
```

**Palette.** Eight hues, each with a light-theme and a dark-theme value
checked for text contrast at 11.5 px on `background` and on `muted`:

| name | light | dark |
| --- | --- | --- |
| teal | `#0f9488` | `#2dd4bf` |
| blue | `#2563eb` | `#60a5fa` |
| amber | `#c2620a` | `#fbbf24` |
| violet | `#7c3aed` | `#a78bfa` |
| rose | `#e11d48` | `#fb7185` |
| emerald | `#059669` | `#34d399` |
| indigo | `#4f46e5` | `#818cf8` |
| slate | `#475569` | `#94a3b8` |

Red is kept for "overdue" and "destructive", so no identity can be red.
Accounts assign hues so that no two identities share one, and the person can
change them.

### The CLI side

`palm identity current --json` returns the same `Identity` object, so a
script draws the same name in the same colour. `palm` refuses to widen the
scope (exit 5, `docs/PALM-CLI.md`), which is the CLI version of "the
compositor decides".

### i18n

Identity names are the person's own words and are never translated. The
fixed strings ("From", "Choose an identity", "a copy, not a link", "in %s",
"as %s") go through `kit.tr` under a `kit` domain, so every app shares one
translation.

---

## 4. What would make this wrong

- **If the wm can't map a client to the process it launched.** Apps started
  through D-Bus activation or a portal are the usual way that mapping breaks.
  Then the tint has to come from the app, and the anti-phishing argument
  gets weaker. In that case only windows launched through the wm should be
  tinted, and the rest should be marked "identity unknown".
- **If people find the band noisy.** The fallback is the title-bar name
  only. The band should go before the name does.
- **If eight hues aren't enough.** Someone with more than eight identities is
  rare; give the extras a pattern (a striped band) rather than a ninth hue.
