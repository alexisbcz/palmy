package main

// The command-line front end of Slides.
//
// Nothing below re-implements the editor. A deck is read with load_deck and
// written with save_deck (serialize.odin), which are the window's Open and
// Save. Every structural change — a new slide, a duplicate, a move, a layout,
// an inserted element, a deletion — is the window's own `invoke` (keys.odin)
// run on a State with no window behind it, with the slide and the selection
// set the way a person would have set them with the keyboard. Text, notes and
// the theme go through elem_set_text, slide_set_notes and theme_by_name, which
// are what the window commits an edit through. Pictures come out of
// render_slide_buffer, the renderer the canvas draws with, and every export
// is deck_export, the window's Export entries. So `slides add` and pressing M
// in the window cannot drift, because there is only one add.
//
// Slides and elements are numbered from 1, as the sorter and the inspector
// show them. An element can also be named by role: `title`, `subtitle` or
// `body` (the first text box of that style).
//
// A read command given no deck reads the built-in deck a fresh window opens
// with — `@fixture` names it explicitly — so every read works on a machine
// with no decks on it, which is also what makes them testable without
// touching anybody's files.
//
// The older spellings --export, --pptx, --pdf, --shots and --make-assets are
// aliases of commands, and `slides deck.json --pdf out.pdf` (a path first)
// still works through main's own loop.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import kit "kit:."
import p "palmy:."

FIXTURE_LABEL :: "@fixture"

// ---------------------------------------------------------------------------
// Declared output. Every list is a self-contained literal, so the order in
// which the package initialises them does not matter (see apps/kit/cli.odin).
// ---------------------------------------------------------------------------

INFO_FIELDS := []kit.Field {
	{name = "deck", kind = .String, help = "the file read, or @fixture for the built-in deck"},
	{name = "title", kind = .String},
	{name = "author", kind = .String},
	{name = "theme", kind = .String},
	{name = "slides", kind = .Int},
	{name = "elements", kind = .Int, help = "across every slide"},
	{name = "words", kind = .Int, help = "in text boxes, not counting notes"},
	{name = "notes_words", kind = .Int},
	{name = "pictures", kind = .Int},
	{
		name = "outline",
		kind = .Array,
		of = {
			{name = "slide", kind = .Int, help = "from 1"},
			{name = "layout", kind = .String},
			{name = "title", kind = .String, help = "the first Title-styled text, else the first text"},
			{name = "elements", kind = .Int},
			{name = "has_notes", kind = .Bool},
		},
	},
}

OUTLINE_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{
		name = "slides",
		kind = .Array,
		of = {
			{name = "slide", kind = .Int},
			{name = "layout", kind = .String},
			{name = "title", kind = .String},
		},
	},
}

TEXT_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{
		name = "slides",
		kind = .Array,
		of = {
			{name = "slide", kind = .Int},
			{name = "title", kind = .String},
			{
				name = "texts",
				kind = .Array,
				of = {
					{name = "element", kind = .Int},
					{name = "style", kind = .String},
					{name = "text", kind = .String},
				},
			},
		},
	},
}

NOTES_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{
		name = "slides",
		kind = .Array,
		of = {
			{name = "slide", kind = .Int},
			{name = "title", kind = .String},
			{name = "notes", kind = .String},
		},
	},
}

SHOW_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{name = "slide", kind = .Int},
	{name = "layout", kind = .String},
	{name = "title", kind = .String},
	{name = "notes", kind = .String},
	{
		name = "elements",
		kind = .Array,
		help = "in paint order, back to front",
		of = {
			{name = "element", kind = .Int},
			{name = "kind", kind = .String, help = "text rect ellipse line arrow image"},
			{name = "label", kind = .String, help = "what the inspector calls it"},
			{name = "x", kind = .Float, help = "slide units, 1280x720"},
			{name = "y", kind = .Float},
			{name = "w", kind = .Float},
			{name = "h", kind = .Float},
			{name = "rotation", kind = .Float},
			{name = "opacity", kind = .Float},
			{name = "fill", kind = .String, help = "a theme slot name, or custom"},
			{name = "stroke", kind = .String},
			{name = "text", kind = .String, opt = true},
			{name = "style", kind = .String, opt = true},
			{name = "bold", kind = .Bool, opt = true},
			{name = "src", kind = .String, opt = true},
		},
	},
}

THEMES_FIELDS := []kit.Field {
	{
		name = "themes",
		kind = .Array,
		of = {
			{name = "name", kind = .String},
			{name = "dark", kind = .Bool},
			{name = "mono", kind = .Bool, help = "sets the whole deck in the monospace face"},
			{name = "background", kind = .String, help = "#rrggbb"},
			{name = "accent", kind = .String},
		},
	},
	{name = "layouts", kind = .Array, of = {{kind = .String}}},
}

// CHANGE_FIELDS is what every edit of a deck prints.
CHANGE_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{name = "action", kind = .String},
	{name = "slide", kind = .Int, help = "the slide acted on, from 1"},
	{name = "element", kind = .Int, opt = true, help = "the element acted on, from 1"},
	{name = "slides", kind = .Int, help = "how many the deck has now"},
	{name = "detail", kind = .String},
	{name = "written", kind = .Bool, help = "false under --dry-run"},
}

NEW_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{name = "title", kind = .String},
	{name = "theme", kind = .String},
	{name = "slides", kind = .Int},
	{name = "written", kind = .Bool},
}

EXPORT_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{name = "out", kind = .String},
	{name = "format", kind = .String, help = "png pptx pdf json"},
	{name = "slides", kind = .Int},
	{name = "files", kind = .Int, help = "files written: one per slide plus a contact sheet for png"},
	{name = "written", kind = .Bool},
}

