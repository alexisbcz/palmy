package main

// The command-line front end: `calendar <verb>`, or `palm calendar <verb>`.
//
// The verbs go through the same engine as the window (cloud.odin): the same
// local copies, the same sync, the same iCalendar. Scope follows
// docs/PALM-CLI.md: PALM_IDENTITY, narrowed by --identity, limits every verb
// to one identity, and asking for another one exits 5. The database refuses
// the rest regardless (cloud/supabase/migrations/20261019600000_dav.sql).
//
// Passwords never go through standard input. Give one with --password-file,
// or PALM_CLOUD_PASSWORD, or --password on a development stack.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import ck "../cloudkit"
import ical "../../cloud/dav/ical"
import kit "kit:."

@(private = "file")
CAL_FIELDS :: []kit.Field {
	{name = "key", kind = .String, help = "<identity>/<calendar>, or local"},
	{name = "identity", kind = .String},
	{name = "name", kind = .String},
	{name = "color", kind = .String},
	{name = "access", kind = .String, help = "owner, read or read-write"},
	{name = "owner", kind = .String},
	{name = "events", kind = .Int, help = "calendar objects in the local copy"},
}

@(private = "file")
EVENT_FIELDS :: []kit.Field {
	{name = "date", kind = .String},
	{name = "start", kind = .String, help = "HH:MM local, or \"\" for all day"},
	{name = "minutes", kind = .Int},
	{name = "title", kind = .String},
	{name = "place", kind = .String},
	{name = "calendar", kind = .String},
	{name = "uid", kind = .String, opt = true},
	{name = "recurring", kind = .Bool},
	{name = "cancelled", kind = .Bool},
	{name = "attendees", kind = .Array, opt = true, help = "address and PARTSTAT of each attendee"},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "whether this machine is signed in, and what is waiting to sync",
		effect = .Read,
		out = {
			{name = "signed_in", kind = .Bool},
			{name = "email", kind = .String, opt = true},
			{name = "dav", kind = .String},
			{name = "pending", kind = .Int, help = "local changes not yet on the server"},
		},
		examples = {"calendar status --json"},
		run = cmd_status,
	},
	{
		verb = "signin",
		summary = "sign in to the Palmy account (the same session Accounts uses)",
		effect = .Mutate,
		args = {{name = "email", kind = .String, required = true}},
		flags = {
			{name = "password", kind = .String, secret = true, help = "development stacks only; prefer --password-file"},
			{name = "password-file", kind = .Path},
		},
		out = {{name = "email", kind = .String}},
		examples = {"calendar signin alice@example.test --password-file ~/.pw"},
		run = cmd_signin,
	},
	{
		verb = "sync",
		summary = "push local changes and pull the server's, for every calendar",
		effect = .Idempotent,
		out = {
			{name = "pushed", kind = .Int},
			{name = "pulled", kind = .Int},
			{name = "removed", kind = .Int},
			{name = "conflicts", kind = .Int},
			{name = "invitations", kind = .Int},
		},
		examples = {"calendar sync --json", "PALM_IDENTITY=alice-work calendar sync"},
		run = cmd_sync,
	},
	{
		verb = "list",
		summary = "the calendars, per identity: own and shared",
		effect = .Read,
		out = {{name = "calendars", kind = .Array, of = CAL_FIELDS}, {name = "count", kind = .Int}},
		examples = {"calendar list --json"},
		run = cmd_list,
	},
	{
		verb = "events",
		summary = "events between two dates, recurring ones expanded",
		effect = .Read,
		flags = {
			{name = "from", kind = .String, help = "YYYY-MM-DD, default today"},
			{name = "to", kind = .String, help = "YYYY-MM-DD, exclusive; default from + 7 days"},
			{name = "calendar", kind = .String, help = "only this calendar key"},
		},
		out = {{name = "events", kind = .Array, of = EVENT_FIELDS}, {name = "count", kind = .Int}},
		examples = {"calendar events --from 2026-10-19 --to 2026-10-26 --json"},
		run = cmd_events,
	},
	{
		verb = "next",
		summary = "the next event from now",
		effect = .Read,
		out = EVENT_FIELDS,
		examples = {"calendar next --json"},
		run = cmd_next,
	},
	{
		verb = "add",
		summary = "add an event (and invite people, which sends the invitations)",
		effect = .Mutate,
		args = {{name = "title", kind = .String, required = true}},
		flags = {
			{name = "date", kind = .String, help = "YYYY-MM-DD", required = true},
			{name = "time", kind = .String, help = "HH:MM local; omit for all day"},
			{name = "minutes", kind = .Int, def = "60"},
			{name = "place", kind = .String},
			{name = "calendar", kind = .String, help = "a calendar key; default the identity's first calendar, else local"},
			{name = "rrule", kind = .String, help = "an RRULE, e.g. FREQ=WEEKLY;COUNT=10"},
			{name = "attendee", kind = .String, help = "comma-separated addresses; a bare handle is <handle>@palm.test"},
		},
		out = {{name = "calendar", kind = .String}, {name = "uid", kind = .String}, {name = "name", kind = .String}, {name = "synced", kind = .Bool}},
		examples = {"calendar add \"Planning\" --identity alice-work --date 2026-10-20 --time 10:00 --rrule FREQ=WEEKLY;COUNT=8 --attendee bob --json"},
		run = cmd_add,
	},
	{
		verb = "delete",
		summary = "delete an event, or one occurrence of a recurring one",
		effect = .Destructive,
		args = {{name = "uid", kind = .String, required = true}},
		flags = {{name = "occurrence", kind = .String, help = "YYYY-MM-DD: only that day's occurrence"}},
		out = {{name = "uid", kind = .String}, {name = "calendar", kind = .String}},
		examples = {"calendar delete 1a2b@palmy --occurrence 2026-10-27 --yes"},
		run = cmd_delete,
	},
	{
		verb = "invitations",
		summary = "invitations waiting for an answer, across identities",
		effect = .Read,
		out = {
			{
				name = "invitations",
				kind = .Array,
				of = {
					{name = "uid", kind = .String},
					{name = "title", kind = .String},
					{name = "identity", kind = .String},
					{name = "organizer", kind = .String},
					{name = "start", kind = .String},
					{name = "calendar", kind = .String},
				},
			},
			{name = "count", kind = .Int},
		},
		examples = {"calendar invitations --json"},
		run = cmd_invitations,
	},
	{
		verb = "accept",
		summary = "accept an invitation (the organizer is told)",
		effect = .Idempotent,
		args = {{name = "uid", kind = .String, required = true}},
		out = {{name = "uid", kind = .String}, {name = "partstat", kind = .String}},
		examples = {"calendar accept 1a2b@palmy"},
		run = cmd_accept,
	},
	{
		verb = "decline",
		summary = "decline an invitation (the organizer is told)",
		effect = .Idempotent,
		args = {{name = "uid", kind = .String, required = true}},
		out = {{name = "uid", kind = .String}, {name = "partstat", kind = .String}},
		examples = {"calendar decline 1a2b@palmy"},
		run = cmd_decline,
	},
	{
		verb = "share",
		summary = "share one of your calendars with another identity",
		effect = .Idempotent,
		flags = {
			{name = "calendar", kind = .String, required = true, help = "a calendar key you own"},
			{name = "with", kind = .String, required = true, help = "the other identity's address or handle"},
			{name = "access", kind = .Enum, values = {"read", "read-write"}, def = "read"},
		},
		out = {{name = "calendar", kind = .String}, {name = "with", kind = .String}, {name = "access", kind = .String}},
		examples = {"calendar share --calendar alice/default --with bob@palm.test --access read"},
		run = cmd_share,
	},
	{
		verb = "unshare",
		summary = "revoke a share",
		effect = .Destructive,
		flags = {
			{name = "calendar", kind = .String, required = true},
			{name = "with", kind = .String, required = true},
		},
		out = {{name = "calendar", kind = .String}, {name = "with", kind = .String}, {name = "removed", kind = .Int}},
		examples = {"calendar unshare --calendar alice/default --with bob@palm.test --yes"},
		run = cmd_unshare,
	},
	{
		verb = "app-password",
		summary = "passwords for other CalDAV/CardDAV clients, one identity each",
		effect = .Mutate,
		args = {
			{name = "action", kind = .Enum, values = {"create", "list", "revoke"}, required = true},
			{name = "id", kind = .String, help = "revoke: the password's id"},
		},
		flags = {{name = "label", kind = .String, help = "create: what it is for, e.g. Thunderbird"}},
		out = {
			{name = "identity", kind = .String},
			{name = "secret", kind = .String, opt = true, help = "create: shown once"},
			{name = "username", kind = .String, opt = true},
			{name = "url", kind = .String, opt = true},
			{name = "passwords", kind = .Array, opt = true},
		},
		examples = {"calendar app-password create --identity alice --label Thunderbird --json", "calendar app-password list --identity alice"},
		run = cmd_app_password,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "calendar",
			summary  = "a month grid of your calendars: this device, and every identity's in the Palmy cloud",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `The account is the one Accounts signs in (cloudkit's token store,
$PALM_CLOUD_DIR); calendars sync over CalDAV with palm-davd at $PALM_DAV_URL
(default http://127.0.0.1:59580). Local copies live in $PALM_DAV_CACHE
(default ~/.local/share/palm/dav); the device calendar is
~/.local/share/palmy-calendar/events.tsv.

A calendar key is <identity>/<calendar>, e.g. alice-work/default; a calendar
shared with you appears in your home as <you>/<owner>~<calendar>.`

// ---------------------------------------------------------------------------
// Opening, with scope
// ---------------------------------------------------------------------------

@(private = "file")
open_cloud :: proc(c: ^kit.Call, cl: ^Cloud, need_sign_in := true) -> int {
	cloud_open(cl, c.identity)
	if need_sign_in && !cl.signed {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "not signed in: calendar signin EMAIL, or sign in with Accounts")
	}
	if c.identity != "" && cl.signed {
		// The identity list comes from the server when we can reach it.
		_, _ = cloud_sync_identities(cl)
		if _, ok := ident_of(cl, c.identity); !ok {
			kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("this session does not reach identity %q", c.identity))
			kit.cli_err_field(c, "requested", c.identity)
			return kit.EXIT_OUT_OF_SCOPE
		}
	}
	return kit.EXIT_OK
}

