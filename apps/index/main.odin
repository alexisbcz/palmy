// index — the local search index: one per identity, on this device.
//
//	index search <query…> [--identity H] [--limit N] [--order relevance|newest|oldest] --json
//	index status [--identity H] --json
//	index identities --json
//	index rebuild --identity H
//	index daemon [--once] [--verbose]          (palm-indexd is the same loop)
//	index --selftest
//
// `index search --json` is the assistant's tool (apps/ai): its output is a
// documented, stable object (cloud/docs/search.md, "The CLI"). Scope is
// $PALM_IDENTITY, which --identity may narrow and never widen: a scoped
// caller gets its own identity's results and nothing that says the others
// exist, and the files of other identities' indexes are not opened at all.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import ic "core"
import feed "feed"
import kit "kit:."

RESULT_FIELDS := []kit.Field {
	{name = "identity", kind = .String, help = "the handle of the identity the result belongs to; always present"},
	{name = "identity_name", kind = .String},
	{name = "kind", kind = .String, help = "mail event task doc file note chat person page issue"},
	{name = "title", kind = .String},
	{name = "title_marks", kind = .Array, help = "[start, end) byte ranges of matches in title"},
	{name = "who", kind = .String, help = "sender and recipients, organiser, author"},
	{name = "detail", kind = .String, help = "folder, place, path"},
	{name = "snippet", kind = .String, opt = true},
	{name = "marks", kind = .Array, opt = true, help = "[start, end) byte ranges of matches in snippet"},
	{name = "time", kind = .Int, help = "unix seconds: received, modified, starts"},
	{name = "date", kind = .String, help = "the same, ISO 8601 UTC"},
	{name = "minutes", kind = .Int, opt = true, help = "events: duration"},
	{name = "flags", kind = .Array, help = "unread waiting attachment done flagged sent opened"},
	{name = "key", kind = .String, help = "stable id of the item inside its identity's index"},
	{name = "uri", kind = .String, help = "palm://<identity>/<kind>/<id>, a path, or a URL"},
	{name = "app", kind = .String},
	{name = "open", kind = .Array, help = "argv that opens it in its application, in its identity"},
	{name = "open_exact", kind = .Bool, help = "the application goes to the item itself, not only near it"},
	{name = "score", kind = .Float},
}

SEARCH_FIELDS := []kit.Field {
	{name = "query", kind = .String},
	{name = "scope", kind = .String, help = "\"all\" or the one identity searched"},
	{name = "identities", kind = .Array, help = "the identities searched: handle, name, kind, color"},
	{name = "results", kind = .Array, of = RESULT_FIELDS},
	{name = "count", kind = .Int, help = "results returned"},
	{name = "matched", kind = .Int, help = "documents that matched, before the limit"},
	{name = "searched", kind = .Int, help = "documents in the indexes searched"},
	{name = "per_kind", kind = .Object},
	{name = "per_identity", kind = .Object},
	{name = "corrections", kind = .Array, help = "typo corrections applied: {from, to}"},
	{name = "unknown", kind = .Array, help = "operators not understood (the search ran without them)"},
	{name = "took_ms", kind = .Float},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "search",
		summary = "search the identities in scope; results are labelled with their identity",
		effect = .Read,
		args = {{name = "query", kind = .String, required = true, variadic = true, help = "words and operators: in: type: is: has: from: before: after: \"phrase\" -word"}},
		flags = {
			{name = "limit", kind = .Int, def = "20", help = "results to return"},
			{name = "per-kind", kind = .Int, def = "0", help = "at most this many of one kind (0: no cap)"},
			{name = "order", kind = .Enum, values = {"relevance", "newest", "oldest"}, def = "relevance"},
			{name = "typing", kind = .Bool, help = "the last word is unfinished: match it as a prefix"},
			{name = "no-snippets", kind = .Bool},
		},
		out = SEARCH_FIELDS,
		examples = {
			"index search roadmap --json",
			"PALM_IDENTITY=northwind index search \"from:priya is:unread\" --json",
			"index search \"type:event after:today before:7d\" --order oldest",
		},
		run = cmd_search,
	},
	{
		verb = "status",
		summary = "what is indexed, per identity and source, and whether the daemon runs",
		effect = .Read,
		out = {
			{name = "daemon", kind = .Object, help = "{running, pid}"},
			{name = "root", kind = .String},
			{name = "identities", kind = .Array, help = "per identity: handle, name, docs, bytes, segments, state, kinds, sources"},
			{name = "unclaimed", kind = .Array, help = "data folders naming no identity, not indexed"},
		},
		examples = {"index status --json"},
		run = cmd_status,
	},
	{
		verb = "identities",
		summary = "the identities this device has an index for, within scope",
		effect = .Read,
		out = {{name = "identities", kind = .Array}},
		examples = {"index identities --json"},
		run = cmd_identities,
	},
	{
		verb = "rebuild",
		summary = "drop one identity's index and build it again from its sources",
		effect = .Idempotent,
		out = {{name = "identity", kind = .String}, {name = "how", kind = .String, help = "\"daemon\" (asked the running daemon) or \"here\""}, {name = "docs", kind = .Int, opt = true}},
		examples = {"index rebuild --identity northwind"},
		run = cmd_rebuild,
	},
	{
		verb = "daemon",
		summary = "run the indexer in the foreground (palm-indexd)",
		effect = .Mutate,
		flags = {{name = "once", kind = .Bool, help = "scan everything once, then exit"}},
		out = {{name = "identities", kind = .Int}},
		examples = {"index daemon --verbose"},
		run = cmd_daemon,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "index",
			summary  = "the local search index, one per identity",
			selftest = run_selftest,
			commands = COMMANDS,
			notes    = "Scope is $PALM_IDENTITY, narrowed by --identity, never widened. Unscoped, search covers every identity on this device and labels each result. cloud/docs/search.md documents the query language and the JSON.",
		}
	}
	return &g_surface
}

