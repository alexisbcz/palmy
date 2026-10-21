package palmy

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/kqueue"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import NS "core:sys/darwin/Foundation"

// ---------------------------------------------------------------------------
// The macOS backend: a Cocoa window, blitted in software.
//
// The same six things the Linux backends do (window.odin's header), done with
// AppKit:
//
//	open, close     an NSWindow whose content view is a layer-hosting NSView
//	                of our own class (PalmyView), which is also the window's
//	                delegate and its NSTextInputClient
//	buffers         two plain heap buffers of 0xAARRGGBB words, as the
//	                rasterizer writes them
//	present         the buffer becomes a CGImage (the bytes are copied, so
//	                Core Animation never reads memory the next frame is
//	                drawing into) and the layer's contents. No GPU code.
//	wait            -[NSApp nextEventMatchingMask:untilDate:...], which parks
//	                in the main CFRunLoop until an event, the timeout, or a
//	                wake
//	toplevel        title, minimum size, fullscreen, cursor
//
// **Waking.** window.odin's wake descriptor is a kqueue here, with one
// EVFILT_USER event: `wake_poke` triggers it (one syscall, no lock, no
// allocation — still safe from any thread), `drain_wake` collects it. A
// CFFileDescriptor watches the kqueue from the main run loop; its callback
// posts an application-defined NSEvent, which is what ends a
// nextEventMatchingMask wait — run-loop sources alone do not.
//
// **Pacing.** There is no frame callback to wait for, so the loop paces
// itself the way a Wayland compositor would pace it: a present sets
// `frame_pending`, and the wait clears it once a refresh interval of the
// window's screen has passed (`maximumFramesPerSecond`, 60 when unknown).
// While the window is fully occluded or minimised (NSWindowOcclusionState)
// the interval never ends — exactly a compositor withholding callbacks — so
// due wakes and input run logic frames and painting waits until it is seen
// again. Frames identical to the last one are not sent (damage.odin).
//
// **Keys.** A key's keysym is the X keysym palmy already speaks: special keys
// by virtual key code, everything else from the layout's character
// (`charactersIgnoringModifiers`, which keeps Shift as X keysyms do), and
// `unshifted` from the character with no modifiers at all. Text goes through
// `interpretKeyEvents:` and NSTextInputClient, so dead keys, the accent
// press-and-hold menu and input methods all deliver composed text. Marked
// (pre-edit) text is not drawn: palmy has no pre-edit display on any backend.
//
// **Modifiers — a decision.** Command and Control both report as `.Ctrl`.
// Every palmy application spells its shortcuts with Ctrl (Ctrl+C, Ctrl+S,
// Ctrl+Z); mapping Command there makes them the shortcuts a Mac user's
// hands already know, and keeping Control there too keeps a terminal's ^C
// working. Nothing in palmy tells the two apart today, so nothing is lost.
// PALMY_MAC_COMMAND=super reports Command as `.Super` instead. Option is
// `.Alt` and still types (Option+e is a dead acute), as AltGr does on Linux.
//
// **Not done.** Live resize: AppKit runs its own tracking loop inside
// sendEvent while an edge is dragged, and palmy's frame loop belongs to the
// application, so the old frame stays pinned top-left until the drag ends and
// the new size paints. Layer-shell surfaces have no macOS equivalent (as on
// X11). No pre-edit display, no drag and drop, no primary selection (see
// clipboard_darwin.odin).
// ---------------------------------------------------------------------------

Cocoa_State :: struct {
	open:        bool,
	window:      ^NS.Window,
	view:        ^NS.View,
	layer:       ^NS.Layer,
	tracking:    ^NS.Object,
	wake_cf:     rawptr, // CFFileDescriptorRef over the wake kqueue
	wake_src:    rawptr, // its CFRunLoopSourceRef
	wake_ctx:    CF_File_Descriptor_Context,
	visible:     bool,
	frame_due:   i64, // mono_ns at which `frame_pending` lapses
	interval:    i64, // one refresh of the window's screen, in ns
	cursor:      Cursor,
	// An NSProcessInfo activity held while a wake deadline is armed; see
	// cocoa_timer_precision.
	activity:    ^NS.Object,
	in_key_down: bool,
	clicks:      u32,
	presents:    int,
	// Diagnostics for tests and the self-check: the last present's size.
	last_w:      int,
	last_h:      int,
}

// ---------------------------------------------------------------------------
// Foreign: CoreFoundation, CoreGraphics, QuartzCore. Only what is used.
// ---------------------------------------------------------------------------

foreign import cf "system:CoreFoundation.framework"
foreign import cg "system:CoreGraphics.framework"
@(require) foreign import qc "system:QuartzCore.framework"

@(private)
CF_File_Descriptor_Context :: struct {
	version:          int,
	info:             rawptr,
	retain:           rawptr,
	release:          rawptr,
	copy_description: rawptr,
}

@(private)
CF_File_Descriptor_Callback :: #type proc "c" (f: rawptr, types: c.ulong, info: rawptr)

@(private)
CF_READ_CALLBACK :: c.ulong(1)

@(default_calling_convention = "c")
@(private)
foreign cf {
	CFRelease :: proc(obj: rawptr) ---
	CFDataCreate :: proc(alloc: rawptr, bytes: [^]u8, length: int) -> rawptr ---
	CFFileDescriptorCreate :: proc(alloc: rawptr, fd: c.int, close_on_invalidate: bool, callout: CF_File_Descriptor_Callback, ctx: ^CF_File_Descriptor_Context) -> rawptr ---
	CFFileDescriptorEnableCallBacks :: proc(f: rawptr, types: c.ulong) ---
	CFFileDescriptorCreateRunLoopSource :: proc(alloc: rawptr, f: rawptr, order: int) -> rawptr ---
	CFFileDescriptorInvalidate :: proc(f: rawptr) ---
	CFRunLoopGetMain :: proc() -> rawptr ---
	CFRunLoopAddSource :: proc(rl: rawptr, src: rawptr, mode: rawptr) ---
	CFRunLoopRemoveSource :: proc(rl: rawptr, src: rawptr, mode: rawptr) ---
	kCFRunLoopCommonModes: rawptr
}

