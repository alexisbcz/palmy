package main

// Translations, as the installer sees them: tr, trf, N, set_language, is_rtl.
//
// Every user-visible string in this package goes through one of these, with
// the msgid written as a literal right inside the call. That is a rule, not a
// style: selftest.odin finds the msgids by scanning the source for `tr("`,
// `trf("` and `N("`, and checks that every catalogue in
// distro/locale/*/installer.msg has each of them. A msgid built at run time
// would be invisible to that check.
//
// The catalogues are kit's (apps/kit/i18n.odin), which owns the format, the
// search path and the language fallback. This file only adds what the
// installer needs on top: `N` for msgids that are chosen in one place and
// translated in another, and finding the checkout's catalogues when the
// binary is run from distro/out/bin on a development machine.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import kit "kit:."

// The domain: catalogues are <root>/<lang>/installer.msg.
DOMAIN :: "installer"

// N marks a string as a msgid without translating it, for tables and return
// values that are translated where they are drawn (gettext's N_).
N :: proc "contextless" (msgid: string) -> string {
	return msgid
}

// tr and trf mark a right-to-left translation as such. palmy gives each
// paragraph the direction of its first strong character, so an Arabic
// sentence that starts with "GPT", "Palmframe" or a %s would otherwise be
// laid out left to right, its full stop and guillemets landing on the wrong
// side. A RIGHT-TO-LEFT MARK in front fixes the paragraph's direction and
// draws nothing.
RLM :: "\u200f"
FSI :: "\u2068" // FIRST STRONG ISOLATE
PDI :: "\u2069" // POP DIRECTIONAL ISOLATE

tr :: proc(msgid: string) -> string {
	return mark(kit.tr(msgid))
}

// trf also isolates every string argument (FSI ... PDI) in a right-to-left
// interface. "/dev/vda" inside an Arabic sentence is otherwise taken apart
// by the bidi algorithm — its leading slash is neutral and joins the Arabic
// run — and drawn as "dev/vda/".
trf :: proc(msgid: string, args: ..any) -> string {
	format := kit.tr(msgid)
	if !is_rtl() {
		return fmt.tprintf(format, ..args)
	}
	// The isolated copies live in their own slice: an `any` points at its
	// value, so each one needs storage that outlives the loop iteration.
	texts := make([]string, len(args), context.temp_allocator)
	wrapped := make([]any, len(args), context.temp_allocator)
	for a, i in args {
		if s, ok := a.(string); ok {
			// An argument that is itself a translation ("20.0 GiB" from
			// size_label) loses its mark, or the isolate would take the
			// mark's direction instead of its text's.
			texts[i] = fmt.tprintf("%s%s%s", FSI, strings.trim_prefix(s, RLM), PDI)
			wrapped[i] = texts[i]
		} else {
			wrapped[i] = a
		}
	}
	return mark(fmt.tprintf(format, ..wrapped), format)
}

// text_tr translates one of the core's messages (model.odin's Text): its
// msgid through the catalogue, then its arguments, isolated as trf does.
// The msgids are not literals here; the selftest finds them in the core's
// MESSAGE_FORMAT instead.
text_tr :: proc(t: Text) -> string {
	if t.msgid == "" {
		return ""
	}
	a: [len(t.args)]any
	for i in 0 ..< t.nargs {
		a[i] = t.args[i]
	}
	return trf(t.msgid, ..a[:t.nargs])
}

// mark prefixes the RIGHT-TO-LEFT MARK when the interface is right to left
// and the translation is written in a right-to-left script. A translation
// with no such letters ("%.1f GiB") is left alone: forced right to left it
// would come out as "GiB 20.0".
mark :: proc(text: string, decided_by := "") -> string {
	if !is_rtl() || !has_rtl_letters(decided_by == "" ? text : decided_by) {
		return text
	}
	return fmt.tprintf("%s%s", RLM, text)
}

has_rtl_letters :: proc(s: string) -> bool {
	for r in s {
		switch r {
		case 0x0590 ..= 0x08FF, 0xFB1D ..= 0xFDFF, 0xFE70 ..= 0xFEFF:
			return true
		}
	}
	return false
}

// i18n_start loads the catalogue for `lang` ("" = from the environment).
i18n_start :: proc(lang := "") {
	find_checkout_catalogues()
	kit.i18n_init(DOMAIN, lang)
}

// set_language switches the whole interface: the next frame is drawn from the
// new catalogue, and mirrored when the language is written right to left.
set_language :: proc(code: string) {
	find_checkout_catalogues()
	kit.i18n_init(DOMAIN, code)
}

is_rtl :: proc() -> bool {
	return kit.i18n_is_rtl()
}

// find_checkout_catalogues points kit at the repository's distro/locale when
// the installed root is absent and PALM_LOCALE_DIR is not set: the binary in
// distro/out/bin, or the current directory being the repository.
find_checkout_catalogues :: proc() {
	if os.get_env("PALM_LOCALE_DIR", context.temp_allocator) != "" || os.exists(kit.LOCALE_ROOT) {
		return
	}
	candidates := make([dynamic]string, context.temp_allocator)
	if len(os.args) > 0 {
		append(&candidates, fmt.tprintf("%s/../../locale", filepath.dir(os.args[0])))
	}
	append(&candidates, "distro/locale")
	for c in candidates {
		if os.exists(fmt.tprintf("%s/fr/%s.msg", c, DOMAIN)) {
			abs, _ := filepath.abs(c, context.temp_allocator)
			os.set_env("PALM_LOCALE_DIR", abs)
			return
		}
	}
}
