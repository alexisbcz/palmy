# TODO

What is not done, in the order it is worth doing, with a prompt for each that
an agent can be handed without further context.

This file is written to be *used*: the sections under **Toolkit** are blocking
multiple applications right now and should be cleared before more applications
are added. Everything is justified by something an agent actually hit, not by
taste — where a count appears (*"ten apps"*), it came from grepping the tree.

## How to use a prompt from this file

Every prompt below assumes the conventions this project already runs on. Rather
than repeat them in each one, they are here once, and each prompt says which
apply.

**The standing rules, which belong in every prompt:**

- **Own one directory.** Name it. Say explicitly that `palmy/`, `shadcn/`,
  `apps/kit/` and `parity/` are off limits unless the task is about them, and
  that other agents are working in other directories concurrently. If a build
  fails inside shared code, that is somebody else mid-edit: wait and retry,
  never "fix" it.
- **Never end a tool call with shared code uncompilable.** 42 applications and
  a parity suite build against `palmy/`. Breaking it blocks everyone, and it
  has happened twice.
- **The 182-case parity suite must stay at mean mae 2.953.** `cd parity && bash
  tools/diff-all.sh`. It compares against real browser captures and is the
  instrument that says whether something changed that was not meant to.
- **The unit tests must pass**: `odin test tests -collection:shadcn=$PWD/shadcn`
  — 44 tests. Parity and the app builds do **not** cover everything; a theme
  regression shipped once because only those two were run.
- **Rebuild every app** after touching shared code: `for d in apps/*/`.
- **Record with `apps/tools/headless-record.sh`**, which runs on a private
  invisible compositor — no lock, no queue, nothing on the user's screen.
- **Report an assertion count**, and say what you could *not* verify. A stated
  gap is worth more than a claim that cannot be checked.
- **Render and look.** Write PNGs through `p.offscreen_*` and read them back.
  Several real bugs this session passed every assertion and were visibly wrong.

**The safety rules, which are not negotiable and must be restated in full in
any prompt they touch:**

- Networking is **read-only**. Nothing may disable the radio or drop a
  connection — that would take the machine, and the session doing the work,
  off the network. `apps/network` routes those through a logged intent.
- Power and session actions are **intent-only**: log the command, execute
  nothing.
- Never `systemctl enable/disable/start/stop` sddm, greetd, display-manager or
  ollama. ollama is deliberately a user process here.
- The real webcam and microphone are **never** captured into a demo,
  screenshot, measurement or committed file. Synthetic sources only.
- Never read the user's real credential stores, mail, or financial files.

---

# Toolkit

These block applications today. Clearing them removes workarounds from dozens
of files.

## T1 — Wake the frame loop from another thread

**Ten applications are burning CPU because of this**: `ai`, `archive`, `chat`,
`clipboard`, `colorpick`, `emoji`, `kit`, `launcher`, `slides`, `vault` all set
`ui.animating = true` permanently, repainting at vsync forever, because there
is no way to tell a sleeping frame loop that something happened. `frames()`
parks in `poll()` on the display fd alone.

`vault` is the sharpest case: its idle auto-lock, clipboard countdown and TOTP
countdown are *security* timers that only fire while the loop happens to be
running, so it repaints continuously while unlocked and says so.

