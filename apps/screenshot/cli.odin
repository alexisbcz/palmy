package main

// The command-line front end of the screenshot tool: `palm capture`.
//
// The window captures the live session — that is what a person opens a
// screenshot tool for, and they are there to see it happen. A command is not
// that. An agent asking for a screenshot of the session would be reading the
// user's screen, and one asking twice a second would be watching it. So:
//
//   screenshot   captures on a *private* headless compositor that this
//                command starts, optionally with an application launched into
//                it, and stops again. Its runtime directory is a fresh one,
//                so grim cannot even see the session's sockets, let alone
//                connect to one. This is what `apps/tools/headless-record.sh`
//                does for video; `record` hands over to that script.
//
//   screen       is intent class. It prints the grim command the window would
//                run for that capture — built by the same `capture_words` the
//                window's jobs use — and runs nothing.
//
//   outputs, tools   read what is available, and change nothing.
//
// No verb here takes a camera or a microphone, and `record` never asks
// wf-recorder for audio.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "screenshot",
		summary = "capture a PNG on a private headless compositor, never the session's screen",
		effect = .Mutate,
		args = {{name = "path", kind = .Path, help = "the PNG to write", required = true}},
		flags = {
			{name = "app", kind = .Path, help = "a program to launch into the private compositor first"},
			{name = "width", kind = .Int, help = "the private output's width", def = "1280"},
			{name = "height", kind = .Int, help = "the private output's height", def = "800"},
			{name = "wait", kind = .Float, help = "seconds to let it settle before the capture", def = "1"},
		},
		out = SCREENSHOT_FIELDS,
		examples = {
			"screenshot screenshot /tmp/capture.png --json",
			"screenshot screenshot /tmp/calc.png --app apps/calc/calc.bin --width 800 --height 600",
		},
		run = cmd_screenshot,
	},
	{
		verb = "record",
		summary = "record an application on a private headless compositor (headless-record.sh)",
		effect = .Mutate,
		args = {
			{name = "app", kind = .Path, help = "the program to record", required = true},
			{name = "out", kind = .Path, help = "the .mp4 to write", required = true},
			{name = "steps", kind = .Path, help = "the keys to drive it with (see headless-record.sh)", required = true},
		},
		flags = {
			{name = "width", kind = .Int, def = "1280", help = "the private output's width"},
			{name = "height", kind = .Int, def = "800", help = "the private output's height"},
		},
		out = {{name = "path", kind = .String, help = "the file written"}, {name = "bytes", kind = .Int}},
		examples = {"screenshot record apps/calc/calc.bin /tmp/calc.mp4 apps/calc/demo.txt"},
		run = cmd_record,
	},
	{
		verb = "screen",
		summary = "log the grim command that would capture the live session, and run nothing",
		effect = .Intent,
		args = {{name = "path", kind = .Path, help = "where the capture would go; ~/Pictures by default"}},
		flags = {
			{name = "output", kind = .String, help = "one output, by name"},
			{name = "region", kind = .String, help = "a rectangle, as slurp prints it: \"x,y wxh\""},
		},
		out = INTENT_FIELDS,
		examples = {"screenshot screen --json", "screenshot screen --output HDMI-A-2", "screenshot screen /tmp/r.png --region \"10,20 300x200\" --json"},
		run = cmd_screen,
	},
	{
		verb = "outputs",
		summary = "the session's outputs as the compositor reports them (hyprctl), read only",
		effect = .Read,
		out = OUTPUTS_FIELDS,
		examples = {"screenshot outputs --json"},
		run = cmd_outputs,
	},
	{
		verb = "tools",
		summary = "which capture tools are installed",
		effect = .Read,
		out = TOOLS_FIELDS,
		examples = {"screenshot tools --json"},
		run = cmd_tools,
	},
	{
		verb = "shot",
		summary = "render this tool's own window offscreen to a PNG",
		effect = .Mutate,
		aliases = {"--shot"},
		args = {
			{name = "path", kind = .Path, help = "the PNG to write", required = true},
			{name = "keys", kind = .String, help = "keys to press first", variadic = true},
		},
		out = {{name = "path", kind = .String, help = "the file written"}},
		examples = {"screenshot shot /tmp/screenshot-tool.png", "screenshot shot /tmp/screenshot-help.png ?"},
		run = cmd_shot,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "capture",
			summary  = "screenshots and recordings on a private headless compositor; the live screen is intent only",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `screenshot and record start a private headless compositor of their own, with a
private runtime directory, and capture that: nothing appears on the user's
screen and nothing on it is read. Capturing the live session is the window's
job; from here, screen prints the grim command it would run and runs nothing.`

// ---------------------------------------------------------------------------
// Declared output
// ---------------------------------------------------------------------------

SCREENSHOT_FIELDS := []kit.Field {
	{name = "path", kind = .String, help = "the file written"},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "bytes", kind = .Int},
	{name = "display", kind = .String, help = "the private compositor's Wayland display"},
	{name = "private", kind = .Bool, help = "always true: the session's display was never used"},
}