@(default_calling_convention = "c")
@(private)
foreign cg {
	CGColorSpaceCreateWithName :: proc(name: rawptr) -> rawptr ---
	CGColorSpaceRelease :: proc(cs: rawptr) ---
	CGDataProviderCreateWithCFData :: proc(data: rawptr) -> rawptr ---
	CGDataProviderRelease :: proc(p: rawptr) ---
	CGImageCreate :: proc(w, h, bits_per_component, bits_per_pixel, bytes_per_row: uint, space: rawptr, bitmap_info: u32, provider: rawptr, decode: rawptr, interpolate: bool, intent: i32) -> rawptr ---
	CGImageRelease :: proc(img: rawptr) ---
	kCGColorSpaceSRGB: rawptr
}

// QuartzCore is linked (above) for CALayer and CATransaction, which are
// reached through objc_send.

// The pixel words are 0xXXRRGGBB in little-endian memory: B, G, R, X.
@(private)
CG_BITMAP_INFO :: u32(6 /* NoneSkipFirst */ | (2 << 12) /* ByteOrder32Little */)

@(objc_class = "CALayer")
@(private)
CA_Layer :: struct {
	using _: NS.Object,
}

@(objc_class = "CATransaction")
@(private)
CA_Transaction :: struct {
	using _: NS.Object,
}

@(objc_class = "NSCursor")
@(private)
NS_Cursor :: struct {
	using _: NS.Object,
}

@(objc_class = "NSTrackingArea")
@(private)
NS_Tracking_Area :: struct {
	using _: NS.Object,
}

@(objc_class = "NSMenu")
@(private)
NS_Menu :: struct {
	using _: NS.Object,
}

@(objc_class = "NSMenuItem")
@(private)
NS_Menu_Item :: struct {
	using _: NS.Object,
}

@(objc_class = "NSAttributedString")
@(private)
NS_Attributed_String :: struct {
	using _: NS.Object,
}

@(private)
msg :: intrinsics.objc_send

// ns_string makes an autoreleased NSString; call inside an autorelease pool.
@(private)
ns_string :: proc(s: string) -> ^NS.String {
	str := NS.String_initWithOdinString(NS.String_alloc(), s)
	msg(^NS.String, str, "autorelease")
	return str
}

// ---------------------------------------------------------------------------
// The application, once per process
// ---------------------------------------------------------------------------

@(private)
g_cocoa: struct {
	ready:     bool,
	ok:        bool,
	app:       ^NS.Application,
	view_cls:  NS.Class,
	srgb:      rawptr,
	windows:   [dynamic]^Window,
	cmd_super: bool,
	ctx:       runtime.Context,
}

@(private)
cocoa_init :: proc() -> string {
	if g_cocoa.ready {
		return g_cocoa.ok ? "" : "AppKit could not be initialised"
	}
	g_cocoa.ready = true
	g_cocoa.ctx = runtime.default_context()
	g_cocoa.cmd_super = os.get_env("PALMY_MAC_COMMAND", context.temp_allocator) == "super"

	NS.scoped_autoreleasepool()
	if !bool(msg(NS.BOOL, NS_Thread, "isMainThread")) {
		return "AppKit windows can only be opened from the main thread"
	}

	app := NS.Application_sharedApplication()
	NS.Application_setActivationPolicy(app, .Regular)
	g_cocoa.app = app
	g_cocoa.srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)

	register_view_class()
	install_menu(app)
	install_app_delegate(app)
	NS.Application_finishLaunching(app)
	g_cocoa.ok = true
	return ""
}

@(objc_class = "NSThread")
@(private)
NS_Thread :: struct {
	using _: NS.Object,
}

// A minimal menu bar: the application menu with Hide and Quit, so that ⌘Q
// and the Dock's Quit ask every window to close instead of killing the
// process mid-frame.
@(private)
install_menu :: proc(app: ^NS.Application) {
	bar := msg(^NS_Menu, msg(^NS_Menu, NS_Menu, "alloc"), "init")
	app_item := msg(^NS_Menu_Item, msg(^NS_Menu_Item, NS_Menu_Item, "alloc"), "init")
	msg(nil, bar, "addItem:", app_item)
	menu := msg(^NS_Menu, msg(^NS_Menu, NS_Menu, "alloc"), "init")

	name := filepath_base(os.args[0])
	hide := msg(
		^NS_Menu_Item,
		msg(^NS_Menu_Item, NS_Menu_Item, "alloc"),
		"initWithTitle:action:keyEquivalent:",
		ns_string(fmt.tprintf("Hide %s", name)),
		intrinsics.objc_find_selector("hide:"),
		ns_string("h"),
	)
	msg(nil, menu, "addItem:", hide)
	quit := msg(
		^NS_Menu_Item,
		msg(^NS_Menu_Item, NS_Menu_Item, "alloc"),
		"initWithTitle:action:keyEquivalent:",
		ns_string(fmt.tprintf("Quit %s", name)),
		intrinsics.objc_find_selector("terminate:"),
		ns_string("q"),
	)
	msg(nil, menu, "addItem:", quit)
	msg(nil, app_item, "setSubmenu:", menu)
	msg(nil, app, "setMainMenu:", bar)
}

@(private)
filepath_base :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '/')
	return i < 0 ? p : p[i + 1:]
}

// The application delegate answers "terminate?" with "not yet", and asks
// every window to close: the frame loops then end the way they end on Linux.
@(private)
install_app_delegate :: proc(app: ^NS.Application) {
	cls := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "PalmyAppDelegate", 0)
	if cls == nil {
		return
	}
	should_terminate :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) -> NS.UInteger {
		context = g_cocoa.ctx
		for w in g_cocoa.windows {
			w.should_close = true
			w.input_dirty = true
			wake_window(w)
		}
		return 0 // NSTerminateCancel
	}
	NS.class_addMethod(cls, intrinsics.objc_find_selector("applicationShouldTerminate:"), auto_cast should_terminate, "Q@:@")
	NS.objc_registerClassPair(cls)
	del := NS.class_createInstance(cls, 0)
	msg(nil, app, "setDelegate:", del)
}

// ---------------------------------------------------------------------------
// PalmyView: content view, window delegate and text input client in one
// ---------------------------------------------------------------------------

