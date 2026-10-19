// Translations for the palmy applications: a message catalogue per language
// and per program, looked up by the English string itself.
//
//	kit.i18n_init("greeter")            // once, at start; language from the environment
//	p.text(ui, kit.tr("Sign in"), ...)  // the translation, or "Sign in" again
//	kit.trf("no greetd on %s", sock)    // translate the format, then format
//	fmt.tprintf(kit.trn("%d account", "%d accounts", n), n)
//	kit.i18n_set_language("fr_FR")      // switch live (the installer's first page)
//	kit.i18n_is_rtl()                   // lay the screen out right to left
//
// The English text is the key, as with gettext, so a program with no
// catalogue at all — or a msgid nobody has translated yet — still shows real
// words rather than identifiers. Nothing here can fail loudly: a missing or
// broken catalogue means English, with one line on stderr for the broken one.
//
// Catalogues live in <root>/<lang>/<domain>.msg, where <root> is
// /usr/share/palm/locale on Palmy and PALM_LOCALE_DIR overrides it (the
// repository's distro/locale for tests and for running an app from the
// checkout). The format is gettext's .po with everything that needs a tool
// taken out; distro/locale/README.md describes it for translators:
//
//	# comment
//	plural = n > 1                      header lines: key = value, unquoted
//
//	msgid "Install Palmy"
//	msgstr "Installer Palmy"
//
//	msgid "%d package"
//	msgid_plural "%d packages"
//	msgstr[0] "%d paquet"
//	msgstr[1] "%d paquets"
//
// Which language: the explicit one given to i18n_init/i18n_set_language, or
// else the environment in the order the contract (distro/INSTALLER.md) and
// gettext agree on — LANGUAGE (a colon-separated list), then the first set of
// LC_ALL, LC_MESSAGES, LANG. Each name is tried from the most specific to the
// least, so fr_FR.UTF-8@euro looks in fr_FR.UTF-8@euro, fr_FR.UTF-8,
// fr_FR@euro, fr_FR and fr, and every catalogue found along the way is kept:
// a string fr_FR does not translate is looked up in fr before falling back to
// the msgid. "C" and "POSIX" mean the msgids themselves and stop the search.
//
// The state is one global per process, set up before the first frame and
// read from the UI thread. Nothing here locks: switching language from a
// worker thread while the UI thread draws is not supported.
package kit

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

LOCALE_ROOT :: "/usr/share/palm/locale"

// Catalog is one parsed .msg file.
Catalog :: struct {
	lang:   string, // the directory it came from: "fr", "fr_FR", ...
	path:   string,
	header: map[string]string, // plural, name, english, direction, ...
	plural: string, // the plural expression, already checked to evaluate
	msgs:   map[string][]string, // msgid -> forms; [0] alone for a plain string
}

@(private = "file")
I18n_State :: struct {
	domain:   string,
	explicit: string, // the language asked for by name, "" = environment
	chain:    [dynamic]Catalog, // most specific first
	tried:    [dynamic]string, // the language names searched, in order
}

@(private = "file")
i18n: I18n_State

// i18n_root is where catalogues are read from.
i18n_root :: proc() -> string {
	if dir := os.get_env("PALM_LOCALE_DIR", context.temp_allocator); dir != "" {
		return dir
	}
	return LOCALE_ROOT
}

// i18n_init loads `domain`'s catalogues for `lang`, or for the language the
// environment names when `lang` is "". Calling it again replaces everything.
i18n_init :: proc(domain: string, lang := "") {
	i18n_reset()
	i18n.domain = strings.clone(domain)
	i18n.explicit = strings.clone(lang)
	i18n_load()
}

// i18n_set_language switches the running program to another language at
// once; the next frame draws in it. "" goes back to the environment's.
i18n_set_language :: proc(lang: string) {
	domain := strings.clone(i18n.domain, context.temp_allocator)
	i18n_init(domain, lang)
}

// i18n_shutdown drops every catalogue; tr returns msgids afterwards.
i18n_shutdown :: proc() {
	i18n_reset()
}

// i18n_language is the language being shown: the directory name of the most
// specific catalogue in use ("fr", "pt_BR"), or "en" when the msgids are.
i18n_language :: proc() -> string {
	if len(i18n.chain) > 0 {
		return i18n.chain[0].lang
	}
	return "en"
}