> **Prompt.** Add two things to palmy: a way to wake the frame loop from
> another thread, and a one-shot timer.
>
> You own `palmy/app.odin`, `palmy/window.odin`, `palmy/wayland.odin` and
> `palmy/x11.odin`. Do not touch `apps/` or `shadcn/`. Read `palmy/app.odin`'s
> `frames` and `wait_for_frame` first, and `palmy/window.odin`, which is a
> backend seam with Wayland and X11 behind it — whatever you add must work on
> both.
>
> The mechanism is an `eventfd` (or a self-pipe) added to the `poll` set
> alongside the display fd. A public `wake(app)` that is safe to call from any
> thread writes to it; the loop wakes, drains it, and runs a frame. A
> `wake_at(app, when)` arms a one-shot by capping the poll timeout.
>
> Then prove it removes the workaround: pick **two** of the ten applications
> above, delete their permanent `animating = true`, drive them from a worker
> thread or a timer instead, and measure idle CPU before and after. `vault` is
> the best demonstration because its timers are load-bearing; `ai` is the best
> stress because tokens arrive from a socket on another thread. Those two
> directories are yours for this task only — nothing else under `apps/`.
>
> Assert what can be asserted headlessly: that a wake from another thread
> causes exactly one frame rather than a spin, that an armed timer fires once
> and not repeatedly, that waking an app that is already drawing does not
> deadlock, and that a wake delivered while the loop is between frames is not
> lost. Report the assertion count and the measured idle CPU for both apps,
> before and after.
>
> Parity must stay at 182 cases / mean mae 2.953, the 44 unit tests must pass,
> and all 42 apps must build. Never end a tool call with `palmy/`
> uncompilable.

## T2 — `flex-wrap` does not grow the row's height

**Three independent reports** (`chat`, `ai`, `mail`), and I failed to reproduce
it twice from the vaguer two. The concrete repro is `mail`'s: **five attachment
chips each carrying a Save button wrap onto a second line, and the row's height
does not grow, so the second line draws over whatever follows.** Five bare
chips do not trigger it.

The suspected mechanism, from the `ai` agent, is that `measure()` wraps a
`flex-wrap` row against the width it is *offered* rather than the width it
ends up with: a box constrained only by `max-w` offers its parent's full width
while measuring and the real, narrower width while arranging, so it wraps onto
more lines than it reserved height for. That is the same class of bug as the
`h-full` pre-shrink fix in `palmy/layout.odin` — read that commit first.

> **Prompt.** Fix `flex-wrap` rows reporting too little height, in
> `palmy/layout.odin` only.
>
> **Reproduce it first and do not proceed until you can**, because two attempts
> to reproduce it from description failed. The case that is known to trigger
> it: a `flex-wrap` row whose width is constrained only by `max-w`, containing
> items that each have an interactive child — five chips with buttons in them.
> Build it through `p.offscreen_*`, render a PNG, read it back, and show the
> overlap. Then assert the geometry: the row's height must cover every line it
> laid out, and no child's rectangle may extend past its parent's.
>
> Read `palmy/layout.odin` and the commit that fixed `h-full` resolving against
> a pre-shrink height — this is likely the same shape of bug, where `measure`
> uses the offered space and `arrange` uses the real one. Note that `arrange`
> already re-wraps a `.Text` node when the final width turns out narrower;
> a wrapping row probably needs the equivalent.
>
> The hazard to watch for: a fix that re-measures could change layout
> everywhere. The parity suite is the instrument — 182 cases, mean mae 2.953,
> and the whole `metrics.ndjson` should stay byte-identical unless you can
> explain exactly which case moved and why. The 44 unit tests must pass, and
> all 42 apps must build.
>
> When it is fixed, tell me, because `apps/mail` has a workaround (an explicit
> column instead of a wrapping row) that can be reverted.

## T3 — Interactive widgets that are only decorative

`sc.input` takes a `string` and cannot be typed into, so **every editable field
in every application** goes through `p.text_field` instead and re-implements
the shadcn look. `sc.slider` never reads its pointer, so `ai`, `photoshop`,
`mixer`, `videoedit` and the media players each rebuilt one from `p.div` +
`p.rect_of` + `p.is_active`. `sc.progress` is display-only.

This one needs care: those components are in the parity suite, which compares
them against real browser captures in fixed states. Interaction must be
**additive** — the default rendering cannot move a pixel.

