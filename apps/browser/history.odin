// History, downloads and the session.
//
// History is an append-only log of visits, one JSON object per line. That
// shape is also its sync rule, should history ever sync (it does not, and the
// settings page says so): visits are a grow-only set keyed by their UUID, so
// two copies merge by union, and "clear history" is a tombstone line
// (`{"forget_before": ms}` or `{"forget_url": ...}`) that every replica applies
// to whatever it holds. Nothing is rewritten except by `compact`, which drops
// what tombstones have already hidden.
package browser

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Visit :: struct {
	id:            string `json:"id"`,
	url:           string `json:"url"`,
	title:         string `json:"title"`,
	at:            i64 `json:"at"`,
	device:        string `json:"device"`,
	forget_before: i64 `json:"forget_before"`,
	forget_url:    string `json:"forget_url"`,
}

History :: struct {
	path:   string,
	visits: [dynamic]Visit, // live visits, oldest first
	device: string,
}

HISTORY_KEEP :: 20000

history_open :: proc(path, device: string) -> History {
	h := History {
		path   = strings.clone(path),
		device = strings.clone(device),
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return h
	}
	forget_before: i64
	forget := make(map[string]i64, context.temp_allocator)
	// a visit whose title arrived later is written again with the same id;
	// the later line wins
	by_id := make(map[string]int, context.temp_allocator)
	lines := strings.split_lines(string(data), context.temp_allocator)
	for line in lines {
		if strings.trim_space(line) == "" {
			continue
		}
		v: Visit
		if json.unmarshal(transmute([]u8)line, &v) != nil {
			continue
		}
		if v.forget_before > 0 {
			forget_before = max(forget_before, v.forget_before)
			continue
		}
		if v.forget_url != "" {
			forget[v.forget_url] = max(forget[v.forget_url], v.at)
			continue
		}
		if i, ok := by_id[v.id]; ok && v.id != "" {
			h.visits[i] = v
			continue
		}
		by_id[v.id] = len(h.visits)
		append(&h.visits, v)
	}
	// apply tombstones
	n := 0
	for v in h.visits {
		if v.at <= forget_before {
			continue
		}
		if t, ok := forget[v.url]; ok && v.at <= t {
			continue
		}
		h.visits[n] = v
		n += 1
	}
	resize(&h.visits, n)
	slice.sort_by(h.visits[:], proc(a, b: Visit) -> bool {return a.at < b.at})
	if len(h.visits) > HISTORY_KEEP {
		remove_range(&h.visits, 0, len(h.visits) - HISTORY_KEEP)
	}
	return h
}

@(private = "file")
history_append_line :: proc(h: ^History, v: Visit) {
	data, err := json.marshal(v, {}, context.temp_allocator)
	if err != nil {
		return
	}
	f, ferr := os.open(h.path, {.Write, .Create, .Append}, os.perm(0o600))
	if ferr != nil {
		return
	}
	defer os.close(f)
	os.write(f, data)
	os.write(f, transmute([]u8)string("\n"))
}

// history_visit records a visit. Consecutive visits to the same URL within a
// minute fold into one, so a reload is not ten entries.
history_visit :: proc(h: ^History, url, title: string) {
	if url == "" || is_internal(url) || strings.has_prefix(url, "about:") || strings.has_prefix(url, "data:") {
		return
	}
	now := now_ms()
	if n := len(h.visits); n > 0 {
		last := &h.visits[n - 1]
		if last.url == url && now - last.at < 60_000 {
			if title != "" && title != last.title {
				last.title = strings.clone(title)
				history_append_line(h, last^)
			}
			return
		}
	}
	v := Visit {
		id     = new_uuid(),
		url    = strings.clone(url),
		title  = strings.clone(title),
		at     = now,
		device = h.device,
	}
	append(&h.visits, v)
	history_append_line(h, v)
}

// history_title updates the title of the latest visit of `url`, which arrives
// after the URL does.
history_title :: proc(h: ^History, url, title: string) {
	for i := len(h.visits) - 1; i >= 0 && i >= len(h.visits) - 20; i -= 1 {
		if h.visits[i].url == url {
			if h.visits[i].title != title {
				h.visits[i].title = strings.clone(title)
				history_append_line(h, h.visits[i])
			}
			return
		}
	}
}

