package arabic_dump

// Shapes one string per line of the file named on the command line and prints
// what palmy's shaper decided, one line in, one line out. It exists so the
// harfbuzz harness can compare against a real build of the module rather than
// a reimplementation of it:
//
//	odin build tools/arabic/dump -collection:palmy=$PWD/palmy -out:/tmp/dump
//	FUZZ=5000 python3 tools/arabic/hb-oracle.py --cases --fuzz > /tmp/cases
//	/tmp/dump /tmp/cases > /tmp/mine
//	FUZZ=5000 python3 tools/arabic/hb-oracle.py --compare /tmp/mine --fuzz
//
// Each output field is CODEPOINT:FORM:SRC:SIZE:LIG for one shaped rune.

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: dump FILE")
		os.exit(2)
	}
	data, rerr := os.read_entire_file_from_path(os.args[1], context.allocator)
	if rerr != nil {
		fmt.eprintfln("cannot read %s", os.args[1])
		os.exit(1)
	}
	b := strings.builder_make()
	for line in strings.split_lines(string(data)) {
		strings.builder_reset(&b)
		runes := p.shape_arabic_runes(line, p.DEFAULT_SHAPE_OPTIONS, context.temp_allocator)
		for sr, i in runes {
			if i > 0 {
				strings.write_string(&b, " ")
			}
			fmt.sbprintf(&b, "%04X:%v:%d:%d:%v", sr.cp, sr.form, sr.src, sr.size, sr.lig ? "L" : "-")
		}
		fmt.println(strings.to_string(b))
		free_all(context.temp_allocator)
	}
}