RENDER_FIELDS := []kit.Field {
	{name = "deck", kind = .String},
	{name = "slide", kind = .Int},
	{name = "out", kind = .String},
	{name = "width", kind = .Int},
	{name = "height", kind = .Int},
	{name = "written", kind = .Bool},
}

SHOTS_FIELDS := []kit.Field {
	{name = "dir", kind = .String},
	{name = "written", kind = .Bool},
}

ASSETS_FIELDS := []kit.Field {
	{name = "dir", kind = .String},
	{name = "written", kind = .Array, of = {{kind = .String}}},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "info",
		summary = "a deck's title, theme, counts and outline",
		effect = .Read,
		args = {{name = "deck", kind = .Path, help = "a deck .json, or @fixture (the default) for the built-in deck"}},
		out = INFO_FIELDS,
		examples = {"slides info --json", "slides info talk.json --json"},
		run = cmd_info,
	},
	{
		verb = "outline",
		summary = "every slide's number, layout and title",
		effect = .Read,
		args = {{name = "deck", kind = .Path, help = "a deck .json, or @fixture (the default)"}},
		out = OUTLINE_FIELDS,
		examples = {"slides outline --json", "slides outline talk.json"},
		run = cmd_outline,
	},
	{
		verb = "text",
		summary = "the words on the slides, box by box",
		effect = .Read,
		args = {{name = "deck", kind = .Path, help = "a deck .json, or @fixture (the default)"}},
		flags = {{name = "slide", kind = .Int, help = "one slide only, from 1"}},
		out = TEXT_FIELDS,
		examples = {"slides text --json", "slides text talk.json --slide 3 --json"},
		run = cmd_text,
	},
	{
		verb = "notes",
		summary = "the speaker notes, slide by slide",
		effect = .Read,
		args = {{name = "deck", kind = .Path, help = "a deck .json, or @fixture (the default)"}},
		flags = {{name = "slide", kind = .Int, help = "one slide only, from 1"}},
		out = NOTES_FIELDS,
		examples = {"slides notes --json", "slides notes talk.json --slide 2"},
		run = cmd_notes,
	},
	{
		verb = "show",
		summary = "one slide in full: every element, its geometry and paint",
		effect = .Read,
		args = {
			{name = "slide", kind = .Int, help = "from 1", required = true},
			{name = "deck", kind = .Path, help = "a deck .json, or @fixture (the default)"},
		},
		out = SHOW_FIELDS,
		examples = {"slides show 4 --json", "slides show 2 talk.json --json"},
		run = cmd_show,
	},
	{
		verb = "themes",
		summary = "the themes and layouts a deck can use",
		effect = .Read,
		out = THEMES_FIELDS,
		examples = {"slides themes --json"},
		run = cmd_themes,
	},
	{
		verb = "new",
		summary = "write a new deck: a title slide, or a copy of the built-in deck",
		effect = .Mutate,
		args = {{name = "deck", kind = .Path, help = "where to write it (.json)", required = true}},
		flags = {
			{name = "title", kind = .String, help = "the deck's title, also put on the title slide"},
			{name = "subtitle", kind = .String, help = "the title slide's subtitle"},
			{name = "author", kind = .String},
			{name = "theme", kind = .String, help = "a theme name from `slides themes`", def = "Midnight"},
			{name = "fixture", kind = .Bool, help = "start from the built-in eight-slide deck instead"},
			{name = "force", kind = .Bool, help = "overwrite a file that is already there"},
		},
		out = NEW_FIELDS,
		examples = {"slides new talk.json --title \"Quarterly review\" --theme Paper --json"},
		run = cmd_new,
	},
	{
		verb = "add",
		summary = "add a slide after another, as M does, with its words",
		effect = .Mutate,
		args = {{name = "deck", kind = .Path, required = true}},
		flags = {
			{name = "after", kind = .Int, help = "the slide to add it after, from 1; the last by default"},
			{
				name = "layout",
				kind = .Enum,
				values = {"title", "title-content", "two-content", "section", "picture", "blank"},
				def = "title-content",
			},
			{name = "title", kind = .String, help = "the title box's text"},
			{name = "body", kind = .String, help = "the body's text; \\n is a new line, a leading \"- \" a bullet"},
			{name = "notes", kind = .String, help = "speaker notes; \\n is a new line"},
		},
		out = CHANGE_FIELDS,
		examples = {
			"slides add talk.json --title Agenda --body \"- Numbers\\n- Plans\" --json",
			"slides add talk.json --after 1 --layout section --title \"Part two\"",
		},
		run = cmd_add,
	},
	{
		verb = "duplicate",
		summary = "copy a slide, notes and all, to just after it (Shift D)",
		effect = .Mutate,
		args = {{name = "deck", kind = .Path, required = true}, {name = "slide", kind = .Int, required = true}},
		out = CHANGE_FIELDS,
		examples = {"slides duplicate talk.json 2 --json"},
		run = cmd_duplicate,
	},
	{
		verb = "move",
		summary = "move a slide to another position (Shift J and Shift K)",
		effect = .Mutate,
		args = {
			{name = "deck", kind = .Path, required = true},
			{name = "slide", kind = .Int, required = true},
			{name = "to", kind = .Int, help = "the position it ends up at, from 1", required = true},
		},
		out = CHANGE_FIELDS,
		examples = {"slides move talk.json 5 2 --json"},
		run = cmd_move,
	},
	{
		verb = "layout",
		summary = "change a slide's layout, keeping its words (1 to 6)",
		effect = .Mutate,
		args = {
			{name = "deck", kind = .Path, required = true},
			{name = "slide", kind = .Int, required = true},
			{
				name = "layout",
				kind = .Enum,
				values = {"title", "title-content", "two-content", "section", "picture", "blank"},
				required = true,
			},
		},
		out = CHANGE_FIELDS,
		examples = {"slides layout talk.json 3 two-content --json"},
		run = cmd_layout,
	},
	{
		verb = "set-text",
		summary = "replace what a text box says",
		effect = .Idempotent,
		args = {
			{name = "deck", kind = .Path, required = true},
			{name = "slide", kind = .Int, required = true},
			{name = "element", kind = .String, help = "its number from 1, or title, subtitle or body", required = true},
			{name = "text", kind = .String, help = "\\n is a new line; put -- before text that starts with a dash", required = true},
		},
		out = CHANGE_FIELDS,
		examples = {"slides set-text talk.json 1 title \"Quarterly review\" --json", "slides set-text talk.json 3 2 -- \"- One\\n- Two\""},
		run = cmd_set_text,
	},
	{
		verb = "set-notes",
		summary = "replace a slide's speaker notes",
		effect = .Idempotent,
		args = {
			{name = "deck", kind = .Path, required = true},
			{name = "slide", kind = .Int, required = true},
			{name = "notes", kind = .String, help = "\\n is a new line; empty clears them", required = true},
		},
		out = CHANGE_FIELDS,
		examples = {"slides set-notes talk.json 2 \"Pause here for questions.\" --json"},
		run = cmd_set_notes,
	},
	{
		verb = "insert",
		summary = "put a text box, shape or picture on a slide (T R E L A I)",
		effect = .Mutate,
		args = {
			{name = "deck", kind = .Path, required = true},
			{name = "slide", kind = .Int, required = true},
			{name = "kind", kind = .Enum, values = {"text", "rect", "ellipse", "line", "arrow", "image"}, required = true},
		},
		flags = {
			{name = "text", kind = .String, help = "a text box's words; \\n is a new line"},
			{
				name = "style",
				kind = .Enum,
				values = {"title", "subtitle", "body", "bullets", "caption", "quote", "metric"},
				help = "a text box's style",
			},
			{name = "src", kind = .String, help = "an image's file, absolute or relative to the binary"},
			// Not x/y/w/h: the kit reads --y as --yes and --h as --help.
			{name = "left", kind = .Float, help = "slide units: the slide is 1280 by 720"},
			{name = "top", kind = .Float},
			{name = "width", kind = .Float},
			{name = "height", kind = .Float},
		},
		out = CHANGE_FIELDS,
		examples = {
			"slides insert talk.json 2 text --text \"Ship it\" --style quote --json",
			"slides insert talk.json 2 rect --left 100 --top 100 --width 300 --height 200",
		},
		run = cmd_insert,
	},
	{
		verb = "delete",
		summary = "delete a slide, or one element of it with --element",
		effect = .Destructive,
		args = {{name = "deck", kind = .Path, required = true}, {name = "slide", kind = .Int, required = true}},
		flags = {{name = "element", kind = .String, help = "delete this element instead: a number from 1, or title, subtitle or body"}},
		out = CHANGE_FIELDS,
		examples = {"slides delete talk.json 4 --yes --json", "slides delete talk.json 2 --element 3 --yes"},
		run = cmd_delete,
	},
	{
		verb = "theme",
		summary = "dress the deck in another theme (G steps through them)",
		effect = .Idempotent,
		args = {{name = "deck", kind = .Path, required = true}, {name = "name", kind = .String, help = "from `slides themes`", required = true}},
		out = CHANGE_FIELDS,
		examples = {"slides theme talk.json Paper --json"},
		run = cmd_theme,
	},
	{
		verb = "rename",
		summary = "set the deck's title, and its author with --author",
		effect = .Idempotent,
		args = {{name = "deck", kind = .Path, required = true}, {name = "title", kind = .String, required = true}},
		flags = {{name = "author", kind = .String}},
		out = CHANGE_FIELDS,
		examples = {"slides rename talk.json \"Quarterly review\" --author Ada --json"},
		run = cmd_rename,
	},
	{
		verb = "export",
		summary = "write the deck as PNGs, PowerPoint, PDF or JSON; the format follows the extension",
		effect = .Mutate,
		args = {
			{name = "deck", kind = .Path, help = "a deck .json, or @fixture", required = true},
			{name = "out", kind = .Path, help = "a .pptx, .pdf or .json file, or a directory for PNGs", required = true},
		},
		flags = {{name = "format", kind = .Enum, values = {"png", "pptx", "pdf", "json"}, help = "instead of the extension"}},
		out = EXPORT_FIELDS,
		examples = {"slides export talk.json talk.pdf --json", "slides export @fixture /tmp/slides-png --json"},
		run = cmd_export,
	},
	{
		verb = "render",
		summary = "render one slide to a PNG, through the canvas's own renderer",
		effect = .Mutate,
		args = {
			{name = "deck", kind = .Path, help = "a deck .json, or @fixture", required = true},
			{name = "slide", kind = .Int, required = true},
			{name = "out", kind = .Path, help = "the .png to write", required = true},
		},
		flags = {{name = "width", kind = .Int, def = "1920", help = "pixels; the height keeps 16:9"}},
		out = RENDER_FIELDS,
		examples = {"slides render @fixture 1 /tmp/title.png --json", "slides render talk.json 3 /tmp/s3.png --width 640"},
		run = cmd_render,
	},
	{
		verb = "shots",
		summary = "render the editor itself offscreen into PNGs; no window, nothing on screen",
		effect = .Mutate,
		args = {{name = "dir", kind = .Path, help = "where to write them", def = "slides-shots"}},
		out = SHOTS_FIELDS,
		examples = {"slides shots /tmp/slides-shots --json", "slides --shots /tmp/slides-shots"},
		aliases = {"--shots"},
		run = cmd_shots,
	},
	// The older spellings, which take the built-in deck. Hidden: `export` is
	// the command, these keep invocations that worked before working.
	{
		verb = "export-fixture",
		summary = "the built-in deck to PNGs (the old --export)",
		effect = .Mutate,
		args = {{name = "out", kind = .Path, help = "a directory; ~/Pictures/palmy-slides by default"}},
		out = EXPORT_FIELDS,
		examples = {"slides --export /tmp/slides-png"},
		aliases = {"--export"},
		hidden = true,
		run = cmd_legacy_png,
	},
	{
		verb = "pptx",
		summary = "the built-in deck to PowerPoint (the old --pptx)",
		effect = .Mutate,
		args = {{name = "out", kind = .Path}},
		out = EXPORT_FIELDS,
		examples = {"slides --pptx /tmp/deck.pptx"},
		aliases = {"--pptx"},
		hidden = true,
		run = cmd_legacy_pptx,
	},
	{
		verb = "pdf",
		summary = "the built-in deck to PDF (the old --pdf)",
		effect = .Mutate,
		args = {{name = "out", kind = .Path}},
		out = EXPORT_FIELDS,
		examples = {"slides --pdf /tmp/deck.pdf"},
		aliases = {"--pdf"},
		hidden = true,
		run = cmd_legacy_pdf,
	},
	{
		verb = "make-assets",
		summary = "regenerate the pictures the built-in deck uses, next to the binary",
		effect = .Mutate,
		out = ASSETS_FIELDS,
		examples = {"slides make-assets --json"},
		aliases = {"--make-assets"},
		hidden = true,
		run = cmd_make_assets,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun       = "slides",
			summary    = "a presentation editor",
			gui        = true,
			// `slides talk.json` opens the deck in the window.
			takes_path = true,
			selftest   = cli_selftest,
			notes      = SURFACE_NOTES,
			commands   = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `With no command, slides opens a window on the built-in deck; a path opens
that deck, and --collab <id|new> [--as NAME] [--offline] joins a shared one.
Presenting (F5) is the window's: it is a fullscreen overlay with no headless
equivalent beyond render and export.

Slides and elements are numbered from 1, as the sorter and the inspector show
them; an element may also be named title, subtitle or body. A read command
given no deck reads the built-in deck a fresh window opens with; @fixture
names it. Edits write the deck back in place; --dry-run prints the change and
writes nothing. The older --export, --pptx, --pdf, --shots and --make-assets
keep working.`

cli_selftest :: proc() -> int {
	return selftest(exe_directory())
}

// ---------------------------------------------------------------------------
// Loading and saving
// ---------------------------------------------------------------------------

// cli_load opens the deck a command names into a State with no window — the
// same State the window runs on. `optional` lets a read fall back to the
// built-in deck when no deck was given.
@(private = "file")
cli_load :: proc(c: ^kit.Call, name: string, optional := false) -> (st: ^St, label: string, code: int) {
	path := kit.cli_str(c, name)
	st = state_new(exe_directory())
	if (optional && path == "") || path == FIXTURE_LABEL {
		st.deck = fixture_deck()
		return st, FIXTURE_LABEL, kit.EXIT_OK
	}
	if !os.exists(path) {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
		kit.cli_err_field(c, "deck", path)
		return st, path, code
	}
	d, err := load_deck(path)
	if err != "" {
		return st, path, kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	st.deck = d
	st.path = strings.clone(path)
	return st, path, kit.EXIT_OK
}

// cli_save writes an edited deck back where it came from, unless this is a
// dry run, and fills in the fields every edit prints.
@(private = "file")
cli_save :: proc(c: ^kit.Call, st: ^St, label, action, detail: string) -> int {
	if label == FIXTURE_LABEL {
		return kit.cli_fail(c, kit.EXIT_USAGE, "the built-in deck cannot be edited; `slides new FILE --fixture` copies it")
	}
	written := false
	if !c.dry_run {
		if err := save_deck(&st.deck, label); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		written = true
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset_str(c.out, "action", action)
	kit.jset_int(c.out, "slide", st.slide + 1)
	if st.sel >= 0 {
		kit.jset_int(c.out, "element", st.sel + 1)
	}
	kit.jset_int(c.out, "slides", len(st.deck.slides))
	kit.jset_str(c.out, "detail", detail)
	kit.jset_bool(c.out, "written", written)
	return kit.EXIT_OK
}

// cli_slide turns a 1-based slide number into the State's current slide, the
// way pressing J and K would.
@(private = "file")
cli_slide :: proc(c: ^kit.Call, st: ^St, name: string) -> int {
	n := kit.cli_int(c, name, 0)
	if n < 1 || n > len(st.deck.slides) {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "the deck has %d slides; there is no slide %d", len(st.deck.slides), n)
		kit.cli_err_field(c, "slide", fmt.tprintf("%d", n))
		return code
	}
	st.slide = n - 1
	st.sel = -1
	return kit.EXIT_OK
}

// find_element resolves an element reference: a number from 1, or a role.
find_element :: proc(s: ^Slide, ref: string) -> int {
	if n, ok := strconv.parse_int(ref); ok {
		return n >= 1 && n <= len(s.elems) ? n - 1 : -1
	}
	want: []Style
	switch strings.to_lower(ref, context.temp_allocator) {
	case "title":
		want = {.Title}
	case "subtitle":
		want = {.Subtitle}
	case "body":
		want = {.Bullets, .Body}
	case:
		return -1
	}
	for w in want {
		for &e, i in s.elems {
			if e.kind == .Text && e.style == w {
				return i
			}
		}
	}
	return -1
}

// cli_element selects the element a command names, as Tab would.
@(private = "file")
cli_element :: proc(c: ^kit.Call, st: ^St, ref: string) -> int {
	s := cur_slide(st)
	i := find_element(s, ref)
	if i < 0 {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "slide %d has no element %q (it has %d)", st.slide + 1, ref, len(s.elems))
		kit.cli_err_field(c, "element", ref)
		return code
	}
	st.sel = i
	return kit.EXIT_OK
}

// unescape lets a one-line argument carry lines: `\n` is a new line, `\\` a
// backslash.
@(private = "file")
unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
				i += 1
				continue
			case '\\':
				strings.write_byte(&b, '\\')
				i += 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

LAYOUT_WORDS := [Layout]string {
	.Title          = "title",
	.Title_Content  = "title-content",
	.Two_Content    = "two-content",
	.Section_Header = "section",
	.Picture        = "picture",
	.Blank          = "blank",
}

// LAYOUT_CMDS are the keys 1 to 6: a layout change on the command line is the
// same `invoke` pressing the digit is.
LAYOUT_CMDS := [Layout]Cmd {
	.Title          = .Layout_Title,
	.Title_Content  = .Layout_Title_Content,
	.Two_Content    = .Layout_Two,
	.Section_Header = .Layout_Section,
	.Picture        = .Layout_Picture,
	.Blank          = .Layout_Blank,
}

layout_of_word :: proc(w: string) -> (Layout, bool) {
	for name, l in LAYOUT_WORDS {
		if name == w {
			return l, true
		}
	}
	return .Title_Content, false
}

@(private = "file")
slot_word :: proc(v: u32) -> string {
	return paint_label(v)
}

@(private = "file")
hex_rgb :: proc(v: u32) -> string {
	return fmt.tprintf("#%06x", v & 0xffffff)
}

@(private = "file")
words_in :: proc(s: string) -> int {
	n := 0
	in_word := false
	for i in 0 ..< len(s) {
		c := s[i]
		space := c == ' ' || c == '\n' || c == '\t' || c == '\r'
		if !space && !in_word {
			n += 1
		}
		in_word = !space
	}
	return n
}

@(private = "file")
want_slide :: proc(c: ^kit.Call, st: ^St) -> (lo, hi: int, code: int) {
	if !kit.cli_has(c, "slide") {
		return 0, len(st.deck.slides), kit.EXIT_OK
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return 0, 0, e
	}
	return st.slide, st.slide + 1, kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

@(private = "file")
cmd_info :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck", true)
	if code != kit.EXIT_OK {
		return code
	}
	elements, words, notes_words, pictures := 0, 0, 0, 0
	outline := kit.jarr()
	for &s, i in st.deck.slides {
		elements += len(s.elems)
		notes_words += words_in(s.notes)
		for &e in s.elems {
			if e.kind == .Text {
				words += words_in(e.text)
			}
			if e.kind == .Image {
				pictures += 1
			}
		}
		o := kit.jobj()
		kit.jset_int(o, "slide", i + 1)
		kit.jset_str(o, "layout", LAYOUT_WORDS[s.layout])
		kit.jset_str(o, "title", slide_title(&s))
		kit.jset_int(o, "elements", len(s.elems))
		kit.jset_bool(o, "has_notes", strings.trim_space(s.notes) != "")
		kit.jpush(outline, o)
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset_str(c.out, "title", st.deck.title)
	kit.jset_str(c.out, "author", st.deck.author)
	kit.jset_str(c.out, "theme", st.deck.theme.name)
	kit.jset_int(c.out, "slides", len(st.deck.slides))
	kit.jset_int(c.out, "elements", elements)
	kit.jset_int(c.out, "words", words)
	kit.jset_int(c.out, "notes_words", notes_words)
	kit.jset_int(c.out, "pictures", pictures)
	kit.jset(c.out, "outline", outline)
	return kit.EXIT_OK
}

@(private = "file")
cmd_outline :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck", true)
	if code != kit.EXIT_OK {
		return code
	}
	list := kit.jarr()
	for &s, i in st.deck.slides {
		o := kit.jobj()
		kit.jset_int(o, "slide", i + 1)
		kit.jset_str(o, "layout", LAYOUT_WORDS[s.layout])
		// One line, for a table: the sorter shows the first line too.
		t := slide_title(&s)
		if nl := strings.index_byte(t, '\n'); nl >= 0 {
			t = fmt.tprintf("%s %s", t[:nl], strings.trim_space(t[nl + 1:]))
		}
		kit.jset_str(o, "title", t)
		kit.jpush(list, o)
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset(c.out, "slides", list)
	return kit.EXIT_OK
}

@(private = "file")
cmd_text :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck", true)
	if code != kit.EXIT_OK {
		return code
	}
	lo, hi, e := want_slide(c, st)
	if e != kit.EXIT_OK {
		return e
	}
	list := kit.jarr()
	for si in lo ..< hi {
		s := &st.deck.slides[si]
		o := kit.jobj()
		kit.jset_int(o, "slide", si + 1)
		kit.jset_str(o, "title", slide_title(s))
		texts := kit.jarr()
		for &el, i in s.elems {
			if el.kind != .Text {
				continue
			}
			t := kit.jobj()
			kit.jset_int(t, "element", i + 1)
			kit.jset_str(t, "style", strings.to_lower(STYLE_NAMES[el.style], context.temp_allocator))
			kit.jset_str(t, "text", el.text)
			kit.jpush(texts, t)
		}
		kit.jset(o, "texts", texts)
		kit.jpush(list, o)
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset(c.out, "slides", list)
	return kit.EXIT_OK
}

@(private = "file")
cmd_notes :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck", true)
	if code != kit.EXIT_OK {
		return code
	}
	lo, hi, e := want_slide(c, st)
	if e != kit.EXIT_OK {
		return e
	}
	list := kit.jarr()
	for si in lo ..< hi {
		s := &st.deck.slides[si]
		o := kit.jobj()
		kit.jset_int(o, "slide", si + 1)
		kit.jset_str(o, "title", slide_title(s))
		kit.jset_str(o, "notes", s.notes)
		kit.jpush(list, o)
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset(c.out, "slides", list)
	return kit.EXIT_OK
}

@(private = "file")
cmd_show :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck", true)
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	s := cur_slide(st)
	list := kit.jarr()
	for &el, i in s.elems {
		o := kit.jobj()
		kit.jset_int(o, "element", i + 1)
		kit.jset_str(o, "kind", strings.to_lower(fmt.tprintf("%v", el.kind), context.temp_allocator))
		kit.jset_str(o, "label", elem_label(&el))
		kit.jset_num(o, "x", f64(el.x))
		kit.jset_num(o, "y", f64(el.y))
		kit.jset_num(o, "w", f64(el.w))
		kit.jset_num(o, "h", f64(el.h))
		kit.jset_num(o, "rotation", f64(el.rotation))
		kit.jset_num(o, "opacity", f64(el.opacity))
		kit.jset_str(o, "fill", slot_word(elem_colour(&el)))
		kit.jset_str(o, "stroke", slot_word(el.stroke))
		switch el.kind {
		case .Text:
			kit.jset_str(o, "text", el.text)
			kit.jset_str(o, "style", strings.to_lower(STYLE_NAMES[el.style], context.temp_allocator))
			kit.jset_bool(o, "bold", el.bold)
		case .Image:
			kit.jset_str(o, "src", el.src)
		case .Rect, .Ellipse, .Line, .Arrow:
		}
		kit.jpush(list, o)
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset_int(c.out, "slide", st.slide + 1)
	kit.jset_str(c.out, "layout", LAYOUT_WORDS[s.layout])
	kit.jset_str(c.out, "title", slide_title(s))
	kit.jset_str(c.out, "notes", s.notes)
	kit.jset(c.out, "elements", list)
	return kit.EXIT_OK
}

@(private = "file")
cmd_themes :: proc(c: ^kit.Call) -> int {
	list := kit.jarr()
	for th in THEMES {
		o := kit.jobj()
		kit.jset_str(o, "name", th.name)
		kit.jset_bool(o, "dark", th.dark)
		kit.jset_bool(o, "mono", th.mono)
		kit.jset_str(o, "background", hex_rgb(th.bg))
		kit.jset_str(o, "accent", hex_rgb(th.accent))
		kit.jpush(list, o)
	}
	layouts := kit.jarr()
	for w in LAYOUT_WORDS {
		kit.jpush(layouts, kit.jstr(w))
	}
	kit.jset(c.out, "themes", list)
	kit.jset(c.out, "layouts", layouts)
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Edits
// ---------------------------------------------------------------------------

@(private = "file")
cmd_new :: proc(c: ^kit.Call) -> int {
	path := kit.cli_str(c, "deck")
	if os.exists(path) && !kit.cli_bool(c, "force") {
		return kit.cli_failf(c, kit.EXIT_USAGE, "%s is already there; pass --force to overwrite it", path)
	}
	th, ok := theme_by_name(kit.cli_str(c, "theme"))
	if !ok {
		code := kit.cli_failf(c, kit.EXIT_USAGE, "there is no theme %q; `slides themes` lists them", kit.cli_str(c, "theme"))
		kit.cli_err_field(c, "theme", kit.cli_str(c, "theme"))
		return code
	}
	d: Deck
	if kit.cli_bool(c, "fixture") {
		d = fixture_deck()
	} else {
		d = Deck {
			version = DECK_VERSION,
			title   = "Untitled deck",
			slides  = make([dynamic]Slide),
		}
		// A new deck is the window's first slide: one Title layout, its
		// placeholders filled from the flags.
		slide_add(&d, 0, .Title)
		s := &d.slides[0]
		if kit.cli_has(c, "title") {
			if i := find_element(s, "title"); i >= 0 {
				elem_set_text(&s.elems[i], unescape(kit.cli_str(c, "title")))
			}
		}
		if kit.cli_has(c, "subtitle") {
			if i := find_element(s, "subtitle"); i >= 0 {
				elem_set_text(&s.elems[i], unescape(kit.cli_str(c, "subtitle")))
			}
		}
	}
	d.theme = th
	if kit.cli_has(c, "title") {
		d.title = strings.clone(kit.cli_str(c, "title"))
	}
	if kit.cli_has(c, "author") {
		d.author = strings.clone(kit.cli_str(c, "author"))
	}
	if !c.dry_run {
		if err := save_deck(&d, path); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
	}
	kit.jset_str(c.out, "deck", path)
	kit.jset_str(c.out, "title", d.title)
	kit.jset_str(c.out, "theme", d.theme.name)
	kit.jset_int(c.out, "slides", len(d.slides))
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}

@(private = "file")
cmd_add :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	after := kit.cli_int(c, "after", len(st.deck.slides))
	if after < 0 || after > len(st.deck.slides) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "the deck has %d slides; cannot add after %d", len(st.deck.slides), after)
	}
	layout, _ := layout_of_word(kit.cli_str(c, "layout"))
	// M adds a Title + Content slide after the current one; a digit then
	// changes its layout. After slide 0 is "at the start", which M cannot do
	// from the keyboard, so that one case adds and moves it up.
	st.slide = max(after - 1, 0)
	invoke(st, nil, nil, .Slide_New)
	if after == 0 {
		invoke(st, nil, nil, .Slide_Up)
	}
	if layout != .Title_Content {
		invoke(st, nil, nil, LAYOUT_CMDS[layout])
	}
	s := cur_slide(st)
	if kit.cli_has(c, "title") {
		if i := find_element(s, "title"); i >= 0 {
			elem_set_text(&s.elems[i], unescape(kit.cli_str(c, "title")))
		} else {
			return kit.cli_failf(c, kit.EXIT_USAGE, "a %s slide has no title box", LAYOUT_WORDS[layout])
		}
	}
	if kit.cli_has(c, "body") {
		i := find_element(s, "body")
		if i < 0 {
			i = find_element(s, "subtitle")
		}
		if i < 0 {
			return kit.cli_failf(c, kit.EXIT_USAGE, "a %s slide has no body box", LAYOUT_WORDS[layout])
		}
		elem_set_text(&s.elems[i], unescape(kit.cli_str(c, "body")))
	}
	if kit.cli_has(c, "notes") {
		slide_set_notes(s, unescape(kit.cli_str(c, "notes")))
	}
	return cli_save(c, st, label, "add", fmt.tprintf("a %s slide at %d", LAYOUT_NAMES[layout], st.slide + 1))
}

