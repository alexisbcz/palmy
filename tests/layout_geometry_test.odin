// Layout geometry, asserted directly.
//
// The parity suite renders one component at the size the browser gave it and
// compares pixels. That cannot see a tree laid out *inside a container*, which
// is where every layout bug this project has shipped actually lived: `h-full`
// resolving against a pre-shrink height, and `flex-wrap` measuring against the
// width a row is offered rather than the width it ends up with. These tests
// build trees through `p.offscreen_*` and assert rectangles, which is cheap,
// deterministic, and catches a class of bug parity structurally cannot.
package palmy_tests

import "core:fmt"
import "core:testing"
import p "../palmy"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@(private)
EPS :: f32(0.51)

@(private)
geom_eq :: proc(t: ^testing.T, got, want: f32, what: string, loc := #caller_location) {
	testing.expectf(t, abs(got - want) <= EPS, "%s: got %.2f, want %.2f", what, got, want, loc = loc)
}

// contains reports whether `inner` sits inside `outer`, allowing a half pixel
// of rounding on each edge.
@(private)
contains :: proc(outer, inner: p.Rect, slack: f32 = EPS) -> bool {
	return(
		inner.x >= outer.x - slack &&
		inner.y >= outer.y - slack &&
		inner.x + inner.w <= outer.x + outer.w + slack &&
		inner.y + inner.h <= outer.y + outer.h + slack \
	)
}

@(private)
rect_str :: proc(r: p.Rect) -> string {
	return fmt.tprintf("(%.1f,%.1f %.1fx%.1f)", r.x, r.y, r.w, r.h)
}

// assert_contained walks every node built this frame and checks that it sits
// inside its parent. Nodes that are deliberately outside the flow -- absolute
// positioning, negative margins, scroll containers -- are skipped, since
// overflowing is what they are for.
@(private)
assert_contained :: proc(t: ^testing.T, ui: ^p.Ctx, loc := #caller_location) -> (checked: int) {
	for i in 0 ..< p.node_count(ui) {
		parent := p.node_parent(ui, i)
		if parent < 0 {
			continue
		}
		s := p.node_style(ui, i)
		if s.position == .Absolute {
			continue
		}
		if s.margin[p.LEFT] < 0 || s.margin[p.TOP] < 0 || s.margin[p.RIGHT] < 0 || s.margin[p.BOTTOM] < 0 {
			continue
		}
		ps := p.node_style(ui, parent)
		if ps.overflow != .Visible {
			continue
		}
		pr, cr := p.node_rect(ui, parent), p.node_rect(ui, i)
		checked += 1
		testing.expectf(
			t,
			contains(pr, cr),
			"node %d %v %s escapes its parent %d %v %s",
			i,
			p.node_kind(ui, i),
			rect_str(cr),
			parent,
			p.node_kind(ui, parent),
			rect_str(pr),
			loc = loc,
		)
	}
	return
}

// ---------------------------------------------------------------------------
// flex-1 inside a container, not at the root
// ---------------------------------------------------------------------------

// A flexible child must take exactly the space its siblings leave *inside its
// own container*, not inside the window. The existing coverage measures a row
// that fills the viewport, where "the space left over" and "the viewport minus
// the fixed child" are the same number and a bug cannot tell them apart.
@(test)
test_flex_child_fills_what_siblings_leave_in_a_container :: proc(t: ^testing.T) {
	off := p.offscreen_create(800, 400)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.row(ui, "w-full h-full")
	card := p.col(ui, "w-[300] p-4")
	bar := p.row(ui, "w-full gap-4")
	fixed := p.div(ui, "w-[60] h-[20]");p.end(ui)
	flex := p.div(ui, "flex-1 h-[20]");p.end(ui)
	p.end(ui)
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	rcard, rbar := p.node_rect(ui, card), p.node_rect(ui, bar)
	rfixed, rflex := p.node_rect(ui, fixed), p.node_rect(ui, flex)

	geom_eq(t, rcard.w, 300, "the card keeps its fixed width")
	geom_eq(t, rbar.w, 268, "a w-full row fills its parent's content box, not the window")
	geom_eq(t, rfixed.w, 60, "the fixed sibling is untouched")
	geom_eq(t, rflex.w, 268 - 60 - 16, "flex-1 takes what the sibling and the gap leave")
	geom_eq(t, rflex.x, rfixed.x + rfixed.w + 16, "the gap sits between them")
	testing.expect(t, contains(rbar, rflex), "the flexible child stays inside the row")
	testing.expect(t, contains(rcard, rbar), "the row stays inside the card")
}

