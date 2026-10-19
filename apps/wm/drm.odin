// drm.odin — the DRM/KMS output backend.
//
// The compositor in main.odin draws into a `p.Canvas` and knows nothing about
// where those pixels land. Nested, the canvas comes from the host compositor
// via `p.direct_frames`. On bare metal it comes from here: a dumb buffer
// allocated out of the GPU's KMS node, mmap'd into the process, registered as
// a framebuffer with ADDFB2 and shown with a page flip.
//
// There is no GL and no Vulkan in this program and there never will be. The
// rasterizer writes u32 XRGB pixels with the CPU, which is exactly the memory
// layout a DRM_FORMAT_XRGB8888 dumb buffer wants, so the scanout path is a
// plain store to a mapping — zero copy when the driver's pitch happens to be
// width*4, one row-wise blit out of a shadow buffer when it is not.
//
// Legacy page-flip, not atomic. See drm_present.
//
// ----------------------------------------------------------------------------
// SAFETY
//
// Everything that can take over the display is behind `drm_live`, which is off
// unless PALMY_WM_DRM_LIVE=1 is in the environment or `wm --drm` opened it
// with drm_enable_live (bare.odin, which first refuses to run inside a
// graphical session): SET_MASTER, DROP_MASTER, SETCRTC, PAGE_FLIP, DIRTYFB.
//
// It has run, inside QEMU (apps/wm/qemu-test.sh): virtio-gpu, 1280x800,
// direct open of /dev/dri/card0 as a non-root user in `video`, master by the
// first-opener rule, legacy PAGE_FLIP with real completion events. virtio-gpu
// completes a flip as soon as the host has the pixels, so flips do not pace
// anything there; bare.odin spaces frames by the refresh period as well. Nothing in this file touches a VT, /dev/tty* or
// /sys/class/vtconsole. The enumeration half — GET_CAP, GETRESOURCES,
// GETCONNECTOR, GETENCODER, GETCRTC, GETPROPERTY, GETPROPBLOB — needs no
// master, affects nothing, and is what `--drm-probe` exercises.
package wm

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import p "palmy:."

// ----------------------------------------------------------------------------
// uapi: ioctl numbers
//
// Computed from <drm/drm.h> with _IOWR(0x64, nr, struct). They are written out
// literally rather than derived so that a struct whose size drifts away from
// the kernel's produces an EINVAL we can see, instead of silently encoding a
// different request. drm_selftest asserts every struct size that feeds one.
// ----------------------------------------------------------------------------

DRM_IOCTL_VERSION :: u32(0xc0406400)
DRM_IOCTL_GET_CAP :: u32(0xc010640c)
DRM_IOCTL_SET_CLIENT_CAP :: u32(0x4010640d)
DRM_IOCTL_SET_MASTER :: u32(0x0000641e)
DRM_IOCTL_DROP_MASTER :: u32(0x0000641f)
DRM_IOCTL_MODE_GETRESOURCES :: u32(0xc04064a0)
DRM_IOCTL_MODE_GETCRTC :: u32(0xc06864a1)
DRM_IOCTL_MODE_SETCRTC :: u32(0xc06864a2)
DRM_IOCTL_MODE_GETENCODER :: u32(0xc01464a6)
DRM_IOCTL_MODE_GETCONNECTOR :: u32(0xc05064a7)
DRM_IOCTL_MODE_GETPROPERTY :: u32(0xc04064aa)
DRM_IOCTL_MODE_GETPROPBLOB :: u32(0xc01064ac)
DRM_IOCTL_MODE_RMFB :: u32(0xc00464af)
DRM_IOCTL_MODE_PAGE_FLIP :: u32(0xc01864b0)
DRM_IOCTL_MODE_CREATE_DUMB :: u32(0xc02064b2)
DRM_IOCTL_MODE_MAP_DUMB :: u32(0xc01064b3)
DRM_IOCTL_MODE_DESTROY_DUMB :: u32(0xc00464b4)
DRM_IOCTL_MODE_GETPLANERESOURCES :: u32(0xc01064b5)
DRM_IOCTL_MODE_DIRTYFB :: u32(0xc01864b1)
DRM_IOCTL_MODE_ADDFB2 :: u32(0xc06864b8)
DRM_IOCTL_MODE_OBJ_GETPROPERTIES :: u32(0xc02064b9)
DRM_IOCTL_MODE_ATOMIC :: u32(0xc03864bc)

DRM_CAP_DUMB_BUFFER :: u64(0x1)
DRM_CAP_VBLANK_HIGH_CRTC :: u64(0x2)
DRM_CAP_DUMB_PREFERRED_DEPTH :: u64(0x3)
DRM_CAP_PRIME :: u64(0x5)
DRM_CAP_TIMESTAMP_MONOTONIC :: u64(0x6)
DRM_CAP_ASYNC_PAGE_FLIP :: u64(0x7)
DRM_CAP_ADDFB2_MODIFIERS :: u64(0x10)
DRM_CAP_CRTC_IN_VBLANK_EVENT :: u64(0x12)

DRM_CLIENT_CAP_STEREO_3D :: u64(1)
DRM_CLIENT_CAP_UNIVERSAL_PLANES :: u64(2)
DRM_CLIENT_CAP_ATOMIC :: u64(3)
DRM_CLIENT_CAP_ASPECT_RATIO :: u64(4)

DRM_FORMAT_XRGB8888 :: u32(0x34325258) // 'XR24'
DRM_FORMAT_ARGB8888 :: u32(0x34325241) // 'AR24'

DRM_MODE_PAGE_FLIP_EVENT :: u32(0x01)
DRM_MODE_PAGE_FLIP_ASYNC :: u32(0x02)

DRM_MODE_ATOMIC_TEST_ONLY :: u32(0x0100)
DRM_MODE_ATOMIC_NONBLOCK :: u32(0x0200)
DRM_MODE_ATOMIC_ALLOW_MODESET :: u32(0x0400)

DRM_EVENT_VBLANK :: u32(0x01)
DRM_EVENT_FLIP_COMPLETE :: u32(0x02)
DRM_EVENT_CRTC_SEQUENCE :: u32(0x03)

DRM_MODE_TYPE_PREFERRED :: u32(1 << 3)
DRM_MODE_TYPE_DRIVER :: u32(1 << 6)
DRM_MODE_FLAG_INTERLACE :: u32(1 << 4)
DRM_MODE_FLAG_DBLSCAN :: u32(1 << 5)

DRM_MODE_PROP_BLOB :: u32(1 << 4)

DRM_MODE_OBJECT_CRTC :: u32(0xcccccccc)
DRM_MODE_OBJECT_CONNECTOR :: u32(0xc0c0c0c0)
DRM_MODE_OBJECT_ENCODER :: u32(0xe0e0e0e0)
DRM_MODE_OBJECT_PLANE :: u32(0xeeeeeeee)

DRM_MODE_CONNECTED :: u32(1)
DRM_MODE_DISCONNECTED :: u32(2)
DRM_MODE_UNKNOWNCONNECTION :: u32(3)

DRM_PROP_NAME_LEN :: 32
DRM_DISPLAY_MODE_LEN :: 32

// ----------------------------------------------------------------------------
// uapi: structs
//
// Field-for-field with <drm/drm.h> and <drm/drm_mode.h>. Odin lays these out
// the same way the C compiler does; drm_selftest pins every size so a change
// to either side is a loud failure and not a corrupted ioctl.
// ----------------------------------------------------------------------------

Drm_Version :: struct {
	version_major:      i32,
	version_minor:      i32,
	version_patchlevel: i32,
	name_len:           uint,
	name:               [^]u8,
	date_len:           uint,
	date:               [^]u8,
	desc_len:           uint,
	desc:               [^]u8,
}

Drm_Get_Cap :: struct {
	capability: u64,
	value:      u64,
}

Drm_Set_Client_Cap :: struct {
	capability: u64,
	value:      u64,
}

Drm_Mode_Card_Res :: struct {
	fb_id_ptr:        u64,
	crtc_id_ptr:      u64,
	connector_id_ptr: u64,
	encoder_id_ptr:   u64,
	count_fbs:        u32,
	count_crtcs:      u32,
	count_connectors: u32,
	count_encoders:   u32,
	min_width:        u32,
	max_width:        u32,
	min_height:       u32,
	max_height:       u32,
}

Drm_Mode_Info :: struct {
	clock:       u32,
	hdisplay:    u16,
	hsync_start: u16,
	hsync_end:   u16,
	htotal:      u16,
	hskew:       u16,
	vdisplay:    u16,
	vsync_start: u16,
	vsync_end:   u16,
	vtotal:      u16,
	vscan:       u16,
	vrefresh:    u32,
	flags:       u32,
	kind:        u32, // `type` in C
	name:        [DRM_DISPLAY_MODE_LEN]u8,
}

Drm_Mode_Crtc :: struct {
	set_connectors_ptr: u64,
	count_connectors:   u32,
	crtc_id:            u32,
	fb_id:              u32,
	x:                  u32,
	y:                  u32,
	gamma_size:         u32,
	mode_valid:         u32,
	mode:               Drm_Mode_Info,
}

Drm_Mode_Get_Encoder :: struct {
	encoder_id:     u32,
	encoder_type:   u32,
	crtc_id:        u32,
	possible_crtcs: u32,
	possible_clones: u32,
}

Drm_Mode_Get_Connector :: struct {
	encoders_ptr:      u64,
	modes_ptr:         u64,
	props_ptr:         u64,
	prop_values_ptr:   u64,
	count_modes:       u32,
	count_props:       u32,
	count_encoders:    u32,
	encoder_id:        u32,
	connector_id:      u32,
	connector_type:    u32,
	connector_type_id: u32,
	connection:        u32,
	mm_width:          u32,
	mm_height:         u32,
	subpixel:          u32,
	pad:               u32,
}

Drm_Mode_Get_Property :: struct {
	values_ptr:       u64,
	enum_blob_ptr:    u64,
	prop_id:          u32,
	flags:            u32,
	name:             [DRM_PROP_NAME_LEN]u8,
	count_values:     u32,
	count_enum_blobs: u32,
}

Drm_Mode_Get_Blob :: struct {
	blob_id: u32,
	length:  u32,
	data:    u64,
}

Drm_Mode_Obj_Get_Properties :: struct {
	props_ptr:       u64,
	prop_values_ptr: u64,
	count_props:     u32,
	obj_id:          u32,
	obj_type:        u32,
}

Drm_Mode_Fb_Cmd2 :: struct {
	fb_id:        u32,
	width:        u32,
	height:       u32,
	pixel_format: u32,
	flags:        u32,
	handles:      [4]u32,
	pitches:      [4]u32,
	offsets:      [4]u32,
	modifier:     [4]u64,
}

Drm_Mode_Crtc_Page_Flip :: struct {
	crtc_id:   u32,
	fb_id:     u32,
	flags:     u32,
	reserved:  u32,
	user_data: u64,
}

// struct drm_mode_fb_dirty_cmd. With no clips the whole framebuffer is
// flushed, which is what a virtual GPU whose scanout is a host-side copy of
// the dumb buffer (virtio-gpu, the QXL family) needs before anything shows.
Drm_Mode_Fb_Dirty_Cmd :: struct {
	fb_id:     u32,
	flags:     u32,
	color:     u32,
	num_clips: u32,
	clips_ptr: u64,
}

Drm_Mode_Create_Dumb :: struct {
	height: u32,
	width:  u32,
	bpp:    u32,
	flags:  u32,
	handle: u32,
	pitch:  u32,
	size:   u64,
}

Drm_Mode_Map_Dumb :: struct {
	handle: u32,
	pad:    u32,
	offset: u64,
}

Drm_Mode_Destroy_Dumb :: struct {
	handle: u32,
}

Drm_Event_Header :: struct {
	kind:   u32, // `type` in C
	length: u32,
}

Drm_Event_Vblank :: struct {
	base:      Drm_Event_Header,
	user_data: u64,
	tv_sec:    u32,
	tv_usec:   u32,
	sequence:  u32,
	crtc_id:   u32,
}

// ----------------------------------------------------------------------------
// The model
// ----------------------------------------------------------------------------

// How many buffers per head. Two is enough to never scan out a half-drawn
// frame; three keeps the CPU rasterizer from stalling on a slow vblank at the
// cost of one more frame of latency and another mode-sized allocation.
DRM_BUFFERS :: 3

// Drm_Fb is one dumb buffer: the GEM handle, the KMS framebuffer object built
// over it, and the mapping the rasterizer writes into.
Drm_Fb :: struct {
	handle:    u32,
	fb_id:     u32,
	pitch:     u32, // bytes per row as the driver chose it
	size:      u64,
	stride_px: int, // pitch/4, >= width
	w, h:      int,
	mem:       rawptr,
	px:        []u32, // the whole mapping, stride_px*h words
	// anon is true for a buffer faked with an anonymous mmap instead of a
	// dumb buffer. The swap-chain tests use these; nothing scans them out.
	anon:      bool,
	// seq is the compositor frame whose pixels this buffer last received
	// (bare.odin's damage history); 0 means never, so repaint it whole.
	seq:       u64,
}

// Drm_Head is one output: a connector, the CRTC driving it, the mode, where it
// sits in the global layout, and its own swap chain. There is a list of these,
// never a single one — the nested backend only ever had one output and that
// assumption is not reproduced here.
Drm_Head :: struct {
	card:          ^Drm_Card,
	name:          string, // "eDP-1", "DP-3"
	monitor:       string, // from EDID, "" when unknown
	conn_id:       u32,
	enc_id:        u32,
	crtc_id:       u32,
	crtc_index:    int, // bit position in possible_crtcs
	connected:     bool,
	mode:          Drm_Mode_Info,
	have_mode:     bool,
	modes:         [dynamic]Drm_Mode_Info,
	preferred:     int, // index into modes, -1 when none is flagged
	mm_w, mm_h:    int,
	subpixel:      u32,

	// Position in the global layout space, in logical pixels, and the scale
	// factor from logical to device pixels on this head. Nothing consumes
	// `scale` yet; it exists so that the first HiDPI output does not force a
	// change to the data model.
	x, y:          int,
	scale:         f32,

	fbs:           [DRM_BUFFERS]Drm_Fb,
	back:          int, // index being drawn into
	front:         int, // index currently scanned out (-1 before the first flip)
	queued:        int, // index handed to the kernel, waiting for its event
	awaiting_flip: bool,

	// When the driver's pitch is not exactly width*4 the canvas cannot alias
	// the mapping, because p.Canvas indexes px[y*w+x]. In that case the canvas
	// points at `shadow` and drm_present blits row by row.
	shadow:        []u32,
	canvas:        p.Canvas,
	canvas_ready:  bool,

	enabled:       bool, // a mode is currently set on this head
	saved_crtc:    Drm_Mode_Crtc,
	saved_valid:   bool,

	clip:          [4]int, // what the frame being presented changed (DIRTYFB)

	refresh_ns:    i64, // from the mode's timings
	last_flip_ns:  i64,
	flip_sent_ns:  i64, // when the outstanding PAGE_FLIP went to the kernel
	frames:        u64,
	missed:        u64,
}

Drm_Card :: struct {
	fd:               linux.Fd,
	path:             string,
	driver:           string,
	have_dumb:        bool,
	monotonic:        bool,
	crtc_in_vblank:   bool,
	addfb2_modifiers: bool,
	prefer_bpp:       int,
	max_w, max_h:     int,
	crtcs:            [dynamic]u32,
	encoders:         [dynamic]u32,
	connectors:       [dynamic]u32,
	heads:            [dynamic]^Drm_Head,
	// Which CRTCs this card has already committed to a head, as a bitmask over
	// the index into `crtcs`. Keeps two heads off one CRTC.
	crtcs_taken:      u32,
	master:           bool,
	// Page flip does not work on this card — the ioctl was refused, or its
	// completion event never arrived — so every frame is shown with SETCRTC
	// onto the new buffer followed by DIRTYFB. Tears, but shows.
	no_flip:          bool,
	// The fd came from the seat layer, so it is the seat layer's to close and
	// the seat layer's master to drop.
	from_seat:        bool,
}

