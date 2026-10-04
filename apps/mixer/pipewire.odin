package main

// Everything this mixer knows about the audio graph, read from PipeWire's two
// command line front ends.
//
// `pactl -f json` is the one that answers in structured form — this version
// (PipeWire 1.6.8's pulse compatibility layer) supports it, which was checked
// before anything here depended on it. It gives a sink's description, its mute
// flag, its per-channel volume, its active port, and the PipeWire node id in
// `properties["object.id"]`.
//
// That node id is the handle `wpctl` takes, so reads come from `pactl` and
// writes go through `wpctl set-volume` / `set-mute` / `set-default` — the two
// tools are talking about the same objects.
//
// Both answer in about six milliseconds, which is why there is no worker
// thread in this program: a refresh runs inside the frame and nothing waits.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import kit "kit:."

// PulseAudio's volume scale: 65536 is "100%", and wpctl's 0..1 is the same
// number divided by it.
VOL_NORM :: f32(65536)

Dev :: struct {
	index:   int, // pactl's own index
	node:    int, // PipeWire object id — what wpctl takes
	name:    string, // node name, stable across restarts
	desc:    string, // what a person calls it
	mute:    bool,
	vol:     f32, // 0..1, averaged over the channels
	chans:   int,
	state:   string, // RUNNING / IDLE / SUSPENDED
	port:    string, // active port description, e.g. "Headphones"
	bus:     string, // pci / usb / bluetooth
	form:    string, // device.form_factor
	codec:   string, // api.bluez5.codec, when this is a Bluetooth device
	spec:    string, // sample specification
	default: bool,
	input:   bool,
}

Stream :: struct {
	index:   int,
	node:    int,
	app:     string,
	media:   string,
	binary:  string,
	target:  string, // the device it is attached to
	mute:    bool,
	vol:     f32,
	corked:  bool,
	record:  bool, // a source-output: this one is listening, not playing
}

Audio :: struct {
	outs:        []Dev,
	ins:         []Dev,
	streams:     []Stream,
	default_out: string,
	default_in:  string,
	ok:          bool,
	err:         string,
}

// ---------------------------------------------------------------------------
// A thin reader over core:encoding/json
//
// Only a handful of fields out of a very large document are wanted, so the
// document is walked rather than unmarshalled into a mirror of pactl's schema.
// ---------------------------------------------------------------------------

jfield :: proc(v: json.Value, key: string) -> (out: json.Value, ok: bool) {
	o := v.(json.Object) or_return
	out, ok = o[key]
	return
}

jstr :: proc(v: json.Value, key: string) -> string {
	x, ok := jfield(v, key)
	if !ok {
		return ""
	}
	s, is := x.(json.String)
	return is ? string(s) : ""
}

jnum :: proc(v: json.Value, key: string) -> f64 {
	x, ok := jfield(v, key)
	if !ok {
		return 0
	}
	#partial switch n in x {
	case json.Integer:
		return f64(n)
	case json.Float:
		return f64(n)
	}
	return 0
}

jbool :: proc(v: json.Value, key: string) -> bool {
	x, ok := jfield(v, key)
	if !ok {
		return false
	}
	b, is := x.(json.Boolean)
	return is && bool(b)
}

// jprop reads one entry of the `properties` object, which pactl renders as a
// flat map of strings.
jprop :: proc(v: json.Value, key: string) -> string {
	props, ok := jfield(v, "properties")
	if !ok {
		return ""
	}
	return jstr(props, key)
}

jprop_int :: proc(v: json.Value, key: string) -> int {
	s := jprop(v, key)
	if s == "" {
		return -1
	}
	n, ok := strconv.parse_int(s)
	return ok ? n : -1
}

