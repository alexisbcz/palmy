package main

// Conversations, settings and the prompt library on disk, under
// ~/.local/share/palmy-ai/. Nothing here leaves the machine and nothing here
// is a database: one file per conversation, one record per line, so a
// conversation can be read with `cat` and deleted with `rm`.
//
// The record format is deliberately dull. Each line is `<tag> <payload>`, and
// the payload is escaped so that a message containing newlines, tabs or
// backslashes still occupies exactly one line. `store_escape` and
// `store_unescape` are each other's inverse for every byte sequence, which is
// what the self-test asserts.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Role :: enum u8 {
	User,
	Assistant,
	System,
}

Message :: struct {
	role:   Role,
	text:   string, // owned
	think:  string, // the model's reasoning block, when it produced one
	model:  string, // which model answered; empty for a user message
	// Measured facts about this reply, kept so the transcript still shows them
	// after a reload.
	ttft:   f64,
	tps:    f32,
	in_n:   int,
	out_n:  int,
	halted: bool, // the user stopped this one mid-stream
}

Conversation :: struct {
	id:      string,
	title:   string,
	model:   string,
	created: i64,
	msgs:    [dynamic]Message,
	dirty:   bool,
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

data_dir :: proc(allocator := context.allocator) -> string {
	if xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator); xdg != "" {
		return strings.concatenate({xdg, "/palmy-ai"}, allocator)
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return strings.clone("/tmp/palmy-ai", allocator)
	}
	return strings.concatenate({home, "/.local/share/palmy-ai"}, allocator)
}

chats_dir :: proc(allocator := context.allocator) -> string {
	d := data_dir(context.temp_allocator)
	return strings.concatenate({d, "/conversations"}, allocator)
}

ensure_dirs :: proc() {
	_ = os.make_directory_all(chats_dir(context.temp_allocator))
}

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

store_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

store_unescape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case 't':
				strings.write_byte(&b, '\t')
			case '\\':
				strings.write_byte(&b, '\\')
			case:
				strings.write_byte(&b, s[i + 1])
			}
			i += 2
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Serialising a conversation
// ---------------------------------------------------------------------------

conv_serialise :: proc(c: ^Conversation, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "palmy-ai 1\n")
	fmt.sbprintf(&b, "id %s\n", c.id)
	fmt.sbprintf(&b, "title %s\n", store_escape(c.title, context.temp_allocator))
	fmt.sbprintf(&b, "model %s\n", c.model)
	fmt.sbprintf(&b, "created %d\n", c.created)
	for m in c.msgs {
		role := "user"
		switch m.role {
		case .User:
			role = "user"
		case .Assistant:
			role = "assistant"
		case .System:
			role = "system"
		}
		fmt.sbprintf(
			&b,
			"msg %s %s %.4f %.3f %d %d %d %s\n",
			role,
			m.model == "" ? "-" : m.model,
			m.ttft,
			m.tps,
			m.in_n,
			m.out_n,
			m.halted ? 1 : 0,
			store_escape(m.text, context.temp_allocator),
		)
		if m.think != "" {
			fmt.sbprintf(&b, "think %s\n", store_escape(m.think, context.temp_allocator))
		}
	}
	return strings.to_string(b)
}

