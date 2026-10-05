// Importing `TODO.md`.
//
// This repository's tracker today is one Markdown file, and the import exists
// to prove the format can hold it without losing anything that mattered about
// it. Round-tripping a real document is a harder test of a file format than
// any fixture, because the document was not written with the format in mind.
//
// The mapping, which follows the shape `TODO.md` actually has:
//
//   * A `#` heading is a **project** — `Toolkit`, `The command surface`,
//     `Applications`, `Packages`, `The long work`. It also becomes a label,
//     slugged, so `track list --label toolkit` works without knowing about
//     projects at all.
//   * A `##` heading is an **issue**. `## T1 — Wake the frame loop` gives the
//     id `T1` and the title `Wake the frame loop`; a heading with no id
//     prefix gets one generated from the project.
//   * A `> **Prompt.**` blockquote is the issue's **prompt**, unindented, with
//     the leading `**Prompt.**` dropped since the field already says so.
//   * `# Known-unfixed, deliberately` holds no `##` headings at all — it is a
//     bullet list, each bullet a decision. Each `- **thing**` bullet becomes
//     an issue in the `wontfix` state, because that is exactly what they are
//     and writing them anywhere else would lose the distinction between "not
//     done" and "decided against".
//   * `## How to use a prompt from this file` is the standing rules, not a
//     piece of work. It is imported as an issue in `wontfix`, labelled
//     `convention`, because the three false claims this whole feature exists
//     for live inside it and it has to be verifiable like everything else.
//
// Nothing in here executes a verify command, writes to `TODO.md`, or invents
// a dependency. Dependencies are an assertion about the world and the file
// makes almost none: see `import_links`, which only draws an edge where one
// issue names another's id in its text.
package main

import "core:fmt"
import "core:strings"

Import_Stats :: struct {
	projects: int,
	issues:   int,
	prompts:  int,
	wontfix:  int,
	links:    int,
	skipped:  int,
}

// heading_level is the number of leading '#' on a line, 0 for anything else.
// It deliberately ignores headings inside a fenced block, which the caller
// tracks, because `TODO.md`'s prompts contain shell and Odin samples.
heading_level :: proc(line: string) -> (level: int, text: string) {
	i := 0
	for i < len(line) && line[i] == '#' {
		i += 1
	}
	if i == 0 || i > 6 || i >= len(line) || line[i] != ' ' {
		return 0, ""
	}
	return i, strings.trim_space(line[i:])
}

// split_id pulls `T1` off the front of `T1 — Wake the frame loop`. The
// separator in this file is an em dash, but a hyphen and a colon are accepted
// too since the next person to write one will use whichever is on their
// keyboard.
split_id :: proc(heading: string) -> (id, title: string, ok: bool) {
	for sep in ([?]string{" — ", " -- ", " – ", " - ", ": "}) {
		if at := strings.index(heading, sep); at > 0 {
			cand := strings.trim_space(heading[:at])
			if looks_like_id(cand) {
				return cand, strings.trim_space(heading[at + len(sep):]), true
			}
			return "", heading, false
		}
	}
	return "", heading, false
}

// looks_like_id is letters then digits: T1, C2, ENG-14 is not one and is not
// meant to be. Being strict here is what stops `## Toolkit 2024` becoming an
// issue with the id `Toolkit`.
looks_like_id :: proc(s: string) -> bool {
	if len(s) < 2 || len(s) > 8 {
		return false
	}
	i := 0
	for i < len(s) && s[i] >= 'A' && s[i] <= 'Z' {
		i += 1
	}
	if i == 0 || i == len(s) {
		return false
	}
	for j in i ..< len(s) {
		if s[j] < '0' || s[j] > '9' {
			return false
		}
	}
	return true
}

// strip_quote unindents a blockquote: `> text` becomes `text`, and a bare `>`
// becomes an empty line, so paragraph breaks inside a prompt survive.
strip_quote :: proc(block: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	rest := block
	first := true
	for line in strings.split_lines_iterator(&rest) {
		t := line
		trimmed := strings.trim_left_space(t)
		if strings.has_prefix(trimmed, ">") {
			t = trimmed[1:]
			if strings.has_prefix(t, " ") {
				t = t[1:]
			}
		}
		if !first {
			strings.write_byte(&sb, '\n')
		}
		first = false
		strings.write_string(&sb, strings.trim_right_space(t))
	}
	return strings.trim_space(strings.to_string(sb))
}