// view_window is the palmy Window a PalmyView belongs to, kept in the
// object's indexed ivars; nil once the window has closed.
@(private)
view_window :: proc "contextless" (self: NS.id) -> ^Window {
	return (^^Window)(NS.object_getIndexedIvars(self))^
}

@(private)
NS_Range :: struct {
	location: NS.UInteger,
	length:   NS.UInteger,
}

@(private)
NS_NOT_FOUND :: NS.UInteger(max(NS.Integer))

@(private)
register_view_class :: proc() {
	cls := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSView"), "PalmyView", 0)
	assert(cls != nil, "PalmyView registered twice")
	add :: proc(cls: NS.Class, sel: cstring, imp: rawptr, types: cstring) {
		NS.class_addMethod(cls, NS.sel_registerName(sel), auto_cast imp, types)
	}

	yes :: proc "c" (self: NS.id, cmd: NS.SEL) -> NS.BOOL {return true}
	yes_ev :: proc "c" (self: NS.id, cmd: NS.SEL, ev: ^NS.Event) -> NS.BOOL {return true}
	add(cls, "acceptsFirstResponder", rawptr(yes), "c@:")
	add(cls, "canBecomeKeyView", rawptr(yes), "c@:")
	add(cls, "isOpaque", rawptr(yes), "c@:")
	add(cls, "acceptsFirstMouse:", rawptr(yes_ev), "c@:@")

	// --- keys
	key_down :: proc "c" (self: NS.id, cmd: NS.SEL, ev: ^NS.Event) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			cocoa_key_down(w, self, ev)
		}
	}
	flags_changed :: proc "c" (self: NS.id, cmd: NS.SEL, ev: ^NS.Event) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			w.input.mods = cocoa_mods(ev)
			w.input_dirty = true
		}
	}
	key_up :: proc "c" (self: NS.id, cmd: NS.SEL, ev: ^NS.Event) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			w.input.mods = cocoa_mods(ev)
		}
	}
	add(cls, "keyDown:", rawptr(key_down), "v@:@")
	add(cls, "keyUp:", rawptr(key_up), "v@:@")
	add(cls, "flagsChanged:", rawptr(flags_changed), "v@:@")

	// --- pointer
	mouse :: proc "c" (self: NS.id, cmd: NS.SEL, ev: ^NS.Event) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			cocoa_mouse(w, ev)
		}
	}
	for sel in ([]cstring{
			"mouseDown:", "mouseUp:", "rightMouseDown:", "rightMouseUp:",
			"otherMouseDown:", "otherMouseUp:", "mouseMoved:", "mouseDragged:",
			"rightMouseDragged:", "otherMouseDragged:", "mouseEntered:",
			"mouseExited:", "scrollWheel:", "cursorUpdate:",
		}) {
		add(cls, sel, rawptr(mouse), "v@:@")
	}

	// --- NSTextInputClient
	insert_text :: proc "c" (self: NS.id, cmd: NS.SEL, str: NS.id, range: NS_Range) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			cocoa_insert_text(w, str)
		}
	}
	do_command :: proc "c" (self: NS.id, cmd: NS.SEL, sel: NS.SEL) {
		// Arrows, Return, Delete... arrive here as selectors. They were
		// already delivered as key events; there is no text to add.
	}
	set_marked :: proc "c" (self: NS.id, cmd: NS.SEL, str: NS.id, sel_range: NS_Range, repl: NS_Range) {}
	unmark :: proc "c" (self: NS.id, cmd: NS.SEL) {}
	no :: proc "c" (self: NS.id, cmd: NS.SEL) -> NS.BOOL {return false}
	no_range :: proc "c" (self: NS.id, cmd: NS.SEL) -> NS_Range {return {NS_NOT_FOUND, 0}}
	empty_array :: proc "c" (self: NS.id, cmd: NS.SEL) -> NS.id {
		return msg(NS.id, NS.Array, "array")
	}
	no_substring :: proc "c" (self: NS.id, cmd: NS.SEL, r: NS_Range, actual: ^NS_Range) -> NS.id {return nil}
	char_index :: proc "c" (self: NS.id, cmd: NS.SEL, p: NS.Point) -> NS.UInteger {return NS_NOT_FOUND}
	first_rect :: proc "c" (self: NS.id, cmd: NS.SEL, r: NS_Range, actual: ^NS_Range) -> NS.Rect {
		// Where an input method puts its candidate window: the bottom-left
		// of the window, in screen coordinates. palmy does not expose the
		// caret to the backend.
		context = g_cocoa.ctx
		w := view_window(self)
		if w == nil || w.cocoa.window == nil {
			return {}
		}
		f := NS.Window_frame(w.cocoa.window)
		return {f.origin, {0, 0}}
	}
	add(cls, "insertText:replacementRange:", rawptr(insert_text), "v@:@{_NSRange=QQ}")
	add(cls, "doCommandBySelector:", rawptr(do_command), "v@::")
	add(cls, "setMarkedText:selectedRange:replacementRange:", rawptr(set_marked), "v@:@{_NSRange=QQ}{_NSRange=QQ}")
	add(cls, "unmarkText", rawptr(unmark), "v@:")
	add(cls, "hasMarkedText", rawptr(no), "c@:")
	add(cls, "markedRange", rawptr(no_range), "{_NSRange=QQ}@:")
	add(cls, "selectedRange", rawptr(no_range), "{_NSRange=QQ}@:")
	add(cls, "validAttributesForMarkedText", rawptr(empty_array), "@@:")
	add(cls, "attributedSubstringForProposedRange:actualRange:", rawptr(no_substring), "@@:{_NSRange=QQ}^{_NSRange=QQ}")
	add(cls, "characterIndexForPoint:", rawptr(char_index), "Q@:{CGPoint=dd}")
	add(cls, "firstRectForCharacterRange:actualRange:", rawptr(first_rect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}")
	if p := NS.objc_getProtocol("NSTextInputClient"); p != nil {
		NS.class_addProtocol(cls, p)
	}

	// --- NSWindowDelegate
	should_close :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) -> NS.BOOL {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			w.should_close = true
			w.input_dirty = true
		}
		return false // the application decides, and destroys the window
	}
	did_resize :: proc "c" (self: NS.id, cmd: NS.SEL, note: NS.id) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			cocoa_sync_geometry(w)
		}
	}
	key_changed :: proc "c" (self: NS.id, cmd: NS.SEL, note: NS.id) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			key := bool(NS.Window_keyWindow(w.cocoa.window))
			w.activated = key
			w.input.focused = key
			if !key {
				w.input.mods = {}
			}
			w.input_dirty = true
		}
	}
	occlusion :: proc "c" (self: NS.id, cmd: NS.SEL, note: NS.id) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			cocoa_sync_occlusion(w)
		}
	}
	fullscreen :: proc "c" (self: NS.id, cmd: NS.SEL, note: NS.id) {
		context = g_cocoa.ctx
		if w := view_window(self); w != nil {
			mask := msg(NS.UInteger, w.cocoa.window, "styleMask")
			w.fullscreen = mask & (1 << 14) != 0 // NSWindowStyleMaskFullScreen
			cocoa_sync_geometry(w)
		}
	}
	add(cls, "windowShouldClose:", rawptr(should_close), "c@:@")
	add(cls, "windowDidResize:", rawptr(did_resize), "v@:@")
	add(cls, "windowDidChangeBackingProperties:", rawptr(did_resize), "v@:@")
	add(cls, "windowDidChangeScreen:", rawptr(did_resize), "v@:@")
	add(cls, "windowDidBecomeKey:", rawptr(key_changed), "v@:@")
	add(cls, "windowDidResignKey:", rawptr(key_changed), "v@:@")
	add(cls, "windowDidChangeOcclusionState:", rawptr(occlusion), "v@:@")
	add(cls, "windowDidMiniaturize:", rawptr(occlusion), "v@:@")
	add(cls, "windowDidDeminiaturize:", rawptr(occlusion), "v@:@")
	add(cls, "windowDidEnterFullScreen:", rawptr(fullscreen), "v@:@")
	add(cls, "windowDidExitFullScreen:", rawptr(fullscreen), "v@:@")

	NS.objc_registerClassPair(cls)
	g_cocoa.view_cls = cls
}

