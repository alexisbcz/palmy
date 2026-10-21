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
  58 when this line was written and grows; do not trust a number quoted in a
  brief over that command. `drive`, `forge` and `installer` need their own
  collections (`drive:`, `forge:`, `install:`) on the command line.
- **The 182-case parity suite must not move.** `cd parity && bash
  tools/diff-all.sh`. It compares against real browser captures and is the
  instrument that says whether something changed that was not meant to. The
  mean mae depends on the machine's fonts and browser — 2.953 on the old Arch
  host, 2.959 in the build VM with Chrome for Testing 153 (playwright 1.63) —
  so compare against a baseline taken on the same machine, not against a
  number in a brief. It prints `measuring <tree>` first; check that line is
  the tree you meant. The browser captures (`parity/out/web/*.png`) are
  gitignored, so a fresh clone has none, and the renderer sizes each canvas
  from them: without them 53 cases render a pixel off and every comparison is
  meaningless. Re-capture (`parity/harness`: `capture.mjs`, `interact.mjs`
  against `parity/web`'s dev server) or copy them in before measuring.
- **The unit tests must pass**: `odin test tests -collection:shadcn=$PWD/shadcn`
  — **154 tests**. Note that `tests/` imports `"../palmy"` by *relative path*,
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

## K3 — small gaps, each reported by a real application

| gap | reported by | note |
| --- | --- | --- |
| `text-slate-100` on `bg-indigo-500` is 4.08:1 | tests | under WCAG AA for body text. A toolkit design decision, not something a test should silently enforce (`tests/widgets_test.odin:446`) |
| no `xdg_popup` | several | menus and tooltips are drawn in-window; a real constraint, not a bug. `apps/wm` serves `xdg_popup` to other clients now, so the server side exists |
| ZWJ emoji sequences not composed | typography | needs GSUB; a skin-tone modifier renders as a swatch after the base emoji |
| a client's keyboard re-bind is asynchronous | editor, mail, vault | fixed in the recorder, still a latent toolkit issue — see *Known-unfixed* |

The clipboard offer API is done (`clipboard_watch`, `clipboard_next_offer`,
`clipboard_offer_read`; `tests/clipboard_offer_test.odin`), and `apps/clipboard`
captures through it, falling back to `wl-paste` only without data control. Its
edges are untested:
`ext_data_control_v1` (only wlroots' older protocol has run), the `.Focused`
fallback on a compositor without data control, X11 reads larger than one
request, and X11 owners other than palmy.

## K4 — frame-loop follow-ups

The loop is verified on X11 (Xvfb + openbox), weston, mutter, gnome-shell,
kwin 5.27, cage and sway, all in the arm64 VM: idle apps at ~0% CPU, carets
blink, vault's clipboard clear and idle lock fire within 2–13 ms of their
deadlines while minimised, covered or on another workspace. A hidden or covered
X11 window no longer repaints. Every wait outside palmy now goes through
`poll_fds` or `epoll_pwait` (notify's toasts and center used to quit within
43–286 ms on arm64). The 50 ms toast workaround is gone everywhere: the stale
toast did not reproduce in 648 runs. `PALMY_TRACE_LOOP=1` prints each loop
decision. What is left:

- **A compositor that throttles hidden windows** rather than withholding frame
  callbacks (KWin 6, Hyprland) — none was installable in the VM.
- **Real GPU drivers**, and a full palmy run on amd64 or riscv64 (it compiles
  for both; only a `poll_fds` harness ran there, under Rosetta and qemu-user).
- **mutter and gnome-shell in the VM do not pace frames** (a visible animating
  window runs at 300–500 fps); `weston-simple-shm` does the same, so it is the
  VM's software path, not palmy — but worth a look on real hardware.
- **X11 window managers that keep minimised windows mapped** would see no
  saving from the covered-window rule.
- **The loop exits 0 when the connection dies**; it says why on stderr and in
  `window_error(app)`, but no application checks it.
- **A caret blink repaints the whole window in software** — most of the 2–8%
  of a core a focused field still costs.

---

# The window manager

`apps/wm` runs on bare metal now, inside QEMU. `wm --drm` (`apps/wm/bare.odin`)
drives KMS dumb buffers with page flip, reads `/dev/input/event*` directly,
compiles its own keymap without libxkbcommon, and opens the devices itself when
there is no logind, which is how Palmy runs it. It also gained `--exec`
and `--kiosk`, which the login screen uses. The nested mode is unchanged.

## W1 — boot it: done, in QEMU only

The Palmy image boots to `wm --drm` as user palm, and the verification run
in `distro/README.md` drove it over QMP: SUPER+Return opens `term`, typed
commands run, two windows tile, and an absolute pointer click moves focus
(`distro/out/shots/verify-r1-0[2-6]-*.png`). `wm --drm-probe` inside the guest
passes 173 of 173. What W1 asked for and did not happen:

- **Never on real hardware.** Only QEMU has run (virtio-gpu and bochs-drm).
  The SETCRTC + DIRTYFB fallback for a device that refuses page flip is now
  exercised by forcing it (`PALMY_WM_DRM_NOFLIP=1`, `qemu-test.sh --noflip`)
  on both; a VT is exercised with `qemu-test.sh --vt 1`.
- **The logind path has never executed.** `seat_take_control` and
  `seat_bind_backends` are wired, but Palmy has no logind and the host was
  off limits, so no `TakeDevice` has returned a real descriptor and no
  `PauseDevice` has arrived.
- **Two heads, in QEMU only** (two GPUs; see multi-head under W2).

## W2 — the things a daily driver needs that it does not have

- **No `linux-dmabuf`**, so no GPU client — Firefox, Chromium, anything on EGL
  or Vulkan. Importing a dmabuf into a CPU rasterizer needs GPU readback it
  cannot do. This is a design question, not a task.
- **No XWayland**, so no X11-only application. Probably by linking the real
  Xwayland binary rather than hand-rolling it — the one place to break the
  zero-dependency rule without regret.
- **Output hotplug is unproven.** Two heads run (virtio-vga + virtio-gpu-pci
  in QEMU): one output per head, its own bar and workspace. Plugging and
  unplugging a monitor was not exercised: the Palmy kernel has no PCI
  hotplug and QEMU's virtio-gpu enables extra outputs only from a UI.
- **Damage tracking is one rectangle per frame** in wm. palmy clients now
  send real damage (the rows that changed, up to 16 rectangles, and no
  commit at all for an unchanged frame: `palmy/damage.odin`), but wm folds
  them into one box, and the CPU numbers in `distro/notes/wm.md` were
  measured before the client side changed.

---

# Distribution

`distro/` builds Palmy into a disk image (`make distro`) that boots in
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
  asks for the passphrase, a host-copied `cryptsetup` package and the kernel
  options (`CONFIG_DM_CRYPT` and the ciphers). The kernel options are set,
  built in; the package, the initramfs and the installer's side are not.
- **The wm bar's date** (`Tue 13 Oct`) and its empty-desktop hint are
  English in every language, because wm has no catalogue.
- **NVMe under a BIOS needs a boot index.** QEMU's SeaBIOS never tries an
  NVMe disk unless it has one (what choosing it in a BIOS boot menu does);
  with one, an installed NVMe disk boots through limine's BIOS stages.
- **Some old BIOSes refuse a GPT disk whose protective MBR entry is not
  marked active** (parted's `pmbr_boot`). The installer leaves it inactive,
  as UEFI asks; no such BIOS was at hand.
- **Not exercised:** MMC partition naming and 4 KiB-sector devices outside
  image files; real hardware, and a real USB stick.
- **The Japanese subset on the live medium is generated by hand.**
  `distro/live/subset-cjk.py` needs fontTools, which the build host does not
  have by default; `live/build.sh` refuses a subset missing a character of
  `distro/locale/ja`, so a new Japanese string means running it again.
- **Erase-the-whole-disk only:** no resize or dual boot. The contract chose
  this. It is listed here so that it is not mistaken for finished.

## The system

- **The disk image has no firmware.** The installer installs
  `linux-firmware` (or, from the medium, the parts the live ISO carries:
  `LIVE_FIRMWARE` in `distro/live/build.sh`), and the live system runs with
  those parts; the disk image, built for QEMU, has none
  (`distro/notes/kernel.md`, Firmware). The firmware also makes the ISO
  576 MB, held in RAM.
- **busybox's `su` still fails** for anyone but root (busybox is not setuid).
  `doas` and `passwd` (distro/doas, distro/passwd) replace what mattered;
  `su` could be dropped from the busybox package.
- **glibc, libxkbcommon, xkeyboard-config, tzdata, e2fsprogs, dosfstools,
  limine and the CJK font are copied from the Arch build host**
  (`distro/recipes/generate.sh`). Where a version is recorded, it comes from
  `pacman -Q`. The image is only as reproducible as the host. So are
  PipeWire, BlueZ, OpenSSL and the libraries they pull; dbus, iwd, ffmpeg,
  opus and libarchive are built from pinned, checksummed sources
  (`distro/recipes/runtime/src`), and glibc 2.44 builds that way too but is
  not switched over yet (`distro/notes/runtime.md`).
- **Never booted on real hardware.** The kernel is configured for it and
  was tested on emulated PC devices (NVMe root, e1000e, HD Audio, xHCI,
  AHCI, PCIe hotplug), but no native GPU driver, Wi-Fi card or SOF audio
  has run. No early microcode, no initramfs for an encrypted root, and no
  fallback boot entry with the previous kernel (`distro/notes/kernel.md`).
- **Not exercised in the image:** Restart from the greeter, the autologin
  and single-user limine entries, and the windowed `distro/run-qemu.sh`
  (all testing was headless). Restart passed in the login agent's own
  initramfs boot; logging out with SUPER+SHIFT+E now runs in
  `distro/recipes/runtime/test-runtime.py`.
- **The public repository is published by hand** from one machine
  (`distro/repo-publish/publish.sh`, the release key in
  `~/.config/palmy/keys/`). No CI publishes it, the key has no backup or
  rotation plan beyond "ship a new .pub, then re-sign", and the published
  palmy-base is rebuilt at publish time with the release key standing in
  for the checkout's build key. The image points at
  `https://palmy-packages.vercel.app/x86_64` (`distro/notes/palm.md`).
- **palm**: no revocation checking in its TLS client, indexes do not expire,
  and each package is decompressed whole in memory to install
  (`distro/notes/palm.md`, *Not done*).
- **Runtime dependencies** (`distro/notes/runtime.md`): poppler,
  whisper.cpp and v4l-utils are not shipped, and ffmpeg has no libass
  (videoedit's `subtitles`). The kernel's crypto API and Bluetooth,
  PipeWire started by palm-login, `apps/network` on iwd and the bus running
  as `dbus` are done (test-runtime.py passes on the shipped kernel).
- **busybox's serial `login`** ignores shadow's aging fields; palm-login,
  doas and passwd honour them.

---

# The command surface

The design is `docs/PALM-CLI.md`, the convention `apps/kit/cli.odin` (documented
in `apps/APPS.md` under `kit.cli`), the dispatcher `apps/palm`. **All 39 nouns are
on it**; the `NOUNS` table in `apps/palm/main.odin` is the source of truth and
`palm --selftest` holds it honest (it now runs every child with a private home
and a 30 s timeout). `mail` routes to the cloud's `palm-mail`; the desktop
client `apps/mail` has a full CLI but no noun yet — `mailbox` is the proposed
one. `colorpick`, `emoji`, `photoshop` and `archive` have no noun and no CLI.

## C3 — what is left in `kit.cli`

Secret flags and private arguments, an owned argv arena, repeatable flags,
`unless`, surface-wide flags, `takes_word`, `on_refuse`, display-width tables
(16 columns), the widened guard, `cli_capture`, `cli_partial`, progress and jobs
are all in. Left:

- **Surface flags are not accepted before the verb**, and a line of only
  surface flags is not handed to the window (`mail` keeps a small pre-check).
- **`unless` counts an alternative given with an empty value** as given
  (torrent and notes keep a body check).
- **No long aliases on a `Param`**, so slides, sheets and image use
  `--left/--top/--width/--height` where `x/y/w/h` would read better.
- **No public padding helper**: settings, accounts, welcome, index, drive and
  prose still pad tables by bytes with `%-Ns`.
- **`takes_word` checks only the first word**, and sheets, docs, torrent,
  audio, browser and money could set it but do not.
- **vault's `health --breach`** asks for `--yes` itself on a read; `on_refuse`
  only covers destructive commands.
- The audit log is compact JSON while `--json` is indented; several self-tests
  match its exact text, so changing that is a coordinated edit.

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
**`sheets`** — charts resize from the keyboard and CLI only (the grid has no
pointer handling); a 3-D reference is plain text in shared editing, so a
collaborator's sheet rename does not rewrite it; a name cannot be a 3-D range;
a deleted name's references vanish rather than becoming `=#REF!`; multi-sheet
CSV is export-only; the frozen-pane line is drawn across charts.
**`slides`** — styled runs inside one text box, transitions, `.pptx`/PDF import,
real placeholders so PowerPoint's outline view is not empty.
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
**`files`** — Drive sync badges need the drive server; `open` is tested only
under `--dry-run`.
**`editor`** — multi-caret editing and auto-closing brackets have no CLI form.
**`image`** — a copy saved with Ctrl-S does not appear in the thumbnail strip
until the folder is reopened.
**`clipboard`** — the `.Focused` fallback is untested (headless sway always
offers data control).
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

- **Playwright's own browser download fails** (`npx playwright install`
  exits with "Download failure") even when its CDN answers; the Chrome for
  Testing zips from `storage.googleapis.com/chrome-for-testing-public/<version>/`
  unpacked into `~/.cache/ms-playwright/chromium{,_headless_shell}-<rev>/` with
  an `INSTALLATION_COMPLETE` marker work.
- **`torrent`'s end-to-end check** ("seeder still uploaded the whole payload")
  fails about 1 run in 6 under full CPU load, on main as on branches.
- **The VM's `bluetoothctl` never returns** (no bluetoothd); `palm --selftest`
  now times it out as unavailable, but anything else calling it blind hangs.
- **`apps/APPS.md`'s *Building* section** still hardcodes
  `/home/alex/Work/palmy` in its build command.
- **Self-tests with known, environment-free failures**: `docs` segfaults on the
  default 8 MB stack in "find: regular expressions" (run with `ulimit -s
  unlimited`); `pickdemo` fails 3 symlink-loop checks; `audio` fails 8 playback
  checks because its clock does not advance headless.
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
the web from inside Palmy at all. Whether that is a gap or the point is the
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
  `apps/term` is the Palmy image under QEMU, where a virtio-tablet click
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