OUTPUTS_FIELDS := []kit.Field {
	{
		name = "outputs",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "description", kind = .String},
			{name = "width", kind = .Int},
			{name = "height", kind = .Int},
			{name = "x", kind = .Int},
			{name = "y", kind = .Int},
			{name = "scale", kind = .Float},
			{name = "focused", kind = .Bool},
		},
	},
}

TOOLS_FIELDS := []kit.Field {
	{name = "grim", kind = .Bool},
	{name = "slurp", kind = .Bool},
	{name = "wl_copy", kind = .Bool},
	{name = "sway", kind = .Bool, help = "needed for the private compositor"},
	{name = "wf_recorder", kind = .Bool, help = "needed by record"},
	{name = "hyprctl", kind = .Bool},
}

INTENT_FIELDS := []kit.Field {
	{name = "intent", kind = .String, help = "the command that was NOT run"},
	{name = "label", kind = .String},
	{name = "executed", kind = .Bool, help = "always false"},
	{name = "effect", kind = .String, help = "always \"intent\""},
}

// ---------------------------------------------------------------------------
// The private compositor
// ---------------------------------------------------------------------------

// PRIVATE_CAPTURE starts sway headless with a runtime directory of its own,
// launches the application (if one was named) into it, waits, and runs grim
// against it. Arguments: out, app ("" for none), width, height, wait.
//
// The isolation is the runtime directory, not a promise: Wayland clients find
// their compositor's socket in $XDG_RUNTIME_DIR, and this one is a fresh
// mktemp directory, so neither the application nor grim can reach the
// session's compositor even by mistake. The script also checks the display
// sway reported really is a socket inside it before anything connects.
//
// Exit 6 means a tool is missing (unavailable); anything else non-zero is a
// failure. On success the last line of stdout is the private display.
PRIVATE_CAPTURE :: `set -u
OUT="$1"; APP="$2"; W="$3"; H="$4"; WAIT="$5"
command -v sway >/dev/null 2>&1 || { echo "sway is not installed" >&2; exit 6; }
command -v grim >/dev/null 2>&1 || { echo "grim is not installed" >&2; exit 6; }
RT="$(mktemp -d /tmp/palmy-capture-XXXXXX)" || exit 7
chmod 700 "$RT"
SWAY=""; APPPID=""
cleanup() {
  [ -n "$APPPID" ] && kill "$APPPID" 2>/dev/null
  if [ -n "$SWAY" ]; then
    kill "$SWAY" 2>/dev/null
    i=0; while kill -0 "$SWAY" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
    kill -9 "$SWAY" 2>/dev/null
  fi
  rm -rf "$RT"
}
trap cleanup EXIT
printf 'output HEADLESS-1 resolution %sx%s\ndefault_border none\nexec printf %%s "$WAYLAND_DISPLAY" > %s/display\n' "$W" "$H" "$RT" > "$RT/sway.conf"
env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK XDG_RUNTIME_DIR="$RT" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
  sway -c "$RT/sway.conf" > "$RT/sway.log" 2>&1 &
SWAY=$!
WD=""; i=0
while [ $i -lt 100 ]; do sleep 0.1; WD="$(cat "$RT/display" 2>/dev/null)"; [ -n "$WD" ] && break; i=$((i+1)); done
[ -n "$WD" ] || { echo "the private compositor never reported a display" >&2; tail -3 "$RT/sway.log" >&2; exit 7; }
[ -S "$RT/$WD" ] || { echo "the display $WD is not a socket in the private runtime directory" >&2; exit 7; }
export XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$WD"
unset DISPLAY
export SWAYSOCK="$RT/sway-ipc.$(id -u).$SWAY.sock"
if [ -n "$APP" ]; then
  "$APP" > "$RT/app.log" 2>&1 &
  APPPID=$!
  i=0
  while [ $i -lt 100 ]; do
    sleep 0.1
    kill -0 "$APPPID" 2>/dev/null || { echo "the application exited before mapping a window:" >&2; head -3 "$RT/app.log" >&2; exit 7; }
    swaymsg -t get_tree 2>/dev/null | grep -q '"app_id"' && break
    i=$((i+1))
  done
  swaymsg '[app_id=".*"] fullscreen enable' >/dev/null 2>&1
fi
sleep "$WAIT"
grim "$OUT" || exit 7
echo "$WD"
`