Drm_State :: struct {
	cards:     [dynamic]^Drm_Card,
	live:      bool, // PALMY_WM_DRM_LIVE=1: the modeset/flip gate
	live_read: bool,
	paused:    bool, // the session is on another VT; stop flipping
	active:    bool, // drm_init succeeded
	uevent_fd: linux.Fd,
	seat:      Drm_Seat,
	hotplug:   bool, // a re-probe is pending
	verbose:   bool,
	dirty_calls: u64, // DIRTYFB ioctls, and the pixels their clips covered
	dirty_px:    u64,
}

// The package already keeps backend state in a package-level global (`server`
// in main.odin). This is that, for the output side. Nothing here is added to
// Server: main.odin belongs to someone else.
drm_state: Drm_State

// ----------------------------------------------------------------------------
// The seat seam
//
// On bare metal the compositor is not root and cannot open /dev/dri/card* with
// the privileges it needs, nor can it hold master across a VT switch by
// itself. systemd-logind does both: TakeDevice hands back an fd, and
// PauseDevice/ResumeDevice bracket every VT switch.
//
// apps/wm/seat.odin is being written by someone else. This is the whole of
// what it has to provide, and all of it is optional: when `open` is nil this
// file opens the node itself, which is what makes --drm-probe work today in an
// ordinary user session.
// ----------------------------------------------------------------------------

Drm_Seat :: struct {
	// open takes a device path and returns an fd for it. logind's TakeDevice
	// returns a duplicate of the kernel's fd over D-Bus; returning it here is
	// enough. Return ok=false to fall back to opening the node directly.
	open:          proc(path: string) -> (fd: linux.Fd, ok: bool),
	// close releases the device back to the seat (logind ReleaseDevice).
	close:         proc(path: string, fd: linux.Fd),
	// has_master is true when the seat layer has already made this process
	// DRM master (logind's session does, via the VT it owns). When it is
	// false this file calls SET_MASTER itself, gated on drm_live.
	seat_master:   bool,
	// A seat layer that implements the logind VT handshake sets this so the
	// backend does not also try to take a VT. Informational.
	manages_vt:    bool,
}

// drm_set_seat installs the seat layer. seat.odin calls this once, before
// drm_init. Calling it with a zeroed Drm_Seat restores the direct-open
// fallback.
drm_set_seat :: proc(s: Drm_Seat) {
	drm_state.seat = s
}

// drm_pause is the PauseDevice signal: the session has gone to another VT, or
// logind is about to hand the device to someone else. Stop flipping and give
// up master. The buffers stay allocated — the GEM objects survive, and
// re-acquiring is then just a modeset.
drm_pause :: proc() {
	if drm_state.paused {
		return
	}
	drm_state.paused = true
	for c in drm_state.cards {
		for h in c.heads {
			h.awaiting_flip = false
			h.queued = -1
		}
		drm_drop_master(c)
	}
	drm_log("paused: master dropped on %d card(s)", len(drm_state.cards))
}

// drm_resume is the ResumeDevice signal. logind may hand back a fresh fd for
// the device; pass it, or -1 to keep the one we have. Every head's mode is set
// again, because whoever had the VT in between will have left the CRTCs
// pointing at their own framebuffers.
drm_resume :: proc(path := "", fd: linux.Fd = linux.Fd(-1)) {
	if !drm_state.paused {
		return
	}
	for c in drm_state.cards {
		if fd >= 0 && (path == "" || path == c.path) {
			c.fd = fd
			c.from_seat = true
		}
		if !drm_take_master(c) {
			drm_log("resume: could not become master on %s", c.path)
			continue
		}
		for h in c.heads {
			h.enabled = false
			if h.connected && h.have_mode {
				drm_modeset(h)
			}
		}
	}
	drm_state.paused = false
	drm_log("resumed: %d card(s) remoded", len(drm_state.cards))
}

// ----------------------------------------------------------------------------
// ioctl plumbing
// ----------------------------------------------------------------------------

@(private = "file")
drm_ioctl :: proc "contextless" (fd: linux.Fd, request: u32, arg: rawptr) -> (errno: i32) {
	for {
		r := i64(linux.ioctl(fd, request, uintptr(arg)))
		if r >= 0 {
			return 0
		}
		e := i32(-r)
		// EINTR/EAGAIN are routine on DRM: the kernel restarts long-running
		// mode ioctls this way. libdrm's drmIoctl does the same loop.
		if e == 4 || e == 11 {
			continue
		}
		return e
	}
}

@(private = "file")
drm_live_gate :: proc() -> bool {
	if !drm_state.live_read {
		drm_state.live_read = true
		drm_state.live = os.get_env("PALMY_WM_DRM_LIVE", context.temp_allocator) == "1"
		if !drm_state.live {
			drm_log("live output disabled (PALMY_WM_DRM_LIVE is not 1); enumeration only")
		}
	}
	return drm_state.live
}

// drm_enable_live opens the modeset gate for this process without the
// environment variable. It is what `wm --drm` calls: asking for the bare-metal
// backend on the command line is the explicit, per-run consent the variable
// stands for, and main.odin refuses --drm inside a graphical session before
// it gets here.
drm_enable_live :: proc() {
	drm_state.live_read = true
	drm_state.live = true
}

@(private = "file")
drm_log :: proc(f: string, args: ..any) {
	if !drm_state.verbose {
		return
	}
	fmt.eprintf("wm/drm: ")
	fmt.eprintfln(f, ..args)
}

@(private = "file")
drm_cstr :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n += 1
	}
	return string(b[:n])
}

// drm_now_ns is CLOCK_MONOTONIC, the clock page-flip events are stamped with
// (DRM_CAP_TIMESTAMP_MONOTONIC), so a deadline computed from an event's
// timestamp and one computed from now are on the same axis.
@(private = "file")
drm_now_ns :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

// ----------------------------------------------------------------------------
// Device discovery
// ----------------------------------------------------------------------------

// drm_list_cards returns the /dev/dri/card* nodes, in name order. The primary
// node is not card0 on every machine — on this one it is card1 — so nothing
// may assume an index.
drm_list_cards :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	infos, err := os.read_directory_by_path("/dev/dri", -1, context.temp_allocator)
	if err == nil {
		for fi in infos {
			if !strings.has_prefix(fi.name, "card") {
				continue
			}
			// card10 must sort after card9, but there are at most a handful
			// of nodes and the probe prints them all, so plain insertion by
			// numeric suffix is enough.
			n := drm_atoi(fi.name[4:])
			idx := len(out)
			for j in 0 ..< len(out) {
				if drm_atoi(out[j][len("/dev/dri/card"):]) > n {
					idx = j
					break
				}
			}
			inject_at(&out, idx, strings.concatenate({"/dev/dri/", fi.name}, allocator))
		}
	}
	if len(out) == 0 {
		// /dev/dri unreadable (a container without the bind mount, say).
		// Probe the conventional range rather than give up.
		for i in 0 ..< 8 {
			path := fmt.aprintf("/dev/dri/card%d", i, allocator = allocator)
			if fd, oerr := linux.open(
				strings.clone_to_cstring(path, context.temp_allocator),
				{.RDWR, .CLOEXEC},
			); oerr == .NONE {
				linux.close(fd)
				append(&out, path)
			} else {
				delete(path, allocator)
			}
		}
	}
	return out[:]
}

@(private = "file")
drm_atoi :: proc(s: string) -> int {
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' {
			break
		}
		n = n * 10 + int(ch - '0')
	}
	return n
}

// drm_open_card opens one node and fills in its capabilities. It does not take
// master and does not enumerate; drm_scan_card does that.
drm_open_card :: proc(path: string) -> (card: ^Drm_Card, err: string) {
	fd := linux.Fd(-1)
	from_seat := false
	if drm_state.seat.open != nil {
		if f, ok := drm_state.seat.open(path); ok {
			fd, from_seat = f, true
		}
	}
	if fd < 0 {
		// The weak fallback: open the node directly. In a logged-in session
		// the ACL on /dev/dri/card* grants the user rw, which is enough for
		// every enumeration ioctl and for dumb-buffer allocation.
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		f, oerr := linux.open(cpath, {.RDWR, .CLOEXEC})
		if oerr != .NONE {
			return nil, fmt.tprintf("%s: open failed (%v)", path, oerr)
		}
		fd = f
	}

	card = new(Drm_Card)
	card.fd = fd
	card.path = strings.clone(path)
	card.from_seat = from_seat
	card.prefer_bpp = 32

	ver := Drm_Version{}
	namebuf: [64]u8
	ver.name_len = len(namebuf)
	ver.name = raw_data(namebuf[:])
	if drm_ioctl(fd, DRM_IOCTL_VERSION, &ver) == 0 {
		card.driver = strings.clone(drm_cstr(namebuf[:min(int(ver.name_len), len(namebuf))]))
	}

	card.have_dumb = drm_cap(fd, DRM_CAP_DUMB_BUFFER) != 0
	card.monotonic = drm_cap(fd, DRM_CAP_TIMESTAMP_MONOTONIC) != 0
	card.crtc_in_vblank = drm_cap(fd, DRM_CAP_CRTC_IN_VBLANK_EVENT) != 0
	card.addfb2_modifiers = drm_cap(fd, DRM_CAP_ADDFB2_MODIFIERS) != 0
	if d := drm_cap(fd, DRM_CAP_DUMB_PREFERRED_DEPTH); d != 0 {
		card.prefer_bpp = d == 24 ? 32 : int(d)
	}
	return card, ""
}

drm_cap :: proc(fd: linux.Fd, cap: u64) -> u64 {
	req := Drm_Get_Cap {
		capability = cap,
	}
	if drm_ioctl(fd, DRM_IOCTL_GET_CAP, &req) != 0 {
		return 0
	}
	return req.value
}

drm_close_card :: proc(card: ^Drm_Card) {
	if card == nil {
		return
	}
	for h in card.heads {
		drm_head_free(h)
	}
	delete(card.heads)
	delete(card.crtcs)
	delete(card.encoders)
	delete(card.connectors)
	if card.master {
		drm_drop_master(card)
	}
	if card.from_seat && drm_state.seat.close != nil {
		drm_state.seat.close(card.path, card.fd)
	} else {
		linux.close(card.fd)
	}
	delete(card.path)
	delete(card.driver)
	free(card)
}

// ----------------------------------------------------------------------------
// Resource enumeration
//
// Every one of these works without master. They are the verification path: if
// a struct layout is wrong the kernel returns EINVAL or the counts come back
// absurd, and --drm-probe says so.
// ----------------------------------------------------------------------------

Drm_Resources :: struct {
	crtcs:        []u32,
	connectors:   []u32,
	encoders:     []u32,
	fbs:          []u32,
	min_w, max_w: int,
	min_h, max_h: int,
}

drm_get_resources :: proc(
	fd: linux.Fd,
	allocator := context.allocator,
) -> (
	res: Drm_Resources,
	ok: bool,
) {
	r := Drm_Mode_Card_Res{}
	if drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &r) != 0 {
		return {}, false
	}
	// The kernel fills the counts on the first pass with every pointer NULL,
	// then the arrays on the second. A hotplug between the two changes the
	// counts; the kernel refuses to fill an array whose length no longer
	// matches, so retry until the counts hold still.
	for attempt in 0 ..< 8 {
		crtcs := make([]u32, max(int(r.count_crtcs), 1), allocator)
		conns := make([]u32, max(int(r.count_connectors), 1), allocator)
		encs := make([]u32, max(int(r.count_encoders), 1), allocator)
		fbs := make([]u32, max(int(r.count_fbs), 1), allocator)

		want_crtcs, want_conns := r.count_crtcs, r.count_connectors
		want_encs, want_fbs := r.count_encoders, r.count_fbs

		q := Drm_Mode_Card_Res {
			crtc_id_ptr      = u64(uintptr(raw_data(crtcs))),
			connector_id_ptr = u64(uintptr(raw_data(conns))),
			encoder_id_ptr   = u64(uintptr(raw_data(encs))),
			fb_id_ptr        = u64(uintptr(raw_data(fbs))),
			count_crtcs      = want_crtcs,
			count_connectors = want_conns,
			count_encoders   = want_encs,
			count_fbs        = want_fbs,
		}
		if drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &q) != 0 {
			delete(crtcs, allocator);delete(conns, allocator)
			delete(encs, allocator);delete(fbs, allocator)
			return {}, false
		}
		if q.count_crtcs == want_crtcs &&
		   q.count_connectors == want_conns &&
		   q.count_encoders == want_encs {
			res.crtcs = crtcs[:q.count_crtcs]
			res.connectors = conns[:q.count_connectors]
			res.encoders = encs[:q.count_encoders]
			res.fbs = fbs[:min(q.count_fbs, want_fbs)]
			res.min_w, res.max_w = int(q.min_width), int(q.max_width)
			res.min_h, res.max_h = int(q.min_height), int(q.max_height)
			return res, true
		}
		delete(crtcs, allocator);delete(conns, allocator)
		delete(encs, allocator);delete(fbs, allocator)
		r = q
		_ = attempt
	}
	return {}, false
}

Drm_Conn_Info :: struct {
	id:          u32,
	kind:        u32,
	type_id:     u32,
	connection:  u32,
	mm_w, mm_h:  int,
	subpixel:    u32,
	encoder_id:  u32,
	encoders:    []u32,
	modes:       []Drm_Mode_Info,
	prop_ids:    []u32,
	prop_values: []u64,
}

// drm_get_connector re-probes one connector. Forcing a probe (count_modes=0)
// is only honoured for the current master and can block and flicker, so this
// never does it: it asks for the cached state, which is what a hotplug uevent
// has already refreshed.
drm_get_connector :: proc(
	fd: linux.Fd,
	id: u32,
	allocator := context.allocator,
) -> (
	info: Drm_Conn_Info,
	ok: bool,
) {
	probe := Drm_Mode_Get_Connector {
		connector_id = id,
	}
	// count_modes=1 with modes_ptr pointing at one scratch mode is the
	// documented way to read the counts without triggering a forced probe.
	scratch := Drm_Mode_Info{}
	probe.modes_ptr = u64(uintptr(&scratch))
	probe.count_modes = 1
	if drm_ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &probe) != 0 {
		return {}, false
	}

	for attempt in 0 ..< 8 {
		n_modes := int(probe.count_modes)
		n_props := int(probe.count_props)
		n_encs := int(probe.count_encoders)

		modes := make([]Drm_Mode_Info, max(n_modes, 1), allocator)
		props := make([]u32, max(n_props, 1), allocator)
		vals := make([]u64, max(n_props, 1), allocator)
		encs := make([]u32, max(n_encs, 1), allocator)

		q := Drm_Mode_Get_Connector {
			connector_id    = id,
			modes_ptr       = u64(uintptr(raw_data(modes))),
			props_ptr       = u64(uintptr(raw_data(props))),
			prop_values_ptr = u64(uintptr(raw_data(vals))),
			encoders_ptr    = u64(uintptr(raw_data(encs))),
			count_modes     = u32(n_modes),
			count_props     = u32(n_props),
			count_encoders  = u32(n_encs),
		}
		// count_modes == 0 would force a probe. A connector with no modes is
		// normal (nothing plugged in); pass 1 and ignore the scratch entry.
		if n_modes == 0 {
			q.modes_ptr = u64(uintptr(&scratch))
			q.count_modes = 1
		}
		if drm_ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &q) != 0 {
			delete(modes, allocator);delete(props, allocator)
			delete(vals, allocator);delete(encs, allocator)
			return {}, false
		}
		stable :=
			int(q.count_props) == n_props &&
			int(q.count_encoders) == n_encs &&
			(n_modes == 0 || int(q.count_modes) == n_modes)
		if stable {
			info.id = q.connector_id
			info.kind = q.connector_type
			info.type_id = q.connector_type_id
			info.connection = q.connection
			info.mm_w, info.mm_h = int(q.mm_width), int(q.mm_height)
			info.subpixel = q.subpixel
			info.encoder_id = q.encoder_id
			info.modes = n_modes == 0 ? modes[:0] : modes[:q.count_modes]
			info.prop_ids = props[:min(int(q.count_props), n_props)]
			info.prop_values = vals[:min(int(q.count_props), n_props)]
			info.encoders = encs[:min(int(q.count_encoders), n_encs)]
			return info, true
		}
		delete(modes, allocator);delete(props, allocator)
		delete(vals, allocator);delete(encs, allocator)
		probe = q
		_ = attempt
	}
	return {}, false
}

