package main

// `mixer --selftest` — headless, no compositor, no window, and no wpctl.
//
// Nothing in here touches the machine's audio. Every reader is driven from
// canned `pactl -f json` documents, the volume arithmetic is checked on its
// own, and the one section that drives the real interface presses only keys
// that cannot write: Down, Up, Home, End, C and ?. The keys that do write —
// Left, Right, M, D, L, U — are deliberately never pressed here, because a
// self-test that changes somebody's volume is not a self-test.

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

@(private = "file")
checks := 0
@(private = "file")
failures := 0

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	checks += 1
	if !ok {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq_s :: proc(got, want: string, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %q, want %q\n", what, got, want)
	}
}

@(private = "file")
eq_i :: proc(got, want: int, what: string) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %d, want %d\n", what, got, want)
	}
}

@(private = "file")
near :: proc(a, b: f32, what: string, tol: f32 = 1e-5) {
	checks += 1
	if math.abs(a - b) > tol {
		failures += 1
		fmt.printf("  FAIL  %s: got %.6f, want %.6f\n", what, a, b)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("mixer self-test")

	test_sinks()
	test_sources()
	test_streams()
	test_malformed()
	test_volume_math()
	test_volume_readback()
	test_labels()
	test_level()
	test_navigation()
	test_interface()

	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// Fixtures
//
// Shaped exactly like this machine's `pactl -f json list sinks`, cut down to
// the fields this applet reads.
// ---------------------------------------------------------------------------

@(private = "file")
SINKS :: `[
  {
    "index": 51,
    "state": "RUNNING",
    "name": "alsa_output.pci-0000_c1_00.6.analog-stereo",
    "description": "Family 17h HD Audio Controller Analog Stereo",
    "mute": false,
    "volume": {
      "front-left":  { "value": 32768, "value_percent": "50%", "db": "-18.06dB" },
      "front-right": { "value": 32768, "value_percent": "50%", "db": "-18.06dB" }
    },
    "sample_specification": "s16le 2ch 48000Hz",
    "active_port": "analog-output-headphones",
    "ports": [
      { "name": "analog-output-lineout",    "description": "Line Out" },
      { "name": "analog-output-headphones", "description": "Headphones" }
    ],
    "properties": {
      "object.id": "51",
      "device.bus": "pci",
      "device.form_factor": "internal"
    }
  },
  {
    "index": 62,
    "state": "SUSPENDED",
    "name": "bluez_output.AC_80_0A_51_2B_33.1",
    "description": "CMF Headphone Pro",
    "mute": true,
    "volume": {
      "mono": { "value": 65536, "value_percent": "100%", "db": "0.00dB" }
    },
    "sample_specification": "s16le 1ch 48000Hz",
    "active_port": "headset-output",
    "ports": [ { "name": "headset-output", "description": "" } ],
    "properties": {
      "object.id": "62",
      "device.bus": "bluetooth",
      "device.form_factor": "headset",
      "api.bluez5.codec": "aac"
    }
  },
  {
    "index": 70,
    "state": "IDLE",
    "name": "alsa_output.usb-Generic.analog-stereo",
    "description": "USB Audio",
    "mute": false,
    "volume": {
      "front-left":  { "value": 0, "value_percent": "0%" },
      "front-right": { "value": 65536, "value_percent": "100%" }
    },
    "active_port": "analog-output",
    "properties": { "object.id": "70", "device.bus": "usb" }
  }
]`

@(private = "file")
SOURCES :: `[
  {
    "index": 44,
    "state": "SUSPENDED",
    "name": "alsa_input.pci-0000_c1_00.6.analog-stereo",
    "description": "Built-in Microphone",
    "mute": false,
    "volume": { "front-left": { "value": 45875 }, "front-right": { "value": 45875 } },
    "properties": { "object.id": "44", "device.bus": "pci", "device.class": "sound" }
  },
  {
    "index": 52,
    "name": "alsa_output.pci-0000_c1_00.6.analog-stereo.monitor",
    "description": "Monitor of Analog Stereo",
    "mute": false,
    "volume": { "mono": { "value": 65536 } },
    "properties": { "object.id": "52", "device.class": "monitor" }
  }
]`

@(private = "file")
STREAMS :: `[
  {
    "index": 311,
    "mute": false,
    "corked": false,
    "volume": { "front-left": { "value": 65536 }, "front-right": { "value": 49152 } },
    "properties": {
      "object.id": "311",
      "application.name": "Firefox",
      "application.process.binary": "firefox",
      "media.name": "AudioStream"
    }
  },
  {
    "index": 318,
    "mute": true,
    "corked": true,
    "volume": { "mono": { "value": 16384 } },
    "properties": {
      "object.id": "318",
      "application.process.binary": "mpv",
      "media.name": "video.mkv"
    }
  },
  {
    "index": 320,
    "mute": false,
    "volume": { "mono": { "value": 65536 } },
    "properties": { "object.id": "320" }
  }
]`

@(private = "file")
arenas :: proc() -> (al, sl: virtual.Arena) {
	virtual.arena_init_growing(&al) or_else panic("arena")
	virtual.arena_init_growing(&sl) or_else panic("scratch")
	return
}

// ---------------------------------------------------------------------------
// Sinks
// ---------------------------------------------------------------------------

test_sinks :: proc() {
	section("pactl -f json list sinks")

	a, s := arenas()
	defer virtual.arena_destroy(&a)
	defer virtual.arena_destroy(&s)
	al, sl := virtual.arena_allocator(&a), virtual.arena_allocator(&s)

	devs := make([dynamic]Dev, 0, 8, al)
	n, ok := parse_devs(
		&devs,
		SINKS,
		false,
		"bluez_output.AC_80_0A_51_2B_33.1",
		al,
		sl,
	)
	check(ok, "the sink document parsed")
	eq_i(n, 3, "three sinks")
	if n != 3 {
		return
	}

	// --- the analog sink -------------------------------------------------
	d := devs[0]
	eq_i(d.index, 51, "pactl's own index")
	eq_i(d.node, 51, "the PipeWire node id, out of properties[object.id]")
	eq_s(d.desc, "Family 17h HD Audio Controller Analog Stereo", "its description")
	check(!d.mute, "it is not muted")
	// 32768 / 65536 = exactly half.
	near(d.vol, 0.5, "two channels at 32768 average to 0.5")
	eq_i(d.chans, 2, "two channels")
	eq_s(d.state, "RUNNING", "its state")
	// The active port's *description*, not its name: "Headphones", not
	// "analog-output-headphones". That is the whole reason port_label exists.
	eq_s(d.port, "Headphones", "the active port's description")
	eq_s(d.bus, "pci", "its bus")
	eq_s(d.spec, "s16le 2ch 48000Hz", "its sample specification")
	check(!d.default, "it is not the default")
	check(!d.input, "it is an output")

	// --- the Bluetooth sink ----------------------------------------------
	b := devs[1]
	eq_i(b.node, 62, "the headset's node id")
	check(b.mute, "it is muted")
	near(b.vol, 1.0, "65536 is 100%")
	eq_i(b.chans, 1, "one channel")
	eq_s(b.bus, "bluetooth", "its bus")
	eq_s(b.codec, "aac", "its codec")
	check(b.default, "it is the default, matched on node name")
	// Its port has an empty description, so the port *name* is the fallback
	// rather than a blank line in the interface.
	eq_s(b.port, "headset-output", "a port with no description falls back to its name")

	// --- the USB sink: unbalanced channels --------------------------------
	u := devs[2]
	near(u.vol, 0.5, "0 and 65536 average to 0.5")
	eq_s(u.bus, "usb", "its bus")
	eq_s(u.codec, "", "no codec on a USB device")
	// No "ports" array at all, so active_port is used verbatim.
	eq_s(u.port, "analog-output", "no ports array means the active port's name")
	eq_s(u.spec, "", "a missing sample specification is empty, not garbage")
}

test_sources :: proc() {
	section("pactl -f json list sources")

	a, s := arenas()
	defer virtual.arena_destroy(&a)
	defer virtual.arena_destroy(&s)
	al, sl := virtual.arena_allocator(&a), virtual.arena_allocator(&s)

	ins := make([dynamic]Dev, 0, 8, al)
	n, ok := parse_devs(&ins, SOURCES, true, "", al, sl)
	check(ok, "the source document parsed")
	// The monitor source is the loopback of an output, not a microphone.
	// Listing them is how a mixer ends up showing eight inputs on a machine
	// with one.
	eq_i(n, 1, "the monitor source was dropped")
	if n == 1 {
		eq_s(ins[0].desc, "Built-in Microphone", "the real input survived")
		check(ins[0].input, "and is marked as an input")
		near(ins[0].vol, 45875.0 / 65536.0, "its volume")
		check(!ins[0].default, "with no default source set, nothing is default")
	}

	// The same document read as outputs: monitors are only filtered on the
	// input side, so all three come back.
	outs := make([dynamic]Dev, 0, 8, al)
	n2, _ := parse_devs(&outs, SOURCES, false, "", al, sl)
	eq_i(n2, 2, "read as outputs, the monitor is not filtered")
}

test_streams :: proc() {
	section("pactl -f json list sink-inputs")

	a, s := arenas()
	defer virtual.arena_destroy(&a)
	defer virtual.arena_destroy(&s)
	al, sl := virtual.arena_allocator(&a), virtual.arena_allocator(&s)

	st := make([dynamic]Stream, 0, 8, al)
	parse_streams(&st, STREAMS, false, al, sl)
	eq_i(len(st), 3, "three streams")
	if len(st) != 3 {
		return
	}

	eq_s(st[0].app, "Firefox", "application.name wins when it is there")
	eq_s(st[0].binary, "firefox", "and the binary is kept separately")
	eq_s(st[0].media, "AudioStream", "the media name")
	check(!st[0].corked, "it is playing")
	check(!st[0].record, "and it is a playback stream")
	near(st[0].vol, (1.0 + 0.75) / 2, "its two channels average")

	// No application.name: the binary stands in for it.
	eq_s(st[1].app, "mpv", "a stream with no application.name falls back to its binary")
	check(st[1].corked, "it is corked")
	check(st[1].mute, "and muted")

	// Neither: "Unknown" rather than a blank row.
	eq_s(st[2].app, "Unknown", "a stream with no name at all is Unknown")

	// Read as source-outputs, the same document marks every stream as a
	// recorder, which is what puts the "listening" badge on a row.
	rec := make([dynamic]Stream, 0, 8, al)
	parse_streams(&rec, STREAMS, true, al, sl)
	eq_i(len(rec), 3, "three source-outputs")
	if len(rec) == 3 {
		check(rec[0].record, "a source-output is a recorder")
	}
}

// ---------------------------------------------------------------------------
// Input that is not what pactl promises
// ---------------------------------------------------------------------------

test_malformed :: proc() {
	section("malformed and truncated pactl output")

	a, s := arenas()
	defer virtual.arena_destroy(&a)
	defer virtual.arena_destroy(&s)
	al, sl := virtual.arena_allocator(&a), virtual.arena_allocator(&s)

	cases := [?]struct {
		text: string,
		what: string,
	} {
		{"", "an empty document"},
		{"[", "a document truncated after the opening bracket"},
		{"[{\"index\": 1,", "a document truncated mid-object"},
		{"not json at all", "plain prose"},
		{"{\"index\": 1}", "an object where an array was promised"},
		{"null", "a bare null"},
		{"[[1,2],[3]]", "an array of arrays"},
	}
	for c in cases {
		devs := make([dynamic]Dev, 0, 4, al)
		n, ok := parse_devs(&devs, c.text, false, "", al, sl)
		check(!ok || n == 0, "%s yields nothing", c.what)
		// Whatever happens, it must not crash and must not invent devices.
		eq_i(len(devs), 0, fmt.tprintf("%s adds no devices", c.what))

		st := make([dynamic]Stream, 0, 4, al)
		parse_streams(&st, c.text, false, al, sl)
		eq_i(len(st), 0, fmt.tprintf("%s adds no streams", c.what))
	}

	// An empty array is valid and means exactly what it says.
	devs := make([dynamic]Dev, 0, 4, al)
	n, ok := parse_devs(&devs, "[]", false, "", al, sl)
	check(ok, "an empty array is a successful read")
	eq_i(n, 0, "of no devices")

	// A device with none of the fields this applet wants. Everything reads as
	// absent rather than as a wrong value.
	bare := make([dynamic]Dev, 0, 4, al)
	n2, ok2 := parse_devs(&bare, "[{}]", false, "", al, sl)
	check(ok2 && n2 == 1, "a device object with no fields is still a device")
	if n2 == 1 {
		eq_i(bare[0].node, -1, "an absent object.id is -1, not 0 — 0 is a real node")
		eq_i(bare[0].chans, 0, "no channels")
		near(bare[0].vol, 0, "no volume")
		eq_s(bare[0].name, "", "no name")
		// And with no name, it must not accidentally match an empty default.
		check(bare[0].default, "an empty name does match an empty default name")
	}

	// Volume values of the wrong type must not be read as numbers.
	odd := make([dynamic]Dev, 0, 4, al)
	parse_devs(&odd, `[{"volume": {"mono": {"value": "loud"}}}]`, false, "x", al, sl)
	if len(odd) == 1 {
		near(odd[0].vol, 0, "a non-numeric channel value reads as zero")
		eq_i(odd[0].chans, 1, "but the channel is still counted")
	}
}

// ---------------------------------------------------------------------------
// Volume arithmetic
// ---------------------------------------------------------------------------

test_volume_math :: proc() {
	section("volume arithmetic and the ceiling")

	near(vol_clamp(0), 0, "zero")
	near(vol_clamp(0.5), 0.5, "a half")
	near(vol_clamp(1), 1, "the ceiling itself")
	near(vol_clamp(-0.0001), 0, "just below zero")
	near(vol_clamp(-5), 0, "well below zero")
	// PipeWire will happily amplify past 1.0. This applet will not.
	near(vol_clamp(1.0001), 1, "just above the ceiling")
	near(vol_clamp(1.5), 1, "150% is clamped to 100%")
	near(vol_clamp(1e9), 1, "an absurd value is clamped")
	near(vol_clamp(math.nan_f32()), 0, "NaN clamps to silence rather than passing through")
	check(VOL_CEILING == 1.0, "the ceiling is 1.0, got %v", VOL_CEILING)

	// The five percent step the arrow keys use, and the one percent fine step.
	near(nudge_target(0.5, 0.05), 0.55, "up a step", 1e-6)
	near(nudge_target(0.5, -0.05), 0.45, "down a step", 1e-6)
	near(nudge_target(0.5, 0.01), 0.51, "up a fine step", 1e-6)
	near(nudge_target(0.98, 0.05), 1.0, "a step that would overshoot lands on the ceiling")
	near(nudge_target(0.02, -0.05), 0.0, "a step that would undershoot lands on silence")
	near(nudge_target(1.0, 0.05), 1.0, "already at the ceiling")
	near(nudge_target(0.0, -0.05), 0.0, "already silent")

	// Twenty steps from silence reach exactly the ceiling and stop there.
	v: f32 = 0
	for _ in 0 ..< 40 {
		v = nudge_target(v, 0.05)
	}
	near(v, 1.0, "forty steps up from silence stop at the ceiling")
	for _ in 0 ..< 40 {
		v = nudge_target(v, -0.05)
	}
	near(v, 0.0, "and forty back down stop at silence")

	// The scale pactl speaks.
	check(VOL_NORM == 65536, "PulseAudio's unit volume is 65536, got %v", VOL_NORM)
}

test_volume_readback :: proc() {
	section("wpctl get-volume")

	v, m, ok := parse_volume_line("Volume: 0.50")
	check(ok, "a plain reading parses")
	near(v, 0.5, "its value")
	check(!m, "and it is not muted")

	v2, m2, ok2 := parse_volume_line("Volume: 0.50 [MUTED]")
	check(ok2, "a muted reading parses")
	near(v2, 0.5, "its value is still there")
	check(m2, "and the mute flag is seen")

	v3, _, ok3 := parse_volume_line("Volume: 1.00\n")
	check(ok3, "a trailing newline is tolerated")
	near(v3, 1.0, "full volume")

	v4, _, ok4 := parse_volume_line("Volume: 0.00")
	check(ok4, "silence parses")
	near(v4, 0, "as zero")

	// wpctl prints more than 1.0 when something else has amplified the node.
	// Reading it back honestly is right; it is *setting* it that is refused.
	v5, _, ok5 := parse_volume_line("Volume: 1.40")
	check(ok5, "an amplified node reads back")
	near(v5, 1.4, "at its real value — read-back is not clamped")

	_, _, bad := parse_volume_line("")
	check(!bad, "an empty answer is not a reading")
	_, _, bad2 := parse_volume_line("Node 51 not found")
	check(!bad2, "an error message is not a reading")
	_, _, bad3 := parse_volume_line("Volume:")
	check(!bad3, "a header with no number is not a reading")
	_, _, bad4 := parse_volume_line("Volume: loud")
	check(!bad4, "a non-numeric volume is not a reading")

	// No colon at all: the whole string is taken as the number, and it is not
	// one.
	_, _, bad5 := parse_volume_line("0.5")
	check(bad5, "a bare number with no header is still a number")
}

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

test_labels :: proc() {
	section("labels")

	eq_s(pct_label(0), "0%", "silence")
	eq_s(pct_label(0.5), "50%", "a half")
	eq_s(pct_label(1), "100%", "full")
	eq_s(pct_label(0.055), "6%", "rounded to the nearest percent")

	eq_s(bus_label(Dev{bus = "pci"}), "Built-in", "pci")
	eq_s(bus_label(Dev{bus = "usb"}), "USB", "usb")
	eq_s(bus_label(Dev{bus = "bluetooth"}), "Bluetooth", "bluetooth with no codec")
	eq_s(
		bus_label(Dev{bus = "bluetooth", codec = "aac"}),
		"Bluetooth · AAC",
		"bluetooth with a codec, upper-cased",
	)
	eq_s(bus_label(Dev{}), "", "no bus at all")
	eq_s(bus_label(Dev{bus = "firewire"}), "firewire", "an unknown bus prints itself")

	eq_s(upper("sbc-xq"), "SBC-XQ", "upper leaves punctuation alone")
	eq_s(upper(""), "", "upper of nothing")
	eq_s(upper("AAC"), "AAC", "upper is idempotent")

	eq_s(state_label("RUNNING"), "playing", "RUNNING")
	eq_s(state_label("IDLE"), "idle", "IDLE")
	eq_s(state_label("SUSPENDED"), "suspended", "SUSPENDED")
	eq_s(state_label(""), "", "no state")
	eq_s(state_label("INIT"), "INIT", "an unknown state prints itself")
}

test_level :: proc() {
	section("the input meter")

	// The meter is off until it is asked for, and it says what it runs.
	l := Level {
		source = "alsa_input.pci-0000_c1_00.6.analog-stereo",
	}
	cmd := level_cmd(&l)
	check(strings.has_prefix(cmd, "parec "), "the meter's command is parec, got %q", cmd)
	check(strings.contains(cmd, l.source), "and names the source it listens to")
	check(strings.contains(cmd, "--format=s16le"), "in the format the reader expects")
	check(strings.contains(cmd, fmt.tprintf("--rate=%d", RATE)), "at the rate the reader expects")
	check(!l.on, "a Level starts off")

	// dB.
	eq_s(db_label(0), "silent", "zero amplitude")
	eq_s(db_label(0.00001), "silent", "below the floor")
	eq_s(db_label(1), "0.0 dB", "full scale")
	eq_s(db_label(0.5), "-6.0 dB", "half amplitude")
	eq_s(db_label(0.1), "-20.0 dB", "a tenth")

	// The history ring reads oldest to newest whether or not it has wrapped.
	h: Level
	eq_i(int(level_hist_at(&h, 0) * 1000), 0, "an empty history reads zero")
	for i in 0 ..< 5 {
		h.hist[h.at] = f32(i + 1) / 10
		h.at = (h.at + 1) % len(h.hist)
		h.n += 1
	}
	near(level_hist_at(&h, 0), 0.1, "the oldest sample first")
	near(level_hist_at(&h, 4), 0.5, "the newest sample last")

	// Wrapped: fill the ring past its length and the window slides.
	w: Level
	for i in 0 ..< len(w.hist) + 7 {
		w.hist[w.at] = f32(i)
		w.at = (w.at + 1) % len(w.hist)
		if w.n < len(w.hist) {
			w.n += 1
		}
	}
	eq_i(w.n, len(w.hist), "the ring is full")
	near(level_hist_at(&w, 0), f32(7), "after wrapping the oldest kept sample is first")
	near(level_hist_at(&w, len(w.hist) - 1), f32(len(w.hist) + 6), "and the newest is last")
}

// ---------------------------------------------------------------------------
// The flat list the keyboard walks
// ---------------------------------------------------------------------------

@(private = "file")
canned_model :: proc(m: ^Model) {
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	virtual.arena_init_growing(&m.scratch) or_else panic("scratch")
	m.al = virtual.arena_allocator(&m.arena)
	m.sl = virtual.arena_allocator(&m.scratch)
	m.at = -1
	m.have_tools = true
	m.loaded = true

	outs := make([dynamic]Dev, 0, 8, m.al)
	ins := make([dynamic]Dev, 0, 8, m.al)
	streams := make([dynamic]Stream, 0, 8, m.al)
	parse_devs(&outs, SINKS, false, "bluez_output.AC_80_0A_51_2B_33.1", m.al, m.sl)
	parse_devs(&ins, SOURCES, true, "alsa_input.pci-0000_c1_00.6.analog-stereo", m.al, m.sl)
	parse_streams(&streams, STREAMS, false, m.al, m.sl)
	m.a = Audio {
		outs        = outs[:],
		ins         = ins[:],
		streams     = streams[:],
		default_out = "bluez_output.AC_80_0A_51_2B_33.1",
		default_in  = "alsa_input.pci-0000_c1_00.6.analog-stereo",
		ok          = true,
	}
	m.orig_name = "CMF Headphone Pro"
	m.orig_node = 62
	m.orig_vol = 1.0
	m.orig_mute = true
	m.orig_default = "bluez_output.AC_80_0A_51_2B_33.1"
	m.orig_ok = true
}

test_navigation :: proc() {
	section("the row list")

	m := new(Model)
	defer free(m)
	canned_model(m)
	defer virtual.arena_destroy(&m.arena)
	defer virtual.arena_destroy(&m.scratch)

	rebuild_items(m)
	// Three sinks, one source (the monitor is filtered), three streams.
	eq_i(len(m.items), 7, "seven rows")
	eq_i(m.at, 0, "the first row is selected when nothing was")
	check(m.items[0].kind == .Out, "outputs come first")
	check(m.items[3].kind == .In, "then inputs")
	check(m.items[4].kind == .Stream, "then streams")

	// Keys are stable identities, not positions.
	eq_s(item_key(m, Item{.Out, 0}), "o:alsa_output.pci-0000_c1_00.6.analog-stereo", "an output's key")
	eq_s(item_key(m, Item{.In, 0}), "i:alsa_input.pci-0000_c1_00.6.analog-stereo", "an input's key")
	eq_s(item_key(m, Item{.Stream, 1}), "s:0:318", "a playback stream's key")

	move_sel(m, 1)
	eq_i(m.at, 1, "Down moves one")
	move_sel(m, 1)
	move_sel(m, 1)
	eq_i(m.at, 3, "and keeps moving")
	k, ok := sel_kind(m)
	check(ok && k == .In, "the fourth row is the input")
	node, vol, mute, label, got := sel_node(m)
	check(got, "the selected row resolves")
	eq_i(node, 44, "to the microphone's node")
	eq_s(label, "Built-in Microphone", "and its description")
	near(vol, 45875.0 / 65536.0, "and its volume")
	check(!mute, "and its mute flag")

	move_sel(m, 1 << 20)
	eq_i(m.at, 6, "End lands on the last row, not past it")
	move_sel(m, -1 << 20)
	eq_i(m.at, 0, "Home lands on the first")
	move_sel(m, -1)
	eq_i(m.at, 0, "and Up at the top stays there")

	// The selection follows the row across a refresh, even when the list has
	// been reordered — that is what the key is for.
	move_sel(m, 2)
	eq_i(m.at, 2, "on the USB sink")
	want := strings.clone(item_key(m, m.items[m.at]), context.temp_allocator)
	// Reverse the outputs behind its back.
	m.a.outs[0], m.a.outs[2] = m.a.outs[2], m.a.outs[0]
	rebuild_items(m)
	eq_i(m.at, 0, "the USB sink moved to the top and the selection went with it")
	eq_s(item_key(m, m.items[m.at]), want, "and it is the same row")

	// A row that has gone away: the selection falls back to the first row
	// rather than pointing at nothing.
	m.a.outs = m.a.outs[1:]
	rebuild_items(m)
	eq_i(len(m.items), 6, "six rows now")
	eq_i(m.at, 0, "the selection fell back to the first row")

	// An empty graph: no rows, no selection, and nothing that indexes past
	// the end.
	m.a.outs, m.a.ins, m.a.streams = nil, nil, nil
	rebuild_items(m)
	eq_i(len(m.items), 0, "no rows")
	eq_i(m.at, -1, "and no selection")
	_, _, _, _, none := sel_node(m)
	check(!none, "sel_node says so rather than indexing past the end")
	_, nk := sel_kind(m)
	check(!nk, "and so does sel_kind")
	move_sel(m, 1)
	eq_i(m.at, -1, "and moving does nothing")
}

// ---------------------------------------------------------------------------
// The real interface, driven headless
//
// Only keys that cannot write. Left, Right, M, D, L and U are never pressed
// here: they would change the machine's audio.
// ---------------------------------------------------------------------------

@(private = "file")
step :: proc(off: ^p.Offscreen, m: ^Model) {
	ui := p.offscreen_begin(off)
	rebuild_items(m)
	keys(ui, nil, m)
	rebuild_items(m)
	build(ui, m)
	p.offscreen_end(off)
}

test_interface :: proc() {
	section("the interface, with no compositor")

	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	canned_model(m)
	defer virtual.arena_destroy(&m.arena)
	defer virtual.arena_destroy(&m.scratch)

	before := g_log_count

	step(off, m)
	step(off, m)
	check(ink(off) > 0.01, "the window drew something (ink %.3f)", ink(off))

	p.press_key(off, p.KEY_DOWN)
	step(off, m)
	eq_i(m.at, 1, "Down moved the selection in the real key handler")
	p.press_key(off, p.KEY_END)
	step(off, m)
	eq_i(m.at, len(m.items) - 1, "End went to the last row")
	p.press_key(off, p.KEY_HOME)
	step(off, m)
	eq_i(m.at, 0, "Home came back")

	p.press_key(off, 'c')
	step(off, m)
	check(m.log_open, "C opened the command log")
	p.press_key(off, p.KEY_DOWN)
	step(off, m)
	eq_i(m.at, 0, "the list does not move while the log is open")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, m)
	check(!m.log_open, "Escape closed it")

	p.press_key(off, '?')
	step(off, m)
	check(m.help_open, "? opened the key list")
	p.press_key(off, p.KEY_ESCAPE)
	step(off, m)
	check(!m.help_open, "Escape closed it")

	// Nothing above ran a command against PipeWire.
	eq_i(g_log_count, before, "driving the interface ran no wpctl commands")

	if shot := os.get_env("MIXER_SELFTEST_PNG", context.temp_allocator); shot != "" {
		p.offscreen_write_png(off, shot)
		fmt.printf("  wrote %s\n", shot)
	}
}

// ---------------------------------------------------------------------------
// `mixer --shot out.png`
// ---------------------------------------------------------------------------

shot :: proc(path: string, keys_to_press: []u32 = nil) {
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_selftest_fonts(&off.fonts)

	m := new(Model)
	defer free(m)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	virtual.arena_init_growing(&m.scratch) or_else panic("scratch")
	m.al = virtual.arena_allocator(&m.arena)
	m.sl = virtual.arena_allocator(&m.scratch)
	m.at = -1
	m.have_tools = kit_has("pactl") && kit_has("wpctl")
	refresh(m)
	capture_original(m)

	step(off, m)
	step(off, m)
	for k in keys_to_press {
		p.press_key(off, k)
		step(off, m)
	}
	step(off, m)
	if p.offscreen_write_png(off, path) {
		fmt.eprintfln("[mixer] wrote %s", path)
	}
}

@(private = "file")
ink :: proc(off: ^p.Offscreen) -> f32 {
	px := p.offscreen_pixels(off)
	if len(px) == 0 {
		return 0
	}
	bg := px[0]
	n := 0
	for v in px {
		if v != bg {
			n += 1
		}
	}
	return f32(n) / f32(len(px))
}

FONT_DIR :: "/home/alex/Work/palmy/parity/web/public/fonts"
MONO_CANDIDATES := [?]string {
	"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
	"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
	"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

load_selftest_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in MONO_CANDIDATES {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}