main :: proc() {
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	fmt.print(kit.cli_help_text(surface()))
}

FLAG_NAMES := [ic.Flag]string {
	.Unread     = "unread",
	.Waiting    = "waiting",
	.Attachment = "attachment",
	.Done       = "done",
	.Flagged    = "flagged",
	.Sent       = "sent",
	.Opened     = "opened",
}

iso :: proc(t: i64) -> string {
	if t == 0 {
		return ""
	}
	tm := time.unix(t, 0)
	y, mo, d := time.date(tm)
	h, mi, s := time.clock(tm)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

marks_json :: proc(ms: []ic.Mark) -> ^kit.Json {
	a := kit.jarr()
	for m in ms {
		p := kit.jarr()
		kit.jpush(p, kit.jint(m[0]))
		kit.jpush(p, kit.jint(m[1]))
		kit.jpush(a, p)
	}
	return a
}

// open_targets opens the indexes of the identities in scope, and only
// those: the scoped path never lists the root or reads another
// identity's files.
open_targets :: proc(root, scope: string) -> (ids: [dynamic]feed.Ident, targets: [dynamic]ic.Target) {
	ids = feed.identities_visible(root, scope)
	targets = make([dynamic]ic.Target)
	for x in ids {
		ix, ok := ic.index_open(root, x.handle)
		if ok {
			append(&targets, ic.Target{ident = x.info, ix = ix})
		}
	}
	return
}

cmd_search :: proc(c: ^kit.Call) -> int {
	text := strings.join(kit.cli_rest(c), " ", context.temp_allocator)
	if v := kit.cli_str(c, "query"); v != "" && len(kit.cli_rest(c)) == 0 {
		text = v
	}
	paths := feed.paths_default()
	ids, targets := open_targets(paths.index, c.identity)
	if c.identity != "" && len(targets) == 0 {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no index for %q on this device", c.identity)
	}
	defer for t in targets {
		ic.index_close(t.ix)
	}
	now := time.to_unix_seconds(time.now())
	q := ic.parse_query(text, now, kit.cli_bool(c, "typing"))

	// in: narrows to the identities it names, among those in scope.
	if len(q.in_words) > 0 {
		keep := make([dynamic]ic.Target, context.temp_allocator)
		for t in targets {
			for w in q.in_words {
				if ident_matches(t.ident, w) {
					append(&keep, t)
					break
				}
			}
		}
		if len(keep) == 0 {
			// An in: that names nothing in scope is reported, never widened.
			for w in q.in_words {
				append(&q.unknown, fmt.tprintf("in:%s", w))
			}
		}
		targets_ := keep
		return search_out(c, text, &q, ids[:], targets_[:], paths)
	}
	return search_out(c, text, &q, ids[:], targets[:], paths)
}

// ident_matches is in:'s rule: a prefix of the name or handle, or the kind
// (in:work).
ident_matches :: proc(i: ic.Identity, w: string) -> bool {
	lw := strings.to_lower(w, context.temp_allocator)
	return strings.has_prefix(strings.to_lower(i.name, context.temp_allocator), lw) || strings.has_prefix(i.handle, lw) || i.kind == lw
}

search_out :: proc(c: ^kit.Call, text: string, q: ^ic.Query, ids: []feed.Ident, targets: []ic.Target, paths: feed.Paths) -> int {
	order := kit.cli_str(c, "order")
	opt := ic.Options {
		limit    = kit.cli_int(c, "limit", 20),
		per_kind = kit.cli_int(c, "per-kind", 0),
		typing   = kit.cli_bool(c, "typing"),
		snippets = !kit.cli_bool(c, "no-snippets"),
	}
	switch order {
	case "newest":
		opt.order = .Newest
	case "oldest":
		opt.order = .Oldest
	}
	out := make([dynamic]ic.Result, context.temp_allocator)
	st: ic.Stats
	ic.search_all(targets, q, opt, &out, &st)

	o := kit.jobj()
	kit.jset_str(o, "query", text)
	kit.jset_str(o, "scope", c.identity == "" ? "all" : c.identity)
	ia := kit.jarr()
	for t in targets {
		io := kit.jobj()
		kit.jset_str(io, "handle", t.ident.handle)
		kit.jset_str(io, "name", t.ident.name)
		kit.jset_str(io, "kind", t.ident.kind)
		kit.jset_str(io, "color", t.ident.color)
		kit.jpush(ia, io)
	}
	kit.jset(o, "identities", ia)
	ra := kit.jarr()
	per_id := make(map[string]int, allocator = context.temp_allocator)
	for r in out {
		ident: feed.Ident
		for x in ids {
			if x.handle == r.handle {
				ident = x
			}
		}
		ro := kit.jobj()
		kit.jset_str(ro, "identity", r.handle)
		kit.jset_str(ro, "identity_name", ident.name)
		kit.jset_str(ro, "kind", ic.KIND_NAME[r.kind])
		kit.jset_str(ro, "title", r.title)
		kit.jset(ro, "title_marks", marks_json(r.title_marks))
		kit.jset_str(ro, "who", r.who)
		kit.jset_str(ro, "detail", r.detail)
		if opt.snippets {
			kit.jset_str(ro, "snippet", r.snippet)
			kit.jset(ro, "marks", marks_json(r.marks))
		}
		kit.jset_i64(ro, "time", r.time)
		kit.jset_str(ro, "date", iso(r.time))
		if r.kind == .Event {
			kit.jset_int(ro, "minutes", int(r.dur))
		}
		fa := kit.jarr()
		for f in ic.Flag {
			if f in r.flags {
				kit.jpush(fa, kit.jstr(FLAG_NAMES[f]))
			}
		}
		kit.jset(ro, "flags", fa)
		kit.jset_str(ro, "key", r.key)
		kit.jset_str(ro, "uri", r.uri)
		kit.jset_str(ro, "app", r.app)
		op := feed.open_command(r, ident, paths)
		aa := kit.jarr()
		for a in op.argv {
			kit.jpush(aa, kit.jstr(a))
		}
		kit.jset(ro, "open", aa)
		kit.jset_bool(ro, "open_exact", op.exact)
		kit.jset_num(ro, "score", f64(r.score))
		kit.jpush(ra, ro)
		per_id[r.handle] += 1
	}
	kit.jset(o, "results", ra)
	kit.jset_int(o, "count", len(out))
	kit.jset_int(o, "matched", st.matched)
	kit.jset_int(o, "searched", st.searched)
	pk := kit.jobj()
	for n, k in st.per_kind {
		if n > 0 {
			kit.jset_int(pk, ic.KIND_NAME[k], n)
		}
	}
	kit.jset(o, "per_kind", pk)
	pi := kit.jobj()
	for t in targets {
		kit.jset_int(pi, t.ident.handle, per_id[t.ident.handle])
	}
	kit.jset(o, "per_identity", pi)
	ca := kit.jarr()
	for cr in st.corrections {
		co := kit.jobj()
		kit.jset_str(co, "from", cr.from)
		kit.jset_str(co, "to", cr.to)
		kit.jpush(ca, co)
	}
	kit.jset(o, "corrections", ca)
	ua := kit.jarr()
	for u in q.unknown {
		kit.jpush(ua, kit.jstr(u))
	}
	kit.jset(o, "unknown", ua)
	kit.jset_num(o, "took_ms", f64(st.took_us) / 1000)
	c.out = o
	if !c.json {
		print_results(o, out[:], ids, st, q)
		c.out = kit.jobj()
	}
	return kit.EXIT_OK
}

// print_results is the human rendering: one line per result, labelled.
print_results :: proc(o: ^kit.Json, out: []ic.Result, ids: []feed.Ident, st: ic.Stats, q: ^ic.Query) {
	for r in out {
		name := r.handle
		for x in ids {
			if x.handle == r.handle {
				name = x.name
			}
		}
		fmt.printfln("%-6s %-22s  %s  ● %s", ic.KIND_NAME[r.kind], trunc(r.title, 60), iso(r.time)[:min(10, len(iso(r.time)))], name)
		if r.snippet != "" {
			fmt.printfln("       %s", trunc(r.snippet, 100))
		}
	}
	for cr in st.corrections {
		fmt.printfln("(searched for %q instead of %q)", cr.to, cr.from)
	}
	for u in q.unknown {
		fmt.eprintfln("index: %q is not an operator this search knows; it was ignored", u)
	}
	fmt.printfln("%d of %d matches, %d items searched on this device in %.1f ms. Nothing left the machine.", len(out), st.matched, st.searched, f64(st.took_us) / 1000)
}

trunc :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	k := n
	for k > 0 && s[k] & 0xc0 == 0x80 {
		k -= 1
	}
	return fmt.tprintf("%s…", s[:k])
}

