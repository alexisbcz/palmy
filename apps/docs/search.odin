// What the find box searches with: Unicode case folding, and a regular
// expression engine.
//
// WHY THIS IS NOT `strings.contains`
//
// Two things a find box has to get right that a byte scan cannot:
//
//   * **Case outside ASCII.** `lower()` on a byte folds `A`–`Z` and nothing
//     else, so `Straße` did not match `STRASSE`, `CAFÉ` did not match `café`,
//     and `ΣΙΣΥΦΟΣ` did not match `σισυφος`. Folding is per *rune*, and it is
//     not a bijection: ß folds to `ss`, ﬁ folds to `fi`, so one rune in the
//     text can stand for two in the pattern and a match is not `len(needle)`
//     bytes long. Everything downstream therefore works in spans, not
//     lengths.
//
//   * **Patterns.** Finding "a number followed by mm" or "two spaces" is what
//     a regular expression is for, and a document editor without one makes
//     people leave to use `sed`.
//
// WHAT THE FOLDING COVERS
//
// Simple and full case folding over the ranges a Latin-script document
// actually contains: ASCII, Latin-1 Supplement, Latin Extended-A, Greek and
// Cyrillic, plus the handful of expanding folds (ß, ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ, ŉ, ǰ, ΐ, ΰ)
// and the positional ones (final sigma, long s). It is a table of ranges and
// a dozen special cases, not the full Unicode `CaseFolding.txt`: Armenian,
// Georgian, Deseret, Cherokee, Adlam and the Latin Extended-B oddities are
// not folded, and are matched case-sensitively. That is a real limit, stated
// here rather than discovered later.
//
// WHAT THE REGEX ENGINE IS
//
// A backtracking VM over a small instruction set — the Thompson/Pike shape
// without the parallel threads, which is the right trade for kilobyte
// paragraphs and lets capture groups fall out for free. The syntax is the
// common subset:
//
//     .  any rune          *  + ?  greedy, and *? +? ?? lazy
//     [] class, ranges and ^negation, \d \w \s inside
//     () capture, 1–9      |  alternation      {m} {m,} {m,n} repeat
//     ^  $  start and end of the paragraph      \b \B word boundary
//     \d \D \w \W \s \S    \n \t \r             \ escapes a metacharacter
//
// Backtracking can be made exponential by a pattern like `(a*)*b`, so the VM
// counts steps and gives up rather than hanging the editor; the find box then
// reports no match. That is the honest behaviour for an interactive search.
package main

import "core:strings"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Case folding
// ---------------------------------------------------------------------------

// fold_rune returns the folded form of one rune: usually itself lowercased,
// occasionally two or three runes.
fold_rune :: proc(r: rune) -> (out: [3]rune, n: int) {
	// The expansions first, because they are the reason this returns a slice
	// at all.
	switch r {
	case 'ß':
		return {'s', 's', 0}, 2
	case 'ﬀ':
		return {'f', 'f', 0}, 2
	case 'ﬁ':
		return {'f', 'i', 0}, 2
	case 'ﬂ':
		return {'f', 'l', 0}, 2
	case 'ﬃ':
		return {'f', 'f', 'i'}, 3
	case 'ﬄ':
		return {'f', 'f', 'l'}, 3
	case 'ﬅ', 'ﬆ':
		return {'s', 't', 0}, 2
	case 'ŉ':
		return {0x02bc, 'n', 0}, 2
	case 'ǰ':
		return {'j', 0x030c, 0}, 2
	case 0x0130: // İ — the dotted capital I
		return {'i', 0x0307, 0}, 2
	}
	out[0] = fold_simple(r)
	return out, 1
}