// i18n_is_rtl reports whether the language being shown is written right to
// left, so a screen can mirror its layout. A catalogue may say so itself with
// `direction = rtl` (or `ltr`); otherwise Arabic, Hebrew, Persian and Urdu
// are. It is false when no catalogue was found: English is then on screen,
// whatever was asked for.
i18n_is_rtl :: proc() -> bool {
	if len(i18n.chain) == 0 {
		return false
	}
	c := &i18n.chain[0]
	if d, ok := c.header["direction"]; ok {
		return d == "rtl"
	}
	return lang_is_rtl(c.lang)
}

// lang_is_rtl answers for a language name alone, with no catalogue: the
// installer's language list uses it to mark the ones it cannot preview.
lang_is_rtl :: proc(lang: string) -> bool {
	switch lang_base(lang) {
	case "ar", "he", "fa", "ur", "yi", "ps", "sd", "ug", "dv", "ckb":
		return true
	}
	return false
}

// tr returns the translation of msgid, or msgid itself. The result belongs to
// the catalogue and stays valid until the language changes; copy it to keep
// it across an i18n_set_language.
tr :: proc(msgid: string) -> string {
	for &c in i18n.chain {
		if forms, ok := c.msgs[msgid]; ok && len(forms) > 0 && forms[0] != "" {
			return forms[0]
		}
	}
	return msgid
}

// trf translates the format, then formats with it, so a translator can move
// the arguments around: Odin's explicit indices are zero-based, `%[1]d %[0]s`.
// The result is in the temp allocator, which palmy clears every frame.
trf :: proc(msgid: string, args: ..any) -> string {
	return fmt.tprintf(tr(msgid), ..args)
}

// trn picks the singular or one of the plural forms for n, by the plural rule
// of the catalogue the translation came from. Untranslated, it is English's
// rule: singular for exactly 1.
trn :: proc(singular, plural: string, n: int) -> string {
	for &c in i18n.chain {
		forms, ok := c.msgs[singular]
		if !ok || len(forms) == 0 {
			continue
		}
		idx, _ := plural_eval(c.plural, n)
		if idx >= 0 && idx < len(forms) && forms[idx] != "" {
			return forms[idx]
		}
		// A catalogue with fewer forms than its rule asks for: the last one
		// it has is a better guess than English.
		if forms[len(forms) - 1] != "" {
			return forms[len(forms) - 1]
		}
	}
	return n == 1 ? singular : plural
}

// trnf is trn, then formatted with the given arguments (temp allocator).
//
//	kit.trnf("%d account", "%d accounts", n, n)
trnf :: proc(singular, plural: string, n: int, args: ..any) -> string {
	return fmt.tprintf(trn(singular, plural, n), ..args)
}

// i18n_candidates expands one locale name into the directories to try, most
// specific first: fr_FR.UTF-8@euro -> fr_FR.UTF-8@euro, fr_FR.UTF-8,
// fr_FR@euro, fr_FR, fr.
i18n_candidates :: proc(name: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	add :: proc(out: ^[dynamic]string, s: string, allocator: runtime.Allocator) {
		if s == "" {
			return
		}
		for have in out {
			if have == s {
				return
			}
		}
		append(out, strings.clone(s, allocator))
	}
	n := strings.trim_space(name)
	modifier := ""
	if at := strings.index_byte(n, '@'); at >= 0 {
		modifier = n[at:]
		n = n[:at]
	}
	codeset := ""
	if dot := strings.index_byte(n, '.'); dot >= 0 {
		codeset = n[dot:]
		n = n[:dot]
	}
	base := n
	if us := strings.index_byte(n, '_'); us >= 0 {
		base = n[:us]
	}
	add(&out, strings.concatenate({n, codeset, modifier}, context.temp_allocator), allocator)
	add(&out, strings.concatenate({n, codeset}, context.temp_allocator), allocator)
	add(&out, strings.concatenate({n, modifier}, context.temp_allocator), allocator)
	add(&out, n, allocator)
	add(&out, base, allocator)
	return out[:]
}

// i18n_env_languages is what the environment asks for, in order.
i18n_env_languages :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	if l := os.get_env("LANGUAGE", context.temp_allocator); l != "" {
		for part in strings.split(l, ":", context.temp_allocator) {
			if p := strings.trim_space(part); p != "" {
				append(&out, strings.clone(p, allocator))
			}
		}
	}
	for key in ([?]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		if v := os.get_env(key, context.temp_allocator); v != "" {
			append(&out, strings.clone(v, allocator))
			break
		}
	}
	return out[:]
}