> **Prompt.** Make `sc.input`, `sc.slider` and `sc.progress` interactive
> without changing how they render.
>
> You own `shadcn/`. Do not touch `palmy/`, `apps/` or `parity/`.
>
> The constraint that defines this task: the parity suite captures these
> components from a real browser in fixed states, so **the default rendering
> must not move a single pixel**. 182 cases, mean mae 2.953, and
> `out/diff/metrics.ndjson` should come back byte-identical. Interaction is an
> addition — new optional parameters and return values — not a change to what
> the existing calls draw.
>
> `sc.input` should edit a buffer and return whether it changed, the way
> `p.text_field` does, while keeping `INPUT_BASE` and the focus/invalid/disabled
> states exactly as they are. `sc.slider` should drag and return its value.
> `sc.progress` should keep its display role but gain an indeterminate mode.
>
> Read `palmy/widgets.odin`'s `text_field` for how this project does editable
> text, including the placeholder and caret colours, and reuse it rather than
> writing a second implementation — the goal is that `sc.input` *is*
> `p.text_field` wearing shadcn's clothes.
>
> Verify by driving them through palmy's synthetic input offscreen, as
> `apps/pickdemo`'s tests do: type into the input, drag the slider, assert the
> resulting values. Report the assertion count. Then pick one application that
> rebuilt a slider by hand — `apps/mixer` is the simplest — and show the
> rebuilt one can be replaced, but **do not commit that change**; just report
> that it works.

## T4 — A multi-line text widget

`p.text_field` is single-line. `vault`'s Notes field is a tall single-line
field that cannot accept a newline (the model stores them correctly — that is
asserted — they just cannot be typed). `mail`'s composer, `notes`, `docs` and
`chat` each wrote their own multi-line buffer and caret logic.

> **Prompt.** Add a multi-line text area to palmy, in `palmy/widgets.odin`.
>
> You own `palmy/widgets.odin`. Do not touch other `palmy/` files without
> telling me, and do not touch `apps/` or `shadcn/`.
>
> Four applications have already solved parts of this and you should read them
> rather than invent: `apps/notes/wrap.odin` has soft wrap with the two-way
> caret conversion and an asserted round trip (`col_at` inverts `caret_x`, and
> down-then-up with the same goal column returns to the same place);
> `apps/editor/buffer.odin` is a line array with measured costs;
> `apps/docs/layout.odin` caches wrapping per paragraph after measuring a naive
> re-wrap at 33 ms per keystroke.
>
> The widget needs: wrapping to its width, a caret that survives wrapping,
> selection, Home/End on the *visual* line, Up/Down by visual line with a
> remembered goal column, scrolling when the caret leaves the view, and
> Enter inserting a newline rather than submitting.
>
> The assertions that matter are the caret round trip over every rune boundary
> and that the lines partition the text exactly — nothing lost, nothing
> duplicated — at several widths. Report the count.
>
> Then prove it: replace `vault`'s Notes field with it (that directory is yours
> for this task only) and show a newline can be typed and survives a save and
> reload. Parity must not move; the 44 unit tests must pass; all 42 apps must
> build.

## T5 — Parity does not cover palmy's own widgets

`grep text_field parity/odin/render/` returns nothing. The suite exercises
`sc.input`, not `p.text_field` — which is exactly how a regression shipped
this session where a text field rendered slate-200 text on a white page under
no theme. Parity passed, all 42 apps built, and only `tests/` caught it.