// fold_simple is the one-rune-to-one-rune part, which is what the regex
// engine compares with.
fold_simple :: proc(r: rune) -> rune {
	switch {
	case r < 0x80:
		return r >= 'A' && r <= 'Z' ? r + 32 : r

	// Latin-1 Supplement. 0xD7 is ×, which is not a letter.
	case r >= 0x00c0 && r <= 0x00de && r != 0x00d7:
		return r + 0x20
	case r == 0x017f: // ſ, the long s
		return 's'

	// Latin Extended-A is almost entirely even/odd upper/lower pairs.
	case r >= 0x0100 && r <= 0x0137, r >= 0x014a && r <= 0x0177:
		return r % 2 == 0 ? r + 1 : r
	case r >= 0x0139 && r <= 0x0148, r >= 0x0179 && r <= 0x017e:
		return r % 2 == 1 ? r + 1 : r
	case r == 0x0178: // Ÿ
		return 0x00ff

	// Greek. 0x3A2 is unassigned; final sigma folds onto sigma so that
	// "ΟΔΥΣΣΕΥΣ" and "οδυσσευς" are the same word.
	case r >= 0x0391 && r <= 0x03a9 && r != 0x03a2:
		return r + 0x20
	case r == 0x03c2:
		return 0x03c3
	case r == 0x0386:
		return 0x03ac
	case r >= 0x0388 && r <= 0x038a:
		return r + 0x25
	case r == 0x038c:
		return 0x03cc
	case r == 0x038e:
		return 0x03cd
	case r == 0x038f:
		return 0x03ce

	// Cyrillic.
	case r >= 0x0410 && r <= 0x042f:
		return r + 0x20
	case r >= 0x0400 && r <= 0x040f:
		return r + 0x50
	case r >= 0x0460 && r <= 0x0481, r >= 0x048a && r <= 0x04bf:
		return r % 2 == 0 ? r + 1 : r
	case r >= 0x04c1 && r <= 0x04ce:
		return r % 2 == 1 ? r + 1 : r
	case r >= 0x04d0 && r <= 0x052f:
		return r % 2 == 0 ? r + 1 : r
	}
	return r
}

// Fold_Cursor walks a string as a stream of folded runes. `pos` is the byte
// offset of the *next* rune, so a match can report where in the original text
// it ended — which is the whole reason this is a cursor rather than a
// "fold the string and search that": a folded copy has different offsets.
Fold_Cursor :: struct {
	s:    string,
	pos:  int,
	buf:  [3]rune,
	have: int,
	at:   int,
}

fold_cursor :: proc(s: string, from: int) -> Fold_Cursor {
	return Fold_Cursor{s = s, pos = clamp(from, 0, len(s))}
}

// fold_next yields the next folded rune, and the byte offset just past the
// source rune it came from once its expansion is exhausted.
fold_next :: proc(c: ^Fold_Cursor, fold: bool) -> (r: rune, boundary: int, ok: bool) {
	if c.at >= c.have {
		if c.pos >= len(c.s) {
			return 0, c.pos, false
		}
		src, w := utf8.decode_rune_in_string(c.s[c.pos:])
		if w <= 0 {
			return 0, c.pos, false
		}
		c.pos += w
		if fold {
			c.buf, c.have = fold_rune(src)
		} else {
			c.buf[0], c.have = src, 1
		}
		c.at = 0
	}
	r = c.buf[c.at]
	c.at += 1
	// The boundary is only meaningful once the whole expansion has been
	// consumed: half of an ß is not a place a match can end.
	return r, c.at >= c.have ? c.pos : -1, true
}

// ---------------------------------------------------------------------------
// Plain search, in spans
// ---------------------------------------------------------------------------

// match_folded_at tests the needle against the haystack starting exactly at
// `at`, and returns the byte offset just past the match. A fold that expands
// means the two can differ in length: `Straße` (7 bytes) matches the pattern
// `strasse` (7) and `STRASSE` (7) matches the pattern `straße` (7), but
// `Straße` also matches `STRASSE` where neither is the other's length.
match_folded_at :: proc(hay, needle: string, at: int, fold := true) -> (end: int, ok: bool) {
	h := fold_cursor(hay, at)
	n := fold_cursor(needle, 0)
	last := at
	for {
		want, _, more := fold_next(&n, fold)
		if !more {
			// A match may not end half way through an expansion: the `s` of
			// `ss` is not a place where `Straße` can be cut.
			if h.at < h.have {
				return at, false
			}
			return last, true
		}
		got, boundary, have := fold_next(&h, fold)
		if !have || got != want {
			return at, false
		}
		if boundary >= 0 {
			last = boundary
		}
	}
}

