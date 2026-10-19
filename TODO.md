# TODO

What is not done, in the order it is worth doing, with a prompt for each that
an agent can be handed without further context.

This file is written to be *used*, which means it has to stay true. It did not:
a session found five of its claims false at once — a whole section describing
work that had shipped two commits earlier, a test count off by more than half,
a reproduction case that reproduced fine, an application named as having a
workaround it did not have, and an importer listed as missing that was wired
into three entry points. Everything below is justified by something an agent
actually hit, and where a number appears it came from running the command next
to it.

`apps/track` exists now and can hold this file instead: `track import TODO.md`
turns it into one Markdown file per issue, and an issue may carry a `verify:`
command so that `track stale --run` reports which of these claims have stopped
being true. Three of the five above were caught that way.

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
- **Work in a git worktree when the task touches `palmy/`, `shadcn/` or
  `parity/`.** Parity is a *measurement*, not a build: several agents editing
  the toolkit in one tree each see the others' regressions with no way to tell
  them apart. Worktrees make every parity run trustworthy, and the merge is
  cheap if the file ownership is disjoint — decide that up front and say it.
- **Never end a tool call with shared code uncompilable.** Every application
  and the parity suite build against `palmy/`. Breaking it blocks everyone, and
  it has happened twice. The count is whatever `ls -d apps/*/ | wc -l` reports
  minus `kit/`, `tools/` and `prose/`, which have no top-level `main` — it was
  45 buildable when this line was written and grows; do not trust a number
  quoted in a brief over that command.
- **The 182-case parity suite must stay at mean mae 2.953.** `cd parity && bash
  tools/diff-all.sh`. It compares against real browser captures and is the
  instrument that says whether something changed that was not meant to. It
  prints `measuring <tree>` first; check that line is the tree you meant.
- **The unit tests must pass**: `odin test tests -collection:shadcn=$PWD/shadcn`
  — **121 tests**. Note that `tests/` imports `"../palmy"` by *relative path*,
  not as a collection, so `-collection:palmy=` is silently ignored and the
  suite always measures the `palmy/` sitting beside it.
- **Rebuild every app** after touching shared code: `for d in apps/*/`.
- **Report an assertion count**, and say what you could *not* verify. A stated
  gap is worth more than a claim that cannot be checked.
- **Render and look.** Write PNGs through `p.offscreen_*` and read them back.
  Several real bugs have passed every assertion and been visibly wrong — a
  selection that flashed an entire line grey, a shadow measured faster and
  drawn differently, a border colour silently falling back to its default.
- **Record with `apps/tools/headless-record.sh`**, which runs on a private
  invisible compositor — no lock, no queue, nothing on the user's screen.
- **Use a private scratch directory.** The session scratchpad is shared between
  agents: one had its harness script overwritten mid-run by another's copy
  pointing at a different tree, and another's sweep iterated over a neighbour's
  binaries and briefly opened windows on the user's screen.

**The safety rules, which are not negotiable and must be restated in full in
any prompt they touch:**

- Networking is **read-only**. Nothing may disable the radio or drop a
  connection — that would take the machine, and the session doing the work,
  off the network. `apps/network` routes those through a logged intent.
- Power and session actions are **intent-only**: log the command, execute
  nothing. `apps/kit`'s CLI guard now enforces this for any command declared
  `intent`, and refuses the whole denylist while a CLI command runs.
- Never `systemctl enable/disable/start/stop` sddm, greetd, display-manager or
  ollama. ollama is deliberately a user process here.
- The real webcam and microphone are **never** captured into a demo,
  screenshot, measurement or committed file. Synthetic sources only.
- Never read the user's real credential stores, mail, or financial files.
- **`sudo` needs a password on this machine.** An agent cannot be given one and
  must never cache, embed or prompt for one. Anything needing root stops at the
  line and says what a person has to run.

---

# Toolkit

## K1 — `[12px]` is silently dropped

> **Done.** `[12px]` is the bare number, `[N%]` is a percentage wherever a
> dimension is expected (`w-`, `h-`, `min-`/`max-`, insets), and `rem`/`em`
> are refused rather than guessed: palmy has no root font size, and 16 would
> be right on some screens and silently wrong on others. A dropped numeric
> bracket value is reported once on stderr (`palmy: dropped the class value
> [3rem]: ...`); colour brackets are not. `tests/bracket_units_test.odin`.
> Parity unchanged, metrics byte-identical. What the grep finds now: the 41
> `text-[9px]`/`[10px]`/`[11px]` in `apps/track/ui.odin` now render at the
> size asked for (they were at the inherited size, so `track` will look
> smaller); `apps/track/repro/flexwrap` and the `[420px]` in
> `apps/track/selftest.odin` now really constrain the row, so that repro now
> reproduces; `max-h-[86%]` at `apps/captions/ui.odin` now applies. None
> relied on being dropped in a way that should stay.