conv_parse :: proc(text: string, allocator := context.allocator) -> (c: Conversation, ok: bool) {
	c.msgs = make([dynamic]Message, allocator)
	it := text
	line_no := 0
	for line in strings.split_lines_iterator(&it) {
		line_no += 1
		if line_no == 1 {
			if !strings.has_prefix(line, "palmy-ai ") {
				return c, false
			}
			continue
		}
		sp := strings.index_byte(line, ' ')
		if sp < 0 {
			continue
		}
		tag := line[:sp]
		rest := line[sp + 1:]
		switch tag {
		case "id":
			c.id = strings.clone(rest, allocator)
		case "title":
			c.title = store_unescape(rest, allocator)
		case "model":
			c.model = strings.clone(rest, allocator)
		case "created":
			c.created, _ = strconv.parse_i64(rest)
		case "think":
			if len(c.msgs) > 0 {
				c.msgs[len(c.msgs) - 1].think = store_unescape(rest, allocator)
			}
		case "msg":
			// role model ttft tps in out halted text…
			f := rest
			role_s, f1 := cut(f)
			model_s, f2 := cut(f1)
			ttft_s, f3 := cut(f2)
			tps_s, f4 := cut(f3)
			in_s, f5 := cut(f4)
			out_s, f6 := cut(f5)
			halt_s, body := cut(f6)

			m: Message
			switch role_s {
			case "assistant":
				m.role = .Assistant
			case "system":
				m.role = .System
			case:
				m.role = .User
			}
			m.model = model_s == "-" ? "" : strings.clone(model_s, allocator)
			m.ttft, _ = strconv.parse_f64(ttft_s)
			tps, _ := strconv.parse_f32(tps_s)
			m.tps = tps
			m.in_n, _ = strconv.parse_int(in_s)
			m.out_n, _ = strconv.parse_int(out_s)
			m.halted = halt_s == "1"
			m.text = store_unescape(body, allocator)
			append(&c.msgs, m)
		}
	}
	if c.id == "" {
		return c, false
	}
	return c, true
}

@(private = "file")
cut :: proc(s: string) -> (head, tail: string) {
	sp := strings.index_byte(s, ' ')
	if sp < 0 {
		return s, ""
	}
	return s[:sp], s[sp + 1:]
}

conv_path :: proc(id: string, allocator := context.allocator) -> string {
	d := chats_dir(context.temp_allocator)
	return fmt.aprintf("%s/%s.chat", d, id, allocator = allocator)
}

conv_save :: proc(c: ^Conversation) -> bool {
	ensure_dirs()
	text := conv_serialise(c, context.temp_allocator)
	path := conv_path(c.id, context.temp_allocator)
	werr := os.write_entire_file(path, transmute([]u8)text)
	if werr == nil {
		c.dirty = false
	}
	return werr == nil
}

conv_delete_file :: proc(id: string) {
	path := conv_path(id, context.temp_allocator)
	_ = os.remove(path)
}

// conv_load_all reads every conversation, newest first.
conv_load_all :: proc(allocator := context.allocator) -> [dynamic]Conversation {
	out := make([dynamic]Conversation, allocator)
	dir := chats_dir(context.temp_allocator)
	fd, err := os.open(dir)
	if err != nil {
		return out
	}
	defer os.close(fd)
	infos, rerr := os.read_dir(fd, -1, context.temp_allocator)
	if rerr != nil {
		return out
	}
	for info in infos {
		if !strings.has_suffix(info.name, ".chat") {
			continue
		}
		data, derr := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		if derr != nil {
			continue
		}
		c, ok := conv_parse(string(data), allocator)
		if ok {
			append(&out, c)
		}
	}
	// Newest first.
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && out[j].created > out[j - 1].created {
			out[j], out[j - 1] = out[j - 1], out[j]
			j -= 1
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

settings_path :: proc(allocator := context.allocator) -> string {
	d := data_dir(context.temp_allocator)
	return strings.concatenate({d, "/settings.conf"}, allocator)
}

settings_save :: proc(model: string, pr: Params, show_think: bool) {
	ensure_dirs()
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "model %s\n", model)
	fmt.sbprintf(&b, "temperature %.4f\n", pr.temperature)
	fmt.sbprintf(&b, "top_p %.4f\n", pr.top_p)
	fmt.sbprintf(&b, "num_predict %d\n", pr.num_predict)
	fmt.sbprintf(&b, "think %d\n", pr.think ? 1 : 0)
	fmt.sbprintf(&b, "show_reasoning %d\n", show_think ? 1 : 0)
	fmt.sbprintf(&b, "system %s\n", store_escape(pr.system, context.temp_allocator))
	_ = os.write_entire_file(
		settings_path(context.temp_allocator),
		transmute([]u8)strings.to_string(b),
	)
}

settings_load :: proc(model: ^string, pr: ^Params, show_think: ^bool) {
	path := settings_path(context.temp_allocator)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		sp := strings.index_byte(line, ' ')
		if sp < 0 {
			continue
		}
		k, v := line[:sp], line[sp + 1:]
		switch k {
		case "model":
			model^ = strings.clone(v)
		case "temperature":
			f, _ := strconv.parse_f32(v)
			pr.temperature = f
		case "top_p":
			f, _ := strconv.parse_f32(v)
			pr.top_p = f
		case "num_predict":
			n, _ := strconv.parse_int(v)
			pr.num_predict = n
		case "think":
			pr.think = v == "1"
		case "show_reasoning":
			show_think^ = v == "1"
		case "system":
			pr.system = store_unescape(v)
		}
	}
}