// Two flexible children inside a padded container split what is left evenly,
// and neither one reaches outside the container.
@(test)
test_two_flex_children_split_the_remainder :: proc(t: ^testing.T) {
	off := p.offscreen_create(640, 200)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.row(ui, "w-full h-full justify-center items-center")
	panel := p.row(ui, "w-[420] p-2 gap-2")
	a := p.div(ui, "flex-1 h-[24]");p.end(ui)
	b := p.div(ui, "w-[100] h-[24]");p.end(ui)
	c := p.div(ui, "flex-1 h-[24]");p.end(ui)
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	// 420 - 2*8 padding - 2*8 gaps - 100 fixed = 288, split in two.
	ra, rb, rc := p.node_rect(ui, a), p.node_rect(ui, b), p.node_rect(ui, c)
	geom_eq(t, ra.w, 144, "first flexible child")
	geom_eq(t, rc.w, 144, "second flexible child")
	geom_eq(t, rb.w, 100, "the fixed child between them")
	rp := p.node_rect(ui, panel)
	geom_eq(t, rc.x + rc.w, rp.x + rp.w - 8, "the last child ends at the padding edge")
}

// ---------------------------------------------------------------------------
// Percentages against the real parent
// ---------------------------------------------------------------------------

// `w-1/2` must halve the parent's *content* box. A percentage that resolved
// against the window, or against the parent's border box before padding was
// taken off, would still look plausible at the root and be wrong everywhere
// else.
@(test)
test_percentage_resolves_against_its_real_parent :: proc(t: ^testing.T) {
	off := p.offscreen_create(800, 300)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.div(ui, "w-full h-full")
	outer := p.div(ui, "w-[400] p-4")
	half := p.div(ui, "w-1/2 h-[20]");p.end(ui)
	quarter := p.div(ui, "w-1/4 h-[20]");p.end(ui)
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	rh, rq := p.node_rect(ui, half), p.node_rect(ui, quarter)
	geom_eq(t, rh.w, 184, "half of 400 minus 32px of padding, not half of the window")
	geom_eq(t, rq.w, 92, "a quarter of the same content box")
	geom_eq(t, rh.x, p.node_rect(ui, outer).x + 16, "the padding offsets it")
}

// A percentage height resolves against the parent's resolved height, including
// when that parent is itself a percentage of a fixed grandparent.
@(test)
test_percentage_height_chains_through_two_parents :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 600)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-[400]")
	mid := p.col(ui, "w-full h-1/2")
	inner := p.div(ui, "w-[10] h-1/2");p.end(ui)
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	geom_eq(t, p.node_rect(ui, mid).h, 200, "half of a fixed 400")
	geom_eq(t, p.node_rect(ui, inner).h, 100, "half of the resolved 200, not of 400 or of the window")
}

// ---------------------------------------------------------------------------
// h-full against the final height, not the offered one
// ---------------------------------------------------------------------------

// The `h-full` pre-shrink bug: a child asking for its parent's full height got
// the height the parent was *offered* before its siblings took their share.
// Here the body is whatever is left of 200 after a 40px header and a 24px
// footer, and a `h-full` grandchild must match that, not 200.
@(test)
test_h_full_uses_the_height_left_after_siblings :: proc(t: ^testing.T) {
	off := p.offscreen_create(300, 500)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-[200]")
	p.div(ui, "w-full h-[40]");p.end(ui)
	body := p.div(ui, "w-full flex-1")
	fill := p.div(ui, "w-[20] h-full");p.end(ui)
	p.end(ui)
	p.div(ui, "w-full h-[24]");p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	rb, rf := p.node_rect(ui, body), p.node_rect(ui, fill)
	geom_eq(t, rb.h, 136, "the flexible body is 200 - 40 - 24")
	geom_eq(t, rf.h, 136, "h-full is the parent's final height, not the one it was offered")
	testing.expect(t, contains(rb, rf), "and so the child cannot stick out of the body")
}

// ---------------------------------------------------------------------------
// Containment, as an invariant over a whole tree
// ---------------------------------------------------------------------------

