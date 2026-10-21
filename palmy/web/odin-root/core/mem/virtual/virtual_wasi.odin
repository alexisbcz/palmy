#+build wasi
#+private
package mem_virtual

// Part of the web backend's overlay of the Odin root (see
// apps/tools/web-build.sh). In Odin dev-2026-09, core:mem/virtual has no
// WebAssembly implementation: virtual_other.odin's `_reserve` returns a nil
// block, so the first virtual.Arena allocation -- palmy's per-frame node arena
// -- writes through a null pointer and trips an assertion. Linear memory has
// no reserve/commit distinction, so a reservation here is simply zeroed
// memory from the wasm heap, page aligned, and a release gives it back.
// web-build.sh tags the stock virtual_other.odin `!wasi` in the overlay so the
// two do not collide.

import "base:runtime"

@(private = "file")
RESERVE_ALIGN :: 4096

_reserve :: proc "contextless" (size: uint, address_hint: uintptr) -> (data: []byte, err: Allocator_Error) {
	context = runtime.default_context()
	return runtime.mem_alloc(int(size), RESERVE_ALIGN, runtime.default_wasm_allocator())
}

_commit :: proc "contextless" (data: rawptr, size: uint) -> Allocator_Error {
	return nil
}

_decommit :: proc "contextless" (data: rawptr, size: uint) {
}

_release :: proc "contextless" (data: rawptr, size: uint) {
	context = runtime.default_context()
	runtime.mem_free_with_size(data, int(size), runtime.default_wasm_allocator())
}

_protect :: proc "contextless" (data: rawptr, size: uint, flags: Protect_Flags) -> bool {
	return false
}

_map_file :: proc "contextless" (f: any, size: i64, flags: Map_File_Flags) -> (data: []byte, error: Map_File_Error) {
	return nil, .Map_Failure
}

_unmap_file :: proc "contextless" (data: []byte) {
}
