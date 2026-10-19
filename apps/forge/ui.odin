// The window.
//
// Left, the identities this session can act as and their repositories;
// across the top, which identity you are acting as, in its colour, with how
// the session came to be scoped. The repository pages are the familiar ones —
// code, commits, issues, pull requests with a diff review, activity,
// settings — and every number on them comes from the same procedures the
// command line calls (client.odin).
//
// Keys: 1-6 tabs, j/k move, Enter open, Backspace up/back, r reload, n new
// repository, t tokens, q quit.
package main

import "core:encoding/json"
import "core:fmt"
import "base:runtime"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import wire "forge:wire"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

tfmt :: fmt.tprintf

Screen :: enum {
	Repo,
	New_Repo,
	Tokens,
	Activity,
}

Tab :: enum {
	Code,
	Commits,
	Issues,
	Pulls,
	Activity,
	Settings,
}

TAB_NAMES := [Tab]string {
	.Code     = "Code",
	.Commits  = "Commits",
	.Issues   = "Issues",
	.Pulls    = "Pull requests",
	.Activity = "Activity",
	.Settings = "Settings",
}

Pull_View :: enum {
	Conversation,
	Files,
}

App :: struct {
	cl:          Client,
	err:         string, // why there is no session, shown instead of content
	toast:       string,
	dark:        bool,
	screen:      Screen,
	tab:         Tab,

	// session-lifetime data
	keep:        vmem.Arena,
	identities:  json.Value,
	repos:       json.Value,
	repo_i:      int,

	// page data, thrown away on navigation
	page:        vmem.Arena,
	repo:        json.Value,
	ref:         Repo_Ref,
	path:        string, // directory or file shown in Code
	tree:        json.Value,
	blob:        json.Value,
	blob_toks:   [][dynamic]Token,
	blob_lines:  []string,
	readme:      json.Value,
	commits:     json.Value,
	commit:      json.Value, // the commit open in Commits
	commit_diff: []Diff_File,
	items:       json.Value, // issues or pulls
	item:        json.Value, // the one open
	comments:    json.Value,
	reviews:     json.Value,
	compare:     json.Value,
	pull_diff:   []Diff_File,
	pull_view:   Pull_View,
	events:      json.Value,
	collabs:     json.Value,
	tokens:      json.Value,
	new_token:   string,
	sel:         int,

	// inputs
	comment_buf: [dynamic]u8,
	name_buf:    [dynamic]u8,
	desc_buf:    [dynamic]u8,
	grant_buf:   [dynamic]u8,
	token_buf:   [dynamic]u8,
	new_vis:     string,
	new_owner:   int,
	new_readme:  bool,
	grant_role:  string,
	token_scope: string,
	want_quit:   bool,
	fields:      map[u64]bool, // element ids of the text inputs, so keys know when someone is typing
}

// field is a text input whose id is remembered: a letter typed into it must
// not also move the selection.
field :: proc(ui: ^p.Ctx, a: ^App, buf: ^[dynamic]u8, placeholder, class: string) {
	at := p.node_count(ui)
	if strings.contains(class, "h-[") {
		p.text_area(ui, buf, placeholder, class)
	} else {
		p.text_field(ui, buf, placeholder, class)
	}
	id := p.node_id(ui, at)
	if id not_in a.fields {
		a.fields[id] = true
	}
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

app_init :: proc(a: ^App) {
	a.fields = make(map[u64]bool, runtime.heap_allocator())
	_ = vmem.arena_init_growing(&a.keep)
	_ = vmem.arena_init_growing(&a.page)
	a.new_vis = "private"
	a.grant_role = "read"
	a.token_scope = "read"
	a.new_readme = true
	cl, err := client_open(os.get_env("PALM_IDENTITY", context.temp_allocator))
	a.cl = cl
	a.err = err
	load_session(a)
}

load_session :: proc(a: ^App) {
	vmem.arena_free_all(&a.keep)
	context.allocator = vmem.arena_allocator(&a.keep)
	if a.err != "" {
		return
	}
	a.identities = my_identities(&a.cl).value
	r := list_repos(&a.cl)
	a.repos = r.value
	if !wire.ok(r) {
		a.err = r.err
	}
	a.repo_i = clamp(a.repo_i, 0, max(len(wire.arr(a.repos)) - 1, 0))
}

// open_repo_page loads the selected repository and the current tab.
load_page :: proc(a: ^App) {
	vmem.arena_free_all(&a.page)
	context.allocator = vmem.arena_allocator(&a.page)
	a.tree, a.blob, a.readme, a.commits, a.commit, a.items, a.item = nil, nil, nil, nil, nil, nil, nil
	a.comments, a.reviews, a.compare, a.events, a.collabs, a.tokens = nil, nil, nil, nil, nil, nil
	a.commit_diff, a.pull_diff, a.blob_toks, a.blob_lines = nil, nil, nil, nil
	switch a.screen {
	case .Tokens:
		a.tokens = list_tokens(&a.cl).value
		return
	case .Activity:
		a.events = list_events(&a.cl, "", 40).value
		return
	case .New_Repo:
		return
	case .Repo:
	}
	repos := wire.arr(a.repos)
	if len(repos) == 0 {
		a.repo = nil
		return
	}
	a.repo = repos[a.repo_i]
	a.ref = Repo_Ref{strings.clone(wire.str(a.repo, "owner_handle")), strings.clone(wire.str(a.repo, "name"))}
	switch a.tab {
	case .Code:
		a.tree = get_tree(&a.cl, a.ref, "", a.path).value
		if a.tree == nil || wire.get(a.tree, "entries") == nil {
			// a file, not a directory
			a.tree = get_tree(&a.cl, a.ref, "", parent_dir(a.path)).value
			open_blob(a, a.path)
		} else {
			for e in wire.arr(a.tree, "entries") {
				if strings.to_lower(wire.str(e, "name"), context.temp_allocator) == "readme.md" {
					a.readme = get_blob(&a.cl, a.ref, "", join_path(a.path, wire.str(e, "name"))).value
				}
			}
		}
	case .Commits:
		a.commits = get_commits(&a.cl, a.ref, "", 60).value
	case .Issues, .Pulls:
		a.items = list_issues(&a.cl, wire.str(a.repo, "id"), a.tab == .Pulls, "all").value
	case .Activity:
		a.events = list_events(&a.cl, wire.str(a.repo, "id"), 40).value
	case .Settings:
		a.collabs = list_collaborators(&a.cl, wire.str(a.repo, "id")).value
	}
}

open_blob :: proc(a: ^App, path: string) {
	a.blob = get_blob(&a.cl, a.ref, "", path).value
	text := wire.str(a.blob, "text")
	a.blob_lines = strings.split_lines(text)
	if len(a.blob_lines) > 0 && a.blob_lines[len(a.blob_lines) - 1] == "" {
		a.blob_lines = a.blob_lines[:len(a.blob_lines) - 1]
	}
	lang := lang_detect(path, a.blob_lines[0] if len(a.blob_lines) > 0 else "")
	n := min(len(a.blob_lines), 600)
	a.blob_toks = make([][dynamic]Token, n)
	st := Lex_State{}
	for i in 0 ..< n {
		a.blob_toks[i] = make([dynamic]Token)
		st = lex_line(a.blob_lines[i], st, &a.blob_toks[i], lang)
	}
}

open_item :: proc(a: ^App, row: json.Value) {
	context.allocator = vmem.arena_allocator(&a.page)
	a.item = row
	a.comments = list_comments(&a.cl, wire.str(row, "id")).value
	if wire.flag(row, "is_pull") {
		a.reviews = list_reviews(&a.cl, wire.str(row, "id")).value
		if wire.is_null(row, "merged_at") {
			a.compare = get_compare(&a.cl, a.ref, wire.str(row, "base_ref"), wire.str(row, "head_ref")).value
			a.pull_diff = parse_diff(wire.str(a.compare, "diff"))
		} else {
			c := get_commit(&a.cl, a.ref, wire.str(row, "merged_sha")).value
			a.compare = nil
			a.pull_diff = parse_diff(wire.str(c, "diff"))
		}
	}
}

open_commit :: proc(a: ^App, sha: string) {
	context.allocator = vmem.arena_allocator(&a.page)
	a.commit = get_commit(&a.cl, a.ref, sha).value
	a.commit_diff = parse_diff(wire.str(a.commit, "diff"))
}

parent_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return "" if i < 0 else path[:i]
}

join_path :: proc(dir, name: string) -> string {
	return strings.clone(name) if dir == "" else fmt.aprintf("%s/%s", dir, name)
}

go_repo :: proc(a: ^App, i: int, tab := Tab.Code) {
	a.screen = .Repo
	a.repo_i = i
	a.tab = tab
	a.path = ""
	a.sel = 0
	load_page(a)
}

// ---------------------------------------------------------------------------
// Small pieces
// ---------------------------------------------------------------------------

// identity colours are Tailwind palette names; `slate` is the fallback.
hue :: proc(color: string) -> string {
	return color if color != "" else "slate"
}

