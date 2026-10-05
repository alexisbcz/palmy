package vt

// ---------------------------------------------------------------------------
// SGR: Select Graphic Rendition, the `ESC[1;31m` family.
//
// The parameter list is not a flat list of numbers. `38;2;255;0;0` is one
// attribute spread over five parameters, `4:3` is one attribute with a
// subparameter, and the two spellings can be mixed in the same sequence. So
// this is an iterator over attributes, not over parameters.
//
// `seps[i]` is the separator that *follows* parameter i. A colon there binds
// the parameter to the next one; a semicolon ends the group. That is the only
// difference between `4:3`, a curly underline, and `4;3`, an underline
// followed by italics.
//
// The tag numbering is deliberately identical to libghostty-vt's
// GhosttySgrAttributeTag, because the differential test compares the two as
// integers and a mapping table in the middle would be one more thing that can
// be wrong in a way the test cannot see.
// ---------------------------------------------------------------------------

Sgr_Tag :: enum u8 {
	Unset                 = 0,
	Unknown               = 1,
	Bold                  = 2,
	Reset_Bold            = 3,
	Italic                = 4,
	Reset_Italic          = 5,
	Faint                 = 6,
	Underline             = 7,
	Underline_Color       = 8,
	Underline_Color_256   = 9,
	Reset_Underline_Color = 10,
	Overline              = 11,
	Reset_Overline        = 12,
	Blink                 = 13,
	Reset_Blink           = 14,
	Inverse               = 15,
	Reset_Inverse         = 16,
	Invisible             = 17,
	Reset_Invisible       = 18,
	Strikethrough         = 19,
	Reset_Strikethrough   = 20,
	Direct_Color_Fg       = 21,
	Direct_Color_Bg       = 22,
	Bg_8                  = 23,
	Fg_8                  = 24,
	Reset_Fg              = 25,
	Reset_Bg              = 26,
	Bright_Bg_8           = 27,
	Bright_Fg_8           = 28,
	Bg_256                = 29,
	Fg_256                = 30,
}

Underline_Style :: enum u8 {
	None   = 0,
	Single = 1,
	Double = 2,
	Curly  = 3,
	Dotted = 4,
	Dashed = 5,
}

Rgb :: [3]u8

Sgr_Attr :: struct {
	tag:       Sgr_Tag,
	underline: Underline_Style,
	rgb:       Rgb,
	idx:       u8,
}

Sgr_Parser :: struct {
	params: []u16,
	seps:   []u8,
	i:      int,
}

sgr_begin :: proc(params: []u16, seps: []u8) -> Sgr_Parser {
	return Sgr_Parser{params = params, seps = seps}
}

// sep_after reports whether parameter i is colon-joined to the one after it.
@(private = "file")
colon_after :: proc(s: ^Sgr_Parser, i: int) -> bool {
	return s.seps != nil && i < len(s.seps) && s.seps[i] == ':'
}

