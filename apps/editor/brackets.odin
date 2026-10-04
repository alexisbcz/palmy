// Brackets: matching, jumping, and closing pairs as you type.
//
// Matching is done against the **tokeniser**, not against the raw bytes. A
// brace inside a string or a comment is not a brace, and an editor that jumps
// to one is worse than an editor that does not jump at all — so the scan lexes
// each line it crosses and ignores every bracket that lands in a string, a rune
// literal, a comment or a Markdown code span. That is only affordable because
// the per-line entry states are already cached (lex.odin), so a scan over a
// screenful of code costs a screenful of lexing.
//
// Auto-close is the feature most editors make infuriating, and the reason is
// always the same two omissions. Both are implemented here:
//
//   - typing the closing character when it is already in front of the caret
//     moves over it instead of inserting a second one;
//   - backspacing between an empty pair removes both halves.
//
// Without those, auto-close turns `()` into `())` and leaves `(` behind when
// you change your mind. With them it disappears into the typing.
package main

import "core:strings"

Pair :: struct {
	open:  u8,
	close: u8,
}

BRACKETS := [?]Pair{{'(', ')'}, {'[', ']'}, {'{', '}'}}

// The pairs that close themselves. The quotes are here too, because a quote is
// a pair in every language the editor highlights — the difference is only that
// both halves look the same, which is why `skip over the one in front` matters
// more for a quote than for a brace.
AUTO_PAIRS := [?]Pair {
	{'(', ')'},
	{'[', ']'},
	{'{', '}'},
	{'"', '"'},
	{'\'', '\''},
	{'`', '`'},
}

// MATCH_LINES bounds a scan. A bracket with no partner within a couple of
// thousand lines is not a bracket anyone is looking for, and an unbalanced file
// must not freeze the editor while it reads to the end.
MATCH_LINES :: 2000

bracket_open_for :: proc(c: u8) -> (Pair, bool) {
	for p in BRACKETS {
		if p.open == c {
			return p, true
		}
	}
	return {}, false
}

bracket_close_for :: proc(c: u8) -> (Pair, bool) {
	for p in BRACKETS {
		if p.close == c {
			return p, true
		}
	}
	return {}, false
}

auto_pair_open :: proc(c: u8) -> (Pair, bool) {
	for p in AUTO_PAIRS {
		if p.open == c {
			return p, true
		}
	}
	return {}, false
}