// is_word_rune is the word-boundary test, in runes: a letter anywhere in
// Unicode counts, not only `[A-Za-z0-9_]`, or "whole word" would cut
// `Grüße` in half.
is_word_rune :: proc(r: rune) -> bool {
	switch {
	case r >= '0' && r <= '9', r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r == '_':
		return true
	case r < 0x80:
		return false
	case r >= 0x00c0 && r != 0x00d7 && r != 0x00f7:
		// Everything above the Latin-1 punctuation block is treated as a
		// letter. Over-inclusive on CJK punctuation, and right on every
		// alphabet this editor is likely to see.
		return true
	}
	return false
}

// rune_ending_at decodes the rune that ends at byte offset `at`. (`model.odin`
// already has a `rune_before` that returns an offset rather than a rune.)
rune_ending_at :: proc(s: string, at: int) -> rune {
	i := clamp(at, 0, len(s))
	if i == 0 {
		return 0
	}
	j := i - 1
	for j > 0 && s[j] & 0xc0 == 0x80 {
		j -= 1
	}
	r, _ := utf8.decode_rune_in_string(s[j:])
	return r
}

rune_at_off :: proc(s: string, at: int) -> rune {
	if at < 0 || at >= len(s) {
		return 0
	}
	r, _ := utf8.decode_rune_in_string(s[at:])
	return r
}

// search_plain is the literal search: a forward scan, rune by rune, with the
// word-boundary test applied to the span that was actually matched.
search_plain :: proc(
	hay, needle: string,
	from: int,
	fold := true,
	word := false,
) -> (
	lo, hi: int,
	ok: bool,
) {
	if len(needle) == 0 {
		return 0, 0, false
	}
	i := clamp(from, 0, len(hay))
	for i <= len(hay) {
		if end, hit := match_folded_at(hay, needle, i, fold); hit && end > i {
			if !word || (!is_word_rune(rune_ending_at(hay, i)) && !is_word_rune(rune_at_off(hay, end))) {
				return i, end, true
			}
		}
		if i >= len(hay) {
			break
		}
		// Advance by a whole rune: a match can never start inside one.
		i += 1
		for i < len(hay) && hay[i] & 0xc0 == 0x80 {
			i += 1
		}
	}
	return 0, 0, false
}

// ---------------------------------------------------------------------------
// The regular expression engine
// ---------------------------------------------------------------------------

// The bail-out, so that a pathological pattern cannot hang a frame: steps
// bound the total work of one search. There is no depth limit because the
// matcher does not recurse — its choice points live on a heap stack (see
// `rx_exec`), and every push costs a step, so the stack is bounded by this
// too. It used to recurse once per greedy repetition, which at 20 000 frames
// deep ran the default 8 MB thread stack out on `(a*)*b`.
RX_MAX_STEPS :: 200_000
RX_GROUPS :: 10

Rx_Op :: enum {
	Char,
	Any,
	Class,
	Split,
	Jmp,
	Save,
	Bol,
	Eol,
	Word_B,
	Not_Word_B,
	Match,
}

Rx_Inst :: struct {
	op:  Rx_Op,
	ch:  rune,
	x:   int, // Split/Jmp target, Save slot, Class index
	y:   int, // Split's second target
}

Rx_Range :: struct {
	lo, hi: rune,
}

Rx_Class :: struct {
	neg:    bool,
	ranges: [dynamic]Rx_Range,
}

Rx :: struct {
	prog:    [dynamic]Rx_Inst,
	classes: [dynamic]Rx_Class,
	fold:    bool,
	ngroups: int,
	src:     string,
}

rx_destroy :: proc(rx: ^Rx) {
	if rx == nil {
		return
	}
	delete(rx.prog)
	for &c in rx.classes {
		delete(c.ranges)
	}
	delete(rx.classes)
	delete(rx.src)
	rx^ = {}
}

// --- the parser --------------------------------------------------------
//
// Recursive descent straight into the instruction list. `alt` is the top
// level; each level emits code and returns, so no AST is built.

@(private = "file")
Rx_Parser :: struct {
	pat:   string,
	i:     int,
	rx:    ^Rx,
	err:   string,
	group: int,
}

@(private = "file")
emit :: proc(p: ^Rx_Parser, inst: Rx_Inst) -> int {
	append(&p.rx.prog, inst)
	return len(p.rx.prog) - 1
}

