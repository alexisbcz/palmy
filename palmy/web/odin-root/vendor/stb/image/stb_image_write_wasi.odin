#+build wasi
package stb_image

// Part of the web backend's overlay of the Odin root (apps/tools/web-build.sh
// copies it into a symlinked copy of the toolchain; the install itself is not
// touched). Odin's stb binding has no stdio on wasm, so the file-writing entry
// points palmy uses do not exist there. On WASI a file is the page's
// filesystem, so they can: encode through `write_png_to_func` into memory and
// write the bytes with core:os.

import "base:runtime"
import "core:c"
import "core:os"

@(private = "file")
Sink :: struct {
	bytes: [dynamic]u8,
}

@(private = "file")
sink_write :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	context = runtime.default_context()
	s := (^Sink)(ctx)
	append(&s.bytes, ..([^]u8)(data)[:size])
}

write_png :: proc(filename: cstring, w, h, comp: c.int, data: rawptr, stride_in_bytes: c.int) -> c.int {
	s: Sink
	defer delete(s.bytes)
	if write_png_to_func(sink_write, &s, w, h, comp, data, stride_in_bytes) == 0 {
		return 0
	}
	if os.write_entire_file(string(filename), s.bytes[:]) != nil {
		return 0
	}
	return 1
}