dot :: proc(ui: ^p.Ctx, color: string, size := "size-2.5") {
	p.div(ui, tfmt("%s rounded-full shrink-0 bg-%s-500", size, hue(color)))
	p.end(ui)
}

btn :: proc(ui: ^p.Ctx, label: string, v := sc.Variant.Outline, s := sc.Size.SM, ic: Maybe(p.Icon) = nil, disabled := false) -> bool {
	idx := sc.button_open(ui, v, s, sc.State{disabled = disabled})
	p.focusable(ui)
	if i, ok := ic.?; ok {
		p.icon(ui, i, "size-3.5")
	}
	if label != "" {
		p.text(ui, label, "whitespace-nowrap")
		p.style(ui).shrink = 0
	}
	sc.button_end(ui)
	return !disabled && p.activated(ui, idx)
}

pill :: proc(ui: ^p.Ctx, label, cls: string) {
	p.row(ui, tfmt("shrink-0 items-center px-2 py-0.5 rounded-full text-[11px] font-medium %s", cls))
	p.text(ui, label, "whitespace-nowrap")
	p.end(ui)
}

vis_pill :: proc(ui: ^p.Ctx, vis: string) {
	switch vis {
	case "public":
		pill(ui, "Public", "border border-emerald-600/30 text-emerald-700 dark:text-emerald-400")
	case "shared":
		pill(ui, "Shared with my identities", "border border-sky-600/30 text-sky-700 dark:text-sky-400")
	case:
		pill(ui, "Private", "border border-border text-muted-foreground")
	}
}

role_pill :: proc(ui: ^p.Ctx, role: string) {
	switch role {
	case "admin":
		pill(ui, "owner", "bg-primary/10 text-foreground")
	case "write":
		pill(ui, "write", "bg-amber-500/15 text-amber-700")
	case:
		pill(ui, "read", "bg-muted text-muted-foreground")
	}
}

short_sha :: proc(s: string) -> string {
	return s[:min(7, len(s))]
}

rel_time :: proc(iso: string) -> string {
	if iso == "" {
		return ""
	}
	t, n := time.rfc3339_to_time_utc(iso)
	if n == 0 {
		return iso[:min(10, len(iso))]
	}
	d := time.diff(t, time.now())
	s := int(time.duration_seconds(d))
	switch {
	case s < 60:
		return "just now"
	case s < 3600:
		return tfmt("%d min ago", s / 60)
	case s < 86400:
		return tfmt("%d h ago", s / 3600)
	case s < 86400 * 30:
		return tfmt("%d days ago", s / 86400)
	}
	return iso[:10]
}

human_size :: proc(n: int) -> string {
	switch {
	case n < 1024:
		return tfmt("%d B", n)
	case n < 1024 * 1024:
		return tfmt("%.1f KB", f64(n) / 1024)
	}
	return tfmt("%.1f MB", f64(n) / (1024 * 1024))
}

// The GitHub syntax hues, light and dark.
tok_color :: proc(k: Tok, dark: bool) -> string {
	if !dark {
		return tok_class(k)
	}
	switch k {
	case .Keyword:
		return "text-[#ff7b72]"
	case .Type:
		return "text-[#d2a8ff]"
	case .Builtin, .Number:
		return "text-[#79c0ff]"
	case .Str, .Rune_Lit, .Code:
		return "text-[#a5d6ff]"
	case .Comment:
		return "text-[#8b949e]"
	case .Directive, .Marker:
		return "text-[#ffa657]"
	case .Punct:
		return "text-[#c9d1d9]"
	case .Call:
		return "text-[#d2a8ff]"
	case .Decl:
		return "text-[#f0f6fc] font-semibold"
	case .Key, .Heading:
		return "text-[#79c0ff] font-semibold"
	case .Emph:
		return "text-[#c9d1d9] italic"
	case .Strong:
		return "text-[#f0f6fc] font-semibold"
	case .Link:
		return "text-[#58a6ff]"
	case .Plain:
		return "text-foreground"
	}
	return "text-foreground"
}

// code_line draws one line of source as coloured runs. Tabs are four spaces.
code_line :: proc(ui: ^p.Ctx, line: string, toks: []Token, dark: bool) {
	p.row(ui, "items-center min-w-0 overflow-hidden whitespace-pre")
	defer p.end(ui)
	if len(line) == 0 {
		p.text(ui, " ", "text-[12px] font-mono")
		return
	}
	at := 0
	run :: proc(ui: ^p.Ctx, s, cls: string) {
		if s == "" {
			return
		}
		t, _ := strings.replace_all(s, "\t", "    ", context.temp_allocator)
		p.text(ui, t, tfmt("text-[12px] font-mono whitespace-pre shrink-0 %s", cls))
	}
	for t in toks {
		if t.from > at {
			run(ui, line[at:t.from], "text-foreground")
		}
		run(ui, line[t.from:min(t.to, len(line))], tok_color(t.kind, dark))
		at = min(t.to, len(line))
	}
	if at < len(line) {
		run(ui, line[at:], "text-foreground")
	}
}

