// Running the external renderers.
//
// Thin wrappers over `kit.run`, with the temp allocator as the default,
// because this app calls out to poppler and djvulibre dozens of times a
// session and every one of those strings is read once and thrown away.
package main

import kit "kit:."

kit_run :: proc(argv: []string) -> (out: string, ok: bool) {
	return kit.run(argv, context.temp_allocator)
}

kit_lines :: proc(argv: []string) -> (lines: []string, ok: bool) {
	return kit.run_lines(argv, context.temp_allocator)
}

kit_has_tool :: proc(name: string) -> bool {
	return kit.has_tool(name)
}