PROMPT_MARKS := [?]string{"**Prompt.**", "**Prompt**", "**Prompt** (one group at a time).", "Prompt."}

// drop_prompt_mark removes the `**Prompt.**` lead-in, keeping any
// parenthetical that followed it — `**Prompt** (adapt the group).` keeps the
// instruction and loses only the word that the field name already carries.
drop_prompt_mark :: proc(s: string, allocator := context.temp_allocator) -> string {
	t := s
	if strings.has_prefix(t, "**Prompt**") {
		t = t[len("**Prompt**"):]
	} else if strings.has_prefix(t, "**Prompt.**") {
		t = t[len("**Prompt.**"):]
	} else {
		return strings.clone(strings.trim_space(t), allocator)
	}
	t = strings.trim_left_space(t)
	// `(adapt the group). Bring ...` -> keep the note, drop the dangling dot.
	if strings.has_prefix(t, ".") {
		t = strings.trim_left_space(t[1:])
	}
	return strings.clone(strings.trim_space(t), allocator)
}

// import_todo parses a `TODO.md`-shaped document into issues. It is pure: it
// reads a string and returns issues, writing nothing, so the self-test drives
// it on fixtures and `track import --dry-run` drives it on the real file.
//
// The issue under construction is tracked by INDEX, not by pointer. `out` is
// a dynamic array and appending to it reallocates; a `^Issue` held across an
// append is a dangling pointer, and this parser appends in the middle of
// accumulating a body.
import_todo :: proc(text: string, states: []State_Def) -> (out: [dynamic]Issue, stats: Import_Stats) {
	out = make([dynamic]Issue, 0, 64)

	project := ""
	project_label := ""
	wontfix_section := false

	cur := -1
	body := strings.builder_make(context.temp_allocator)
	prompt := strings.builder_make(context.temp_allocator)
	in_prompt := false
	in_fence := false

	// Headings with no id of their own get one AFTERWARDS, from a pass that
	// can see every explicit id in the document. Numbering them as they are
	// met collides: `## How to use a prompt from this file` sits under `#
	// TODO`, would be numbered T1, and `## T1 — Wake the frame loop` would
	// then be the second issue with that id. The tracker would have silently
	// merged two unrelated things.
	// The marker is carried ON the issue rather than in a parallel list of
	// indices. A section issue that turns out to be unnecessary is popped,
	// and a later issue takes its index — so an index recorded earlier would
	// then be pointing at somebody else's issue. It did: "The long work" was
	// dropped and "Known-unfixed, deliberately" inherited its id.
	AUTO :: "\x01"

	// A `#` section opens a provisional issue for the section itself, which
	// is thrown away again the moment the section turns out to have `##`
	// headings or bullets of its own. Three of `TODO.md`'s sections —
	// Packages, Applications and The long work — carry a `> **Prompt.**`
	// directly under the `#` and have no sub-headings at all, and without
	// this they import as nothing: the prompt, which is the most valuable
	// thing in the document, would be silently dropped.
	sect := -1

	wontfix_state := "wontfix"
	if !state_known(states, wontfix_state) {
		// The configured states may not have one. Fall back to the last
		// closed state rather than inventing a name the board cannot show.
		wontfix_state = ""
		for s in states {
			if s.closed {
				wontfix_state = s.name
			}
		}
		if wontfix_state == "" && len(states) > 0 {
			wontfix_state = states[len(states) - 1].name
		}
	}

	// drop_section throws the provisional section issue away, and is called
	// from exactly the two places that prove it was not needed: a `##`
	// heading, and a bullet in the Known-unfixed list. A section with
	// children of its own is a heading; a section with none — Packages,
	// Applications, The long work — is the issue, and keeps its prompt.
	//
	// It is always the most recent entry when this runs, so popping is
	// enough. Nothing holds an index into `out` across this.
	drop_section :: proc(out: ^[dynamic]Issue, sect: ^int, stats: ^Import_Stats) {
		if sect^ >= 0 && sect^ == len(out) - 1 {
			it := &out[sect^]
			if it.prompt != "" {
				stats.prompts -= 1
			}
			issue_free(it)
			pop(out)
			stats.issues -= 1
		}
		sect^ = -1
	}

	finish :: proc(out: ^[dynamic]Issue, cur: ^int, body, prompt: ^strings.Builder, stats: ^Import_Stats) {
		if cur^ >= 0 {
			it := &out[cur^]
			if it.body == "" {
				it.body = strings.clone(strings.trim_space(strings.to_string(body^)))
			}
			it.prompt = strings.clone(strings.trim_space(strings.to_string(prompt^)))
			if it.prompt != "" {
				stats.prompts += 1
			}
		}
		strings.builder_reset(body)
		strings.builder_reset(prompt)
		cur^ = -1
	}

	begin :: proc(out: ^[dynamic]Issue, id, title, project, label, state: string, stats: ^Import_Stats) -> int {
		labels := make([]string, label == "" ? 0 : 1)
		if label != "" {
			labels[0] = strings.clone(label)
		}
		stamp := now_stamp(context.allocator)
		append(
			out,
			Issue {
				id = strings.clone(id),
				title = strings.clone(title),
				state = strings.clone(state),
				project = strings.clone(project),
				labels = labels,
				deps = make([]string, 0),
				extra_k = make([]string, 0),
				extra_v = make([]string, 0),
				body = "",
				prompt = "",
				created = stamp,
				updated = strings.clone(stamp),
			},
		)
		stats.issues += 1
		return len(out) - 1
	}

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if fence_toggle(line) {
			in_fence = !in_fence
			if in_prompt {
				strings.write_string(&prompt, strings.trim_right_space(line))
				strings.write_byte(&prompt, '\n')
			} else if cur >= 0 {
				strings.write_string(&body, strings.trim_right_space(line))
				strings.write_byte(&body, '\n')
			}
			continue
		}

		if !in_fence {
			level, head := heading_level(line)
			if level == 1 {
				finish(&out, &cur, &body, &prompt, &stats)
				sect = -1
				in_prompt = false
				project = strings.clone(head, context.temp_allocator)
				project_label = slug(head, context.temp_allocator)
				wontfix_section = strings.has_prefix(head, "Known-unfixed")
				stats.projects += 1
				// The provisional section issue. If the section turns out to
				// have `##` headings, this is dropped again below.
				cur = begin(
					&out,
					fmt.tprintf("%s%s", AUTO, import_prefix(project)),
					head,
					project,
					project_label,
					"todo",
					&stats,
				)
				sect = cur
				continue
			}
			if level == 2 {
				finish(&out, &cur, &body, &prompt, &stats)
				drop_section(&out, &sect, &stats)
				in_prompt = false
				id, title, has_id := split_id(head)
				// The standing rules are not a piece of work, but the three
				// false claims this whole feature exists for live inside
				// them, so they are imported and have to be verifiable like
				// anything else.
				convention := strings.has_prefix(head, "How to use a prompt")
				state := "todo"
				label := project_label
				if wontfix_section || convention {
					state = wontfix_state
					stats.wontfix += 1
				}
				if convention {
					label = "convention"
				}
				if !has_id {
					id = fmt.tprintf("%s%s", AUTO, import_prefix(project))
				}
				cur = begin(&out, id, title, project, label, state, &stats)
				continue
			}
		}

		// `Known-unfixed, deliberately` has no `##` headings at all: it is a
		// bullet list, and each `- **thing**` bullet is its own decision.
		// They become issues in a closed state, because "decided against" is
		// not the same as "not done". A bullet ends the previous bullet,
		// which is why this is checked before the `cur < 0` branch rather
		// than inside it — the second bullet in a list was otherwise read as
		// more body text for the first.
		if wontfix_section && !in_fence {
			t := strings.trim_left_space(line)
			if strings.has_prefix(t, "- **") {
				if end := strings.index(t[4:], "**"); end > 0 {
					finish(&out, &cur, &body, &prompt, &stats)
					drop_section(&out, &sect, &stats)
					in_prompt = false
					{
						title := strings.trim_space(t[4:4 + end])
						cur = begin(
							&out,
							fmt.tprintf("%sK", AUTO),
							title,
							project,
							project_label,
							wontfix_state,
							&stats,
						)
						stats.wontfix += 1
						tail := strings.trim_space(t[4 + end + 2:])
						tail = strings.trim_space(strings.trim_left(tail, "—- "))
						strings.write_string(&body, tail)
						strings.write_byte(&body, '\n')
					}
					continue
				}
			}
		}

		if cur < 0 {
			// Prose between a `#` heading and the first `##` under it, and
			// the preamble at the top of the file.
			if !in_fence && strings.trim_space(line) != "" {
				stats.skipped += 1
			}
			continue
		}

		// Inside an issue.
		trimmed := strings.trim_left_space(line)
		is_quote := strings.has_prefix(trimmed, ">")
		if !in_fence && is_quote && !in_prompt {
			inner := strings.trim_space(trimmed[1:])
			for mark in PROMPT_MARKS {
				if strings.has_prefix(inner, mark) {
					in_prompt = true
					break
				}
			}
		}
		if in_prompt {
			if is_quote || strings.trim_space(line) == "" || in_fence {
				strings.write_string(&prompt, strings.trim_right_space(line))
				strings.write_byte(&prompt, '\n')
				continue
			}
			// A non-quoted, non-blank line ends the blockquote.
			in_prompt = false
		}
		strings.write_string(&body, strings.trim_right_space(line))
		strings.write_byte(&body, '\n')
	}
	finish(&out, &cur, &body, &prompt, &stats)

	// Now the ids nobody wrote down, numbered around the ones somebody did.
	taken := make(map[string]bool, len(out) * 2, context.temp_allocator)
	for it in out {
		if !strings.has_prefix(it.id, AUTO) {
			taken[it.id] = true
		}
	}
	nextn := make(map[string]int, 8, context.temp_allocator)
	for &it in out {
		if !strings.has_prefix(it.id, AUTO) {
			continue
		}
		prefix := it.id[len(AUTO):]
		n := nextn[prefix]
		id: string
		for {
			n += 1
			id = fmt.tprintf("%s%d", prefix, n)
			if !taken[id] {
				break
			}
		}
		nextn[prefix] = n
		taken[id] = true
		dfree(it.id)
		it.id = strings.clone(id)
	}

	// The prompt was accumulated as a blockquote; unindent it and drop the
	// `**Prompt.**` lead-in now that the field name carries it.
	for &it in out {
		if it.prompt == "" {
			continue
		}
		un := strip_quote(it.prompt, context.temp_allocator)
		cleaned := drop_prompt_mark(un, context.allocator)
		delete(it.prompt)
		it.prompt = cleaned
	}
	// A bullet-derived issue never went through `finish` with its body in the
	// builder, so sweep up anything still empty.
	for &it in out {
		if it.body == "" {
			it.body = strings.clone("")
		}
	}
	return out, stats
}