@(private = "file")
peek_b :: proc(p: ^Rx_Parser) -> u8 {
	return p.i < len(p.pat) ? p.pat[p.i] : 0
}

// rx_compile turns a pattern into a program. A bad pattern returns ok=false
// with a message the find bar can show, rather than matching nothing silently.
rx_compile :: proc(pattern: string, fold: bool) -> (rx: ^Rx, err: string) {
	rx = new(Rx)
	rx.prog = make([dynamic]Rx_Inst, 0, 32)
	rx.classes = make([dynamic]Rx_Class, 0, 4)
	rx.fold = fold
	rx.src = strings.clone(pattern)

	p := Rx_Parser {
		pat = pattern,
		rx  = rx,
	}
	// Slot 0/1 are the whole match.
	emit(&p, Rx_Inst{op = .Save, x = 0})
	rx_alt(&p)
	if p.err == "" && p.i < len(p.pat) {
		p.err = "unbalanced )"
	}
	emit(&p, Rx_Inst{op = .Save, x = 1})
	emit(&p, Rx_Inst{op = .Match})
	rx.ngroups = p.group
	if p.err != "" {
		e := p.err
		rx_destroy(rx)
		free(rx)
		return nil, e
	}
	return rx, ""
}

// rx_alt parses `seq (| seq)*`. Each alternative is wrapped in a Split that
// tries it and falls through to the next.
@(private = "file")
rx_alt :: proc(p: ^Rx_Parser) {
	start := len(p.rx.prog)
	rx_seq(p)
	for p.err == "" && peek_b(p) == '|' {
		p.i += 1
		// Splice a Split in front of everything emitted for this alternation
		// so far, and a Jmp over the alternative that follows. Targets at or
		// past the splice point move with it.
		rx_shift(p, start, 1)
		inject_at(&p.rx.prog, start, Rx_Inst{op = .Split, x = start + 1})
		jmp := emit(p, Rx_Inst{op = .Jmp})
		p.rx.prog[start].y = len(p.rx.prog)
		rx_seq(p)
		p.rx.prog[jmp].x = len(p.rx.prog)
	}
}

// rx_shift moves every absolute target at or past `from` by `by`, which is
// what splicing an instruction into the middle of a program costs.
@(private = "file")
rx_shift :: proc(p: ^Rx_Parser, from, by: int) {
	for &in_ in p.rx.prog {
		#partial switch in_.op {
		case .Split:
			if in_.x >= from {in_.x += by}
			if in_.y >= from {in_.y += by}
		case .Jmp:
			if in_.x >= from {in_.x += by}
		}
	}
}

@(private = "file")
rx_seq :: proc(p: ^Rx_Parser) {
	for p.err == "" && p.i < len(p.pat) {
		c := peek_b(p)
		if c == '|' || c == ')' {
			return
		}
		rx_term(p)
	}
}

@(private = "file")
rx_term :: proc(p: ^Rx_Parser) {
	start := len(p.rx.prog)
	if !rx_atom(p) || p.err != "" {
		return
	}
	// A quantifier, if one follows.
	for p.i < len(p.pat) {
		c := p.pat[p.i]
		min, max := 0, 0
		switch c {
		case '*':
			min, max = 0, -1
		case '+':
			min, max = 1, -1
		case '?':
			min, max = 0, 1
		case '{':
			lo, hi, n, ok := rx_braces(p.pat, p.i)
			if !ok {
				return // a literal brace, already emitted as a Char atom
			}
			p.i += n
			rx_repeat(p, start, lo, hi, rx_lazy(p))
			continue
		case:
			return
		}
		p.i += 1
		rx_repeat(p, start, min, max, rx_lazy(p))
	}
}

// rx_lazy consumes a trailing `?` and reports whether the quantifier is lazy.
@(private = "file")
rx_lazy :: proc(p: ^Rx_Parser) -> bool {
	if p.i < len(p.pat) && p.pat[p.i] == '?' {
		p.i += 1
		return true
	}
	return false
}