// ---------------------------------------------------------------------------
// Open and close
// ---------------------------------------------------------------------------

@(private)
cocoa_open :: proc(w: ^Window, decorate: bool) -> (err: string) {
	w.conn.fd = -1
	if w.use_layer {
		return "a layer surface needs wlr-layer-shell, which macOS has no equivalent of; open an ordinary window instead"
	}
	if e := cocoa_init(); e != "" {
		return e
	}
	NS.scoped_autoreleasepool()
	cs := &w.cocoa

	// `decorate` is ignored, as on X11: the window server's frame is how a
	// Mac window is moved, closed and resized, and palmy draws none of its
	// own, so a window without it could do none of those.
	style := NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable}
	rect := NS.Rect{{0, 0}, {NS.Float(w.width), NS.Float(w.height)}}
	win := NS.Window_initWithContentRect(NS.Window_alloc(), rect, style, .Buffered, false)
	if win == nil {
		return "could not create an NSWindow"
	}
	NS.Window_setReleasedWhenClosed(win, false)
	msg(nil, win, "setCollectionBehavior:", NS.UInteger(1 << 7)) // FullScreenPrimary

	view := (^NS.View)(NS.class_createInstance(g_cocoa.view_cls, size_of(^Window)))
	(^^Window)(NS.object_getIndexedIvars(view))^ = w
	view = msg(^NS.View, view, "initWithFrame:", rect)

	// Layer-hosting rather than layer-backed: set the layer before asking
	// for one, and AppKit never draws into it or replaces its contents.
	layer := msg(^NS.Layer, CA_Layer, "layer")
	msg(nil, layer, "retain")
	msg(nil, layer, "setContentsGravity:", ns_string("topLeft"))
	msg(nil, layer, "setOpaque:", NS.BOOL(true))
	NS.View_setLayer(view, layer)
	NS.View_setWantsLayer(view, true)

	NS.Window_setContentView(win, view)
	msg(nil, win, "setDelegate:", view)
	NS.Window_makeFirstResponder(win, view)
	NS.Window_setAcceptsMouseMovedEvents(win, true)
	NS.Window_setTitle(win, ns_string(w.title))

	// Enter, exit and moves over the whole view, whether or not it is key.
	TRACK_FLAGS :: NS.UInteger(0x01 | 0x02 | 0x20 | 0x80 | 0x200) // EnteredAndExited | MouseMoved | CursorUpdate? | ActiveAlways | InVisibleRect
	ta := msg(
		^NS.Object,
		msg(^NS_Tracking_Area, NS_Tracking_Area, "alloc"),
		"initWithRect:options:owner:userInfo:",
		NS.Rect{},
		NS.UInteger(0x01 | 0x02 | 0x80 | 0x200),
		view,
		NS.id(nil),
	)
	msg(nil, view, "addTrackingArea:", ta)

	cs.window = win
	cs.view = view
	cs.layer = layer
	cs.tracking = ta
	cs.visible = true
	cs.cursor = .Default
	cs.interval = 1_000_000_000 / 60
	cs.open = true

	NS.Window_center(win)
	NS.Window_makeKeyAndOrderFront(win, nil)
	if os.get_env("PALMY_MAC_NO_ACTIVATE", context.temp_allocator) != "1" {
		NS.Application_activateIgnoringOtherApps(g_cocoa.app, true)
	}

	// The window number is what `screencapture -l` takes.
	if os.get_env("PALMY_MAC_DEBUG", context.temp_allocator) == "1" {
		fmt.eprintfln("palmy-cocoa: window %d pid %d", msg(NS.Integer, win, "windowNumber"), posix.getpid())
	}
	append(&g_cocoa.windows, w)
	cocoa_wake_attach(w)
	cocoa_sync_geometry(w)
	w.width = w.pending_width
	w.height = w.pending_height
	w.configured = true
	return ""
}

