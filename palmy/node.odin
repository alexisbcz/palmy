package palmy

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

Node_Kind :: enum u8 {
	Box,
	Text,
	Custom,
	Icon,
	Image,
}

// Custom_Fn is the escape hatch: a procedure handed the node's rectangle and
// the raw canvas, free to write whatever pixels it likes.
Custom_Fn :: proc(c: ^Canvas, r: Rect, user: rawptr)

Text_Line :: struct {
	text:  string,
	width: f32,
}

Node :: struct {
	kind:        Node_Kind,
	id:          u64,
	parent:      int,
	first_child: int,
	last_child:  int,
	next:        int,
	n_children:  int,
	style:       Style,
	text:        string,
	lines:       []Text_Line,

	// Results of layout, in logical pixels relative to the window.
	rect:        Rect,
	content:     [2]f32,
	clip:        Rect,

	interactive: bool,
	scrollable:  bool,
	focusable:   bool,
	custom:      Custom_Fn,
	user:        rawptr,
	icon:        Icon,
	img:         Image,
	fit:         Fit,
	zoom:        f32,
}

// Widget is the state palmy keeps for a node between frames: where it was, how
// far it is scrolled, and the colors its transition is currently animating.
@(private)
Widget :: struct {
	rect:      Rect,
	clip:      Rect,
	scroll:    [2]f32,
	over:      [2]f32, // how much content sticks out of a scroll container
	view:      [2]f32,
	anim:      Anim,
	cursor:    int,
	sel:       int,
	drag:      [2]f32,
	seen:      u64,
}

@(private)
Anim :: struct {
	bg:     Color,
	bg2:    Color,
	fg:     Color,
	border: Color,
	init:   bool,
}

@(private)
State_Slot :: struct {
	data: []u8,
	type: typeid,
	seen: u64,
}

// Ctx is the per-frame UI context. It is handed to you by `frames` and is the
// single argument every element takes.
Ctx :: struct {
	app:       ^App,
	fonts:     ^Fonts,
	input:     ^Input,

	nodes:     [dynamic]Node,
	prev:      [dynamic]Node,
	stack:     [dynamic]int,
	arena:     virtual.Arena,
	arena_old: virtual.Arena,
	alloc:     mem.Allocator,

	next_key:  string,
	seq:       [dynamic]u32,

	states:    map[u64]State_Slot,
	widgets:   map[u64]Widget,
	icons:     Icons,

	hot:       u64, // topmost interactive node under the pointer
	active:    u64, // node being pressed
	clicked:   u64, // node that completed a click this frame
	focus:     u64, // keyboard focus
	frame:     u64,

	// Pointer position in logical pixels, and the time base for animations.
	mouse:     [2]f32,
	dt:        f32,
	now:       f64,
	viewport:  [2]f32,

	animating: bool,
	redraw:    bool,

	// Index of the most recently created element, which `style` targets.
	last:      int,
}

@(private)
ctx_init :: proc(ctx: ^Ctx) {
	_ = virtual.arena_init_growing(&ctx.arena)
	_ = virtual.arena_init_growing(&ctx.arena_old)
	ctx.alloc = virtual.arena_allocator(&ctx.arena)
	ctx.nodes = make([dynamic]Node)
	ctx.prev = make([dynamic]Node)
	ctx.stack = make([dynamic]int)
	ctx.seq = make([dynamic]u32)
	ctx.states = make(map[u64]State_Slot)
	ctx.widgets = make(map[u64]Widget)
	icons_init(&ctx.icons)
}

@(private)
ctx_destroy :: proc(ctx: ^Ctx) {
	for _, slot in ctx.states {
		delete(slot.data)
	}
	delete(ctx.states)
	delete(ctx.widgets)
	icons_destroy(&ctx.icons)
	delete(ctx.nodes)
	delete(ctx.prev)
	delete(ctx.stack)
	delete(ctx.seq)
	virtual.arena_destroy(&ctx.arena)
	virtual.arena_destroy(&ctx.arena_old)
}

// ---------------------------------------------------------------------------
// Identity
//
// Every element gets a stable id derived from its position in the tree, so
// state and hover survive across frames without the caller naming anything.
// `key` overrides the sibling index, which is what dynamic lists need.
// ---------------------------------------------------------------------------

@(private)
FNV_OFFSET :: 0xcbf29ce484222325
@(private)
FNV_PRIME :: 0x100000001b3

@(private)
hash_bytes :: proc(seed: u64, data: []u8) -> u64 {
	h := seed
	for b in data {
		h = (h ~ u64(b)) * FNV_PRIME
	}
	return h
}