// Nothing in an ordinary tree may be drawn outside the box that owns it. This
// is the cheapest assertion in the file and the one that would have caught the
// overlap both layout bugs produced: a child whose rectangle leaves its parent
// is drawing over whatever is next.
@(test)
test_no_child_escapes_its_parent :: proc(t: ^testing.T) {
	off := p.offscreen_create(420, 320)
	defer p.offscreen_destroy(off)

	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-full p-4 gap-2")

	p.row(ui, "w-full items-center gap-2")
	p.div(ui, "size-[24] rounded-full bg-indigo-500");p.end(ui)
	p.text(ui, "Inbox", "text-sm font-semibold")
	p.spacer(ui)
	p.button(ui, "New")
	p.end(ui)

	p.col(ui, "w-full flex-1 gap-2 p-2 rounded-lg bg-slate-900")
	for i in 0 ..< 4 {
		p.row(ui, "w-full items-center gap-2 p-2 rounded-md bg-slate-800")
		p.div(ui, "size-[16] rounded bg-slate-600");p.end(ui)
		p.text(ui, fmt.tprintf("Message %d", i), "text-sm flex-1")
		p.text(ui, "12:04", "text-xs")
		p.end(ui)
	}
	p.end(ui)

	p.text(ui, "A footer line long enough that it has to wrap inside the column it was given, twice over.", "text-xs w-full")
	p.end(ui)
	p.offscreen_end(off)

	checked := assert_contained(t, ui)
	testing.expectf(t, checked >= 20, "the invariant covered the tree (%d nodes checked)", checked)
}

// ---------------------------------------------------------------------------
// flex-wrap: the row's height must cover the lines it laid out
// ---------------------------------------------------------------------------
//
// TODO.md T2. The mechanism is not `max-w`: it is *any* gap between the width
// a node is offered while it is measured and the width it is given while it is
// arranged. A row measured against the wider offer wraps onto fewer lines than
// it will really need, reserves that much height, and then draws its extra
// lines over whatever follows.
//
// There are several shapes that open such a gap, and a fix for one of them is
// not a fix for the others. The ones covered here:
//
//	A  a `max-w` row of chips that each carry an interactive child
//	   -- the attachment-chip repro as TODO.md describes it
//	B  a `w-full` wrapping row inside a `max-w` bubble      (the ai/chat shape)
//	C  a `w-full` wrapping row inside a `flex-1 min-w-0` pane with fixed-width
//	   siblings -- `apps/mail`'s actual reading pane, and the shape a
//	   `max-w`-only fix leaves broken
//	D  A without the interactive children
//	E  the same row at a fixed width, which must keep passing: here the offer
//	   and the final width are the same number, so there is no gap to get wrong
//
// **Frames.** A, B, D and E resolve on the first frame. C cannot: the pane's
// width is only known once its fixed siblings have taken theirs, so the row
// converges on the second frame, from the previous frame's width -- the same
// contract `.Text` has always had in `arrange`, and the reason
// `parity/odin/render/main.odin` renders every case twice before measuring it.
// So every case here renders two frames, and the first-frame expectation for
// shape A is asserted separately, by
// `test_wrapping_row_is_right_on_the_first_frame`.
//
// KNOWN FAILURE, all of the wrap cases except E, while T2 is open in this
// tree. They are written to pass once `palmy/layout.odin` carries the fix.

@(private)
CHIPS :: 5

@(private)
Wrap_Probe :: struct {
	row:    p.Rect,
	chips:  [CHIPS]p.Rect,
	follow: p.Rect, // the element after the row; zero when there is none
	lines:  int,
	bottom: f32, // the lowest point the chips actually reach
}

@(private)
probe_wrap :: proc(ui: ^p.Ctx, row: int, chips: [CHIPS]int, follow: int) -> (w: Wrap_Probe) {
	w.row = p.node_rect(ui, row)
	w.follow = follow >= 0 ? p.node_rect(ui, follow) : p.Rect{}
	w.lines = 1
	w.bottom = w.row.y
	for c, i in chips {
		w.chips[i] = p.node_rect(ui, c)
		w.bottom = max(w.bottom, w.chips[i].y + w.chips[i].h)
		if i > 0 && w.chips[i].y > w.chips[i - 1].y + 1 {
			w.lines += 1
		}
	}
	return
}

