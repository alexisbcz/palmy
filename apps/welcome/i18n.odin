package main

// Translations, as the welcome app sees them: tr, trf, N, is_rtl.
//
// The same rule as the installer, whose pattern this is: every user-visible
// string goes through one of these with the msgid written as a literal right
// inside the call, because selftest.odin finds the msgids by scanning the
// source for `tr("`, `trf("` and `N("` and checks that every catalogue in
// distro/locale/*/welcome.msg has each of them.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import kit "kit:."

DOMAIN :: "welcome"

// N marks a string as a msgid without translating it, for tables that are
// translated where they are drawn (gettext's N_).
N :: proc "contextless" (msgid: string) -> string {
	return msgid
}

// A RIGHT-TO-LEFT MARK in front of an Arabic sentence that starts with
// "Palmy" or a %s keeps the paragraph right to left; isolates keep an
// address or a path in one piece inside it.
RLM :: "‏"
FSI :: "⁨"
PDI :: "⁩"

tr :: proc(msgid: string) -> string {
	return mark(kit.tr(msgid))
}

trf :: proc(msgid: string, args: ..any) -> string {
	format := kit.tr(msgid)
	if !is_rtl() {
		return fmt.tprintf(format, ..args)
	}
	texts := make([]string, len(args), context.temp_allocator)
	wrapped := make([]any, len(args), context.temp_allocator)
	for a, i in args {
		if s, ok := a.(string); ok {
			texts[i] = fmt.tprintf("%s%s%s", FSI, strings.trim_prefix(s, RLM), PDI)
			wrapped[i] = texts[i]
		} else {
			wrapped[i] = a
		}
	}
	return mark(fmt.tprintf(format, ..wrapped), format)
}

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

is_rtl :: proc() -> bool {
	return kit.i18n_is_rtl()
}

i18n_start :: proc(lang := "") {
	find_checkout_catalogues()
	kit.i18n_init(DOMAIN, lang)
}

set_language :: proc(code: string) {
	find_checkout_catalogues()
	kit.i18n_init(DOMAIN, code)
}

// find_checkout_catalogues points kit at the repository's distro/locale when
// the installed root is absent and PALM_LOCALE_DIR is not set, so the binary
// built into apps/welcome or distro/out/bin finds its catalogues.
find_checkout_catalogues :: proc() {
	if os.get_env("PALM_LOCALE_DIR", context.temp_allocator) != "" || os.exists(kit.LOCALE_ROOT) {
		return
	}
	candidates := make([dynamic]string, context.temp_allocator)
	if len(os.args) > 0 {
		dir := filepath.dir(os.args[0])
		append(&candidates, fmt.tprintf("%s/../../distro/locale", dir))
		append(&candidates, fmt.tprintf("%s/../../locale", dir))
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