// rx_braces reads `{m}`, `{m,}` or `{m,n}`. Anything else is a literal brace.
@(private = "file")
rx_braces :: proc(pat: string, at: int) -> (lo, hi, used: int, ok: bool) {
	i := at + 1
	a, da := 0, 0
	for i < len(pat) && pat[i] >= '0' && pat[i] <= '9' {
		a = a * 10 + int(pat[i] - '0')
		i += 1
		da += 1
	}
	if da == 0 {
		return 0, 0, 0, false
	}
	if i < len(pat) && pat[i] == '}' {
		return a, a, i + 1 - at, true
	}
	if i >= len(pat) || pat[i] != ',' {
		return 0, 0, 0, false
	}
	i += 1
	b, db := 0, 0
	for i < len(pat) && pat[i] >= '0' && pat[i] <= '9' {
		b = b * 10 + int(pat[i] - '0')
		i += 1
		db += 1
	}
	if i >= len(pat) || pat[i] != '}' {
		return 0, 0, 0, false
	}
	return a, db == 0 ? -1 : b, i + 1 - at, true
}

// rx_repeat rewrites the instructions from `start` as a repetition.
//
// `{m,n}` is expanded by copying the body, which is why the counts are capped:
// a pattern may not make a program bigger than a page of code.
RX_MAX_REPEAT :: 64

@(private = "file")
rx_repeat :: proc(p: ^Rx_Parser, start, rmin, rmax: int, lazy: bool) {
	if rmax >= 0 && rmax < rmin {
		p.err = "{m,n} with n < m"
		return
	}
	if rmin > RX_MAX_REPEAT || rmax > RX_MAX_REPEAT {
		p.err = "a repeat count that large is not supported"
		return
	}
	body := make([]Rx_Inst, len(p.rx.prog) - start, context.temp_allocator)
	copy(body, p.rx.prog[start:])
	resize(&p.rx.prog, start)

	// `{m,n}` is m copies then (n-m) optional ones; `{m,}` is m copies
	// followed by a star; `*`, `+` and `?` are the special cases of those.
	n_fixed := rmax == -1 ? max(rmin, 0) : rmin
	for _ in 0 ..< n_fixed {
		rx_paste(p, body, start, len(p.rx.prog))
	}
	if rmax == -1 {
		split := emit(p, Rx_Inst{op = .Split})
		at := len(p.rx.prog)
		rx_paste(p, body, start, at)
		emit(p, Rx_Inst{op = .Jmp, x = split})
		after := len(p.rx.prog)
		p.rx.prog[split].x = lazy ? after : at
		p.rx.prog[split].y = lazy ? at : after
		return
	}
	opt := rmax - rmin
	splits := make([dynamic]int, 0, max(1, opt), context.temp_allocator)
	for _ in 0 ..< opt {
		sp := emit(p, Rx_Inst{op = .Split})
		append(&splits, sp)
		rx_paste(p, body, start, len(p.rx.prog))
	}
	after := len(p.rx.prog)
	for sp in splits {
		p.rx.prog[sp].x = lazy ? after : sp + 1
		p.rx.prog[sp].y = lazy ? sp + 1 : after
	}
}

// rx_paste appends a copy of `body` — lifted from offset `base` — at `at`,
// relocating the absolute targets inside it.
@(private = "file")
rx_paste :: proc(p: ^Rx_Parser, body: []Rx_Inst, base, at: int) {
	for in_ in body {
		c := in_
		#partial switch c.op {
		case .Split:
			c.x = c.x - base + at
			c.y = c.y - base + at
		case .Jmp:
			c.x = c.x - base + at
		}
		append(&p.rx.prog, c)
	}
}

@(private = "file")
rx_atom :: proc(p: ^Rx_Parser) -> bool {
	if p.i >= len(p.pat) {
		return false
	}
	c := p.pat[p.i]
	switch c {
	case '(':
		p.i += 1
		capture := true
		if strings.has_prefix(p.pat[p.i:], "?:") {
			p.i += 2
			capture = false
		}
		slot := 0
		if capture {
			p.group += 1
			if p.group >= RX_GROUPS {
				p.err = "too many capture groups"
				return false
			}
			slot = p.group * 2
			emit(p, Rx_Inst{op = .Save, x = slot})
		}
		rx_alt(p)
		if p.i >= len(p.pat) || p.pat[p.i] != ')' {
			if p.err == "" {
				p.err = "missing )"
			}
			return false
		}
		p.i += 1
		if capture {
			emit(p, Rx_Inst{op = .Save, x = slot + 1})
		}
		return true
	case '[':
		return rx_class(p)
	case '.':
		p.i += 1
		emit(p, Rx_Inst{op = .Any})
		return true
	case '^':
		p.i += 1
		emit(p, Rx_Inst{op = .Bol})
		return true
	case '$':
		p.i += 1
		emit(p, Rx_Inst{op = .Eol})
		return true
	case '*', '+', '?':
		p.err = "a quantifier with nothing in front of it"
		return false
	case '\\':
		return rx_escape(p)
	}
	r, w := utf8.decode_rune_in_string(p.pat[p.i:])
	p.i += max(1, w)
	emit(p, Rx_Inst{op = .Char, ch = p.rx.fold ? fold_simple(r) : r})
	return true
}

