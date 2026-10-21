// Watching the selection: offers, their types, and reads from the same offer.
//
// The wire halves (ext/zwlr data control and wl_data_device on Wayland,
// XFIXES and TARGETS on X11) need a display server; they were exercised on a
// headless sway with wl-copy and on Xvfb by hand. What is asserted here is the
// contract every backend shares, through the offscreen clipboard, which feeds
// the same queue: order, the held offer, staleness, overflow, filtering.
package palmy_tests

import "core:testing"
import p "../palmy"

@(private = "file")
HINT :: "x-kde-passwordManagerHint"

@(private = "file")
with_ctx :: proc() -> (^p.Offscreen, ^p.Ctx) {
	off := p.offscreen_create(64, 64)
	return off, p.offscreen_begin(off)
}

@(private = "file")
done :: proc(off: ^p.Offscreen, ui: ^p.Ctx) {
	p.clipboard_watch(ui, {})
	p.offscreen_end(off)
	p.offscreen_destroy(off)
}

@(test)
test_offer_nothing_until_watched :: proc(t: ^testing.T) {
	off, ui := with_ctx()
	defer done(off, ui)

	testing.expect(t, !p.offscreen_clipboard_offer(.Clipboard, {"text/plain"}, {"x"}), "an unwatched clipboard takes no offer")
	_, got := p.clipboard_next_offer(ui)
	testing.expect(t, !got, "nothing is queued before watching")
	_, err := p.clipboard_offer_read(ui, p.Clip_Offer{id = 1}, "text/plain")
	testing.expect_value(t, err, p.Clip_Error.Unsupported)

	testing.expect_value(t, p.clipboard_watch(ui), p.Clip_Watch.Always)
	testing.expect_value(t, p.clipboard_watch(ui, {}), p.Clip_Watch.Unsupported)
}

// The sensitivity gate and the read see one offer: the hint is in the very
// type list that the read is checked against.
@(test)
test_offer_types_and_read_are_one_selection :: proc(t: ^testing.T) {
	off, ui := with_ctx()
	defer done(off, ui)
	p.clipboard_watch(ui)

	testing.expect(
		t,
		p.offscreen_clipboard_offer(.Clipboard, {"text/plain;charset=utf-8", HINT}, {"hunter2-synthetic", "secret"}),
	)
	testing.expect(t, p.offscreen_clipboard_offer(.Clipboard, {"image/png", "text/html"}, {"\x89PNG\r\n\x1a\n\x00", "<img>"}))

	a, ok := p.clipboard_next_offer(ui)
	testing.expect(t, ok)
	testing.expect_value(t, len(a.types), 2)
	testing.expect(t, len(a.types) == 2 && a.types[0] == "text/plain;charset=utf-8" && a.types[1] == HINT, "types in the owner's order")
	testing.expect(t, p.clipboard_offer_has(a, HINT), "the gate sees the hint on this offer")
	testing.expect(t, !p.clipboard_offer_has(a, "image/png"), "...and not the next offer's types")
	testing.expect(t, !a.own)
	testing.expect_value(t, a.missed, 0)

	// The next selection is already queued; reading `a` still reads `a`.
	data, err := p.clipboard_offer_read(ui, a, "text/plain;charset=utf-8")
	testing.expect_value(t, err, p.Clip_Error.None)
	testing.expect_value(t, string(data), "hunter2-synthetic")
	delete(data)
	_, err = p.clipboard_offer_read(ui, a, "image/png")
	testing.expect_value(t, err, p.Clip_Error.Not_Offered)

	b, ok2 := p.clipboard_next_offer(ui)
	testing.expect(t, ok2)
	testing.expect(t, b.id > a.id, "ids increase")
	testing.expect(t, !p.clipboard_offer_has(b, HINT))

	// `a` is let go of: its read is refused rather than answered with `b`.
	_, err = p.clipboard_offer_read(ui, a, "text/plain;charset=utf-8")
	testing.expect_value(t, err, p.Clip_Error.Stale)
	png, perr := p.clipboard_offer_read(ui, b, "image/png")
	testing.expect_value(t, perr, p.Clip_Error.None)
	testing.expect_value(t, len(png), 9)
	testing.expect(t, len(png) == 9 && png[8] == 0, "binary bytes come back untouched")
	delete(png)

	// Nothing left: nothing held either.
	_, ok3 := p.clipboard_next_offer(ui)
	testing.expect(t, !ok3)
	_, err = p.clipboard_offer_read(ui, b, "image/png")
	testing.expect_value(t, err, p.Clip_Error.Stale)
}