`scale` in `palmy/class.odin:296` parses a bracket value with
`strconv.parse_f32` at line 305, which rejects a unit suffix:
`parse_f32("420px")` returns `ok=false`, so **the whole class is discarded with
no warning**. `max-w-[420px]` does nothing. `text-[11px]` renders at the
inherited size.

This is the real Tailwind spelling, and the README promises "the class names you
already know", so it will keep being written. **44 live instances today**, found
with

```sh
grep -rnoE '\[[0-9.]+(px|rem|em|%)\]' --include=*.odin apps/ palmy/ shadcn/
```

after discarding comment lines — most of `shadcn/`'s hits are header comments
quoting the original `.tsx`, and `palmy/` and `shadcn/` have none that are live.
41 of the 44 are `text-[Npx]` in `apps/track/ui.odin`, so that application's
typography is rendering at the inherited size rather than what it asked for. The
rest are two `[420px]` in `apps/track`'s own flex-wrap repro and a pre-existing
`max-h-[86%]` at `apps/captions/ui.odin:1838`. `apps/term` had one and fixed it
by deriving the class from its constant, which is the pattern to copy.

It also produced a false negative in `apps/track`'s own verification of a real
bug: the repro wrote `max-w-[420px]`, the class vanished, the row became an
ordinary full-width one with no measure/arrange gap, the bug correctly did not
reproduce, and the tracker reported a live bug as fixed.

> **Prompt.** Make `palmy`'s bracket values accept a unit suffix, in
> `palmy/class.odin`.
>
> You own `palmy/class.odin`. Work in a git worktree. Do not touch `apps/`,
> `shadcn/` or `parity/`.
>
> `scale` at line 305 hands `[420px]` straight to `strconv.parse_f32`, which
> fails on the suffix and drops the class. Accept `px` as an explicit synonym
> for the bare number, since palmy's bracket values are already exact pixels.
> Decide deliberately what to do with `rem`, `em` and `%` and say why — `%` has
> a real meaning that `pct()` already expresses and may belong here; `rem` and
> `em` need a root size this toolkit does not have, so refusing them loudly may
> be better than guessing.
>
> **A dropped class must stop being silent.** That is the actual defect: the
> parse failure is recoverable, the silence is not. Whatever you decide about
> the units, make an unparseable bracket value visible — at minimum behind the
> existing verbose logging, so a developer can find it.
>
> Then grep the tree for `\[[0-9.]+(px|rem|em|%)\]` and report which are now
> correct and which were relying on being dropped. Do not fix them; they are
> other directories.
>
> Parity must stay at 182 / 2.953 with metrics byte-identical — if a case moves,
> a parity case was itself relying on a dropped class, which is worth knowing.
> 121 unit tests, every app builds, assertion count reported.

## K2 — `p.slider`'s knob walks off the end of its track

> **Done.** Track, fill and knob are placed with `inset`; the knob's centre
> travels between half a knob in from each end and the pointer maps onto the
> same span. `tests/slider_test.odin` asserts the geometry and the painted
> pixels at 0, 25, 50 and 100; rendered and looked at.

`slider` offsets its knob with `margin[LEFT] = -8`, and **a negative margin does
not apply to an absolutely positioned child**. Measured on a 248px track: at
value 25 the knob rect sits at x=78 where its *centre* should be 78, and at
value 100 the rect is 264..280 while the track ends at 264 — painted pixels
265..278, entirely outside the control. Confirmed by rendering and looking.

`palmy/widgets.odin`'s `text_area` positions its caret and selection with
`inset` for exactly this reason, with a comment naming this bug.

> **Prompt.** Fix `p.slider`'s knob position, in `palmy/widgets.odin`.
>
> You own `palmy/widgets.odin`. Work in a git worktree. Do not touch `apps/`,
> `shadcn/` or `parity/`.
>
> The knob is centred with a negative left margin, which an absolutely
> positioned child ignores. Use `inset` as `text_area` in the same file does.
> Assert the knob's painted pixels stay inside the track at 0, 50 and 100, and
> that its centre tracks the value — and **render it and look**, because the
> existing assertions passed while it was visibly wrong.
>
> Check whether `sc.slider` in `shadcn/` has the same shape before you start; it
> was written against the browser's geometry and may not. Report, do not fix.
>
> Parity byte-identical, 121 tests, every app builds.