// assert_wrap_covers is the whole contract in one place: the case has to have
// wrapped at all, every chip has to be inside the row, the row has to be tall
// enough for the lines it laid out, and whatever comes after it must start
// below the last of them.
@(private)
assert_wrap_covers :: proc(t: ^testing.T, what: string, w: Wrap_Probe, loc := #caller_location) {
	testing.expectf(t, w.lines >= 2, "%s: the row wrapped onto %d lines", what, w.lines, loc = loc)
	for c in w.chips {
		testing.expectf(
			t,
			contains(w.row, c),
			"%s: chip %s escapes the row %s",
			what,
			rect_str(c),
			rect_str(w.row),
			loc = loc,
		)
	}
	testing.expectf(
		t,
		w.row.y + w.row.h >= w.bottom - EPS,
		"%s: the row is %.1fpx tall but its content reaches %.1fpx past its top",
		what,
		w.row.h,
		w.bottom - w.row.y,
		loc = loc,
	)
	if w.follow.h > 0 {
		testing.expectf(
			t,
			w.follow.y >= w.bottom - EPS,
			"%s: what follows starts at y=%.1f, under content that reaches y=%.1f",
			what,
			w.follow.y,
			w.bottom,
			loc = loc,
		)
	}
}

// chip builds one attachment chip, with or without the Save button that the
// original report blamed.
@(private)
build_chip :: proc(ui: ^p.Ctx, i: int, interactive: bool) -> int {
	idx := p.row(ui, "items-center gap-2 px-2 py-1 rounded-md bg-slate-800")
	p.text(ui, fmt.tprintf("report-%d.pdf", i), "text-xs")
	if interactive {
		p.button(ui, "Save", "px-2 py-0.5 text-xs")
	}
	p.end(ui)
	return idx
}

// Shape A: a `max-w` row of chips that each carry an interactive child.
@(test)
test_wrapping_row_height_covers_its_lines :: proc(t: ^testing.T) {
	off := p.offscreen_create(520, 400)
	defer p.offscreen_destroy(off)

	probe: Wrap_Probe
	for _ in 0 ..< 2 {
		chips: [CHIPS]int
		ui := p.offscreen_begin(off)
		p.col(ui, "w-full h-full p-4 gap-2 items-start")
		wrap := p.row(ui, "flex-wrap gap-2 max-w-[360]")
		for i in 0 ..< CHIPS {
			chips[i] = build_chip(ui, i, true)
		}
		p.end(ui)
		follow := p.div(ui, "w-full h-[20] bg-emerald-500");p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
		probe = probe_wrap(ui, wrap, chips, follow)
	}

	assert_wrap_covers(t, "A: max-w row, chips with buttons", probe)
}

// Shape A again, measured after a single frame. Everything whose width is
// known before its siblings are laid out has to be right immediately: only
// shape C is allowed the second frame, and a fix that made every wrapping row
// converge over two frames instead of one would be a regression nothing else
// here would catch.
@(test)
test_wrapping_row_is_right_on_the_first_frame :: proc(t: ^testing.T) {
	off := p.offscreen_create(520, 400)
	defer p.offscreen_destroy(off)

	chips: [CHIPS]int
	ui := p.offscreen_begin(off)
	p.col(ui, "w-full h-full p-4 gap-2 items-start")
	wrap := p.row(ui, "flex-wrap gap-2 max-w-[360]")
	for i in 0 ..< CHIPS {
		chips[i] = build_chip(ui, i, true)
	}
	p.end(ui)
	follow := p.div(ui, "w-full h-[20] bg-emerald-500");p.end(ui)
	p.end(ui)
	p.offscreen_end(off)

	assert_wrap_covers(t, "A on frame 1", probe_wrap(ui, wrap, chips, follow))
}

// Shape B: a `w-full` wrapping row inside a `max-w` bubble. The row is told to
// fill its parent, and the parent's width is itself only pinned by a maximum,
// which is the chat/ai shape.
@(test)
test_wrapping_row_inside_a_max_w_bubble_covers_its_lines :: proc(t: ^testing.T) {
	off := p.offscreen_create(640, 400)
	defer p.offscreen_destroy(off)

	probe: Wrap_Probe
	for _ in 0 ..< 2 {
		chips: [CHIPS]int
		ui := p.offscreen_begin(off)
		p.col(ui, "w-full h-full p-4 items-start")
		p.col(ui, "max-w-[360] gap-2 p-2 rounded-lg bg-slate-900")
		wrap := p.row(ui, "w-full flex-wrap gap-2")
		for i in 0 ..< CHIPS {
			chips[i] = build_chip(ui, i, true)
		}
		p.end(ui)
		follow := p.div(ui, "w-full h-[20] bg-emerald-500");p.end(ui)
		p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
		probe = probe_wrap(ui, wrap, chips, follow)
	}

	assert_wrap_covers(t, "B: w-full row in a max-w bubble", probe)
}

