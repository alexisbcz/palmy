package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import vt "./vt"

// ---------------------------------------------------------------------------
// Tabs, splits and panes.
//
// A pane is a terminal and the process behind it: its own pty, its own VT
// state, its own pixel cache. A tab is a tree of panes -- a leaf is one pane,
// a split is two subtrees side by side or one above the other, with a ratio
// between them -- and the tab strip is a list of tabs. That was the seam this
// file was written around: the strip, the reader thread and the housekeeping
// all work on panes, and "a tab holding two terminals" is a tab whose tree has
// a split at the top.
//
// The session keeps every pane of every tab in one flat list as well, which
// is what the reader thread walks: it does not care which tab a pane is in,
// only that it is still alive.
// ---------------------------------------------------------------------------

Pane :: struct {
	term:       vt.Terminal,
	pty:        Pty,
	rend:       Grid_Renderer,
	// The title the program asked for, via OSC 0/2. Empty means fall back to
	// the process name, which is what makes a tab say "vim" without the
	// program having to cooperate.
	osc_title:  string,
	fallback:   string,
	// Set when the child is gone. The pane stays until it is closed by hand
	// so that whatever the command printed before it died is still readable.
	dead:       bool,
	exit_code:  int,
	// When a close was asked for and the child was signalled, this is when.
	// If it is still alive a moment later it gets a harder signal.
	closing_at: time.Time,
	closing:    bool,
	bytes_in:   u64,
	id:         int,
	// Where the layout put it, in device pixels relative to the grid area,
	// and where inside that the cell grid starts.
	rect:       [4]int,
	grid:       [2]int,
	shown:      bool,
}

Split_Dir :: enum u8 {
	Columns, // side by side: a vertical divider
	Rows,    // one above the other: a horizontal divider
}

Node :: struct {
	parent: ^Node,
	// A leaf holds a pane; a split holds two children.
	pane:   ^Pane,
	dir:    Split_Dir,
	ratio:  f32, // the share of the first child
	a, b:   ^Node,
	// The size the split had at the last layout, along its axis, so a
	// resize can move the divider by one cell.
	extent: int,
}

Tab :: struct {
	root:   ^Node,
	focus:  ^Pane,
	id:     int,
	// One pane fills the tab while the others keep running behind it.
	zoomed: bool,
}

Session :: struct {
	tabs:       [dynamic]^Tab,
	// Every pane of every tab, for the reader thread and the housekeeping.
	panes:      [dynamic]^Pane,
	active:     int,
	next_id:    int,
	cols, rows: int,
	scrollback: int,
	term_name:  string,
	shell:      []string,
	// The last directory a pane reported through OSC 7, used as the working
	// directory for the next new tab. Opening a tab in the directory you were
	// just in is the single most useful thing a tab strip can do.
	last_cwd:   string,
	// Text a program asked to put on the clipboard with OSC 52, picked up
	// by the frame loop. Reads are refused in the engine and never reach
	// here; see the note in terminal.odin.
	clipboard_request: string,
	// The cell size panes are opened with, until the first layout.
	cell_w:     int,
	cell_h:     int,
}

DIVIDER_LOGICAL :: 1

session_init :: proc(s: ^Session, cols, rows, scrollback: int, term_name: string, shell: []string) {
	s.tabs = make([dynamic]^Tab)
	s.panes = make([dynamic]^Pane)
	s.cols = cols
	s.rows = rows
	s.scrollback = scrollback
	s.term_name = term_name
	s.shell = shell
}

session_destroy :: proc(s: ^Session) {
	for t in s.tabs {
		node_free(t.root)
		free(t)
	}
	for p in s.panes {
		pane_destroy(p)
	}
	delete(s.tabs)
	delete(s.panes)
}

@(private = "file")
node_free :: proc(n: ^Node) {
	if n == nil {
		return
	}
	node_free(n.a)
	node_free(n.b)
	free(n)
}

