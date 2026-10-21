package call

// The command line, on the shared convention (apps/kit/cli.odin).
//
// A call is a window, or a headless peer, driven by the long list of flags in
// main.odin's USAGE — and those stay exactly as they were: `call --bind 47811
// --peer 47812` still opens a window. The convention's verbs are the parts of
// the call that answer a question without placing one: what the echo
// canceller removes on a synthetic echo path (`aec`), and what the bitrate
// controller does on an emulated link (`rate`). Neither opens a socket, a
// microphone or a camera, so both are read-only and safe to run anywhere.

import "core:fmt"
import "core:os"
import "core:strconv"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "aec",
		summary = "measure the echo canceller (ERLE, in dB) on a synthetic echo path",
		effect = .Read,
		flags = {
			{name = "delay-ms", kind = .Float, help = "bulk delay of the echo path", def = "40"},
			{name = "room-ms", kind = .Float, help = "length of the room's impulse response (60 dB decay)", def = "30"},
			{name = "gain-db", kind = .Float, help = "energy gain of the echo path", def = "-6"},
			{name = "noise-db", kind = .Float, help = "near-end noise floor, dBFS", def = "-65"},
			{name = "tail-ms", kind = .Float, help = "the canceller's filter length", def = "170"},
			{name = "off", kind = .Bool, help = "bypass the canceller, to see the baseline it is scored against"},
			{name = "far", kind = .Path, help = "far-end voice, raw s16le 48 kHz mono (e.g. from ffmpeg lavfi); default: synthetic"},
			{name = "near", kind = .Path, help = "near-end voice, same format; default: synthetic"},
			{name = "near-always", kind = .Bool, help = "the near end talks throughout (double talk from the first sample), not only 5-7 s"},
		},
		out = AEC_FIELDS,
		examples = {"call aec --json", "call aec --delay-ms 90 --gain-db 0", "call aec --off --json"},
		run = cmd_aec,
	},
	{
		verb = "rate",
		summary = "run the adaptive bitrate controller against an emulated bottleneck link",
		effect = .Read,
		flags = {
			{name = "link-kbps", kind = .Float, help = "the bottleneck's capacity", def = "200"},
			{name = "loss", kind = .Float, help = "random loss on top, percent", def = "0"},
			{name = "rtt-ms", kind = .Float, help = "the path's base round-trip time", def = "20"},
			{name = "start-kbps", kind = .Float, help = "the encoder's starting (and ceiling) rate", def = "300"},
			{name = "seconds", kind = .Float, help = "how long to run", def = "30"},
			{name = "fixed", kind = .Bool, help = "never adapt, to see the baseline"},
		},
		out = RATE_FIELDS,
		examples = {"call rate --json", "call rate --link-kbps 120 --loss 2", "call rate --fixed --json"},
		run = cmd_rate,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "call",
			summary  = "audio and video calls: two-party direct, or many through palm-sfu; end-to-end encrypted",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `Placing a call is the window's job, or a headless peer's: call --bind PORT
--peer PORT, call --sfu HOST:PORT --join-token T (see call --help).
Those flags are unchanged and are not commands here. Nothing on this surface
opens a socket, a microphone or a camera.`

// is_cli_invocation says the first word is the convention's, not the window's.
is_cli_invocation :: proc(first: string) -> bool {
	switch first {
	case "help", "--schema", "--selftest", "--self-test", "-t":
		return true
	}
	for c in COMMANDS {
		if c.verb == first {
			return true
		}
	}
	return false
}

cli_selftest :: proc() -> int {
	return run_self_test()
}

AEC_FIELDS := []kit.Field {
	{name = "enabled", kind = .Bool, help = "false under --off"},
	{name = "tail_ms", kind = .Float, help = "filter length"},
	{name = "path_delay_ms", kind = .Float},
	{name = "path_gain_db", kind = .Float},
	{name = "erle_db", kind = .Float, help = "microphone over output energy, far end alone, 2-5 s"},
	{name = "echo_removal_db", kind = .Float, help = "echo over residual echo, far end alone, 2-5 s"},
	{name = "dt_echo_removal_db", kind = .Float, help = "the same during double talk, 5-7 s"},
	{name = "dt_near_to_residual_db", kind = .Float, help = "near voice over what is left of the echo, double talk"},
	{name = "post_dt_erle_db", kind = .Float, help = "ERLE after double talk, 7-9 s"},
	{name = "reconverged_erle_db", kind = .Float, help = "ERLE 1.5 s after the echo path moves at 9 s"},
	{name = "converge_ms", kind = .Float, help = "first 100 ms window with 20 dB of echo removal; -1 if never"},
	{name = "copies", kind = .Int, help = "background filter promoted"},
	{name = "resets", kind = .Int, help = "background filter reset after diverging"},
	{name = "cpu_ms_per_s", kind = .Float, help = "processing time per second of audio"},
}

@(private = "file")
read_raw :: proc(c: ^kit.Call, flag: string) -> (pcm: []f32, code: int) {
	path := kit.cli_str(c, flag)
	if path == "" {
		return nil, kit.EXIT_OK
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", path)
	}
	n := len(data) / 2
	pcm = make([]f32, n)
	for i in 0 ..< n {
		s := i16(u16(data[2 * i]) | u16(data[2 * i + 1]) << 8)
		pcm[i] = f32(s) / 32768
	}
	delete(data)
	return pcm, kit.EXIT_OK
}

@(private = "file")
flt :: proc(c: ^kit.Call, name: string, def: f64) -> f64 {
	v := kit.cli_str(c, name)
	if v == "" {
		return def
	}
	f, ok := strconv.parse_f64(v)
	return ok ? f : def
}

@(private = "file")
cmd_aec :: proc(c: ^kit.Call) -> int {
	sc := AEC_SCENARIO_DEFAULT
	sc.delay_ms = f32(flt(c, "delay-ms", 40))
	sc.room_ms = f32(flt(c, "room-ms", 30))
	sc.gain_db = f32(flt(c, "gain-db", -6))
	sc.noise_db = f32(flt(c, "noise-db", -65))
	tail := flt(c, "tail-ms", 170)
	sc.parts = max(1, int(tail * f64(A_RATE) / 1000 / f64(AEC_N) + 0.5))
	sc.enabled = !kit.cli_bool(c, "off")
	sc.near_always = kit.cli_bool(c, "near-always")
	if sc.delay_ms < 0 || sc.delay_ms > 500 || sc.room_ms <= 0 || sc.room_ms > 500 || tail <= 0 || tail > 1000 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "delay 0..500 ms, room 0..500 ms, tail 0..1000 ms")
	}
	code: int
	sc.far, code = read_raw(c, "far")
	if code != kit.EXIT_OK {
		return code
	}
	sc.near, code = read_raw(c, "near")
	if code != kit.EXIT_OK {
		return code
	}
	rep := aec_measure(sc)
	o := c.out
	kit.jset_bool(o, "enabled", sc.enabled)
	kit.jset_num(o, "tail_ms", f64(rep.tail_ms))
	kit.jset_num(o, "path_delay_ms", f64(rep.path_delay_ms))
	kit.jset_num(o, "path_gain_db", f64(rep.path_gain_db))
	kit.jset_num(o, "erle_db", r1(rep.erle_db))
	kit.jset_num(o, "echo_removal_db", r1(rep.echo_removal_db))
	kit.jset_num(o, "dt_echo_removal_db", r1(rep.dt_echo_removal_db))
	kit.jset_num(o, "dt_near_to_residual_db", r1(rep.dt_near_to_residual_db))
	kit.jset_num(o, "post_dt_erle_db", r1(rep.post_dt_erle_db))
	kit.jset_num(o, "reconverged_erle_db", r1(rep.reconverged_erle_db))
	kit.jset_num(o, "converge_ms", r1(rep.converge_ms))
	kit.jset_int(o, "copies", rep.copies)
	kit.jset_int(o, "resets", rep.resets)
	kit.jset_num(o, "cpu_ms_per_s", r1(rep.cpu_ms_per_s))
	return kit.EXIT_OK
}