history_forget_all :: proc(h: ^History) -> int {
	n := len(h.visits)
	history_append_line(h, Visit{forget_before = now_ms(), device = h.device})
	clear(&h.visits)
	return n
}

history_forget_url :: proc(h: ^History, url: string) -> int {
	n := 0
	w := 0
	for v in h.visits {
		if v.url == url {
			n += 1
			continue
		}
		h.visits[w] = v
		w += 1
	}
	resize(&h.visits, w)
	history_append_line(h, Visit{forget_url = url, at = now_ms(), device = h.device})
	return n
}

// compact rewrites the log without what tombstones hide.
history_compact :: proc(h: ^History) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	for v in h.visits {
		data, err := json.marshal(v, {}, context.temp_allocator)
		if err != nil {
			continue
		}
		strings.write_string(&sb, string(data))
		strings.write_byte(&sb, '\n')
	}
	return write_atomic(h.path, transmute([]u8)strings.to_string(sb))
}

// Suggestion is one row of the omnibox dropdown.
Suggestion_Kind :: enum u8 {
	Search,
	Url,
	Bookmark,
	History,
	Tab,
	Page, // an internal page
}

Suggestion :: struct {
	kind:  Suggestion_Kind,
	title: string,
	url:   string,
	score: f32,
}

// history_top is the most visited sites, newest visit breaking ties, for the
// new tab page.
Site :: struct {
	url:   string,
	title: string,
	host:  string,
	count: int,
	last:  i64,
}

history_top :: proc(h: ^History, n: int, allocator := context.allocator) -> []Site {
	by := make(map[string]int, context.temp_allocator)
	sites := make([dynamic]Site, context.temp_allocator)
	for v in h.visits {
		host := url_host(v.url)
		if host == "" {
			continue
		}
		if i, ok := by[host]; ok {
			sites[i].count += 1
			if v.at >= sites[i].last {
				sites[i].last = v.at
				// the shortest URL seen for the host is usually its front page
				if len(v.url) < len(sites[i].url) {
					sites[i].url = v.url
					sites[i].title = v.title
				}
			}
		} else {
			by[host] = len(sites)
			append(&sites, Site{url = v.url, title = v.title, host = host, count = 1, last = v.at})
		}
	}
	slice.sort_by(sites[:], proc(a, b: Site) -> bool {
		if a.count != b.count {
			return a.count > b.count
		}
		return a.last > b.last
	})
	out := make([]Site, min(n, len(sites)), allocator)
	copy(out, sites[:len(out)])
	return out
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

Download :: struct {
	id:       u32 `json:"-"`,
	url:      string `json:"url"`,
	path:     string `json:"path"`,
	mime:     string `json:"mime"`,
	received: i64 `json:"received"`,
	total:    i64 `json:"total"`,
	state:    string `json:"state"`, // progress, done, cancelled, failed
	started:  i64 `json:"started"`,
	view:     int `json:"-"`,
}

Download_File :: struct {
	items: [dynamic]Download `json:"items"`,
}

downloads_load :: proc(path: string) -> [dynamic]Download {
	f: Download_File
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil {
		json.unmarshal(data, &f)
	}
	// an interrupted download from a previous run did not finish
	for &d in f.items {
		if d.state == "progress" {
			d.state = "failed"
		}
	}
	return f.items
}

downloads_save :: proc(path: string, items: []Download) {
	f := Download_File{}
	f.items = make([dynamic]Download, context.temp_allocator)
	start := max(0, len(items) - 200)
	append(&f.items, ..items[start:])
	data, err := json.marshal(f, {pretty = true, use_spaces = true, spaces = 1}, context.temp_allocator)
	if err == nil {
		write_atomic(path, data)
	}
}

// ---------------------------------------------------------------------------
// The session: which tabs were open
// ---------------------------------------------------------------------------

Session_Tab :: struct {
	url:   string `json:"url"`,
	title: string `json:"title"`,
}

Session :: struct {
	tabs:   [dynamic]Session_Tab `json:"tabs"`,
	active: int `json:"active"`,
}

session_load :: proc(path: string) -> Session {
	s: Session
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil {
		json.unmarshal(data, &s)
	}
	return s
}

session_save :: proc(path: string, s: Session) {
	data, err := json.marshal(s, {pretty = true, use_spaces = true, spaces = 1}, context.temp_allocator)
	if err == nil {
		write_atomic(path, data)
	}
}

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

is_internal :: proc(url: string) -> bool {
	return strings.has_prefix(url, "palm://")
}

url_host :: proc(url: string) -> string {
	s := url
	if i := strings.index(s, "://"); i >= 0 {
		s = s[i + 3:]
	} else {
		return ""
	}
	if i := strings.index_any(s, "/?#"); i >= 0 {
		s = s[:i]
	}
	if i := strings.last_index_byte(s, '@'); i >= 0 {
		s = s[i + 1:]
	}
	if i := strings.last_index_byte(s, ':'); i >= 0 && !strings.contains(s, "]") {
		s = s[:i]
	}
	return strings.trim_prefix(s, "www.")
}

url_scheme :: proc(url: string) -> string {
	if i := strings.index(url, "://"); i > 0 {
		return url[:i]
	}
	if i := strings.index_byte(url, ':'); i > 0 {
		return url[:i]
	}
	return ""
}

// display_url is what the omnibox shows when it is not being edited: the
// scheme for https and a trailing slash dropped.
display_url :: proc(url: string) -> string {
	s := url
	s = strings.trim_prefix(s, "https://")
	if strings.count(s, "/") == 1 && strings.has_suffix(s, "/") {
		s = s[:len(s) - 1]
	}
	return s
}

url_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for b in transmute([]u8)s {
		switch b {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~':
			strings.write_byte(&sb, b)
		case ' ':
			strings.write_byte(&sb, '+')
		case:
			fmt.sbprintf(&sb, "%%%02X", b)
		}
	}
	return strings.to_string(sb)
}