> **Prompt.** Extend the test coverage to palmy's own widget set and to layout
> against a container.
>
> You own `tests/` and may add cases under `parity/odin/render/`. Do not change
> `palmy/`, `shadcn/` or `apps/`.
>
> Two gaps, both of which let real bugs through this session:
>
> **Palmy's widgets are untested against anything.** `p.text_field`,
> `p.button`, `p.checkbox`, `p.progress` and the rest have no parity case and
> little unit coverage. A field rendered unreadable text under no theme and
> nothing caught it but one hand-written test. Add unit tests that assert what
> is *visible*, not just what is stored: that a placeholder appears only when
> empty, that masking changes what is drawn, that text has contrast against the
> field's own background under a light theme, a dark theme, and **no theme at
> all** — that last case is the one that failed.
>
> **Layout is only tested against Chrome.** The parity suite renders single
> components at a fixed size; nothing asserts that a tree lays out correctly
> *inside a container*, which is where the `h-full` pre-shrink bug lived and
> where the open `flex-wrap` bug lives. Add a layout-geometry suite: build
> trees through `p.offscreen_*`, assert rectangles directly — a `flex-1` child
> fills the space its siblings leave, a percentage resolves against its real
> parent, a wrapping row's height covers its lines, a child never extends past
> its parent. These are cheap, fast, and catch a class parity cannot.
>
> Report the assertion count and, for each new test, name the bug it would have
> caught.

## T6 — Smaller toolkit gaps, each reported by a real application

Listed with their source so the next agent does not have to rediscover why.

| gap | reported by | note |
| --- | --- | --- |
| `p.image` cannot pan or rotate | `image` | re-implemented bilinear sampling and `rotate90` in the app |
| `p.drop_shadow` evaluates the whole interior | `docs` | 11.7 ms → 3.6 ms a frame once cut into four clipped bands |
| `push_clip` is one rect with no exclusion | `docs` | which is why the shadow needs four calls |
| keysym table stops at F5 and F11 | `sheets` | spelled `KEY_F10 :: 0xffc7` locally |
| `srgb_to_linear`/`linear_to_srgb` are private | `docs` | an app compositing its own coverage must re-derive them |
| `p.theme_color` is private | `sheets` | `p.parse_color` works but is not documented as the route |
| no `text-current` colour inheritance | `call` | a chip inside a filled button must restate its colour per variant |
| no `xdg_popup` | several | menus and tooltips are drawn in-window; a real constraint, not a bug |
| no bidi | picker | RTL filenames list and sort correctly but read in logical order |
| ZWJ emoji sequences not composed | typography | needs GSUB; a skin-tone modifier renders as a swatch |
| a client's keyboard re-bind is asynchronous | editor, mail, vault | see below — fixed in the recorder, still a latent toolkit issue |

> **Prompt.** Clear the small toolkit gaps in the table in `TODO.md` section T6.
>
> You own `palmy/`. Do not touch `apps/`, `shadcn/` or `parity/`. Read the
> table first — each row names the application that hit the gap, and reading
> that app's workaround will usually tell you what the API should have been.
>
> Take them in this order, because the first two have measured wins behind
> them: `p.drop_shadow` drawing only the ring it needs (`docs` measured
> 11.7 ms → 3.6 ms a frame working around it), then `p.image` gaining an offset
> and quarter-turns (`image` re-implemented sampling to get them), then the
> straightforwardly missing things — the rest of the function keys, making
> `srgb_to_linear`/`linear_to_srgb`/`theme_color` public, and `text-current`.
>
> Leave bidi, `xdg_popup` and ZWJ composition alone unless everything else is
> done: each is a project rather than a gap, and `xdg_popup` may be a
> deliberate constraint rather than something to fix.
>
> Every change is additive — no existing signature changes. Parity at 182 /
> 2.953 with the metrics byte-identical, 44 unit tests, 42 apps building, and
> a reported assertion count. For `drop_shadow` and `p.image`, report the
> measured frame time before and after, since that is the point of both.

---

# The command surface

`docs/PALM-CLI.md` has the full design. The principle: **every application is a
library with two front ends**, the GUI and the CLI, and the CLI is not a
reduced version.

The inventory as it stands: `mailcore` carries 33 flags, `torrent` 24, `call`
22, while `maps`, `reader`, `shop`, `launcher`, `files`, `notes` and `calendar`
have essentially none — and the conventions have diverged (`--selftest` against
`--self-test`, which `call` accepts both of; `--shot` against `--export-png`;
`--help` in about a dozen of forty-two).