@(private)
cocoa_close :: proc(w: ^Window) {
	cs := &w.cocoa
	if !cs.open {
		return
	}
	NS.scoped_autoreleasepool()
	cocoa_wake_detach(w)
	intrinsics.atomic_store(&w.wake_deadline, 0)
	cocoa_timer_precision(w)
	for x, i in g_cocoa.windows {
		if x == w {
			unordered_remove(&g_cocoa.windows, i)
			break
		}
	}
	(^^Window)(NS.object_getIndexedIvars(cs.view))^ = nil
	msg(nil, cs.window, "setDelegate:", NS.id(nil))
	NS.Window_orderOut(cs.window, nil)
	NS.Window_close(cs.window)
	msg(nil, cs.tracking, "release")
	msg(nil, cs.layer, "release")
	msg(nil, cs.view, "release")
	msg(nil, cs.window, "release")
	cocoa_destroy_buffers(w)
	cs^ = {}
}

// cocoa_sync_geometry reads the content size and the backing scale, which is
// what a configure carries on the other backends.
@(private)
cocoa_sync_geometry :: proc(w: ^Window) {
	cs := &w.cocoa
	if cs.view == nil {
		return
	}
	b := NS.View_bounds(cs.view)
	pw, ph := int(math.round(f64(b.size.width))), int(math.round(f64(b.size.height)))
	scale := max(int(math.round(f64(NS.Window_backingScaleFactor(cs.window)))), 1)
	if pw > 0 && ph > 0 {
		w.pending_width, w.pending_height = pw, ph
	}
	w.pending_scale = scale
	w.maximized = bool(msg(NS.BOOL, cs.window, "isZoomed"))
	if scr := NS.Window_screen(cs.window); scr != nil {
		fps := int(msg(NS.Integer, scr, "maximumFramesPerSecond"))
		if fps > 0 {
			cs.interval = 1_000_000_000 / i64(fps)
		}
	}
	w.input_dirty = true
}

@(private)
cocoa_sync_occlusion :: proc(w: ^Window) {
	cs := &w.cocoa
	if cs.window == nil {
		return
	}
	state := msg(NS.UInteger, cs.window, "occlusionState")
	mini := bool(msg(NS.BOOL, cs.window, "isMiniaturized"))
	was := cs.visible
	cs.visible = state & 2 != 0 && !mini // NSWindowOcclusionStateVisible
	if cs.visible && !was {
		// Seen again: the "callback" that was withheld arrives now.
		w.frame_pending = false
		w.frame_ready = true
		w.input_dirty = true
	}
}

// ---------------------------------------------------------------------------
// Buffers and present
// ---------------------------------------------------------------------------

@(private)
cocoa_destroy_buffers :: proc(w: ^Window) {
	for &b in w.buffers {
		delete(b.px)
		b = {}
	}
}

@(private)
cocoa_alloc_buffers :: proc(w: ^Window) -> string {
	cocoa_destroy_buffers(w)
	dw, dh := w.width * w.scale, w.height * w.scale
	for &b in w.buffers {
		b.px = make([]u32, dw * dh)
		b.w, b.h = dw, dh
		b.busy = false
	}
	return ""
}

@(private)
cocoa_present :: proc(w: ^Window, b: ^Shm_Buffer) -> bool {
	cs := &w.cocoa
	if !cs.open {
		return false
	}
	// As on Wayland: an unchanged frame is not sent at all.
	if !frame_damage(&w.damage, b.px, b.w, b.h) && !w.need_configure_ack {
		w.damage.skipped += 1
		w.damage.hold_until = time.time_add(time.now(), SKIP_HOLD_MS * time.Millisecond)
		return false
	}
	NS.scoped_autoreleasepool()
	bytes := b.w * b.h * 4
	data := CFDataCreate(nil, ([^]u8)(raw_data(b.px)), bytes)
	prov := CGDataProviderCreateWithCFData(data)
	img := CGImageCreate(uint(b.w), uint(b.h), 8, 32, uint(b.w * 4), g_cocoa.srgb, CG_BITMAP_INFO, prov, nil, false, 0)
	msg(nil, CA_Transaction, "begin")
	msg(nil, CA_Transaction, "setDisableActions:", NS.BOOL(true))
	msg(nil, cs.layer, "setContentsScale:", NS.Float(w.scale))
	msg(nil, cs.layer, "setContents:", img)
	msg(nil, CA_Transaction, "commit")
	CGImageRelease(img)
	CGDataProviderRelease(prov)
	CFRelease(data)

	cs.presents += 1
	cs.last_w, cs.last_h = b.w, b.h
	w.need_configure_ack = false
	w.frame_pending = true
	cs.frame_due = mono_ns(w) + cs.interval
	w.last_present = time.now()
	return true
}

// ---------------------------------------------------------------------------
// Waiting
// ---------------------------------------------------------------------------

@(private)
cocoa_wait :: proc(w: ^Window, timeout_ms: int) -> bool {
	cs := &w.cocoa
	if w.conn.fatal != "" || !cs.open {
		return false
	}
	NS.scoped_autoreleasepool()

	pace :: proc(w: ^Window) {
		if w.frame_pending && w.cocoa.visible && mono_ns(w) >= w.cocoa.frame_due {
			w.frame_pending = false
			w.frame_ready = true
		}
	}
	shorter :: proc(a, b: int) -> int {
		return b if a < 0 || (b >= 0 && b < a) else a
	}

	pace(w)
	timeout := wake_cap(w, timeout_ms)
	if w.frame_pending && cs.visible {
		left := (cs.frame_due - mono_ns(w) + 999_999) / 1_000_000
		timeout = shorter(timeout, int(max(left, 0)))
	}
	if .Clipboard in w.clip.watch.kinds {
		timeout = shorter(timeout, CLIP_POLL_MS)
	}

	if cs.wake_cf != nil {
		CFFileDescriptorEnableCallBacks(cs.wake_cf, CF_READ_CALLBACK)
	}
	cocoa_timer_precision(w)
	until := timeout < 0 ? NS.Date_distantFuture() : NS.Date_dateWithTimeIntervalSinceNow(NS.TimeInterval(f64(timeout) / 1000))
	ev := NS.Application_nextEventMatchingMask(g_cocoa.app, NS.EventMaskAny, until, NS.DefaultRunLoopMode, true)
	for ev != nil {
		if NS.Event_type(ev) != .ApplicationDefined {
			NS.Application_sendEvent(g_cocoa.app, ev)
		}
		ev = NS.Application_nextEventMatchingMask(g_cocoa.app, NS.EventMaskAny, NS.Date_distantPast(), NS.DefaultRunLoopMode, true)
	}

	drain_wake(w)
	pace(w)
	clip_poll(w)
	return w.conn.fatal == "" && cs.open
}

