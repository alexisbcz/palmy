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
// The catalogues belong to kit's i18n library (apps/kit/i18n.odin), which owns
// the format, the search path and the language fallback. Until that library
// lands, the loader below reads the same `.msg` format (INSTALLER.md, "i18n
// library") itself; the five procedures are the seam, so swapping it for kit
// is a change to this file only.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The domain: catalogues are <root>/<lang>/installer.msg.
DOMAIN :: "installer"

// N marks a string as a msgid without translating it, for tables and return
// values that are translated where they are drawn (gettext's N_).
N :: proc(msgid: string) -> string {
	return msgid
}

tr :: proc(msgid: string) -> string {
	if s, ok := cat.strings[msgid]; ok && s != "" {
		return s
	}
	return msgid
}

trf :: proc(msgid: string, args: ..any) -> string {
	return fmt.tprintf(tr(msgid), ..args)
}

// i18n_start loads the catalogue for `lang` ("" = from the environment).
i18n_start :: proc(lang := "") {
	l := lang
	if l == "" {
		for v in ([?]string{"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}) {
			if e := os.get_env(v, context.temp_allocator); e != "" {
				l = e
				break
			}
		}
	}
	set_language(l)
}

// set_language switches the whole interface: the next frame is drawn from the
// new catalogue, and mirrored when the language is written right to left.
set_language :: proc(code: string) {
	clear(&cat.strings)
	cat.lang = strings.clone(code)
	cat.rtl = false
	// fr_FR.UTF-8 -> fr_FR -> fr, the fallback order INSTALLER.md gives.
	base := code
	if i := strings.index_any(base, ".@"); i >= 0 {
		base = base[:i]
	}
	short := base
	if i := strings.index_byte(short, '_'); i >= 0 {
		short = short[:i]
	}
	cat.rtl = short == "ar" || short == "he" || short == "fa" || short == "ur"
	if short == "" || short == "C" || short == "POSIX" || short == "en" {
		return
	}
	for root in locale_roots() {
		for l in ([?]string{base, short}) {
			path := fmt.tprintf("%s/%s/%s.msg", root, l, DOMAIN)
			if data, err := os.read_entire_file(path, context.allocator); err == nil {
				catalogue_parse(string(data), &cat.strings)
				return
			}
		}
	}
}

is_rtl :: proc() -> bool {
	return cat.rtl
}

@(private = "file")
Catalogue :: struct {
	lang:    string,
	rtl:     bool,
	strings: map[string]string,
}

@(private = "file")
cat: Catalogue

// locale_roots: the installed path, an override for development, and the
// checkout's distro/locale found relative to the binary (distro/out/bin).
@(private = "file")
locale_roots :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if e := os.get_env("PALM_LOCALE_DIR", context.temp_allocator); e != "" {
		append(&out, e)
	}
	append(&out, "/usr/share/palm/locale")
	if len(os.args) > 0 {
		dir := filepath.dir(os.args[0], context.temp_allocator)
		append(&out, fmt.tprintf("%s/../../locale", dir))
	}
	append(&out, "distro/locale")
	return out[:]
}

// catalogue_parse reads the gettext-like `.msg` format. Plural entries keep
// their singular form only; the installer has no plural strings.
catalogue_parse :: proc(text: string, into: ^map[string]string) {
	id := ""
	have_id := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		switch {
		case strings.has_prefix(l, "msgid_plural "):
		// ignored: see above
		case strings.has_prefix(l, "msgid "):
			id = unquote(l[len("msgid "):])
			have_id = true
		case strings.has_prefix(l, "msgstr[0] "), strings.has_prefix(l, "msgstr "):
			if have_id {
				v := unquote(l[strings.index_byte(l, ' ') + 1:])
				into[id] = v
				have_id = false
			}
		}
	}
}

// unquote strips the quotes and resolves \" \\ \n \t.
unquote :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if len(t) < 2 || t[0] != '"' || t[len(t) - 1] != '"' {
		return strings.clone(t)
	}
	t = t[1:len(t) - 1]
	sb := strings.builder_make()
	for i := 0; i < len(t); i += 1 {
		c := t[i]
		if c == '\\' && i + 1 < len(t) {
			i += 1
			switch t[i] {
			case 'n':
				strings.write_byte(&sb, '\n')
			case 't':
				strings.write_byte(&sb, '\t')
			case:
				strings.write_byte(&sb, t[i])
			}
			continue
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}