// cloud_sync_identities refreshes the identity list only.
cloud_sync_identities :: proc(cl: ^Cloud) -> (int, string) {
	if cl.acct == nil {
		return 0, "not signed in"
	}
	rep, err := cloud_sync(cl)
	return rep.pulled, err
}

// in_scope refuses a calendar key outside the scope in force.
@(private = "file")
key_in_scope :: proc(c: ^kit.Call, cl: ^Cloud, key: string) -> (int, int) {
	i := find_source(cl, key)
	if i < 0 {
		// A key for an identity this session cannot reach is out of scope,
		// not merely absent.
		handle := key
		if slash := strings.index_byte(key, '/'); slash >= 0 {
			handle = key[:slash]
		}
		if c.identity != "" && handle != c.identity && key != "local" {
			kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("%s is not in identity %s", key, c.identity))
			kit.cli_err_field(c, "requested", handle)
			return -1, kit.EXIT_OUT_OF_SCOPE
		}
		return -1, kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no calendar %q (calendar list shows the keys)", key))
	}
	return i, kit.EXIT_OK
}

@(private = "file")
event_json :: proc(cl: ^Cloud, e: Event) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "date", date_iso(e.date))
	kit.jset_str(o, "start", e.start < 0 ? "" : clock_text(e.start))
	kit.jset_int(o, "minutes", e.mins)
	kit.jset_str(o, "title", e.title)
	kit.jset_str(o, "place", e.place)
	kit.jset_str(o, "calendar", cl.sources[e.src].key)
	if e.uid != "" {
		kit.jset_str(o, "uid", e.uid)
	}
	kit.jset_bool(o, "recurring", e.recurring)
	kit.jset_bool(o, "cancelled", e.cancelled)
	people := people_of(cl, e.src, e.obj)
	if len(people) > 0 {
		arr := kit.jarr()
		for pp in people {
			po := kit.jobj()
			kit.jset_str(po, "address", pp.address)
			kit.jset_str(po, "partstat", pp.organizer ? "ORGANIZER" : pp.partstat)
			kit.jpush(arr, po)
		}
		kit.jset(o, "attendees", arr)
	}
	return o
}