// sgr_next yields the next attribute, or false when the list is exhausted.
//
// Two shapes of parameter list arrive here and they are read differently. A
// colon-joined run is a single attribute with subparameters, and the run is
// consumed whole whether or not it made sense. A plain parameter consumes just
// itself -- except for the colour introducers, which are allowed to read ahead
// across semicolons, because `38;2;255;0;0` is the spelling almost everything
// actually emits.
sgr_next :: proc(s: ^Sgr_Parser) -> (attr: Sgr_Attr, ok: bool) {
	if s.i >= len(s.params) {
		return {}, false
	}
	start := s.i
	colon := colon_after(s, start)
	group: []u16
	if colon {
		end := start
		for end + 1 < len(s.params) && colon_after(s, end) {
			end += 1
		}
		group = s.params[start:end + 1]
		s.i = end + 1
	} else {
		group = s.params[start:]
		s.i = start + 1
	}

	plain :: proc(colon: bool, tag: Sgr_Tag) -> (Sgr_Attr, bool) {
		if colon {
			return Sgr_Attr{tag = .Unknown}, true
		}
		return Sgr_Attr{tag = tag}, true
	}

	switch group[0] {
	case 0:
		return plain(colon, .Unset)
	case 1:
		return plain(colon, .Bold)
	case 2:
		return plain(colon, .Faint)
	case 3:
		return plain(colon, .Italic)
	case 4:
		if colon {
			// `4:n` picks the underline style. A style number nobody has
			// defined yet falls back to a plain underline rather than
			// dropping the attribute: the application asked to underline.
			if len(group) != 2 {
				return Sgr_Attr{tag = .Unknown}, true
			}
			st := Underline_Style.Single
			if group[1] <= 5 {
				st = Underline_Style(group[1])
			}
			return Sgr_Attr{tag = .Underline, underline = st}, true
		}
		return Sgr_Attr{tag = .Underline, underline = .Single}, true
	case 5:
		return plain(colon, .Blink)
	case 6:
		return plain(colon, .Blink)
	case 7:
		return plain(colon, .Inverse)
	case 8:
		return plain(colon, .Invisible)
	case 9:
		return plain(colon, .Strikethrough)
	case 21:
		if colon {
			return Sgr_Attr{tag = .Unknown}, true
		}
		return Sgr_Attr{tag = .Underline, underline = .Double}, true
	case 22:
		return plain(colon, .Reset_Bold)
	case 23:
		return plain(colon, .Reset_Italic)
	case 24:
		if colon {
			return Sgr_Attr{tag = .Unknown}, true
		}
		return Sgr_Attr{tag = .Underline, underline = .None}, true
	case 25:
		return plain(colon, .Reset_Blink)
	case 26:
		return Sgr_Attr{tag = .Unknown}, true
	case 27:
		return plain(colon, .Reset_Inverse)
	case 28:
		return plain(colon, .Reset_Invisible)
	case 29:
		return plain(colon, .Reset_Strikethrough)
	case 30, 31, 32, 33, 34, 35, 36, 37:
		if colon {
			return Sgr_Attr{tag = .Unknown}, true
		}
		return Sgr_Attr{tag = .Fg_8, idx = u8(group[0] - 30)}, true
	case 38:
		return sgr_color(s, start, group, colon, .Fg_256, .Direct_Color_Fg)
	case 39:
		return plain(colon, .Reset_Fg)
	case 40, 41, 42, 43, 44, 45, 46, 47:
		if colon {
			return Sgr_Attr{tag = .Unknown}, true
		}
		return Sgr_Attr{tag = .Bg_8, idx = u8(group[0] - 40)}, true
	case 48:
		return sgr_color(s, start, group, colon, .Bg_256, .Direct_Color_Bg)
	case 49:
		return plain(colon, .Reset_Bg)
	case 53:
		return plain(colon, .Overline)
	case 55:
		return plain(colon, .Reset_Overline)
	case 58:
		return sgr_color(s, start, group, colon, .Underline_Color_256, .Underline_Color)
	case 59:
		return plain(colon, .Reset_Underline_Color)
	case 90, 91, 92, 93, 94, 95, 96, 97:
		if colon {
			return Sgr_Attr{tag = .Unknown}, true
		}
		return Sgr_Attr{tag = .Bright_Fg_8, idx = u8(group[0] - 90 + 8)}, true
	case 100, 101, 102, 103, 104, 105, 106, 107:
		if colon {
			return Sgr_Attr{tag = .Unknown}, true
		}
		return Sgr_Attr{tag = .Bright_Bg_8, idx = u8(group[0] - 100 + 8)}, true
	}
	return Sgr_Attr{tag = .Unknown}, true
}

// sgr_color reads 38, 48 and 58, which carry a colour in one of four spellings:
//
//	38;5;N              256-colour, semicolons
//	38:5:N              256-colour, colons
//	38;2;R;G;B          direct colour, semicolons
//	38:2:R:G:B          direct colour, colons
//	38:2:CS:R:G:B       direct colour with a leading colour-space id
//
// Channel values wider than a byte are truncated rather than rejected, which
// is what xterm does and therefore what programs have come to rely on.
@(private = "file")
sgr_color :: proc(
	s: ^Sgr_Parser,
	start: int,
	group: []u16,
	colon: bool,
	tag_256: Sgr_Tag,
	tag_direct: Sgr_Tag,
) -> (Sgr_Attr, bool) {
	// Two spellings, read differently, and the difference is not cosmetic.
	//
	// `38;2;R;G;B` is the one everything emits. It is read straight off the
	// parameter list and the separators after the introducer are ignored,
	// because half the programs in the world write `38;2:1:2:3`.
	//
	// `38:2:...` is the ISO 8613-6 form, where the colon group is a single
	// parameter with subparameters. There the group length is what tells a
	// bare `R:G:B` from a `colourspace:R:G:B`, so the length is checked and a
	// group of any other length is rejected whole.
	//
	// A rejected colour consumes only its introducer, so `38;2;1;2` is a
	// broken colour followed by three perfectly good attributes.
	slice := s.params[start:]
	fail_one :: proc(s: ^Sgr_Parser, start: int) -> (Sgr_Attr, bool) {
		s.i = start + 1
		return Sgr_Attr{tag = .Unknown}, true
	}
	if len(slice) < 2 {
		return fail_one(s, start)
	}
	switch slice[1] {
	case 5:
		if len(slice) < 3 {
			return fail_one(s, start)
		}
		s.i = start + 3
		return Sgr_Attr{tag = tag_256, idx = u8(slice[2])}, true
	case 2:
		if len(slice) < 5 {
			return fail_one(s, start)
		}
		off := 2
		if colon {
			switch len(group) {
			case 5:
				off = 2
			case 6:
				// The six-element form leads with a colour-space id that
				// nothing uses and everything has to skip.
				off = 3
			case:
				return Sgr_Attr{tag = .Unknown}, true
			}
		} else {
			s.i = start + 5
		}
		return Sgr_Attr {
				tag = tag_direct,
				rgb = {u8(slice[off]), u8(slice[off + 1]), u8(slice[off + 2])},
			},
			true
	}
	return fail_one(s, start)
}