drm_get_encoder :: proc(fd: linux.Fd, id: u32) -> (enc: Drm_Mode_Get_Encoder, ok: bool) {
	enc.encoder_id = id
	if drm_ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &enc) != 0 {
		return {}, false
	}
	return enc, true
}

drm_get_crtc :: proc(fd: linux.Fd, id: u32) -> (c: Drm_Mode_Crtc, ok: bool) {
	c.crtc_id = id
	if drm_ioctl(fd, DRM_IOCTL_MODE_GETCRTC, &c) != 0 {
		return {}, false
	}
	return c, true
}

drm_get_property :: proc(fd: linux.Fd, id: u32) -> (name: string, flags: u32, ok: bool) {
	pr := Drm_Mode_Get_Property {
		prop_id = id,
	}
	if drm_ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &pr) != 0 {
		return "", 0, false
	}
	return strings.clone(drm_cstr(pr.name[:]), context.temp_allocator), pr.flags, true
}

// drm_get_blob reads a property blob — the EDID, a mode, a format list. Two
// passes: length first, then the bytes.
drm_get_blob :: proc(fd: linux.Fd, blob_id: u32, allocator := context.allocator) -> ([]u8, bool) {
	if blob_id == 0 {
		return nil, false
	}
	b := Drm_Mode_Get_Blob {
		blob_id = blob_id,
	}
	if drm_ioctl(fd, DRM_IOCTL_MODE_GETPROPBLOB, &b) != 0 || b.length == 0 {
		return nil, false
	}
	buf := make([]u8, int(b.length), allocator)
	b.data = u64(uintptr(raw_data(buf)))
	if drm_ioctl(fd, DRM_IOCTL_MODE_GETPROPBLOB, &b) != 0 {
		delete(buf, allocator)
		return nil, false
	}
	return buf[:min(int(b.length), len(buf))], true
}

// drm_conn_prop finds a connector property by name and returns its raw value.
drm_conn_prop :: proc(fd: linux.Fd, info: Drm_Conn_Info, want: string) -> (u64, bool) {
	for pid, i in info.prop_ids {
		name, _, ok := drm_get_property(fd, pid)
		if ok && name == want {
			return info.prop_values[i], true
		}
	}
	return 0, false
}

// ----------------------------------------------------------------------------
// EDID
//
// Only the base block is parsed, and only for a human-readable name: the
// monitor descriptor (0xFC) when the display provides one, otherwise the
// three-letter PNP manufacturer code packed five bits per letter plus the
// product code, which every EDID has.
// ----------------------------------------------------------------------------

Drm_Edid :: struct {
	valid:        bool,
	vendor:       string, // "DEL", "SDC" — three PNP letters
	product:      u16,
	serial:       u32,
	name:         string, // descriptor 0xFC, trimmed
	serial_text:  string, // descriptor 0xFF
	mm_w, mm_h:   int,
	year:         int,
	week:         int,
	extensions:   int,
	checksum_ok:  bool,
}

drm_parse_edid :: proc(data: []u8, allocator := context.allocator) -> (e: Drm_Edid) {
	if len(data) < 128 {
		return
	}
	magic := [8]u8{0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00}
	for i in 0 ..< 8 {
		if data[i] != magic[i] {
			return
		}
	}
	e.valid = true

	sum: u8 = 0
	for i in 0 ..< 128 {
		sum += data[i]
	}
	e.checksum_ok = sum == 0

	// Bytes 8..9: three letters, five bits each, big-endian, 'A' == 1.
	id := (u16(data[8]) << 8) | u16(data[9])
	letters: [3]u8
	letters[0] = u8((id >> 10) & 0x1f) + 'A' - 1
	letters[1] = u8((id >> 5) & 0x1f) + 'A' - 1
	letters[2] = u8(id & 0x1f) + 'A' - 1
	for i in 0 ..< 3 {
		if letters[i] < 'A' || letters[i] > 'Z' {
			letters[i] = '?'
		}
	}
	e.vendor = strings.clone(string(letters[:]), allocator)

	e.product = u16(data[10]) | (u16(data[11]) << 8)
	e.serial =
		u32(data[12]) | (u32(data[13]) << 8) | (u32(data[14]) << 16) | (u32(data[15]) << 24)
	e.week = int(data[16])
	e.year = int(data[17]) + 1990
	e.mm_w = int(data[21]) * 10
	e.mm_h = int(data[22]) * 10
	e.extensions = int(data[126])

	// Four 18-byte descriptors at 54. A descriptor whose first two bytes are
	// zero is a text block, not a detailed timing; byte 3 says which kind.
	for d in 0 ..< 4 {
		off := 54 + d * 18
		if off + 18 > len(data) {
			break
		}
		if data[off] != 0 || data[off + 1] != 0 || data[off + 2] != 0 {
			continue
		}
		tag := data[off + 3]
		if tag != 0xfc && tag != 0xff {
			continue
		}
		raw := data[off + 5:off + 18]
		n := 0
		for n < len(raw) && raw[n] != 0x0a {
			n += 1
		}
		txt := strings.clone(strings.trim_space(string(raw[:n])), allocator)
		if tag == 0xfc {
			if e.name != "" {
				// A name longer than 13 characters is split over two
				// descriptors; join them.
				joined := strings.concatenate({e.name, txt}, allocator)
				delete(e.name, allocator)
				delete(txt, allocator)
				e.name = joined
			} else {
				e.name = txt
			}
		} else {
			e.serial_text = txt
		}
	}
	return
}

// drm_edid_label is what to show a human: the descriptor name when there is
// one, otherwise vendor plus product code.
drm_edid_label :: proc(e: Drm_Edid, allocator := context.allocator) -> string {
	if !e.valid {
		return ""
	}
	if e.name != "" {
		return strings.clone(e.name, allocator)
	}
	return fmt.aprintf("%s %04X", e.vendor, e.product, allocator = allocator)
}

// ----------------------------------------------------------------------------
// Naming and mode helpers
// ----------------------------------------------------------------------------

drm_connector_type_name :: proc(kind: u32) -> string {
	switch kind {
	case 0:
		return "Unknown"
	case 1:
		return "VGA"
	case 2:
		return "DVI-I"
	case 3:
		return "DVI-D"
	case 4:
		return "DVI-A"
	case 5:
		return "Composite"
	case 6:
		return "SVIDEO"
	case 7:
		return "LVDS"
	case 8:
		return "Component"
	case 9:
		return "DIN"
	case 10:
		return "DP"
	case 11:
		return "HDMI-A"
	case 12:
		return "HDMI-B"
	case 13:
		return "TV"
	case 14:
		return "eDP"
	case 15:
		return "Virtual"
	case 16:
		return "DSI"
	case 17:
		return "DPI"
	case 18:
		return "Writeback"
	case 19:
		return "SPI"
	case 20:
		return "USB"
	}
	return "Unknown"
}

drm_connector_name :: proc(
	kind, type_id: u32,
	allocator := context.allocator,
) -> string {
	return fmt.aprintf(
		"%s-%d",
		drm_connector_type_name(kind),
		type_id,
		allocator = allocator,
	)
}

drm_encoder_type_name :: proc(kind: u32) -> string {
	switch kind {
	case 0:
		return "None"
	case 1:
		return "DAC"
	case 2:
		return "TMDS"
	case 3:
		return "LVDS"
	case 4:
		return "TVDAC"
	case 5:
		return "Virtual"
	case 6:
		return "DSI"
	case 7:
		return "DPMST"
	case 8:
		return "DPI"
	}
	return "?"
}

drm_connection_name :: proc(c: u32) -> string {
	switch c {
	case DRM_MODE_CONNECTED:
		return "connected"
	case DRM_MODE_DISCONNECTED:
		return "disconnected"
	}
	return "unknown"
}

// drm_mode_refresh_mhz is the vertical refresh in millihertz, computed from the
// timings rather than trusting `vrefresh`, which many drivers leave at zero.
drm_mode_refresh_mhz :: proc(m: Drm_Mode_Info) -> i64 {
	htotal := i64(m.htotal)
	vtotal := i64(m.vtotal)
	if htotal == 0 || vtotal == 0 {
		return i64(m.vrefresh) * 1000
	}
	// clock is in kHz. refresh = clock*1000 / (htotal*vtotal), in Hz.
	num := i64(m.clock) * 1_000_000
	den := htotal * vtotal
	if m.flags & DRM_MODE_FLAG_INTERLACE != 0 {
		num *= 2
	}
	if m.flags & DRM_MODE_FLAG_DBLSCAN != 0 {
		den *= 2
	}
	if m.vscan > 1 {
		den *= i64(m.vscan)
	}
	if den == 0 {
		return 0
	}
	return num / den
}

drm_mode_refresh_ns :: proc(m: Drm_Mode_Info) -> i64 {
	mhz := drm_mode_refresh_mhz(m)
	if mhz <= 0 {
		return 16_666_667
	}
	return 1_000_000_000_000 / mhz
}

// drm_pick_mode returns the index of the mode to drive a head with: the one
// the display flagged PREFERRED, else the largest, breaking ties on refresh.
drm_pick_mode :: proc(modes: []Drm_Mode_Info) -> int {
	best := -1
	for m, i in modes {
		if m.kind & DRM_MODE_TYPE_PREFERRED != 0 {
			return i
		}
		if best < 0 {
			best = i
			continue
		}
		b := modes[best]
		area := int(m.hdisplay) * int(m.vdisplay)
		barea := int(b.hdisplay) * int(b.vdisplay)
		if area > barea || (area == barea && drm_mode_refresh_mhz(m) > drm_mode_refresh_mhz(b)) {
			best = i
		}
	}
	return best
}

// ----------------------------------------------------------------------------
// Scanning: connectors to heads
// ----------------------------------------------------------------------------

// drm_scan_card (re)reads the card's resources and syncs the head list against
// what is actually plugged in. It is idempotent: calling it after a hotplug
// adds heads for newly connected connectors and tears down the ones that went
// away, leaving untouched heads — and their framebuffers — alone.
drm_scan_card :: proc(card: ^Drm_Card) -> (changed: bool) {
	res, ok := drm_get_resources(card.fd, context.temp_allocator)
	if !ok {
		return false
	}
	clear(&card.crtcs)
	clear(&card.encoders)
	clear(&card.connectors)
	append(&card.crtcs, ..res.crtcs)
	append(&card.encoders, ..res.encoders)
	append(&card.connectors, ..res.connectors)
	card.max_w, card.max_h = res.max_w, res.max_h

	seen := make(map[u32]bool, len(res.connectors), context.temp_allocator)

	for cid in res.connectors {
		info, iok := drm_get_connector(card.fd, cid, context.temp_allocator)
		if !iok {
			continue
		}
		seen[cid] = true
		connected := info.connection == DRM_MODE_CONNECTED && len(info.modes) > 0

		h := drm_find_head(card, cid)
		if !connected {
			if h != nil && h.connected {
				drm_log("%s went away", h.name)
				h.connected = false
				drm_head_release_fbs(h)
				changed = true
			}
			continue
		}
		if h == nil {
			h = new(Drm_Head)
			h.card = card
			h.conn_id = cid
			h.scale = 1
			h.front, h.queued = -1, -1
			h.preferred = -1
			append(&card.heads, h)
			changed = true
		}
		if drm_head_refresh(h, info) {
			changed = true
		}
	}

	// A connector that vanished from the resource list entirely (a DP-MST
	// branch unplugging) takes its head with it.
	for i := len(card.heads) - 1; i >= 0; i -= 1 {
		if !seen[card.heads[i].conn_id] {
			drm_head_free(card.heads[i])
			ordered_remove(&card.heads, i)
			changed = true
		}
	}

	if changed {
		drm_layout_apply()
	}
	return changed
}

drm_find_head :: proc(card: ^Drm_Card, conn_id: u32) -> ^Drm_Head {
	for h in card.heads {
		if h.conn_id == conn_id {
			return h
		}
	}
	return nil
}

@(private = "file")
drm_head_refresh :: proc(h: ^Drm_Head, info: Drm_Conn_Info) -> (changed: bool) {
	card := h.card
	was := h.connected
	h.connected = true
	h.mm_w, h.mm_h = info.mm_w, info.mm_h
	h.subpixel = info.subpixel

	if h.name == "" {
		h.name = drm_connector_name(info.kind, info.type_id)
	}
	if h.monitor == "" {
		if blob_id, bok := drm_conn_prop(card.fd, info, "EDID"); bok && blob_id != 0 {
			if raw, rok := drm_get_blob(card.fd, u32(blob_id), context.temp_allocator); rok {
				e := drm_parse_edid(raw, context.temp_allocator)
				h.monitor = drm_edid_label(e)
				if e.valid && h.mm_w == 0 {
					h.mm_w, h.mm_h = e.mm_w, e.mm_h
				}
			}
		}
	}

	if h.modes == nil {
		h.modes = make([dynamic]Drm_Mode_Info)
	}
	old_count := len(h.modes)
	clear(&h.modes)
	append(&h.modes, ..info.modes)
	h.preferred = drm_pick_mode(h.modes[:])

	if !h.have_mode && h.preferred >= 0 {
		drm_head_set_mode_index(h, h.preferred)
		changed = true
	}
	if old_count != len(h.modes) || !was {
		changed = true
	}

	// Bind a CRTC. Prefer the one already driving this connector — on the
	// first scan that is whatever the previous master left in place, which
	// means a resume does not move the picture to a different pipe.
	if h.crtc_id == 0 {
		drm_bind_crtc(h, info)
		changed = true
	}
	return
}

drm_head_set_mode_index :: proc(h: ^Drm_Head, idx: int) {
	if idx < 0 || idx >= len(h.modes) {
		return
	}
	h.mode = h.modes[idx]
	h.have_mode = true
	h.refresh_ns = drm_mode_refresh_ns(h.mode)
	// The swap chain is mode-sized; changing the mode invalidates it.
	drm_head_release_fbs(h)
}