// cocoa_timer_precision keeps an armed `wake_after` on time.
//
// When none of an application's windows can be seen, App Nap coalesces its
// timers: measured with a window on another Space for 45 s, six
// wake_after(500 ms) ran 98-118 ms late without this and 1-2 ms late with it.
// A password manager's clipboard clear is exactly a deadline on a window
// nobody is looking at. So while a deadline is armed the process
// holds a user-initiated, latency-critical activity, which exempts it from
// App Nap; with no deadline it holds none, and an idle window naps (it is
// parked with no timer at all then, so there is nothing to coalesce).
@(private)
cocoa_timer_precision :: proc(w: ^Window) {
	cs := &w.cocoa
	armed := intrinsics.atomic_load(&w.wake_deadline) != 0
	pi := NS.ProcessInfo_processInfo()
	if armed && cs.activity == nil {
		// NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
		opts := u64(0x00FF_FFFF) &~ u64(1 << 20) | u64(0xFF_0000_0000)
		a := msg(^NS.Object, pi, "beginActivityWithOptions:reason:", opts, ns_string("palmy: a wake_after deadline is armed"))
		cs.activity = msg(^NS.Object, a, "retain")
	} else if !armed && cs.activity != nil {
		msg(nil, pi, "endActivity:", cs.activity)
		msg(nil, cs.activity, "release")
		cs.activity = nil
	}
}

// The wake descriptor (window.odin): a kqueue with one user event.

@(private)
WAKE_IDENT :: 1

@(private)
cocoa_wake_fd :: proc() -> (linux.Fd, linux.Errno) {
	kq, err := kqueue.kqueue()
	if err != nil {
		return -1, linux.Errno(int(err))
	}
	posix.fcntl(kq, .SETFD, posix.FD_CLOEXEC)
	ch := [1]kqueue.KEvent{{ident = WAKE_IDENT, filter = .User, flags = {.Add, .Clear}}}
	if _, kerr := kqueue.kevent(kq, ch[:], nil, nil); kerr != nil {
		posix.close(kq)
		return -1, linux.Errno(int(kerr))
	}
	return linux.Fd(kq), .NONE
}

@(private)
cocoa_wake_fd_close :: proc(fd: linux.Fd) {
	posix.close(posix.FD(fd))
}

@(private)
cocoa_wake_fd_poke :: proc "contextless" (fd: linux.Fd) {
	ch := [1]kqueue.KEvent{{ident = WAKE_IDENT, filter = .User}}
	ch[0].fflags.user = {.Trigger}
	context = runtime.default_context()
	kqueue.kevent(posix.FD(fd), ch[:], nil, nil)
}

// cocoa_wake_fd_read collects a pending wake without blocking: (1, .NONE)
// when there was one, (0, .EAGAIN) when the queue is empty, as the eventfd
// read it stands in for.
@(private)
cocoa_wake_fd_read :: proc(fd: linux.Fd, buf: []u8) -> (int, linux.Errno) {
	evs: [4]kqueue.KEvent
	zero := posix.timespec{}
	n, err := kqueue.kevent(posix.FD(fd), nil, evs[:], &zero)
	if err != nil {
		return 0, linux.Errno(int(err))
	}
	if n == 0 {
		return 0, .EAGAIN
	}
	return int(n), .NONE
}

@(private)
cocoa_wake_attach :: proc(w: ^Window) {
	cs := &w.cocoa
	if w.wake_fd <= 0 {
		return
	}
	cs.wake_ctx = {info = w}
	callback :: proc "c" (f: rawptr, types: c.ulong, info: rawptr) {
		// On the main thread, inside nextEventMatchingMask: posting an
		// event is what ends that wait. The event itself is dropped.
		context = g_cocoa.ctx
		NS.scoped_autoreleasepool()
		ev := msg(
			^NS.Event,
			NS.Event,
			"otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
			NS.EventType.ApplicationDefined,
			NS.Point{},
			NS.UInteger(0),
			NS.TimeInterval(0),
			NS.Integer(0),
			NS.id(nil),
			i16(0),
			NS.Integer(0),
			NS.Integer(0),
		)
		NS.Application_postEvent(g_cocoa.app, ev, true)
	}
	cs.wake_cf = CFFileDescriptorCreate(nil, c.int(w.wake_fd), false, callback, &cs.wake_ctx)
	if cs.wake_cf == nil {
		return
	}
	cs.wake_src = CFFileDescriptorCreateRunLoopSource(nil, cs.wake_cf, 0)
	CFRunLoopAddSource(CFRunLoopGetMain(), cs.wake_src, kCFRunLoopCommonModes)
	CFFileDescriptorEnableCallBacks(cs.wake_cf, CF_READ_CALLBACK)
}

@(private)
cocoa_wake_detach :: proc(w: ^Window) {
	cs := &w.cocoa
	if cs.wake_src != nil {
		CFRunLoopRemoveSource(CFRunLoopGetMain(), cs.wake_src, kCFRunLoopCommonModes)
		CFRelease(cs.wake_src)
		cs.wake_src = nil
	}
	if cs.wake_cf != nil {
		CFFileDescriptorInvalidate(cs.wake_cf)
		CFRelease(cs.wake_cf)
		cs.wake_cf = nil
	}
}

// darwin_poll is poll_fds on macOS. struct pollfd is the same 8 bytes, and
// POLLIN, POLLPRI, POLLOUT, POLLERR, POLLHUP and POLLNVAL have the same
// values as on Linux; a negative timeout already means forever. Errors come
// back as the Linux errno of the same meaning, so callers comparing with
// .EINTR and .EAGAIN keep working.
@(private)
darwin_poll :: proc(fds: []linux.Poll_Fd, timeout_ms: int) -> (i32, linux.Errno) {
	#assert(size_of(linux.Poll_Fd) == size_of(posix.pollfd))
	t := c.int(timeout_ms < 0 ? -1 : min(timeout_ms, int(max(c.int))))
	n := posix.poll(([^]posix.pollfd)(raw_data(fds)), posix.nfds_t(len(fds)), t)
	if n < 0 {
		return 0, linux_errno(posix.errno())
	}
	return i32(n), .NONE
}