## K3 — small gaps, each reported by a real application

> **Mostly done**: `window_size(app)`; `push_styled` resolves `current` in the
> caller's classes; `Key_Event.unshifted` (the key's first-level keysym in the
> active layout, from `xkb_keymap_key_get_syms_by_level` / the X11 core
> mapping; `term` uses it); text direction on `Style`; and a `wl_data_device`
> client. Left: the note on `kit.clipboard_*` (kit is not palmy's), `xdg_popup`,
> ZWJ, the asynchronous keyboard re-bind, the contrast decision, and the
> clipboard app's type-aware API (rows below).

| gap | reported by | note |
| --- | --- | --- |
| ~~no window size accessor outside a frame~~ **done**, `window_size(app)` | `reader` | reads `app.win.width`/`height` directly. `offscreen_size` exists for the offscreen half; this is the `app.odin` half |
| ~~`push_styled` does not resolve `text-current`~~ **done** | `call` | it applies the caller's class *after* `push_node`, so `palmy.button(ui, "Save", "border-current")` leaves the sentinel and draws nothing. Everything from `div`/`row`/`col`/`apply`/`text`/`icon`/`image` is already right. One line: capture `style.fg` before `apply_classes`, then `resolve_current` |
| ~~`Key_Event` carries no unshifted codepoint~~ **done**, `Key_Event.unshifted` | `term` | the VT key encoder needs it to tell `Ctrl+Shift+2` from `Ctrl+@`; libghostty and the Kitty protocol both take both. `apps/term/keymap.odin` recovers it from a US-layout reverse table, exact on US and UK and wrong for one chord elsewhere. Fill it from `xkb_state_key_get_one_sym` with the shift level forced to 0 |
| ~~no text direction on `Style`~~ | `palmy` itself | **done**: `Style.text_dir`, from `dir-ltr`/`dir-rtl`/`dir-auto`, reaches `wrap_text`, and `text_area` draws each row at its paragraph's direction |
| `kit.clipboard_set`/`get` fork a process | `term` | calling them inside the frame while a reader thread wants the same mutex is a once-a-month deadlock. `term` now goes through `palmy.clipboard_*`, which does not fork; kit's should too (see *The system*) and say they fork in the fallback |
| `wl_data_device` client: text only | `clipboard` | **the client exists now** (`palmy/clipboard.odin`), but its API is text: set, get. The `clipboard` app needs a selection-changed notification carrying the offer's type list and a read of one type from that same offer, which is what removes the two-call race — **including the sensitivity gate** — between `wl-paste --watch` and `--list-types`. The offer and its types are already tracked per selection; exposing them is the remaining work |
| `text-slate-100` on `bg-indigo-500` is 4.08:1 | tests | under WCAG AA for body text. A toolkit design decision, not something a test should silently enforce |
| no `xdg_popup` | several | menus and tooltips are drawn in-window; a real constraint, not a bug |
| ZWJ emoji sequences not composed | typography | needs GSUB; a skin-tone modifier renders as a swatch after the base emoji |
| a client's keyboard re-bind is asynchronous | editor, mail, vault | fixed in the recorder, still a latent toolkit issue — see *Known-unfixed* |

> **Prompt.** Clear the gaps in the table in `TODO.md` section K3.
>
> You own `palmy/`. Work in a git worktree. Do not touch `apps/`, `shadcn/` or
> `parity/`. Read the table first — each row names the application that hit the
> gap, and reading that app's workaround will usually tell you what the API
> should have been.
>
> Take the four one-liners first: the window size accessor, `push_styled`'s
> `text-current` hole, `Key_Event.unshifted`, and the doc note on
> `clipboard_set`. Then the text-direction field on `Style`, which is the only
> one with design in it and which unblocks correct RTL in `text_area`.
>
> Leave `xdg_popup`, ZWJ composition and the `wl_data_device` client alone
> unless everything else is done: each is a project rather than a gap, and
> `xdg_popup` may be a deliberate constraint.
>
> Every change additive — no existing signature changes. Parity at 182 / 2.953
> with metrics byte-identical, 121 tests, every app building, assertion count
> reported.

## K4 — eight applications still pin the frame loop at vsync

> **palmy's site and `launcher` are done**: the text field caret already
> used `caret_on`; `launcher`'s caret and toast timer now do too, idle CPU
> 39.6% → 1.0% of a core on headless sway. Seven remain: `archive`, `chat`,
> `clipboard`, `emoji`, `kit`, `slides`, `vault`.

`wake(app)`, `wake_after`, `wake_at` and `wake_cancel` exist now and work on
both backends. Two applications were converted as the proof — `colorpick` went
from 33% of a core to 0.9%, `ai` from 43% to 8.2% while streaming. Eight have
not been: `archive`, `chat`, `clipboard`, `emoji`, `kit`, `launcher`, `slides`,
`vault`.

The highest-leverage single site is not in an application at all.
`palmy/widgets.odin:510` sets `ctx.animating = true` unconditionally while a
text field has focus, purely to blink a caret, so **any** application with a
focused field sits at vsync. That is what cost `colorpick` a third of a core
from the moment it opened. `text_area` in the same file draws a steady caret
instead and has the exact replacement written in a comment at its caret site.

> **Prompt.** Retire the permanent `animating = true` from `palmy/widgets.odin`
> and from the eight applications that still carry it.
>
> Start with `palmy/widgets.odin:510`, in a git worktree, and do that one alone
> first — it is shared code and it changes every application at once. The
> replacement pattern is in the comment at `text_area`'s caret:
>
>     phase := monotonic_now() % BLINK_PERIOD
>     visible := phase < BLINK_ON
>     wake_after(ctx, (visible ? BLINK_ON : BLINK_PERIOD) - phase)
>
> **The trap, which bit both converted applications: `ctx.now` cannot drive a
> timer.** `tick` clamps `dt` to 0.1 s so a stalled frame cannot teleport an
> animation, which means a four-second interval measured against it lasts
> twelve seconds at two frames a second. Read a real monotonic clock.
>
> Then take the applications in separate passes, one directory each, measuring
> idle CPU before and after from `/proc/<pid>/stat` across all threads on a
> private headless compositor. `vault` is the one that matters most: its idle
> auto-lock, clipboard countdown and TOTP countdown are *security* timers that
> only fire while the loop happens to be running.
>
> Leave the bounded `ctx.animating` sites in palmy alone — `widgets.odin:182`,
> `node.odin:434`, `paint.odin:72` all settle and stop.
>
> Report measured idle CPU per application, before and after.

---

# The window manager

`apps/wm` runs on bare metal now, inside QEMU. `wm --drm` (`apps/wm/bare.odin`)
drives KMS dumb buffers with page flip, reads `/dev/input/event*` directly,
compiles its own keymap without libxkbcommon, and opens the devices itself when
there is no logind, which is how Palmframe runs it. It also gained `--exec`
and `--kiosk`, which the login screen uses. The nested mode is unchanged.

## W1 — boot it: done, in QEMU only

The Palmframe image boots to `wm --drm` as user palm, and the verification run
in `distro/README.md` drove it over QMP: SUPER+Return opens `term`, typed
commands run, two windows tile, and an absolute pointer click moves focus
(`distro/out/shots/verify-r1-0[2-6]-*.png`). `wm --drm-probe` inside the guest
passes 173 of 173. What W1 asked for and did not happen:

- **Never on a real VT or real hardware.** Only virtio-gpu has run, so the
  SETCRTC + DIRTYFB fallback for a device that refuses page flip has never
  triggered.
- **The logind path has never executed.** `seat_take_control` and
  `seat_bind_backends` are wired, but Palmframe has no logind and the host was
  off limits, so no `TakeDevice` has returned a real descriptor and no
  `PauseDevice` has arrived.
- **One head only.** See multi-head under W2.

## W2 — the things a daily driver needs that it does not have

- **No `linux-dmabuf`**, so no GPU client — Firefox, Chromium, anything on EGL
  or Vulkan. Importing a dmabuf into a CPU rasterizer needs GPU readback it
  cannot do. This is a design question, not a task.
- **No XWayland**, so no X11-only application. Probably by linking the real
  Xwayland binary rather than hand-rolling it — the one place to break the
  zero-dependency rule without regret.
- **Multi-head is unproven.** One monitor is plugged in; the layout, the CRTC
  allocator's collision avoidance and `global_remove` on unplug are exercised
  against fabricated heads only.
- **No VT switching.** Without logind, Ctrl+Alt+Fn does nothing and the console
  VT is not put into `KD_GRAPHICS`. Input devices are grabbed, so the console
  does not also receive keys.
- **No input hotplug.** `/dev/input/event*` is scanned once at startup; a
  keyboard plugged in later is ignored. palm-init already sets its permissions
  from the uevent, so only the wm side is missing.
- **Keys reach clients as press and release pairs** re-derived from the keysym,
  so a client cannot see a key held down.
- **A full CPU repaint every frame**, no damage tracking.

---

# Distribution

`distro/` builds Palmframe into a disk image (`make distro`) that boots in
QEMU from UEFI firmware through limine, palm-init and palm-login to the
greeter and the window manager, and installs and removes packages with palm
from a signed repository. `make -C distro iso` builds a live ISO whose
installer (`apps/installer`, or `palm-install` on the serial console) erases
a disk and installs onto it. In QEMU the installed disk then boots alone
through its own UEFI entry, to a greeter in the chosen language.
`distro/README.md` says what was verified and how, and `distro/INSTALLER.md`
is the installer's reference. These are the gaps those runs found or that
the areas' notes name.

## The installer

- **Encryption is designed, not built.** `distro/notes/installer-core.md`
  (*Encryption*) has the design: a LUKS2 root, an initramfs on the ESP that
  asks for the passphrase, a host-copied `cryptsetup` package and four
  kernel options (`CONFIG_DM_CRYPT` and the ciphers), none of which exist
  yet.
- **The wm bar's date** (`Tue 13 Oct`) and its empty-desktop hint are
  English in every language, because wm has no catalogue.
- **The greeter still mirrors its rows by hand** (`apps/greeter`, `if rtl`
  branches). The installer now uses one `dir-rtl` on its root and
  `dir-auto` on its text nodes; the greeter could do the same.
- **NVMe under a BIOS needs a boot index.** QEMU's SeaBIOS never tries an
  NVMe disk unless it has one (what choosing it in a BIOS boot menu does);
  with one, an installed NVMe disk boots through limine's BIOS stages. The
  shipped kernel config also lacks `CONFIG_BLK_DEV_NVME`, so NVMe disks are
  invisible to the live system and the installed one until it is set
  (the QEMU run used a kernel with it).
- **Some old BIOSes refuse a GPT disk whose protective MBR entry is not
  marked active** (parted's `pmbr_boot`). The installer leaves it inactive,
  as UEFI asks; no such BIOS was at hand.
- **Not exercised:** MMC partition naming and 4 KiB-sector devices outside
  image files; real hardware, and a real USB stick.
- **`apps/term` drops legacy keysyms.** Its `keysym_codepoint` covers only
  Latin-1 and `0x01xxxxxx` Unicode keysyms. With a Cyrillic, Greek, Arabic
  or Hebrew layout, or for the euro sign, wm delivers the keysym and term
  types nothing. The launcher shows the same keys correctly
  (`distro/notes/wm.md`).
- **The Japanese subset on the live medium is generated by hand.**
  `distro/live/subset-cjk.py` needs fontTools, which the build host does not
  have by default; `live/build.sh` refuses a subset missing a character of
  `distro/locale/ja`, so a new Japanese string means running it again.
- **Erase-the-whole-disk only:** no resize or dual boot. The contract chose
  this. It is listed here so that it is not mistaken for finished.

## The system

- **The kernel limine boots is a copy** made at image or install time on the
  FAT partition. `palm upgrade linux` updates `/boot/vmlinuz` on the root and
  not that copy. palm-init now mounts the ESP at `/boot/efi` from fstab (the
  image and installed disks both have the line); the linux package has to
  install there. palm has no hooks by design, so the package has to carry
  the file itself.
- **busybox's `su` still fails** for anyone but root (busybox is not setuid).
  `doas` and `passwd` (distro/doas, distro/passwd) replace what mattered;
  `su` could be dropped from the busybox package.
- **glibc, libxkbcommon, xkeyboard-config, tzdata, e2fsprogs, dosfstools,
  limine and the CJK font are copied from the Arch build host**
  (`distro/recipes/generate.sh`). Where a version is recorded, it comes from
  `pacman -Q`. The image is only as reproducible as the host.
- **Never booted on real hardware.** `distro/kernel/palmframe.config` is
  written for QEMU's devices.
- **Not exercised in the image:** Restart from the greeter, logging out with
  SUPER+SHIFT+E, the autologin and single-user limine entries, and the
  windowed `distro/run-qemu.sh` (all testing was headless). Restart and
  logout passed in the login agent's own initramfs boot.
- **The public repository is published by hand** from one machine
  (`distro/repo-publish/publish.sh`, the release key in
  `~/.config/palmframe/keys/`). No CI publishes it, the key has no backup or
  rotation plan beyond "ship a new .pub, then re-sign", and the published
  palmframe-base is rebuilt at publish time with the release key standing in
  for the checkout's build key. The image points at
  `https://palmframe-packages.vercel.app/x86_64` (`distro/notes/palm.md`).
- **palm**: no revocation checking in its TLS client, indexes do not expire,
  and each package is decompressed whole in memory to install
  (`distro/notes/palm.md`, *Not done*).
- **zram needs the kernel.** palm-init sets up zram swap from
  `/etc/palm/zram` (verified with a kernel built with `CONFIG_ZRAM=y`,
  `CONFIG_ZSMALLOC=y`, `CONFIG_CRYPTO_ZSTD=y`, `CONFIG_ZRAM_BACKEND_ZSTD=y`),
  but `distro/kernel/palmframe.config` does not enable them, so the shipped
  system has no swap.
- **Most applications still copy through `kit.clipboard_set`**, which runs
  `wl-copy`, not shipped. palmy has a native clipboard now
  (`palmy/clipboard.odin`: `wl_data_device`, the primary selection, ICCCM
  selections); `term`, `files`, `launcher` and palmy's own text widgets use
  it. `apps/kit`'s `clipboard_set`/`clipboard_get` should try
  `p.clipboard_set(text)` / `p.clipboard_get()` first (both work on the
  default window and return false with none, off the loop thread, or when
  refused) and keep wl-clipboard as the fallback.
- **busybox's serial `login`** ignores shadow's aging fields; palm-login,
  doas and passwd honour them.
- **A cosmetic fault** in the verification screenshots: the greeter's Shut
  Down button has no hover state. (`term`'s one-cell selection on a single
  click is fixed.)

---

# The command surface

`docs/PALM-CLI.md` has the design, and **its opening line saying none of it
exists is now false** — the convention is in `apps/kit/cli.odin`, the dispatcher
is `apps/palm`, and `notes`, `sheets` and `power` are converted. `apps/APPS.md`
documents `kit.start` and `kit.run` but not `kit.cli`, which is where the next
agent will look first. Both want a pass.

## C2 — bring the rest of the applications up to it

Forty-two applications, in the order an agent would reach for them. **Do not
give one agent all of them.** Four agents, one per group, each owning only its
own directories.

1. **Already close** — `mailcore`, `torrent`, `docs`, `slides`, `money`, `chat`,
   `vault`. Mostly renaming onto the convention and adding `--json`.
2. **Have an engine but no CLI over it** — `mail`, `calendar`, `reader`, `shop`,
   `maps`, `captions`, `videoedit`.
3. **UI-shaped, needing a core lifted out** — `files`, `editor`, `image`,
   `clipboard`, `colorpick`, `emoji`, `photoshop`, `archive`. The real work, and
   worth doing for its own sake: lifting the core out is what makes them
   testable headlessly.
4. **System applets** — `audio`, `power`, `sysmon`, `network`, `bluetooth`,
   `screenshot`, `mixer`. Small surfaces, and the safety rules bite hardest.

> **Prompt** (adapt the group). Bring *group N* up to the `palm` CLI
> convention: `<list the directories>`. Those directories are yours; nothing
> else.
>
> Read `docs/PALM-CLI.md`, then `apps/kit/cli.odin`'s declaration API, then one
> converted exemplar — `apps/notes/cli.odin` is the smallest, `apps/sheets` the
> richest, `apps/power` the one whose actions must stay intent-class.
>
> **Flip your nouns' `on_convention` flag in `apps/palm`'s `NOUNS` table**, or
> `palm` keeps reporting your application unavailable. `palm --selftest` asserts
> that flag is honest: a noun marked converted that does not answer `--schema`
> fails.
>
> A thing is done when **the GUI uses the same entry points the CLI does**. If
> `palm notes write` goes through a different path than typing in the window,
> the two will diverge and the CLI will be the one that rots. For group 3 that
> means genuinely separating the core from the UI, which is the point.
>
> Two Odin facts that each cost a debugging cycle, documented at the top of
> `apps/kit/cli.odin`: a slice literal written inside a procedure lives on that
> procedure's stack frame, so the command table must be a package variable; and
> package initialisers run in declaration order, so a package slice pointing at
> another is captured empty. A silently-empty `out` is a schema that lies.
>
> Keep every existing self-test passing and report the counts before and after.
> Keep each command-line path argument working — the CLI is an addition. Report
> which applications you converted fully, which partially, and what each still
> cannot do headlessly.

---

# Packages

`apps/pkg` is built and has 526 assertions, including the ones that matter: the
exact argv of every plan, that `-Sy` without `-u` is structurally impossible,
that five protected classes refuse separately, and a sentinel asserting the
planned argv is what reaches exec. The safety tests were shown to be able to
fail, by five deliberately broken builds.

**It has never run a real pacman.** That step needs a person at the terminal,
because sudo needs a password:

```sh
pkg install cowsay --dry-run --yes --json   # the plan, which is what has been tested
pkg install cowsay --yes                    # the step a person runs
pkg remove cowsay --yes
```

`cowsay`, `sl`, `figlet`, `tree`, `fortune-mod` and `lolcat` were confirmed
read-only to be in the repos and not installed. Until that runs, **no real
snapper snapshot has been created either** — the `create` argv is built from
documented flags rather than an observed run, and whether `limine-snapper-sync`
picks up a palm-named snapshot is unknown. `snapshots` and `rollback` correctly
return exit 6 because `snapper list` needs root here.

---

# Applications

Gaps the owning agent named as deliberately unfinished. Each is small enough to
bundle; none is worth an agent alone.

**`docs`** — merged cells. Left open deliberately rather than half-landed: it is
the only item that changes the table *model* rather than adding to its edges, so
`Cell` needs a span and a covered flag and then row-height measurement, the cell
box emission, the caret walk, selection, merge/split commands, six exporters
(`gridSpan`/`vMerge`, `number-columns-spanned`, `\clmgf`/`\clmrg`, `colspan`, a
flattening rule for Markdown, span fields in JSON) and three importers all read
it. Vertical spans also need the row-height loop to redistribute, which the
current single-pass measurement does not do.
**`sheets`** — 3-D ranges (`Sheet1:Sheet3!A1`), sheet-local names, multi-sheet
CSV export, chart resize and data labels.
**`slides`** — styled runs inside one text box, transitions, `.pptx`/PDF import,
real placeholders so PowerPoint's outline view is not empty. Its self-test has 8
pre-existing failures, all about embedded PNG and picture shapes.
**`videoedit`** — a live gain change costs ~87 ms of silence because honouring it
rebuilds the graph; scrubbing is silent; no playback rate but 1×.
**`captions`** — word-level karaoke highlight, diarization (needs a tinydiarize
model), undo/redo, and `-tr` translation is wired but never run end to end.
**`call`** — echo cancellation, adaptive bitrate, more than two participants,
encryption.
**`ai`** — retrieval is impossible on this ollama build (`/api/embed` returns
"does not support embeddings"); prompts cannot be edited in place; conversations
cannot be renamed or searched. **Its `--selftest` segfaults** in the "layout,
headless" section, and did so before any of this session's work.
**`archive`** — 7z and rar (not installed), password-protected archives.
**`image`/`video`/`audio`** — no hardware decode, no chapters, spectrum capped at
4 kHz by the 8 kHz decode.
**`term`** — Sixel, the Kitty graphics protocol, and splits, all deliberately
absent. The tab strip is a seam: a split is a tab holding two terminals.
**`track`** — the dependency graph's crossing count is quadratic in the edges
between adjacent layers and has only been laid out at 20 nodes.

> **Prompt** (one group at a time). Close the named gaps in `<app>`: `<list>`.
> You own `apps/<app>/` and nothing else.
>
> Read the application's own `--selftest` first and keep every existing
> assertion passing; report the count before and after. Each gap above was named
> by the agent that built the app as deliberately unfinished, so the reasoning
> for *why* it was left is usually in a comment near the code — read that before
> deciding how to do it.
>
> Where a gap is "not possible here" rather than "not done" — `ai`'s retrieval,
> `archive`'s 7z — confirm that is still true and say so rather than working
> around it.
>
> Record a demo with `apps/tools/headless-record.sh` and watch the frames.

---

# Test and tooling debt

- **`parity/` still hardcodes `/home/alex/Work/palmy` in six places**:
  `run.sh:16`, `odin/showcase/main.odin`, `harness/interact.mjs`,
  `tools/make-comparison-video.sh`, `tools/record-demo.sh`, `tools/gen-icons.mjs`,
  and a path in `CONTRACT.md`. `tools/diff-all.sh`, `odin/render/main.odin`,
  `tools/report.mjs` and `tools/geomdiff.mjs` were fixed; these were not, and
  they fail the same way — silently measuring the wrong tree.
- **`tests/test_theme_tokens` mutates the global token table at run time**,
  which races every other rendering test under the parallel runner. It produced
  bad frees and one segfault in seven full-suite runs before the new tests were
  restructured to register from `@(init)` instead. The existing test was left
  alone.
- **`vault --selftest` is not reliable under parallel load.** Its Argon2id
  derivation is wall-clock asserted: 1991 ms on a quiet machine, 3672 ms under a
  dozen concurrent agents, and the timing checks cascade into dozens of
  failures. A red vault result during a fan-out should be re-run quiet before it
  is believed.
- **`apps/term`'s 215 assertions and oracle live in `apps/term/`**, but the
  78-assertion harness that proved `shadcn`'s interactive widgets render
  identically lives only in a scratchpad and will never run again. Moving it
  into `tests/` is the obvious fix.

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
assumptions and put the shelling-out behind a seam. `mailcore`, `docs` and
`apps/term`'s `vt` package are already the right shape.

**The account and sub-identities.** Supabase, with row-level security as the
load-bearing piece, because separation between identities has to be enforced by
the database rather than by which panel is showing. The testable claim, and the
one to build toward: *an assistant scoped to one identity, asked for another's
data, fails* — with an assertion that says so and runs. `apps/pkg` and
`apps/track` both take `--identity` and the kit refuses to widen a scope, which
is the first inch of this.

**Device interop.** Clipboard, application state with the cursor position
intact, notifications once on the device being looked at, input across screens,
media sessions, and agent context. `apps/call`'s protocol and `apps/chat`'s
ordering guarantee are the prior art. End-to-end encrypted in both the direct
and relayed cases, which is where it differs from server-side AI.

**A browser.** There is none, and it is the largest missing application on any
desktop. Worth naming because the README's thesis is an assistant that is part
of the system rather than a browser tab — and right now there is no way to reach
the web from inside Palmframe at all. Whether that is a gap or the point is the
question to answer before anyone starts.

---

# Known-unfixed, deliberately

So nobody spends an afternoon rediscovering these.

- **Emoji ZWJ sequences** are not composed (no GSUB), so a skin-tone modifier
  renders as a swatch after the base emoji. `apps/term` has the same limit by a
  different route: its grid stores one codepoint per cell, which is what `foot`
  does and what its column-alignment check against `foot` confirms.
- **A client's keyboard re-bind is asynchronous**, and a key pressed in that
  window is lost. Measured independently by two agents at roughly **one key in
  five** when `wtype` runs per step. The recorder now drives a whole take
  through one `wtype` process, which fixed it (27 of 27 across three runs), so
  this no longer bites demos — but the underlying behaviour is still there. It
  was seen again this session in a `mail` recording, where "Southern reach,
  revised" arrived as "thern reach, revised".
- **Pointer steps do not reach a client on the headless seat.** The compositor
  runs with no input devices, so the seat never gains a pointer capability. One
  agent went further than the previous note and built a persistent
  `zwlr_virtual_pointer_v1` holder so the seat genuinely reports
  `capabilities: 1`; the client still receives no `wl_pointer.enter`. Demos are
  keyboard-driven, which every application supports. The cost shows up as real
  gaps: no drag-and-drop has ever completed. The one place a pointer has reached
  `apps/term` is the Palmframe image under QEMU, where a virtio-tablet click
  through `wm --drm` focused it and left a one-cell selection.
- **`apps/network` cannot change network state** and must stay that way.
- **`apps/power` executes nothing** and must stay that way.
- **DHT and PEX in `apps/torrent`** are absent on purpose: both are ways to
  learn an address from a stranger. They are now *tested* absent — the loopback
  fixture offers `ut_pex` specifically to prove it changes nothing.
- **OSC 52 clipboard *reads* are refused** in `apps/term`. A program that can
  read the clipboard can read whatever was last copied and send it anywhere,
  including over ssh, and "ask the user" does not survive a program that asks a
  hundred times.
- **`qwen3:0.6b` is frequently wrong.** Every surface that uses it says so, and
  should keep saying so.