@(private)
hash_u64 :: proc(seed: u64, v: u64) -> u64 {
	b := transmute([8]u8)v
	return hash_bytes(seed, b[:])
}

// key names the next element explicitly. Use it for list items so that their
// state follows the item rather than the slot it happens to occupy.
key :: proc(ctx: ^Ctx, name: string) {
	ctx.next_key = name
}

@(private)
make_id :: proc(ctx: ^Ctx, parent: int) -> u64 {
	base := parent >= 0 ? ctx.nodes[parent].id : FNV_OFFSET
	if ctx.next_key != "" {
		id := hash_bytes(base, transmute([]u8)ctx.next_key)
		ctx.next_key = ""
		return id
	}
	depth := len(ctx.stack)
	for len(ctx.seq) <= depth {
		append(&ctx.seq, 0)
	}
	ctx.seq[depth] += 1
	return hash_u64(base, u64(ctx.seq[depth]))
}

@(private)
interaction_of :: proc(ctx: ^Ctx, id: u64, disabled := false) -> Interaction {
	return Interaction {
		hover = ctx.hot == id,
		active = ctx.active == id,
		focus = ctx.focus == id,
		disabled = disabled,
	}
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// state returns a pointer to a value that persists across frames, created the
// first time it is asked for. This is palmy's useState:
//
//	count := palmy.state(ui, "count", 0)
//	count^ += 1
state :: proc(ctx: ^Ctx, name: string, initial: $T) -> ^T {
	parent := len(ctx.stack) > 0 ? ctx.stack[len(ctx.stack) - 1] : -1
	base := parent >= 0 ? ctx.nodes[parent].id : FNV_OFFSET
	id := hash_u64(hash_bytes(base, transmute([]u8)name), u64(size_of(T)) * 31 + u64(align_of(T)))

	if slot, found := &ctx.states[id]; found {
		slot.seen = ctx.frame
		return (^T)(raw_data(slot.data))
	}

	data := make([]u8, size_of(T))
	(^T)(raw_data(data))^ = initial
	ctx.states[id] = State_Slot {
		data = data,
		type = typeid_of(T),
		seen = ctx.frame,
	}
	return (^T)(raw_data(ctx.states[id].data))
}

// ---------------------------------------------------------------------------
// Tree building
// ---------------------------------------------------------------------------

@(private)
top :: proc(ctx: ^Ctx) -> int {
	return len(ctx.stack) > 0 ? ctx.stack[len(ctx.stack) - 1] : -1
}

@(private)
push_node :: proc(ctx: ^Ctx, kind: Node_Kind, class: string, disabled := false) -> int {
	parent := top(ctx)
	id := make_id(ctx, parent)

	s: Style
	if parent >= 0 {
		s = inherit(ctx.nodes[parent].style)
	} else {
		s = style_default()
	}
	apply_classes(&s, class, interaction_of(ctx, id, disabled))

	idx := len(ctx.nodes)
	append(
		&ctx.nodes,
		Node {
			kind = kind,
			id = id,
			parent = parent,
			first_child = -1,
			last_child = -1,
			next = -1,
			style = s,
			scrollable = s.overflow == .Scroll,
		},
	)

	ctx.last = idx
	if parent >= 0 {
		p := &ctx.nodes[parent]
		if p.first_child < 0 {
			p.first_child = idx
		} else {
			ctx.nodes[p.last_child].next = idx
		}
		p.last_child = idx
		p.n_children += 1
	}
	return idx
}

// div opens a container. Close it with `end`; `defer` reads nicely:
//
//	palmy.div(ui, "flex-row gap-3 p-4 bg-slate-900 rounded-xl")
//	defer palmy.end(ui)
div :: proc(ctx: ^Ctx, class: string = "") -> int {
	idx := push_node(ctx, .Box, class)
	append(&ctx.stack, idx)
	return idx
}

// end closes the container opened by the matching `div`, `row` or `col`.
end :: proc(ctx: ^Ctx) {
	if n := len(ctx.stack); n > 0 {
		depth := n
		if depth < len(ctx.seq) {
			ctx.seq[depth] = 0
		}
		pop(&ctx.stack)
	}
}

// row and col are `div` with the direction already set, since that is how most
// containers start out.
row :: proc(ctx: ^Ctx, class: string = "") -> int {
	idx := push_node(ctx, .Box, "flex-row")
	ctx.nodes[idx].style.dir = .Row
	apply_classes(&ctx.nodes[idx].style, class, interaction_of(ctx, ctx.nodes[idx].id))
	append(&ctx.stack, idx)
	return idx
}

col :: proc(ctx: ^Ctx, class: string = "") -> int {
	idx := push_node(ctx, .Box, "flex-col")
	apply_classes(&ctx.nodes[idx].style, class, interaction_of(ctx, ctx.nodes[idx].id))
	append(&ctx.stack, idx)
	return idx
}

// group builds a subtree with a callback, which keeps nesting visible without
// a matching `end`. The user pointer is passed straight through.
group :: proc(ctx: ^Ctx, class: string, user: ^$T, body: proc(ctx: ^Ctx, user: ^T)) {
	div(ctx, class)
	body(ctx, user)
	end(ctx)
}

// text adds a run of text. It wraps to the width it is given unless the class
// list says `whitespace-nowrap` or `truncate`.
text :: proc(ctx: ^Ctx, str: string, class: string = "") -> int {
	idx := push_node(ctx, .Text, class)
	n := &ctx.nodes[idx]
	n.text = clone_frame(ctx, str)
	switch n.style.transform {
	case .Upper:
		n.text = strings.to_upper(n.text, ctx.alloc)
	case .Lower:
		n.text = strings.to_lower(n.text, ctx.alloc)
	case .None:
	}
	return idx
}

// textf is `text` with formatting. The formatted string lives in the frame
// arena, so there is nothing to free.
textf :: proc(ctx: ^Ctx, class: string, format: string, args: ..any) -> int {
	s := fmt.aprintf(format, ..args, allocator = ctx.alloc)
	return text(ctx, s, class)
}

// spacer pushes its siblings apart.
spacer :: proc(ctx: ^Ctx, class: string = "flex-1") -> int {
	return push_node(ctx, .Box, class)
}

// divider draws a hairline across the cross axis.
divider :: proc(ctx: ^Ctx, class: string = "bg-slate-800") -> int {
	idx := push_node(ctx, .Box, class)
	n := &ctx.nodes[idx]
	if n.style.h.kind == .Auto {
		n.style.h = px(1)
	}
	n.style.shrink = 0
	return idx
}

// pixels hands you the canvas for a rectangle of the layout. Everything in
// canvas.odin is available, as is writing to `canvas.px` directly.
//
//	palmy.pixels(ui, "flex-1 rounded-xl overflow-hidden", &scene,
//		proc(c: ^palmy.Canvas, r: palmy.Rect, s: ^Scene) {
//			...
//		})
pixels :: proc(ctx: ^Ctx, class: string, user: ^$T, draw: proc(c: ^Canvas, r: Rect, user: ^T)) -> int {
	idx := push_node(ctx, .Custom, class)
	n := &ctx.nodes[idx]
	// ^T and rawptr share a representation, so the thunk is a no-op cast.
	n.custom = transmute(Custom_Fn)draw
	n.user = rawptr(user)
	return idx
}

// icon adds a line icon, drawn in the inherited text colour. Size comes from
// the class (`size-4`) and otherwise follows the font size, the way an inline
// SVG does in a browser.
//
//	palmy.icon(ui, ICON_CHECK, "size-4 text-white")
icon :: proc(ctx: ^Ctx, ic: Icon, class: string = "") -> int {
	idx := push_node(ctx, .Icon, class)
	ctx.nodes[idx].icon = ic
	return idx
}

// image places a decoded image. It fills the box the way CSS object-fit does,
// and `zoom` magnifies around the centre for a viewer that can zoom in.
//
//	img, ok := palmy.load_image("photo.jpg")
//	palmy.image(ui, img, "w-full h-full", .Contain)
image :: proc(ctx: ^Ctx, img: Image, class: string = "", fit := Fit.Contain, zoom: f32 = 1) -> int {
	idx := push_node(ctx, .Image, class)
	ctx.nodes[idx].img = img
	ctx.nodes[idx].fit = fit
	ctx.nodes[idx].zoom = zoom
	return idx
}

@(private)
clone_frame :: proc(ctx: ^Ctx, s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	return strings.clone(s, ctx.alloc)
}

// ---------------------------------------------------------------------------
// Queries against the previous frame
// ---------------------------------------------------------------------------

@(private)
widget_of :: proc(ctx: ^Ctx, id: u64) -> ^Widget {
	if w, found := &ctx.widgets[id]; found {
		w.seen = ctx.frame
		return w
	}
	ctx.widgets[id] = Widget {
		seen = ctx.frame,
	}
	return &ctx.widgets[id]
}

// rect_of returns where a node was drawn last frame, which is what hit testing
// and scrolling work from.
rect_of :: proc(ctx: ^Ctx, id: u64) -> Rect {
	if w, found := ctx.widgets[id]; found {
		return w.rect
	}
	return {}
}

// hovered reports whether the pointer is over the node with this id.
hovered :: proc(ctx: ^Ctx, id: u64) -> bool {
	return ctx.hot == id
}

// mark_interactive opts a node into hit testing. Widgets do this for you.
@(private)
mark_interactive :: proc(ctx: ^Ctx, idx: int, focusable := false) {
	ctx.nodes[idx].interactive = true
	ctx.nodes[idx].focusable = focusable
}

// node_rect returns where an element was laid out, in logical pixels. It is
// valid once the frame has been finished, and from the next frame onwards it is
// also what hit testing uses.
node_rect :: proc(ctx: ^Ctx, idx: int) -> Rect {
	if idx < 0 || idx >= len(ctx.nodes) {
		return {}
	}
	return ctx.nodes[idx].rect
}

// node_id is an element's stable identity, for use with `rect_of` or `hovered`.
node_id :: proc(ctx: ^Ctx, idx: int) -> u64 {
	if idx < 0 || idx >= len(ctx.nodes) {
		return 0
	}
	return ctx.nodes[idx].id
}

// node_count is the number of elements built so far this frame, which is also
// the index the next element will take. Pair it with `node_rect` to find out
// where a widget ended up:
//
//	at := palmy.node_count(ui)
//	palmy.button(ui, "Save")
//	// ... after the frame: palmy.node_rect(ui, at)
node_count :: proc(ctx: ^Ctx) -> int {
	return len(ctx.nodes)
}

// style returns the resolved style of the element that was created last, so it
// can be adjusted directly when a class string will not do:
//
//	palmy.div(ui, "h-8 rounded-md")
//	palmy.style(ui).bg = palmy.flat(swatch)
//
// The pointer is only valid until the next element is created.
style :: proc(ctx: ^Ctx, idx := -1) -> ^Style {
	i := idx >= 0 ? idx : ctx.last
	if i < 0 || i >= len(ctx.nodes) {
		// Never hand back nil: a scratch style keeps call sites simple.
		@(static) scratch: Style
		scratch = style_default()
		return &scratch
	}
	return &ctx.nodes[i].style
}

// node_parent, node_kind and node_text expose the built tree, which is what
// the parity renderer dumps alongside its pixels so geometry can be compared
// numerically rather than only visually.
node_parent :: proc(ctx: ^Ctx, idx: int) -> int {
	return idx >= 0 && idx < len(ctx.nodes) ? ctx.nodes[idx].parent : -1
}

node_kind :: proc(ctx: ^Ctx, idx: int) -> Node_Kind {
	return idx >= 0 && idx < len(ctx.nodes) ? ctx.nodes[idx].kind : .Box
}

node_text :: proc(ctx: ^Ctx, idx: int) -> string {
	return idx >= 0 && idx < len(ctx.nodes) ? ctx.nodes[idx].text : ""
}

node_style :: proc(ctx: ^Ctx, idx: int) -> Style {
	return idx >= 0 && idx < len(ctx.nodes) ? ctx.nodes[idx].style : Style{}
}

// apply folds more utilities into the element created last. It is how variant
// systems compose: a base class string, then the variant, then the size, each
// overriding what came before, exactly like `cva` does in the browser.
//
//	palmy.div(ui, BUTTON_BASE)
//	palmy.apply(ui, variant_class(v))
//	palmy.apply(ui, size_class(s))
apply :: proc(ctx: ^Ctx, class: string, idx := -1) {
	i := idx >= 0 ? idx : ctx.last
	if i < 0 || i >= len(ctx.nodes) || class == "" {
		return
	}
	n := &ctx.nodes[i]
	apply_classes(&n.style, class, interaction_of(ctx, n.id))
	n.scrollable = n.style.overflow == .Scroll
}

// concat joins strings into the frame arena. Class strings often have to be
// assembled at runtime — a variant name, a side suffix, a size — and this keeps
// that allocation-free from the caller's point of view, since the arena is
// reset every frame.
//
//	palmy.apply(ui, palmy.concat(ui, "rounded-", size, "-t"))
concat :: proc(ctx: ^Ctx, parts: ..string) -> string {
	total := 0
	for s in parts {
		total += len(s)
	}
	if total == 0 {
		return ""
	}
	out := make([]u8, total, ctx.alloc)
	at := 0
	for s in parts {
		copy(out[at:], s)
		at += len(s)
	}
	return string(out)
}