// jvolume averages the per-channel volumes, because a mixer shows one slider
// per device and balance is not something this applet offers.
jvolume :: proc(v: json.Value) -> (vol: f32, chans: int) {
	x, ok := jfield(v, "volume")
	if !ok {
		return 0, 0
	}
	o, is := x.(json.Object)
	if !is {
		return 0, 0
	}
	sum: f64 = 0
	for _, cv in o {
		sum += jnum(cv, "value")
		chans += 1
	}
	if chans == 0 {
		return 0, 0
	}
	return f32(sum / f64(chans)) / VOL_NORM, chans
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

// audio_read re-reads the whole graph. `al` owns the strings that come back;
// `scratch` is where the JSON documents are parsed and can be thrown away
// afterwards.
audio_read :: proc(al: mem.Allocator, scratch: mem.Allocator) -> (a: Audio) {
	a.default_out, _ = kit.run({"pactl", "get-default-sink"}, al)
	a.default_in, _ = kit.run({"pactl", "get-default-source"}, al)

	outs := make([dynamic]Dev, 0, 8, al)
	ins := make([dynamic]Dev, 0, 8, al)
	streams := make([dynamic]Stream, 0, 8, al)

	sinks, sink_ok := read_devs(&outs, "sinks", false, a.default_out, al, scratch)
	srcs, src_ok := read_devs(&ins, "sources", true, a.default_in, al, scratch)
	_, _ = sinks, srcs

	read_streams(&streams, "sink-inputs", false, al, scratch)
	read_streams(&streams, "source-outputs", true, al, scratch)

	a.outs = outs[:]
	a.ins = ins[:]
	a.streams = streams[:]
	a.ok = sink_ok || src_ok
	if !a.ok {
		a.err = "pactl did not answer — is PipeWire running?"
	}
	return
}

@(private)
read_devs :: proc(
	into: ^[dynamic]Dev,
	what: string,
	input: bool,
	default_name: string,
	al: mem.Allocator,
	scratch: mem.Allocator,
) -> (
	n: int,
	ok: bool,
) {
	text, good := kit.run({"pactl", "-f", "json", "list", what}, scratch)
	if !good || text == "" {
		return 0, false
	}
	doc, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, scratch)
	if err != nil {
		return 0, false
	}
	arr, is := doc.(json.Array)
	if !is {
		return 0, false
	}

	for item in arr {
		// A monitor source is the loopback of an output, not an input device.
		// Showing them under "Inputs" is how a mixer ends up listing eight
		// microphones on a machine with one.
		if input && jprop(item, "device.class") == "monitor" {
			continue
		}
		vol, chans := jvolume(item)
		d := Dev {
			index = int(jnum(item, "index")),
			node  = jprop_int(item, "object.id"),
			name  = strings.clone(jstr(item, "name"), al),
			desc  = strings.clone(jstr(item, "description"), al),
			mute  = jbool(item, "mute"),
			vol   = vol,
			chans = chans,
			state = strings.clone(jstr(item, "state"), al),
			bus   = strings.clone(jprop(item, "device.bus"), al),
			form  = strings.clone(jprop(item, "device.form_factor"), al),
			codec = strings.clone(jprop(item, "api.bluez5.codec"), al),
			spec  = strings.clone(jstr(item, "sample_specification"), al),
			input = input,
		}
		d.default = d.name == default_name
		d.port = strings.clone(port_label(item), al)
		append(into, d)
		n += 1
	}
	return n, true
}

// port_label finds the description of the port that is actually in use, which
// is what distinguishes "Headphones" from "Line Out" on the same card.
@(private)
port_label :: proc(item: json.Value) -> string {
	active := jstr(item, "active_port")
	if active == "" {
		return ""
	}
	ports, ok := jfield(item, "ports")
	if !ok {
		return active
	}
	arr, is := ports.(json.Array)
	if !is {
		return active
	}
	for pv in arr {
		if jstr(pv, "name") == active {
			if d := jstr(pv, "description"); d != "" {
				return d
			}
		}
	}
	return active
}

@(private)
read_streams :: proc(
	into: ^[dynamic]Stream,
	what: string,
	record: bool,
	al: mem.Allocator,
	scratch: mem.Allocator,
) {
	text, good := kit.run({"pactl", "-f", "json", "list", what}, scratch)
	if !good || text == "" {
		return
	}
	doc, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, scratch)
	if err != nil {
		return
	}
	arr, is := doc.(json.Array)
	if !is {
		return
	}
	for item in arr {
		vol, _ := jvolume(item)
		app := jprop(item, "application.name")
		if app == "" {
			app = jprop(item, "application.process.binary")
		}
		if app == "" {
			app = "Unknown"
		}
		s := Stream {
			index  = int(jnum(item, "index")),
			node   = jprop_int(item, "object.id"),
			app    = strings.clone(app, al),
			media  = strings.clone(jprop(item, "media.name"), al),
			binary = strings.clone(jprop(item, "application.process.binary"), al),
			mute   = jbool(item, "mute"),
			vol    = vol,
			corked = jbool(item, "corked"),
			record = record,
		}
		append(into, s)
	}
}