@(test)
test_offer_forged_and_cleared :: proc(t: ^testing.T) {
	off, ui := with_ctx()
	defer done(off, ui)
	p.clipboard_watch(ui)

	p.offscreen_clipboard_offer(.Clipboard, {"text/plain"}, {"one"})
	p.offscreen_clipboard_offer(.Clipboard, nil, nil) // cleared
	a, _ := p.clipboard_next_offer(ui)

	forged := a
	forged.id += 1
	_, err := p.clipboard_offer_read(ui, forged, "text/plain")
	testing.expect_value(t, err, p.Clip_Error.Stale)
	_, err = p.clipboard_offer_read(ui, p.Clip_Offer{}, "text/plain")
	testing.expect_value(t, err, p.Clip_Error.Stale)
	other := a
	other.kind = .Primary
	_, err = p.clipboard_offer_read(ui, other, "text/plain")
	testing.expect_value(t, err, p.Clip_Error.Stale)

	cleared, ok := p.clipboard_next_offer(ui)
	testing.expect(t, ok, "a cleared selection is an offer too")
	testing.expect_value(t, len(cleared.types), 0)
	_, err = p.clipboard_offer_read(ui, cleared, "text/plain")
	testing.expect_value(t, err, p.Clip_Error.Not_Offered)

	testing.expect(t, !p.offscreen_clipboard_offer(.Clipboard, {"a", "b"}, {"x"}), "lists of different lengths are refused")
}

// Every copy between two frames is an offer: the poll race the clipboard app
// documents does not exist here. Past the queue's bound the oldest go, and
// the first one kept says how many.
@(test)
test_offer_order_and_overflow :: proc(t: ^testing.T) {
	off, ui := with_ctx()
	defer done(off, ui)
	p.clipboard_watch(ui)

	names := [?]string{"A", "B", "C"}
	for n in names {
		p.offscreen_clipboard_offer(.Clipboard, {"text/plain"}, {n})
	}
	for n in names {
		o, ok := p.clipboard_next_offer(ui)
		testing.expect(t, ok)
		data, err := p.clipboard_offer_read(ui, o, "text/plain")
		testing.expect_value(t, err, p.Clip_Error.None)
		testing.expect_value(t, string(data), n)
		delete(data)
	}

	digits := "0123456789abcdefghij"
	for i in 0 ..< 20 {
		p.offscreen_clipboard_offer(.Clipboard, {"text/plain"}, {digits[i:i + 1]})
	}
	first, _ := p.clipboard_next_offer(ui)
	testing.expect_value(t, first.missed, 4)
	data, _ := p.clipboard_offer_read(ui, first, "text/plain")
	testing.expect_value(t, string(data), "4")
	delete(data)
	count := 1
	last_id := first.id
	for o in p.clipboard_next_offer(ui) {
		testing.expect_value(t, o.missed, 0)
		testing.expect(t, o.id == last_id + 1, "consecutive ids")
		last_id = o.id
		count += 1
	}
	testing.expect_value(t, count, 16)
}

@(test)
test_offer_kinds_and_own_copy :: proc(t: ^testing.T) {
	off, ui := with_ctx()
	defer done(off, ui)

	// Only the clipboard is watched: a primary selection is not queued.
	p.clipboard_watch(ui, {.Clipboard})
	testing.expect(t, !p.offscreen_clipboard_offer(.Primary, {"text/plain"}, {"x"}))
	p.primary_set(ui, "not watched")
	_, ok := p.clipboard_next_offer(ui)
	testing.expect(t, !ok, "an unwatched kind queues nothing")

	testing.expect_value(t, p.clipboard_watch(ui, {.Clipboard, .Primary}), p.Clip_Watch.Always)
	p.primary_set(ui, "mine")
	o, ok2 := p.clipboard_next_offer(ui)
	testing.expect(t, ok2)
	testing.expect_value(t, o.kind, p.Clip_Kind.Primary)
	testing.expect(t, o.own, "this window's own copy says so")
	testing.expect(t, p.clipboard_offer_has(o, "text/plain;charset=utf-8") && p.clipboard_offer_has(o, "UTF8_STRING"))
	data, err := p.clipboard_offer_read(ui, o, "UTF8_STRING")
	testing.expect_value(t, err, p.Clip_Error.None)
	testing.expect_value(t, string(data), "mine")
	delete(data)

	// Narrowing the set drops what was queued and held of the other kind.
	p.offscreen_clipboard_offer(.Primary, {"text/plain"}, {"queued"})
	p.clipboard_watch(ui, {.Clipboard})
	_, err = p.clipboard_offer_read(ui, o, "UTF8_STRING")
	testing.expect_value(t, err, p.Clip_Error.Stale)
	_, ok3 := p.clipboard_next_offer(ui)
	testing.expect(t, !ok3, "the queued primary offer went with it")

	p.primary_set(ui, "")
}
