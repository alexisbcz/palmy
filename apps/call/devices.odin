package call

// ---------------------------------------------------------------------------
// Devices.
//
// The pickers list what is really on this machine: audio nodes from `wpctl
// status`, cameras from `v4l2-ctl --list-devices`. Enumerating a device and
// opening it are different acts, and this file only does the first — see
// `allow_real` in main.odin for why the second is behind a flag.
//
// Every list begins with a synthetic entry, which is the default. That is not
// a placeholder: `testsrc2` and `aevalsrc` go through exactly the same framer,
// encoder, socket, jitter buffer and decoder as the camera and the microphone
// do, so a call driven by them exercises the whole pipeline and tells you
// nothing about the room the computer is in.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:strconv"
import "core:strings"
import kit "kit:."

Device_Kind :: enum {
	Synthetic,
	Audio_Source,
	Audio_Sink,
	Camera,
}

Device :: struct {
	kind:    Device_Kind,
	id:      int,    // wpctl node id; 0 for the default or a non-audio device
	name:    string,
	path:    string, // /dev/videoN for a camera
	is_default: bool,
	real:    bool,   // true when opening this touches hardware
	// owned marks a name/path this struct allocated, as opposed to a string
	// literal. Without it the fixed entries get freed on a rescan.
	owned:   bool,
}

Devices :: struct {
	sources: [dynamic]Device, // microphones, plus Synthetic first
	sinks:   [dynamic]Device, // speakers, plus the system default first
	cameras: [dynamic]Device, // cameras, plus Synthetic first

	// Indices into the three lists.
	src_sel: int,
	sink_sel: int,
	cam_sel: int,

	note: string,
}

SYNTH_AUDIO_NAME :: "Synthetic tone (440 Hz, modulated)"
SYNTH_VIDEO_NAME :: "Synthetic pattern (testsrc2)"
DEFAULT_SINK_NAME :: "System default output"

devices_init :: proc(d: ^Devices) {
	d.sources = make([dynamic]Device)
	d.sinks = make([dynamic]Device)
	d.cameras = make([dynamic]Device)
}

devices_destroy :: proc(d: ^Devices) {
	devices_free_lists(d)
	delete(d.sources)
	delete(d.sinks)
	delete(d.cameras)
}

@(private = "file")
devices_free_lists :: proc(d: ^Devices) {
	for list in ([?]^[dynamic]Device{&d.sources, &d.sinks, &d.cameras}) {
		for dev in list {
			if dev.owned {
				delete(dev.name)
				if dev.path != "" {
					delete(dev.path)
				}
			}
		}
		clear(list)
	}
}

// devices_scan runs the two enumeration commands. It blocks for as long as
// they take — tens of milliseconds — so it is called on an explicit refresh
// and at startup, never per frame.
devices_scan :: proc(d: ^Devices) {
	devices_free_lists(d)

	append(&d.sources, Device{kind = .Synthetic, name = SYNTH_AUDIO_NAME, is_default = true})
	append(&d.cameras, Device{kind = .Synthetic, name = SYNTH_VIDEO_NAME, is_default = true})
	append(&d.sinks, Device{kind = .Audio_Sink, name = DEFAULT_SINK_NAME, id = 0})

	parse_wpctl(d)
	parse_v4l2(d)

	d.src_sel = clamp(d.src_sel, 0, max(0, len(d.sources) - 1))
	d.sink_sel = clamp(d.sink_sel, 0, max(0, len(d.sinks) - 1))
	d.cam_sel = clamp(d.cam_sel, 0, max(0, len(d.cameras) - 1))
	delete(d.note)
	d.note = fmt.aprintf(
		"%d microphone(s), %d output(s), %d camera(s) found",
		len(d.sources) - 1,
		len(d.sinks) - 1,
		len(d.cameras) - 1,
	)
}

// ---------------------------------------------------------------------------
// wpctl
//
// `wpctl status` is a tree drawn with box characters:
//
//	Audio
//	 ├─ Sinks:
//	 │      34. Ryzen HD Audio Controller Analog Stereo [vol: 0.55]
//	 │  *   86. CMF Headphone Pro                   [vol: 0.50]
//	 ├─ Sources:
//	 │  *   46. Brio 100 Mono                       [vol: 0.83]
//	Video
//	 ├─ Sources:
//	 │  *   72. Brio 100 (V4L2)
//
// So the parse is: track the top-level section, track the sub-heading, and
// read `<id>. <name>` out of the rows. `*` marks the default.
// ---------------------------------------------------------------------------

@(private = "file")
Section :: enum {
	None,
	Audio,
	Video,
}

@(private = "file")
Sub :: enum {
	None,
	Sinks,
	Sources,
}

