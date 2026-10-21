# palmy desktop apps

Four real applications built on palmy (Odin, software rasterizer, Wayland or
X11) and
the shadcn widget layer in `../shadcn`.

| app | what it is |
| --- | --- |
| `launcher/` | a dmenu/rofi replacement with rich, macOS-grade context menus |
| `files/` | a file browser, held to Finder's standard |
| `bluetooth/` | a Bluetooth applet over `bluetoothctl` |
| `network/` | a network applet over `nmcli` |

## Building

From the root of whichever checkout (or worktree) you mean to build — the
collection paths are relative to the current directory, so the binary always
measures the tree you are standing in:

```sh
odin build apps/<name> \
  -collection:palmy=palmy \
  -collection:shadcn=shadcn \
  -collection:kit=apps/kit \
  -o:speed -out:apps/<name>/<name>.bin
```

Three applications need one more collection each: `drive` takes
`-collection:drive=cloud/drive`, `forge` takes `-collection:forge=cloud/forge`,
and `installer` takes `-collection:install=distro/installer`.

## The kit

`import kit "kit:."` gives you the shared setup — do not re-implement it.

```odin
app, err := kit.start({title = "Files", width = 1100, height = 720})
// fonts, shadcn theme and the text calibration are already applied

out, ok  := kit.run({"nmcli", "-t", "-f", "SSID,SIGNAL", "device", "wifi"})
lines, _ := kit.run_lines({"bluetoothctl", "devices"})
kit.launch({"foot"})   // detached, does not block the UI
```

## The command line: `kit.cli`

An application on the `palm` convention does not parse its own arguments: it
*declares* its commands and hands the declaration to `kit.cli`
(`kit/cli.odin`). From that one declaration the kit parses and validates,
generates `--help`, prints `--schema` (what `palm schema` reads), emits
`--json`, refuses a destructive command without `--yes`, narrows the identity
scope, writes the audit log and returns the documented exit codes. The design
is `docs/PALM-CLI.md`; `apps/notes/cli.odin` is the smallest real example.

```odin
@(private = "file")
COMMANDS := []kit.Command {               // a package variable — see trap 1
	{
		verb     = "list",
		summary  = "every note, newest first",
		effect   = .Read,                  // .Read .Idempotent .Mutate .Destructive .Intent
		args     = {{name = "notebook", kind = .String}},
		flags    = {{name = "limit", kind = .Int, def = "50"}},
		out      = {{name = "notes", kind = .Array, of = {{name = "title", kind = .String}}}},
		examples = {"notes list --json"},
		run      = cmd_list,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {       // a procedure — see trap 2
	if g_surface.noun == "" {
		g_surface = kit.Surface{noun = "notes", summary = "a notebook", gui = true,
			selftest = cli_selftest, commands = COMMANDS}
	}
	return &g_surface
}

cmd_list :: proc(c: ^kit.Call) -> int {
	n := kit.cli_int(c, "limit", 50)       // also cli_str, cli_f64, cli_bool, cli_has, cli_rest
	if c.dry_run { ... }                   // the kit only marks the result; honouring it is yours
	kit.jset(c.out, "notes", kit.jarr())   // c.out is the object --json prints
	return kit.EXIT_OK                     // or kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such note")
}

main :: proc() {
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	// not handled: no arguments (or, with takes_path, a bare file) — open the window
}
```

**Two Odin traps, both silent.** (1) `COMMANDS` must be a *package*
variable: a slice literal written inside a procedure lives on that procedure's
stack frame and is gone when it returns. (2) `surface` must be a *procedure*:
package initialisers run in declaration order, so a package-level `Surface`
pointing at a field list declared further down captures it empty — a schema
that lies. Keep each command's field lists self-contained literals and the
order stops mattering.

The rest of what you need:

- **Base flags**, never redeclared: `--json --dry-run --yes --identity NAME
  --verbose/-v --help/-h --schema --parse-only --selftest`.
- **Exit codes**: `EXIT_OK` 0, `EXIT_USAGE` 2, `EXIT_NOT_FOUND` 3,
  `EXIT_NEEDS_YES` 4, `EXIT_OUT_OF_SCOPE` 5, `EXIT_UNAVAILABLE` 6,
  `EXIT_FAILED` 7. `cli_fail`/`cli_failf` record the refusal and return the
  code; `cli_err_field` adds a machine-readable key to it — a string, int,
  bool, `[]string` or any `^Json` — and `cli_err_detail` replaces the
  sentence. `cli_partial(c)` before failing keeps what was done: the refusal
  carries `out` as `partial`.
