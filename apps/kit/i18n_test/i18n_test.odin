// Tests for kit's translations (apps/kit/i18n.odin), and a lint of every
// catalogue in distro/locale.
//
//	odin test apps/kit/i18n_test -collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn
//
// kit has no test binary of its own and its package needs palmy and shadcn,
// which `odin test tests` (the toolkit's suite, run without collections)
// cannot import; so these live beside kit, in their own package, run with
// the same collections the applications are built with.
//
// The catalogue lint is what keeps a translator's slip from reaching a
// screen: a catalogue that does not parse, a plural rule that does not
// evaluate, a plural entry with fewer forms than its rule picks from, or a
// translation whose % verbs differ from its msgid's (Odin's fmt would print
// %!(EXTRA ...) or %!(MISSING ...) on the login screen).
package kit_i18n_test

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import kit "kit:."

LOCALE_DIR :: #directory + "/../../../distro/locale"

@(test)
plural_rules :: proc(t: ^testing.T) {
	Case :: struct {
		expr: string,
		n:    int,
		want: int,
	}
	ARABIC :: "n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5"
	cases := [?]Case {
		{"n != 1", 1, 0},
		{"n != 1", 0, 1},
		{"n != 1", 2, 1},
		{"n > 1", 0, 0},
		{"n > 1", 1, 0},
		{"n > 1", 2, 1},
		{"0", 1, 0},
		{"0", 7, 0},
		{"(n != 1)", 5, 1},
		{"(n > 1);", 5, 1}, // gettext headers end the expression with ';'
		{ARABIC, 0, 0},
		{ARABIC, 1, 1},
		{ARABIC, 2, 2},
		{ARABIC, 3, 3},
		{ARABIC, 10, 3},
		{ARABIC, 11, 4},
		{ARABIC, 99, 4},
		{ARABIC, 100, 5},
		{ARABIC, 102, 5},
		{ARABIC, 103, 3},
		// Russian, for the nesting and && || precedence.
		{"n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2", 21, 0},
		{"n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2", 22, 1},
		{"n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2", 12, 2},
		{"!(n == 1)", 1, 0},
	}
	for c in cases {
		got, ok := kit.plural_eval(c.expr, c.n)
		testing.expectf(t, ok && got == c.want, "plural %q n=%d: got %d ok=%v, want %d", c.expr, c.n, got, ok, c.want)
	}
	for bad in ([?]string{"", "n >", "n ? 1", "(n", "x == 1", "n % 0", "n != 1 1"}) {
		_, ok := kit.plural_eval(bad, 3)
		testing.expectf(t, !ok, "plural %q should not parse", bad)
	}
}

@(test)
parse_format :: proc(t: ^testing.T) {
	c, err := kit.i18n_parse(`# a comment
plural = n > 1
name = Français

msgid "Install Palmframe"
msgstr "Installer Palmframe"

msgid "%d package"
msgid_plural "%d packages"
msgstr[0] "%d paquet"
msgstr[1] "%d paquets"

# continuation lines and escapes
msgid ""
"Two "
"lines"
msgstr "Deux\n"
"lignes \"citées\" \\ ok"

msgid "Untranslated"
msgstr ""

msgid "a = b"
msgstr "a = b, mais en français"
`)
	defer kit.i18n_catalog_destroy(&c)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.plural, "n > 1")
	testing.expect_value(t, c.header["name"], "Français")
	s, ok := kit.i18n_lookup(&c, "Install Palmframe")
	testing.expect(t, ok && s == "Installer Palmframe")
	forms := c.msgs["%d package"]
	testing.expect(t, len(forms) == 2 && forms[0] == "%d paquet" && forms[1] == "%d paquets")
	s, ok = kit.i18n_lookup(&c, "Two lines")
	testing.expectf(t, ok && s == "Deux\nlignes \"citées\" \\ ok", "continuation: %q", s)
	_, ok = kit.i18n_lookup(&c, "Untranslated")
	testing.expect(t, !ok, "an empty msgstr is not a translation")
	s, ok = kit.i18n_lookup(&c, "a = b")
	testing.expect(t, ok && s == "a = b, mais en français", "'=' inside text is text")

	for bad in ([?]string{
		"msgstr \"orphan\"\n",
		"msgid \"x\"\nmsgstr unquoted\n",
		"msgid \"x\"\nmsgstr[x] \"y\"\n",
		"Just some words\n",
		"msgid \"bad \\q escape\"\n",
	}) {
		cb, e := kit.i18n_parse(bad)
		testing.expectf(t, e != "", "should be refused: %q", bad)
		kit.i18n_catalog_destroy(&cb)
		delete(e)
	}
	cp, e := kit.i18n_parse("plural = n >\nmsgid \"a\"\nmsgstr \"b\"\n")
	testing.expect(t, strings.contains(e, "plural") && cp.plural == "n != 1", "a broken plural rule falls back to n != 1")
	kit.i18n_catalog_destroy(&cp)
	delete(e)
}

