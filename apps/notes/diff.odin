// From "the file changed" to "these characters changed".
//
// A note can be edited anywhere — this window, `notes write`, vim, a phone —
// and what sync receives is only the new file. Turning that into CRDT
// operations is where merge quality is won or lost. A prefix-and-suffix diff
// is exact for one keystroke, but for an afternoon of offline edits scattered
// through a note it collapses everything between the first and last change
// into one replace: re-inserting text the other device was editing, so their
// deletions inside it are lost and their insertions land in odd places.
//
// So the diff is Myers' O(ND) algorithm on *lines*, which isolates each edited
// paragraph, followed by a character-level trim inside each changed region,
// which isolates the edited words. Each hunk then touches only bytes that
// really changed, which is what lets two devices' edits to the same note
// interleave the way a person would expect.
package main

import "core:strings"
import "core:unicode/utf8"

Hunk :: struct {
	at:     int, // byte offset in the old text
	remove: int, // bytes of the old text replaced
	insert: string, // what replaces them (a slice of the new text)
}

// MAX_D bounds the work: a rewrite so total that more than this many lines
// differ is applied as one replace of the changed span, which is also what it
// semantically is.
@(private = "file")
MAX_D :: 4000

// diff_text returns the hunks that turn `old` into `new`, ascending and
// non-overlapping, offsets into `old`.
diff_text :: proc(old, new: string, allocator := context.temp_allocator) -> []Hunk {
	context.allocator = allocator
	out := make([dynamic]Hunk)
	if old == new {
		return out[:]
	}
	a := split_keep(old)
	b := split_keep(new)

	// Equal lines at both ends cost nothing to skip and keep D small.
	pre := 0
	for pre < len(a) && pre < len(b) && a[pre] == b[pre] {
		pre += 1
	}
	suf := 0
	for suf < len(a) - pre && suf < len(b) - pre && a[len(a) - 1 - suf] == b[len(b) - 1 - suf] {
		suf += 1
	}
	aa := a[pre:len(a) - suf]
	bb := b[pre:len(b) - suf]
	off_a := 0
	for l in a[:pre] {off_a += len(l)}
	off_b := off_a

	script, ok := myers(aa, bb)
	if !ok {
		// Too different to be worth aligning: one region.
		ta := strings.concatenate(aa)
		tb := strings.concatenate(bb)
		refine(&out, off_a, ta, tb)
		return out[:]
	}

	// Walk the script: runs of equal lines advance both sides; anything else
	// accumulates into a region that is refined when the next equal line (or
	// the end) closes it.
	i, j := 0, 0
	ra, rb := off_a, off_b
	ra_start, rb_start := -1, -1
	region_a := strings.builder_make()
	region_b := strings.builder_make()
	close :: proc(out: ^[dynamic]Hunk, start: int, ra, rb: ^strings.Builder, open: ^int) {
		if open^ < 0 {
			return
		}
		refine(out, start, strings.to_string(ra^), strings.to_string(rb^))
		strings.builder_reset(ra)
		strings.builder_reset(rb)
		open^ = -1
	}
	for op in script {
		switch op {
		case .Same:
			close(&out, ra_start, &region_a, &region_b, &ra_start)
			ra += len(aa[i])
			rb += len(bb[j])
			i += 1
			j += 1
		case .Del:
			if ra_start < 0 {
				ra_start = ra
				rb_start = rb
			}
			strings.write_string(&region_a, aa[i])
			ra += len(aa[i])
			i += 1
		case .Ins:
			if ra_start < 0 {
				ra_start = ra
				rb_start = rb
			}
			strings.write_string(&region_b, bb[j])
			rb += len(bb[j])
			j += 1
		}
	}
	close(&out, ra_start, &region_a, &region_b, &ra_start)
	_ = rb_start
	return out[:]
}