@(private = "file")
drm_bind_crtc :: proc(h: ^Drm_Head, info: Drm_Conn_Info) {
	card := h.card

	try :: proc(card: ^Drm_Card, h: ^Drm_Head, crtc_id: u32) -> bool {
		if crtc_id == 0 {
			return false
		}
		for id, i in card.crtcs {
			if id != crtc_id {
				continue
			}
			if card.crtcs_taken & (1 << u32(i)) != 0 {
				return false
			}
			card.crtcs_taken |= 1 << u32(i)
			h.crtc_id = crtc_id
			h.crtc_index = i
			if c, ok := drm_get_crtc(card.fd, crtc_id); ok {
				h.saved_crtc = c
				h.saved_valid = true
			}
			return true
		}
		return false
	}

	// 1. The encoder currently attached to this connector, and its CRTC.
	if info.encoder_id != 0 {
		if enc, ok := drm_get_encoder(card.fd, info.encoder_id); ok {
			h.enc_id = enc.encoder_id
			if try(card, h, enc.crtc_id) {
				return
			}
		}
	}
	// 2. Any CRTC any of this connector's possible encoders can drive.
	for eid in info.encoders {
		enc, ok := drm_get_encoder(card.fd, eid)
		if !ok {
			continue
		}
		for id, i in card.crtcs {
			if enc.possible_crtcs & (1 << u32(i)) == 0 {
				continue
			}
			if card.crtcs_taken & (1 << u32(i)) != 0 {
				continue
			}
			h.enc_id = eid
			card.crtcs_taken |= 1 << u32(i)
			h.crtc_id = id
			h.crtc_index = i
			if c, cok := drm_get_crtc(card.fd, id); cok {
				h.saved_crtc = c
				h.saved_valid = true
			}
			return
		}
	}
	drm_log("%s: no free CRTC", h.name)
}

@(private = "file")
drm_head_free :: proc(h: ^Drm_Head) {
	drm_head_release_fbs(h)
	if h.card != nil && h.crtc_id != 0 {
		h.card.crtcs_taken &~= 1 << u32(h.crtc_index)
	}
	delete(h.modes)
	delete(h.name)
	delete(h.monitor)
	free(h)
}

// ----------------------------------------------------------------------------
// Layout
//
// Heads sit side by side in a global logical space, in the order they were
// scanned, which is connector order and therefore stable across a restart.
// A config layer can overwrite x/y afterwards; nothing here depends on the
// heads being contiguous or non-overlapping.
// ----------------------------------------------------------------------------

drm_layout_apply :: proc() {
	x := 0
	for c in drm_state.cards {
		for h in c.heads {
			if !h.connected || !h.have_mode {
				continue
			}
			h.x = x
			h.y = 0
			if h.scale <= 0 {
				h.scale = 1
			}
			x += int(f32(h.mode.hdisplay) / h.scale)
		}
	}
}

// drm_layout_extent is the bounding box of every enabled head, in logical
// pixels. The compositor's workspace coordinate space is this big.
drm_layout_extent :: proc() -> (w, h: int) {
	for c in drm_state.cards {
		for head in c.heads {
			if !head.connected || !head.have_mode {
				continue
			}
			s := head.scale <= 0 ? f32(1) : head.scale
			w = max(w, head.x + int(f32(head.mode.hdisplay) / s))
			h = max(h, head.y + int(f32(head.mode.vdisplay) / s))
		}
	}
	return
}

// drm_head_at maps a point in the global layout to the head under it.
drm_head_at :: proc(x, y: int) -> ^Drm_Head {
	for c in drm_state.cards {
		for h in c.heads {
			if !h.connected || !h.have_mode {
				continue
			}
			s := h.scale <= 0 ? f32(1) : h.scale
			w := int(f32(h.mode.hdisplay) / s)
			ht := int(f32(h.mode.vdisplay) / s)
			if x >= h.x && x < h.x + w && y >= h.y && y < h.y + ht {
				return h
			}
		}
	}
	return nil
}

// drm_heads flattens every card's heads into one list, which is what the
// compositor iterates to draw a frame.
drm_heads :: proc(allocator := context.temp_allocator) -> []^Drm_Head {
	out := make([dynamic]^Drm_Head, allocator)
	for c in drm_state.cards {
		for h in c.heads {
			if h.connected {
				append(&out, h)
			}
		}
	}
	return out[:]
}

// ----------------------------------------------------------------------------
// Dumb buffers
// ----------------------------------------------------------------------------

@(private = "file")
drm_fb_create :: proc(card: ^Drm_Card, w, h: int, fb: ^Drm_Fb) -> (err: string) {
	req := Drm_Mode_Create_Dumb {
		width  = u32(w),
		height = u32(h),
		bpp    = 32,
	}
	if e := drm_ioctl(card.fd, DRM_IOCTL_MODE_CREATE_DUMB, &req); e != 0 {
		return fmt.tprintf("CREATE_DUMB %dx%d: errno %d", w, h, e)
	}
	fb.handle = req.handle
	fb.pitch = req.pitch
	fb.size = req.size
	fb.w, fb.h = w, h
	fb.stride_px = int(req.pitch) / 4

	mreq := Drm_Mode_Map_Dumb {
		handle = fb.handle,
	}
	if e := drm_ioctl(card.fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq); e != 0 {
		drm_fb_destroy(card, fb)
		return fmt.tprintf("MAP_DUMB: errno %d", e)
	}
	mem, merr := linux.mmap(0, uint(fb.size), {.READ, .WRITE}, {.SHARED}, card.fd, i64(mreq.offset))
	if merr != .NONE {
		drm_fb_destroy(card, fb)
		return fmt.tprintf("mmap of %d bytes: %v", fb.size, merr)
	}
	fb.mem = mem
	fb.px = ([^]u32)(mem)[:int(fb.size) / 4]
	// A dumb buffer is not guaranteed zeroed on every driver, and a frame of
	// uninitialised VRAM on screen is somebody's old window.
	for i in 0 ..< len(fb.px) {
		fb.px[i] = 0xff00_0000
	}

	// XRGB8888 and not ARGB8888: the rasterizer sets the top byte to 0xff but
	// the scanout must not treat it as per-pixel alpha against the CRTC
	// background, which on some drivers it would.
	cmd := Drm_Mode_Fb_Cmd2 {
		width        = u32(w),
		height       = u32(h),
		pixel_format = DRM_FORMAT_XRGB8888,
	}
	cmd.handles[0] = fb.handle
	cmd.pitches[0] = fb.pitch
	if e := drm_ioctl(card.fd, DRM_IOCTL_MODE_ADDFB2, &cmd); e != 0 {
		drm_fb_destroy(card, fb)
		return fmt.tprintf("ADDFB2: errno %d", e)
	}
	fb.fb_id = cmd.fb_id
	return ""
}

@(private = "file")
drm_fb_destroy :: proc(card: ^Drm_Card, fb: ^Drm_Fb) {
	if fb.fb_id != 0 {
		id := fb.fb_id
		drm_ioctl(card.fd, DRM_IOCTL_MODE_RMFB, &id)
		fb.fb_id = 0
	}
	if fb.mem != nil {
		linux.munmap(fb.mem, uint(fb.size))
		fb.mem = nil
		fb.px = nil
	}
	if fb.handle != 0 && !fb.anon {
		d := Drm_Mode_Destroy_Dumb {
			handle = fb.handle,
		}
		drm_ioctl(card.fd, DRM_IOCTL_MODE_DESTROY_DUMB, &d)
		fb.handle = 0
	}
}

// drm_head_alloc_fbs builds the swap chain for a head's current mode. Safe
// without master: CREATE_DUMB and ADDFB2 are not master-gated, and a
// framebuffer object that is never handed to a CRTC is invisible.
drm_head_alloc_fbs :: proc(h: ^Drm_Head) -> (err: string) {
	if !h.have_mode {
		return "no mode"
	}
	w, ht := int(h.mode.hdisplay), int(h.mode.vdisplay)
	if h.fbs[0].px != nil && h.fbs[0].w == w && h.fbs[0].h == ht {
		return ""
	}
	drm_head_release_fbs(h)
	for i in 0 ..< DRM_BUFFERS {
		if e := drm_fb_create(h.card, w, ht, &h.fbs[i]); e != "" {
			drm_head_release_fbs(h)
			return e
		}
	}
	h.back, h.front, h.queued = 0, -1, -1
	drm_head_bind_canvas(h)
	return ""
}

// drm_head_bind_canvas points the head's canvas at the buffer the rasterizer
// should write into.
//
// When the driver's pitch is exactly width*4 the canvas aliases the mapping
// and `draw()` writes straight into scanout memory, which is the whole point.
// When it is padded — and drivers do pad, to 64 or 256 bytes — p.Canvas cannot
// represent it, because it indexes px[y*w+x] with no stride. Rather than touch
// palmy, the head keeps a tightly packed shadow and drm_present blits.
drm_head_bind_canvas :: proc(h: ^Drm_Head) {
	fb := &h.fbs[h.back]
	w, ht := fb.w, fb.h
	if w == 0 || ht == 0 {
		return
	}
	if h.canvas_ready {
		p.canvas_destroy(&h.canvas)
		h.canvas_ready = false
	}
	if fb.stride_px == w {
		h.canvas = p.canvas_from(fb.px[:w * ht], w, ht, h.scale <= 0 ? 1 : h.scale)
	} else {
		if len(h.shadow) != w * ht {
			delete(h.shadow)
			h.shadow = make([]u32, w * ht)
		}
		h.canvas = p.canvas_from(h.shadow, w, ht, h.scale <= 0 ? 1 : h.scale)
	}
	h.canvas_ready = true
}

drm_head_release_fbs :: proc(h: ^Drm_Head) {
	if h.canvas_ready {
		p.canvas_destroy(&h.canvas)
		h.canvas_ready = false
	}
	for i in 0 ..< DRM_BUFFERS {
		if h.card != nil {
			drm_fb_destroy(h.card, &h.fbs[i])
		}
		h.fbs[i] = {}
	}
	delete(h.shadow)
	h.shadow = nil
	h.back, h.front, h.queued = 0, -1, -1
	h.awaiting_flip = false
}

// ----------------------------------------------------------------------------
// Drawing and presenting
// ----------------------------------------------------------------------------

// drm_begin_frame hands back the canvas for this head's back buffer, or nil
// when the head is not ready to take one — no mode, no buffers, paused, or
// still waiting for the kernel to finish the last flip.
drm_begin_frame :: proc(h: ^Drm_Head) -> ^p.Canvas {
	if h == nil || !h.connected || !h.have_mode || drm_state.paused {
		return nil
	}
	if h.fbs[0].px == nil {
		if e := drm_head_alloc_fbs(h); e != "" {
			drm_log("%s: %s", h.name, e)
			return nil
		}
	}
	if !drm_head_free_buffer(h) {
		return nil
	}
	if !h.canvas_ready {
		drm_head_bind_canvas(h)
	}
	p.reset_clip(&h.canvas)
	return &h.canvas
}

// drm_head_free_buffer advances `back` to a buffer that is neither on screen
// nor queued. With DRM_BUFFERS == 3 this only fails when two flips are
// outstanding, which the kernel does not allow anyway.
@(private = "file")
drm_head_free_buffer :: proc(h: ^Drm_Head) -> bool {
	for i in 0 ..< DRM_BUFFERS {
		if i == h.front || i == h.queued {
			continue
		}
		if i != h.back {
			h.back = i
			drm_head_bind_canvas(h)
		}
		return true
	}
	return false
}

// drm_present puts the back buffer on screen.
//
// Legacy DRM_IOCTL_MODE_PAGE_FLIP, not an atomic commit. The reasons:
//
//   - This compositor has exactly one plane's worth of content per output. It
//     has no overlays, no hardware cursor plane yet, no per-plane scaling, and
//     no explicit fences to hand the kernel. Everything atomic buys is
//     something it does not do.
//   - Atomic means hand-rolling the property tables: OBJ_GETPROPERTIES on
//     every CRTC, connector and plane, a CREATEPROPBLOB for each mode, and
//     four parallel arrays per commit. That is a few hundred lines of C-free
//     plumbing whose only payoff today is tidiness.
//   - The failure mode matters here. A legacy flip that the driver rejects
//     returns EINVAL and leaves the screen exactly as it was. An atomic commit
//     with ALLOW_MODESET that goes wrong blanks outputs.
//
// The seam for atomic is drm_modeset and this procedure: both already take a
// head and nothing else, so adding Drm_Commit_Mode later changes two bodies.
drm_present :: proc(h: ^Drm_Head) -> bool {
	return drm_present_clip(h, {}, true)
}

// drm_back_fb is drm_begin_frame for a caller that writes the buffer itself,
// rows of fb.stride_px pixels, rather than through the head's canvas: the
// damage-tracked path in bare.odin, which copies only what changed. nil when
// the head cannot take a frame.
drm_back_fb :: proc(h: ^Drm_Head) -> ^Drm_Fb {
	if h == nil || !h.connected || !h.have_mode || drm_state.paused {
		return nil
	}
	if h.fbs[0].px == nil {
		if e := drm_head_alloc_fbs(h); e != "" {
			drm_log("%s: %s", h.name, e)
			return nil
		}
	}
	if !drm_head_free_buffer(h) {
		return nil
	}
	return &h.fbs[h.back]
}

// drm_present_clip presents the back buffer. `clip` (x, y, w, h in the
// head's pixels; all zero for the whole buffer) is the region that changed:
// it becomes the DIRTYFB clip on the no-flip path, so a virtual GPU copies
// only that to its host. `from_canvas` says the pixels are in the head's
// canvas (drm_begin_frame), which must still be blitted when it is a shadow.
drm_present_clip :: proc(h: ^Drm_Head, clip: [4]int, from_canvas: bool) -> bool {
	if h == nil || !h.have_mode || h.fbs[0].px == nil {
		return false
	}
	fb := &h.fbs[h.back]
	h.clip = clip

	// Padded pitch: copy the packed shadow into the buffer a row at a time.
	if from_canvas && fb.stride_px != fb.w {
		src := h.shadow
		for y in 0 ..< fb.h {
			copy(fb.px[y * fb.stride_px:][:fb.w], src[y * fb.w:][:fb.w])
		}
	}

	if !drm_live_gate() || drm_state.paused {
		// Development and headless: the pixels are correct and in the buffer,
		// but nothing is handed to a CRTC. This is the branch that keeps the
		// user's session alive while this file is being written.
		h.front = h.back
		h.frames += 1
		h.last_flip_ns = drm_now_ns()
		return true
	}

	if !h.enabled {
		if !drm_modeset(h) {
			return false
		}
	}
	if h.awaiting_flip {
		h.missed += 1
		return false
	}
	if h.card.no_flip {
		return drm_present_noflip(h)
	}

	req := Drm_Mode_Crtc_Page_Flip {
		crtc_id   = h.crtc_id,
		fb_id     = fb.fb_id,
		flags     = DRM_MODE_PAGE_FLIP_EVENT,
		user_data = u64(uintptr(h)),
	}
	if e := drm_ioctl(h.card.fd, DRM_IOCTL_MODE_PAGE_FLIP, &req); e != 0 {
		drm_log("%s: PAGE_FLIP errno %d", h.name, e)
		// EACCES means master was taken away between the pause signal and
		// here. Treat it as a pause rather than spinning on a dead CRTC.
		if e == 13 {
			drm_pause()
			return false
		}
		// EINVAL or ENOSYS from a driver without page flip (simpledrm,
		// some fbdev-era KMS drivers). EBUSY is a flip already in flight,
		// which the bookkeeping above should have prevented; either way the
		// frame is still worth showing, so show it the slow way.
		if e != 16 {
			drm_log("%s: page flip unsupported, falling back to SETCRTC + DIRTYFB", h.name)
			h.card.no_flip = true
			return drm_present_noflip(h)
		}
		return false
	}
	h.queued = h.back
	h.awaiting_flip = true
	h.flip_sent_ns = drm_now_ns()
	return true
}