// rx_escape handles the backslash forms outside a class.
@(private = "file")
rx_escape :: proc(p: ^Rx_Parser) -> bool {
	p.i += 1
	if p.i >= len(p.pat) {
		p.err = "a trailing backslash"
		return false
	}
	c := p.pat[p.i]
	p.i += 1
	switch c {
	case 'd', 'D', 'w', 'W', 's', 'S':
		idx := rx_add_shorthand(p.rx, c)
		emit(p, Rx_Inst{op = .Class, x = idx})
		return true
	case 'b':
		emit(p, Rx_Inst{op = .Word_B})
		return true
	case 'B':
		emit(p, Rx_Inst{op = .Not_Word_B})
		return true
	case 'n':
		emit(p, Rx_Inst{op = .Char, ch = '\n'})
		return true
	case 't':
		emit(p, Rx_Inst{op = .Char, ch = '\t'})
		return true
	case 'r':
		emit(p, Rx_Inst{op = .Char, ch = '\r'})
		return true
	}
	r, w := utf8.decode_rune_in_string(p.pat[p.i - 1:])
	p.i += max(0, w - 1)
	emit(p, Rx_Inst{op = .Char, ch = p.rx.fold ? fold_simple(r) : r})
	return true
}

@(private = "file")
rx_add_shorthand :: proc(rx: ^Rx, c: u8) -> int {
	cl := Rx_Class {
		ranges = make([dynamic]Rx_Range, 0, 4),
	}
	switch c {
	case 'd', 'D':
		append(&cl.ranges, Rx_Range{'0', '9'})
		cl.neg = c == 'D'
	case 'w', 'W':
		append(&cl.ranges, Rx_Range{'0', '9'}, Rx_Range{'A', 'Z'}, Rx_Range{'a', 'z'}, Rx_Range{'_', '_'})
		append(&cl.ranges, Rx_Range{0x00c0, 0x024f}, Rx_Range{0x0370, 0x04ff})
		cl.neg = c == 'W'
	case 's', 'S':
		append(&cl.ranges, Rx_Range{' ', ' '}, Rx_Range{'\t', '\t'}, Rx_Range{'\n', '\n'})
		append(&cl.ranges, Rx_Range{'\r', '\r'}, Rx_Range{0x00a0, 0x00a0})
		cl.neg = c == 'S'
	}
	append(&rx.classes, cl)
	return len(rx.classes) - 1
}

@(private = "file")
rx_class :: proc(p: ^Rx_Parser) -> bool {
	p.i += 1 // past '['
	cl := Rx_Class {
		ranges = make([dynamic]Rx_Range, 0, 8),
	}
	if p.i < len(p.pat) && p.pat[p.i] == '^' {
		cl.neg = true
		p.i += 1
	}
	first := true
	for {
		if p.i >= len(p.pat) {
			delete(cl.ranges)
			p.err = "missing ]"
			return false
		}
		if p.pat[p.i] == ']' && !first {
			p.i += 1
			break
		}
		first = false
		// A shorthand inside a class folds its ranges into this one.
		if p.pat[p.i] == '\\' && p.i + 1 < len(p.pat) {
			e := p.pat[p.i + 1]
			switch e {
			case 'd', 'w', 's':
				idx := rx_add_shorthand(p.rx, e)
				for r in p.rx.classes[idx].ranges {
					append(&cl.ranges, r)
				}
				p.i += 2
				continue
			case 'n':
				append(&cl.ranges, Rx_Range{'\n', '\n'})
				p.i += 2
				continue
			case 't':
				append(&cl.ranges, Rx_Range{'\t', '\t'})
				p.i += 2
				continue
			}
			p.i += 1 // the escaped character is taken literally below
		}
		lo, w := utf8.decode_rune_in_string(p.pat[p.i:])
		p.i += max(1, w)
		hi := lo
		if p.i + 1 < len(p.pat) && p.pat[p.i] == '-' && p.pat[p.i + 1] != ']' {
			p.i += 1
			h, w2 := utf8.decode_rune_in_string(p.pat[p.i:])
			p.i += max(1, w2)
			hi = h
		}
		if hi < lo {
			lo, hi = hi, lo
		}
		append(&cl.ranges, Rx_Range{lo, hi})
	}
	append(&p.rx.classes, cl)
	emit(p, Rx_Inst{op = .Class, x = len(p.rx.classes) - 1})
	return true
}