cmd_identities :: proc(c: ^kit.Call) -> int {
	paths := feed.paths_default()
	ids := feed.identities_visible(paths.index, c.identity)
	o := kit.jobj()
	a := kit.jarr()
	for x in ids {
		io := kit.jobj()
		kit.jset_str(io, "handle", x.handle)
		kit.jset_str(io, "name", x.name)
		kit.jset_str(io, "kind", x.kind)
		kit.jset_str(io, "color", x.color)
		kit.jset_str(io, "address", x.address)
		kit.jset_str(io, "id", x.id)
		kit.jpush(a, io)
	}
	kit.jset(o, "identities", a)
	c.out = o
	return kit.EXIT_OK
}

cmd_status :: proc(c: ^kit.Call) -> int {
	paths := feed.paths_default()
	o := kit.jobj()
	pid, running := feed.daemon_pid(paths.index)
	dm := kit.jobj()
	kit.jset_bool(dm, "running", running)
	if running {
		kit.jset_int(dm, "pid", pid)
	}
	kit.jset(o, "daemon", dm)
	kit.jset_str(o, "root", paths.index)
	ids := feed.identities_visible(paths.index, c.identity)
	a := kit.jarr()
	for x in ids {
		io := kit.jobj()
		kit.jset_str(io, "handle", x.handle)
		kit.jset_str(io, "name", x.name)
		ix, ok := ic.index_open(paths.index, x.handle)
		if ok {
			kit.jset_int(io, "docs", ix.ndocs)
			kit.jset_int(io, "segments", len(ix.segs))
			kit.jset_i64(io, "bytes", ic.index_bytes(ix))
			ic.index_close(ix)
		}
		if data, err := os.read_entire_file_from_path(fmt.tprintf("%s/%s/status", paths.index, x.handle), context.temp_allocator); err == nil {
			if v, pok := json_tree(data); pok {
				for key in ([?]string{"state", "updated", "kinds", "sources"}) {
					if f, fok := kit.jget(v, key); fok {
						kit.jset(io, key, f)
					}
				}
			}
		}
		kit.jpush(a, io)
	}
	kit.jset(o, "identities", a)
	ua := kit.jarr()
	if c.identity == "" {
		all := feed.discover(paths)
		for u in feed.unclaimed(paths, all[:]) {
			kit.jpush(ua, kit.jstr(u))
		}
	}
	kit.jset(o, "unclaimed", ua)
	c.out = o
	if !c.json {
		fmt.printfln("daemon: %s", running ? fmt.tprintf("running (pid %d)", pid) : "not running")
		for x in ids {
			ix, ok := ic.index_open(paths.index, x.handle)
			if ok {
				fmt.printfln("%-14s %s items, %s, %d segment(s)", x.handle, fmt.tprint(ix.ndocs), size_words(ic.index_bytes(ix)), len(ix.segs))
				ic.index_close(ix)
			}
		}
		for i in 0 ..< kit.jlen(ua) {
			fmt.printfln("not indexed: %s", ua.items[i].s)
		}
		c.out = kit.jobj()
	}
	return kit.EXIT_OK
}

