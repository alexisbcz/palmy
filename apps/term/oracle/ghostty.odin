package oracle

import "core:dynlib"

// ---------------------------------------------------------------------------
// libghostty-vt, loaded at runtime.
//
// This package is never linked into term.bin. It is a separate program, built
// only by apps/term/oracle/run.sh, so that the shipped terminal keeps its
// three-line ldd and the oracle still gets used on every change. The library
// is opened the way palmy opens libxkbcommon: a struct of function pointers
// whose field names are the symbol names, filled in by dynlib.
// ---------------------------------------------------------------------------

G_Sgr_Attr :: struct {
	tag:   i32,
	_pad:  i32,
	value: [8]u64,
}

G_Unknown :: struct {
	full_ptr:    [^]u16,
	full_len:    uint,
	partial_ptr: [^]u16,
	partial_len: uint,
}

Ghostty :: struct {
	ghostty_sgr_new:                       proc "c" (alloc: rawptr, out: ^rawptr) -> i32,
	ghostty_sgr_free:                      proc "c" (p: rawptr),
	ghostty_sgr_set_params:                proc "c" (
		p: rawptr,
		params: [^]u16,
		seps: [^]u8,
		n: uint,
	) -> i32,
	ghostty_sgr_next:                      proc "c" (p: rawptr, out: ^G_Sgr_Attr) -> bool,
	ghostty_osc_new:                       proc "c" (alloc: rawptr, out: ^rawptr) -> i32,
	ghostty_osc_free:                      proc "c" (p: rawptr),
	ghostty_osc_reset:                     proc "c" (p: rawptr),
	ghostty_osc_next:                      proc "c" (p: rawptr, b: u8),
	ghostty_osc_end:                       proc "c" (p: rawptr, term: u8) -> rawptr,
	ghostty_osc_command_type:              proc "c" (cmd: rawptr) -> i32,
	ghostty_osc_command_data:              proc "c" (cmd: rawptr, kind: i32, out: rawptr) -> bool,
	ghostty_paste_is_safe:                 proc "c" (data: [^]u8, n: uint) -> bool,
	ghostty_key_encoder_new:               proc "c" (alloc: rawptr, out: ^rawptr) -> i32,
	ghostty_key_encoder_free:              proc "c" (e: rawptr),
	ghostty_key_encoder_setopt:            proc "c" (e: rawptr, opt: i32, val: rawptr),
	ghostty_key_encoder_encode:            proc "c" (
		e: rawptr,
		ev: rawptr,
		buf: [^]u8,
		size: uint,
		out_len: ^uint,
	) -> i32,
	ghostty_key_event_new:                 proc "c" (alloc: rawptr, out: ^rawptr) -> i32,
	ghostty_key_event_free:                proc "c" (ev: rawptr),
	ghostty_key_event_set_action:          proc "c" (ev: rawptr, a: i32),
	ghostty_key_event_set_key:             proc "c" (ev: rawptr, k: i32),
	ghostty_key_event_set_mods:            proc "c" (ev: rawptr, m: u16),
	ghostty_key_event_set_consumed_mods:   proc "c" (ev: rawptr, m: u16),
	ghostty_key_event_set_composing:       proc "c" (ev: rawptr, c: bool),
	ghostty_key_event_set_utf8:            proc "c" (ev: rawptr, s: [^]u8, n: uint),
	ghostty_key_event_set_unshifted_codepoint: proc "c" (ev: rawptr, cp: u32),
	ghostty_simd_codepoint_width:          proc "c" (cp: u32) -> i8,
	__handle:                              dynlib.Library,
}

// Option ids from <ghostty/vt/key/encoder.h>.
OPT_CURSOR_KEY_APPLICATION :: 0
OPT_KEYPAD_KEY_APPLICATION :: 1
OPT_IGNORE_KEYPAD_WITH_NUMLOCK :: 2
OPT_ALT_ESC_PREFIX :: 3
OPT_MODIFY_OTHER_KEYS_STATE_2 :: 4
OPT_KITTY_FLAGS :: 5

LIB_CANDIDATES := [?]string {
	"libghostty-vt.so.0",
	"libghostty-vt.so",
	"/usr/lib/libghostty-vt.so.0",
}

g: Ghostty

load_ghostty :: proc() -> (string, bool) {
	for name in LIB_CANDIDATES {
		if _, ok := dynlib.initialize_symbols(&g, name); ok {
			return name, true
		}
	}
	return "", false
}