- **Declaring parameters**: beside `required`, `def`, `values`, `variadic`,
  a `Param` may be `secret` (never repeated back: the audit log, `--json`,
  refusals, `cli_note`, `--help` and the schema's examples show
  `<redacted>`; `cli_str` still returns the value), `repeat` (`cli_all(c,
  name)` is every value, in order; `cli_str` stays the last), or `unless =
  {"password-file"}` (required unless one of those has a value: `--magnet
  ""` is not given). `aliases = {"x"}` gives a flag other long spellings
  (`--x 4` is `--left 4`, read under `left`), and `confirm = "makes network
  requests to …"` makes a flag ask for `--yes` on any command, a read
  included (`vault health --breach`): exit 4 before the command runs, naming
  the flag. A surface's `flags` are taken by every command, before or after
  the verb (`mail --data-dir X list`), and published in each command's schema;
  a line of nothing but them is handed to the window, which reads them with
  `kit.cli_surface_flag(surface(), os.args[1:], "maildir")`. An output
  `Field` with `keyed = true` is an object whose keys are data; `of` is the
  shape of each value.
  A positional declared `free` takes a word starting with `-` that names no
  flag (a word with a space, like `"- One"`, or a negative number always
  does). A command with `private_args = true` has every positional replaced
  by `<redacted>` in the audit log (`clipboard add <text>`).
- **Base flags never shadow yours**: a command's own flag of the same name or
  short alias wins (`--h 12` is a height where `h` is declared), and the
  one-letter aliases are single-dash only (`-y`, `-v`, `-h`; `--y` is not
  `--yes`).
- **Destructive refusals with a reason**: `on_refuse = proc(c)` on a
  destructive command is asked why when the kit refuses it for want of
  `--yes` — `pkg remove` names the dependants. It runs under the guard as an
  intent command does, so it can execute nothing, and the exit stays 4.
- **A bare word under `takes_path`** opens the window. Set `takes_word =
  kit.cli_word_is_path` to open it only for something on disk or a URI, and
  make anything else (a mistyped verb) a usage error; a surface whose window
  takes other words (`settings network`) passes its own predicate. Every
  bare word on the line is asked, not only the first (`sheets book.csv
  tabel` is a typo); the word after an option the kit does not know is
  taken as that option's value and not asked about.
- **Stdout is the result and nothing else.** Progress and warnings go through
  `cli_note` (or `cli_trace`, `--verbose` only), which write to stderr.
  `cli_progress(c, done, total)` reports progress there too, as one JSON
  object per line under `--json`. A long command can keep a job record
  (`cli_job_begin` / `cli_job_progress` / `cli_job_end`, read back with
  `cli_jobs`) in `$XDG_RUNTIME_DIR/palm/jobs` (`$PALM_JOBS`). Text tables
  pad by display width, so `é`, `€` and CJK line up; a successful dry run
  says so on stderr in text mode and as `"dry_run": true` under `--json`.
  A command printing its own lines pads with `kit.cli_pad(s, width)` (or
  `cli_pad_left`) instead of `%-Ns`, or lays rows out with
  `kit.cli_table(rows)`.
- **Nothing prompts.** The kit never reads stdin.
- **Intent commands** (`effect = .Intent`, anything that would power off, log
  out, disconnect) are written as `return kit.cli_intent(c, "systemctl
  poweroff", "power off")`: it logs and runs nothing, and while any command
  runs the guard makes `kit.run`/`run_lines`/`launch` refuse the project's
  denylist — power and session verbs, network changes, camera and
  microphone capture, `sudo`/`doas`/`pkexec`, and every mutating `pacman`,
  `yay`, `paru` and `snapper` argv (`-Q`, `-Si`, `-Ss`, `snapper list` stay
  allowed). `pkg` execs its own plan after `--yes`, not through these.
- **Scope**: `kit.cli_scope()` is `$PALM_IDENTITY`; `c.identity` is that,
  narrowed by `--identity`; `cli_scope_require(c, owner, ...)` refuses
  anything outside the scope of every owner named.
- **Memory**: the kit's parse lives in its own arena (`cli_mem()`), so a
  command may `free_all(context.temp_allocator)` and an argv built in the
  temp allocator is safe to hand to `cli_args`.