parse_wpctl :: proc(d: ^Devices) {
	lines, ok := kit.run_lines({"wpctl", "status"}, context.temp_allocator)
	if !ok || len(lines) == 0 {
		return
	}

	section := Section.None
	sub := Sub.None

	for raw in lines {
		// A top-level heading is the only thing with no box drawing on it.
		bare := strip_tree(raw)
		if raw == "Audio" {
			section, sub = .Audio, .None
			continue
		}
		if raw == "Video" {
			section, sub = .Video, .None
			continue
		}
		if raw == "Settings" {
			section, sub = .None, .None
			continue
		}
		if strings.has_suffix(bare, "Sinks:") {
			sub = .Sinks
			continue
		}
		if strings.has_suffix(bare, "Sources:") {
			sub = .Sources
			continue
		}
		if strings.has_suffix(bare, "Devices:") ||
		   strings.has_suffix(bare, "Streams:") ||
		   strings.has_suffix(bare, "Filters:") ||
		   strings.has_suffix(bare, "Clients:") {
			sub = .None
			continue
		}
		if section == .None || sub == .None {
			continue
		}

		id, name, got := parse_node_row(bare)
		if !got {
			continue
		}
		is_def := strings.has_prefix(bare, "*")

		switch {
		case section == .Audio && sub == .Sources:
			append(
				&d.sources,
				Device {
					kind = .Audio_Source,
					id = id,
					name = strings.clone(name),
					is_default = is_def,
					real = true,
					owned = true,
				},
			)
		case section == .Audio && sub == .Sinks:
			append(
				&d.sinks,
				Device {
					kind = .Audio_Sink,
					id = id,
					name = strings.clone(name),
					is_default = is_def,
					real = true,
					owned = true,
				},
			)
		case section == .Video && sub == .Sources:
			// A PipeWire video node; the v4l2 pass adds the /dev path, so this
			// one is informational and carries no path to open.
			append(
				&d.cameras,
				Device {
					kind = .Camera,
					id = id,
					name = fmt.aprintf("%s [pipewire]", name),
					is_default = is_def,
					real = true,
					owned = true,
				},
			)
		}
	}
}

// strip_tree removes wpctl's box-drawing prefix and surrounding space, so the
// row can be matched on its content.
strip_tree :: proc(s: string) -> string {
	out := s
	for {
		trimmed := strings.trim_left_space(out)
		cut := false
		for prefix in ([?]string{"└─", "├─", "│", "─", "┌─"}) {
			if strings.has_prefix(trimmed, prefix) {
				trimmed = trimmed[len(prefix):]
				cut = true
				break
			}
		}
		out = trimmed
		if !cut {
			break
		}
	}
	return strings.trim_space(out)
}

// parse_node_row reads `[*] <id>. <name> [vol: x]`.
parse_node_row :: proc(s: string) -> (id: int, name: string, ok: bool) {
	t := strings.trim_space(s)
	if strings.has_prefix(t, "*") {
		t = strings.trim_space(t[1:])
	}
	dot := strings.index_byte(t, '.')
	if dot <= 0 {
		return 0, "", false
	}
	n, parsed := strconv.parse_int(t[:dot])
	if !parsed {
		return 0, "", false
	}
	rest := strings.trim_space(t[dot + 1:])
	// Trim the trailing `[vol: 0.55]` and anything else in brackets at the end.
	if br := strings.last_index_byte(rest, '['); br > 0 {
		rest = strings.trim_space(rest[:br])
	}
	if rest == "" {
		return 0, "", false
	}
	return n, rest, true
}

// ---------------------------------------------------------------------------
// v4l2-ctl
//
//	Brio 100 (usb-0000:06:00.3-1):
//		/dev/video0
//		/dev/video1
//
// Only the first node of a device is a capture node on a UVC camera; the
// second is the metadata node. Take the first and label it with the name.
// ---------------------------------------------------------------------------

parse_v4l2 :: proc(d: ^Devices) {
	lines, ok := kit.run_lines({"v4l2-ctl", "--list-devices"}, context.temp_allocator)
	if !ok && len(lines) == 0 {
		return
	}
	label := ""
	taken := false
	for raw in lines {
		t := strings.trim_space(raw)
		if strings.has_suffix(t, ":") {
			label = strings.trim_space(t[:len(t) - 1])
			taken = false
			continue
		}
		if !strings.has_prefix(t, "/dev/video") || taken || label == "" {
			continue
		}
		append(
			&d.cameras,
			Device {
				kind = .Camera,
				name = strings.clone(label),
				path = strings.clone(t),
				real = true,
				owned = true,
			},
		)
		taken = true
	}
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

sel_source :: proc(d: ^Devices) -> Device {
	if len(d.sources) == 0 {
		return {kind = .Synthetic, name = SYNTH_AUDIO_NAME}
	}
	return d.sources[clamp(d.src_sel, 0, len(d.sources) - 1)]
}

sel_sink :: proc(d: ^Devices) -> Device {
	if len(d.sinks) == 0 {
		return {kind = .Audio_Sink, name = DEFAULT_SINK_NAME}
	}
	return d.sinks[clamp(d.sink_sel, 0, len(d.sinks) - 1)]
}

sel_camera :: proc(d: ^Devices) -> Device {
	if len(d.cameras) == 0 {
		return {kind = .Synthetic, name = SYNTH_VIDEO_NAME}
	}
	return d.cameras[clamp(d.cam_sel, 0, len(d.cameras) - 1)]
}
