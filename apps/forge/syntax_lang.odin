// Copied from apps/editor/lang.odin, unchanged; see syntax_lex.odin.
//
// What language is this, and what are its words?
//
// The tokeniser in lex.odin was written for Odin and turned out to be the
// right shape for everything else: a scanner where each rule owns the text it
// consumes. Adding a language is therefore a table — the comment markers, the
// quoting rules and the word lists — rather than a second scanner. Only JSON
// and Markdown need code of their own, because neither is a C-family grammar:
// JSON cares which strings are keys, and Markdown is a line grammar where the
// first character of the line decides everything.
//
// Every word list below is **sorted**, because `in_set` binary-searches it.
// A word out of order is silently never matched, so `--selftest` asserts the
// ordering of all of them rather than trusting the author.
package main

import "core:strings"

Lang :: enum u8 {
	Plain,
	Odin,
	C,
	JSON,
	Markdown,
	Python,
	Shell,
}

// Syntax is everything the generic C-family scanner needs to know. The
// languages that have one of these share `lex_code`; JSON and Markdown do not.
Syntax :: struct {
	keywords:     []string,
	types:        []string,
	builtins:     []string,
	line_comment: string, // "//", "#", or "" for none
	alt_comment:  string, // a second line-comment form, e.g. C++'s "//" beside C
	block_open:   string, // "/*", or "" for none
	block_close:  string,
	nest_block:   bool, // Odin's block comments nest; C's do not
	raw_quote:    u8, // '`' opens a raw string that may cross lines, 0 for none
	char_quote:   bool, // '…' is a character literal, not a string
	directive:    string, // the characters that introduce #partial / @(private) / #include
	decl_colon:   bool, // `name ::` is a declaration worth marking
}

// ---------------------------------------------------------------------------
// Odin
// ---------------------------------------------------------------------------

ODIN_KEYWORDS := [?]string {
	"asm",
	"auto_cast",
	"bit_field",
	"bit_set",
	"break",
	"case",
	"cast",
	"context",
	"continue",
	"defer",
	"distinct",
	"do",
	"dynamic",
	"else",
	"enum",
	"fallthrough",
	"for",
	"foreign",
	"if",
	"import",
	"in",
	"map",
	"matrix",
	"not_in",
	"or_break",
	"or_continue",
	"or_else",
	"or_return",
	"package",
	"proc",
	"return",
	"struct",
	"switch",
	"transmute",
	"typeid",
	"union",
	"using",
	"when",
	"where",
}

ODIN_TYPES := [?]string {
	"any",
	"b16",
	"b32",
	"b64",
	"b8",
	"bool",
	"byte",
	"complex128",
	"complex32",
	"complex64",
	"cstring",
	"f16",
	"f32",
	"f64",
	"i128",
	"i16",
	"i32",
	"i64",
	"i8",
	"int",
	"quaternion128",
	"quaternion256",
	"quaternion64",
	"rawptr",
	"rune",
	"string",
	"u128",
	"u16",
	"u32",
	"u64",
	"u8",
	"uint",
	"uintptr",
}

ODIN_BUILTINS := [?]string {
	"abs",
	"align_of",
	"append",
	"cap",
	"clamp",
	"clear",
	"copy",
	"delete",
	"false",
	"free",
	"len",
	"make",
	"max",
	"min",
	"new",
	"nil",
	"offset_of",
	"ordered_remove",
	"raw_data",
	"remove_range",
	"reserve",
	"resize",
	"size_of",
	"swizzle",
	"true",
	"type_of",
	"unordered_remove",
}

// ---------------------------------------------------------------------------
// C and C++
//
// One table serves both: a C++ keyword in a .c file is not a word any C
// programmer would use for something else, and splitting the tables would buy
// nothing but a second thing to keep sorted.
// ---------------------------------------------------------------------------