// all_events: the device calendar plus every cloud instance in [from, to).
@(private = "file")
all_events :: proc(cl: ^Cloud, from, to: Date, only := "") -> [dynamic]Event {
	out := make([dynamic]Event, 0, 32)
	if (only == "" || only == "local") && cl.scope == "" {
		dir := store_dir()
		for e in events_load(dir) {
			if !date_less(e.date, from) && date_less(e.date, to) {
				append(&out, e)
			}
		}
	}
	for e in cloud_events(cl, from, to) {
		if !date_less(e.date, from) && date_less(e.date, to) && (only == "" || cl.sources[e.src].key == only) {
			append(&out, e)
		}
	}
	events_sort(&out)
	return out
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

cmd_status :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	cloud_open(&cl, c.identity)
	pending := 0
	for s in cl.sources {
		if s.local == nil {
			continue
		}
		for _, e in s.local.entries {
			if e.state != .Clean {
				pending += 1
			}
		}
	}
	kit.jset_bool(c.out, "signed_in", cl.signed)
	if cl.signed {
		kit.jset_str(c.out, "email", cl.email)
	}
	dav := cl.acct != nil ? cl.acct.dav_text : ""
	kit.jset_str(c.out, "dav", dav)
	kit.jset_int(c.out, "pending", pending)
	return kit.EXIT_OK
}