@(test)
candidates :: proc(t: ^testing.T) {
	got := kit.i18n_candidates("fr_FR.UTF-8@euro", context.temp_allocator)
	want := []string{"fr_FR.UTF-8@euro", "fr_FR.UTF-8", "fr_FR@euro", "fr_FR", "fr"}
	testing.expectf(t, slice.equal(got, want), "got %v", got)
	got = kit.i18n_candidates("fr_FR.UTF-8", context.temp_allocator)
	testing.expectf(t, slice.equal(got, []string{"fr_FR.UTF-8", "fr_FR", "fr"}), "got %v", got)
	got = kit.i18n_candidates("ja", context.temp_allocator)
	testing.expectf(t, slice.equal(got, []string{"ja"}), "got %v", got)
	testing.expect(t, kit.lang_is_rtl("ar_EG.UTF-8") && kit.lang_is_rtl("he") && kit.lang_is_rtl("fa_IR") && kit.lang_is_rtl("ur"))
	testing.expect(t, !kit.lang_is_rtl("fr_FR") && !kit.lang_is_rtl("arn"))
}

// The global state and the environment, in one test so nothing races.
@(test)
fallback_chain :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/kit-i18n-test-%d", os.get_pid())
	write :: proc(dir, lang, text: string) {
		os.make_directory_all(fmt.tprintf("%s/%s", dir, lang))
		_ = os.write_entire_file(fmt.tprintf("%s/%s/demo.msg", dir, lang), transmute([]u8)text)
	}
	write(dir, "fr", "plural = n > 1\nmsgid \"Hello\"\nmsgstr \"Bonjour\"\nmsgid \"Bye\"\nmsgstr \"Au revoir\"\nmsgid \"%d file\"\nmsgid_plural \"%d files\"\nmsgstr[0] \"%d fichier\"\nmsgstr[1] \"%d fichiers\"\n")
	write(dir, "fr_CA", "msgid \"Hello\"\nmsgstr \"Allô\"\n")
	write(dir, "de", "msgid \"Bye\"\nmsgstr \"Tschüss\"\n")
	write(dir, "ar", "msgid \"Hello\"\nmsgstr \"مرحبا\"\n")
	write(dir, "xx", "direction = rtl\nmsgid \"Hello\"\nmsgstr \"olleH\"\n")
	defer os.remove_all(dir)

	saved: [5]string
	keys := [5]string{"PALM_LOCALE_DIR", "LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}
	for k, i in keys {
		saved[i] = os.get_env(k, context.temp_allocator)
	}
	defer for k, i in keys {
		if saved[i] == "" {os.unset_env(k)} else {os.set_env(k, saved[i])}
	}
	os.set_env("PALM_LOCALE_DIR", dir)
	for k in keys[1:] {os.unset_env(k)}

	// LANG=fr_CA.UTF-8: fr_CA first, then fr, then the msgid.
	os.set_env("LANG", "fr_CA.UTF-8")
	kit.i18n_init("demo")
	testing.expect_value(t, kit.i18n_language(), "fr_CA")
	testing.expect_value(t, kit.tr("Hello"), "Allô")
	testing.expect_value(t, kit.tr("Bye"), "Au revoir")
	testing.expect_value(t, kit.tr("Untouched"), "Untouched")
	testing.expect_value(t, kit.trn("%d file", "%d files", 0), "%d fichier") // French: 0 is singular
	testing.expect_value(t, kit.trnf("%d file", "%d files", 3, 3), "3 fichiers")
	testing.expect_value(t, kit.trn("%d dir", "%d dirs", 1), "%d dir")
	testing.expect_value(t, kit.trn("%d dir", "%d dirs", 0), "%d dirs")
	testing.expect_value(t, kit.trf("%s!", "x"), "x!")
	testing.expect(t, !kit.i18n_is_rtl())

	// LC_MESSAGES beats LANG, LC_ALL beats both, LANGUAGE beats everything
	// and lists fallbacks of its own.
	os.set_env("LC_MESSAGES", "de_DE.UTF-8")
	kit.i18n_init("demo")
	testing.expect_value(t, kit.tr("Bye"), "Tschüss")
	testing.expect_value(t, kit.tr("Hello"), "Hello") // de has no Hello, and LANG is not a fallback
	os.set_env("LC_ALL", "ar_EG.UTF-8")
	kit.i18n_init("demo")
	testing.expect_value(t, kit.tr("Hello"), "مرحبا")
	testing.expect(t, kit.i18n_is_rtl())
	os.set_env("LANGUAGE", "de:fr")
	kit.i18n_init("demo")
	testing.expect_value(t, kit.tr("Bye"), "Tschüss")
	testing.expect_value(t, kit.tr("Hello"), "Bonjour")
	os.unset_env("LANGUAGE")
	os.unset_env("LC_ALL")
	os.unset_env("LC_MESSAGES")

	// Switching live, and the header's own direction.
	kit.i18n_set_language("xx")
	testing.expect_value(t, kit.tr("Hello"), "olleH")
	testing.expect(t, kit.i18n_is_rtl())
	kit.i18n_set_language("fr_FR.UTF-8")
	testing.expect_value(t, kit.tr("Hello"), "Bonjour")
	testing.expect_value(t, kit.i18n_language(), "fr")
	kit.i18n_set_language("") // back to the environment: LANG=fr_CA.UTF-8
	testing.expect_value(t, kit.tr("Hello"), "Allô")

	// C, a language with no catalogue, and an unset environment: the msgids.
	for lang in ([?]string{"C", "C.UTF-8", "POSIX", "pt_BR.UTF-8"}) {
		kit.i18n_set_language(lang)
		testing.expectf(t, kit.tr("Hello") == "Hello" && kit.i18n_language() == "en" && !kit.i18n_is_rtl(), "%s: %q", lang, kit.tr("Hello"))
	}
	os.unset_env("LANG")
	kit.i18n_init("demo")
	testing.expect_value(t, kit.tr("Hello"), "Hello")

	// A domain with no catalogue anywhere.
	os.set_env("LANG", "fr_FR.UTF-8")
	kit.i18n_init("nosuchapp")
	testing.expect_value(t, kit.tr("Hello"), "Hello")

	// The real catalogues, through the real root.
	os.set_env("PALM_LOCALE_DIR", LOCALE_DIR)
	kit.i18n_init("greeter", "fr_FR.UTF-8")
	testing.expect_value(t, kit.tr("Sign in"), "Se connecter")
	testing.expect_value(t, kit.trf("%[0]s, %[1]d %[2]s %[3]d", kit.tr("Tuesday"), 13, kit.tr("October"), 2026), "mardi 13 octobre 2026")
	kit.i18n_set_language("ja_JP.UTF-8")
	testing.expect_value(t, kit.trf("%[0]s, %[1]d %[2]s %[3]d", kit.tr("Tuesday"), 13, kit.tr("October"), 2026), "2026年10月13日（火曜日）")
	kit.i18n_set_language("ar")
	testing.expect(t, kit.i18n_is_rtl())
	testing.expect_value(t, kit.trnf("%d account", "%d accounts", 2, 2), "2 حسابان")
	testing.expect_value(t, kit.trnf("%d account", "%d accounts", 11, 11), "11 حسابًا")
	kit.i18n_shutdown()
	testing.expect_value(t, kit.tr("Sign in"), "Sign in")
}