cmd_rebuild :: proc(c: ^kit.Call) -> int {
	h := c.identity
	if h == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "rebuild needs --identity: one identity at a time")
	}
	if !ic.handle_ok(h) {
		return kit.cli_failf(c, kit.EXIT_USAGE, "not an identity handle: %q", h)
	}
	paths := feed.paths_default()
	o := kit.jobj()
	kit.jset_str(o, "identity", h)
	if _, running := feed.daemon_pid(paths.index); running {
		// The daemon holds the lock; ask it.
		dir := fmt.tprintf("%s/%s", paths.index, h)
		if !os.is_dir(dir) {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no index for %q on this device", h)
		}
		if c.dry_run {
			kit.jset_str(o, "how", "daemon")
			c.out = o
			return kit.EXIT_OK
		}
		if os.write_entire_file(fmt.tprintf("%s/rebuild", dir), transmute([]u8)string("1\n"), os.perm_number(0o600)) != nil {
			return kit.cli_fail(c, kit.EXIT_FAILED, "could not ask the daemon")
		}
		kit.jset_str(o, "how", "daemon")
		c.out = o
		return kit.EXIT_OK
	}
	kit.jset_str(o, "how", "here")
	if c.dry_run {
		c.out = o
		return kit.EXIT_OK
	}
	d: feed.Daemon
	if err := feed.daemon_init(&d, paths, h); err != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	if len(d.ids) == 0 {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%q names no identity on this device", h)
	}
	feed.rebuild(&d, h)
	d.once = true
	d.battery_at = feed.now_ms() // a rebuild asked for by hand runs now
	feed.daemon_run(&d)
	if w := d.writers[h]; w != nil {
		kit.jset_int(o, "docs", w.ix.ndocs)
	}
	feed.daemon_close(&d)
	c.out = o
	return kit.EXIT_OK
}