// resolve_input turns what was typed into the omnibox into a URL: a URL as
// typed, a bare host with a dot, localhost, an internal page -- or a search.
resolve_input :: proc(text: string, search: Search_Engine, allocator := context.allocator) -> (url: string, is_search: bool) {
	t := strings.trim_space(text)
	if t == "" {
		return "", false
	}
	lower := strings.to_lower(t, context.temp_allocator)
	if strings.has_prefix(lower, "palm://") || strings.has_prefix(lower, "about:") ||
	   strings.has_prefix(lower, "file://") || strings.has_prefix(lower, "data:") ||
	   strings.has_prefix(lower, "view-source:") {
		return strings.clone(t, allocator), false
	}
	if strings.contains(t, "://") && !strings.contains(t, " ") {
		return strings.clone(t, allocator), false
	}
	if strings.has_prefix(t, "/") && !strings.contains(t, " ") {
		return fmt.aprintf("file://%s", t, allocator = allocator), false
	}
	if !strings.contains(t, " ") {
		host := t
		if i := strings.index_any(host, "/?#"); i >= 0 {
			host = host[:i]
		}
		hl := strings.to_lower(host, context.temp_allocator)
		if strings.has_prefix(hl, "localhost") || is_ipv4_host(hl) {
			return fmt.aprintf("http://%s", t, allocator = allocator), false
		}
		if strings.contains(host, ".") && !strings.has_suffix(host, ".") && !strings.has_prefix(host, ".") {
			tld := host[strings.last_index_byte(host, '.') + 1:]
			if i := strings.index_byte(tld, ':'); i >= 0 {
				tld = tld[:i]
			}
			if len(tld) >= 2 && is_alpha(tld) {
				return fmt.aprintf("https://%s", t, allocator = allocator), false
			}
		}
	}
	q, _ := strings.replace_all(search.query, "%s", url_escape(t), context.temp_allocator)
	return strings.clone(q, allocator), true
}

@(private = "file")
is_alpha :: proc(s: string) -> bool {
	for c in s {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
			return false
		}
	}
	return true
}

@(private = "file")
is_ipv4_host :: proc(s: string) -> bool {
	h := s
	if i := strings.index_byte(h, ':'); i >= 0 {
		h = h[:i]
	}
	parts := strings.split(h, ".", context.temp_allocator)
	if len(parts) != 4 {
		return false
	}
	for p in parts {
		if p == "" || len(p) > 3 {
			return false
		}
		for c in p {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}
