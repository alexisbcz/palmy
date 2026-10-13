// cursor.odin — the pointer's shape (UX.md P0-7).
//
// On bare metal there is no host to draw the cursor, so the window manager
// draws it last, every frame. It used to be one fixed arrow over edges,
// corners, title bars and text alike. Now it is a set of shapes, each with a
// hotspot, chosen by what is under the pointer:
//
//   - over the window manager's own chrome (edges, corners, a title bar
//     being dragged, menus), interact.odin picks the shape;
//   - over a client, the client's own choice wins, through either of the two
//     ways Wayland offers: `wp_cursor_shape_manager_v1.set_shape` names a
//     shape from the same set (palmy's toolkit asks for the I-beam over text
//     this way), and `wl_pointer.set_cursor` hands over a surface, whose
//     latest buffer is drawn as the cursor at its hotspot (a null surface
//     hides it).
//
// The shapes are vector outlines rasterized once, at startup, into 32 x 32
// ARGB images: white fill, a black outline grown from the fill. Nested, the
// host draws the pointer and is only told the nearest shape palmy names.
package wm

import "core:math"
import p "palmy:."

Cursor_Shape :: enum u8 {
	Default,
	Client, // whatever the client under the pointer asked for
	Hidden,
	Move,
	Grab,
	Grabbing,
	N,
	S,
	E,
	W,
	NE,
	NW,
	SE,
	SW,
	EW,
	NS,
	NESW,
	NWSE,
	Text,
	Pointer,
	Not_Allowed,
	Wait,
	Crosshair,
}

CURSOR_SIZE :: 32

Cursor_Img :: struct {
	px:     [CURSOR_SIZE * CURSOR_SIZE]u32,
	hx, hy: int,
	built:  bool,
}

cursor_imgs: [Cursor_Shape]Cursor_Img

// What each client last asked the pointer to look like over its surfaces.
Client_Cursor :: struct {
	shape: Cursor_Shape,
	surf:  ^Surface, // wl_pointer.set_cursor's surface, when that was used last
	hot:   [2]int,
	use_surface: bool,
}

client_cursors: map[^Client]Client_Cursor

cursor_for_edges :: proc(e: Edges) -> Cursor_Shape {
	switch e {
	case {.Left}:
		return .W
	case {.Right}:
		return .E
	case {.Top}:
		return .N
	case {.Bottom}:
		return .S
	case {.Top, .Left}:
		return .NW
	case {.Top, .Right}:
		return .NE
	case {.Bottom, .Left}:
		return .SW
	case {.Bottom, .Right}:
		return .SE
	}
	return .Default
}

// cursor_from_wp maps the wp_cursor_shape_device_v1.shape enum onto the set;
// a shape the set does not have falls back to the nearest one, or the arrow.
cursor_from_wp :: proc(code: u32) -> Cursor_Shape {
	switch code {
	case 4:
		return .Pointer
	case 5, 6:
		return .Wait
	case 7, 8:
		return .Crosshair
	case 9, 10:
		return .Text
	case 13, 32:
		return .Move
	case 14, 15:
		return .Not_Allowed
	case 16:
		return .Grab
	case 17:
		return .Grabbing
	case 18:
		return .E
	case 19:
		return .N
	case 20:
		return .NE
	case 21:
		return .NW
	case 22:
		return .S
	case 23:
		return .SE
	case 24:
		return .SW
	case 25:
		return .W
	case 26, 30:
		return .EW
	case 27, 31:
		return .NS
	case 28:
		return .NESW
	case 29:
		return .NWSE
	}
	return .Default
}

// ---------------------------------------------------------------------------
// Rasterizing the shapes
// ---------------------------------------------------------------------------

Cur_Poly :: struct {
	pts: [dynamic][2]f32,
	sub: bool, // cut out of what came before, instead of added
}

cur_poly :: proc(polys: ^[dynamic]Cur_Poly, pts: ..[2]f32) {
	pl := Cur_Poly{pts = make([dynamic][2]f32, 0, len(pts), context.temp_allocator)}
	for v in pts {
		append(&pl.pts, v)
	}
	append(polys, pl)
}