auto_pair_close :: proc(c: u8) -> (Pair, bool) {
	for p in AUTO_PAIRS {
		if p.close == c {
			return p, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Which bytes of a line are code
// ---------------------------------------------------------------------------

// line_code_mask returns one bool per byte of line `li`: true where that byte
// is code rather than string, comment or literal text. For a language with no
// highlighter every byte counts as code, which is the only honest answer.
line_code_mask :: proc(ed: ^Editor, li: int) -> []bool {
	src := buf_line(&ed.buf, li)
	out := make([]bool, len(src), context.temp_allocator)
	for i in 0 ..< len(out) {
		out[i] = true
	}
	if !lang_highlights(ed.lang) {
		return out
	}
	toks := make([dynamic]Token, 0, 48, context.temp_allocator)
	lex_line(src, lex_state_at(&ed.buf, li, ed.lang), &toks, ed.lang)
	for t in toks {
		if !tok_is_text(t.kind) {
			continue
		}
		for i in t.from ..< min(t.to, len(out)) {
			out[i] = false
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

// bracket_at_caret finds the bracket the caret is "on". The character to the
// right wins, then the one to the left — which is what makes the highlight
// appear both when you have just typed `}` and when you are sitting in front
// of one.
bracket_at_caret :: proc(ed: ^Editor, cur: Pos) -> (at: Pos, c: u8, ok: bool) {
	src := buf_line(&ed.buf, cur.line)
	mask := line_code_mask(ed, cur.line)

	is_bracket :: proc(c: u8) -> bool {
		_, o := bracket_open_for(c)
		_, k := bracket_close_for(c)
		return o || k
	}

	if cur.col < len(src) && is_bracket(src[cur.col]) && mask[cur.col] {
		return cur, src[cur.col], true
	}
	if cur.col > 0 {
		j := rune_left(src, cur.col)
		if j < len(src) && is_bracket(src[j]) && mask[j] {
			return {cur.line, j}, src[j], true
		}
	}
	return {}, 0, false
}

// bracket_match walks out from a bracket to its partner, counting depth and
// skipping anything the tokeniser says is not code.
bracket_match :: proc(ed: ^Editor, from: Pos) -> (at: Pos, ok: bool) {
	src := buf_line(&ed.buf, from.line)
	if from.col < 0 || from.col >= len(src) {
		return {}, false
	}
	c := src[from.col]
	if p, is_open := bracket_open_for(c); is_open {
		return scan_bracket(ed, from, p, 1)
	}
	if p, is_close := bracket_close_for(c); is_close {
		return scan_bracket(ed, from, p, -1)
	}
	return {}, false
}

@(private = "file")
scan_bracket :: proc(ed: ^Editor, from: Pos, p: Pair, d: int) -> (at: Pos, ok: bool) {
	depth := 0
	li := from.line
	col := from.col
	n := buf_lines(&ed.buf)
	for steps in 0 ..< MATCH_LINES {
		src := buf_line(&ed.buf, li)
		mask := line_code_mask(ed, li)
		// On the first line start from the bracket itself; afterwards from the
		// end (going backwards) or the start (going forwards).
		if steps > 0 {
			col = d > 0 ? 0 : len(src) - 1
		}
		for col >= 0 && col < len(src) {
			if mask[col] {
				switch src[col] {
				case p.open:
					depth += d
					if depth == 0 {
						return {li, col}, true
					}
				case p.close:
					depth -= d
					if depth == 0 {
						return {li, col}, true
					}
				}
			}
			col += d
		}
		li += d
		if li < 0 || li >= n {
			return {}, false
		}
	}
	return {}, false
}

// bracket_pair_at_caret is what the renderer asks for: both ends, or nothing.
bracket_pair_at_caret :: proc(ed: ^Editor) -> (a, b: Pos, ok: bool) {
	at, _, found := bracket_at_caret(ed, ed.cur)
	if !found {
		return {}, {}, false
	}
	m, matched := bracket_match(ed, at)
	if !matched {
		return at, {}, false
	}
	return at, m, true
}

// ---------------------------------------------------------------------------
// Typing
// ---------------------------------------------------------------------------

// should_auto_close decides whether typing an opener inserts its partner too.
// The rule is the one that stays out of the way: close the pair when the caret
// is at the end of the line or in front of whitespace or a closing bracket, and
// leave it alone when it is in front of a word — because `(` typed before
// `foo)` is almost always a cast or a call being wrapped, not a new pair.
//
// Quotes get one more condition: not immediately after a word character, so
// that the apostrophe in `don't` and Odin's `0'` do not sprout a partner.
should_auto_close :: proc(line: string, col: int, p: Pair) -> bool {
	quote := p.open == p.close
	if quote && col > 0 {
		prev := line[rune_left(line, col)]
		if class_of(prev) == .Word || prev == p.open {
			return false
		}
	}
	if col >= len(line) {
		return true
	}
	next := line[col]
	switch class_of(next) {
	case .Space:
		return true
	case .Word:
		return false
	case .Punct:
	}
	// In front of punctuation: a closing bracket or a separator is fine to
	// close in front of; another quote is not.
	if quote && next == p.open {
		return false
	}
	if _, is_close := bracket_close_for(next); is_close {
		return true
	}
	return strings.contains_rune(",;:.", rune(next)) || next == '>'
}

// type_bracket handles one typed character that might be part of a pair. It
// returns false when the character is ordinary and the caller should insert it
// the plain way.
type_bracket :: proc(ed: ^Editor, c: u8) -> bool {
	line := buf_line(&ed.buf, ed.cur.line)

	// A closing character already in front of the caret is stepped over
	// rather than doubled. This is the behaviour that makes auto-close
	// tolerable, so it is tested before anything else.
	if p, is_close := auto_pair_close(c); is_close {
		if _, has_sel := sel_is_live(ed); !has_sel {
			if ed.cur.col < len(line) && line[ed.cur.col] == p.close {
				ed.cur.col += 1
				ed.goal = disp_of(line, ed.cur.col)
				clear_sel(ed)
				return true
			}
		}
	}

	p, is_open := auto_pair_open(c)
	if !is_open {
		return false
	}

	// With a selection, an opener wraps it. Nothing is lost and it is the one
	// gesture that makes surrounding text with quotes or brackets instant.
	if lo, hi, has := sel_range(ed); has {
		text := buf_text(&ed.buf, lo, hi, context.temp_allocator)
		wrapped := strings.concatenate(
			{string([]u8{p.open}), text, string([]u8{p.close})},
			context.temp_allocator,
		)
		end := buf_apply(&ed.buf, lo, hi, wrapped, ed.cur, .No)
		ed.anchor = Pos{lo.line, lo.col + 1}
		ed.cur = Pos{end.line, max(0, end.col - 1)}
		ed.has_sel = true
		ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
		return true
	}

	if !should_auto_close(line, ed.cur.col, p) {
		return false
	}
	both := [2]u8{p.open, p.close}
	ed.cur = buf_apply(&ed.buf, ed.cur, ed.cur, string(both[:]), ed.cur, .No)
	ed.cur.col = max(0, ed.cur.col - 1)
	ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
	clear_sel(ed)
	return true
}

// backspace_pair deletes both halves of an empty pair in one keystroke, which
// is the other half of making auto-close bearable: the pair appeared together,
// so it has to disappear together.
backspace_pair :: proc(ed: ^Editor) -> bool {
	line := buf_line(&ed.buf, ed.cur.line)
	if ed.cur.col <= 0 || ed.cur.col >= len(line) {
		return false
	}
	prev := line[ed.cur.col - 1]
	next := line[ed.cur.col]
	for p in AUTO_PAIRS {
		if prev == p.open && next == p.close {
			ed.cur = buf_apply(
				&ed.buf,
				{ed.cur.line, ed.cur.col - 1},
				{ed.cur.line, ed.cur.col + 1},
				"",
				ed.cur,
				.No,
			)
			ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
			return true
		}
	}
	return false
}

// return_in_pair is the third behaviour auto-close needs, and the one that
// turns `{` from a nuisance into the fastest way to open a block: Return
// pressed between an empty pair puts the closing half on its own line and the
// caret on an indented blank line between them.
//
// Quotes are excluded — a string split across two lines is not what anyone
// meant by pressing Return inside one.
return_in_pair :: proc(ed: ^Editor) -> bool {
	line := buf_line(&ed.buf, ed.cur.line)
	if ed.cur.col <= 0 || ed.cur.col >= len(line) {
		return false
	}
	if _, has := sel_is_live(ed); has {
		return false
	}
	prev := line[ed.cur.col - 1]
	next := line[ed.cur.col]
	p, is_open := bracket_open_for(prev)
	if !is_open || next != p.close {
		return false
	}
	indent := 0
	for indent < len(line) && (line[indent] == ' ' || line[indent] == '\t') {
		indent += 1
	}
	lead := line[:min(indent, ed.cur.col)]
	at := ed.cur
	buf_apply(&ed.buf, at, at, tfmt("\n%s\t\n%s", lead, lead), at, .No)
	ed.cur = pos_clamp(&ed.buf, {at.line + 1, len(lead) + 1})
	clear_sel(ed)
	ed.goal = disp_of(buf_line(&ed.buf, ed.cur.line), ed.cur.col)
	return true
}

// sel_is_live is sel_range without the positions, for the places that only
// need to know whether anything is selected.
sel_is_live :: proc(ed: ^Editor) -> (Pos, bool) {
	_, _, ok := sel_range(ed)
	return ed.cur, ok
}