@(private = "file")
cmd_screenshot :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	app := kit.cli_str(c, "app")
	w := clamp(kit.cli_int(c, "width", 1280), 64, 7680)
	h := clamp(kit.cli_int(c, "height", 800), 64, 4320)
	wait := clamp(kit.cli_f64(c, "wait", 1), 0, 60)
	kit.jset_str(c.out, "path", path)
	if app != "" && !os.exists(app) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no program at %s", app)
	}
	if c.dry_run {
		kit.jset_int(c.out, "width", w)
		kit.jset_int(c.out, "height", h)
		kit.jset_int(c.out, "bytes", 0)
		kit.jset_str(c.out, "display", "")
		kit.jset_bool(c.out, "private", true)
		return kit.EXIT_OK
	}
	argv := []string {
		"sh",
		"-c",
		PRIVATE_CAPTURE,
		"capture",
		path,
		app,
		fmt.tprintf("%d", w),
		fmt.tprintf("%d", h),
		fmt.tprintf("%.2f", wait),
	}
	if why := kit.cli_guard_check(argv); why != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, why)
	}
	state, sout, serr, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil {
		return kit.cli_fail(c, kit.EXIT_FAILED, "could not start sh")
	}
	detail := strings.trim_space(string(serr))
	switch state.exit_code {
	case 0:
	case 6:
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, detail)
	case:
		return kit.cli_fail(c, kit.EXIT_FAILED, detail == "" ? "the private capture failed" : detail)
	}
	lines := strings.split_lines(strings.trim_space(string(sout)), context.temp_allocator)
	display := len(lines) > 0 ? lines[len(lines) - 1] : ""
	iw, ih, _, ok := p.image_size(path)
	if !ok || file_bytes(path) == 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "grim wrote nothing readable to %s", path)
	}
	kit.jset_int(c.out, "width", iw)
	kit.jset_int(c.out, "height", ih)
	kit.jset_i64(c.out, "bytes", file_bytes(path))
	kit.jset_str(c.out, "display", display)
	kit.jset_bool(c.out, "private", true)
	return kit.EXIT_OK
}

// record_script finds apps/tools/headless-record.sh beside this binary or in
// the working tree.
record_script :: proc() -> (path: string, ok: bool) {
	self, err := os.get_executable_path(context.temp_allocator)
	dir := err == nil ? self : os.args[0]
	if i := strings.last_index_byte(dir, '/'); i > 0 {
		dir = dir[:i]
	}
	for cand in ([?]string {
		fmt.tprintf("%s/../tools/headless-record.sh", dir),
		fmt.tprintf("%s/headless-record.sh", dir),
		"apps/tools/headless-record.sh",
	}) {
		if os.exists(cand) {
			return cand, true
		}
	}
	return "", false
}

@(private = "file")
cmd_record :: proc(c: ^kit.Call) -> int {
	app := kit.cli_str(c, "app")
	out := kit.cli_str(c, "out")
	steps := kit.cli_str(c, "steps")
	kit.jset_str(c.out, "path", out)
	for f in ([?]string{app, steps}) {
		if !os.exists(f) {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no file at %s", f)
		}
	}
	script, found := record_script()
	if !found {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "apps/tools/headless-record.sh was not found beside this binary")
	}
	for tool in ([?]string{"sway", "wf-recorder", "wtype"}) {
		if !kit.has_tool(tool) {
			return kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "%s is not installed", tool)
		}
	}
	if c.dry_run {
		kit.jset_int(c.out, "bytes", 0)
		return kit.EXIT_OK
	}
	argv := []string {
		"bash",
		script,
		app,
		out,
		steps,
		fmt.tprintf("%d", kit.cli_int(c, "width", 1280)),
		fmt.tprintf("%d", kit.cli_int(c, "height", 800)),
	}
	state, _, serr, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil || state.exit_code != 0 || file_bytes(out) == 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "headless-record.sh failed: %s", strings.trim_space(string(serr)))
	}
	kit.jset_i64(c.out, "bytes", file_bytes(out))
	return kit.EXIT_OK
}