cur_rect :: proc(polys: ^[dynamic]Cur_Poly, x, y, w, h: f32, sub := false) {
	cur_poly(polys, {x, y}, {x + w, y}, {x + w, y + h}, {x, y + h})
	polys[len(polys) - 1].sub = sub
}

cur_circle :: proc(polys: ^[dynamic]Cur_Poly, cx, cy, r: f32, sub := false) {
	pl := Cur_Poly{pts = make([dynamic][2]f32, 0, 32, context.temp_allocator), sub = sub}
	for i in 0 ..< 32 {
		a := f32(i) / 32 * 2 * math.PI
		append(&pl.pts, [2]f32{cx + r * math.cos(a), cy + r * math.sin(a)})
	}
	append(polys, pl)
}

// cur_double_arrow is a two-headed arrow through (cx, cy) at angle `ang`.
cur_double_arrow :: proc(polys: ^[dynamic]Cur_Poly, cx, cy, ang: f32, half: f32 = 11, shaft: f32 = 1.6, head: f32 = 5, head_w: f32 = 5) {
	pts := [?][2]f32 {
		{-half, 0},
		{-half + head, -head_w},
		{-half + head, -shaft},
		{half - head, -shaft},
		{half - head, -head_w},
		{half, 0},
		{half - head, head_w},
		{half - head, shaft},
		{-half + head, shaft},
		{-half + head, head_w},
	}
	pl := Cur_Poly{pts = make([dynamic][2]f32, 0, len(pts), context.temp_allocator)}
	c, sn := math.cos(ang), math.sin(ang)
	for v in pts {
		append(&pl.pts, [2]f32{cx + v.x * c - v.y * sn, cy + v.x * sn + v.y * c})
	}
	append(polys, pl)
}

// cur_inside is the even-odd point-in-polygon test.
cur_inside :: proc(pts: [][2]f32, x, y: f32) -> bool {
	in_ := false
	j := len(pts) - 1
	for i in 0 ..< len(pts) {
		a := pts[i]
		b := pts[j]
		if (a.y > y) != (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
			in_ = !in_
		}
		j = i
	}
	return in_
}

// cursor_raster turns a list of polygons into a cursor image: coverage by
// 4 x 4 supersampling, an outline grown 1.5 px out of the fill.
cursor_raster :: proc(img: ^Cursor_Img, polys: []Cur_Poly, hx, hy: int) {
	N :: CURSOR_SIZE
	fill: [N * N]f32
	for y in 0 ..< N {
		for x in 0 ..< N {
			hits := 0
			for sy in 0 ..< 4 {
				for sx in 0 ..< 4 {
					px := f32(x) + (f32(sx) + 0.5) / 4
					py := f32(y) + (f32(sy) + 0.5) / 4
					in_ := false
					for &pl in polys {
						if cur_inside(pl.pts[:], px, py) {
							in_ = !pl.sub
						}
					}
					if in_ {
						hits += 1
					}
				}
			}
			fill[y * N + x] = f32(hits) / 16
		}
	}
	R :: 1.5
	for y in 0 ..< N {
		for x in 0 ..< N {
			o: f32 = 0
			for dy in -2 ..= 2 {
				for dx in -2 ..= 2 {
					xx, yy := x + dx, y + dy
					if xx < 0 || yy < 0 || xx >= N || yy >= N {
						continue
					}
					d := math.sqrt(f32(dx * dx + dy * dy))
					w := clamp(R + 0.5 - d, 0, 1)
					o = max(o, fill[yy * N + xx] * w)
				}
			}
			f := fill[y * N + x]
			// Black outline under white fill, composed into one ARGB pixel.
			a := max(o, f)
			if a <= 0.001 {
				img.px[y * N + x] = 0
				continue
			}
			lum := f / a
			v := u32(clamp(lum, 0, 1) * 255)
			img.px[y * N + x] = (u32(a * 255) << 24) | (v << 16) | (v << 8) | v
		}
	}
	img.hx, img.hy = hx, hy
	img.built = true
}