C_KEYWORDS := [?]string {
	"alignas",
	"alignof",
	"and",
	"asm",
	"auto",
	"break",
	"case",
	"catch",
	"class",
	"co_await",
	"co_return",
	"co_yield",
	"concept",
	"const",
	"const_cast",
	"consteval",
	"constexpr",
	"constinit",
	"continue",
	"decltype",
	"default",
	"delete",
	"do",
	"dynamic_cast",
	"else",
	"enum",
	"explicit",
	"export",
	"extern",
	"for",
	"friend",
	"goto",
	"if",
	"inline",
	"mutable",
	"namespace",
	"new",
	"noexcept",
	"not",
	"operator",
	"or",
	"private",
	"protected",
	"public",
	"register",
	"reinterpret_cast",
	"requires",
	"restrict",
	"return",
	"sizeof",
	"static",
	"static_assert",
	"static_cast",
	"struct",
	"switch",
	"template",
	"this",
	"thread_local",
	"throw",
	"try",
	"typedef",
	"typeid",
	"typename",
	"union",
	"using",
	"virtual",
	"volatile",
	"while",
	"xor",
}

C_TYPES := [?]string {
	"bool",
	"char",
	"char16_t",
	"char32_t",
	"char8_t",
	"double",
	"float",
	"int",
	"int16_t",
	"int32_t",
	"int64_t",
	"int8_t",
	"intptr_t",
	"long",
	"ptrdiff_t",
	"short",
	"signed",
	"size_t",
	"ssize_t",
	"uint16_t",
	"uint32_t",
	"uint64_t",
	"uint8_t",
	"uintptr_t",
	"unsigned",
	"va_list",
	"void",
	"wchar_t",
}

C_BUILTINS := [?]string {
	"NULL",
	"false",
	"nullptr",
	"true",
}

// ---------------------------------------------------------------------------
// Python
// ---------------------------------------------------------------------------

PY_KEYWORDS := [?]string {
	"and",
	"as",
	"assert",
	"async",
	"await",
	"break",
	"class",
	"continue",
	"def",
	"del",
	"elif",
	"else",
	"except",
	"finally",
	"for",
	"from",
	"global",
	"if",
	"import",
	"in",
	"is",
	"lambda",
	"match",
	"nonlocal",
	"not",
	"or",
	"pass",
	"raise",
	"return",
	"try",
	"while",
	"with",
	"yield",
}

PY_TYPES := [?]string {
	"bool",
	"bytearray",
	"bytes",
	"complex",
	"dict",
	"float",
	"frozenset",
	"int",
	"list",
	"object",
	"set",
	"str",
	"tuple",
	"type",
}