// ---------------------------------------------------------------------------
// The prompt library
// ---------------------------------------------------------------------------

Prompt :: struct {
	name: string,
	body: string,
}

prompts_path :: proc(allocator := context.allocator) -> string {
	d := data_dir(context.temp_allocator)
	return strings.concatenate({d, "/prompts.txt"}, allocator)
}

DEFAULT_PROMPTS := [?]Prompt {
	{"Explain simply", "Explain this as if to a competent beginner, in no more than five sentences:\n\n"},
	{"Code review", "Review this code for correctness bugs. Be specific and terse. Do not restate the code.\n\n"},
	{"Shell one-liner", "Give me a single POSIX shell command that does this, and one line explaining it:\n\n"},
	{"Summarise", "Summarise the following in three bullet points:\n\n"},
	{"Name things", "Suggest five short, concrete names for this, with a two-word reason each:\n\n"},
	{"Odin idiom", "I am writing Odin. Show the idiomatic way to do this, with no imports I do not need:\n\n"},
}

prompts_load :: proc(allocator := context.allocator) -> [dynamic]Prompt {
	out := make([dynamic]Prompt, allocator)
	data, err := os.read_entire_file_from_path(
		prompts_path(context.temp_allocator),
		context.temp_allocator,
	)
	if err != nil {
		for p in DEFAULT_PROMPTS {
			append(&out, Prompt{strings.clone(p.name, allocator), strings.clone(p.body, allocator)})
		}
		return out
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		tab := strings.index_byte(line, '\t')
		if tab <= 0 {
			continue
		}
		append(
			&out,
			Prompt {
				store_unescape(line[:tab], allocator),
				store_unescape(line[tab + 1:], allocator),
			},
		)
	}
	return out
}

prompts_save :: proc(ps: []Prompt) {
	ensure_dirs()
	b := strings.builder_make(context.temp_allocator)
	for p in ps {
		fmt.sbprintf(
			&b,
			"%s\t%s\n",
			store_escape(p.name, context.temp_allocator),
			store_escape(p.body, context.temp_allocator),
		)
	}
	_ = os.write_entire_file(
		prompts_path(context.temp_allocator),
		transmute([]u8)strings.to_string(b),
	)
}

// ---------------------------------------------------------------------------
// Ids and titles
// ---------------------------------------------------------------------------

new_id :: proc(seed: i64, allocator := context.allocator) -> string {
	// Monotonic and sortable; two conversations made in the same second get
	// different ids from the counter.
	ID_COUNTER += 1
	return fmt.aprintf("%d-%03d", seed, ID_COUNTER % 1000, allocator = allocator)
}

ID_COUNTER := 0

// title_from derives a conversation's title from its first user message, the
// way every chat client does.
title_from :: proc(text: string, allocator := context.allocator) -> string {
	t := strings.trim_space(text)
	if t == "" {
		return strings.clone("New conversation", allocator)
	}
	// First line, first 42 characters, cut on a rune boundary.
	if nl := strings.index_byte(t, '\n'); nl > 0 {
		t = t[:nl]
	}
	if len(t) > 42 {
		cut := 42
		for cut > 0 && t[cut] & 0xc0 == 0x80 {
			cut -= 1
		}
		return strings.concatenate({t[:cut], "…"}, allocator)
	}
	return strings.clone(t, allocator)
}