- **Testing**: `kit.cli_args(surface(), argv)` runs a command line in-process;
  `kit.cli_capture(surface(), argv)` does the same and returns what the kit
  printed instead of printing it, and `kit.cli_capture_json` adds `--json`
  and parses it. `kit.cli_validate_output(text, FIELDS)` checks printed JSON
  against the declared `out`. Set `$PALM_AUDIT` so a self-test never writes
  the real audit log (`$XDG_STATE_HOME/palm/audit.jsonl`: JSONL, one record
  per line, spaced as `--json` spaces it — `"verb": "purge"` greps both —
  with the `--json` refusal's `error` token on a failure; `kit.cli_json_line`
  writes that format).
  The convention's own tests: `odin test apps/kit/cli_test
  -collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn`.
- **The window's loop**: `for ui in kit.frames(app)` is `p.frames` that
  notices a loop ended by a dead display connection (`p.window_error`); the
  code after the loop still runs, and the process then exits 6 with the
  reason on stderr instead of 0. An app with its own loop calls
  `kit.window_loop_ended(app)` where it ends.
- **`palm`** finds the application only once its noun's `on_convention` flag
  is flipped in `apps/palm/main.odin`'s `NOUNS`; `palm --selftest` then holds
  it to the whole convention.

## What you have to build with

- **palmy** — read `/home/alex/Work/palmy/README.md` for the full class
  vocabulary and element API. Layout is flexbox, styling is Tailwind class
  strings, and the design tokens are registered so `bg-primary`,
  `text-muted-foreground`, `rounded-lg` and `ring-3` all work.
- **shadcn** — 58 files of components: `button`, `input`, `badge`, `card`,
  `dialog`, `menu` (dropdown + context menu), `select`, `tabs`, `table`,
  `switch`, `checkbox`, `slider`, `separator`, `avatar`, `skeleton`, `tooltip`,
  `popover`, `sidebar`, `scroll_area`, `command`, `spinner`, `progress`,
  `breadcrumb` and more. Read the `.odin` file before using a widget; they take
  an explicit `State{hover, focus, disabled}`.
- Icons: `p.icon(ui, sc.ICON_FOLDER, "size-4")`. Add more with
  `cd /home/alex/Work/palmy/parity && node tools/gen-icons.mjs <PascalName>` —
  the generator is additive and safe.

## Interaction

palmy gives you hit testing, hover, focus, keyboard and scrolling. The patterns:

```odin
idx := p.div(ui, "px-3 py-2 rounded-md hover:bg-accent transition")
p.focusable(ui)              // joins the Tab order
if p.activated(ui, idx) { }  // click, or Enter/Space while focused
hovered := p.is_hovered(ui, idx)
if p.key_pressed(ui, p.KEY_DOWN) { }
n := p.key_count(ui, p.KEY_DOWN)   // see below: not the same thing
p.text_field(ui, &buf, "Search")
```

`key_pressed` answers *was it pressed*, not *how many times*. Several presses
can arrive in one frame and collapse to a single `true`, so two taps of `j`
move one row. This bites immediately under synthetic input, because a driver
script sends keys far faster than a human does. Where one press must equal one
step -- navigation, a nudge, stepping a value -- use **`key_count`** and act
that many times.

There is no `xdg_popup`, so **menus are drawn inside the window** as absolutely
positioned overlays with a `z-` class. That is a real constraint, not a bug to
work around with a second window.

## Images

palmy decodes images through stb_image — PNG, JPEG, BMP, GIF, TGA, PSD, PNM,
HDR. Pixels are straight 0xAARRGGBB and composite like anything else.

```odin
img, ok := p.load_image("/path/photo.jpg")   // decode
defer p.image_destroy(&img)

p.image(ui, img, "w-full h-full", .Contain)  // .Contain .Cover .Fill .None
p.image(ui, img, "w-full h-full", .None, zoom)   // zoom magnifies around centre

w, h, ch, ok := p.image_size(path)   // dimensions without decoding pixels
p.is_image_path(path)                // cheap extension check
p.write_png_rgba(path, rgba, w, h)   // save
```

Sampling is bilinear, switching to nearest past 2x magnification so a zoomed
photo shows real pixels rather than mush. `draw_image` is available directly
inside `p.pixels` if you need to composite frames yourself — which is how a
video player should blit decoded frames.

## Text editing

Beyond `p.text_field`, which is a single-line widget, palmy gives you the two
measurements a real text editor needs:

```odin
// Where does a click land in this string?
i := p.text_index_at(&app.fonts, line, size, click_x)