PY_BUILTINS := [?]string {
	"False",
	"None",
	"True",
	"abs",
	"all",
	"any",
	"enumerate",
	"isinstance",
	"len",
	"max",
	"min",
	"open",
	"print",
	"range",
	"repr",
	"reversed",
	"round",
	"self",
	"sorted",
	"sum",
	"super",
	"zip",
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

SH_KEYWORDS := [?]string {
	"case",
	"do",
	"done",
	"elif",
	"else",
	"esac",
	"fi",
	"for",
	"function",
	"if",
	"in",
	"return",
	"select",
	"then",
	"until",
	"while",
}

SH_TYPES := [?]string {
	"declare",
	"export",
	"local",
	"readonly",
	"typeset",
}

SH_BUILTINS := [?]string {
	"break",
	"cd",
	"continue",
	"echo",
	"eval",
	"exec",
	"exit",
	"printf",
	"pwd",
	"read",
	"set",
	"shift",
	"source",
	"test",
	"trap",
	"unset",
	"wait",
}

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

syntax_of :: proc(l: Lang) -> Syntax {
	switch l {
	case .Odin:
		return {
			keywords = ODIN_KEYWORDS[:],
			types = ODIN_TYPES[:],
			builtins = ODIN_BUILTINS[:],
			line_comment = "//",
			block_open = "/*",
			block_close = "*/",
			nest_block = true, // Odin's block comments nest
			raw_quote = '`',
			char_quote = true,
			directive = "#@",
			decl_colon = true,
		}
	case .C:
		return {
			keywords = C_KEYWORDS[:],
			types = C_TYPES[:],
			builtins = C_BUILTINS[:],
			line_comment = "//",
			block_open = "/*",
			block_close = "*/",
			nest_block = false, // C's do not: /* /* */ closes
			char_quote = true,
			directive = "#",
		}
	case .Python:
		return {
			keywords = PY_KEYWORDS[:],
			types = PY_TYPES[:],
			builtins = PY_BUILTINS[:],
			line_comment = "#",
			// A quote in Python is a string either way; there is no character
			// literal, so '…' must not be lexed as one.
			char_quote = false,
		}
	case .Shell:
		return {
			keywords = SH_KEYWORDS[:],
			types = SH_TYPES[:],
			builtins = SH_BUILTINS[:],
			line_comment = "#",
			char_quote = false,
		}
	case .Plain, .JSON, .Markdown:
		return {}
	}
	return {}
}

lang_name :: proc(l: Lang) -> string {
	switch l {
	case .Odin:
		return "Odin"
	case .C:
		return "C / C++"
	case .JSON:
		return "JSON"
	case .Markdown:
		return "Markdown"
	case .Python:
		return "Python"
	case .Shell:
		return "Shell"
	case .Plain:
		return "Plain Text"
	}
	return "Plain Text"
}

// lang_highlights is false for the languages that have no highlighter, which
// is what the status bar and the Odin badge key off.
lang_highlights :: proc(l: Lang) -> bool {
	return l != .Plain
}

// ---------------------------------------------------------------------------
// Picking one
// ---------------------------------------------------------------------------

Ext_Lang :: struct {
	ext:  string,
	lang: Lang,
}

EXTENSIONS := [?]Ext_Lang {
	{".odin", .Odin},
	{".c", .C},
	{".h", .C},
	{".cc", .C},
	{".cpp", .C},
	{".cxx", .C},
	{".hh", .C},
	{".hpp", .C},
	{".hxx", .C},
	{".ino", .C},
	{".m", .C},
	{".json", .JSON},
	{".jsonc", .JSON},
	{".jsonl", .JSON},
	{".md", .Markdown},
	{".markdown", .Markdown},
	{".mdown", .Markdown},
	{".mkd", .Markdown},
	{".py", .Python},
	{".pyi", .Python},
	{".pyw", .Python},
	{".sh", .Shell},
	{".bash", .Shell},
	{".zsh", .Shell},
	{".ksh", .Shell},
	{".bashrc", .Shell},
	{".profile", .Shell},
}

// Files that carry their language in their whole name rather than a suffix.
NAMED_FILES := [?]Ext_Lang {
	{"readme", .Markdown},
	{"changelog", .Markdown},
	{"license", .Plain},
	{".bashrc", .Shell},
	{".zshrc", .Shell},
	{".profile", .Shell},
	{"pkgbuild", .Shell},
	{"configure", .Shell},
}

// lang_for_path picks a language from a file name. The extension is the first
// authority, then the whole name — `.bashrc` has no extension to speak of and
// `README` has none at all.
lang_for_path :: proc(path: string) -> Lang {
	name := strings.to_lower(base_of(path), context.temp_allocator)
	for e in EXTENSIONS {
		if strings.has_suffix(name, e.ext) {
			return e.lang
		}
	}
	for n in NAMED_FILES {
		if name == n.ext {
			return n.lang
		}
	}
	return .Plain
}

// lang_for_shebang reads the first line of a file with no useful name. A
// script is identified by what it says it is, which is more reliable than its
// absence of an extension.
lang_for_shebang :: proc(first_line: string) -> (Lang, bool) {
	if !strings.has_prefix(first_line, "#!") {
		return .Plain, false
	}
	l := first_line[2:]
	switch {
	case strings.contains(l, "python"):
		return .Python, true
	case strings.contains(l, "bash"),
	     strings.contains(l, "zsh"),
	     strings.contains(l, "/sh"),
	     strings.contains(l, " sh"),
	     strings.contains(l, "dash"):
		return .Shell, true
	}
	return .Plain, false
}

// lang_detect is what the app calls: the name first, the shebang as a fallback
// for the files that have no name worth reading.
lang_detect :: proc(path: string, first_line: string) -> Lang {
	if l := lang_for_path(path); l != .Plain {
		return l
	}
	if l, ok := lang_for_shebang(first_line); ok {
		return l
	}
	return .Plain
}