## C1 — The shared convention and the dispatcher

> **Prompt.** Build the `palm` command surface: the shared CLI convention in
> `apps/kit`, and the dispatcher.
>
> Read `docs/PALM-CLI.md` first — it is the design and it is specific. Read
> `apps/mailcore/main.odin` and `apps/torrent/main.odin` as the two
> applications that already have a real CLI, and note how differently they got
> there.
>
> You own `apps/kit/` (add files; extend `kit.odin` additively only, since 42
> applications compile against it) and a new `apps/palm/`.
>
> The convention goes in the kit so forty-two applications cannot each invent
> their own: an application declares its commands, and the kit parses,
> validates, generates `--help`, emits `--json`, honours `--dry-run`, and
> produces the documented exit codes. `palm schema` then introspects the same
> declarations, which is what stops the index and the behaviour drifting apart.
>
> Get these right, because they are what makes it usable by an agent rather
> than a person: **machine output on stdout and nothing else on stdout**
> (progress and warnings to stderr, so a pipeline never strips chatter out of a
> JSON document); **refusal rather than prompting**, since a destructive
> command without `--yes` must exit non-zero with a machine-readable reason and
> never block on a TTY read; and a **declared side-effect class** per command
> (`read`, `idempotent`, `mutate`, `destructive`, `intent`) so a caller can
> reason about retry safety.
>
> `--selftest` is the one existing convention to keep, since every application
> has it and the counts are how this project judges its own work.
>
> Then convert **three** applications as exemplars, chosen to be different
> shapes: `apps/notes` (has an engine, no CLI), `apps/sheets` (rich already,
> needs the convention), and `apps/power` (whose actions must stay `intent`
> class — `apps/power/main.odin:264` has `log_intent`, and its self-test proves
> nothing executes by putting fake `systemctl`/`reboot` binaries on `PATH` that
> write to a sentinel which must stay empty; keep that assertion passing).
> Those three directories are yours for this task only.
>
> Assert the surface against itself: every command `palm schema` advertises
> exists, every example it ships parses, every documented exit code is produced
> by something, every `read` command emits JSON matching its declared schema,
> and every `destructive` command refuses without `--yes`.
>
> The safety rules in `docs/PALM-CLI.md` are not negotiable and must be
> enforced in the code rather than the documentation: networking read-only,
> power and session intent-only, capture on a private headless compositor,
> and no verb anywhere that lists vault secrets across identities.

## C2 — Bring the rest of the applications up to it

Forty-two applications, in the order an agent would reach for them. **Do not
give one agent all of them.** Four agents, one per group, each owning only its
own directories.

1. **Already close** — `mailcore`, `torrent`, `docs`, `sheets`, `slides`,
   `money`, `chat`, `vault`. Mostly renaming onto the convention and adding
   `--json`.
2. **Have an engine but no CLI over it** — `mail`, `calendar`, `notes`,
   `reader`, `shop`, `maps`, `captions`, `videoedit`.
3. **UI-shaped, needing a core lifted out** — `files`, `editor`, `image`,
   `clipboard`, `colorpick`, `emoji`, `photoshop`, `archive`. The real work,
   and worth doing for its own sake: lifting the core out is what makes them
   testable headlessly.
4. **System applets** — `audio`, `power`, `sysmon`, `network`, `bluetooth`,
   `screenshot`, `mixer`. Small surfaces, and the safety rules bite hardest.

> **Prompt** (adapt the group). Bring *group N* up to the `palm` CLI
> convention: `<list the directories>`. Those directories are yours; nothing
> else.
>
> Read `docs/PALM-CLI.md` and `apps/kit`'s CLI declaration API first, and one
> converted exemplar.
>
> A thing is done when **the GUI uses the same entry points the CLI does**. If
> `palm notes write` goes through a different path than typing in the window,
> the two will diverge and the CLI will be the one that rots. For group 3 that
> means genuinely separating the core from the UI, which is the point.
>
> Keep every application's existing self-test passing and report the counts
> before and after. Keep each command-line path argument working — the CLI is
> an addition. Report which applications you converted fully, which partially,
> and what each still cannot do headlessly.