@(private = "file")
cmd_duplicate :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	from := st.slide + 1
	invoke(st, nil, nil, .Slide_Dup)
	return cli_save(c, st, label, "duplicate", fmt.tprintf("slide %d copied to %d", from, st.slide + 1))
}

@(private = "file")
cmd_move :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	to := kit.cli_int(c, "to")
	if to < 1 || to > len(st.deck.slides) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "the deck has %d slides; there is no position %d", len(st.deck.slides), to)
	}
	from := st.slide + 1
	// One Shift J or Shift K per step, exactly as the keyboard does it.
	for st.slide + 1 < to {
		invoke(st, nil, nil, .Slide_Down)
	}
	for st.slide + 1 > to {
		invoke(st, nil, nil, .Slide_Up)
	}
	return cli_save(c, st, label, "move", fmt.tprintf("slide %d moved to %d", from, st.slide + 1))
}

@(private = "file")
cmd_layout :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	l, _ := layout_of_word(kit.cli_str(c, "layout"))
	invoke(st, nil, nil, LAYOUT_CMDS[l])
	return cli_save(c, st, label, "layout", fmt.tprintf("slide %d is now %s", st.slide + 1, LAYOUT_NAMES[l]))
}

@(private = "file")
cmd_set_text :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	if e := cli_element(c, st, kit.cli_str(c, "element")); e != kit.EXIT_OK {
		return e
	}
	el := cur_elem(st)
	if el.kind != .Text {
		// What Enter says about a shape.
		return kit.cli_failf(c, kit.EXIT_USAGE, "element %d is a %s, which has no text", st.sel + 1, KIND_NAMES[el.kind])
	}
	elem_set_text(el, unescape(kit.cli_str(c, "text")))
	return cli_save(c, st, label, "set-text", fmt.tprintf("slide %d element %d", st.slide + 1, st.sel + 1))
}