// drm_present_noflip shows the back buffer without a page flip: point the
// CRTC at it with SETCRTC — on an atomic driver with the same mode that is a
// plane update, not a modeset — then DIRTYFB so a virtual GPU copies the
// pixels to wherever its scanout really lives. Synchronous, so there is no
// event to wait for and the buffer is on screen when this returns.
@(private = "file")
drm_present_noflip :: proc(h: ^Drm_Head) -> bool {
	fb := &h.fbs[h.back]
	conn := h.conn_id
	req := Drm_Mode_Crtc {
		crtc_id            = h.crtc_id,
		fb_id              = fb.fb_id,
		set_connectors_ptr = u64(uintptr(&conn)),
		count_connectors   = 1,
		mode               = h.mode,
		mode_valid         = 1,
	}
	if e := drm_ioctl(h.card.fd, DRM_IOCTL_MODE_SETCRTC, &req); e != 0 {
		drm_log("%s: SETCRTC (no-flip present) errno %d", h.name, e)
		if e == 13 {
			drm_pause()
		}
		return false
	}
	drm_dirty(h.card, fb.fb_id, h.clip)
	h.front = h.back
	h.queued = -1
	h.frames += 1
	h.last_flip_ns = drm_now_ns()
	return true
}

// drm_dirty flushes a whole framebuffer. ENOSYS means the driver scans out of
// the buffer directly and needs no flush, which is the common case on real
// hardware; nothing else is worth reporting more than once.
drm_dirty :: proc(card: ^Drm_Card, fb_id: u32, clip: [4]int = {}) {
	cmd := Drm_Mode_Fb_Dirty_Cmd {
		fb_id = fb_id,
	}
	// struct drm_clip_rect: x1, y1, x2, y2 as u16. One rectangle: the damage
	// bounding box. The kernel copies only that much to the host.
	r: [4]u16
	if clip[2] > 0 && clip[3] > 0 {
		r = {u16(clip[0]), u16(clip[1]), u16(clip[0] + clip[2]), u16(clip[1] + clip[3])}
		cmd.num_clips = 1
		cmd.clips_ptr = u64(uintptr(&r))
	}
	drm_ioctl(card.fd, DRM_IOCTL_MODE_DIRTYFB, &cmd)
	drm_state.dirty_calls += 1
	if cmd.num_clips > 0 {
		drm_state.dirty_px += u64(clip[2] * clip[3])
	}
}

// drm_modeset programs the mode. Gated: this is the call that would take over
// the user's display.
drm_modeset :: proc(h: ^Drm_Head) -> bool {
	if !drm_live_gate() || drm_state.paused {
		return false
	}
	if h.crtc_id == 0 || h.fbs[0].fb_id == 0 {
		return false
	}
	if !h.card.master && !drm_take_master(h.card) {
		return false
	}
	conn := h.conn_id
	req := Drm_Mode_Crtc {
		crtc_id            = h.crtc_id,
		fb_id              = h.fbs[h.back].fb_id,
		set_connectors_ptr = u64(uintptr(&conn)),
		count_connectors   = 1,
		mode               = h.mode,
		mode_valid         = 1,
	}
	if e := drm_ioctl(h.card.fd, DRM_IOCTL_MODE_SETCRTC, &req); e != 0 {
		drm_log("%s: SETCRTC errno %d", h.name, e)
		return false
	}
	h.enabled = true
	h.front = h.back
	drm_dirty(h.card, h.fbs[h.back].fb_id)
	drm_log("%s: mode %s set on crtc %d", h.name, drm_cstr(h.mode.name[:]), h.crtc_id)
	return true
}

// drm_restore puts back whatever the previous master had on each CRTC. Called
// on shutdown so quitting the compositor leaves a usable console.
drm_restore :: proc() {
	if !drm_live_gate() {
		return
	}
	for c in drm_state.cards {
		for h in c.heads {
			if !h.saved_valid || h.saved_crtc.mode_valid == 0 {
				continue
			}
			conn := h.conn_id
			req := h.saved_crtc
			req.set_connectors_ptr = u64(uintptr(&conn))
			req.count_connectors = 1
			drm_ioctl(c.fd, DRM_IOCTL_MODE_SETCRTC, &req)
			h.enabled = false
		}
	}
}

// ----------------------------------------------------------------------------
// Master
// ----------------------------------------------------------------------------

drm_take_master :: proc(card: ^Drm_Card) -> bool {
	if card.master {
		return true
	}
	if drm_state.seat.seat_master {
		// logind's session already owns the VT and therefore master; asking
		// again is at best redundant and at worst steals it from ourselves.
		card.master = true
		return true
	}
	if !drm_live_gate() {
		return false
	}
	if e := drm_ioctl(card.fd, DRM_IOCTL_SET_MASTER, nil); e != 0 {
		drm_log("%s: SET_MASTER errno %d", card.path, e)
		return false
	}
	card.master = true
	return true
}

drm_drop_master :: proc(card: ^Drm_Card) {
	if !card.master {
		return
	}
	card.master = false
	if drm_state.seat.seat_master || !drm_live_gate() {
		return
	}
	drm_ioctl(card.fd, DRM_IOCTL_DROP_MASTER, nil)
}

// ----------------------------------------------------------------------------
// Events and the frame clock
// ----------------------------------------------------------------------------

// drm_poll_fds fills the caller's pollfd array with every fd this backend
// wants watched: each card (page-flip completions) and the uevent socket.
// Returns how many entries were written.
drm_poll_fds :: proc(buf: []linux.Poll_Fd) -> int {
	n := 0
	for c in drm_state.cards {
		if n >= len(buf) {
			return n
		}
		buf[n] = {
			fd     = c.fd,
			events = {.IN},
		}
		n += 1
	}
	if drm_state.uevent_fd > 0 && n < len(buf) {
		buf[n] = {
			fd     = drm_state.uevent_fd,
			events = {.IN},
		}
		n += 1
	}
	return n
}

// drm_dispatch drains the DRM fds and the uevent socket. Call it after poll()
// returns, or with a zero timeout in a busy loop. Returns true when something
// changed that the compositor should redraw for.
drm_dispatch :: proc() -> (redraw: bool) {
	buf: [4096]u8
	for c in drm_state.cards {
		for {
			pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
			n, perr := linux.poll(pfd[:], 0)
			if perr != .NONE || n <= 0 {
				break
			}
			got, rerr := linux.read(c.fd, buf[:])
			if rerr != .NONE || got <= 0 {
				break
			}
			if drm_handle_events(buf[:got]) {
				redraw = true
			}
		}
	}
	if drm_uevent_poll() {
		redraw = true
	}
	return
}

@(private = "file")
drm_handle_events :: proc(data: []u8) -> (redraw: bool) {
	off := 0
	for off + size_of(Drm_Event_Header) <= len(data) {
		hdr := (^Drm_Event_Header)(raw_data(data[off:]))^
		if hdr.length < u32(size_of(Drm_Event_Header)) || off + int(hdr.length) > len(data) {
			break
		}
		switch hdr.kind {
		case DRM_EVENT_FLIP_COMPLETE, DRM_EVENT_VBLANK:
			if int(hdr.length) >= size_of(Drm_Event_Vblank) {
				ev := (^Drm_Event_Vblank)(raw_data(data[off:]))^
				if drm_flip_done(ev) {
					redraw = true
				}
			}
		}
		off += int(hdr.length)
	}
	return
}

@(private = "file")
drm_flip_done :: proc(ev: Drm_Event_Vblank) -> bool {
	// user_data is the head pointer we put in the flip request. Trusting a
	// pointer round-tripped through the kernel is fine — it is our own fd —
	// but it is still checked against the head list before use, because a
	// stale event can arrive after a head has been torn down.
	target := rawptr(uintptr(ev.user_data))
	for c in drm_state.cards {
		for h in c.heads {
			if rawptr(h) != target && !(ev.crtc_id != 0 && ev.crtc_id == h.crtc_id) {
				continue
			}
			h.awaiting_flip = false
			if h.queued >= 0 {
				h.front = h.queued
				h.queued = -1
			}
			h.frames += 1
			// tv_sec/tv_usec are CLOCK_MONOTONIC when DRM_CAP_TIMESTAMP_MONOTONIC
			// is set, which it always is on a kernel from this decade.
			h.last_flip_ns = i64(ev.tv_sec) * 1_000_000_000 + i64(ev.tv_usec) * 1_000
			return true
		}
	}
	return false
}

// drm_head_ready is the vblank-paced frame clock: true when this head can take
// another frame. With a flip outstanding the answer is no, and the main loop
// should go back to poll() rather than rasterize a frame nobody will see.
drm_head_ready :: proc(h: ^Drm_Head) -> bool {
	if h == nil || !h.connected || !h.have_mode || drm_state.paused {
		return false
	}
	if h.awaiting_flip {
		// A completion that has not arrived in half a second is not going
		// to. Some virtual GPUs accept PAGE_FLIP and never send the event;
		// waiting for it forever would freeze the screen on the first frame.
		if h.flip_sent_ns != 0 && drm_now_ns() - h.flip_sent_ns > 500_000_000 {
			drm_log("%s: no page-flip event after 500 ms; falling back to SETCRTC + DIRTYFB", h.name)
			h.card.no_flip = true
			h.awaiting_flip = false
			if h.queued >= 0 {
				h.front = h.queued
				h.queued = -1
			}
			return true
		}
		return false
	}
	return true
}

// drm_next_deadline_ms is how long poll() may sleep before the next head wants
// a frame: -1 when nothing is animating and every head is idle.
drm_next_deadline_ms :: proc(animating: bool) -> i32 {
	if !animating {
		return -1
	}
	best := i64(max(i32))
	now := drm_now_ns()
	for c in drm_state.cards {
		for h in c.heads {
			if !h.connected || !h.have_mode || h.awaiting_flip {
				continue
			}
			due := h.last_flip_ns + h.refresh_ns
			ms := (due - now) / 1_000_000
			best = min(best, max(ms, 0))
		}
	}
	if best == i64(max(i32)) {
		return -1
	}
	return i32(best)
}

// ----------------------------------------------------------------------------
// Hotplug
//
// Two mechanisms, either of which is enough:
//
//   - drm_recheck re-probes every connector with GETCONNECTOR. It needs no
//     master and no extra fd, so it works everywhere; call it on a timer or
//     after a suspend/resume.
//   - A NETLINK_KOBJECT_UEVENT socket, which is the thing udev reads. It is
//     read-only, needs no privileges for the kernel group, and turns the
//     re-probe from a poll into an event. drm_uevent_open brings it up.
// ----------------------------------------------------------------------------

@(private = "file")
DRM_AF_NETLINK :: 16
@(private = "file")
DRM_SOCK_DGRAM :: 2
@(private = "file")
DRM_SOCK_NONBLOCK :: 0o4000
@(private = "file")
DRM_SOCK_CLOEXEC :: 0o2000000
@(private = "file")
DRM_NETLINK_KOBJECT_UEVENT :: 15

@(private = "file")
Drm_Sockaddr_Nl :: struct {
	family: u16,
	pad:    u16,
	pid:    u32,
	groups: u32,
}

// drm_uevent_open joins the kernel's uevent multicast group. Read-only: the
// socket is never written to, and nothing here acts on a uevent except by
// re-probing connectors.
drm_uevent_open :: proc() -> bool {
	if drm_state.uevent_fd > 0 {
		return true
	}
	r := linux.syscall(
		linux.SYS_socket,
		uintptr(DRM_AF_NETLINK),
		uintptr(DRM_SOCK_DGRAM | DRM_SOCK_NONBLOCK | DRM_SOCK_CLOEXEC),
		uintptr(DRM_NETLINK_KOBJECT_UEVENT),
	)
	if r < 0 {
		return false
	}
	fd := linux.Fd(i32(r))
	addr := Drm_Sockaddr_Nl {
		family = DRM_AF_NETLINK,
		pid    = 0, // let the kernel assign; two compositors must not collide
		groups = 1, // group 1 is the kernel's own uevents
	}
	if b := linux.syscall(linux.SYS_bind, uintptr(fd), uintptr(&addr), uintptr(size_of(addr)));
	   b < 0 {
		linux.close(fd)
		return false
	}
	drm_state.uevent_fd = fd
	return true
}

drm_uevent_close :: proc() {
	if drm_state.uevent_fd > 0 {
		linux.close(drm_state.uevent_fd)
		drm_state.uevent_fd = 0
	}
}

// drm_uevent_poll drains the socket. A DRM hotplug looks like
//
//	change@/devices/.../drm/card1\0ACTION=change\0SUBSYSTEM=drm\0HOTPLUG=1\0...
//
// NUL-separated key=value after the first line. Anything that is not a DRM
// hotplug is discarded without allocating.
drm_uevent_poll :: proc() -> (changed: bool) {
	if drm_state.uevent_fd <= 0 {
		return false
	}
	buf: [8192]u8
	for {
		pfd := [1]linux.Poll_Fd{{fd = drm_state.uevent_fd, events = {.IN}}}
		n, perr := linux.poll(pfd[:], 0)
		if perr != .NONE || n <= 0 {
			break
		}
		got, rerr := linux.read(drm_state.uevent_fd, buf[:])
		if rerr != .NONE || got <= 0 {
			break
		}
		if drm_uevent_is_hotplug(buf[:got]) {
			drm_state.hotplug = true
		}
	}
	if drm_state.hotplug {
		drm_state.hotplug = false
		changed = drm_recheck()
	}
	return
}

@(private = "file")
drm_uevent_is_hotplug :: proc(msg: []u8) -> bool {
	// libudev's own messages start with "libudev\0"; the kernel's do not, and
	// only the kernel's are trustworthy here.
	if len(msg) >= 8 && string(msg[:8]) == "libudev\x00" {
		return false
	}
	is_drm, is_hotplug := false, false
	start := 0
	for i in 0 ..< len(msg) {
		if msg[i] != 0 {
			continue
		}
		field := string(msg[start:i])
		start = i + 1
		switch field {
		case "SUBSYSTEM=drm":
			is_drm = true
		case "HOTPLUG=1":
			is_hotplug = true
		}
	}
	return is_drm && is_hotplug
}

// drm_recheck re-probes every connector on every card. Idempotent and
// master-free; this is the fallback when there is no uevent socket.
drm_recheck :: proc() -> (changed: bool) {
	for c in drm_state.cards {
		if drm_scan_card(c) {
			changed = true
		}
	}
	return
}

// ----------------------------------------------------------------------------
// Bring-up
// ----------------------------------------------------------------------------

Drm_Options :: struct {
	verbose:  bool,
	// When set, only this card is opened. Empty means: open every card that
	// has a connected connector.
	only:     string,
	// Open the netlink uevent socket for hotplug.
	hotplug:  bool,
}

// drm_init opens the cards, enumerates them and builds the heads. It does not
// modeset and does not take master: the first drm_present does that, and only
// with the live gate open.
drm_init :: proc(opt: Drm_Options = {}) -> (ok: bool, err: string) {
	if drm_state.active {
		return true, ""
	}
	drm_state.verbose = opt.verbose
	paths := drm_list_cards(context.temp_allocator)
	if len(paths) == 0 {
		return false, "no /dev/dri/card* nodes"
	}
	last_err := ""
	for path in paths {
		if opt.only != "" && path != opt.only {
			continue
		}
		card, cerr := drm_open_card(path)
		if cerr != "" {
			last_err = cerr
			continue
		}
		if !card.have_dumb {
			// A render-only node, or a GPU with no display engine. Nothing to
			// scan out on.
			drm_close_card(card)
			continue
		}
		drm_scan_card(card)
		if len(card.heads) == 0 {
			drm_close_card(card)
			continue
		}
		// PALMY_WM_DRM_NOFLIP=1 takes the path a card that refuses page flip
		// takes (SETCRTC + DIRTYFB) from the first frame, so that path can be
		// tested on hardware that does flip. qemu-test.sh --noflip sets it.
		if os.get_env("PALMY_WM_DRM_NOFLIP", context.temp_allocator) == "1" {
			card.no_flip = true
			drm_log("%s: page flip disabled by PALMY_WM_DRM_NOFLIP; presenting with SETCRTC + DIRTYFB", card.path)
		}
		append(&drm_state.cards, card)
	}
	if len(drm_state.cards) == 0 {
		return false, last_err != "" ? last_err : "no card with a connected output"
	}
	drm_layout_apply()
	if opt.hotplug {
		drm_uevent_open()
	}
	drm_state.active = true
	drm_live_gate()
	return true, ""
}

