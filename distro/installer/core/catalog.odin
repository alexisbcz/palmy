package install_core

// The choices a person is offered — keyboard layouts, time zones, languages —
// read from the data the system already ships, never from a copy of our own
// that could drift from it:
//
//   keyboard   xkeyboard-config's rules/base.lst: the "! layout" section gives
//              `code  Description`, the "! variant" section
//              `variant  layout: Description`. The same file the wm's XKB
//              compiler resolves names against, so whatever is listed compiles.
//   time zone  tzdata's zone1970.tab (fallback zone.tab): one line per zone
//              with its country codes; iso3166.tab names the countries.
//   language   a fixed list of the languages the installer is translated
//              into, each available when its catalogue is installed under
//              /usr/share/palm/locale — and, for Japanese, when a CJK font is
//              installed too, because a language whose text renders as boxes
//              is not available, whatever the catalogue says.

import "core:os"
import "core:slice"
import "core:strings"

list_layouts :: proc(xkb_root := "/usr/share/X11/xkb") -> []Keyboard {
	data, err := os.read_entire_file_from_path(join(xkb_root, "rules/base.lst"), context.temp_allocator)
	if err != nil {
		return nil
	}
	layouts := make([dynamic]Keyboard, context.temp_allocator)
	variants := make(map[string][dynamic]Keyboard, context.temp_allocator)
	section := ""
	for raw in strings.split_lines(string(data), context.temp_allocator) {
		line := strings.trim_right_space(raw)
		if strings.has_prefix(line, "!") {
			section = strings.trim_space(line[1:])
			continue
		}
		code, rest, ok := split_first_field(line)
		if !ok {
			continue
		}
		switch section {
		case "layout":
			append(&layouts, Keyboard{layout = code, description = rest})
		case "variant":
			colon := strings.index_byte(rest, ':')
			if colon <= 0 {continue}
			layout := rest[:colon]
			desc := strings.trim_space(rest[colon + 1:])
			if layout not_in variants {
				variants[layout] = make([dynamic]Keyboard, context.temp_allocator)
			}
			append(&variants[layout], Keyboard{layout = layout, variant = code, description = desc})
		}
	}
	// Each layout followed by its variants, in base.lst's order (which is by
	// description), so a list reads "French", "French (AZERTY)", ...
	out := make([dynamic]Keyboard)
	for l in layouts {
		append(&out, Keyboard{layout = strings.clone(l.layout), description = strings.clone(l.description)})
		if vs, ok := variants[l.layout]; ok {
			for v in vs {
				append(&out, Keyboard{layout = strings.clone(v.layout), variant = strings.clone(v.variant), description = strings.clone(v.description)})
			}
		}
	}
	return out[:]
}

// split_first_field splits "  code    the rest" into ("code", "the rest").
@(private = "file")
split_first_field :: proc(line: string) -> (first, rest: string, ok: bool) {
	s := strings.trim_left_space(line)
	if s == "" || s[0] == '#' {
		return
	}
	i := strings.index_any(s, " \t")
	if i < 0 {
		return s, "", true
	}
	return s[:i], strings.trim_space(s[i:]), true
}

list_zones :: proc(zoneinfo := "/usr/share/zoneinfo") -> []Zone {
	countries := make(map[string]string, context.temp_allocator)
	if data, err := os.read_entire_file_from_path(join(zoneinfo, "iso3166.tab"), context.temp_allocator); err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) {
			if line == "" || line[0] == '#' {continue}
			f := strings.split_n(line, "\t", 2, context.temp_allocator)
			if len(f) == 2 {
				countries[f[0]] = strings.trim_space(f[1])
			}
		}
	}
	data, err := os.read_entire_file_from_path(join(zoneinfo, "zone1970.tab"), context.temp_allocator)
	if err != nil {
		data, err = os.read_entire_file_from_path(join(zoneinfo, "zone.tab"), context.temp_allocator)
		if err != nil {
			return nil
		}
	}
	out := make([dynamic]Zone)
	seen := make(map[string]bool, context.temp_allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if line == "" || line[0] == '#' {continue}
		// codes <TAB> coordinates <TAB> TZ [<TAB> comments]; zone.tab has a
		// single code in the first column, zone1970.tab a comma list.
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 {continue}
		name := strings.trim_space(f[2])
		if name == "" || seen[name] {continue}
		seen[name] = true
		code := f[0]
		if i := strings.index_byte(code, ','); i >= 0 {
			code = code[:i]
		}
		append(&out, make_zone(name, countries[code] or_else code))
	}
	// The one zone nobody lives in but many want.
	if !seen["UTC"] {
		append(&out, Zone{name = strings.clone("UTC"), region = "", city = strings.clone("UTC"), country = ""})
	}
	slice.sort_by(out[:], proc(a, b: Zone) -> bool {return a.name < b.name})
	return out[:]
}