// refine trims the common prefix and suffix of one changed region at byte
// level, backing off to rune boundaries so a hunk never splits a character.
@(private = "file")
refine :: proc(out: ^[dynamic]Hunk, at: int, a, b: string) {
	p := 0
	for p < len(a) && p < len(b) && a[p] == b[p] {
		p += 1
	}
	for p > 0 && p < len(a) && !utf8.rune_start(a[p]) {
		p -= 1
	}
	s := 0
	for s < len(a) - p && s < len(b) - p && a[len(a) - 1 - s] == b[len(b) - 1 - s] {
		s += 1
	}
	for s > 0 && len(a) - s < len(a) && !utf8.rune_start(a[len(a) - s]) {
		s -= 1
	}
	if len(a) - p - s == 0 && len(b) - p - s == 0 {
		return
	}
	append(out, Hunk{at = at + p, remove = len(a) - p - s, insert = strings.clone(b[p:len(b) - s])})
}

@(private = "file")
Op :: enum u8 {
	Same,
	Del,
	Ins,
}

// split_keep cuts text into lines that keep their '\n', so joining them gives
// the text back byte for byte.
@(private = "file")
split_keep :: proc(s: string) -> []string {
	out := make([dynamic]string)
	start := 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			append(&out, s[start:i + 1])
			start = i + 1
		}
	}
	if start < len(s) {
		append(&out, s[start:])
	}
	return out[:]
}

// myers is the greedy forward algorithm with the V vectors kept per step so
// the path can be walked back. Lines are compared through their hashes first.
@(private = "file")
myers :: proc(a, b: []string) -> (script: []Op, ok: bool) {
	n, m := len(a), len(b)
	if n == 0 && m == 0 {
		return {}, true
	}
	ha := make([]u64, n)
	hb := make([]u64, m)
	for x, i in a {ha[i] = fnv(x)}
	for x, i in b {hb[i] = fnv(x)}
	eq :: proc(a, b: []string, ha, hb: []u64, x, y: int) -> bool {
		return ha[x] == hb[y] && a[x] == b[y]
	}

	max_d := min(n + m, MAX_D)
	off := max_d + 1
	v := make([]int, 2 * max_d + 3)
	trace := make([dynamic][]int)
	found := -1
	outer: for d in 0 ..= max_d {
		snap := make([]int, len(v))
		copy(snap, v)
		append(&trace, snap)
		for k := -d; k <= d; k += 2 {
			x: int
			if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) {
				x = v[off + k + 1]
			} else {
				x = v[off + k - 1] + 1
			}
			y := x - k
			for x < n && y < m && eq(a, b, ha, hb, x, y) {
				x += 1
				y += 1
			}
			v[off + k] = x
			if x >= n && y >= m {
				found = d
				break outer
			}
		}
	}
	if found < 0 {
		return nil, false
	}

	// Walk back from (n, m) through the saved vectors.
	rev := make([dynamic]Op)
	x, y := n, m
	for d := found; d > 0; d -= 1 {
		vv := trace[d]
		k := x - y
		prev_k: int
		if k == -d || (k != d && vv[off + k - 1] < vv[off + k + 1]) {
			prev_k = k + 1
		} else {
			prev_k = k - 1
		}
		px := vv[off + prev_k]
		py := px - prev_k
		// The non-diagonal move lands on (mx, my); the snake runs from there.
		down := prev_k == k + 1
		mx, my := down ? px : px + 1, down ? py + 1 : py
		for x > mx && y > my {
			append(&rev, Op.Same)
			x -= 1
			y -= 1
		}
		append(&rev, down ? Op.Ins : Op.Del)
		x, y = px, py
	}
	for x > 0 && y > 0 {
		append(&rev, Op.Same)
		x -= 1
		y -= 1
	}
	out := make([]Op, len(rev))
	for op, i in rev {
		out[len(rev) - 1 - i] = op
	}
	return out, true
}

// apply_hunks applies hunks to a string: the reference the tests hold the
// CRDT path to.
apply_hunks :: proc(old: string, hunks: []Hunk, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	at := 0
	for h in hunks {
		strings.write_string(&b, old[at:h.at])
		strings.write_string(&b, h.insert)
		at = h.at + h.remove
	}
	strings.write_string(&b, old[at:])
	return strings.to_string(b)
}
