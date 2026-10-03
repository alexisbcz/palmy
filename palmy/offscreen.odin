package palmy

import "core:strings"
import stbi "vendor:stb/image"

// Offscreen renders the same UI into an ordinary pixel buffer, with no
// compositor involved. It is what the tests drive, and it is the easy way to
// produce a screenshot in CI or to render a UI into a texture.
//
//	off := palmy.offscreen_create(800, 600)
//	defer palmy.offscreen_destroy(off)
//
//	ui := palmy.offscreen_begin(off)
//	palmy.text(ui, "Hello", "text-2xl font-bold")
//	palmy.offscreen_end(off)
//	palmy.offscreen_write_png(off, "shot.png")
Offscreen :: struct {
	ctx:        Ctx,
	fonts:      Fonts,
	canvas:     Canvas,
	input:      Input,
	px:         []u32,
	width:      int,
	height:     int,

	// The layout viewport, which may be fractional and smaller than the
	// canvas. A browser lays an element out at a subpixel width and the
	// screenshot is the enclosing whole pixels; matching that needs both.
	view:       [2]f32,
	scale:      f32,
	root_class: string,
	dt:         f32,
}

offscreen_create :: proc(width, height: int, scale: f32 = 1, root_class := "w-full h-full bg-slate-950 text-slate-200") -> ^Offscreen {
	o := new(Offscreen)
	o.width, o.height, o.scale = width, height, scale
	o.view = {f32(width), f32(height)}
	o.root_class = strings.clone(root_class)
	o.dt = 1.0 / 60

	dw := int(f32(width) * scale)
	dh := int(f32(height) * scale)
	o.px = make([]u32, dw * dh)
	o.canvas = canvas_from(o.px, dw, dh, scale)

	fonts_init(&o.fonts)
	ctx_init(&o.ctx)
	o.ctx.fonts = &o.fonts
	o.input.text = strings.builder_make()
	o.ctx.input = &o.input
	return o
}

offscreen_destroy :: proc(o: ^Offscreen) {
	if o == nil {
		return
	}
	canvas_destroy(&o.canvas)
	ctx_destroy(&o.ctx)
	fonts_destroy(&o.fonts)
	delete(o.px)
	delete(o.root_class)
	delete(o.input.keys)
	strings.builder_destroy(&o.input.text)
	free(o)
}

// offscreen_begin opens a frame and returns the context to build into.
offscreen_begin :: proc(o: ^Offscreen) -> ^Ctx {
	o.ctx.dt = o.dt
	o.ctx.now += f64(o.dt)
	reset_clip(&o.canvas)
	begin_ui(&o.ctx, &o.input, o.view, o.root_class)
	return &o.ctx
}

// offscreen_end lays out and paints the frame, then clears the input edges the
// way the windowed loop does.
offscreen_end :: proc(o: ^Offscreen) {
	end_ui(&o.ctx, &o.canvas)
	clear_edges(&o.input)
	free_all(context.temp_allocator)
}

// offscreen_viewport overrides the layout size, which may be fractional and
// need not fill the canvas. Everything outside it keeps the canvas background.
offscreen_viewport :: proc(o: ^Offscreen, w, h: f32) {
	o.view = {w, h}
}

// offscreen_pixels is the rendered buffer, 0xffRRGGBB per pixel.
offscreen_pixels :: proc(o: ^Offscreen) -> []u32 {
	return o.px
}

offscreen_canvas :: proc(o: ^Offscreen) -> ^Canvas {
	return &o.canvas
}

// offscreen_pixel reads one device pixel, which is what assertions use.
offscreen_pixel :: proc(o: ^Offscreen, x, y: int) -> Color {
	return get(&o.canvas, x, y)
}

// offscreen_write_png saves the frame.
offscreen_write_png :: proc(o: ^Offscreen, path: string) -> bool {
	rgba := make([]u8, len(o.px) * 4)
	defer delete(rgba)
	for v, i in o.px {
		rgba[i * 4 + 0] = u8(v >> 16)
		rgba[i * 4 + 1] = u8(v >> 8)
		rgba[i * 4 + 2] = u8(v)
		rgba[i * 4 + 3] = 255
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return stbi.write_png(cpath, i32(o.canvas.w), i32(o.canvas.h), 4, raw_data(rgba), i32(o.canvas.w * 4)) != 0
}

// ---------------------------------------------------------------------------
// Synthetic input, for tests and scripted demos
// ---------------------------------------------------------------------------

// move_pointer places the pointer, in logical pixels.
move_pointer :: proc(o: ^Offscreen, x, y: f32) {
	o.input.mouse_delta += {x, y} - o.input.mouse
	o.input.mouse = {x, y}
	o.input.over_surface = true
}

// press and release drive a button through a full click. A click is press on a
// frame and release on a later one, exactly as a real pointer delivers it.
press :: proc(o: ^Offscreen, b := Mouse_Button.Left) {
	o.input.down[b] = true
	o.input.pressed[b] = true
}

release :: proc(o: ^Offscreen, b := Mouse_Button.Left) {
	o.input.down[b] = false
	o.input.released[b] = true
}

// scroll_by queues wheel movement.
scroll_by :: proc(o: ^Offscreen, dx, dy: f32) {
	o.input.scroll += {dx, dy}
}

// type_text queues printable input.
type_text :: proc(o: ^Offscreen, s: string) {
	strings.write_string(&o.input.text, s)
}

// press_key queues a keysym, with optional modifiers.
press_key :: proc(o: ^Offscreen, sym: u32, mods: Modifiers = {}) {
	o.input.mods = mods
	append(&o.input.keys, Key_Event{sym = sym, mods = mods})
}