@(private = "file")
cmd_set_notes :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	slide_set_notes(cur_slide(st), unescape(kit.cli_str(c, "notes")))
	return cli_save(c, st, label, "set-notes", fmt.tprintf("slide %d", st.slide + 1))
}

INSERT_CMDS := [Kind]Cmd {
	.Text    = .Add_Text,
	.Rect    = .Add_Rect,
	.Ellipse = .Add_Ellipse,
	.Line    = .Add_Line,
	.Arrow   = .Add_Arrow,
	.Image   = .Add_Image,
}

@(private = "file")
cmd_insert :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	kind: Kind
	switch kit.cli_str(c, "kind") {
	case "text":
		kind = .Text
	case "rect":
		kind = .Rect
	case "ellipse":
		kind = .Ellipse
	case "line":
		kind = .Line
	case "arrow":
		kind = .Arrow
	case "image":
		kind = .Image
	}
	if kind != .Text && (kit.cli_has(c, "text") || kit.cli_has(c, "style")) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "--text and --style are for a text box, not a %s", kit.cli_str(c, "kind"))
	}
	if kind != .Image && kit.cli_has(c, "src") {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--src is for an image")
	}
	invoke(st, nil, nil, INSERT_CMDS[kind])
	el := cur_elem(st)
	if kind == .Text {
		// T leaves the box empty and editing; the command line commits the
		// text in one go, as Escape would.
		st.mode = .Browse
		elem_set_text(el, unescape(kit.cli_str(c, "text")))
		if kit.cli_has(c, "style") {
			for name, sty in STYLE_NAMES {
				if strings.equal_fold(name, kit.cli_str(c, "style")) {
					el.style = sty
				}
			}
		}
	}
	if kind == .Image && kit.cli_has(c, "src") {
		el.src = strings.clone(kit.cli_str(c, "src"))
	}
	if kit.cli_has(c, "left") {el.x = f32(kit.cli_f64(c, "left"))}
	if kit.cli_has(c, "top") {el.y = f32(kit.cli_f64(c, "top"))}
	if kit.cli_has(c, "width") {el.w = f32(kit.cli_f64(c, "width"))}
	if kit.cli_has(c, "height") {el.h = f32(kit.cli_f64(c, "height"))}
	normalise(el)
	return cli_save(c, st, label, "insert", fmt.tprintf("a %s on slide %d", KIND_NAMES[kind], st.slide + 1))
}