// pane_open starts a process on a new pty and gives it a terminal.
pane_open :: proc(s: ^Session, cols, rows: int, argv: []string = nil, cwd: string = "") -> (^Pane, string) {
	p := new(Pane)
	vt.terminal_init(&p.term, cols, rows, s.scrollback)
	p.term.gfx.load_file = kitty_read_file
	if s.cell_w > 0 {
		vt.terminal_set_cell_size(&p.term, s.cell_w, s.cell_h)
	}
	cmd := argv
	if len(cmd) == 0 {
		cmd = s.shell
	}
	dir := cwd
	if dir == "" {
		dir = s.last_cwd
	}
	if dir == "" {
		dir = os.get_env("HOME", context.temp_allocator)
	}
	env := child_env(s.term_name, nil)
	pty, err := pty_spawn(
		{
			argv = cmd,
			env = env,
			cwd = dir,
			cols = cols,
			rows = rows,
			cell_w = p.term.gfx.cell_w,
			cell_h = p.term.gfx.cell_h,
		},
	)
	if err != "" {
		vt.terminal_destroy(&p.term)
		free(p)
		return nil, err
	}
	p.pty = pty
	p.fallback = strings.clone(base_name(cmd[0]))
	s.next_id += 1
	p.id = s.next_id
	append(&s.panes, p)
	return p, ""
}

pane_destroy :: proc(p: ^Pane) {
	pty_close(&p.pty)
	vt.terminal_destroy(&p.term)
	renderer_destroy(&p.rend)
	delete(p.osc_title)
	delete(p.fallback)
	free(p)
}

// tab_open opens a new tab holding one pane, and makes it the active one.
tab_open :: proc(s: ^Session, argv: []string = nil, cwd: string = "") -> (^Tab, string) {
	p, err := pane_open(s, s.cols, s.rows, argv, cwd)
	if err != "" {
		return nil, err
	}
	t := new(Tab)
	t.root = new(Node)
	t.root.pane = p
	t.focus = p
	s.next_id += 1
	t.id = s.next_id
	append(&s.tabs, t)
	s.active = len(s.tabs) - 1
	return t, ""
}

// tab_split splits the focused pane of a tab in two, starts a new shell in
// the second half, in the directory the first one is in, and focuses it.
tab_split :: proc(s: ^Session, t: ^Tab, dir: Split_Dir, argv: []string = nil) -> (^Pane, string) {
	old := t.focus
	leaf := find_leaf(t.root, old)
	if leaf == nil {
		return nil, "nothing to split"
	}
	cols, rows := old.term.cols, old.term.rows
	if dir == .Columns {
		cols = max(1, cols / 2)
	} else {
		rows = max(1, rows / 2)
	}
	p, err := pane_open(s, cols, rows, argv, pane_cwd(old))
	if err != "" {
		return nil, err
	}
	a := new(Node)
	a.pane = old
	a.parent = leaf
	b := new(Node)
	b.pane = p
	b.parent = leaf
	leaf.pane = nil
	leaf.dir = dir
	leaf.ratio = 0.5
	leaf.a = a
	leaf.b = b
	t.focus = p
	t.zoomed = false
	return p, ""
}

@(private = "file")
find_leaf :: proc(n: ^Node, p: ^Pane) -> ^Node {
	if n == nil {
		return nil
	}
	if n.pane != nil {
		return n.pane == p ? n : nil
	}
	if l := find_leaf(n.a, p); l != nil {
		return l
	}
	return find_leaf(n.b, p)
}

@(private = "file")
first_leaf :: proc(n: ^Node) -> ^Pane {
	m := n
	for m != nil && m.pane == nil {
		m = m.a
	}
	return m != nil ? m.pane : nil
}

// tab_panes lists a tab's panes, left to right and top to bottom.
tab_panes :: proc(t: ^Tab, out: ^[dynamic]^Pane) {
	walk :: proc(n: ^Node, out: ^[dynamic]^Pane) {
		if n == nil {
			return
		}
		if n.pane != nil {
			append(out, n.pane)
			return
		}
		walk(n.a, out)
		walk(n.b, out)
	}
	clear(out)
	walk(t.root, out)
}