// ---------------------------------------------------------------------------
// Writing
//
// Every one of these is a single wpctl invocation, and every one is logged
// verbatim so the applet can show exactly what it ran against the real graph.
// ---------------------------------------------------------------------------

// VOL_CEILING caps what this applet will set. PipeWire happily goes past 1.0
// into software amplification, which is a good way to hand somebody a clipped
// 150% headphone output they did not ask for.
VOL_CEILING :: f32(1.0)

set_volume :: proc(node: int, v: f32) -> (ok: bool) {
	if node < 0 {
		return false
	}
	clamped := clamp(v, 0, VOL_CEILING)
	arg := fmt.tprintf("%.2f", clamped)
	id := fmt.tprintf("%d", node)
	_, good := kit.run({"wpctl", "set-volume", id, arg}, context.temp_allocator)
	log_cmd(fmt.tprintf("wpctl set-volume %s %s", id, arg), good)
	return good
}

set_mute :: proc(node: int, on: bool) -> (ok: bool) {
	if node < 0 {
		return false
	}
	id := fmt.tprintf("%d", node)
	arg := on ? "1" : "0"
	_, good := kit.run({"wpctl", "set-mute", id, arg}, context.temp_allocator)
	log_cmd(fmt.tprintf("wpctl set-mute %s %s", id, arg), good)
	return good
}

set_default :: proc(node: int) -> (ok: bool) {
	if node < 0 {
		return false
	}
	id := fmt.tprintf("%d", node)
	_, good := kit.run({"wpctl", "set-default", id}, context.temp_allocator)
	log_cmd(fmt.tprintf("wpctl set-default %s", id), good)
	return good
}

// read_back asks wpctl what the volume actually is now. Every write in this
// applet is followed by one of these, so the UI shows what the server did
// rather than what it was asked to do.
read_back :: proc(node: int) -> (vol: f32, mute: bool, ok: bool) {
	if node < 0 {
		return 0, false, false
	}
	out, good := kit.run({"wpctl", "get-volume", fmt.tprintf("%d", node)}, context.temp_allocator)
	if !good {
		return 0, false, false
	}
	// "Volume: 0.50" or "Volume: 0.50 [MUTED]"
	rest := out
	if i := strings.index_byte(rest, ':'); i >= 0 {
		rest = rest[i + 1:]
	}
	mute = strings.index(out, "MUTED") >= 0
	f, parsed := strconv.parse_f32(strings.trim_space(first_word(rest)))
	return f, mute, parsed
}

@(private)
first_word :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index_byte(t, ' '); i > 0 {
		return t[:i]
	}
	return t
}

// ---------------------------------------------------------------------------
// The command log
// ---------------------------------------------------------------------------

Log_Entry :: struct {
	cmd:  string,
	ok:   bool,
	used: bool,
}

LOG_N :: 64
g_log: [LOG_N]Log_Entry
g_log_at: int
g_log_count: int

log_cmd :: proc(cmd: string, ok: bool) {
	e := &g_log[g_log_at % LOG_N]
	if e.used {
		delete(e.cmd)
	}
	e^ = {cmd = strings.clone(cmd), ok = ok, used = true}
	g_log_at += 1
	g_log_count += 1
	// Also to stderr, so a run from a terminal leaves an auditable trail of
	// every command this applet issued against the user's audio.
	fmt.eprintfln("[mixer] %s%s", cmd, ok ? "" : "   (failed)")
}

log_recent :: proc(n: int, al := context.temp_allocator) -> []Log_Entry {
	count := min(n, min(g_log_count, LOG_N))
	out := make([]Log_Entry, count, al)
	for i in 0 ..< count {
		out[count - 1 - i] = g_log[(g_log_at - 1 - i + LOG_N * 4) % LOG_N]
	}
	return out
}