@(private = "file")
class_has :: proc(rx: ^Rx, idx: int, r: rune) -> bool {
	if idx < 0 || idx >= len(rx.classes) {
		return false
	}
	cl := &rx.classes[idx]
	// A case-insensitive class tests both cases of the character, which is
	// cheaper and more predictable than trying to fold the ranges.
	cands: [3]rune
	n := 1
	cands[0] = r
	if rx.fold {
		if f := fold_simple(r); f != r {
			cands[n] = f
			n += 1
		}
		if u := upper_simple(r); u != r {
			cands[n] = u
			n += 1
		}
	}
	in_ := false
	outer: for rg in cl.ranges {
		for k in 0 ..< n {
			if cands[k] >= rg.lo && cands[k] <= rg.hi {
				in_ = true
				break outer
			}
		}
	}
	return cl.neg ? !in_ : in_
}

// upper_simple is the inverse of `fold_simple` over the same ranges, used
// only to test a character class both ways round.
upper_simple :: proc(r: rune) -> rune {
	switch {
	case r >= 'a' && r <= 'z':
		return r - 32
	case r >= 0x00e0 && r <= 0x00fe && r != 0x00f7:
		return r - 0x20
	case r == 0x00ff:
		return 0x0178
	case r >= 0x0101 && r <= 0x0137, r >= 0x014b && r <= 0x0177:
		return r % 2 == 1 ? r - 1 : r
	case r >= 0x013a && r <= 0x0148, r >= 0x017a && r <= 0x017e:
		return r % 2 == 0 ? r - 1 : r
	case r >= 0x03b1 && r <= 0x03c9 && r != 0x03c2:
		return r - 0x20
	case r >= 0x0430 && r <= 0x044f:
		return r - 0x20
	case r >= 0x0450 && r <= 0x045f:
		return r - 0x50
	}
	return r
}

// --- the matcher -------------------------------------------------------

Rx_Caps :: [RX_GROUPS * 2]int

// A choice point the matcher can come back to. `.Branch` resumes at (pc, sp);
// `.Restore` puts a capture slot back the way it was before a `.Save` that a
// failed branch went through. Popping until a `.Branch` therefore undoes
// exactly the captures the abandoned path made, which is what the recursive
// version did with its saved copies.
@(private = "file")
Rx_Back :: struct {
	restore: bool,
	pc, sp:  int, // .Branch: where to resume; .Restore: pc = slot, sp = old value
}

@(private = "file")
Rx_Run :: struct {
	rx:    ^Rx,
	hay:   string,
	steps: int,
	stack: [dynamic]Rx_Back,
}