empty :: proc(ui: ^p.Ctx, ic: p.Icon, title, sub: string) {
	p.col(ui, "w-full items-center justify-center gap-2 py-16")
	p.row(ui, "size-10 rounded-xl bg-muted items-center justify-center")
	p.icon(ui, ic, "size-5 text-muted-foreground")
	p.end(ui)
	p.text(ui, title, "text-sm font-semibold")
	p.text(ui, sub, "text-xs text-muted-foreground max-w-[420] text-center")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

gui_main :: proc() {
	a := new(App)
	a.dark = os.get_env("PALM_DARK", context.temp_allocator) == "1"
	app_init(a)
	load_page(a)
	app, err := kit.start({title = "Forge", width = 1320, height = 860, app_id = "palmy-forge"}, a.dark)
	if err != "" {
		fmt.eprintln("forge:", err)
		os.exit(1)
	}
	defer p.destroy(app)
	for ui in p.frames(app) {
		keys(ui, a)
		frame(ui, a)
		if a.want_quit {
			p.quit_app(app)
		}
	}
}

keys :: proc(ui: ^p.Ctx, a: ^App) {
	if a.fields[p.focus_id(ui)] {
		return // typing in a field
	}
	for t, i in Tab {
		if p.shortcut(ui, u32('1' + i), {}) && a.screen == .Repo {
			a.tab = t
			a.sel = 0
			load_page(a)
		}
	}
	if p.shortcut(ui, 'j', {}) || p.shortcut(ui, p.KEY_DOWN, {}) {
		a.sel += 1
	}
	if p.shortcut(ui, 'k', {}) || p.shortcut(ui, p.KEY_UP, {}) {
		a.sel = max(a.sel - 1, 0)
	}
	if p.shortcut(ui, 'r', {}) {
		load_session(a)
		load_page(a)
	}
	if p.shortcut(ui, 'n', {}) {
		a.screen = .New_Repo
	}
	if p.shortcut(ui, 't', {}) {
		a.screen = .Tokens
		load_page(a)
	}
	if p.shortcut(ui, 'q', {}) {
		a.want_quit = true
	}
	if p.shortcut(ui, p.KEY_BACKSPACE, {}) {
		switch {
		case a.item != nil:
			a.item = nil
		case a.commit != nil:
			a.commit = nil
		case a.path != "":
			a.path = parent_dir(a.path)
			load_page(a)
		}
	}
}

acting :: proc(a: ^App) -> (handle, name, color, how: string) {
	ids := wire.arr(a.identities)
	switch a.cl.kind {
	case "token":
		for x in ids {
			if wire.str(x, "id") == a.cl.token_identity {
				return wire.str(x, "handle"), wire.str(x, "display_name"), wire.str(x, "color"), tfmt("%s token", a.cl.token_scope)
			}
		}
	case "scoped":
		if len(ids) > 0 {
			return wire.str(ids[0], "handle"), wire.str(ids[0], "display_name"), wire.str(ids[0], "color"), "scoped session"
		}
	case "session":
		if a.repo != nil && a.screen == .Repo {
			owner := wire.str(a.repo, "identity_id")
			for x in ids {
				if wire.str(x, "id") == owner {
					return wire.str(x, "handle"), wire.str(x, "display_name"), wire.str(x, "color"), "your account"
				}
			}
		}
		if len(ids) > 0 {
			return wire.str(ids[0], "handle"), wire.str(ids[0], "display_name"), wire.str(ids[0], "color"), "your account"
		}
	}
	return "anonymous", "Not signed in", "slate", "public repositories only"
}

frame :: proc(ui: ^p.Ctx, a: ^App) {
	context.allocator = context.temp_allocator
	p.col(ui, "w-full h-full bg-background text-foreground overflow-hidden")
	defer p.end(ui)

	handle, _, color, _ := acting(a)
	// A 3px band in the acting identity's colour: which self this window is,
	// at a glance, before reading anything.
	p.div(ui, tfmt("h-[3] w-full shrink-0 bg-%s-500", hue(color)))
	p.end(ui)
	_ = handle

	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	sidebar(ui, a)
	p.col(ui, "flex-1 min-w-0 h-full overflow-hidden")
	topbar(ui, a)
	p.col(ui, "flex-1 min-h-0 w-full overflow-y-auto")
	if a.err != "" {
		empty(ui, ICON_LOCK, "Not connected", a.err)
	} else {
		switch a.screen {
		case .Repo:
			repo_page(ui, a)
		case .New_Repo:
			new_repo_page(ui, a)
		case .Tokens:
			tokens_page(ui, a)
		case .Activity:
			p.col(ui, "w-full max-w-[960] px-8 py-6 gap-4")
			p.text(ui, "Activity", "text-xl font-semibold")
			p.text(ui, "Everything visible to the identity you are acting as.", "text-sm text-muted-foreground")
			feed(ui, a, a.events, true)
			p.end(ui)
		}
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

sidebar :: proc(ui: ^p.Ctx, a: ^App) {
	p.col(ui, "w-[264] shrink-0 h-full bg-sidebar border-r border-border overflow-hidden")
	defer p.end(ui)

	p.row(ui, "h-[52] shrink-0 items-center gap-2 px-4")
	p.row(ui, "size-7 rounded-lg bg-primary items-center justify-center")
	p.icon(ui, ICON_GIT_BRANCH, "size-4 text-primary-foreground")
	p.end(ui)
	p.col(ui, "gap-px")
	p.text(ui, "Forge", "text-sm font-semibold leading-tight")
	p.text(ui, "Palmy", "text-[10px] text-muted-foreground leading-tight")
	p.end(ui)
	p.spacer(ui)
	if btn(ui, "", .Ghost, .Icon_SM, ICON_PLUS) {
		a.screen = .New_Repo
	}
	p.end(ui)

	p.col(ui, "flex-1 min-h-0 overflow-y-auto px-2 pb-3 gap-4")
	ids := wire.arr(a.identities)
	repos := wire.arr(a.repos)
	shown := make(map[int]bool, context.temp_allocator)
	group :: proc(ui: ^p.Ctx, a: ^App, title, color, sub: string, repos: []json.Value, keep: proc(r: json.Value, key: string) -> bool, key: string, shown: ^map[int]bool) {
		any := false
		for r, i in repos {
			if keep(r, key) && !shown[i] {
				any = true
			}
		}
		if !any && sub == "" {
			return
		}
		p.col(ui, "gap-0.5")
		p.row(ui, "items-center gap-2 px-2 py-1")
		if color != "" {
			dot(ui, color, "size-2")
		}
		p.text(ui, title, "text-[12px] font-semibold text-muted-foreground")
		p.spacer(ui)
		if sub != "" {
			p.text(ui, sub, "text-[10px] text-muted-foreground/70")
		}
		p.end(ui)
		for r, i in repos {
			if !keep(r, key) || shown[i] {
				continue
			}
			shown[i] = true
			on := a.screen == .Repo && a.repo_i == i
			idx := p.row(ui, tfmt("items-center gap-2 px-2 py-1.5 rounded-md hover:bg-sidebar-accent %s", "bg-sidebar-accent" if on else ""))
			p.focusable(ui)
			p.icon(ui, ICON_LOCK if wire.str(r, "visibility") == "private" else (ICON_USERS if wire.str(r, "visibility") == "shared" else ICON_GLOBE), "size-3.5 text-muted-foreground shrink-0")
			p.text(ui, wire.str(r, "name"), tfmt("text-[13px] truncate min-w-0 %s", "font-medium" if on else ""))
			p.spacer(ui)
			if n := wire.num(r, "open_pulls"); n > 0 {
				p.textf(ui, "text-[10px] text-muted-foreground shrink-0", "%d PR", n)
			}
			p.end(ui)
			if p.activated(ui, idx) {
				go_repo(a, i)
			}
		}
		p.end(ui)
	}
	for x in ids {
		owned :: proc(r: json.Value, key: string) -> bool {return wire.str(r, "identity_id") == key}
		group(ui, a, wire.str(x, "handle"), wire.str(x, "color"), wire.str(x, "kind"), repos[:], owned, wire.str(x, "id"), &shown)
	}
	granted :: proc(r: json.Value, key: string) -> bool {return wire.str(r, "role") != "read" || wire.str(r, "visibility") != "public"}
	group(ui, a, "Shared with you", "", "", repos[:], granted, "", &shown)
	any_public :: proc(r: json.Value, key: string) -> bool {return true}
	group(ui, a, "Public", "", "", repos[:], any_public, "", &shown)
	p.end(ui)

	p.col(ui, "shrink-0 border-t border-border p-2 gap-0.5")
	nav :: proc(ui: ^p.Ctx, a: ^App, ic: p.Icon, label: string, s: Screen) {
		on := a.screen == s
		idx := p.row(ui, tfmt("items-center gap-2 px-2 py-1.5 rounded-md hover:bg-sidebar-accent %s", "bg-sidebar-accent" if on else ""))
		p.focusable(ui)
		p.icon(ui, ic, "size-4 text-muted-foreground")
		p.text(ui, label, "text-[13px]")
		p.end(ui)
		if p.activated(ui, idx) {
			a.screen = s
			load_page(a)
		}
	}
	nav(ui, a, ICON_ACTIVITY, "Activity", .Activity)
	nav(ui, a, ICON_KEY_ROUND, "Access tokens", .Tokens)
	p.end(ui)
}

topbar :: proc(ui: ^p.Ctx, a: ^App) {
	p.row(ui, "h-[52] shrink-0 w-full items-center gap-3 px-6 border-b border-border")
	defer p.end(ui)
	switch a.screen {
	case .Repo:
		if a.repo != nil {
			dot(ui, wire.str(a.repo, "owner_color"))
			p.text(ui, wire.str(a.repo, "owner_handle"), "text-sm text-muted-foreground")
			p.text(ui, "/", "text-sm text-muted-foreground/60")
			p.text(ui, wire.str(a.repo, "name"), "text-sm font-semibold")
			vis_pill(ui, wire.str(a.repo, "visibility"))
		}
	case .New_Repo:
		p.text(ui, "New repository", "text-sm font-semibold")
	case .Tokens:
		p.text(ui, "Personal access tokens", "text-sm font-semibold")
	case .Activity:
		p.text(ui, "Activity", "text-sm font-semibold")
	}
	p.spacer(ui)
	handle, name, color, how := acting(a)
	p.row(ui, "items-center gap-2 pl-1.5 pr-3 py-1 rounded-full border border-border")
	p.row(ui, tfmt("size-6 rounded-full items-center justify-center bg-%s-500", hue(color)))
	p.text(ui, strings.to_upper(handle[:1]), "text-[11px] font-semibold text-white")
	p.end(ui)
	p.col(ui, "gap-px")
	p.text(ui, tfmt("Acting as %s", handle), "text-xs font-medium leading-tight")
	p.text(ui, tfmt("%s · %s", name, how), "text-[10px] text-muted-foreground leading-tight")
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The repository page
// ---------------------------------------------------------------------------

repo_page :: proc(ui: ^p.Ctx, a: ^App) {
	if a.repo == nil {
		empty(ui, ICON_GIT_BRANCH, "No repositories yet", "Create one with the + button, or `forge repo create <name>`.")
		return
	}
	p.col(ui, "w-full px-8 pt-5 gap-4")
	if d := wire.str(a.repo, "description"); d != "" {
		p.text(ui, d, "text-sm text-muted-foreground")
	}
	// tabs
	p.row(ui, "w-full items-end gap-1 border-b border-border")
	for t, i in Tab {
		on := a.tab == t
		idx := p.row(ui, tfmt("items-center gap-2 px-3 py-2 border-b-2 %s", "border-primary" if on else "border-transparent hover:border-border"))
		p.focusable(ui)
		ic := [Tab]p.Icon{.Code = ICON_CODE, .Commits = ICON_GIT_COMMIT_HORIZONTAL, .Issues = ICON_CIRCLE_DOT, .Pulls = ICON_GIT_PULL_REQUEST, .Activity = ICON_ACTIVITY, .Settings = ICON_SETTINGS}
		p.icon(ui, ic[t], tfmt("size-4 %s", "text-foreground" if on else "text-muted-foreground"))
		p.text(ui, TAB_NAMES[t], tfmt("text-[13px] %s", "font-medium" if on else "text-muted-foreground"))
		count := 0
		if t == .Issues {
			count = wire.num(a.repo, "open_issues")
		} else if t == .Pulls {
			count = wire.num(a.repo, "open_pulls")
		}
		if count > 0 {
			p.row(ui, "px-1.5 rounded-full bg-muted")
			p.textf(ui, "text-[10px] font-medium text-muted-foreground", "%d", count)
			p.end(ui)
		}
		p.end(ui)
		if p.activated(ui, idx) {
			a.tab = t
			a.sel = 0
			load_page(a)
		}
		_ = i
	}
	p.spacer(ui)
	p.row(ui, "items-center gap-2 pb-2.5")
	p.text(ui, "your access", "text-[11px] text-muted-foreground")
	role_pill(ui, wire.str(a.repo, "role"))
	p.end(ui)
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full px-8 py-5 gap-4")
	defer p.end(ui)
	switch a.tab {
	case .Code:
		code_tab(ui, a)
	case .Commits:
		commits_tab(ui, a)
	case .Issues, .Pulls:
		if a.item != nil {
			item_page(ui, a)
		} else {
			items_tab(ui, a)
		}
	case .Activity:
		feed(ui, a, a.events, false)
	case .Settings:
		settings_tab(ui, a)
	}
}

code_tab :: proc(ui: ^p.Ctx, a: ^App) {
	if wire.flag(a.tree, "empty") {
		p.col(ui, "w-full rounded-xl border border-border p-6 gap-3")
		p.text(ui, "This repository is empty", "text-base font-semibold")
		p.text(ui, "Push an existing repository from the command line:", "text-sm text-muted-foreground")
		p.col(ui, "w-full rounded-lg bg-muted px-4 py-3 gap-1")
		p.text(ui, tfmt("git remote add origin %s", clone_url(&a.cl, a.ref)), "text-[12px] font-mono")
		p.text(ui, "git push -u origin main", "text-[12px] font-mono")
		p.end(ui)
		p.text(ui, "Use a personal access token as the password (Access tokens, in the sidebar).", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}
	// branch and path
	p.row(ui, "w-full items-center gap-2")
	p.row(ui, "items-center gap-1.5 px-2.5 py-1 rounded-md border border-border")
	p.icon(ui, ICON_GIT_BRANCH, "size-3.5 text-muted-foreground")
	p.text(ui, wire.str(a.tree, "ref"), "text-xs font-medium")
	p.icon(ui, ICON_CHEVRON_DOWN, "size-3 text-muted-foreground")
	p.end(ui)
	crumb := p.text(ui, wire.str(a.repo, "name"), "text-sm font-medium text-primary")
	p.focusable(ui, crumb)
	if p.activated(ui, crumb) {
		a.path = ""
		load_page(a)
	}
	acc := ""
	for seg in strings.split(a.path, "/", context.temp_allocator) {
		if seg == "" {
			continue
		}
		acc = seg if acc == "" else tfmt("%s/%s", acc, seg)
		p.text(ui, "/", "text-sm text-muted-foreground")
		p.text(ui, seg, "text-sm font-medium")
	}
	p.spacer(ui)
	p.row(ui, "items-center gap-2 px-2.5 py-1 rounded-md border border-border")
	p.icon(ui, ICON_COPY, "size-3.5 text-muted-foreground")
	p.text(ui, clone_url(&a.cl, a.ref), "text-[11px] font-mono text-muted-foreground whitespace-nowrap")
	p.end(ui)
	p.end(ui)

	if a.blob != nil {
		blob_view(ui, a)
		return
	}

	// the listing, under the last commit
	p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
	if lc := wire.get(a.tree, "last_commit"); lc != nil {
		p.row(ui, "w-full items-center gap-3 px-4 py-2.5 bg-muted/50 border-b border-border")
		p.row(ui, "size-5 rounded-full bg-muted-foreground/20 items-center justify-center")
		p.text(ui, strings.to_upper(wire.str(lc, "author_name")[:1]), "text-[9px] font-semibold")
		p.end(ui)
		p.text(ui, wire.str(lc, "author_name"), "text-[13px] font-medium shrink-0")
		p.text(ui, wire.str(lc, "summary"), "text-[13px] text-muted-foreground truncate min-w-0")
		p.spacer(ui)
		p.text(ui, short_sha(wire.str(lc, "sha")), "text-[11px] font-mono text-muted-foreground shrink-0")
		p.text(ui, rel_time(wire.str(lc, "authored_at")), "text-[11px] text-muted-foreground shrink-0")
		p.end(ui)
	}
	entries := wire.arr(a.tree, "entries")
	for e, i in entries {
		is_dir := wire.str(e, "type") == "tree"
		idx := p.row(ui, tfmt("w-full items-center gap-3 px-4 py-2 hover:bg-muted/50 %s %s", "border-t border-border" if i > 0 else "", "bg-muted/60" if a.sel == i else ""))
		p.focusable(ui)
		p.icon(ui, ICON_FOLDER if is_dir else ICON_FILE_TEXT, tfmt("size-4 shrink-0 %s", "text-sky-500" if is_dir else "text-muted-foreground"))
		p.text(ui, wire.str(e, "name"), "text-[13px]")
		p.spacer(ui)
		if !is_dir {
			p.text(ui, human_size(wire.num(e, "size")), "text-[11px] text-muted-foreground")
		}
		p.end(ui)
		if p.activated(ui, idx) || (a.sel == i && p.shortcut(ui, p.KEY_RETURN, {})) {
			a.path = join_path(a.path, wire.str(e, "name"))
			a.path = strings.clone(a.path, runtime.heap_allocator())
			load_page(a)
		}
	}
	p.end(ui)

	if a.readme != nil {
		p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
		p.row(ui, "w-full items-center gap-2 px-4 py-2.5 border-b border-border")
		p.icon(ui, ICON_FILE_TEXT, "size-4 text-muted-foreground")
		p.text(ui, wire.str(a.readme, "path"), "text-[13px] font-medium")
		p.end(ui)
		p.col(ui, "w-full px-6 py-5 gap-1.5")
		for line in strings.split_lines(wire.str(a.readme, "text"), context.temp_allocator) {
			switch {
			case strings.has_prefix(line, "# "):
				p.text(ui, line[2:], "text-xl font-semibold pb-1")
			case strings.has_prefix(line, "## "):
				p.text(ui, line[3:], "text-base font-semibold pt-2")
			case strings.has_prefix(line, "- "):
				p.row(ui, "gap-2 items-start")
				p.text(ui, "•", "text-sm text-muted-foreground")
				p.text(ui, line[2:], "text-sm")
				p.end(ui)
			case line == "":
				p.div(ui, "h-1")
				p.end(ui)
			case:
				p.text(ui, line, "text-sm leading-relaxed")
			}
		}
		p.end(ui)
		p.end(ui)
	}
}

blob_view :: proc(ui: ^p.Ctx, a: ^App) {
	p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
	defer p.end(ui)
	p.row(ui, "w-full items-center gap-3 px-4 py-2.5 bg-muted/50 border-b border-border")
	p.icon(ui, ICON_FILE_CODE, "size-4 text-muted-foreground")
	p.text(ui, wire.str(a.blob, "path"), "text-[13px] font-medium")
	p.textf(ui, "text-[11px] text-muted-foreground", "%d lines · %s", len(a.blob_lines), human_size(wire.num(a.blob, "size")))
	p.spacer(ui)
	lang := lang_detect(wire.str(a.blob, "path"), a.blob_lines[0] if len(a.blob_lines) > 0 else "")
	p.text(ui, lang_name(lang), "text-[11px] text-muted-foreground")
	p.end(ui)
	if wire.flag(a.blob, "binary") {
		empty(ui, ICON_FILE_TEXT, "Binary file", "Not shown. `forge cat` with --json gives its size; clone to read it.")
		return
	}
	p.row(ui, "w-full items-start py-2")
	p.col(ui, "shrink-0 items-end px-3 border-r border-border")
	for i in 0 ..< len(a.blob_toks) {
		p.textf(ui, "text-[12px] font-mono text-muted-foreground/60 leading-[20]", "%d", i + 1)
	}
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 px-4")
	for line, i in a.blob_lines[:len(a.blob_toks)] {
		p.row(ui, "h-[20] items-center")
		code_line(ui, line, a.blob_toks[i][:], a.dark)
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

commits_tab :: proc(ui: ^p.Ctx, a: ^App) {
	if a.commit != nil {
		c := a.commit
		p.col(ui, "w-full rounded-xl border border-border p-5 gap-2")
		msg := wire.str(c, "message")
		first, _, rest := strings.partition(msg, "\n")
		p.text(ui, first, "text-lg font-semibold")
		if r := strings.trim_space(rest); r != "" {
			p.text(ui, r, "text-sm text-muted-foreground whitespace-pre-wrap")
		}
		p.row(ui, "items-center gap-2 pt-1")
		p.text(ui, wire.str(c, "author_name"), "text-[13px] font-medium")
		p.text(ui, tfmt("committed %s", rel_time(wire.str(c, "authored_at"))), "text-[13px] text-muted-foreground")
		p.spacer(ui)
		p.text(ui, wire.str(c, "sha"), "text-[11px] font-mono text-muted-foreground")
		p.end(ui)
		p.end(ui)
		diff_view(ui, a, a.commit_diff, nil)
		return
	}
	list := wire.arr(a.commits, "commits")
	if len(list) == 0 {
		empty(ui, ICON_GIT_COMMIT_HORIZONTAL, "No commits yet", "Push a branch and its history appears here.")
		return
	}
	p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
	day := ""
	for c, i in list {
		d := wire.str(c, "authored_at")[:10]
		if d != day {
			day = d
			p.row(ui, tfmt("w-full px-4 py-2 bg-muted/50 %s", "border-t border-border" if i > 0 else ""))
			p.icon(ui, ICON_GIT_COMMIT_HORIZONTAL, "size-3.5 text-muted-foreground")
			p.text(ui, tfmt("Commits on %s", d), "text-[12px] text-muted-foreground pl-2")
			p.end(ui)
		}
		idx := p.row(ui, tfmt("w-full items-center gap-3 px-4 py-2.5 border-t border-border hover:bg-muted/40 %s", "bg-muted/60" if a.sel == i else ""))
		p.focusable(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, wire.str(c, "summary"), "text-[13px] font-medium truncate")
		p.text(ui, tfmt("%s committed %s", wire.str(c, "author_name"), rel_time(wire.str(c, "authored_at"))), "text-[11px] text-muted-foreground")
		p.end(ui)
		p.row(ui, "shrink-0 px-2 py-0.5 rounded-md border border-border")
		p.text(ui, short_sha(wire.str(c, "sha")), "text-[11px] font-mono")
		p.end(ui)
		p.end(ui)
		if p.activated(ui, idx) || (a.sel == i && p.shortcut(ui, p.KEY_RETURN, {})) {
			open_commit(a, wire.str(c, "sha"))
		}
	}
	p.end(ui)
}

// diff_view draws unified diffs, one card per file, with the review's line
// comments under the lines they are anchored to.
diff_view :: proc(ui: ^p.Ctx, a: ^App, files: []Diff_File, comments: json.Value) {
	adds, dels := 0, 0
	for f in files {
		adds += f.additions
		dels += f.deletions
	}
	p.row(ui, "w-full items-center gap-2")
	p.textf(ui, "text-[13px] font-medium", "%d file%s changed", len(files), "" if len(files) == 1 else "s")
	p.textf(ui, "text-[13px] font-medium text-emerald-600", "+%d", adds)
	p.textf(ui, "text-[13px] font-medium text-red-600", "−%d", dels)
	p.end(ui)
	for f in files {
		path := diff_path(f)
		lang := lang_for_path(path)
		p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
		p.row(ui, "w-full items-center gap-2 px-4 py-2 bg-muted/50 border-b border-border")
		p.icon(ui, ICON_FILE_CODE, "size-4 text-muted-foreground")
		p.text(ui, path, "text-[13px] font-medium font-mono")
		if f.status != "modified" {
			pill(ui, f.status, "bg-muted text-muted-foreground")
		}
		p.spacer(ui)
		p.textf(ui, "text-[11px] text-emerald-600", "+%d", f.additions)
		p.textf(ui, "text-[11px] text-red-600", "−%d", f.deletions)
		p.end(ui)
		toks := make([dynamic]Token, context.temp_allocator)
		for l in f.lines {
			bg, sign := "", " "
			switch l.kind {
			case .Add:
				bg, sign = "bg-emerald-500/10", "+"
			case .Del:
				bg, sign = "bg-red-500/10", "−"
			case .Hunk:
				bg = "bg-sky-500/10"
			case .Context:
			}
			p.row(ui, tfmt("w-full h-[20] items-center %s", bg))
			if l.kind == .Hunk {
				p.div(ui, "w-[104] shrink-0")
				p.end(ui)
				p.text(ui, l.text, "text-[11px] font-mono text-muted-foreground whitespace-nowrap")
				p.end(ui)
				continue
			}
			num :: proc(ui: ^p.Ctx, n: int) {
				p.row(ui, "w-[44] shrink-0 justify-end pr-2")
				if n > 0 {
					p.textf(ui, "text-[11px] font-mono text-muted-foreground/60", "%d", n)
				}
				p.end(ui)
			}
			num(ui, l.old_no)
			num(ui, l.new_no)
			p.text(ui, sign, tfmt("w-[16] shrink-0 text-[12px] font-mono %s", "text-emerald-600" if l.kind == .Add else ("text-red-600" if l.kind == .Del else "text-muted-foreground")))
			clear(&toks)
			lex_line(l.text, {}, &toks, lang)
			code_line(ui, l.text, toks[:], a.dark)
			p.end(ui)
			// line comments anchored here
			for cm in wire.arr(comments) {
				if wire.str(cm, "path") == path && wire.num(cm, "line") == l.new_no && l.kind != .Del && l.new_no > 0 {
					p.col(ui, "w-full px-4 py-2 bg-background border-y border-border")
					p.col(ui, "ml-[104] max-w-[640] rounded-lg border border-border p-3 gap-1")
					p.row(ui, "items-center gap-2")
					dot(ui, wire.str(cm, "author_color"), "size-2")
					p.text(ui, wire.str(cm, "author_handle"), "text-[12px] font-semibold")
					p.text(ui, rel_time(wire.str(cm, "created_at")), "text-[11px] text-muted-foreground")
					p.end(ui)
					p.text(ui, wire.str(cm, "body"), "text-[13px]")
					p.end(ui)
					p.end(ui)
				}
			}
		}
		p.end(ui)
	}
}

state_icon :: proc(ui: ^p.Ctx, row: json.Value) {
	merged := !wire.is_null(row, "merged_at")
	open := wire.str(row, "state") == "open"
	switch {
	case merged:
		p.icon(ui, ICON_GIT_MERGE, "size-4 text-violet-600 shrink-0")
	case wire.flag(row, "is_pull") && open:
		p.icon(ui, ICON_GIT_PULL_REQUEST, "size-4 text-emerald-600 shrink-0")
	case wire.flag(row, "is_pull"):
		p.icon(ui, ICON_GIT_PULL_REQUEST_CLOSED, "size-4 text-red-600 shrink-0")
	case open:
		p.icon(ui, ICON_CIRCLE_DOT, "size-4 text-emerald-600 shrink-0")
	case:
		p.icon(ui, ICON_CIRCLE_CHECK, "size-4 text-violet-600 shrink-0")
	}
}

state_badge :: proc(ui: ^p.Ctx, row: json.Value) {
	merged := !wire.is_null(row, "merged_at")
	open := wire.str(row, "state") == "open"
	label, cls, ic := "Open", "bg-emerald-600 text-white", ICON_CIRCLE_DOT
	switch {
	case merged:
		label, cls, ic = "Merged", "bg-violet-600 text-white", ICON_GIT_MERGE
	case !open:
		label, cls, ic = "Closed", "bg-red-600 text-white" if wire.flag(row, "is_pull") else "bg-violet-600 text-white", ICON_CIRCLE_CHECK
	case wire.flag(row, "is_pull"):
		ic = ICON_GIT_PULL_REQUEST
	}
	p.row(ui, tfmt("shrink-0 items-center gap-1.5 px-2.5 py-1 rounded-full %s", cls))
	p.icon(ui, ic, "size-3.5 text-white")
	p.text(ui, label, "text-xs font-medium")
	p.end(ui)
}

items_tab :: proc(ui: ^p.Ctx, a: ^App) {
	list := wire.arr(a.items)
	pulls := a.tab == .Pulls
	n_open, n_closed := 0, 0
	for x in list {
		if wire.str(x, "state") == "open" {
			n_open += 1
		} else {
			n_closed += 1
		}
	}
	p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
	p.row(ui, "w-full items-center gap-4 px-4 py-2.5 bg-muted/50")
	p.icon(ui, ICON_GIT_PULL_REQUEST if pulls else ICON_CIRCLE_DOT, "size-4")
	p.textf(ui, "text-[13px] font-medium", "%d Open", n_open)
	p.icon(ui, ICON_CHECK, "size-4 text-muted-foreground")
	p.textf(ui, "text-[13px] text-muted-foreground", "%d Closed", n_closed)
	p.end(ui)
	if len(list) == 0 {
		p.end(ui)
		empty(ui, ICON_GIT_PULL_REQUEST if pulls else ICON_CIRCLE_DOT, "Nothing here yet",
			"Push a branch and open a pull request with `forge pr create`." if pulls else "Open one with `forge issue create`.")
		return
	}
	for x, i in list {
		idx := p.row(ui, tfmt("w-full items-start gap-3 px-4 py-3 border-t border-border hover:bg-muted/40 %s", "bg-muted/60" if a.sel == i else ""))
		p.focusable(ui)
		p.col(ui, "pt-0.5")
		state_icon(ui, x)
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-1")
		p.row(ui, "items-center gap-2 min-w-0")
		p.text(ui, wire.str(x, "title"), "text-[14px] font-semibold truncate min-w-0")
		for l in wire.arr(x, "labels") {
			pill(ui, wire.str(l), "bg-primary/10 text-foreground")
		}
		p.end(ui)
		p.row(ui, "items-center gap-1.5")
		p.textf(ui, "text-[12px] text-muted-foreground", "#%d opened %s by", wire.num(x, "number"), rel_time(wire.str(x, "created_at")))
		dot(ui, wire.str(x, "author_color"), "size-2")
		p.text(ui, wire.str(x, "author_handle"), "text-[12px] text-muted-foreground font-medium")
		if pulls {
			p.row(ui, "items-center gap-1 ml-2 px-1.5 rounded bg-muted")
			p.text(ui, tfmt("%s → %s", wire.str(x, "head_ref"), wire.str(x, "base_ref")), "text-[11px] font-mono text-muted-foreground")
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)
		if n := wire.num(x, "comment_count"); n > 0 {
			p.row(ui, "items-center gap-1 shrink-0")
			p.icon(ui, ICON_MESSAGE_SQUARE, "size-3.5 text-muted-foreground")
			p.textf(ui, "text-[12px] text-muted-foreground", "%d", n)
			p.end(ui)
		}
		p.end(ui)
		if p.activated(ui, idx) || (a.sel == i && p.shortcut(ui, p.KEY_RETURN, {})) {
			open_item(a, x)
		}
	}
	p.end(ui)
}

comment_card :: proc(ui: ^p.Ctx, handle, color, when_, body: string, extra := "") {
	p.row(ui, "w-full items-start gap-3")
	p.row(ui, tfmt("size-8 shrink-0 rounded-full items-center justify-center bg-%s-500", hue(color)))
	p.text(ui, strings.to_upper(handle[:min(1, len(handle))]), "text-xs font-semibold text-white")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 rounded-xl border border-border overflow-hidden")
	p.row(ui, "w-full items-center gap-2 px-4 py-2 bg-muted/50 border-b border-border")
	p.text(ui, handle, "text-[13px] font-semibold")
	p.text(ui, when_, "text-[12px] text-muted-foreground")
	if extra != "" {
		p.spacer(ui)
		p.text(ui, extra, "text-[11px] text-muted-foreground")
	}
	p.end(ui)
	p.col(ui, "w-full px-4 py-3")
	p.text(ui, body if body != "" else "No description provided.", tfmt("text-[13px] leading-relaxed %s", "" if body != "" else "italic text-muted-foreground"))
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

item_page :: proc(ui: ^p.Ctx, a: ^App) {
	x := a.item
	pull := wire.flag(x, "is_pull")
	p.col(ui, "w-full gap-2 pb-2 border-b border-border")
	p.row(ui, "items-center gap-2")
	p.text(ui, wire.str(x, "title"), "text-2xl font-semibold")
	p.textf(ui, "text-2xl text-muted-foreground", "#%d", wire.num(x, "number"))
	p.end(ui)
	p.row(ui, "items-center gap-2")
	state_badge(ui, x)
	if pull {
		n := wire.num(a.compare, "ahead")
		verb := "merged" if !wire.is_null(x, "merged_at") else "wants to merge"
		p.text(ui, wire.str(x, "author_handle"), "text-[13px] font-semibold")
		if n > 0 {
			p.textf(ui, "text-[13px] text-muted-foreground", "%s %d commit%s into", verb, n, "" if n == 1 else "s")
		} else {
			p.textf(ui, "text-[13px] text-muted-foreground", "%s into", verb)
		}
		branch_chip(ui, wire.str(x, "base_ref"))
		p.text(ui, "from", "text-[13px] text-muted-foreground")
		branch_chip(ui, wire.str(x, "head_ref"))
	} else {
		p.textf(ui, "text-[13px] text-muted-foreground", "%s opened this %s · %d comment%s", wire.str(x, "author_handle"),
			rel_time(wire.str(x, "created_at")), wire.num(x, "comment_count"), "" if wire.num(x, "comment_count") == 1 else "s")
	}
	p.end(ui)
	p.end(ui)

	if pull {
		p.row(ui, "w-full items-end gap-1 border-b border-border")
		for v in Pull_View {
			on := a.pull_view == v
			label := "Conversation" if v == .Conversation else tfmt("Files changed  %d", len(a.pull_diff))
			idx := p.row(ui, tfmt("px-3 py-2 border-b-2 %s", "border-primary" if on else "border-transparent"))
			p.focusable(ui)
			p.text(ui, label, tfmt("text-[13px] %s", "font-medium" if on else "text-muted-foreground"))
			p.end(ui)
			if p.activated(ui, idx) {
				a.pull_view = v
			}
		}
		p.end(ui)
		if a.pull_view == .Files {
			review_comments := make(json.Array, context.temp_allocator)
			for cm in wire.arr(a.comments) {
				if wire.str(cm, "path") != "" {
					append(&review_comments, cm)
				}
			}
			diff_view(ui, a, a.pull_diff, review_comments)
			return
		}
	}

	p.row(ui, "w-full items-start gap-6")
	p.col(ui, "flex-1 min-w-0 gap-4")
	comment_card(ui, wire.str(x, "author_handle"), wire.str(x, "author_color"), rel_time(wire.str(x, "created_at")), wire.str(x, "body"))
	for rv in wire.arr(a.reviews) {
		st := wire.str(rv, "state")
		p.row(ui, "w-full min-w-0 overflow-hidden items-center gap-2 pl-11")
		ic, cls, what := ICON_MESSAGE_SQUARE, "text-muted-foreground", "reviewed"
		if st == "approved" {
			ic, cls, what = ICON_CIRCLE_CHECK, "text-emerald-600", "approved these changes"
		} else if st == "changes_requested" {
			ic, cls, what = ICON_X, "text-red-600", "requested changes"
		}
		p.icon(ui, ic, tfmt("size-4 %s", cls))
		p.text(ui, review_author(a, rv), "text-[13px] font-semibold")
		p.text(ui, what, "text-[13px] text-muted-foreground shrink-0")
		if b := wire.str(rv, "body"); b != "" {
			p.text(ui, tfmt("“%s”", b), "text-[13px] truncate min-w-0")
		}
		p.spacer(ui)
		p.text(ui, rel_time(wire.str(rv, "created_at")), "text-[11px] text-muted-foreground")
		p.end(ui)
	}
	for cm in wire.arr(a.comments) {
		at_line := ""
		if path := wire.str(cm, "path"); path != "" {
			at_line = tfmt("on %s:%d", path, wire.num(cm, "line"))
		}
		comment_card(ui, wire.str(cm, "author_handle"), wire.str(cm, "author_color"), rel_time(wire.str(cm, "created_at")), wire.str(cm, "body"), at_line)
	}
	if pull && wire.is_null(x, "merged_at") && wire.str(x, "state") == "open" {
		merge_box(ui, a)
	}
	if pull && !wire.is_null(x, "merged_at") {
		p.row(ui, "w-full items-center gap-3 pl-11")
		p.row(ui, "size-8 rounded-full bg-violet-600 items-center justify-center")
		p.icon(ui, ICON_GIT_MERGE, "size-4 text-white")
		p.end(ui)
		p.text(ui, tfmt("Merged with a %s as %s", wire.str(x, "merge_method"), short_sha(wire.str(x, "merged_sha"))), "text-[13px]")
		p.end(ui)
	}
	// reply
	p.col(ui, "w-full gap-2 pl-11")
	field(ui, a, &a.comment_buf, "Leave a comment", "w-full h-[84] text-[13px]")
	p.row(ui, "w-full justify-end gap-2")
	if wire.str(x, "state") == "open" && !pull {
		if btn(ui, "Close issue", .Outline, .SM, ICON_CIRCLE_CHECK) {
			set_issue_state(&a.cl, wire.str(x, "id"), "closed")
			reload_item(a)
		}
	}
	if btn(ui, "Comment", .Default, .SM, nil, len(a.comment_buf) == 0) {
		author, _ := acting_identity(&a.cl, a.ref, "")
		r := add_comment(&a.cl, wire.str(x, "repo_id"), wire.str(x, "id"), author, string(a.comment_buf[:]))
		a.toast = "Commented." if wire.ok(r) else r.err
		clear(&a.comment_buf)
		reload_item(a)
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)

	// side column
	p.col(ui, "w-[240] shrink-0 gap-4")
	side :: proc(ui: ^p.Ctx, title, value: string) {
		p.col(ui, "w-full gap-1 pb-3 border-b border-border")
		p.text(ui, title, "text-[12px] font-semibold text-muted-foreground")
		p.text(ui, value, "text-[13px]")
		p.end(ui)
	}
	labels := wire.strs(x, "labels")
	side(ui, "Labels", strings.join(labels, ", ") if len(labels) > 0 else "None yet")
	side(ui, "Author", wire.str(x, "author_handle"))
	if pull {
		approvals := 0
		for rv in wire.arr(a.reviews) {
			if wire.str(rv, "state") == "approved" {
				approvals += 1
			}
		}
		side(ui, "Reviews", tfmt("%d approval%s", approvals, "" if approvals == 1 else "s"))
	}
	p.end(ui)
	p.end(ui)
}

review_author :: proc(a: ^App, rv: json.Value) -> string {
	id := wire.str(rv, "author_identity_id")
	for cm in wire.arr(a.comments) {
		if wire.str(cm, "author_identity_id") == id {
			return wire.str(cm, "author_handle")
		}
	}
	for x in wire.arr(a.identities) {
		if wire.str(x, "id") == id {
			return wire.str(x, "handle")
		}
	}
	if wire.str(a.item, "author_identity_id") == id {
		return wire.str(a.item, "author_handle")
	}
	return "a reviewer"
}

branch_chip :: proc(ui: ^p.Ctx, name: string) {
	p.row(ui, "items-center px-1.5 py-0.5 rounded-md bg-sky-500/10")
	p.text(ui, name, "text-[12px] font-mono text-sky-700 dark:text-sky-300")
	p.end(ui)
}

reload_item :: proc(a: ^App) {
	n := wire.num(a.item, "number")
	load_session(a)
	load_page(a)
	for x in wire.arr(a.items) {
		if wire.num(x, "number") == n {
			open_item(a, x)
		}
	}
}

merge_box :: proc(ui: ^p.Ctx, a: ^App) {
	cmp := a.compare
	clean := wire.flag(cmp, "mergeable")
	ff := wire.flag(cmp, "fast_forward")
	writable := wire.str(a.repo, "role") != "read"
	p.row(ui, "w-full items-start gap-3")
	p.row(ui, tfmt("size-8 shrink-0 rounded-full items-center justify-center %s", "bg-emerald-600" if clean else "bg-amber-500"))
	p.icon(ui, ICON_GIT_MERGE, "size-4 text-white")
	p.end(ui)
	p.col(ui, tfmt("flex-1 min-w-0 rounded-xl border %s overflow-hidden", "border-emerald-600/40" if clean else "border-amber-500/50"))
	p.row(ui, "w-full items-center gap-3 px-4 py-3 border-b border-border")
	p.icon(ui, ICON_CIRCLE_CHECK if clean else sc.ICON_TRIANGLE_ALERT, tfmt("size-5 %s", "text-emerald-600" if clean else "text-amber-600"))
	p.col(ui, "gap-0.5")
	p.text(ui, "This branch has no conflicts with the base branch" if clean else "This branch has conflicts that must be resolved", "text-[13px] font-semibold")
	p.text(ui, tfmt("%d ahead, %d behind %s%s", wire.num(cmp, "ahead"), wire.num(cmp, "behind"), wire.str(cmp, "base"),
		" · can fast-forward" if ff else ""), "text-[12px] text-muted-foreground")
	p.end(ui)
	p.end(ui)
	p.row(ui, "w-full items-center gap-2 px-4 py-3 bg-muted/40")
	if !writable {
		p.text(ui, "You have read access: only writers can merge.", "text-[12px] text-muted-foreground")
	} else {
		if btn(ui, "Merge pull request", .Default, .SM, ICON_GIT_MERGE, !clean) {
			do_merge(a, "merge-commit")
		}
		if btn(ui, "Fast-forward", .Outline, .SM, nil, !ff) {
			do_merge(a, "fast-forward")
		}
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

do_merge :: proc(a: ^App, method: string) {
	r := merge_pull(&a.cl, a.ref, wire.num(a.item, "number"), method)
	a.toast = tfmt("Merged as %s", short_sha(wire.str(r.value, "sha"))) if wire.ok(r) else r.err
	reload_item(a)
}

feed :: proc(ui: ^p.Ctx, a: ^App, events: json.Value, with_repo: bool) {
	list := wire.arr(events)
	if len(list) == 0 {
		empty(ui, ICON_ACTIVITY, "No activity yet", "Pushes, issues, reviews and merges show up here.")
		return
	}
	p.col(ui, "w-full gap-0")
	for e in list {
		p.row(ui, "w-full items-start gap-3 py-2.5 border-b border-border")
		p.row(ui, tfmt("size-7 shrink-0 rounded-full items-center justify-center bg-%s-500", hue(wire.str(e, "actor_color"))))
		h := wire.str(e, "actor_handle")
		p.text(ui, strings.to_upper(h[:min(1, len(h))]), "text-[11px] font-semibold text-white")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.row(ui, "items-center gap-1.5 min-w-0")
		p.text(ui, h if h != "" else "someone", "text-[13px] font-semibold shrink-0")
		p.text(ui, event_text(e), "text-[13px] truncate min-w-0")
		if with_repo {
			p.text(ui, tfmt("in %s/%s", wire.str(e, "owner_handle"), wire.str(e, "repo_name")), "text-[13px] text-muted-foreground shrink-0")
		}
		p.end(ui)
		if wire.str(e, "kind") == "push" {
			if s := wire.str(wire.get(e, "payload"), "head"); s != "" {
				p.text(ui, s, "text-[12px] text-muted-foreground font-mono truncate")
			}
		}
		p.end(ui)
		p.text(ui, rel_time(wire.str(e, "created_at")), "text-[11px] text-muted-foreground shrink-0")
		p.end(ui)
	}
	p.end(ui)
}

segmented :: proc(ui: ^p.Ctx, value: ^string, options: []string, labels: []string) {
	p.row(ui, "self-start items-center gap-1 p-1 rounded-lg bg-muted")
	for o, i in options {
		on := value^ == o
		idx := p.row(ui, tfmt("px-3 py-1 rounded-md %s", "bg-background border border-border" if on else ""))
		p.focusable(ui)
		p.text(ui, labels[i], tfmt("text-[12px] %s", "font-medium" if on else "text-muted-foreground"))
		p.end(ui)
		if p.activated(ui, idx) {
			value^ = o
		}
	}
	p.end(ui)
}

VIS_OPTIONS := []string{"private", "shared", "public"}
VIS_LABELS := []string{"Private", "Shared", "Public"}

vis_help :: proc(v: string) -> string {
	switch v {
	case "public":
		return "Anyone can read and clone it, without signing in. Only you and your grants can push."
	case "shared":
		return "Your other identities can read it. Nobody else can, and nobody else can see it exists."
	}
	return "Only this identity, and identities you grant access to, can see it."
}

settings_tab :: proc(ui: ^p.Ctx, a: ^App) {
	admin := wire.str(a.repo, "role") == "admin"
	card :: proc(ui: ^p.Ctx, title, sub: string) {
		p.col(ui, "w-full rounded-xl border border-border p-5 gap-4")
		p.col(ui, "gap-1")
		p.text(ui, title, "text-base font-semibold")
		p.text(ui, sub, "text-[13px] text-muted-foreground")
		p.end(ui)
	}
	card(ui, "Visibility", vis_help(wire.str(a.repo, "visibility")))
	vis := wire.str(a.repo, "visibility")
	before := vis
	segmented(ui, &vis, VIS_OPTIONS, VIS_LABELS)
	if vis != before && admin {
		update_repo(&a.cl, wire.str(a.repo, "id"), tfmt(`{{"visibility":%s}}`, wire.q(vis)))
		load_session(a)
		load_page(a)
	}
	p.end(ui)

	card(ui, "Collaborators", "Grants from this identity to another. Each is an explicit, revocable row; nothing crosses identities without one.")
	list := wire.arr(a.collabs)
	if len(list) == 0 {
		p.text(ui, "No one else has access.", "text-[13px] text-muted-foreground")
	}
	for g in list {
		p.row(ui, "w-full items-center gap-3 py-2 border-t border-border")
		p.row(ui, tfmt("size-7 rounded-full items-center justify-center bg-%s-500", hue(wire.str(g, "grantee_color"))))
		h := wire.str(g, "grantee_handle")
		p.text(ui, strings.to_upper(h[:min(1, len(h))]), "text-[11px] font-semibold text-white")
		p.end(ui)
		p.col(ui, "gap-0.5")
		p.text(ui, h, "text-[13px] font-semibold")
		p.text(ui, tfmt("%s · granted %s", wire.str(g, "grantee_name"), rel_time(wire.str(g, "created_at"))), "text-[11px] text-muted-foreground")
		p.end(ui)
		p.spacer(ui)
		role_pill(ui, wire.str(g, "role"))
		if admin && btn(ui, "Revoke", .Ghost, .XS) {
			revoke(&a.cl, wire.str(a.repo, "id"), h)
			load_page(a)
		}
		p.end(ui)
	}
	if admin {
		p.row(ui, "w-full items-center gap-2 pt-2")
		field(ui, a, &a.grant_buf, "identity handle", "w-[220] text-[13px]")
		segmented(ui, &a.grant_role, {"read", "write", "admin"}, {"Read", "Write", "Admin"})
		if btn(ui, "Grant", .Default, .SM, ICON_USER_PLUS, len(a.grant_buf) == 0) {
			r := grant(&a.cl, wire.str(a.repo, "id"), string(a.grant_buf[:]), a.grant_role)
			a.toast = "Granted." if wire.ok(r) else r.err
			clear(&a.grant_buf)
			load_page(a)
		}
		p.end(ui)
	}
	p.end(ui)

	card(ui, "Clone", "Over HTTPS with git; a personal access token is the password.")
	p.row(ui, "w-full rounded-lg bg-muted px-4 py-3")
	p.text(ui, tfmt("git clone %s", clone_url(&a.cl, a.ref)), "text-[12px] font-mono")
	p.end(ui)
	p.end(ui)
}

new_repo_page :: proc(ui: ^p.Ctx, a: ^App) {
	ids := wire.arr(a.identities)
	p.col(ui, "w-full max-w-[720] px-8 py-6 gap-6")
	defer p.end(ui)
	p.col(ui, "gap-1")
	p.text(ui, "Create a new repository", "text-xl font-semibold")
	p.text(ui, "A repository belongs to one identity. Its issues, pull requests and grants live with it.", "text-sm text-muted-foreground")
	p.end(ui)
	if len(ids) == 0 {
		p.text(ui, "Sign in first: `accounts signin`.", "text-sm text-destructive")
		return
	}
	p.col(ui, "gap-2")
	p.text(ui, "Owner", "text-[13px] font-medium")
	p.row(ui, "gap-2 flex-wrap")
	for x, i in ids {
		on := a.new_owner == i
		idx := p.row(ui, tfmt("items-center gap-2 px-3 py-2 rounded-lg border %s", tfmt("border-%s-500 bg-%s-500/10", hue(wire.str(x, "color")), hue(wire.str(x, "color"))) if on else "border-border"))
		p.focusable(ui)
		dot(ui, wire.str(x, "color"))
		p.col(ui, "gap-px")
		p.text(ui, wire.str(x, "handle"), "text-[13px] font-medium")
		p.text(ui, wire.str(x, "kind"), "text-[10px] text-muted-foreground")
		p.end(ui)
		p.end(ui)
		if p.activated(ui, idx) {
			a.new_owner = i
		}
	}
	p.end(ui)
	p.end(ui)
	p.col(ui, "gap-2")
	p.text(ui, "Repository name", "text-[13px] font-medium")
	field(ui, a, &a.name_buf, "palm-notes", "w-[360] text-[13px]")
	p.end(ui)
	p.col(ui, "gap-2")
	p.text(ui, "Description (optional)", "text-[13px] font-medium")
	field(ui, a, &a.desc_buf, "", "w-full text-[13px]")
	p.end(ui)
	p.col(ui, "gap-2")
	p.text(ui, "Visibility", "text-[13px] font-medium")
	segmented(ui, &a.new_vis, VIS_OPTIONS, VIS_LABELS)
	p.text(ui, vis_help(a.new_vis), "text-[12px] text-muted-foreground")
	p.end(ui)
	idx := p.row(ui, "items-center gap-2")
	p.focusable(ui)
	p.row(ui, tfmt("size-4 rounded border items-center justify-center %s", "bg-primary border-primary" if a.new_readme else "border-border"))
	if a.new_readme {
		p.icon(ui, ICON_CHECK, "size-3 text-primary-foreground")
	}
	p.end(ui)
	p.text(ui, "Start with a README", "text-[13px]")
	p.end(ui)
	if p.activated(ui, idx) {
		a.new_readme = !a.new_readme
	}
	p.row(ui, "w-full justify-end pt-2 border-t border-border")
	if btn(ui, "Create repository", .Default, .Default, nil, len(a.name_buf) == 0) {
		owner := ids[clamp(a.new_owner, 0, len(ids) - 1)]
		name := string(a.name_buf[:])
		r := create_repo(&a.cl, wire.str(owner, "id"), name, a.new_vis, string(a.desc_buf[:]))
		if wire.ok(r) {
			init_repo(&a.cl, Repo_Ref{wire.str(owner, "handle"), name}, a.new_readme)
			clear(&a.name_buf)
			clear(&a.desc_buf)
			load_session(a)
			for row, i in wire.arr(a.repos) {
				if wire.str(row, "name") == name && wire.str(row, "identity_id") == wire.str(owner, "id") {
					go_repo(a, i)
				}
			}
		} else {
			a.toast = r.err
		}
	}
	p.end(ui)
}

tokens_page :: proc(ui: ^p.Ctx, a: ^App) {
	ids := wire.arr(a.identities)
	p.col(ui, "w-full max-w-[960] px-8 py-6 gap-5")
	defer p.end(ui)
	p.col(ui, "gap-1")
	p.text(ui, "Personal access tokens", "text-xl font-semibold")
	p.text(ui, "A token acts for exactly one identity, can read or write repositories and nothing else in your account, and can be revoked at once. Use one as the password when git asks.", "text-sm text-muted-foreground max-w-[720]")
	p.end(ui)
	if a.new_token != "" {
		p.col(ui, "w-full rounded-xl border border-emerald-600/40 bg-emerald-500/5 p-4 gap-2")
		p.text(ui, "Copy your new token now. It is not shown again.", "text-[13px] font-semibold")
		p.row(ui, "w-full items-center rounded-lg bg-background border border-border px-3 py-2")
		p.text(ui, a.new_token, "text-[12px] font-mono")
		p.end(ui)
		p.end(ui)
	}
	p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
	p.row(ui, "w-full items-center gap-3 px-4 py-2.5 bg-muted/50")
	p.text(ui, "Name", "w-[180] text-[12px] font-medium text-muted-foreground")
	p.text(ui, "Identity", "w-[160] text-[12px] font-medium text-muted-foreground")
	p.text(ui, "Scope", "w-[90] text-[12px] font-medium text-muted-foreground")
	p.text(ui, "Token", "w-[170] text-[12px] font-medium text-muted-foreground")
	p.text(ui, "Last used", "flex-1 text-[12px] font-medium text-muted-foreground")
	p.end(ui)
	list := wire.arr(a.tokens)
	if len(list) == 0 {
		p.row(ui, "w-full px-4 py-6 border-t border-border")
		p.text(ui, "No tokens yet.", "text-[13px] text-muted-foreground")
		p.end(ui)
	}
	for t in list {
		revoked := !wire.is_null(t, "revoked_at")
		p.row(ui, tfmt("w-full items-center gap-3 px-4 py-2.5 border-t border-border %s", "opacity-50" if revoked else ""))
		p.row(ui, "w-[180] items-center gap-2")
		p.icon(ui, ICON_KEY_ROUND, "size-3.5 text-muted-foreground")
		p.text(ui, wire.str(t, "name"), "text-[13px] font-medium truncate")
		p.end(ui)
		p.row(ui, "w-[160] items-center gap-2")
		for x in ids {
			if wire.str(x, "id") == wire.str(t, "identity_id") {
				dot(ui, wire.str(x, "color"), "size-2")
				p.text(ui, wire.str(x, "handle"), "text-[13px]")
			}
		}
		p.end(ui)
		p.row(ui, "w-[90]")
		pill(ui, wire.str(t, "scope"), "bg-amber-500/15 text-amber-700" if wire.str(t, "scope") == "write" else "bg-muted text-muted-foreground")
		p.end(ui)
		p.text(ui, tfmt("%s…", wire.str(t, "prefix")), "w-[170] text-[12px] font-mono text-muted-foreground")
		p.text(ui, "revoked" if revoked else (rel_time(wire.str(t, "last_used_at")) if !wire.is_null(t, "last_used_at") else "never"), "flex-1 text-[12px] text-muted-foreground")
		if !revoked && btn(ui, "Revoke", .Ghost, .XS) {
			revoke_token(&a.cl, wire.str(t, "id"))
			load_page(a)
		}
		p.end(ui)
	}
	p.end(ui)

	if a.cl.kind == "token" {
		p.text(ui, "This window is signed in with a token; tokens cannot create tokens.", "text-[13px] text-muted-foreground")
		return
	}
	p.col(ui, "w-full rounded-xl border border-border p-5 gap-3")
	p.text(ui, "Generate a new token", "text-base font-semibold")
	p.row(ui, "w-full items-center gap-2")
	field(ui, a, &a.token_buf, "laptop, ci, …", "w-[220] text-[13px]")
	segmented(ui, &a.token_scope, {"read", "write"}, {"Read", "Read and write"})
	p.spacer(ui)
	owner := ids[clamp(a.new_owner, 0, max(len(ids) - 1, 0))] if len(ids) > 0 else nil
	if owner != nil {
		p.row(ui, "items-center gap-2")
		p.text(ui, "for", "text-[12px] text-muted-foreground")
		dot(ui, wire.str(owner, "color"), "size-2")
		p.text(ui, wire.str(owner, "handle"), "text-[13px] font-medium")
		p.end(ui)
	}
	if btn(ui, "Generate", .Default, .SM, ICON_KEY_ROUND, len(a.token_buf) == 0 || owner == nil) {
		r := create_token(&a.cl, wire.str(owner, "id"), string(a.token_buf[:]), a.token_scope, 0)
		if wire.ok(r) {
			a.new_token = strings.clone(wire.str(r.value, "token"), runtime.heap_allocator())
		} else {
			a.toast = r.err
		}
		clear(&a.token_buf)
		load_page(a)
	}
	p.end(ui)
	p.end(ui)
}