@(private = "file")
cmd_delete :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	if kit.cli_has(c, "element") {
		if e := cli_element(c, st, kit.cli_str(c, "element")); e != kit.EXIT_OK {
			return e
		}
		gone := st.sel + 1
		what := elem_label(cur_elem(st))
		invoke(st, nil, nil, .Elem_Del)
		st.sel = gone - 1 // reported as the element that was deleted
		return cli_save(c, st, label, "delete", fmt.tprintf("element %d (%s) of slide %d", gone, what, st.slide + 1))
	}
	if len(st.deck.slides) <= 1 {
		// What Shift X says.
		return kit.cli_fail(c, kit.EXIT_USAGE, "a deck needs at least one slide")
	}
	gone := st.slide + 1
	title := strings.clone(slide_title(cur_slide(st)), context.temp_allocator)
	invoke(st, nil, nil, .Slide_Del)
	return cli_save(c, st, label, "delete", fmt.tprintf("slide %d (%q)", gone, title))
}

@(private = "file")
cmd_theme :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	th, ok := theme_by_name(kit.cli_str(c, "name"))
	if !ok {
		code := kit.cli_failf(c, kit.EXIT_NOT_FOUND, "there is no theme %q; `slides themes` lists them", kit.cli_str(c, "name"))
		kit.cli_err_field(c, "theme", kit.cli_str(c, "name"))
		return code
	}
	was := st.deck.theme.name
	st.deck.theme = th
	return cli_save(c, st, label, "theme", fmt.tprintf("%s, was %s", th.name, was))
}