tab_pane_count :: proc(t: ^Tab) -> int {
	count :: proc(n: ^Node) -> int {
		if n == nil {
			return 0
		}
		if n.pane != nil {
			return 1
		}
		return count(n.a) + count(n.b)
	}
	return count(t.root)
}

// tab_detach takes a pane out of a tab's tree: its sibling takes the place
// of the split they shared, and focus goes to the pane nearest where it was.
// It returns true when the tab is now empty. The pane itself is not touched.
tab_detach :: proc(s: ^Session, t: ^Tab, p: ^Pane) -> bool {
	for x, i in s.panes {
		if x == p {
			ordered_remove(&s.panes, i)
			break
		}
	}
	leaf := find_leaf(t.root, p)
	if leaf == nil {
		return t.root == nil
	}
	parent := leaf.parent
	if parent == nil {
		free(leaf)
		t.root = nil
		t.focus = nil
		return true
	}
	sibling := parent.a == leaf ? parent.b : parent.a
	// The sibling's contents move up into the parent's node, so whatever
	// points at the parent (its own parent, or the tab) is still right.
	parent.pane = sibling.pane
	parent.dir = sibling.dir
	parent.ratio = sibling.ratio
	parent.a = sibling.a
	parent.b = sibling.b
	if parent.a != nil {
		parent.a.parent = parent
	}
	if parent.b != nil {
		parent.b.parent = parent
	}
	free(sibling)
	free(leaf)
	if t.focus == p {
		t.focus = first_leaf(parent)
	}
	t.zoomed = false
	return false
}

// pane_tab finds the tab a pane belongs to.
pane_tab :: proc(s: ^Session, p: ^Pane) -> ^Tab {
	for t in s.tabs {
		if find_leaf(t.root, p) != nil {
			return t
		}
	}
	return nil
}

base_name :: proc(p: string) -> string {
	if i := strings.last_index_byte(p, '/'); i >= 0 {
		return p[i + 1:]
	}
	return p
}

// pane_title is what a pane is called: what the program asked for, or the
// name of whatever is running, or the shell.
pane_title :: proc(p: ^Pane) -> string {
	if p.dead {
		return fmt.tprintf("%s (exited)", p.fallback)
	}
	if p.osc_title != "" {
		return p.osc_title
	}
	if n := foreground_name(&p.pty); n != "" {
		return n
	}
	return p.fallback
}

// tab_title is what the strip shows: the focused pane's title.
tab_title :: proc(t: ^Tab) -> string {
	if t.focus == nil {
		return ""
	}
	return pane_title(t.focus)
}

// pane_cwd is where a new pane split from this one starts: the directory the
// shell last reported with OSC 7, or, since most shells do not report one
// unless configured to, the directory the kernel says the foreground process
// -- and failing that the shell -- is in.
pane_cwd :: proc(p: ^Pane) -> string {
	if p.term.pwd != "" && os.is_dir(p.term.pwd) {
		return p.term.pwd
	}
	buf: [4096]u8
	pids: [2]i32
	if p.pty.master > 0 {
		pids[0] = sys_foreground_pgrp(p.pty.master)
	}
	pids[1] = i32(p.pty.pid)
	for pid in pids {
		if pid <= 0 {
			continue
		}
		if dir := sys_process_cwd(pid, buf[:]); dir != "" {
			if os.is_dir(dir) {
				return dir
			}
		}
	}
	return ""
}

// foreground_name asks the kernel which process currently owns the terminal,
// so a pane running `vim` says vim rather than the shell that launched it.
foreground_name :: proc(p: ^Pty) -> string {
	if p.master <= 0 {
		return ""
	}
	return sys_foreground_name(p.master)
}