cmd_signin :: proc(c: ^kit.Call) -> int {
	if c.identity != "" {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "signing in is an account-level act; run it without an identity scope")
	}
	pass := kit.cli_str(c, "password")
	if f := kit.cli_str(c, "password-file"); f != "" {
		data, err := os.read_entire_file_from_path(f, context.temp_allocator)
		if err != nil {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("cannot read %s", f))
		}
		pass = strings.trim_space(string(data))
	}
	if pass == "" {
		pass = os.get_env("PALM_CLOUD_PASSWORD", context.temp_allocator)
	}
	if pass == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "give --password-file, PALM_CLOUD_PASSWORD or --password")
	}
	email := kit.cli_str(c, "email")
	if c.dry_run {
		kit.jset_str(c.out, "email", email)
		return kit.EXIT_OK
	}
	cl := Cloud{}
	if e := cloud_sign_in(&cl, email, pass); e != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, e)
	}
	kit.jset_str(c.out, "email", email)
	return kit.EXIT_OK
}

cmd_sync :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl); code != kit.EXIT_OK {
		return code
	}
	rep, err := cloud_sync(&cl)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	kit.jset_int(c.out, "pushed", rep.pushed)
	kit.jset_int(c.out, "pulled", rep.pulled)
	kit.jset_int(c.out, "removed", rep.removed)
	kit.jset_int(c.out, "conflicts", rep.conflicts)
	kit.jset_int(c.out, "invitations", rep.invitations)
	return kit.EXIT_OK
}