// Where does the caret at index i sit?
x := p.text_width_upto(&app.fonts, line, i, size)
```

Both are rune-safe and round-trip against each other. `p.text_field` also takes
a mask rune for password entry. If you need styled runs, selection across
lines, or undo, own that model in your app — palmy deliberately does not.

## Recording a demo

Write a plain-text script and hand it to the recorder:

```
# demo.txt
wait 0.6
type doc
wait 0.8
key Down
key Return
```

```sh
bash /home/alex/Work/palmy/apps/tools/headless-record.sh \
  apps/<name>/<name>.bin apps/<name>/demo.mp4 apps/<name>/demo.txt [w] [h]
```

Steps: `key <X11name>`, `chord <mods>+<key>`, `type <text>`, `move <x> <y>`,
`click [button]`, `wait <seconds>`.

**This records on a private headless compositor, not on the user's desktop.**
It starts its own `sway` with its own Wayland socket, its own virtual output at
the size you ask for, and its own seat. That matters more than it sounds:

- Nothing appears on the user's screen, so a recording can never interrupt
  them.
- There is one window on that seat, so `wtype` cannot type into somebody
  else's app and no focus can be stolen mid-take.
- **No lock, and no queue.** Several of these run at once, which is the point.
- The window is exactly the size you asked for rather than a tiling slot.

The older `record-app.sh` drives the user's live compositor and is kept only
for the rare case that needs the real session. Everything it went wrong at —
capturing another agent's window, keystrokes landing elsewhere, crash toasts in
frame, and a shared lock that one orphaned process could hold for half an hour
— came from sharing one seat, and none of it survives here.

**Pointer steps do not work on this seat, and demos must be keyboard-driven.**
The compositor runs with no input devices, so the seat never gains a pointer
capability and no client is ever sent motion or button. `swaymsg seat cursor`
reports success anyway — it moves sway's own cursor — which is why this looked
like it worked for a long time. `wlrctl` speaks the right protocol but its move
is relative and a click still reaches nobody. Verified by clicking a calculator
keypad and watching nothing happen. The recorder warns once if a steps file
uses `move` or `click`.

Every application here is keyboard-usable, which is what makes that acceptable.

Always verify a take by extracting frames with
`ffmpeg -ss <t> -i out.mp4 -frames:v 1 frame.png` and looking at them.

**The whole take is driven through one `wtype` process.** Running it per step
cycles the seat's keyboard capability for every keystroke, and a client's
re-bind is asynchronous — it asks for a keyboard and the keymap and focus
arrive afterwards, so a key pressed in that window is gone. Two agents measured
the loss independently at roughly **one key in five**, which is worse than it
sounds: a dropped key does not merely omit a step, it redirects the ones after
it, and one take left a mail demo deleting the wrong conversation. Batched,
three consecutive nine-step runs landed 27 of 27.

`wait` becomes wtype's own `-s`, so waits happen inside that single process.
A step's text may not begin with `-`; the recorder refuses rather than typing a
flag into your application.

Each invocation is also led by a shift press and release. The first event of an
invocation is the one exposed to the re-bind window, and a bare `key` step that
loses it loses the **whole step** — where a `type` step only loses its first
character. A modifier pressed and released produces nothing whether it arrives
or not, so it is the right thing to sacrifice. With it, three runs of six bare
`key` steps landed six of six each time.

A private compositor is also the way to drive an app interactively without a
recording — start one, point `WAYLAND_DISPLAY` at it, and use `grim` for
stills.

## Rules

- Own only your `apps/<name>/` directory. Do not edit `palmy/`, `shadcn/`,
  `apps/kit/`, `parity/` or another app.
- If palmy or shadcn is missing something you need, work around it in your app
  and **report the gap** — do not patch the toolkit.
- Build to your own `-out` path.
- The package is not shared between apps, so you cannot break another agent's
  build. Take your time and get it right.

## Safety when the app touches the system

`network/` and `bluetooth/` drive the real machine. Build the full
functionality, but **when recording a demo do not disrupt the user's live
connection**: do not disconnect the active wifi, do not forget a saved network,
do not unpair an existing device. Demonstrate scanning, listing, inspecting
details, and at most toggling something you immediately restore. Say in your
report exactly which operations your demo performed.