// ---------------------------------------------------------------------------
// Closing a pane that still has something running
//
// The decision, made deliberately: closing a pane hangs up the terminal the
// way unplugging a serial line would. The child's process group gets SIGHUP,
// which is what every shell is written to handle -- it writes its history out
// and exits, and anything it started under `nohup` or `disown` survives, which
// is exactly what those exist for. If the group is still there after a moment
// it gets SIGKILL, because a pane that will not close is worse than a process
// that did not get to clean up.
//
// The alternative -- silently orphaning the process -- was rejected: a build
// left running with nowhere to write its output is a thing that bites hours
// later, when the disk is full or the port is still bound.
// ---------------------------------------------------------------------------

CLOSE_GRACE :: 1500 * time.Millisecond

pane_request_close :: proc(p: ^Pane) {
	if p.dead {
		return
	}
	p.closing = true
	p.closing_at = time.now()
	pty_signal(&p.pty, .SIGHUP)
	// Closing the master makes the slave side report EIO, which wakes a
	// child that is blocked reading and ignoring signals.
	pty_close(&p.pty)
}

// pane_close_ready says whether a pane asked to close has actually gone.
pane_close_ready :: proc(p: ^Pane) -> bool {
	if p.dead {
		return true
	}
	if !p.closing {
		return false
	}
	if pty_reap(&p.pty) {
		return true
	}
	if time.since(p.closing_at) > CLOSE_GRACE {
		pty_signal(&p.pty, .SIGKILL)
		// One more chance to reap; if the process is unkillable it is in
		// uninterruptible sleep and nothing here can help.
		return pty_reap(&p.pty)
	}
	return false
}

session_move :: proc(s: ^Session, from, to: int) {
	if from < 0 || from >= len(s.tabs) || to < 0 || to >= len(s.tabs) || from == to {
		return
	}
	t := s.tabs[from]
	ordered_remove(&s.tabs, from)
	inject_at(&s.tabs, to, t)
	s.active = to
}

session_select :: proc(s: ^Session, idx: int) {
	if idx >= 0 && idx < len(s.tabs) {
		s.active = idx
	}
}

session_next :: proc(s: ^Session) {
	if len(s.tabs) > 0 {
		s.active = (s.active + 1) % len(s.tabs)
	}
}

session_prev :: proc(s: ^Session) {
	if len(s.tabs) > 0 {
		s.active = (s.active + len(s.tabs) - 1) % len(s.tabs)
	}
}

session_tab :: proc(s: ^Session) -> ^Tab {
	if s.active < 0 || s.active >= len(s.tabs) {
		return nil
	}
	return s.tabs[s.active]
}

// session_active is the pane keystrokes go to: the focused pane of the
// active tab.
session_active :: proc(s: ^Session) -> ^Pane {
	t := session_tab(s)
	if t == nil {
		return nil
	}
	return t.focus
}

// pane_resize gives a pane a new grid size, and tells the child.
pane_resize :: proc(p: ^Pane, cols, rows: int) {
	if cols == p.term.cols && rows == p.term.rows {
		return
	}
	vt.terminal_resize(&p.term, cols, rows)
	pty_resize(&p.pty, cols, rows, p.term.gfx.cell_w, p.term.gfx.cell_h)
}

READ_CHUNK :: 64 * 1024

// session_housekeeping is the part of the pump that belongs to the frame
// loop rather than the reader thread: titles, the working directory, and
// noticing that a child has gone. The bytes themselves are read in pump.odin,
// on its own thread, because the child must never wait for a frame.
session_housekeeping :: proc(s: ^Session) -> bool {
	changed := false
	for p in s.panes {
		if p.term.title != "" && p.term.title != p.osc_title {
			delete(p.osc_title)
			p.osc_title = strings.clone(p.term.title)
			changed = true
		}
		if p.term.pwd != "" && p.term.pwd != s.last_cwd {
			delete(s.last_cwd)
			s.last_cwd = strings.clone(p.term.pwd)
		}
		if !p.dead && p.pty.master > 0 && pty_reap(&p.pty) {
			pane_mark_dead(p)
			changed = true
		}
		if p.term.clipboard_pending {
			p.term.clipboard_pending = false
			s.clipboard_request = strings.clone(p.term.clipboard_set)
		}
	}
	return changed
}