cmd_list :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl, false); code != kit.EXIT_OK {
		return code
	}
	arr := kit.jarr()
	for s in cl.sources {
		if s.device && cl.scope != "" {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "key", s.key)
		kit.jset_str(o, "identity", s.handle)
		kit.jset_str(o, "name", s.name)
		kit.jset_str(o, "color", fmt.tprintf("#%06x", s.color))
		kit.jset_str(o, "access", s.access)
		kit.jset_str(o, "owner", s.device ? "" : s.owner)
		kit.jset_int(o, "events", s.device ? len(events_load(store_dir())) : len(s.objs))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "calendars", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
parse_range :: proc(c: ^kit.Call, cl: ^Cloud) -> (from, to: Date, code: int) {
	td, _ := today(local_offset())
	from = td
	if s := kit.cli_str(c, "from"); s != "" {
		d, ok := parse_iso(s)
		if !ok {
			return {}, {}, kit.cli_fail(c, kit.EXIT_USAGE, "--from is YYYY-MM-DD")
		}
		from = d
	}
	to = date_add(from, 7)
	if s := kit.cli_str(c, "to"); s != "" {
		d, ok := parse_iso(s)
		if !ok {
			return {}, {}, kit.cli_fail(c, kit.EXIT_USAGE, "--to is YYYY-MM-DD")
		}
		to = d
	}
	return from, to, kit.EXIT_OK
}

cmd_events :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl, false); code != kit.EXIT_OK {
		return code
	}
	from, to, code := parse_range(c, &cl)
	if code != kit.EXIT_OK {
		return code
	}
	only := kit.cli_str(c, "calendar")
	if only != "" {
		if _, kc := key_in_scope(c, &cl, only); kc != kit.EXIT_OK {
			return kc
		}
	}
	arr := kit.jarr()
	for e in all_events(&cl, from, to, only) {
		kit.jpush(arr, event_json(&cl, e))
	}
	kit.jset(c.out, "events", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

cmd_next :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl, false); code != kit.EXIT_OK {
		return code
	}
	td, now := today(local_offset())
	for e in all_events(&cl, td, date_add(td, 366)) {
		if date_eq(e.date, td) && e.start >= 0 && e.start < now {
			continue
		}
		o := event_json(&cl, e)
		c.out = o
		return kit.EXIT_OK
	}
	return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "nothing in the next year")
}

cmd_add :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl, false); code != kit.EXIT_OK {
		return code
	}
	date, dok := parse_iso(kit.cli_str(c, "date"))
	if !dok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--date is YYYY-MM-DD")
	}
	start := -1
	if t := kit.cli_str(c, "time"); t != "" {
		v, ok := parse_clock(t)
		if !ok {
			return kit.cli_fail(c, kit.EXIT_USAGE, "--time is HH:MM")
		}
		start = v
	}
	key := kit.cli_str(c, "calendar")
	si := 0
	if key != "" {
		i, kc := key_in_scope(c, &cl, key)
		if kc != kit.EXIT_OK {
			return kc
		}
		si = i
	} else if c.identity != "" {
		si = target_source(&cl, c.identity)
		if si < 0 {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("%s has no calendar here yet: calendar sync", c.identity))
		}
	} else if cl.signed {
		for ident in cl.idents {
			if i := target_source(&cl, ident.handle); i >= 0 {
				si = i
				break
			}
		}
	}
	s := &cl.sources[si]
	if !writable(s) {
		return kit.cli_fail(c, kit.EXIT_FAILED, fmt.tprintf("%s is shared with you read-only", s.key))
	}
	atts := make([dynamic]string, 0, 4)
	for piece in strings.split(kit.cli_str(c, "attendee"), ",") {
		a := strings.trim_space(piece)
		if a == "" {
			continue
		}
		if !strings.contains(a, "@") {
			a = fmt.tprintf("%s@%s", a, mail_domain())
		}
		append(&atts, a)
	}
	rrule := kit.cli_str(c, "rrule")
	if rrule != "" {
		if _, ok := ical.parse_rrule(rrule); !ok {
			return kit.cli_fail(c, kit.EXIT_USAGE, fmt.tprintf("not an RRULE: %s", rrule))
		}
	}
	title := kit.cli_str(c, "title")
	dr := Draft {
		date = date,
		start = start,
		mins = kit.cli_int(c, "minutes", 60),
		title = title,
		place = kit.cli_str(c, "place"),
		rrule = rrule,
		attendees = atts[:],
		organizer = s.handle,
	}
	kit.jset_str(c.out, "calendar", s.key)
	if c.dry_run {
		kit.jset_str(c.out, "uid", "")
		kit.jset_str(c.out, "name", "")
		kit.jset_bool(c.out, "synced", false)
		return kit.EXIT_OK
	}
	if s.device {
		if rrule != "" || len(atts) > 0 {
			return kit.cli_fail(c, kit.EXIT_USAGE, "repetition and invitations need a calendar in the Palmy cloud")
		}
		dir := store_dir()
		list := events_load(dir)
		append(&list, Event{date = date, start = start, mins = dr.mins, title = title, place = dr.place})
		events_sort(&list)
		if !events_save(dir, list[:]) {
			return kit.cli_fail(c, kit.EXIT_FAILED, "could not write the events file")
		}
		kit.jset_str(c.out, "uid", "")
		kit.jset_str(c.out, "name", "")
		kit.jset_bool(c.out, "synced", false)
		return kit.EXIT_OK
	}
	name, msg := cloud_create(&cl, si, dr)
	if name == "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, msg)
	}
	uid := strings.trim_suffix(name, ".ics")
	kit.jset_str(c.out, "uid", uid)
	kit.jset_str(c.out, "name", name)
	kit.jset_bool(c.out, "synced", msg == "")
	if msg != "" {
		kit.cli_note(c, "%s", msg)
	}
	return kit.EXIT_OK
}