@(private = "file")
cmd_rename :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	st.deck.title = strings.clone(kit.cli_str(c, "title"))
	if kit.cli_has(c, "author") {
		st.deck.author = strings.clone(kit.cli_str(c, "author"))
	}
	return cli_save(c, st, label, "rename", st.deck.title)
}

// ---------------------------------------------------------------------------
// Pictures and files
// ---------------------------------------------------------------------------

@(private = "file")
cli_export :: proc(c: ^kit.Call, st: ^St, label, out: string, f: Export_Format) -> int {
	files := 0
	if !c.dry_run {
		fonts: p.Fonts
		fonts_headless(&fonts)
		n, err := deck_export(&st.deck, out, f, &fonts, &st.imgs)
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		files = n
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset_str(c.out, "out", out)
	kit.jset_str(c.out, "format", EXPORT_EXT[f])
	kit.jset_int(c.out, "slides", len(st.deck.slides))
	kit.jset_int(c.out, "files", files)
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}

@(private = "file")
cmd_export :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	out := kit.cli_str(c, "out")
	f := export_format_of(out)
	if kit.cli_has(c, "format") {
		for ext, ff in EXPORT_EXT {
			if ext == kit.cli_str(c, "format") {
				f = ff
			}
		}
	}
	return cli_export(c, st, label, out, f)
}

