// dump — palmy's bidi resolver on stdin, for fuzzing against the oracles.
//
// tests/bidi_cases.odin can only hold a few thousand cases: it is Odin source,
// and the compiler's static arena gives out somewhere past four megabytes of
// string literal. That is plenty for a regression corpus and nowhere near
// enough for a fuzz run, so this program speaks the same line protocol as
// tools/bidi/fribidi-oracle.c and tools/bidi/icu-oracle.c and lets
// gen-bidi-cases.py --compare push hundreds of thousands of random strings
// through all three implementations at once.
//
//   build: odin build tools/bidi/dump -collection:palmy=<repo>/palmy
//   in:    one case per line — "<L|R|A> <hex cp> <hex cp> ..."
//   out:   "<par level>|<level> ...|<logical index in visual order> ..."
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import p "palmy:."

main :: proc() {
	scratch: p.Bidi_Scratch
	p.bidi_scratch_init(&scratch)
	defer p.bidi_scratch_destroy(&scratch)

	// Read the whole corpus in one go: a fuzz run is tens of megabytes at
	// most, and a line-at-a-time read of a pipe is the slowest part of the
	// three-way comparison.
	input: [dynamic]u8
	defer delete(input)
	chunk: [1 << 16]u8
	for {
		n, err := os.read(os.stdin, chunk[:])
		if n <= 0 || err != nil {
			break
		}
		append(&input, ..chunk[:n])
	}

	out: strings.Builder
	strings.builder_init(&out)
	defer strings.builder_destroy(&out)

	text: strings.Builder
	strings.builder_init(&text)
	defer strings.builder_destroy(&text)

	order: [dynamic]i32
	defer delete(order)

	rest := string(input[:])
	for line in strings.split_lines_iterator(&rest) {
		line := strings.trim_right_space(line)
		if line == "" {
			continue
		}

		strings.builder_reset(&text)
		dir := p.Bidi_Direction.Auto
		first := true
		for field in strings.split_iterator(&line, " ") {
			if field == "" {
				continue
			}
			if first {
				switch field {
				case "L":
					dir = .LTR
				case "R":
					dir = .RTL
				case:
					dir = .Auto
				}
				first = false
				continue
			}
			cp, ok := strconv.parse_u64_of_base(field, 16)
			if !ok {
				fmt.eprintfln("bad codepoint %q", field)
				os.exit(1)
			}
			strings.write_rune(&text, rune(cp))
		}

		layout := p.bidi_resolve(strings.to_string(text), dir, &scratch)

		strings.builder_reset(&out)
		fmt.sbprintf(&out, "%d|", layout.base_level)
		for lvl, i in layout.levels {
			fmt.sbprintf(&out, "%s%d", i == 0 ? "" : " ", lvl)
		}
		strings.write_byte(&out, '|')
		resize(&order, len(layout.levels))
		n := p.bidi_visual_order(layout, order[:])
		for i in 0 ..< n {
			fmt.sbprintf(&out, "%s%d", i == 0 ? "" : " ", order[i])
		}
		strings.write_byte(&out, '\n')
		os.write_string(os.stdout, strings.to_string(out))
	}
}