// find_uid locates an event by UID in the sources in scope.
@(private = "file")
find_uid :: proc(cl: ^Cloud, uid: string) -> (si: int, name: string, ok: bool) {
	for &s, i in cl.sources {
		for o in s.objs {
			if master, _ := ical.masters_and_overrides(o.cal, "VEVENT"); master != nil && ical.text(master, "UID") == uid {
				return i, o.name, true
			}
		}
	}
	return -1, "", false
}

cmd_delete :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl); code != kit.EXIT_OK {
		return code
	}
	uid := kit.cli_str(c, "uid")
	si, name, ok := find_uid(&cl, uid)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no event %s in the calendars in scope", uid))
	}
	kit.jset_str(c.out, "uid", uid)
	kit.jset_str(c.out, "calendar", cl.sources[si].key)
	if c.dry_run {
		return kit.EXIT_OK
	}
	msg := ""
	if day := kit.cli_str(c, "occurrence"); day != "" {
		d, dok := parse_iso(day)
		if !dok {
			return kit.cli_fail(c, kit.EXIT_USAGE, "--occurrence is YYYY-MM-DD")
		}
		found := false
		for e in cloud_events(&cl, d, date_add(d, 1)) {
			if e.uid == uid && date_eq(e.date, d) {
				msg = cloud_delete(&cl, si, name, e.rid)
				found = true
				break
			}
		}
		if !found {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("%s has no occurrence on %s", uid, day))
		}
	} else {
		msg = cloud_delete(&cl, si, name)
	}
	if msg != "" && strings.contains(msg, "read-only") {
		return kit.cli_fail(c, kit.EXIT_FAILED, msg)
	}
	return kit.EXIT_OK
}

cmd_invitations :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl); code != kit.EXIT_OK {
		return code
	}
	_, _ = cloud_sync(&cl)
	arr := kit.jarr()
	for inv in pending_invitations(&cl) {
		o := kit.jobj()
		kit.jset_str(o, "uid", inv.uid)
		kit.jset_str(o, "title", inv.title)
		kit.jset_str(o, "identity", inv.handle)
		kit.jset_str(o, "organizer", inv.organizer)
		kit.jset_str(o, "start", ical.iso8601(inv.start, context.temp_allocator))
		kit.jset_str(o, "calendar", cl.sources[inv.src].key)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "invitations", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

@(private = "file")
answer :: proc(c: ^kit.Call, partstat: string) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl); code != kit.EXIT_OK {
		return code
	}
	_, _ = cloud_sync(&cl)
	uid := kit.cli_str(c, "uid")
	// Only in the identity's own calendars: that is where an invitation
	// lands, and answering for a share would be answering for someone else.
	for &s, si in cl.sources {
		if s.device || s.access != "owner" {
			continue
		}
		for o in s.objs {
			master, _ := ical.masters_and_overrides(o.cal, "VEVENT")
			if master == nil || ical.text(master, "UID") != uid {
				continue
			}
			if _, here := partstat_for(master, address_of(s.handle)); !here {
				continue
			}
			kit.jset_str(c.out, "uid", uid)
			kit.jset_str(c.out, "partstat", partstat)
			if c.dry_run {
				return kit.EXIT_OK
			}
			if msg := respond(&cl, si, o.name, partstat); msg != "" {
				return kit.cli_fail(c, kit.EXIT_FAILED, msg)
			}
			return kit.EXIT_OK
		}
	}
	return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no invitation %s for the identities in scope", uid))
}