r1 :: proc(v: f32) -> f64 {
	return f64(i64(v * 10 + (v >= 0 ? 0.5 : -0.5))) / 10
}

RATE_FIELDS := []kit.Field {
	{name = "adaptive", kind = .Bool},
	{name = "link_kbps", kind = .Float},
	{name = "random_loss_pct", kind = .Float},
	{name = "start_kbps", kind = .Float},
	{name = "final_kbps", kind = .Float, help = "the encoder's rate at the end"},
	{name = "mean_kbps_last10", kind = .Float, help = "mean target over the last 10 s"},
	{name = "loss_pct_last10", kind = .Float, help = "packets lost over the last 10 s"},
	{name = "rtt_ms_last10", kind = .Float, help = "mean measured RTT over the last 10 s"},
	{name = "goodput_kbps_last10", kind = .Float, help = "what arrived, last 10 s"},
	{name = "encoder_restarts", kind = .Int, help = "H.264 encoder restarts the rate changes cost"},
	{name = "decreases", kind = .Int},
	{name = "increases", kind = .Int},
}

@(private = "file")
cmd_rate :: proc(c: ^kit.Call) -> int {
	cfg := Rate_Sim {
		link_kbps  = flt(c, "link-kbps", 200),
		loss_pct   = flt(c, "loss", 0),
		base_rtt_ms = flt(c, "rtt-ms", 20),
		start_kbps = flt(c, "start-kbps", 300),
		seconds    = flt(c, "seconds", 30),
		adaptive   = !kit.cli_bool(c, "fixed"),
	}
	if cfg.link_kbps < 10 || cfg.loss_pct < 0 || cfg.loss_pct > 50 || cfg.seconds < 1 || cfg.seconds > 600 || cfg.start_kbps < 40 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "link >= 10 kbit/s, loss 0..50 %, seconds 1..600, start >= 40 kbit/s")
	}
	r := rate_simulate(cfg)
	o := c.out
	kit.jset_bool(o, "adaptive", cfg.adaptive)
	kit.jset_num(o, "link_kbps", cfg.link_kbps)
	kit.jset_num(o, "random_loss_pct", cfg.loss_pct)
	kit.jset_num(o, "start_kbps", cfg.start_kbps)
	kit.jset_num(o, "final_kbps", r1(f32(r.final_kbps)))
	kit.jset_num(o, "mean_kbps_last10", r1(f32(r.mean_kbps)))
	kit.jset_num(o, "loss_pct_last10", r1(f32(r.loss_pct)))
	kit.jset_num(o, "rtt_ms_last10", r1(f32(r.rtt_ms)))
	kit.jset_num(o, "goodput_kbps_last10", r1(f32(r.goodput_kbps)))
	kit.jset_int(o, "encoder_restarts", r.restarts)
	kit.jset_int(o, "decreases", r.decreases)
	kit.jset_int(o, "increases", r.increases)
	_ = fmt.tprintf
	return kit.EXIT_OK
}