@(private)
linux_errno :: proc(e: posix.Errno) -> linux.Errno {
	#partial switch e {
	case .EINTR:
		return .EINTR
	case .EAGAIN:
		return .EAGAIN
	case .EINVAL:
		return .EINVAL
	case .ENOMEM:
		return .ENOMEM
	case .EFAULT:
		return .EFAULT
	case .EBADF:
		return .EBADF
	}
	return .EINVAL
}

// ---------------------------------------------------------------------------
// Toplevel controls
// ---------------------------------------------------------------------------

@(private)
cocoa_set_title :: proc(w: ^Window) {
	if !w.cocoa.open {
		return
	}
	NS.scoped_autoreleasepool()
	NS.Window_setTitle(w.cocoa.window, ns_string(w.title))
}

@(private)
cocoa_set_min_size :: proc(w: ^Window, width, height: int) {
	if !w.cocoa.open {
		return
	}
	msg(nil, w.cocoa.window, "setContentMinSize:", NS.Size{NS.Float(width), NS.Float(height)})
}

@(private)
cocoa_set_fullscreen :: proc(w: ^Window, on: bool) {
	if !w.cocoa.open || on == w.fullscreen {
		return
	}
	NS.Window_toggleFullScreen(w.cocoa.window, nil)
}

@(private)
cocoa_set_cursor :: proc(w: ^Window, want: Cursor) {
	w.cocoa.cursor = want
	if w.cocoa.open && w.input.over_surface {
		cocoa_apply_cursor(want)
	}
}

