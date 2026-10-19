// A text whose string changes must be measured again from scratch.
//
// `measure` re-wraps a text at the width it had last frame, which is what
// keeps a `flex-1` paragraph beside a sidebar from reserving one line's height
// for the three it draws. It used to apply that cap to *every* text, and a
// shrink-to-fit label's width is its own string: when the string at an id got
// longer -- the installer switching language, one validation message
// replacing another -- the new string was wrapped to the old one's width and
// the label never grew back. The installer's notes have the reproduction.
package palmy_tests

import "core:testing"
import p "../palmy"

@(private)
label_frame :: proc(off: ^p.Offscreen, s: string) -> (ui: ^p.Ctx, label: int) {
	ui = p.offscreen_begin(off)
	p.col(ui, "w-full h-full p-4 items-start")
	p.row(ui, "gap-2 items-center")
	p.div(ui, "w-[12] h-[12]");p.end(ui)
	label = p.text(ui, s, "text-sm")
	p.end(ui)
	p.end(ui)
	p.offscreen_end(off)
	return
}

@(test)
test_a_label_whose_string_grows_is_not_wrapped_at_its_old_width :: proc(t: ^testing.T) {
	off := p.offscreen_create(800, 200)
	defer p.offscreen_destroy(off)

	short := "Name"
	long := "Nom de l'ordinateur sur le réseau"

	// Two frames of the short string, so last frame's width is on record.
	label_frame(off, short)
	ui, l := label_frame(off, short)
	narrow := p.node_rect(ui, l).w
	testing.expect_value(t, len(p.node_lines(ui, l)), 1)

	// The very next frame, the same id holds a longer string.
	ui, l = label_frame(off, long)
	lines := p.node_lines(ui, l)
	testing.expectf(t, len(lines) == 1, "the longer label is one line, got %d", len(lines))
	wide := p.node_rect(ui, l).w
	testing.expectf(t, wide > narrow * 3, "the label grew from %.1f to %.1f", narrow, wide)

	// And it stays that way.
	ui, l = label_frame(off, long)
	testing.expect_value(t, len(p.node_lines(ui, l)), 1)
	geom_eq(t, p.node_rect(ui, l).w, wide, "the label keeps its width")

	// Shrinking back is fine too.
	ui, l = label_frame(off, short)
	geom_eq(t, p.node_rect(ui, l).w, narrow, "the label shrinks back")
}

// The reason the cap exists must keep working: a paragraph squeezed by a
// sibling wraps at the width it really gets, and reserves the height of the
// lines it draws, from the second frame on -- including after its string
// changes.
@(test)
test_a_squeezed_paragraph_still_wraps_at_the_width_it_gets :: proc(t: ^testing.T) {
	off := p.offscreen_create(600, 400)
	defer p.offscreen_destroy(off)

	words := "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen"
	more := "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega"

	frame :: proc(off: ^p.Offscreen, s: string) -> (ui: ^p.Ctx, para, after: int) {
		ui = p.offscreen_begin(off)
		p.col(ui, "w-full h-full")
		p.row(ui, "w-full items-start")
		p.div(ui, "w-[400] h-[10] shrink-0");p.end(ui)
		para = p.text(ui, s, "flex-1 text-sm")
		p.end(ui)
		after = p.div(ui, "w-[10] h-[10]");p.end(ui)
		p.end(ui)
		p.offscreen_end(off)
		return
	}

	// The first frame has nothing on record and is a frame behind, as every
	// width-dependent layout here is. From the second on it must be right.
	frame(off, words)
	for s in ([]string{words, more, more, words}) {
		ui, para, after := frame(off, s)
		r := p.node_rect(ui, para)
		lines := p.node_lines(ui, para)
		testing.expectf(t, len(lines) > 1, "the paragraph wraps, got %d line(s)", len(lines))
		for l in lines {
			testing.expectf(t, l.width <= r.w + EPS, "a line of %.1f fits the %.1f the paragraph got", l.width, r.w)
		}
		testing.expectf(
			t,
			p.node_rect(ui, after).y >= r.y + r.h - EPS,
			"what follows sits below all %d lines",
			len(lines),
		)
	}
}