// Shape C: `apps/mail`'s actual reading pane -- a `flex-1 min-w-0` column
// beside a fixed sidebar and a fixed message list, with a `w-full` wrapping
// row of attachment chips inside it. No `max-w` anywhere: the pane is offered
// the whole window while it is measured and gets the 440px remainder while it
// is arranged, which is the entire bug.
//
// This is the case a `max-w`-only fix leaves broken, and the one that needs
// two frames: the pane's width is not known until its fixed siblings have
// taken theirs, so the row wraps correctly from the previous frame's width.
@(test)
test_wrapping_row_in_a_flex_pane_covers_its_lines :: proc(t: ^testing.T) {
	off := p.offscreen_create(900, 400)
	defer p.offscreen_destroy(off)

	probe: Wrap_Probe
	pane, wrap := -1, -1
	ui: ^p.Ctx
	for _ in 0 ..< 2 {
		chips: [CHIPS]int
		ui = p.offscreen_begin(off)
		p.row(ui, "w-full h-full")
		p.div(ui, "w-[200] h-full shrink-0 bg-slate-900");p.end(ui) // sidebar
		p.div(ui, "w-[260] h-full shrink-0 bg-slate-900");p.end(ui) // message list
		pane = p.col(ui, "flex-1 min-w-0 h-full p-4 gap-2 items-start")
		wrap = p.row(ui, "w-full flex-wrap gap-2")
		for i in 0 ..< CHIPS {
			chips[i] = build_chip(ui, i, true)
		}
		p.end(ui)
		follow := p.div(ui, "w-full h-[20] bg-emerald-500");p.end(ui)
		p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
		probe = probe_wrap(ui, wrap, chips, follow)
	}

	// The case only means anything if the pane really is narrower than the
	// window it was offered.
	rp := p.node_rect(ui, pane)
	geom_eq(t, rp.w, 440, "the reading pane is the window minus its fixed siblings")
	testing.expect(t, contains(rp, probe.row), "the wrapping row stays inside the pane")
	assert_wrap_covers(t, "C: w-full row in a flex-1 min-w-0 pane", probe)

	// And nothing anywhere in the tree may stick out of its parent, which is
	// how this bug shows up on screen.
	assert_contained(t, ui)
}

// Shape D: A without the interactive children. T2's report records that five
// bare chips were said not to reproduce it; measured here they do, which T2
// has since confirmed.
@(test)
test_wrapping_row_of_bare_chips_covers_its_lines :: proc(t: ^testing.T) {
	off := p.offscreen_create(520, 400)
	defer p.offscreen_destroy(off)

	probe: Wrap_Probe
	for _ in 0 ..< 2 {
		chips: [CHIPS]int
		ui := p.offscreen_begin(off)
		p.col(ui, "w-full h-full p-4 gap-2 items-start")
		wrap := p.row(ui, "flex-wrap gap-2 max-w-[360]")
		for i in 0 ..< CHIPS {
			chips[i] = build_chip(ui, i, false)
		}
		p.end(ui)
		follow := p.div(ui, "w-full h-[20] bg-emerald-500");p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
		probe = probe_wrap(ui, wrap, chips, follow)
	}

	assert_wrap_covers(t, "D: max-w row, bare chips", probe)
}

// Shape E: the same row at a fixed width, where the width it is offered and
// the width it ends up with are the same number. It passes today and must go
// on passing -- it is the control that says a fix addressed the gap between
// measure and arrange rather than wrapping differently everywhere.
@(test)
test_wrapping_row_at_a_fixed_width_covers_its_lines :: proc(t: ^testing.T) {
	off := p.offscreen_create(520, 400)
	defer p.offscreen_destroy(off)

	probe: Wrap_Probe
	for _ in 0 ..< 2 {
		chips: [CHIPS]int
		ui := p.offscreen_begin(off)
		p.col(ui, "w-full h-full p-4 gap-2 items-start")
		wrap := p.row(ui, "flex-wrap gap-2 w-[360]")
		for i in 0 ..< CHIPS {
			chips[i] = build_chip(ui, i, false)
		}
		p.end(ui)
		follow := p.div(ui, "w-full h-[20] bg-emerald-500");p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
		probe = probe_wrap(ui, wrap, chips, follow)
	}

	assert_wrap_covers(t, "E: fixed-width row", probe)
}