drm_shutdown :: proc() {
	if !drm_state.active {
		return
	}
	drm_restore()
	drm_uevent_close()
	for c in drm_state.cards {
		drm_close_card(c)
	}
	clear(&drm_state.cards)
	drm_state.active = false
}

// ----------------------------------------------------------------------------
// --drm-probe
//
// Everything below is the self-test. It runs the enumeration half against the
// real hardware and prints it, and it checks the arithmetic that cannot be
// checked any other way without master: struct layouts, mode selection, EDID
// parsing, the swap chain, the padded-pitch blit.
// ----------------------------------------------------------------------------

@(private = "file")
drm_checks: int
@(private = "file")
drm_fails: int

@(private = "file")
drm_check :: proc(cond: bool, f: string, args: ..any) {
	drm_checks += 1
	if !cond {
		drm_fails += 1
		fmt.printf("  FAIL: ")
		fmt.printfln(f, ..args)
	}
}

// The @(init) hook. main.odin belongs to another agent, so --drm-probe is
// intercepted here before main() runs rather than added to its argument loop.
// If main.odin ever grows its own case for it, calling drm_probe_main() does
// the same thing and this hook simply never sees the flag.
@(init)
drm_arg_hook :: proc "contextless" () {
	context = runtime.default_context()
	for a in runtime.args__ {
		s := string(a)
		if s == "--drm-probe" || s == "--drm-probe-alloc" || s == "--drm-probe-render" {
			os.exit(drm_probe_main())
		}
	}
}

// drm_probe_main enumerates every card and prints it. Nothing it does needs
// DRM master and nothing it does is visible on screen.
drm_probe_main :: proc() -> int {
	alloc := false
	render := ""
	for a, i in os.args {
		switch os.args[i] {
		case "--drm-probe-alloc":
			alloc = true
		case "--drm-probe-render":
			render = i + 1 < len(os.args) ? os.args[i + 1] : "/tmp/drm-probe.png"
		}
		_ = a
	}

	live := os.get_env("PALMY_WM_DRM_LIVE", context.temp_allocator) == "1"
	fmt.printfln("palmy wm — DRM probe")
	fmt.printfln(
		"  live output gate: %s (PALMY_WM_DRM_LIVE)",
		live ? "OPEN — this build would modeset" : "closed, enumeration only",
	)
	fmt.println()

	paths := drm_list_cards(context.temp_allocator)
	fmt.printfln("cards: %d", len(paths))
	for path in paths {
		drm_probe_card(path, alloc)
	}

	// Bring the real backend up: open the cards, scan, build the heads and
	// lay them out. None of that modesets or takes master.
	fmt.println()
	if ok, ierr := drm_init({verbose = true, hotplug = true}); !ok {
		fmt.printfln("heads: drm_init: %s", ierr)
	} else {
		defer drm_shutdown()
		hs := drm_heads(context.temp_allocator)
		lw, lh := drm_layout_extent()
		fmt.printfln("heads: %d, layout %dx%d logical px", len(hs), lw, lh)
		for h in hs {
			fmt.printfln(
				"  %-10s %-16q conn=%-3d enc=%-3d crtc=%-3d  %dx%d@%d.%03dHz  at %d,%d scale %.2f  %dmm x %dmm  frame %d ns",
				h.name,
				h.monitor,
				h.conn_id,
				h.enc_id,
				h.crtc_id,
				h.mode.hdisplay,
				h.mode.vdisplay,
				drm_mode_refresh_mhz(h.mode) / 1000,
				drm_mode_refresh_mhz(h.mode) % 1000,
				h.x,
				h.y,
				h.scale,
				h.mm_w,
				h.mm_h,
				h.refresh_ns,
			)
			drm_check(h.crtc_id != 0, "%s: no CRTC was bound", h.name)
			drm_check(h.have_mode, "%s: no mode was chosen", h.name)
			drm_check(h.refresh_ns > 1_000_000, "%s: implausible frame time %d ns", h.name, h.refresh_ns)
		}
		drm_check(len(hs) > 0, "drm_init found no heads")
		// Two CRTCs must never land on the same head.
		for a, i in hs {
			for b, j in hs {
				if i < j {
					drm_check(a.crtc_id != b.crtc_id, "%s and %s share CRTC %d", a.name, b.name, a.crtc_id)
				}
			}
		}
		fmt.printfln(
			"  hotplug: netlink uevent socket %s; a GETCONNECTOR re-probe is the fallback",
			drm_state.uevent_fd > 0 ? "open" : "unavailable",
		)
		// A re-probe with nothing unplugged must report no change, which is
		// what makes it safe to call on a timer.
		drm_check(!drm_recheck(), "an idle re-probe reported a change")
		pfds: [8]linux.Poll_Fd
		n := drm_poll_fds(pfds[:])
		fmt.printf("  poll set: %d fd(s) —", n)
		for i in 0 ..< n {
			fmt.printf(" %d", pfds[i].fd)
		}
		fmt.println()
		drm_check(n >= 1, "drm_poll_fds returned nothing to poll on")
		drm_check(!drm_dispatch(), "an idle dispatch reported a redraw")
	}

	fmt.println()
	drm_selftest()
	if render != "" {
		drm_probe_render(render)
	}

	fmt.println()
	fmt.printfln("%d checks, %d failed", drm_checks, drm_fails)
	return drm_fails == 0 ? 0 : 1
}

@(private = "file")
drm_probe_card :: proc(path: string, alloc: bool) {
	fmt.println()
	card, err := drm_open_card(path)
	if err != "" {
		fmt.printfln("%s: %s", path, err)
		return
	}
	defer drm_close_card(card)

	fmt.printfln("%s  driver=%s", path, card.driver == "" ? "?" : card.driver)
	fmt.printfln(
		"  caps: DUMB_BUFFER=%v TIMESTAMP_MONOTONIC=%v CRTC_IN_VBLANK_EVENT=%v ADDFB2_MODIFIERS=%v preferred_bpp=%d",
		card.have_dumb,
		card.monotonic,
		card.crtc_in_vblank,
		card.addfb2_modifiers,
		card.prefer_bpp,
	)

	res, ok := drm_get_resources(card.fd, context.temp_allocator)
	if !ok {
		fmt.printfln("  GETRESOURCES failed — not a KMS node")
		return
	}
	drm_check(len(res.crtcs) > 0, "%s: GETRESOURCES returned no CRTCs", path)
	fmt.printfln(
		"  resources: %d crtc, %d connector, %d encoder, fb %dx%d..%dx%d",
		len(res.crtcs),
		len(res.connectors),
		len(res.encoders),
		res.min_w,
		res.min_h,
		res.max_w,
		res.max_h,
	)

	for cid in res.crtcs {
		c, cok := drm_get_crtc(card.fd, cid)
		if !cok {
			fmt.printfln("  crtc %d: GETCRTC failed", cid)
			drm_check(false, "GETCRTC %d failed", cid)
			continue
		}
		if c.mode_valid != 0 {
			fmt.printfln(
				"  crtc %-3d fb=%-3d +%d+%d  active %s  %dx%d",
				c.crtc_id,
				c.fb_id,
				c.x,
				c.y,
				drm_cstr(c.mode.name[:]),
				c.mode.hdisplay,
				c.mode.vdisplay,
			)
		} else {
			fmt.printfln("  crtc %-3d fb=%-3d  (no mode)", c.crtc_id, c.fb_id)
		}
	}

	for eid in res.encoders {
		e, eok := drm_get_encoder(card.fd, eid)
		if !eok {
			drm_check(false, "GETENCODER %d failed", eid)
			continue
		}
		fmt.printfln(
			"  encoder %-3d %-6s crtc=%-3d possible_crtcs=0b%b possible_clones=0b%b",
			e.encoder_id,
			drm_encoder_type_name(e.encoder_type),
			e.crtc_id,
			e.possible_crtcs,
			e.possible_clones,
		)
	}

	for cid in res.connectors {
		drm_probe_connector(card, cid, alloc)
	}
}

@(private = "file")
drm_probe_connector :: proc(card: ^Drm_Card, cid: u32, alloc: bool) {
	info, ok := drm_get_connector(card.fd, cid, context.temp_allocator)
	if !ok {
		fmt.printfln("  connector %d: GETCONNECTOR failed", cid)
		drm_check(false, "GETCONNECTOR %d failed", cid)
		return
	}
	drm_check(
		info.id == cid,
		"GETCONNECTOR echoed id %d for %d — struct layout is wrong",
		info.id,
		cid,
	)
	name := drm_connector_name(info.kind, info.type_id, context.temp_allocator)
	fmt.println()
	fmt.printfln(
		"  connector %-3d %-10s %-12s  %dmm x %dmm  encoder=%d  %d mode(s), %d prop(s), %d encoder(s)",
		info.id,
		name,
		drm_connection_name(info.connection),
		info.mm_w,
		info.mm_h,
		info.encoder_id,
		len(info.modes),
		len(info.prop_ids),
		len(info.encoders),
	)

	if blob_id, bok := drm_conn_prop(card.fd, info, "EDID"); bok && blob_id != 0 {
		if raw, rok := drm_get_blob(card.fd, u32(blob_id), context.temp_allocator); rok {
			e := drm_parse_edid(raw, context.temp_allocator)
			drm_check(e.valid, "%s: EDID blob %d has no magic header", name, blob_id)
			if e.valid {
				drm_check(e.checksum_ok, "%s: EDID base block checksum is wrong", name)
				fmt.printfln(
					"    EDID: %d bytes, %d extension(s), checksum %s",
					len(raw),
					e.extensions,
					e.checksum_ok ? "ok" : "BAD",
				)
				fmt.printfln(
					"    monitor: %q  vendor=%s product=%04X serial=%08X week %d %d  %dmm x %dmm",
					drm_edid_label(e, context.temp_allocator),
					e.vendor,
					e.product,
					e.serial,
					e.week,
					e.year,
					e.mm_w,
					e.mm_h,
				)
			}
		}
	} else if info.connection == DRM_MODE_CONNECTED {
		fmt.printfln("    EDID: none")
	}

	if len(info.modes) == 0 {
		return
	}
	pref := drm_pick_mode(info.modes)
	for m, i in info.modes {
		m := m
		mhz := drm_mode_refresh_mhz(m)
		flag := ""
		if m.kind & DRM_MODE_TYPE_PREFERRED != 0 {
			flag = " *preferred"
		}
		mark := i == pref ? "->" : "  "
		fmt.printfln(
			"    %s %-14s %-11s %3d.%03d Hz  clock=%-7d htotal=%-5d vtotal=%-5d flags=0x%x type=0x%x%s",
			mark,
			drm_cstr(m.name[:]),
			fmt.tprintf("%dx%d", m.hdisplay, m.vdisplay),
			mhz / 1000,
			mhz % 1000,
			m.clock,
			m.htotal,
			m.vtotal,
			m.flags,
			m.kind,
			flag,
		)
		drm_check(
			m.hdisplay > 0 && m.vdisplay > 0,
			"%s: mode %d has a zero dimension — modeinfo layout is wrong",
			name,
			i,
		)
		drm_check(
			m.htotal >= m.hdisplay && m.vtotal >= m.vdisplay,
			"%s: mode %s has totals below the display size",
			name,
			drm_cstr(m.name[:]),
		)
	}
	drm_check(pref >= 0, "%s: no mode chosen from %d", name, len(info.modes))

	if alloc && info.connection == DRM_MODE_CONNECTED {
		drm_probe_alloc(card, info.modes[max(pref, 0)], name)
	}
}

// drm_probe_alloc allocates one dumb buffer the size of the mode, maps it and
// registers it with ADDFB2, then tears it all down. No CRTC is touched, so the
// screen never sees it. This is the only way to find out whether ADDFB2 is
// master-gated on this kernel, and the answer is printed.
@(private = "file")
drm_probe_alloc :: proc(card: ^Drm_Card, mode: Drm_Mode_Info, name: string) {
	fb := Drm_Fb{}
	w, h := int(mode.hdisplay), int(mode.vdisplay)
	if e := drm_fb_create(card, w, h, &fb); e != "" {
		fmt.printfln("    buffer: %s", e)
		drm_check(false, "%s: dumb buffer %dx%d: %s", name, w, h, e)
		return
	}
	defer drm_fb_destroy(card, &fb)
	fmt.printfln(
		"    buffer: %dx%d handle=%d fb_id=%d pitch=%d (%d px, %s) size=%d",
		w,
		h,
		fb.handle,
		fb.fb_id,
		fb.pitch,
		fb.stride_px,
		fb.stride_px == w ? "tight — canvas aliases scanout" : "padded — canvas needs a shadow",
		fb.size,
	)
	drm_check(fb.fb_id != 0, "%s: ADDFB2 returned fb_id 0", name)
	drm_check(fb.stride_px >= w, "%s: pitch %d is narrower than the mode", name, fb.pitch)
	drm_check(
		fb.size >= u64(fb.pitch) * u64(h),
		"%s: dumb size %d is below pitch*height",
		name,
		fb.size,
	)
	// Write the far corner and read it back: proves the mapping covers the
	// whole buffer and that stride arithmetic lands inside it.
	last := (h - 1) * fb.stride_px + (w - 1)
	fb.px[last] = 0xff00_cc66
	drm_check(fb.px[last] == 0xff00_cc66, "%s: mapped buffer did not retain a write", name)
}

// ----------------------------------------------------------------------------
// Self-test
// ----------------------------------------------------------------------------