@(private = "file")
legacy :: proc(c: ^kit.Call, f: Export_Format) -> int {
	st := state_new(exe_directory())
	st.deck = fixture_deck()
	out := kit.cli_str(c, "out")
	if out == "" {
		out = f == .Png ? default_export_dir() : fmt.tprintf("%s/deck.%s", default_export_dir(context.temp_allocator), EXPORT_EXT[f])
	}
	return cli_export(c, st, FIXTURE_LABEL, out, f)
}

@(private = "file")
cmd_legacy_png :: proc(c: ^kit.Call) -> int {return legacy(c, .Png)}
@(private = "file")
cmd_legacy_pptx :: proc(c: ^kit.Call) -> int {return legacy(c, .Pptx)}
@(private = "file")
cmd_legacy_pdf :: proc(c: ^kit.Call) -> int {return legacy(c, .Pdf)}

@(private = "file")
cmd_render :: proc(c: ^kit.Call) -> int {
	st, label, code := cli_load(c, "deck")
	if code != kit.EXIT_OK {
		return code
	}
	if e := cli_slide(c, st, "slide"); e != kit.EXIT_OK {
		return e
	}
	w := kit.cli_int(c, "width", EXPORT_W)
	if w < 16 || w > 7680 {
		return kit.cli_failf(c, kit.EXIT_USAGE, "--width %d is outside 16..7680", w)
	}
	h := max(9, w * 9 / 16)
	out := kit.cli_str(c, "out")
	if !c.dry_run {
		fonts: p.Fonts
		fonts_headless(&fonts)
		px := render_slide_buffer(&st.deck, st.slide, w, h, &fonts, &st.imgs, context.temp_allocator)
		if slash := strings.last_index_byte(out, '/'); slash > 0 {
			_ = os.make_directory_all(out[:slash])
		}
		if !write_png(out, px, w, h) {
			return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", out)
		}
	}
	kit.jset_str(c.out, "deck", label)
	kit.jset_int(c.out, "slide", st.slide + 1)
	kit.jset_str(c.out, "out", out)
	kit.jset_int(c.out, "width", w)
	kit.jset_int(c.out, "height", h)
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}

@(private = "file")
cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := strings.clone(kit.cli_str(c, "dir"))
	// `shots` renders offscreen frames, and an offscreen frame frees the temp
	// allocator — where the kit keeps the parsed command line it reads again
	// for the audit record afterwards (TODO.md C3). Move it out first.
	argv := make([]string, len(c.argv))
	for a, i in c.argv {
		argv[i] = strings.clone(a)
	}
	c.argv = argv
	if !c.dry_run && shots(dir) != 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render the shots into %s", dir)
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset_bool(c.out, "written", !c.dry_run)
	return kit.EXIT_OK
}

@(private = "file")
cmd_make_assets :: proc(c: ^kit.Call) -> int {
	dir := fmt.tprintf("%s/assets", exe_directory())
	written := kit.jarr()
	if !c.dry_run {
		if e := make_assets(dir); e != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, e)
		}
	}
	for f in ([?]string{"vista.png", "bars.png"}) {
		kit.jpush(written, kit.jstr(fmt.tprintf("%s/%s", dir, f)))
	}
	kit.jset_str(c.out, "dir", dir)
	kit.jset(c.out, "written", written)
	return kit.EXIT_OK
}