---

# Packages

`docs/PACKAGES.md` has the design. The short version: **do not write a package
manager.** pacman already works, `yay` reaches the AUR, and rollback exists —
`snapper` is configured on `/` and `limine-snapper-sync` keeps boot entries in
step with the snapshots. A new one would begin with zero packages.

What is missing is a declarative layer: a file per identity saying what the
machine should have, a `sync` that converges toward it, a diff that shows how
it has drifted, and an interface an agent can drive without parsing prose.

> **Prompt.** Build `palm pkg`, the declarative package layer in
> `docs/PACKAGES.md`. Read that file first; it is specific, and the rules in it
> are each a way a package layer destroys a working machine.
>
> You own `apps/pkg/`. Do not touch `palmy/`, `shadcn/`, `apps/kit/` or
> `parity/`, and do not touch another application.
>
> **Write the whole thing against a fake `pacman` before you run a real one.**
> Everything that matters is testable without modifying this system: the
> declaration parser, the diff between declared and installed, the refusal
> rules, and — the assertion I care most about — **the exact argv that would be
> run**. Assert that a `-Sy` without `-u` is never emitted, because a partial
> upgrade is the documented way to break Arch; that a removal with dependants
> refuses without `--yes`; that the bootloader, kernel, display manager and
> init system are refused separately. `apps/power`'s self-test is the pattern
> to copy: fake binaries on `PATH` writing to a sentinel file, the sentinel
> asserted empty after every verb is driven, and the trap sprung deliberately
> first so a broken trap fails loudly rather than passing.
>
> Only when that is green, and once, install something small and removable for
> real, and say exactly what you installed and that you removed it.
>
> Snapshot before every mutation and name it for the operation. sudo needs a
> password on this machine: ask, never cache, never embed. An agent may not
> start an unattended full upgrade — a `.pacnew` or a keyring change needs a
> person — so `upgrade` is interactive by design and should say so.
>
> Report the assertion count, the argv assertions specifically, what you
> installed for real, and everything you chose not to automate.

# Applications

Gaps the owning agent named as deliberately unfinished. Each is small enough to
bundle; none is worth an agent alone.

**`mail`** — drafts autosave (the composer loses everything on exit), multi-select,
address autocomplete. All three were stopped rather than half-landed.
**`docs`** — `.odt` and `.rtf` import (export-only today), merged cells, an image
inside a table cell, regex find, non-ASCII case folding (`Straße`/`STRASSE`).
**`sheets`** — 3-D ranges (`Sheet1:Sheet3!A1`), sheet-local names, multi-sheet CSV
export, chart resize and data labels.
**`slides`** — styled runs inside one text box, transitions, `.pptx`/PDF import,
real placeholders so PowerPoint's outline view is not empty.
**`videoedit`** — a live gain change costs ~87 ms of silence because honouring it
rebuilds the graph; scrubbing is silent; no playback rate but 1×.
**`captions`** — word-level karaoke highlight, diarization (needs a tinydiarize
model), undo/redo, and `-tr` translation is wired but never run end to end.
**`call`** — echo cancellation, adaptive bitrate, more than two participants,
encryption.
**`torrent`** — BEP 9 (so a magnet resolves without a local `.torrent`), upload
rate limiting, UDP scrape. DHT and PEX are deliberately absent and should stay
so.
**`ai`** — retrieval is impossible on this ollama build (`/api/embed` returns
"does not support embeddings"); prompts cannot be edited in place;
conversations cannot be renamed or searched.
**`clipboard`** — the 0.7 s poll races a fast selection handover and misses
entries; measured, not theoretical.
**`archive`** — 7z and rar (not installed), password-protected archives.
**`image`/`video`/`audio`** — no hardware decode, no chapters, spectrum capped at
4 kHz by the 8 kHz decode.