cmd_accept :: proc(c: ^kit.Call) -> int {
	return answer(c, "ACCEPTED")
}

cmd_decline :: proc(c: ^kit.Call) -> int {
	return answer(c, "DECLINED")
}

// ---------------------------------------------------------------------------
// Sharing and app passwords: rows in the database, through cloudkit
// ---------------------------------------------------------------------------

@(private = "file")
collection_id :: proc(c: ^kit.Call, cl: ^Cloud, key: string) -> (id, owner_id: string, code: int) {
	si, kc := key_in_scope(c, cl, key)
	if kc != kit.EXIT_OK {
		return "", "", kc
	}
	s := cl.sources[si]
	if s.device || s.access != "owner" {
		return "", "", kit.cli_fail(c, kit.EXIT_FAILED, fmt.tprintf("%s is not yours to share", key))
	}
	ident, _ := ident_of(cl, s.handle)
	seg := key[strings.index_byte(key, '/') + 1:]
	v, e := ck.select(cl.acct.cloud, "dav_collections", fmt.tprintf("select=id&kind=eq.calendar&identity_id=eq.%s&slug=eq.%s", ident.id, ck.escape(seg)))
	rows := ck.array(v)
	if !ck.ok(e) || len(rows) == 0 {
		return "", "", kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("cannot find %s on the server", key))
	}
	return strings.clone(ck.get_str(rows[0], "id")), ident.id, kit.EXIT_OK
}

@(private = "file")
resolve :: proc(cl: ^Cloud, who: string) -> string {
	addr := who
	if !strings.contains(addr, "@") {
		addr = fmt.tprintf("%s@%s", addr, mail_domain())
	}
	o := ck.obj()
	ck.put(&o, "address", addr)
	v, e := ck.rpc(cl.acct.cloud, "dav_resolve_address", ck.obj_done(&o))
	if !ck.ok(e) {
		return ""
	}
	// A scalar result: the identity's uuid as a JSON string, or null.
	return strings.clone(ck.get_str(v))
}

cmd_share :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl); code != kit.EXIT_OK {
		return code
	}
	_, _ = cloud_sync(&cl)
	key := kit.cli_str(c, "calendar")
	coll, owner, code := collection_id(c, &cl, key)
	if code != kit.EXIT_OK {
		return code
	}
	who := kit.cli_str(c, "with")
	grantee := resolve(&cl, who)
	if grantee == "" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("%s is not a Palmy identity", who))
	}
	access := kit.cli_str(c, "access")
	if access == "" {
		access = "read"
	}
	kit.jset_str(c.out, "calendar", key)
	kit.jset_str(c.out, "with", who)
	kit.jset_str(c.out, "access", access)
	if c.dry_run {
		return kit.EXIT_OK
	}
	o := ck.obj()
	ck.put(&o, "identity_id", owner)
	ck.put(&o, "collection_id", coll)
	ck.put(&o, "grantee_identity", grantee)
	ck.put(&o, "access", access)
	_, e := ck.upsert(cl.acct.cloud, "dav_grants", ck.obj_done(&o), "collection_id,grantee_identity")
	if !ck.ok(e) {
		return kit.cli_fail(c, e.kind == .Out_Of_Scope ? kit.EXIT_OUT_OF_SCOPE : kit.EXIT_FAILED, e.message)
	}
	return kit.EXIT_OK
}