@(private = "file")
cmd_screen :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	if path == "" {
		path = fmt.tprintf("%s/%s", pictures_dir(), stamp("screenshot"))
	}
	output := kit.cli_str(c, "output")
	region_text := kit.cli_str(c, "region")
	if output != "" && region_text != "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "one of --output or --region, not both")
	}
	words: []string
	label: string
	switch {
	case region_text != "":
		r, ok := parse_geom(region_text)
		if !ok {
			return kit.cli_failf(c, kit.EXIT_USAGE, "%q is not a rectangle: \"x,y wxh\"", region_text)
		}
		words = capture_words(.Region, "", r, path)
		label = "capture a region of the live session"
	case output != "":
		words = capture_words(.Output, output, {}, path)
		label = fmt.tprintf("capture the live output %s", output)
	case:
		words = capture_words(.Screen, "", {}, path)
		label = "capture every output of the live session"
	}
	log_cmd(fmt.tprintf("INTENT ONLY, not executed: %s", strings.join(words, " ", context.temp_allocator)), true)
	return kit.cli_intent(c, strings.join(words, " ", context.temp_allocator), label, quiet = true)
}

@(private = "file")
cmd_outputs :: proc(c: ^kit.Call) -> int {
	if !kit.has_tool("hyprctl") {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "hyprctl is not installed; no compositor to ask")
	}
	text, ok := kit.run({"hyprctl", "monitors", "-j"}, context.temp_allocator)
	if !ok || text == "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "the compositor did not answer")
	}
	arr := kit.jarr()
	for o in parse_outputs(text) {
		obj := kit.jobj()
		kit.jset_str(obj, "name", o.name)
		kit.jset_str(obj, "description", o.desc)
		kit.jset_int(obj, "width", o.w)
		kit.jset_int(obj, "height", o.h)
		kit.jset_int(obj, "x", o.x)
		kit.jset_int(obj, "y", o.y)
		kit.jset_num(obj, "scale", f64(o.scale))
		kit.jset_bool(obj, "focused", o.focused)
		kit.jpush(arr, obj)
	}
	kit.jset(c.out, "outputs", arr)
	return kit.EXIT_OK
}

@(private = "file")
cmd_tools :: proc(c: ^kit.Call) -> int {
	kit.jset_bool(c.out, "grim", have("grim"))
	kit.jset_bool(c.out, "slurp", have("slurp"))
	kit.jset_bool(c.out, "wl_copy", have("wl-copy"))
	kit.jset_bool(c.out, "sway", have("sway"))
	kit.jset_bool(c.out, "wf_recorder", have("wf-recorder"))
	kit.jset_bool(c.out, "hyprctl", have("hyprctl"))
	return kit.EXIT_OK
}

// SHOT_REFUSED_KEYS are the window's keys that run something: Space and
// Return capture the live session, A repeats a region capture, S saves into
// ~/Pictures, C hands the capture to wl-copy, X discards one. A rendering of
// the window is not a way to reach any of them.
SHOT_REFUSED_KEYS :: " \r\nascx"

@(private = "file")
cmd_shot :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "path")
	kit.jset_str(c.out, "path", path)
	keys_wanted := make([dynamic]u32, context.allocator)
	for extra in kit.cli_rest(c) {
		if len(extra) == 0 {
			continue
		}
		ch := extra[0]
		if ch >= 'A' && ch <= 'Z' {
			ch += 32
		}
		if strings.index_byte(SHOT_REFUSED_KEYS, ch) >= 0 {
			return kit.cli_failf(c, kit.EXIT_USAGE, "the key %q runs a capture or a copy in the window, so a shot will not press it", extra[:1])
		}
		append(&keys_wanted, u32(extra[0]))
	}
	if c.dry_run {
		return kit.EXIT_OK
	}
	os.remove(path)
	shot(path, keys_wanted[:])
	if !os.exists(path) {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not write %s", path)
	}
	return kit.EXIT_OK
}

cli_selftest :: proc() -> int {
	selftest() // exits 1 itself when anything failed
	return 0
}