// rx_exec runs the program at one starting offset: a backtracking matcher
// with an explicit stack, leftmost-first (a `.Split` tries `x` before `y`).
@(private = "file")
rx_exec :: proc(run: ^Rx_Run, pc_in, sp_in: int, caps: ^Rx_Caps) -> (end: int, ok: bool) {
	clear(&run.stack)
	pc, sp := pc_in, sp_in
	for {
		fail := false
		run.steps += 1
		if run.steps > RX_MAX_STEPS {
			return 0, false
		}
		if pc < 0 || pc >= len(run.rx.prog) {
			fail = true
		} else {
			in_ := run.rx.prog[pc]
			switch in_.op {
			case .Match:
				return sp, true
			case .Char:
				if sp >= len(run.hay) {
					fail = true
					break
				}
				r, w := utf8.decode_rune_in_string(run.hay[sp:])
				if run.rx.fold {
					r = fold_simple(r)
				}
				if r != in_.ch {
					fail = true
					break
				}
				sp += max(1, w)
				pc += 1
			case .Any:
				if sp >= len(run.hay) {
					fail = true
					break
				}
				_, w := utf8.decode_rune_in_string(run.hay[sp:])
				sp += max(1, w)
				pc += 1
			case .Class:
				if sp >= len(run.hay) {
					fail = true
					break
				}
				r, w := utf8.decode_rune_in_string(run.hay[sp:])
				if !class_has(run.rx, in_.x, r) {
					fail = true
					break
				}
				sp += max(1, w)
				pc += 1
			case .Bol:
				if sp != 0 {
					fail = true
					break
				}
				pc += 1
			case .Eol:
				if sp != len(run.hay) {
					fail = true
					break
				}
				pc += 1
			case .Word_B, .Not_Word_B:
				before := is_word_rune(rune_ending_at(run.hay, sp))
				after := is_word_rune(rune_at_off(run.hay, sp))
				at_b := before != after
				if (in_.op == .Word_B) != at_b {
					fail = true
					break
				}
				pc += 1
			case .Jmp:
				pc = in_.x
			case .Split:
				append(&run.stack, Rx_Back{pc = in_.y, sp = sp})
				pc = in_.x
			case .Save:
				append(&run.stack, Rx_Back{restore = true, pc = in_.x, sp = caps[in_.x]})
				caps[in_.x] = sp
				pc += 1
			}
		}
		if !fail {
			continue
		}
		// Backtrack: undo captures down to the newest branch and take it.
		resumed := false
		for len(run.stack) > 0 {
			b := pop(&run.stack)
			if b.restore {
				caps[b.pc] = b.sp
				continue
			}
			pc, sp = b.pc, b.sp
			resumed = true
			break
		}
		if !resumed {
			return 0, false
		}
	}
}

// rx_search finds the leftmost match at or after `from`. Leftmost-first, the
// Perl rule, which is what the alternation order above encodes.
rx_search :: proc(rx: ^Rx, hay: string, from: int) -> (lo, hi: int, caps: Rx_Caps, ok: bool) {
	if rx == nil {
		return 0, 0, {}, false
	}
	run := Rx_Run {
		rx  = rx,
		hay = hay,
	}
	defer delete(run.stack)
	start := clamp(from, 0, len(hay))
	for at := start; at <= len(hay); {
		c: Rx_Caps
		for i in 0 ..< len(c) {
			c[i] = -1
		}
		if e, hit := rx_exec(&run, 0, at, &c); hit {
			return at, e, c, true
		}
		if run.steps > RX_MAX_STEPS {
			return 0, 0, {}, false
		}
		if at >= len(hay) {
			break
		}
		at += 1
		for at < len(hay) && hay[at] & 0xc0 == 0x80 {
			at += 1
		}
	}
	return 0, 0, {}, false
}

// rx_expand builds a replacement, substituting `\1`…`\9` and `\0` with what
// the groups captured. `\\` is a literal backslash; everything else is
// copied, because a replacement is text, not a pattern.
rx_expand :: proc(repl, hay: string, caps: Rx_Caps, alloc := context.allocator) -> string {
	b := strings.builder_make(alloc)
	i := 0
	for i < len(repl) {
		if repl[i] == '\\' && i + 1 < len(repl) {
			c := repl[i + 1]
			if c >= '0' && c <= '9' {
				g := int(c - '0')
				lo, hi := caps[g * 2], caps[g * 2 + 1]
				if lo >= 0 && hi >= lo && hi <= len(hay) {
					strings.write_string(&b, hay[lo:hi])
				}
				i += 2
				continue
			}
			if c == '\\' {
				strings.write_byte(&b, '\\')
				i += 2
				continue
			}
			if c == 'n' {
				strings.write_byte(&b, '\n')
				i += 2
				continue
			}
			if c == 't' {
				strings.write_byte(&b, '\t')
				i += 2
				continue
			}
		}
		strings.write_byte(&b, repl[i])
		i += 1
	}
	return strings.to_string(b)
}