// i18n_parse reads the text of a .msg file. `err` names the first line it
// could not make sense of; everything before it is still returned.
i18n_parse :: proc(text: string, allocator := context.allocator) -> (c: Catalog, err: string) {
	context.allocator = allocator
	c.header = make(map[string]string)
	c.msgs = make(map[string][]string)

	Field :: enum {
		None,
		Id,
		Plural,
		Str,
	}
	msgid, msgid_plural: strings.Builder
	strings.builder_init(&msgid, context.temp_allocator)
	strings.builder_init(&msgid_plural, context.temp_allocator)
	forms := make([dynamic]strings.Builder, context.temp_allocator)
	have_id := false
	last := Field.None
	last_form := 0

	commit :: proc(c: ^Catalog, have_id: ^bool, msgid: ^strings.Builder, forms: ^[dynamic]strings.Builder) {
		defer {
			have_id^ = false
			strings.builder_reset(msgid)
			clear(forms)
		}
		if !have_id^ || strings.builder_len(msgid^) == 0 || len(forms) == 0 {
			return
		}
		// An empty msgstr is "not translated yet", as in gettext: leave it
		// out so the lookup falls through to the next catalogue or the msgid.
		if strings.builder_len(forms[0]) == 0 {
			return
		}
		out := make([]string, len(forms))
		for &f, i in forms {
			out[i] = strings.clone(strings.to_string(f))
		}
		key := strings.clone(strings.to_string(msgid^))
		if old, dup := c.msgs[key]; dup {
			// The later entry wins, as msgfmt would complain and then do.
			for s in old {delete(s)}
			delete(old)
		}
		c.msgs[key] = out
	}

	lineno := 0
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		lineno += 1
		line := strings.trim_space(raw)
		if lineno == 1 {
			line = strings.trim_prefix(line, "\xef\xbb\xbf")
		}
		if line == "" || line[0] == '#' {
			continue
		}

		// A bare "..." continues whichever string came last.
		if line[0] == '"' {
			s, ok := unquote(line)
			if !ok {
				return c, fmt.aprintf("line %d: bad string", lineno)
			}
			switch last {
			case .Id:
				strings.write_string(&msgid, s)
			case .Plural:
				strings.write_string(&msgid_plural, s)
			case .Str:
				strings.write_string(&forms[last_form], s)
			case .None:
				return c, fmt.aprintf("line %d: a string with nothing to continue", lineno)
			}
			continue
		}

		sp := strings.index_any(line, " \t")
		keyword := sp < 0 ? line : line[:sp]
		value := sp < 0 ? "" : strings.trim_space(line[sp:])

		switch {
		case keyword == "msgid":
			commit(&c, &have_id, &msgid, &forms)
			strings.builder_reset(&msgid_plural)
			s, ok := unquote(value)
			if !ok {
				return c, fmt.aprintf("line %d: msgid needs a quoted string", lineno)
			}
			strings.write_string(&msgid, s)
			have_id = true
			last = .Id
		case keyword == "msgid_plural":
			s, ok := unquote(value)
			if !ok || !have_id {
				return c, fmt.aprintf("line %d: msgid_plural without a msgid", lineno)
			}
			strings.write_string(&msgid_plural, s)
			last = .Plural
		case keyword == "msgstr" || strings.has_prefix(keyword, "msgstr["):
			if !have_id {
				return c, fmt.aprintf("line %d: msgstr without a msgid", lineno)
			}
			idx := 0
			if keyword != "msgstr" {
				close := strings.index_byte(keyword, ']')
				n, nok := strconv.parse_int(keyword[len("msgstr["):max(close, len("msgstr["))])
				if close < 0 || !nok || n < 0 || n > 15 {
					return c, fmt.aprintf("line %d: bad plural index %q", lineno, keyword)
				}
				idx = n
			}
			s, ok := unquote(value)
			if !ok {
				return c, fmt.aprintf("line %d: msgstr needs a quoted string", lineno)
			}
			for len(forms) <= idx {
				b: strings.Builder
				strings.builder_init(&b, context.temp_allocator)
				append(&forms, b)
			}
			strings.write_string(&forms[idx], s)
			last = .Str
			last_form = idx
		case:
			// A header line: key = value. Only lower-case words are keys, so
			// a stray line of text is an error instead of a silent header.
			eq := strings.index_byte(line, '=')
			if eq <= 0 {
				return c, fmt.aprintf("line %d: expected msgid, msgstr or key = value", lineno)
			}
			key := strings.trim_space(line[:eq])
			for ch in key {
				if !(ch >= 'a' && ch <= 'z' || ch == '_' || ch == '-') {
					return c, fmt.aprintf("line %d: %q is not a header key", lineno, key)
				}
			}
			commit(&c, &have_id, &msgid, &forms)
			last = .None
			c.header[strings.clone(key)] = strings.clone(strings.trim_space(line[eq + 1:]))
		}
	}
	commit(&c, &have_id, &msgid, &forms)

	c.plural = "n != 1"
	if expr, ok := c.header["plural"]; ok {
		if _, valid := plural_eval(expr, 1); valid {
			c.plural = expr
		} else {
			err = fmt.aprintf("plural: cannot evaluate %q; using n != 1", expr)
		}
	}
	return c, err
}