drm_selftest :: proc() {
	fmt.println("self-test")

	// Struct layouts. Every one of these feeds an ioctl number that encodes
	// the size; a mismatch is an EINVAL at best and a scribble at worst.
	drm_check(size_of(Drm_Version) == 64, "Drm_Version is %d, want 64", size_of(Drm_Version))
	drm_check(size_of(Drm_Get_Cap) == 16, "Drm_Get_Cap is %d, want 16", size_of(Drm_Get_Cap))
	drm_check(
		size_of(Drm_Set_Client_Cap) == 16,
		"Drm_Set_Client_Cap is %d, want 16",
		size_of(Drm_Set_Client_Cap),
	)
	drm_check(
		size_of(Drm_Mode_Card_Res) == 64,
		"Drm_Mode_Card_Res is %d, want 64",
		size_of(Drm_Mode_Card_Res),
	)
	drm_check(
		size_of(Drm_Mode_Info) == 68,
		"Drm_Mode_Info is %d, want 68",
		size_of(Drm_Mode_Info),
	)
	drm_check(
		size_of(Drm_Mode_Crtc) == 104,
		"Drm_Mode_Crtc is %d, want 104",
		size_of(Drm_Mode_Crtc),
	)
	drm_check(
		size_of(Drm_Mode_Get_Encoder) == 20,
		"Drm_Mode_Get_Encoder is %d, want 20",
		size_of(Drm_Mode_Get_Encoder),
	)
	drm_check(
		size_of(Drm_Mode_Get_Connector) == 80,
		"Drm_Mode_Get_Connector is %d, want 80",
		size_of(Drm_Mode_Get_Connector),
	)
	drm_check(
		size_of(Drm_Mode_Get_Property) == 64,
		"Drm_Mode_Get_Property is %d, want 64",
		size_of(Drm_Mode_Get_Property),
	)
	drm_check(
		size_of(Drm_Mode_Get_Blob) == 16,
		"Drm_Mode_Get_Blob is %d, want 16",
		size_of(Drm_Mode_Get_Blob),
	)
	drm_check(
		size_of(Drm_Mode_Obj_Get_Properties) == 32,
		"Drm_Mode_Obj_Get_Properties is %d, want 32",
		size_of(Drm_Mode_Obj_Get_Properties),
	)
	drm_check(
		size_of(Drm_Mode_Fb_Cmd2) == 104,
		"Drm_Mode_Fb_Cmd2 is %d, want 104",
		size_of(Drm_Mode_Fb_Cmd2),
	)
	drm_check(
		size_of(Drm_Mode_Crtc_Page_Flip) == 24,
		"Drm_Mode_Crtc_Page_Flip is %d, want 24",
		size_of(Drm_Mode_Crtc_Page_Flip),
	)
	drm_check(
		size_of(Drm_Mode_Fb_Dirty_Cmd) == 24,
		"Drm_Mode_Fb_Dirty_Cmd is %d, want 24",
		size_of(Drm_Mode_Fb_Dirty_Cmd),
	)
	drm_check(
		size_of(Drm_Mode_Create_Dumb) == 32,
		"Drm_Mode_Create_Dumb is %d, want 32",
		size_of(Drm_Mode_Create_Dumb),
	)
	drm_check(
		size_of(Drm_Mode_Map_Dumb) == 16,
		"Drm_Mode_Map_Dumb is %d, want 16",
		size_of(Drm_Mode_Map_Dumb),
	)
	drm_check(
		size_of(Drm_Mode_Destroy_Dumb) == 4,
		"Drm_Mode_Destroy_Dumb is %d, want 4",
		size_of(Drm_Mode_Destroy_Dumb),
	)
	drm_check(
		size_of(Drm_Event_Header) == 8,
		"Drm_Event_Header is %d, want 8",
		size_of(Drm_Event_Header),
	)
	drm_check(
		size_of(Drm_Event_Vblank) == 32,
		"Drm_Event_Vblank is %d, want 32",
		size_of(Drm_Event_Vblank),
	)

	// Field offsets the kernel reads directly.
	drm_check(
		offset_of(Drm_Mode_Crtc, mode) == 36,
		"Drm_Mode_Crtc.mode at %d, want 36",
		offset_of(Drm_Mode_Crtc, mode),
	)
	drm_check(
		offset_of(Drm_Mode_Info, name) == 36,
		"Drm_Mode_Info.name at %d, want 36",
		offset_of(Drm_Mode_Info, name),
	)
	drm_check(
		offset_of(Drm_Mode_Get_Property, count_values) == 56,
		"Drm_Mode_Get_Property.count_values at %d, want 56",
		offset_of(Drm_Mode_Get_Property, count_values),
	)
	drm_check(
		offset_of(Drm_Mode_Get_Connector, subpixel) == 72,
		"Drm_Mode_Get_Connector.subpixel at %d, want 72",
		offset_of(Drm_Mode_Get_Connector, subpixel),
	)
	drm_check(
		offset_of(Drm_Mode_Fb_Cmd2, modifier) == 72,
		"Drm_Mode_Fb_Cmd2.modifier at %d, want 72",
		offset_of(Drm_Mode_Fb_Cmd2, modifier),
	)
	drm_check(
		offset_of(Drm_Event_Vblank, crtc_id) == 28,
		"Drm_Event_Vblank.crtc_id at %d, want 28",
		offset_of(Drm_Event_Vblank, crtc_id),
	)

	// The ioctl encoding itself: _IOWR('d', nr, T) is
	// 3<<30 | size<<16 | 'd'<<8 | nr.
	iowr :: proc(nr: u32, size: int) -> u32 {
		return (3 << 30) | (u32(size) << 16) | (0x64 << 8) | nr
	}
	drm_check(
		DRM_IOCTL_MODE_GETRESOURCES == iowr(0xa0, size_of(Drm_Mode_Card_Res)),
		"GETRESOURCES encodes 0x%x, declared 0x%x",
		iowr(0xa0, size_of(Drm_Mode_Card_Res)),
		DRM_IOCTL_MODE_GETRESOURCES,
	)
	drm_check(
		DRM_IOCTL_MODE_GETCONNECTOR == iowr(0xa7, size_of(Drm_Mode_Get_Connector)),
		"GETCONNECTOR encodes 0x%x, declared 0x%x",
		iowr(0xa7, size_of(Drm_Mode_Get_Connector)),
		DRM_IOCTL_MODE_GETCONNECTOR,
	)
	drm_check(
		DRM_IOCTL_MODE_GETCRTC == iowr(0xa1, size_of(Drm_Mode_Crtc)),
		"GETCRTC encodes 0x%x, declared 0x%x",
		iowr(0xa1, size_of(Drm_Mode_Crtc)),
		DRM_IOCTL_MODE_GETCRTC,
	)
	drm_check(
		DRM_IOCTL_MODE_SETCRTC == iowr(0xa2, size_of(Drm_Mode_Crtc)),
		"SETCRTC encodes 0x%x, declared 0x%x",
		iowr(0xa2, size_of(Drm_Mode_Crtc)),
		DRM_IOCTL_MODE_SETCRTC,
	)
	drm_check(
		DRM_IOCTL_MODE_GETENCODER == iowr(0xa6, size_of(Drm_Mode_Get_Encoder)),
		"GETENCODER encodes 0x%x, declared 0x%x",
		iowr(0xa6, size_of(Drm_Mode_Get_Encoder)),
		DRM_IOCTL_MODE_GETENCODER,
	)
	drm_check(
		DRM_IOCTL_MODE_GETPROPERTY == iowr(0xaa, size_of(Drm_Mode_Get_Property)),
		"GETPROPERTY encodes 0x%x, declared 0x%x",
		iowr(0xaa, size_of(Drm_Mode_Get_Property)),
		DRM_IOCTL_MODE_GETPROPERTY,
	)
	drm_check(
		DRM_IOCTL_MODE_GETPROPBLOB == iowr(0xac, size_of(Drm_Mode_Get_Blob)),
		"GETPROPBLOB encodes 0x%x, declared 0x%x",
		iowr(0xac, size_of(Drm_Mode_Get_Blob)),
		DRM_IOCTL_MODE_GETPROPBLOB,
	)
	drm_check(
		DRM_IOCTL_MODE_ADDFB2 == iowr(0xb8, size_of(Drm_Mode_Fb_Cmd2)),
		"ADDFB2 encodes 0x%x, declared 0x%x",
		iowr(0xb8, size_of(Drm_Mode_Fb_Cmd2)),
		DRM_IOCTL_MODE_ADDFB2,
	)
	drm_check(
		DRM_IOCTL_MODE_PAGE_FLIP == iowr(0xb0, size_of(Drm_Mode_Crtc_Page_Flip)),
		"PAGE_FLIP encodes 0x%x, declared 0x%x",
		iowr(0xb0, size_of(Drm_Mode_Crtc_Page_Flip)),
		DRM_IOCTL_MODE_PAGE_FLIP,
	)
	drm_check(
		DRM_IOCTL_MODE_DIRTYFB == iowr(0xb1, size_of(Drm_Mode_Fb_Dirty_Cmd)),
		"DIRTYFB encodes 0x%x, declared 0x%x",
		iowr(0xb1, size_of(Drm_Mode_Fb_Dirty_Cmd)),
		DRM_IOCTL_MODE_DIRTYFB,
	)
	drm_check(
		DRM_IOCTL_MODE_CREATE_DUMB == iowr(0xb2, size_of(Drm_Mode_Create_Dumb)),
		"CREATE_DUMB encodes 0x%x, declared 0x%x",
		iowr(0xb2, size_of(Drm_Mode_Create_Dumb)),
		DRM_IOCTL_MODE_CREATE_DUMB,
	)
	drm_check(
		DRM_IOCTL_MODE_MAP_DUMB == iowr(0xb3, size_of(Drm_Mode_Map_Dumb)),
		"MAP_DUMB encodes 0x%x, declared 0x%x",
		iowr(0xb3, size_of(Drm_Mode_Map_Dumb)),
		DRM_IOCTL_MODE_MAP_DUMB,
	)
	drm_check(
		DRM_IOCTL_GET_CAP == iowr(0x0c, size_of(Drm_Get_Cap)),
		"GET_CAP encodes 0x%x, declared 0x%x",
		iowr(0x0c, size_of(Drm_Get_Cap)),
		DRM_IOCTL_GET_CAP,
	)
	// XRGB8888 is the fourcc 'X','R','2','4' little-endian.
	drm_check(
		DRM_FORMAT_XRGB8888 ==
		u32('X') | (u32('R') << 8) | (u32('2') << 16) | (u32('4') << 24),
		"XRGB8888 fourcc is wrong",
	)

	// Refresh arithmetic, against modes whose numbers are known.
	m1080p60 := Drm_Mode_Info {
		clock    = 148500,
		hdisplay = 1920,
		htotal   = 2200,
		vdisplay = 1080,
		vtotal   = 1125,
	}
	r := drm_mode_refresh_mhz(m1080p60)
	drm_check(r == 60000, "1920x1080@60 computed %d mHz, want 60000", r)
	drm_check(
		drm_mode_refresh_ns(m1080p60) == 16_666_666,
		"1080p60 frame is %d ns",
		drm_mode_refresh_ns(m1080p60),
	)
	m1440p165 := Drm_Mode_Info {
		clock    = 1065960 / 2,
		hdisplay = 2560,
		htotal   = 2656,
		vdisplay = 1440,
		vtotal   = 1498,
	}
	drm_check(
		drm_mode_refresh_mhz(m1440p165) > 100_000,
		"2560x1440 high-refresh computed %d mHz",
		drm_mode_refresh_mhz(m1440p165),
	)
	mzero := Drm_Mode_Info {
		vrefresh = 50,
	}
	drm_check(
		drm_mode_refresh_mhz(mzero) == 50_000,
		"a mode with no timings should fall back to vrefresh",
	)

	// Mode selection.
	modes := []Drm_Mode_Info {
		{hdisplay = 1920, vdisplay = 1080, htotal = 2200, vtotal = 1125, clock = 148500},
		{
			hdisplay = 1280,
			vdisplay = 720,
			htotal = 1650,
			vtotal = 750,
			clock = 74250,
			kind = DRM_MODE_TYPE_PREFERRED,
		},
	}
	drm_check(drm_pick_mode(modes) == 1, "PREFERRED must win over the larger mode")
	unflagged := []Drm_Mode_Info {
		{hdisplay = 1280, vdisplay = 720, htotal = 1650, vtotal = 750, clock = 74250},
		{hdisplay = 1920, vdisplay = 1080, htotal = 2200, vtotal = 1125, clock = 148500},
	}
	drm_check(drm_pick_mode(unflagged) == 1, "with nothing preferred, the largest mode wins")
	same_size := []Drm_Mode_Info {
		{hdisplay = 1920, vdisplay = 1080, htotal = 2200, vtotal = 1125, clock = 148500},
		{hdisplay = 1920, vdisplay = 1080, htotal = 2200, vtotal = 1125, clock = 297000},
	}
	drm_check(drm_pick_mode(same_size) == 1, "equal sizes break the tie on refresh")
	drm_check(drm_pick_mode(nil) == -1, "an empty mode list yields -1")

	// Connector naming.
	drm_check(drm_connector_type_name(14) == "eDP", "connector type 14 is eDP")
	drm_check(drm_connector_type_name(10) == "DP", "connector type 10 is DP")
	drm_check(drm_connector_type_name(11) == "HDMI-A", "connector type 11 is HDMI-A")
	n := drm_connector_name(10, 3, context.temp_allocator)
	drm_check(n == "DP-3", "connector name is %q, want DP-3", n)

	// EDID parsing, against a block built here so the expected answers are
	// known exactly.
	edid := drm_fake_edid("ACME 27Q", "GSM", 0x5BBF)
	e := drm_parse_edid(edid[:], context.temp_allocator)
	drm_check(e.valid, "synthetic EDID did not validate")
	drm_check(e.checksum_ok, "synthetic EDID checksum is wrong")
	drm_check(e.vendor == "GSM", "EDID vendor is %q, want GSM", e.vendor)
	drm_check(e.product == 0x5BBF, "EDID product is %04X, want 5BBF", e.product)
	drm_check(e.name == "ACME 27Q", "EDID monitor name is %q, want \"ACME 27Q\"", e.name)
	drm_check(e.mm_w == 600 && e.mm_h == 340, "EDID size is %dx%d mm", e.mm_w, e.mm_h)
	lbl := drm_edid_label(e, context.temp_allocator)
	drm_check(lbl == "ACME 27Q", "EDID label is %q", lbl)

	noname := drm_fake_edid("", "DEL", 0x4321)
	e2 := drm_parse_edid(noname[:], context.temp_allocator)
	lbl2 := drm_edid_label(e2, context.temp_allocator)
	drm_check(lbl2 == "DEL 4321", "nameless EDID label is %q, want \"DEL 4321\"", lbl2)

	bad := drm_fake_edid("X", "AAA", 1)
	bad[0] = 0x01
	e3 := drm_parse_edid(bad[:], context.temp_allocator)
	drm_check(!e3.valid, "an EDID without the magic header must be rejected")
	drm_check(!drm_parse_edid(nil, context.temp_allocator).valid, "a nil EDID must be rejected")
	short := edid[:64]
	drm_check(
		!drm_parse_edid(short, context.temp_allocator).valid,
		"a truncated EDID must be rejected",
	)

	ck := drm_fake_edid("CK", "ABC", 2)
	ck[127] ~= 0xff
	drm_check(
		!drm_parse_edid(ck[:], context.temp_allocator).checksum_ok,
		"a corrupted checksum must be reported",
	)

	// uevent parsing.
	hp := drm_uevent_msg({"change@/devices/pci0000:00/drm/card1", "ACTION=change", "DEVTYPE=drm_minor", "SUBSYSTEM=drm", "HOTPLUG=1", "SEQNUM=4821"})
	drm_check(drm_uevent_is_hotplug(hp), "a DRM hotplug uevent must be recognised")
	other := drm_uevent_msg({"add@/devices/.../net/eth0", "ACTION=add", "SUBSYSTEM=net"})
	drm_check(!drm_uevent_is_hotplug(other), "a net uevent must be ignored")
	notplug := drm_uevent_msg({"change@/devices/.../drm/card1", "SUBSYSTEM=drm"})
	drm_check(!drm_uevent_is_hotplug(notplug), "a DRM uevent without HOTPLUG=1 must be ignored")
	libudev := drm_uevent_msg({"libudev", "ACTION=change", "SUBSYSTEM=drm", "HOTPLUG=1"})
	drm_check(!drm_uevent_is_hotplug(libudev), "libudev's own messages must be ignored")

	// The swap chain and the layout, against fake heads backed by anonymous
	// memory. No device is involved.
	drm_selftest_swapchain()
	drm_selftest_layout()
}

@(private = "file")
drm_uevent_msg :: proc(fields: []string) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for f in fields {
		strings.write_string(&b, f)
		strings.write_byte(&b, 0)
	}
	return transmute([]u8)strings.to_string(b)
}