// import_prefix picks an id prefix for a heading with no id of its own, from
// the project it sits under: `Applications` -> `A`, `Packages` -> `P`.
import_prefix :: proc(project: string) -> string {
	if project == "" {
		return "I"
	}
	c := project[0]
	if c >= 'a' && c <= 'z' {
		c -= 32
	}
	if c < 'A' || c > 'Z' {
		return "I"
	}
	return fmt.tprintf("%c", rune(c))
}

// import_links draws the only dependency edges the document actually
// supports: one issue naming another's id in its prose. `TODO.md` is almost
// free of these — which is itself the finding, and the reason the headline
// view is empty until somebody says what waits for what.
//
// Inference is kept this narrow on purpose. A tracker that guesses
// dependencies produces a graph that looks authoritative and is fiction, and
// fiction in the blocking graph is the most expensive kind.
import_links :: proc(issues: ^[dynamic]Issue) -> int {
	n := 0
	for &it in issues {
		found := make([dynamic]string, 0, 4)
		for other in issues {
			if other.id == it.id || !looks_like_id(other.id) {
				continue
			}
			if mentions_id(it.body, other.id) || mentions_id(it.prompt, other.id) {
				append(&found, strings.clone(other.id))
			}
		}
		if len(found) > 0 {
			delete(it.deps)
			it.deps = found[:]
			n += len(found)
		} else {
			delete(found)
		}
	}
	return n
}

// mentions_id looks for an id as a whole word: `T6` matches in "section T6"
// and "T6's table", and does not match inside `T60` or `WT6`.
mentions_id :: proc(text, id: string) -> bool {
	at := 0
	for {
		idx := strings.index(text[at:], id)
		if idx < 0 {
			return false
		}
		i := at + idx
		before_ok := i == 0 || !is_word_byte(text[i - 1])
		j := i + len(id)
		after_ok := j >= len(text) || !is_word_byte(text[j])
		if before_ok && after_ok {
			return true
		}
		at = i + 1
		if at >= len(text) {
			return false
		}
	}
}

is_word_byte :: proc(c: u8) -> bool {
	return(
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '_' \
	)
}