// i18n_load_file parses one catalogue from disk.
i18n_load_file :: proc(path: string, lang: string, allocator := context.allocator) -> (c: Catalog, ok: bool) {
	data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return {}, false
	}
	err: string
	c, err = i18n_parse(string(data), allocator)
	if err != "" {
		fmt.eprintfln("i18n: %s: %s", path, err)
	}
	c.lang = strings.clone(lang, allocator)
	c.path = strings.clone(path, allocator)
	return c, true
}

i18n_catalog_destroy :: proc(c: ^Catalog) {
	for k, v in c.header {
		delete(k)
		delete(v)
	}
	delete(c.header)
	for k, v in c.msgs {
		delete(k)
		for s in v {delete(s)}
		delete(v)
	}
	delete(c.msgs)
	delete(c.lang)
	delete(c.path)
	c^ = {}
}

// i18n_lookup is tr against one catalogue, for code that holds its own (a
// language list that shows each language's own name, say).
i18n_lookup :: proc(c: ^Catalog, msgid: string) -> (string, bool) {
	if forms, ok := c.msgs[msgid]; ok && len(forms) > 0 && forms[0] != "" {
		return forms[0], true
	}
	return msgid, false
}

@(private = "file")
i18n_reset :: proc() {
	for &c in i18n.chain {
		i18n_catalog_destroy(&c)
	}
	delete(i18n.chain)
	for s in i18n.tried {delete(s)}
	delete(i18n.tried)
	delete(i18n.domain)
	delete(i18n.explicit)
	i18n = {}
}

@(private = "file")
i18n_load :: proc() {
	i18n.chain = make([dynamic]Catalog)
	i18n.tried = make([dynamic]string)
	names: []string
	if i18n.explicit != "" {
		names = {i18n.explicit}
	} else {
		names = i18n_env_languages()
	}
	already_tried :: proc(s: string) -> bool {
		for t in i18n.tried {
			if t == s {return true}
		}
		return false
	}

	root := i18n_root()
	outer: for name in names {
		if name == "C" || name == "POSIX" || strings.has_prefix(name, "C.") {
			break outer
		}
		for cand in i18n_candidates(name, context.temp_allocator) {
			if already_tried(cand) {
				continue
			}
			append(&i18n.tried, strings.clone(cand))
			path := fmt.tprintf("%s/%s/%s.msg", root, cand, i18n.domain)
			if c, ok := i18n_load_file(path, cand); ok {
				append(&i18n.chain, c)
			}
		}
	}
}

@(private = "file")
lang_base :: proc(lang: string) -> string {
	end := len(lang)
	for ch, i in lang {
		if ch == '_' || ch == '.' || ch == '@' || ch == '-' {
			end = i
			break
		}
	}
	return lang[:end]
}