cursor_build :: proc() {
	if cursor_imgs[.Default].built {
		return
	}
	build :: proc(shape: Cursor_Shape, polys: [dynamic]Cur_Poly, hx, hy: int) {
		cursor_raster(&cursor_imgs[shape], polys[:], hx, hy)
	}
	{
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_poly(&ps, {2, 2}, {2, 21}, {6.5, 16.8}, {9.6, 23.6}, {12.6, 22.4}, {9.6, 15.6}, {15.5, 15.6})
		build(.Default, ps, 2, 2)
	}
	for pair in ([?]struct {
		shape: Cursor_Shape,
		ang:   f32,
	} {
		{.EW, 0},
		{.E, 0},
		{.W, 0},
		{.NS, math.PI / 2},
		{.N, math.PI / 2},
		{.S, math.PI / 2},
		{.NWSE, math.PI / 4},
		{.NW, math.PI / 4},
		{.SE, math.PI / 4},
		{.NESW, -math.PI / 4},
		{.NE, -math.PI / 4},
		{.SW, -math.PI / 4},
	}) {
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_double_arrow(&ps, 16, 16, pair.ang)
		build(pair.shape, ps, 16, 16)
	}
	{
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_double_arrow(&ps, 16, 16, 0, 12, 1.4, 4.5, 4.5)
		cur_double_arrow(&ps, 16, 16, math.PI / 2, 12, 1.4, 4.5, 4.5)
		build(.Move, ps, 16, 16)
	}
	{
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_rect(&ps, 11, 5, 10, 2)
		cur_rect(&ps, 15, 5, 2, 22)
		cur_rect(&ps, 11, 25, 10, 2)
		build(.Text, ps, 16, 16)
	}
	{
		// A pointing hand: the index finger up, a palm, a thumb.
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_rect(&ps, 11, 3, 4, 13)
		cur_circle(&ps, 13, 4, 2)
		cur_poly(&ps, {9, 13}, {23, 12}, {24, 22}, {20, 28}, {12, 28}, {9, 23})
		cur_poly(&ps, {4.5, 16}, {7, 14.5}, {11, 19}, {10, 23})
		build(.Pointer, ps, 13, 3)
	}
	for shape in ([2]Cursor_Shape{.Grab, .Grabbing}) {
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		top := f32(shape == .Grab ? 6 : 10)
		cur_poly(&ps, {9, top + 4}, {12, top}, {20, top}, {24, top + 4}, {24, 24}, {20, 28}, {12, 28}, {8, 23})
		build(shape, ps, 16, 16)
	}
	{
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_circle(&ps, 16, 16, 10)
		cur_circle(&ps, 16, 16, 7, true)
		cur_double_arrow(&ps, 16, 16, math.PI / 4, 8.5, 1.6, 0.01, 1.6)
		build(.Not_Allowed, ps, 16, 16)
	}
	{
		// An hourglass.
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_poly(&ps, {9, 5}, {23, 5}, {23, 8}, {18, 16}, {23, 24}, {23, 27}, {9, 27}, {9, 24}, {14, 16}, {9, 8})
		build(.Wait, ps, 16, 16)
	}
	{
		ps := make([dynamic]Cur_Poly, context.temp_allocator)
		cur_rect(&ps, 15.2, 4, 1.6, 24)
		cur_rect(&ps, 4, 15.2, 24, 1.6)
		build(.Crosshair, ps, 16, 16)
	}
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// cursor_effective resolves `.Client` to what the client under the pointer
// asked for.
cursor_effective :: proc(s: ^Server) -> (Cursor_Shape, ^Client_Cursor) {
	shape := ix.cursor
	if shape != .Client {
		return shape, nil
	}
	surf := s.ptr_surf
	if surf == nil || surf.client == nil {
		return .Default, nil
	}
	cc, ok := &client_cursors[surf.client]
	if !ok {
		return .Default, nil
	}
	if cc.use_surface {
		if cc.surf == nil {
			return .Hidden, nil
		}
		return .Client, cc
	}
	return cc.shape, nil
}

cursor_draw :: proc(s: ^Server, cv: ^p.Canvas, x, y: int) {
	cursor_build()
	shape, cc := cursor_effective(s)
	switch shape {
	case .Hidden:
		return
	case .Client:
		if cc != nil && cc.surf != nil && cc.surf.img != nil {
			p.reset_clip(cv)
			blit_surface(cv, cc.surf, x - cc.hot.x, y - cc.hot.y)
			return
		}
		shape = .Default
	case .Default, .Move, .Grab, .Grabbing, .N, .S, .E, .W, .NE, .NW, .SE, .SW, .EW, .NS, .NESW, .NWSE, .Text, .Pointer, .Not_Allowed, .Wait, .Crosshair:
	}
	img := &cursor_imgs[shape]
	if !img.built {
		img = &cursor_imgs[.Default]
	}
	ox := x - img.hx
	oy := y - img.hy
	for row in 0 ..< CURSOR_SIZE {
		py := oy + row
		if py < 0 || py >= cv.h {
			continue
		}
		for col in 0 ..< CURSOR_SIZE {
			px := ox + col
			if px < 0 || px >= cv.w {
				continue
			}
			v := img.px[row * CURSOR_SIZE + col]
			a := v >> 24
			if a == 0 {
				continue
			}
			i := py * cv.w + px
			if a == 255 {
				cv.px[i] = v
				continue
			}
			d := cv.px[i]
			na := 255 - a
			c := (v & 0xff) * a // grey, so one channel is the colour
			r := (c + ((d >> 16) & 0xff) * na) / 255
			g := (c + ((d >> 8) & 0xff) * na) / 255
			b := (c + (d & 0xff) * na) / 255
			cv.px[i] = 0xff00_0000 | (r << 16) | (g << 8) | b
		}
	}
}

// cursor_nested tells the host which of palmy's named cursors is nearest
// what is under the pointer, when running as a window on a host.
cursor_nested :: proc(s: ^Server, app: ^p.App) {
	shape, _ := cursor_effective(s)
	want := p.Cursor.Default
	switch shape {
	case .Default, .Client:
		want = .Default
	case .Hidden:
		want = .Default
	case .Move:
		want = .Move
	case .Grab:
		want = .Grab
	case .Grabbing:
		want = .Grabbing
	case .E, .W, .EW:
		want = .Col_Resize
	case .N, .S, .NS:
		want = .Row_Resize
	case .NE, .NW, .SE, .SW, .NESW, .NWSE:
		want = .Move
	case .Text:
		want = .Text
	case .Pointer:
		want = .Pointer
	case .Not_Allowed:
		want = .Not_Allowed
	case .Wait:
		want = .Wait
	case .Crosshair:
		want = .Crosshair
	}
	if app.win.cursor_shape != want {
		p.window_set_cursor(&app.win, want)
	}
}

// ---------------------------------------------------------------------------
// Protocol
// ---------------------------------------------------------------------------

// cursor_set_surface is wl_pointer.set_cursor(serial, surface, hx, hy).
cursor_set_surface :: proc(s: ^Server, c: ^Client, sid: u32, hx, hy: i32) {
	cc := client_cursors[c]
	cc.use_surface = true
	cc.surf = nil
	cc.hot = {int(hx), int(hy)}
	if sid != 0 {
		if so, ok := obj_get(c, sid); ok && so.kind == .Surface {
			cc.surf = (^Surface)(so.p)
		}
	}
	client_cursors[c] = cc
	s.dirty = true
}

req_cursor_shape_mgr :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// get_pointer(cursor_shape_device, pointer)
		did := r_u32(r)
		r_u32(r)
		obj_new(c, did, .Cursor_Shape_Dev, o.ver, nil)
	case 2:
		// get_tablet_tool_v2: no tablets here; the device still has to exist.
		did := r_u32(r)
		r_u32(r)
		obj_new(c, did, .Cursor_Shape_Dev, o.ver, nil)
	}
}

req_cursor_shape_dev :: proc(s: ^Server, c: ^Client, o: Object, id: u32, op: u16, r: ^Reader) {
	switch op {
	case 0:
		obj_drop(c, id)
	case 1:
		// set_shape(serial, shape)
		r_u32(r)
		code := r_u32(r)
		cc := client_cursors[c]
		cc.use_surface = false
		cc.surf = nil
		cc.shape = cursor_from_wp(code)
		client_cursors[c] = cc
		s.dirty = true
	}
}

// cursor_surface_gone forgets a cursor surface the client destroyed.
cursor_surface_gone :: proc(surf: ^Surface) {
	for c, &cc in client_cursors {
		_ = c
		if cc.surf == surf {
			cc.surf = nil
		}
	}
}

cursor_client_gone :: proc(c: ^Client) {
	delete_key(&client_cursors, c)
}