cmd_unshare :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl); code != kit.EXIT_OK {
		return code
	}
	_, _ = cloud_sync(&cl)
	key := kit.cli_str(c, "calendar")
	coll, _, code := collection_id(c, &cl, key)
	if code != kit.EXIT_OK {
		return code
	}
	who := kit.cli_str(c, "with")
	grantee := resolve(&cl, who)
	if grantee == "" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("%s is not a Palmy identity", who))
	}
	kit.jset_str(c.out, "calendar", key)
	kit.jset_str(c.out, "with", who)
	if c.dry_run {
		kit.jset_int(c.out, "removed", 0)
		return kit.EXIT_OK
	}
	n, e := ck.delete_rows(cl.acct.cloud, "dav_grants", fmt.tprintf("collection_id=eq.%s&grantee_identity=eq.%s", coll, grantee))
	if !ck.ok(e) {
		return kit.cli_fail(c, kit.EXIT_FAILED, e.message)
	}
	kit.jset_int(c.out, "removed", n)
	return kit.EXIT_OK
}

cmd_app_password :: proc(c: ^kit.Call) -> int {
	cl := Cloud{}
	if code := open_cloud(c, &cl); code != kit.EXIT_OK {
		return code
	}
	_, _ = cloud_sync(&cl)
	handle := c.identity
	if handle == "" && len(cl.idents) > 0 {
		handle = cl.idents[0].handle
	}
	ident, ok := ident_of(&cl, handle)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no identity: give --identity")
	}
	kit.jset_str(c.out, "identity", handle)
	switch kit.cli_str(c, "action") {
	case "create":
		if c.dry_run {
			return kit.EXIT_OK
		}
		o := ck.obj()
		ck.put(&o, "target", ident.id)
		ck.put(&o, "label", kit.cli_str(c, "label"))
		v, e := ck.rpc(cl.acct.cloud, "dav_app_password_create", ck.obj_done(&o))
		rows := ck.array(v)
		if !ck.ok(e) || len(rows) == 0 {
			return kit.cli_fail(c, e.kind == .Out_Of_Scope ? kit.EXIT_OUT_OF_SCOPE : kit.EXIT_FAILED, e.message)
		}
		secret := ck.get_str(rows[0], "secret")
		url := cl.acct.dav_text
		kit.jset_str(c.out, "secret", secret)
		kit.jset_str(c.out, "username", handle)
		kit.jset_str(c.out, "url", fmt.tprintf("%s/", strings.trim_right(url, "/")))
	case "list":
		v, e := ck.select(cl.acct.cloud, "dav_app_passwords", fmt.tprintf("select=id,label,prefix,created_at,last_used_at,revoked_at&identity_id=eq.%s&order=created_at", ident.id))
		if !ck.ok(e) {
			return kit.cli_fail(c, kit.EXIT_FAILED, e.message)
		}
		arr := kit.jarr()
		for r in ck.array(v) {
			o := kit.jobj()
			for k in ([]string{"id", "label", "prefix", "created_at", "last_used_at", "revoked_at"}) {
				kit.jset_str(o, k, ck.get_str(r, k))
			}
			kit.jpush(arr, o)
		}
		kit.jset(c.out, "passwords", arr)
	case "revoke":
		id := kit.cli_str(c, "id")
		if id == "" {
			return kit.cli_fail(c, kit.EXIT_USAGE, "revoke needs the password's id (app-password list)")
		}
		if c.dry_run {
			return kit.EXIT_OK
		}
		o := ck.obj()
		ck.put(&o, "target", id)
		_, e := ck.rpc(cl.acct.cloud, "dav_app_password_revoke", ck.obj_done(&o))
		if !ck.ok(e) {
			return kit.cli_fail(c, kit.EXIT_FAILED, e.message)
		}
	}
	return kit.EXIT_OK
}

_ :: strconv