// Every catalogue in distro/locale: parses, has a plural rule that works,
// enough plural forms, and the same % verbs as its msgid.
@(test)
catalogues_lint :: proc(t: ^testing.T) {
	langs, err := os.read_all_directory_by_path(LOCALE_DIR, context.temp_allocator)
	testing.expectf(t, err == nil && len(langs) > 0, "cannot read %s", LOCALE_DIR)
	count := 0
	for lang in langs {
		if lang.type != .Directory {
			continue
		}
		files, _ := os.read_all_directory_by_path(lang.fullpath, context.temp_allocator)
		for f in files {
			if !strings.has_suffix(f.name, ".msg") {
				continue
			}
			count += 1
			data, rerr := os.read_entire_file_from_path(f.fullpath, context.temp_allocator)
			testing.expectf(t, rerr == nil, "%s: unreadable", f.fullpath)
			c, perr := kit.i18n_parse(string(data))
			testing.expectf(t, perr == "", "%s: %s", f.fullpath, perr)
			testing.expectf(t, c.header["plural"] != "", "%s: no plural = line", f.fullpath)

			most := 0
			for n in 0 ..< 1000 {
				idx, _ := kit.plural_eval(c.plural, n)
				most = max(most, idx)
			}
			for id, forms in c.msgs {
				want := verbs(id)
				for form, i in forms {
					testing.expectf(t, verbs(form) == want, "%s: %q -> %q: %% verbs %q, msgid has %q", f.name, id, form, verbs(form), want)
					_ = i
				}
				if len(forms) > 1 || (len(forms) == 1 && most == 0 && is_plural_entry(string(data), id)) {
					testing.expectf(t, len(forms) > most, "%s/%s: %q has %d forms, its rule picks up to index %d", lang.name, f.name, id, len(forms), most)
				}
			}
			kit.i18n_catalog_destroy(&c)
		}
	}
	testing.expectf(t, count >= 5, "only %d catalogues found", count)
}

// verbs is the sorted string of fmt verb letters in s, ignoring %% and the
// explicit argument indices a translation uses to reorder.
@(private = "file")
verbs :: proc(s: string) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '%' {
			continue
		}
		i += 1
		if i < len(s) && s[i] == '%' {
			continue
		}
		for i < len(s) && strings.index_byte("[]0123456789.+-# ", s[i]) >= 0 {
			i += 1
		}
		if i < len(s) {
			append(&out, s[i])
		}
	}
	slice.sort(out[:])
	return string(out[:])
}

@(private = "file")
is_plural_entry :: proc(text, id: string) -> bool {
	return strings.contains(text, fmt.tprintf("msgid \"%s\"\nmsgid_plural", id))
}