// drm_fake_edid builds a valid 128-byte base block with a known vendor,
// product code and (optionally) a monitor-name descriptor.
@(private = "file")
drm_fake_edid :: proc(name: string, vendor: string, product: u16) -> []u8 {
	b := make([]u8, 128, context.temp_allocator)
	magic := [8]u8{0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00}
	copy(b[0:8], magic[:])
	v := u16(0)
	for i in 0 ..< 3 {
		c := u16(vendor[i]) - 'A' + 1
		v = (v << 5) | (c & 0x1f)
	}
	b[8] = u8(v >> 8)
	b[9] = u8(v)
	b[10] = u8(product)
	b[11] = u8(product >> 8)
	b[16] = 20 // week
	b[17] = 34 // 2024
	b[21] = 60 // 600mm
	b[22] = 34 // 340mm
	if name != "" {
		off := 54 + 18 // second descriptor
		b[off + 0] = 0
		b[off + 1] = 0
		b[off + 2] = 0
		b[off + 3] = 0xfc
		b[off + 4] = 0
		for i in 0 ..< 13 {
			b[off + 5 + i] = i < len(name) ? name[i] : (i == len(name) ? 0x0a : 0x20)
		}
	}
	sum: u8 = 0
	for i in 0 ..< 127 {
		sum += b[i]
	}
	b[127] = u8(0) - sum
	return b
}

// drm_fake_fb stands in for a dumb buffer: an anonymous mapping with the same
// geometry and a pitch chosen to be realistically padded. Everything the swap
// chain does to a real buffer it does to one of these, which is how the stride
// handling gets exercised without a device.
@(private = "file")
drm_fake_fb :: proc(w, h, pitch_bytes: int) -> Drm_Fb {
	size := uint(pitch_bytes * h)
	mem, err := linux.mmap(0, size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if err != .NONE {
		return {}
	}
	fb := Drm_Fb {
		w         = w,
		h         = h,
		pitch     = u32(pitch_bytes),
		stride_px = pitch_bytes / 4,
		size      = u64(size),
		mem       = mem,
		px        = ([^]u32)(mem)[:int(size) / 4],
		anon      = true,
	}
	for i in 0 ..< len(fb.px) {
		fb.px[i] = 0xff00_0000
	}
	return fb
}

@(private = "file")
drm_selftest_swapchain :: proc() {
	W, H :: 320, 200
	// 256-byte aligned pitch — what an amdgpu or i915 dumb buffer actually
	// hands back for this width (320*4 = 1280, which is already aligned, so
	// force a pad to make the shadow path real).
	PITCH :: 1408 // 352 px of stride for 320 px of picture

	h := new(Drm_Head, context.temp_allocator)
	h.name = "TEST-1"
	h.scale = 1
	h.connected = true
	h.front, h.queued = -1, -1
	h.mode = Drm_Mode_Info {
		hdisplay = W,
		vdisplay = H,
		htotal   = 400,
		vtotal   = 220,
		clock    = 5280,
	}
	h.have_mode = true
	for i in 0 ..< DRM_BUFFERS {
		h.fbs[i] = drm_fake_fb(W, H, PITCH)
	}
	drm_check(h.fbs[0].px != nil, "anonymous stand-in buffer could not be mapped")
	if h.fbs[0].px == nil {
		return
	}
	defer {
		for i in 0 ..< DRM_BUFFERS {
			linux.munmap(h.fbs[i].mem, uint(h.fbs[i].size))
		}
		if h.canvas_ready {
			p.canvas_destroy(&h.canvas)
		}
		delete(h.shadow)
	}

	h.back = 0
	drm_head_bind_canvas(h)
	drm_check(h.canvas_ready, "binding a canvas to a padded buffer failed")
	drm_check(h.canvas.w == W && h.canvas.h == H, "canvas is %dx%d", h.canvas.w, h.canvas.h)
	drm_check(len(h.shadow) == W * H, "a padded pitch must allocate a shadow of w*h")
	drm_check(
		raw_data(h.canvas.px) == raw_data(h.shadow),
		"a padded pitch must make the canvas point at the shadow, not the mapping",
	)

	// Draw something with a hard edge at the right-hand column, which is the
	// pixel a stride bug loses.
	p.clear_canvas(&h.canvas, p.hex(0x101418))
	p.fill_rect(&h.canvas, {0, 0, f32(W), 24}, p.hex(0xe4e4e7))
	p.fill_rect(&h.canvas, {f32(W - 8), 0, 8, f32(H)}, p.hex(0xef4444))
	p.fill_rect(&h.canvas, {0, f32(H - 8), f32(W), 8}, p.hex(0x22c55e))
	p.fill_rect_paint(
		&h.canvas,
		{16, 40, f32(W - 48), f32(H - 80)},
		p.gradient(p.hex(0x2563eb), p.hex(0x9333ea), true),
	)

	// Present with the live gate shut: the blit happens, the flip does not.
	ok := drm_present(h)
	drm_check(ok, "drm_present must succeed with the gate closed (blit only)")
	drm_check(!h.awaiting_flip, "no flip may be outstanding with the gate closed")
	drm_check(h.front == 0, "front buffer should be the one just presented")

	fb := &h.fbs[0]
	// Every row must have landed at its padded offset, and the padding must
	// still hold its initial fill — if the blit used w instead of stride, the
	// picture would shear and the padding would be overwritten.
	tl := fb.px[0]
	tr := fb.px[W - 1]
	tr_bar := fb.px[W - 9] // just left of the red column
	bl := fb.px[(H - 1) * fb.stride_px]
	br := fb.px[(H - 1) * fb.stride_px + W - 1]
	drm_check(tl == 0xffe4e4e7, "top-left is %08x, want the title bar colour", tl)
	drm_check(tr_bar == 0xffe4e4e7, "top row left of the red column is %08x", tr_bar)
	drm_check(tr == 0xffef4444, "top-right is %08x, want the red column", tr)
	drm_check(bl == 0xff22c55e, "bottom-left is %08x, want the green strip", bl)
	// The green strip is painted after the red column, so it owns the corner.
	drm_check(br == 0xff22c55e, "bottom-right is %08x, want the green strip", br)
	drm_check(
		fb.px[(H / 2) * fb.stride_px + W - 1] == 0xffef4444,
		"the right-hand red column did not survive the padded blit",
	)
	pad_clean := true
	for y in 0 ..< H {
		for x in W ..< fb.stride_px {
			if fb.px[y * fb.stride_px + x] != 0xff00_0000 {
				pad_clean = false
			}
		}
	}
	drm_check(pad_clean, "the blit wrote into the stride padding")

	// The swap chain must rotate: with three buffers and one on screen the
	// next frame goes somewhere else.
	first := h.back
	c2 := drm_begin_frame(h)
	drm_check(c2 != nil, "a second frame must be available")
	drm_check(h.back != first, "the swap chain must not draw into the front buffer")
	drm_present(h)
	third := h.back
	c3 := drm_begin_frame(h)
	drm_check(c3 != nil, "a third frame must be available")
	drm_check(h.back != third, "the swap chain must keep rotating")

	// A simulated outstanding flip must block the chain rather than let the
	// rasterizer scribble on a queued buffer.
	h.queued = h.back
	h.awaiting_flip = true
	drm_check(!drm_head_ready(h), "a head with a flip outstanding is not ready")
	drm_check(drm_begin_frame(h) != nil, "with three buffers one is still free")
	drm_check(
		h.back != h.queued && h.back != h.front,
		"the free buffer must be neither queued nor on screen",
	)

	// And the completion event must clear it.
	ev := Drm_Event_Vblank {
		base = {kind = DRM_EVENT_FLIP_COMPLETE, length = size_of(Drm_Event_Vblank)},
		user_data = u64(uintptr(h)),
		tv_sec = 1234,
		tv_usec = 567_000,
	}
	_ = ev
	// drm_flip_done walks the real card list, which this fake head is not on,
	// so the event path is checked by parsing instead: the header must split
	// a packed stream into exactly the right records.
	stream: [size_of(Drm_Event_Vblank) * 2]u8
	e1 := (^Drm_Event_Vblank)(raw_data(stream[:]))
	e1^ = ev
	e2 := (^Drm_Event_Vblank)(raw_data(stream[size_of(Drm_Event_Vblank):]))
	e2^ = ev
	e2.crtc_id = 42
	drm_check(
		!drm_handle_events(stream[:]),
		"events for an unknown head must be dropped, not matched",
	)
	trunc := stream[:size_of(Drm_Event_Vblank) + 4]
	drm_check(!drm_handle_events(trunc), "a truncated trailing event must not be parsed")
	bogus := [8]u8{}
	(^Drm_Event_Header)(raw_data(bogus[:]))^ = {kind = 99, length = 0}
	drm_check(!drm_handle_events(bogus[:]), "a zero-length event must not loop forever")

	// Tight pitch: the canvas must alias the mapping with no shadow at all.
	tight := new(Drm_Head, context.temp_allocator)
	tight.scale = 1
	tight.connected = true
	tight.front, tight.queued = -1, -1
	tight.mode = h.mode
	tight.have_mode = true
	tight.fbs[0] = drm_fake_fb(W, H, W * 4)
	defer linux.munmap(tight.fbs[0].mem, uint(tight.fbs[0].size))
	defer if tight.canvas_ready {p.canvas_destroy(&tight.canvas)}
	drm_head_bind_canvas(tight)
	drm_check(tight.shadow == nil, "a tight pitch must not allocate a shadow")
	drm_check(
		raw_data(tight.canvas.px) == raw_data(tight.fbs[0].px),
		"a tight pitch must let the canvas alias scanout memory",
	)
	p.fill_rect(&tight.canvas, {0, 0, 4, 4}, p.hex(0xff8800))
	drm_check(
		tight.fbs[0].px[0] == 0xffff8800,
		"a write through an aliasing canvas must land in the mapping",
	)
}

@(private = "file")
drm_selftest_layout :: proc() {
	// Two heads on one card, which is the case the nested backend could not
	// express at all.
	card := new(Drm_Card, context.temp_allocator)
	a := new(Drm_Head, context.temp_allocator)
	b := new(Drm_Head, context.temp_allocator)
	a.card, b.card = card, card
	a.connected, b.connected = true, true
	a.have_mode, b.have_mode = true, true
	a.scale, b.scale = 1, 1
	a.mode = Drm_Mode_Info {
		hdisplay = 2560,
		vdisplay = 1440,
	}
	b.mode = Drm_Mode_Info {
		hdisplay = 1920,
		vdisplay = 1080,
	}
	append(&card.heads, a)
	append(&card.heads, b)
	append(&drm_state.cards, card)
	defer {
		pop(&drm_state.cards)
		delete(card.heads)
	}

	drm_layout_apply()
	drm_check(a.x == 0 && a.y == 0, "the first head sits at the origin, got %d,%d", a.x, a.y)
	drm_check(b.x == 2560, "the second head starts where the first ends, got %d", b.x)
	w, hh := drm_layout_extent()
	drm_check(w == 4480, "layout width is %d, want 4480", w)
	drm_check(hh == 1440, "layout height is %d, want 1440", hh)

	drm_check(drm_head_at(10, 10) == a, "a point in the left head maps to it")
	drm_check(drm_head_at(3000, 10) == b, "a point in the right head maps to it")
	drm_check(drm_head_at(3000, 1200) == nil, "a point below the shorter head maps to nothing")
	drm_check(drm_head_at(-1, 0) == nil, "a point left of everything maps to nothing")
	drm_check(drm_head_at(4480, 0) == nil, "a point past the right edge maps to nothing")

	// Scale is a field on the head, and the layout is in logical pixels, so a
	// 2x head occupies half the space its mode does.
	a.scale = 2
	drm_layout_apply()
	drm_check(b.x == 1280, "a 2x head takes half the logical width, b.x is %d", b.x)
	w2, _ := drm_layout_extent()
	drm_check(w2 == 3200, "layout width with a 2x head is %d, want 3200", w2)
	drm_check(drm_head_at(100, 100) == a, "a point still lands on the scaled head")
	a.scale = 1

	heads := drm_heads(context.temp_allocator)
	drm_check(len(heads) == 2, "drm_heads returned %d, want 2", len(heads))
	b.connected = false
	drm_check(
		len(drm_heads(context.temp_allocator)) == 1,
		"a disconnected head drops out of drm_heads",
	)
	b.connected = true
}

// drm_probe_render draws one head's worth of pixels through the exact path a
// real frame takes — canvas, padded blit, de-pitch — and writes it out as a
// PNG. Looking at the result is the only check that catches a frame that is
// arithmetically perfect and visibly wrong.
@(private = "file")
drm_probe_render :: proc(path: string) {
	W, H :: 640, 360
	PITCH :: 2816 // 704 px of stride for 640 px of picture

	h := new(Drm_Head, context.temp_allocator)
	h.scale = 1
	h.connected = true
	h.front, h.queued = -1, -1
	h.mode = Drm_Mode_Info {
		hdisplay = W,
		vdisplay = H,
	}
	h.have_mode = true
	for i in 0 ..< DRM_BUFFERS {
		h.fbs[i] = drm_fake_fb(W, H, PITCH)
	}
	if h.fbs[0].px == nil {
		fmt.printfln("render: could not map a stand-in buffer")
		return
	}
	defer {
		for i in 0 ..< DRM_BUFFERS {
			linux.munmap(h.fbs[i].mem, uint(h.fbs[i].size))
		}
		if h.canvas_ready {
			p.canvas_destroy(&h.canvas)
		}
		delete(h.shadow)
	}
	drm_head_bind_canvas(h)
	cv := &h.canvas

	p.fill_rect_paint(
		cv,
		{0, 0, W, H},
		p.gradient(p.hex(0x0b1220), p.hex(0x1e293b), true),
	)
	// A checkerboard, which makes a shear of even one pixel per row obvious.
	for ty in 0 ..< 9 {
		for tx in 0 ..< 16 {
			if (tx + ty) % 2 == 1 {
				continue
			}
			p.fill_rect(cv, {f32(tx * 40), f32(ty * 40), 40, 40}, p.hex(0x172554))
		}
	}
	p.fill_rect(cv, {40, 40, 200, 120}, p.hex(0x38bdf8))
	p.fill_rect(cv, {W - 240, H - 160, 200, 120}, p.hex(0xf59e0b))
	// A one-pixel frame right at the edges, painted last so nothing covers
	// it: if the stride is wrong the right edge is the first thing to go.
	p.fill_rect(cv, {0, 0, W, 1}, p.hex(0xef4444))
	p.fill_rect(cv, {0, H - 1, W, 1}, p.hex(0xef4444))
	p.fill_rect(cv, {0, 0, 1, H}, p.hex(0xef4444))
	p.fill_rect(cv, {W - 1, 0, 1, H}, p.hex(0xef4444))

	drm_present(h)

	// Read back out of the padded buffer the way scanout would, into a packed
	// image, and write it.
	off := p.offscreen_create(W, H)
	defer p.offscreen_destroy(off)
	px := p.offscreen_pixels(off)
	fb := &h.fbs[h.front]
	for y in 0 ..< H {
		copy(px[y * W:][:W], fb.px[y * fb.stride_px:][:W])
	}
	if p.offscreen_write_png(off, path) {
		fmt.printfln("render: wrote %s (%dx%d from a pitch-%d buffer)", path, W, H, PITCH)
	} else {
		fmt.printfln("render: could not write %s", path)
	}
	drm_check(px[0] == 0xffef4444, "the PNG's top-left pixel is not the red frame")
	drm_check(px[W - 1] == 0xffef4444, "the PNG's top-right pixel is not the red frame")
	drm_check(px[(H - 1) * W + W - 1] == 0xffef4444, "the PNG's bottom-right pixel is not the red frame")
	drm_check(px[(H - 1) * W] == 0xffef4444, "the PNG's bottom-left pixel is not the red frame")
	drm_check(px[100 * W + 100] == 0xff38bdf8, "the blue block is not where it was drawn")
	drm_check(
		px[(H - 60) * W + (W - 100)] == 0xfff59e0b,
		"the amber block is not where it was drawn",
	)
	// The last column of every row: a one-pixel-per-row shear would break it.
	edge := true
	for y in 0 ..< H {
		if px[y * W + W - 1] != 0xffef4444 {
			edge = false
		}
	}
	drm_check(edge, "the right-hand edge is not solid — the de-pitch sheared")
}
