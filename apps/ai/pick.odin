package main

// Attaching a file to the message you are writing, through the shared file
// dialog in `kit`.
//
//   Ctrl Shift O   choose a file; its text is fenced into the composer
//
// Ctrl O is already "pull a model" here, and it keeps that meaning.
//
// There is no upload here and there could not be: this client talks to ollama
// on the loopback address and a chat request carries text. So "attach" means
// what it has to mean — the file's contents go into the prompt, fenced and
// labelled, where you can see exactly what the model will be given before you
// press Return. Nothing is sent by choosing a file.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

// A ceiling, because the whole file goes into the context window and a model
// with a 4k window handed a 10 MB log is a request that fails slowly and
// expensively. Large enough for any source file, small enough to notice.
ATTACH_MAX :: 256 * 1024

AI_FILTERS := [?]kit.Pick_Filter {
	kit.PICK_TEXT,
	{"Code", {"odin", "c", "h", "cpp", "hpp", "rs", "go", "py", "js", "ts", "tsx", "sh", "lua", "zig", "rb", "java"}},
	{"Data", {"json", "yaml", "yml", "toml", "xml", "ini", "conf", "csv", "tsv"}},
	kit.PICK_ALL,
}

begin_attach :: proc(st: ^St) {
	kit.pick_begin(
		&st.pick,
		.Open_File,
		{title = "Attach a File", filters = AI_FILTERS[:], confirm = "Attach"},
	)
}

pick_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	if !kit.pick_active(&st.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &st.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	if !res.ok {
		return
	}
	attach_file(st, res.path)
}

// attach_file reads a file into the composer. It refuses the two things that
// would otherwise go wrong quietly: something far too large for a context
// window, and something that is not text at all.
attach_file :: proc(st: ^St, path: string) {
	fi, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		toast(
			st,
			fmt.tprintf("could not read %s", kit.pick_base(path)))
		return
	}
	if fi.size > ATTACH_MAX {
		toast(
			st,
			fmt.tprintf(
				"%s is %s — too large to put in a prompt",
				kit.pick_base(path),
				kit.pick_size_text(fi.size),
			),
		)
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		toast(
			st,
			fmt.tprintf("could not read %s", kit.pick_base(path)))
		return
	}
	text := string(data)
	if strings.contains_rune(text, 0) {
		toast(
			st,
			fmt.tprintf("%s is not a text file", kit.pick_base(path)))
		return
	}

	// Fenced, with the extension as the language tag and the name above it,
	// so the model is told what it is looking at and so are you.
	sb := strings.builder_make(context.temp_allocator)
	if st.caret > 0 && len(st.input) > 0 && st.input[min(st.caret, len(st.input)) - 1] != '\n' {
		strings.write_string(&sb, "\n")
	}
	strings.write_string(&sb, fmt.tprintf("%s:\n```%s\n", kit.pick_base(path), kit.pick_ext(path)))
	strings.write_string(&sb, text)
	if !strings.has_suffix(text, "\n") {
		strings.write_string(&sb, "\n")
	}
	strings.write_string(&sb, "```\n")

	block := strings.to_string(sb)
	st.caret = clamp(st.caret, 0, len(st.input))
	inject_at_elems(&st.input, st.caret, ..transmute([]u8)block)
	st.caret += len(block)
	st.zone = .Composer
	toast(
			st,
			fmt.tprintf("attached %s (%s)", kit.pick_base(path), kit.pick_size_text(fi.size)),
	)
}
