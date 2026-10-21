// A unified diff between two texts, line by line.
//
// It is what `editor replace --dry-run` and `editor edit --dry-run` print: the
// change a command would make, in the format every person and every tool
// already reads. The common head and tail are trimmed first, so the usual edit
// — a few lines somewhere in a long file — costs a longest-common-subsequence
// table the size of the few lines, not of the file. A middle too big for the
// table (more than four million cells) is shown as one replaced block, which is
// still a correct diff, only not a minimal one.
package main

import "core:fmt"
import "core:strings"

DIFF_CONTEXT :: 3
DIFF_TABLE_MAX :: 4_000_000

@(private = "file")
Op :: struct {
	kind: u8, // ' ', '-', '+'
	a, b: int, // line index in each side (the one that applies)
}

// split_for_diff splits on \n, dropping the empty string after a final
// newline: "a\nb\n" is two lines, as diff counts them.
split_for_diff :: proc(s: string) -> []string {
	if s == "" {
		return nil
	}
	parts := strings.split(s, "\n", context.temp_allocator)
	if len(parts) > 0 && parts[len(parts) - 1] == "" {
		parts = parts[:len(parts) - 1]
	}
	for &p in parts {
		p = strings.trim_suffix(p, "\r")
	}
	return parts
}

// unified_diff returns "" when the texts are equal.
unified_diff :: proc(old_text, new_text, old_name, new_name: string, allocator := context.temp_allocator) -> (diff: string, added, removed: int) {
	if old_text == new_text {
		return "", 0, 0
	}
	a := split_for_diff(old_text)
	b := split_for_diff(new_text)

	ops := make([dynamic]Op, context.temp_allocator)
	pre := 0
	for pre < len(a) && pre < len(b) && a[pre] == b[pre] {
		pre += 1
	}
	suf := 0
	for suf < len(a) - pre && suf < len(b) - pre && a[len(a) - 1 - suf] == b[len(b) - 1 - suf] {
		suf += 1
	}
	for i in 0 ..< pre {
		append(&ops, Op{' ', i, i})
	}
	am := a[pre:len(a) - suf]
	bm := b[pre:len(b) - suf]
	n, m := len(am), len(bm)
	if n > 0 && m > 0 && (n + 1) * (m + 1) <= DIFF_TABLE_MAX {
		// lcs[i][j] is the LCS of am[i:] and bm[j:].
		w := m + 1
		lcs := make([]u32, (n + 1) * (m + 1), context.temp_allocator)
		for i := n - 1; i >= 0; i -= 1 {
			for j := m - 1; j >= 0; j -= 1 {
				if am[i] == bm[j] {
					lcs[i * w + j] = lcs[(i + 1) * w + j + 1] + 1
				} else {
					lcs[i * w + j] = max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
				}
			}
		}
		i, j := 0, 0
		for i < n || j < m {
			switch {
			case i < n && j < m && am[i] == bm[j]:
				append(&ops, Op{' ', pre + i, pre + j})
				i += 1
				j += 1
			case i < n && (j == m || lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]):
				// Removals before additions, the way diff prints a change.
				append(&ops, Op{'-', pre + i, pre + j})
				i += 1
			case:
				append(&ops, Op{'+', pre + i, pre + j})
				j += 1
			}
		}
	} else {
		for i in 0 ..< n {
			append(&ops, Op{'-', pre + i, pre})
		}
		for j in 0 ..< m {
			append(&ops, Op{'+', pre + n, pre + j})
		}
	}
	for k in 0 ..< suf {
		append(&ops, Op{' ', len(a) - suf + k, len(b) - suf + k})
	}

	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "--- %s\n+++ %s\n", old_name, new_name)
	// Hunks: runs of changes with DIFF_CONTEXT lines of context either side,
	// merged when their contexts touch.
	k := 0
	for k < len(ops) {
		for k < len(ops) && ops[k].kind == ' ' {
			k += 1
		}
		if k >= len(ops) {
			break
		}
		start := max(0, k - DIFF_CONTEXT)
		end := k
		for end < len(ops) {
			if ops[end].kind != ' ' {
				end += 1
				continue
			}
			run := end
			for run < len(ops) && ops[run].kind == ' ' {
				run += 1
			}
			if run >= len(ops) || run - end > 2 * DIFF_CONTEXT {
				end = min(len(ops), end + DIFF_CONTEXT)
				break
			}
			end = run
		}
		a0, b0, ac, bc := -1, -1, 0, 0
		for o in ops[start:end] {
			if o.kind != '+' {
				if a0 < 0 {a0 = o.a}
				ac += 1
			}
			if o.kind != '-' {
				if b0 < 0 {b0 = o.b}
				bc += 1
			}
		}
		// An empty side is numbered by the line before it, as diff does.
		if a0 < 0 {a0 = ops[start].a}
		if b0 < 0 {b0 = ops[start].b}
		fmt.sbprintf(&sb, "@@ -%d,%d +%d,%d @@\n", ac == 0 ? a0 : a0 + 1, ac, bc == 0 ? b0 : b0 + 1, bc)
		for o in ops[start:end] {
			switch o.kind {
			case ' ':
				fmt.sbprintf(&sb, " %s\n", a[o.a])
			case '-':
				fmt.sbprintf(&sb, "-%s\n", a[o.a])
				removed += 1
			case '+':
				fmt.sbprintf(&sb, "+%s\n", b[o.b])
				added += 1
			}
		}
		k = end
	}
	return strings.to_string(sb), added, removed
}