@(private)
cocoa_apply_cursor :: proc(want: Cursor) {
	sel: string
	switch want {
	case .Inherit, .Default, .Wait, .Progress, .Help:
		sel = "arrowCursor"
	case .Pointer:
		sel = "pointingHandCursor"
	case .Text:
		sel = "IBeamCursor"
	case .Crosshair:
		sel = "crosshairCursor"
	case .Move, .Grab:
		sel = "openHandCursor"
	case .Grabbing:
		sel = "closedHandCursor"
	case .Not_Allowed:
		sel = "operationNotAllowedCursor"
	case .Col_Resize:
		sel = "resizeLeftRightCursor"
	case .Row_Resize:
		sel = "resizeUpDownCursor"
	}
	cls := intrinsics.objc_find_class("NSCursor")
	cur := NS.objc_lookUpClass("NSCursor")
	_ = cls
	csel := strings.clone_to_cstring(sel, context.temp_allocator)
	cursor := msg(^NS.Object, (^NS.Object)(cur), "performSelector:", NS.sel_registerName(csel))
	if cursor != nil {
		msg(nil, cursor, "set")
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

@(private)
NS_FLAG_CAPS :: NS.UInteger(1 << 16)
@(private)
NS_FLAG_SHIFT :: NS.UInteger(1 << 17)
@(private)
NS_FLAG_CONTROL :: NS.UInteger(1 << 18)
@(private)
NS_FLAG_OPTION :: NS.UInteger(1 << 19)
@(private)
NS_FLAG_COMMAND :: NS.UInteger(1 << 20)

@(private)
cocoa_mods :: proc(ev: ^NS.Event) -> Modifiers {
	f := msg(NS.UInteger, ev, "modifierFlags")
	m: Modifiers
	if f & NS_FLAG_SHIFT != 0 {m += {.Shift}}
	if f & NS_FLAG_CONTROL != 0 {m += {.Ctrl}}
	if f & NS_FLAG_OPTION != 0 {m += {.Alt}}
	if f & NS_FLAG_COMMAND != 0 {
		m += g_cocoa.cmd_super ? {.Super} : {.Ctrl}
	}
	if f & NS_FLAG_CAPS != 0 {m += {.Caps}}
	return m
}

// cocoa_point is the event's position in the view, in logical pixels, from
// the top-left as palmy measures.
@(private)
cocoa_point :: proc(w: ^Window, ev: ^NS.Event) -> [2]f32 {
	p := NS.Event_locationInWindow(ev)
	b := NS.View_bounds(w.cocoa.view)
	return {f32(p.x), f32(b.size.height - p.y)}
}

@(private)
cocoa_mouse :: proc(w: ^Window, ev: ^NS.Event) {
	in_ := &w.input
	t := NS.Event_type(ev)
	p := cocoa_point(w, ev)
	in_.mods = cocoa_mods(ev)
	inside := p.x >= 0 && p.y >= 0 && p.x < f32(w.width) && p.y < f32(w.height)

	button :: proc(ev: ^NS.Event) -> Mouse_Button {
		switch NS.Event_buttonNumber(ev) {
		case 1:
			return .Right
		case 2:
			return .Middle
		}
		return .Left
	}

	#partial switch t {
	case .LeftMouseDown, .RightMouseDown, .OtherMouseDown:
		mb := t == .LeftMouseDown ? Mouse_Button.Left : t == .RightMouseDown ? .Right : button(ev)
		in_.mouse = p
		in_.over_surface = true
		in_.down[mb] = true
		in_.pressed[mb] = true
		w.cocoa.clicks += 1
		in_.click_serial = w.cocoa.clicks
	case .LeftMouseUp, .RightMouseUp, .OtherMouseUp:
		mb := t == .LeftMouseUp ? Mouse_Button.Left : t == .RightMouseUp ? .Right : button(ev)
		in_.mouse = p
		in_.down[mb] = false
		in_.released[mb] = true
	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged, .OtherMouseDragged:
		in_.mouse_delta += p - in_.mouse
		in_.mouse = p
		was := in_.over_surface
		in_.over_surface = inside || in_.down[.Left] || in_.down[.Right] || in_.down[.Middle]
		if in_.over_surface && (!was || w.cocoa.cursor != .Default) {
			cocoa_apply_cursor(w.cocoa.cursor)
		}
	case .MouseEntered:
		in_.mouse = p
		in_.over_surface = true
		cocoa_apply_cursor(w.cocoa.cursor)
	case .MouseExited:
		in_.over_surface = false
	case .CursorUpdate:
		cocoa_apply_cursor(w.cocoa.cursor)
		return
	case .ScrollWheel:
		dx := f32(NS.Event_scrollingDeltaX(ev))
		dy := f32(NS.Event_scrollingDeltaY(ev))
		if !bool(NS.Event_hasPreciseScrollingDeltas(ev)) {
			// A wheel reports lines; palmy's unit is one notch = SCROLL_NOTCH.
			dx *= SCROLL_NOTCH
			dy *= SCROLL_NOTCH
		}
		// AppKit's deltas follow the content (positive moves it down);
		// palmy's follow the viewport, as a Wayland axis value does.
		in_.scroll.x -= dx
		in_.scroll.y -= dy
		in_.mouse = p
	case:
		return
	}
	w.input_dirty = true
}

@(private)
cocoa_key_down :: proc(w: ^Window, view: NS.id, ev: ^NS.Event) {
	mods := cocoa_mods(ev)
	w.input.mods = mods
	code := u16(NS.Event_keyCode(ev))
	sym := mac_special_sym(code)
	unshifted := sym
	if sym == 0 {
		sym = keysym_of(event_rune(msg(^NS.String, ev, "charactersIgnoringModifiers")))
		unshifted = keysym_of(event_rune(msg(^NS.String, ev, "charactersByApplyingModifiers:", NS.UInteger(0))))
		if sym == 0 {
			sym = unshifted
		}
	}
	if sym != 0 {
		append(&w.input.keys, Key_Event{sym = sym, mods = mods, repeat = bool(NS.Event_isARepeat(ev)), unshifted = unshifted})
	}
	w.input_dirty = true

	// Text, through the input system: dead keys and input methods compose
	// here. Shortcuts type nothing, as feed_key decides on Linux.
	if .Ctrl not_in mods && .Super not_in mods {
		w.cocoa.in_key_down = true
		arr := msg(^NS.Array, NS.Array, "arrayWithObject:", ev)
		msg(nil, (^NS.Object)(view), "interpretKeyEvents:", arr)
		w.cocoa.in_key_down = false
	}
}

@(private)
cocoa_insert_text :: proc(w: ^Window, str: NS.id) {
	s := (^NS.String)(str)
	if bool(msg(NS.BOOL, (^NS.Object)(str), "isKindOfClass:", intrinsics.objc_find_class("NSAttributedString"))) {
		s = msg(^NS.String, (^NS.Object)(str), "string")
	}
	if s == nil {
		return
	}
	text := string(NS.String_UTF8String(s))
	for r in text {
		// Control characters and AppKit's private-use function-key
		// characters are keys, not text.
		if r < 0x20 || r == 0x7f || (r >= 0xf700 && r <= 0xf8ff) {
			continue
		}
		strings.write_rune(&w.input.text, r)
	}
	w.input_dirty = true
}

@(private)
event_rune :: proc(s: ^NS.String) -> rune {
	if s == nil {
		return 0
	}
	t := string(NS.String_UTF8String(s))
	if t == "" {
		return 0
	}
	r, _ := utf8.decode_rune_in_string(t)
	return r
}

// keysym_of is the X keysym for a character: Latin-1 is its own keysym,
// everything else is 0x01000000 + the code point.
@(private)
keysym_of :: proc(r: rune) -> u32 {
	switch {
	case r <= 0:
		return 0
	case r >= 0xf700 && r <= 0xf8ff:
		return 0 // AppKit's function-key characters; the key code says it
	case r == 0x7f:
		return KEY_DELETE
	case r < 0x20:
		return 0
	case r < 0x100:
		return u32(r)
	}
	return 0x0100_0000 | u32(r)
}

// mac_special_sym maps the virtual key codes (Carbon's kVK_*) whose meaning
// does not depend on the layout.
@(private)
mac_special_sym :: proc(code: u16) -> u32 {
	switch code {
	case 0x24: return KEY_RETURN
	case 0x30: return KEY_TAB
	case 0x31: return KEY_SPACE
	case 0x33: return KEY_BACKSPACE
	case 0x35: return KEY_ESCAPE
	case 0x75: return KEY_DELETE
	case 0x73: return KEY_HOME
	case 0x77: return KEY_END
	case 0x74: return KEY_PAGE_UP
	case 0x79: return KEY_PAGE_DOWN
	case 0x7b: return KEY_LEFT
	case 0x7c: return KEY_RIGHT
	case 0x7d: return KEY_DOWN
	case 0x7e: return KEY_UP
	case 0x72: return KEY_INSERT // Help, where Insert sits on a PC keyboard
	case 0x6e: return KEY_MENU
	case 0x7a: return KEY_F1
	case 0x78: return KEY_F2
	case 0x63: return KEY_F3
	case 0x76: return KEY_F4
	case 0x60: return KEY_F5
	case 0x61: return KEY_F6
	case 0x62: return KEY_F7
	case 0x64: return KEY_F8
	case 0x65: return KEY_F9
	case 0x6d: return KEY_F10
	case 0x67: return KEY_F11
	case 0x6f: return KEY_F12
	case 0x69: return KEY_F13
	case 0x6b: return KEY_F14
	case 0x71: return KEY_F15
	case 0x6a: return KEY_F16
	case 0x40: return KEY_F17
	case 0x4f: return KEY_F18
	case 0x50: return KEY_F19
	case 0x5a: return KEY_F20
	case 0x4c: return KEY_KP_ENTER
	case 0x52: return KEY_KP_0
	case 0x53: return KEY_KP_1
	case 0x54: return KEY_KP_2
	case 0x55: return KEY_KP_3
	case 0x56: return KEY_KP_4
	case 0x57: return KEY_KP_5
	case 0x58: return KEY_KP_6
	case 0x59: return KEY_KP_7
	case 0x5b: return KEY_KP_8
	case 0x5c: return KEY_KP_9
	case 0x41: return KEY_KP_DECIMAL
	case 0x43: return KEY_KP_MUL
	case 0x45: return KEY_KP_ADD
	case 0x4e: return KEY_KP_SUB
	case 0x4b: return KEY_KP_DIV
	}
	return 0
}