@(private = "file")
make_zone :: proc(name, country: string) -> Zone {
	z := Zone{name = strings.clone(name), country = strings.clone(country)}
	if i := strings.index_byte(name, '/'); i >= 0 {
		z.region = strings.clone(name[:i])
		city, _ := strings.replace_all(name[i + 1:], "_", " ")
		z.city = strings.clone(city)
	} else {
		z.city = strings.clone(name)
	}
	return z
}

// The languages the installer is translated into, in the order it offers them.
@(private = "file")
LANGUAGES := [?]Language {
	{code = "en_US", native_name = "English", english_name = "English"},
	{code = "fr_FR", native_name = "Français", english_name = "French"},
	{code = "de_DE", native_name = "Deutsch", english_name = "German"},
	{code = "es_ES", native_name = "Español", english_name = "Spanish"},
	{code = "ar", native_name = "العربية", english_name = "Arabic", rtl = true},
	{code = "ja_JP", native_name = "日本語", english_name = "Japanese"},
}

list_languages :: proc(locale_root := "/usr/share/palm/locale") -> []Language {
	out := make([dynamic]Language)
	// Fonts live beside the catalogues: <prefix>/share/palm/locale ->
	// <prefix>/share/fonts. Deriving it keeps the procedure testable against
	// a scratch tree, and is exactly /usr/share/fonts on the system.
	fonts := "/usr/share/fonts"
	if strings.has_suffix(locale_root, "/palm/locale") {
		fonts = join(locale_root[:len(locale_root) - len("/palm/locale")], "fonts")
	}
	have_cjk := false
	cjk_checked := false
	for l in LANGUAGES {
		lang := l
		lang.available = l.code == "en_US" || has_catalogue(locale_root, l.code)
		if lang.available && strings.has_prefix(l.code, "ja") {
			if !cjk_checked {
				have_cjk = has_font_matching(fonts, {"cjk", "jp", "japanese", "gothic", "mincho"})
				cjk_checked = true
			}
			lang.available = have_cjk
		}
		append(&out, lang)
	}
	// Any other catalogue someone installed is offered too, by its code.
	if entries, err := os.read_all_directory_by_path(locale_root, context.temp_allocator); err == nil {
		for fi in entries {
			if fi.type != .Directory {continue}
			known := false
			for l in LANGUAGES {
				if l.code == fi.name || lang_prefix(l.code) == fi.name {known = true}
			}
			if !known {
				code := strings.clone(fi.name)
				append(&out, Language{code = code, native_name = code, english_name = code, available = true})
			}
		}
	}
	return out[:]
}

@(private = "file")
lang_prefix :: proc(code: string) -> string {
	if i := strings.index_byte(code, '_'); i >= 0 {
		return code[:i]
	}
	return code
}

// A catalogue counts when <root>/<code>/ or <root>/<lang>/ holds a .msg file,
// matching kit.i18n's fallback fr_FR -> fr.
@(private = "file")
has_catalogue :: proc(root, code: string) -> bool {
	for d in ([]string{code, lang_prefix(code)}) {
		entries, err := os.read_all_directory_by_path(join(root, d), context.temp_allocator)
		if err != nil {continue}
		for fi in entries {
			if strings.has_suffix(fi.name, ".msg") {
				return true
			}
		}
	}
	return false
}

@(private = "file")
has_font_matching :: proc(dir: string, needles: []string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return false
	}
	for fi in entries {
		if fi.type == .Directory {
			if has_font_matching(join(dir, fi.name), needles) {return true}
			continue
		}
		lower := strings.to_lower(fi.name, context.temp_allocator)
		if !(strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf") || strings.has_suffix(lower, ".ttc") || strings.has_suffix(lower, ".otc")) {
			continue
		}
		for n in needles {
			if strings.contains(lower, n) {return true}
		}
	}
	return false
}