cmd_daemon :: proc(c: ^kit.Call) -> int {
	return feed.daemon_main(c.identity, kit.cli_bool(c, "once"), c.verbose)
}

// json_tree reads a JSON document (a status file) into kit's tree, so it can
// be embedded in a command's output.
json_tree :: proc(data: []u8) -> (^kit.Json, bool) {
	v, err := json.parse(data, allocator = context.temp_allocator)
	if err != nil {
		return nil, false
	}
	conv :: proc(v: json.Value) -> ^kit.Json {
		switch x in v {
		case json.Null:
			return kit.jnull()
		case json.Boolean:
			return kit.jbool(bool(x))
		case json.Integer:
			return kit.ji64(i64(x))
		case json.Float:
			return kit.jnum(f64(x))
		case json.String:
			return kit.jstr(string(x))
		case json.Array:
			a := kit.jarr()
			for e in x {
				kit.jpush(a, conv(e))
			}
			return a
		case json.Object:
			o := kit.jobj()
			// Map order is the hasher's; sort the keys so output is stable.
			keys := make([dynamic]string, context.temp_allocator)
			for k in x {
				append(&keys, k)
			}
			slice.sort(keys[:])
			for k in keys {
				kit.jset(o, k, conv(x[k]))
			}
			return o
		}
		return kit.jnull()
	}
	return conv(v), true
}

size_words :: proc(n: i64) -> string {
	switch {
	case n >= 1_000_000:
		return fmt.tprintf("%.1f MB", f64(n) / 1e6)
	case n >= 1000:
		return fmt.tprintf("%.0f kB", f64(n) / 1e3)
	}
	return fmt.tprintf("%d bytes", n)
}