> **Prompt** (one group at a time). Close the named gaps in `<app>`: `<list>`.
> You own `apps/<app>/` and nothing else.
>
> Read the application's own `--selftest` first and keep every existing
> assertion passing; report the count before and after. Each gap above was
> named by the agent that built the app as deliberately unfinished, so the
> reasoning for *why* it was left is usually in a comment near the code — read
> that before deciding how to do it.
>
> Where a gap is "not possible here" rather than "not done" — `ai`'s retrieval,
> `archive`'s 7z — confirm that is still true and say so rather than working
> around it.
>
> Record a demo with `apps/tools/headless-record.sh` and watch the frames.

---

# The long work

From the README's *Where this is going*. Each is a project, not a task, and
each needs a design before an agent.

**The web backend.** The cheapest of the four ports and the one that proves the
seam: `window.odin` already dispatches to `wayland.odin` or `x11.odin`, Odin
targets WebAssembly, and a canvas `ImageData` buffer is the same thing the
rasterizer already writes into. Layout, text and widgets do not change.
Constraints: no subprocess, fonts must be shipped rather than discovered,
threads need Web Workers with `SharedArrayBuffer` and cross-origin isolation.

**Windows, macOS, Android, iOS.** Each needs a window, a buffer to blit into
and an input stream; none needs a GPU. The applications are the harder half —
many shell out to ffmpeg, `bsdtar`, `wpctl`, `nmcli`, poppler, and a sandboxed
mobile process cannot spawn any of them. **The discipline that makes this
possible starts now**: keep each application's core free of subprocess
assumptions and put the shelling-out behind a seam. `mailcore` and `docs` are
already the right shape.

**The account and sub-identities.** Supabase, with row-level security as the
load-bearing piece, because separation between identities has to be enforced by
the database rather than by which panel is showing. The testable claim, and the
one to build toward: *an assistant scoped to one identity, asked for another's
data, fails* — with an assertion that says so and runs.

**Device interop.** Clipboard, application state with the cursor position
intact, notifications once on the device being looked at, input across screens,
media sessions, and agent context. `apps/call`'s protocol and `apps/chat`'s
ordering guarantee are the prior art. End-to-end encrypted in both the direct
and relayed cases, which is where it differs from server-side AI.

---

# Known-unfixed, deliberately

So nobody spends an afternoon rediscovering these.

- **Emoji ZWJ sequences** are not composed (no GSUB), so a skin-tone modifier
  renders as a swatch after the base emoji.
- **A client's keyboard re-bind is asynchronous**, and a key pressed in that
  window is lost. Measured independently by two agents at roughly **one key in
  five** when `wtype` runs per step. The recorder now drives a whole take
  through one `wtype` process, which fixed it (27 of 27 across three runs), so
  this no longer bites demos — but the underlying behaviour is still there and
  would bite an on-screen keyboard or IME that attaches and detaches. Fixing it
  properly means not losing keys that arrive between the bind request and the
  `enter`.
- **Pointer steps do not reach a client on the headless seat.** The compositor
  runs with no input devices, so the seat never gains a pointer capability.
  `swaymsg seat cursor` reports success regardless because it moves sway's own
  cursor, which is why this looked like it worked; `wlrctl` speaks the right
  protocol but its move is relative and a click still reaches nobody. Verified
  by clicking a calculator keypad and watching nothing happen. Demos are
  keyboard-driven, which every application supports.
- **`apps/network` cannot change network state** and must stay that way.
- **`apps/power` executes nothing** and must stay that way.
- **DHT and PEX in `apps/torrent`** are absent on purpose: both are ways to
  learn an address from a stranger.
- **`qwen3:0.6b` is frequently wrong.** Every surface that uses it says so, and
  should keep saying so.