pane_mark_dead :: proc(p: ^Pane) {
	if p.dead {
		return
	}
	pty_reap(&p.pty)
	p.dead = true
	p.exit_code = pty_exit_code(&p.pty)
	pty_close(&p.pty)
	// Leave a line saying what happened. A window that simply goes blank
	// when a command dies is a window that loses the error message.
	msg := fmt.tprintf(
		"\r\n\x1b[2m[process exited with code %d — ctrl+shift+w to close]\x1b[0m\r\n",
		p.exit_code,
	)
	vt.terminal_feed(&p.term, transmute([]u8)msg)
}

session_write :: proc(s: ^Session, data: []u8) {
	p := session_active(s)
	if p == nil || p.dead {
		return
	}
	pty_write(&p.pty, data)
}

// session_fds collects the pty descriptors so the frame loop can wait on them
// alongside the display connection.
session_fds :: proc(s: ^Session, out: ^[dynamic]Fd) {
	clear(out)
	for p in s.panes {
		if !p.dead && p.pty.master > 0 {
			append(out, p.pty.master)
		}
	}
	slice.sort(out[:])
}

// session_bytes_in is how much every pane has read, which is how the frame
// loop tells a busy session from an idle one.
session_bytes_in :: proc(s: ^Session) -> u64 {
	n: u64
	for p in s.panes {
		n += p.bytes_in
	}
	return n
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

// tab_layout gives every pane of a tab its rectangle inside `area` (device
// pixels), with a divider `div` pixels wide between the two halves of each
// split. A zoomed tab gives the whole area to the focused pane.
tab_layout :: proc(t: ^Tab, area: [4]int, div: int) {
	all := make([dynamic]^Pane, context.temp_allocator)
	tab_panes(t, &all)
	for p in all {
		p.shown = false
	}
	if t.zoomed && t.focus != nil {
		t.focus.rect = area
		t.focus.shown = true
		return
	}
	node_layout(t.root, area, div)
}

@(private = "file")
node_layout :: proc(n: ^Node, r: [4]int, div: int) {
	if n == nil {
		return
	}
	if n.pane != nil {
		n.pane.rect = r
		n.pane.shown = true
		return
	}
	x, y, w, h := r[0], r[1], r[2], r[3]
	if n.dir == .Columns {
		n.extent = w
		aw := clamp(int(f32(w - div) * n.ratio + 0.5), 0, max(0, w - div))
		node_layout(n.a, {x, y, aw, h}, div)
		node_layout(n.b, {x + aw + div, y, max(0, w - aw - div), h}, div)
	} else {
		n.extent = h
		ah := clamp(int(f32(h - div) * n.ratio + 0.5), 0, max(0, h - div))
		node_layout(n.a, {x, y, w, ah}, div)
		node_layout(n.b, {x, y + ah + div, w, max(0, h - ah - div)}, div)
	}
}

// tab_dividers lists the divider rectangles, for drawing.
tab_dividers :: proc(t: ^Tab, out: ^[dynamic][4]int, div: int) {
	clear(out)
	if t.zoomed {
		return
	}
	walk :: proc(n: ^Node, out: ^[dynamic][4]int, div: int) {
		if n == nil || n.pane != nil {
			return
		}
		ra := node_rect(n.a)
		rb := node_rect(n.b)
		if n.dir == .Columns {
			append(out, [4]int{ra[0] + ra[2], ra[1], div, max(ra[3], rb[3])})
		} else {
			append(out, [4]int{ra[0], ra[1] + ra[3], max(ra[2], rb[2]), div})
		}
		walk(n.a, out, div)
		walk(n.b, out, div)
	}
	walk(t.root, out, div)
}

// node_rect is the bounding box of everything under a node.
@(private = "file")
node_rect :: proc(n: ^Node) -> [4]int {
	if n.pane != nil {
		return n.pane.rect
	}
	a := node_rect(n.a)
	b := node_rect(n.b)
	x0 := min(a[0], b[0])
	y0 := min(a[1], b[1])
	x1 := max(a[0] + a[2], b[0] + b[2])
	y1 := max(a[1] + a[3], b[1] + b[3])
	return {x0, y0, x1 - x0, y1 - y0}
}

Direction :: enum u8 {
	Left,
	Right,
	Up,
	Down,
}

// tab_focus_move moves focus to the pane next to the focused one in a
// direction: of the panes whose near edge touches the focused pane's far
// edge, the one that overlaps it most along the other axis, and of those the
// one nearest its centre. Nothing there, nothing happens.
tab_focus_move :: proc(t: ^Tab, d: Direction, div: int) -> bool {
	f := t.focus
	if f == nil || t.zoomed {
		return false
	}
	all := make([dynamic]^Pane, context.temp_allocator)
	tab_panes(t, &all)
	fr := f.rect
	best: ^Pane
	best_overlap := -1
	best_dist := max(int)
	for p in all {
		if p == f || !p.shown {
			continue
		}
		r := p.rect
		touching := false
		overlap := 0
		center := 0
		switch d {
		case .Left:
			touching = abs(r[0] + r[2] + div - fr[0]) <= div
		case .Right:
			touching = abs(fr[0] + fr[2] + div - r[0]) <= div
		case .Up:
			touching = abs(r[1] + r[3] + div - fr[1]) <= div
		case .Down:
			touching = abs(fr[1] + fr[3] + div - r[1]) <= div
		}
		if !touching {
			continue
		}
		if d == .Left || d == .Right {
			overlap = min(fr[1] + fr[3], r[1] + r[3]) - max(fr[1], r[1])
			center = abs((r[1] + r[3] / 2) - (fr[1] + fr[3] / 2))
		} else {
			overlap = min(fr[0] + fr[2], r[0] + r[2]) - max(fr[0], r[0])
			center = abs((r[0] + r[2] / 2) - (fr[0] + fr[2] / 2))
		}
		if overlap <= 0 {
			continue
		}
		if overlap > best_overlap || (overlap == best_overlap && center < best_dist) {
			best = p
			best_overlap = overlap
			best_dist = center
		}
	}
	if best == nil {
		return false
	}
	t.focus = best
	return true
}

// tab_resize moves the divider of the nearest split around the focused pane
// that runs the right way -- a side-by-side split for left and right, a
// stacked one for up and down -- by `step` pixels in the arrow's direction.
// Each side keeps at least `min_px`.
tab_resize :: proc(t: ^Tab, d: Direction, step, min_px, div: int) -> bool {
	if t.focus == nil || t.zoomed {
		return false
	}
	want: Split_Dir = (d == .Left || d == .Right) ? .Columns : .Rows
	n := find_leaf(t.root, t.focus)
	for n != nil && n.parent != nil {
		n = n.parent
		if n.dir != want || n.extent <= 0 {
			continue
		}
		usable := n.extent - div
		if usable <= 2 * min_px {
			return false
		}
		cur := f32(usable) * n.ratio
		delta := f32(step)
		if d == .Left || d == .Up {
			delta = -delta
		}
		nv := clamp(cur + delta, f32(min_px), f32(usable - min_px))
		if nv == cur {
			return false
		}
		n.ratio = nv / f32(usable)
		return true
	}
	return false
}

// tab_pane_at finds the pane under a point in the grid area.
tab_pane_at :: proc(t: ^Tab, x, y: int) -> ^Pane {
	all := make([dynamic]^Pane, context.temp_allocator)
	tab_panes(t, &all)
	for p in all {
		r := p.rect
		if p.shown && x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3] {
			return p
		}
	}
	return nil
}