// unquote reads one C-style string literal: "..." with \" \\ \n \t escapes.
// The result is in the temp allocator.
@(private = "file")
unquote :: proc(s: string) -> (string, bool) {
	t := strings.trim_space(s)
	if len(t) < 2 || t[0] != '"' || t[len(t) - 1] != '"' {
		return "", false
	}
	t = t[1:len(t) - 1]
	if strings.index_byte(t, '\\') < 0 {
		return t, strings.index_byte(t, '"') < 0
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(t); i += 1 {
		ch := t[i]
		if ch == '"' {
			return "", false
		}
		if ch != '\\' {
			strings.write_byte(&b, ch)
			continue
		}
		i += 1
		if i >= len(t) {
			return "", false
		}
		switch t[i] {
		case 'n':
			strings.write_byte(&b, '\n')
		case 't':
			strings.write_byte(&b, '\t')
		case '"', '\\':
			strings.write_byte(&b, t[i])
		case:
			return "", false
		}
	}
	return strings.to_string(b), true
}

// ---------------------------------------------------------------------------
// Plural rules
//
// The header's `plural =` is gettext's C expression in n: `n != 1`,
// `n > 1`, `0`, or Arabic's whole six-way rule, nested ?: and all. The value
// is the index of the msgstr[] to use; a comparison is 0 or 1. It is parsed
// and evaluated in one recursive-descent pass every time it is needed — the
// expressions are a few dozen bytes and only trn calls this.
// ---------------------------------------------------------------------------

@(private = "file")
Plural_Parser :: struct {
	s:  string,
	i:  int,
	n:  int,
	ok: bool,
}

// plural_eval evaluates `expr` for n. ok is false for anything it cannot
// parse, so a catalogue's rule is checked once at load.
plural_eval :: proc(expr: string, n: int) -> (value: int, ok: bool) {
	p := Plural_Parser{s = expr, n = n, ok = true}
	v := pe_ternary(&p)
	pe_space(&p)
	if p.i != len(p.s) {
		p.ok = false
	}
	return p.ok ? v : (n == 1 ? 0 : 1), p.ok
}

@(private = "file")
pe_space :: proc(p: ^Plural_Parser) {
	for p.i < len(p.s) && (p.s[p.i] == ' ' || p.s[p.i] == '\t' || p.s[p.i] == ';') {
		p.i += 1
	}
}

@(private = "file")
pe_eat :: proc(p: ^Plural_Parser, tok: string) -> bool {
	pe_space(p)
	if strings.has_prefix(p.s[p.i:], tok) {
		// `<` must not swallow the first half of `<=`, nor `!` of `!=`.
		if (tok == "<" || tok == ">" || tok == "!" || tok == "=") && p.i + 1 < len(p.s) && p.s[p.i + 1] == '=' {
			return false
		}
		p.i += len(tok)
		return true
	}
	return false
}

@(private = "file")
pe_ternary :: proc(p: ^Plural_Parser) -> int {
	cond := pe_or(p)
	if pe_eat(p, "?") {
		a := pe_ternary(p)
		if !pe_eat(p, ":") {
			p.ok = false
			return 0
		}
		b := pe_ternary(p)
		return cond != 0 ? a : b
	}
	return cond
}

@(private = "file")
pe_or :: proc(p: ^Plural_Parser) -> int {
	v := pe_and(p)
	for pe_eat(p, "||") {
		r := pe_and(p)
		v = int(v != 0 || r != 0)
	}
	return v
}

@(private = "file")
pe_and :: proc(p: ^Plural_Parser) -> int {
	v := pe_eq(p)
	for pe_eat(p, "&&") {
		r := pe_eq(p)
		v = int(v != 0 && r != 0)
	}
	return v
}

@(private = "file")
pe_eq :: proc(p: ^Plural_Parser) -> int {
	v := pe_rel(p)
	for {
		if pe_eat(p, "==") {
			v = int(v == pe_rel(p))
		} else if pe_eat(p, "!=") {
			v = int(v != pe_rel(p))
		} else {
			return v
		}
	}
}

@(private = "file")
pe_rel :: proc(p: ^Plural_Parser) -> int {
	v := pe_add(p)
	for {
		if pe_eat(p, "<=") {
			v = int(v <= pe_add(p))
		} else if pe_eat(p, ">=") {
			v = int(v >= pe_add(p))
		} else if pe_eat(p, "<") {
			v = int(v < pe_add(p))
		} else if pe_eat(p, ">") {
			v = int(v > pe_add(p))
		} else {
			return v
		}
	}
}

@(private = "file")
pe_add :: proc(p: ^Plural_Parser) -> int {
	v := pe_mul(p)
	for {
		if pe_eat(p, "+") {
			v += pe_mul(p)
		} else if pe_eat(p, "-") {
			v -= pe_mul(p)
		} else {
			return v
		}
	}
}

@(private = "file")
pe_mul :: proc(p: ^Plural_Parser) -> int {
	v := pe_unary(p)
	for {
		if pe_eat(p, "*") {
			v *= pe_unary(p)
		} else if pe_eat(p, "/") || pe_eat(p, "%") {
			op := p.s[p.i - 1]
			r := pe_unary(p)
			if r == 0 {
				p.ok = false
				return 0
			}
			v = op == '/' ? v / r : v % r
		} else {
			return v
		}
	}
}

@(private = "file")
pe_unary :: proc(p: ^Plural_Parser) -> int {
	if pe_eat(p, "!") {
		return int(pe_unary(p) == 0)
	}
	pe_space(p)
	if p.i >= len(p.s) {
		p.ok = false
		return 0
	}
	ch := p.s[p.i]
	switch {
	case ch == 'n':
		p.i += 1
		return p.n
	case ch >= '0' && ch <= '9':
		start := p.i
		for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
			p.i += 1
		}
		v, _ := strconv.parse_int(p.s[start:p.i])
		return v
	case ch == '(':
		p.i += 1
		v := pe_ternary(p)
		if !pe_eat(p, ")") {
			p.ok = false
		}
		return v
	}
	p.ok = false
	return 0
}
