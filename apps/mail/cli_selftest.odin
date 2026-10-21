// `mail --selftest`, the command-line part.
//
// The binary is run again as a child against a fixture mailbox in /tmp, with
// $PALMY_MAIL_DIR pointing there and $PALM_AUDIT beside it, so no part of this
// can read the mailbox somebody is actually using. Whatever the child changes
// is then read back through the window's own scan, which is the assertion
// that the two front ends share one model rather than agreeing by accident.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

@(private = "file")
self_exe :: proc() -> string {
	if path, err := os.get_executable_path(context.temp_allocator); err == nil {
		return path
	}
	return os.args[0]
}

@(private = "file")
run_cli :: proc(data, scratch: string, env: []string, args: ..string) -> (out: string, code: int) {
	line := strings.builder_make(context.temp_allocator)
	strings.write_string(&line, "WAYLAND_DISPLAY= DISPLAY= PALM_IDENTITY= ")
	strings.write_string(&line, fmt.tprintf("PALMY_MAIL_DIR=%q PALM_AUDIT=%q ", data, fmt.tprintf("%s/audit.jsonl", scratch)))
	for e in env {
		strings.write_string(&line, e)
		strings.write_byte(&line, ' ')
	}
	strings.write_string(&line, fmt.tprintf("%q", self_exe()))
	for a in args {
		strings.write_string(&line, fmt.tprintf(" %q", a))
	}
	state, sout, _, err := os.process_exec({command = {"sh", "-c", strings.to_string(line)}}, context.temp_allocator)
	if err != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

// scan_as_window loads a data directory the way the window does.
@(private = "file")
scan_as_window :: proc(data: string) -> ^State {
	st := new(State)
	st.data_dir = strings.clone(data)
	st.reader_msg = -1
	load_config(st)
	discover_accounts(st)
	reload_all(st)
	return st
}

@(private = "file")
first_id :: proc(out: string) -> string {
	v, err := json.parse_string(out, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil {
		return ""
	}
	obj, _ := v.(json.Object)
	arr, _ := obj["messages"].(json.Array)
	if len(arr) == 0 {
		return ""
	}
	m, _ := arr[0].(json.Object)
	id, _ := m["id"].(json.String)
	return string(id)
}

@(private = "file")
valid :: proc(out: string, fields: []kit.Field, what: string) {
	problems := kit.cli_validate_output(out, fields, context.temp_allocator)
	ok(len(problems) == 0, "%s matches its declared schema%s", what, len(problems) > 0 ? fmt.tprintf(" (%s)", problems[0]) : "")
}

test_cli :: proc() {
	scratch := fmt.tprintf("/tmp/palmy-mail-cli-%d", os.get_pid())
	remove_tree(scratch)
	os.make_directory_all(scratch)
	defer remove_tree(scratch)
	data := fmt.tprintf("%s/data", scratch)
	write_fixtures(data)

	// --- the declaration -------------------------------------------------
	sf := surface()
	eq_str(sf.noun, "mailbox", "the surface is the mailbox noun (palm mail is the cloud's)")
	ok(sf.selftest != nil && sf.gui, "it declares its self-test and its window")
	destructive := 0
	for cmd in sf.commands {
		ok(cmd.run != nil, "%s has an implementation", cmd.verb)
		ok(len(cmd.out) > 0, "%s declares what it prints", cmd.verb)
		ok(len(cmd.examples) > 0, "%s ships an example", cmd.verb)
		if cmd.effect == .Destructive {
			destructive += 1
		}
		for ex in cmd.examples {
			words := kit.cli_split_example(ex, context.temp_allocator)
			ok(len(words) > 0 && words[0] == "mail", "the example %q is typed as the binary is named", ex)
			args := make([dynamic]string, context.temp_allocator)
			for w in words[1:] {
				append(&args, w)
			}
			append(&args, "--parse-only")
			_, code := run_cli(data, scratch, {}, ..args[:])
			eq_int(code, 0, fmt.tprintf("the example %q parses", ex))
		}
	}
	eq_int(destructive, 1, "exactly one command is destructive: purge")
	{
		out, code := run_cli(data, scratch, {}, "--schema")
		eq_int(code, 0, "--schema answers")
		_, err := json.parse_string(out, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		ok(err == nil, "and is JSON")
		eq_int(strings.count(out, `"name": "data-dir"`), len(sf.commands) + 1, "--data-dir is in every command's schema, and the surface's")
		ok(strings.contains(out, `"name": "maildir"`) && strings.contains(out, `"name": "save-dir"`), "and so are --maildir and --save-dir")
	}
	{
		// The surface's flags, read by the kit rather than stripped from argv
		// first. $PALMY_MAIL_DIR points at an empty directory, so only the
		// flag can find the fixtures.
		empty := fmt.tprintf("%s/flag-empty", scratch)
		os.make_directory_all(empty)
		out, code := run_cli(empty, scratch, {}, "accounts", "--data-dir", data, "--json")
		eq_int(code, 0, "accounts --data-dir PATH exits 0")
		ok(strings.contains(out, `"count": 3`) && strings.contains(out, data), "and reads that directory, not $PALMY_MAIL_DIR")
		out2, code2 := run_cli(empty, scratch, {}, "accounts", fmt.tprintf("--data-dir=%s", data), "--save-dir=/nonexistent", "--json")
		eq_int(code2, 0, "--data-dir=PATH and --save-dir=PATH are taken too")
		ok(strings.contains(out2, `"count": 3`), "with the same answer")
		tree := fmt.tprintf("%s/flag-tree", scratch)
		maildir_make(tree)
		write_file(fmt.tprintf("%s/new/1.M1P1.flag", tree), transmute([]u8)string("From: A <a@t>\r\nSubject: Only here\r\nMessage-ID: <flag-1@t>\r\n\r\nbody\r\n"))
		out3, code3 := run_cli(data, scratch, {}, "search", "only here", fmt.tprintf("--maildir=%s", tree), "--json")
		eq_int(code3, 0, "search --maildir=PATH exits 0")
		ok(strings.contains(out3, "Only here") && strings.contains(out3, `"count": 1`), "and searches that one tree")
		_, code4 := run_cli(data, scratch, {}, "accounts", "--data-dir")
		eq_int(code4, kit.EXIT_USAGE, "--data-dir with no value is a usage error")

		// Before the verb, too: the kit moves them after it.
		out5, code5 := run_cli(empty, scratch, {}, "--data-dir", data, "accounts", "--json")
		eq_int(code5, 0, "--data-dir PATH accounts exits 0")
		ok(strings.contains(out5, `"count": 3`) && strings.contains(out5, data), "and reads that directory")
		out6, code6 := run_cli(data, scratch, {}, fmt.tprintf("--maildir=%s", tree), "search", "only here", "--json")
		eq_int(code6, 0, "--maildir=PATH search exits 0")
		ok(strings.contains(out6, `"count": 1`), "and searches that one tree")
		// A line of nothing but them is the window's, in either spelling,
		// and the window reads the value the way a command does.
		_, handled := kit.cli_args(surface(), {"--maildir", tree})
		ok(!handled, "mail --maildir PATH is the window's line")
		_, handled = kit.cli_args(surface(), {fmt.tprintf("--maildir=%s", tree), "--save-dir=/x"})
		ok(!handled, "so is mail --maildir=PATH --save-dir=PATH")
		v, got := kit.cli_surface_flag(surface(), {"--save-dir=/x", "--maildir", tree}, "maildir")
		ok(got && v == tree, "and the window reads --maildir PATH as --maildir=PATH")
		_, code7 := run_cli(data, scratch, {}, "--maildir", tree, "lsit")
		eq_int(code7, kit.EXIT_USAGE, "a typo after the window's flags is still a usage error, not a window")
	}

	// --- reads ------------------------------------------------------------
	{
		out, code := run_cli(data, scratch, {}, "accounts", "--json")
		eq_int(code, 0, "accounts exits 0")
		valid(out, ACCOUNTS_FIELDS, "accounts")
		ok(strings.contains(out, `"count": 3`), "and finds the three fixture accounts")
	}
	{
		out, code := run_cli(data, scratch, {}, "folders", "--account", "Work", "--json")
		eq_int(code, 0, "folders --account Work exits 0")
		valid(out, FOLDERS_FIELDS, "folders")
		ok(strings.contains(out, `"role": "trash"`), "and lists a Trash by role")
	}
	id := ""
	{
		out, code := run_cli(data, scratch, {}, "list", "--account", "Work", "--json")
		eq_int(code, 0, "list exits 0")
		valid(out, LIST_FIELDS, "list")
		id = first_id(out)
		ok(id != "", "and hands back an id")
		// The same count the window's own Inbox shows.
		st := scan_as_window(data)
		fi := -1
		for f, i in st.folders {
			if f.role == .Inbox && st.accounts[f.account].name == "Work" {
				fi = i
				break
			}
		}
		ok(fi >= 0 && strings.contains(out, fmt.tprintf(`"count": %d`, st.folders[fi].total)), "and as many messages as the window's Inbox holds")
	}
	{
		out, code := run_cli(data, scratch, {}, "read", id, "--json")
		eq_int(code, 0, "read exits 0")
		valid(out, READ_FIELDS, "read")
		st := scan_as_window(data)
		for m in st.messages {
			if msg_key(m) == id {
				ok(msg_unread(m), "and reading does not mark it read")
			}
		}
		_, missing := run_cli(data, scratch, {}, "read", "no-such-message", "--json")
		eq_int(missing, kit.EXIT_NOT_FOUND, "an unknown id exits 3")
	}
	{
		out, code := run_cli(data, scratch, {}, "search", "from:grace", "--json")
		eq_int(code, 0, "search exits 0")
		valid(out, SEARCH_FIELDS, "search")
		ok(first_id(out) != "", "and finds the fixture sender")
	}

	// --- writes, read back through the window's scan ----------------------
	{
		out, code := run_cli(data, scratch, {}, "mark", id, "--seen", "--flagged", "--json")
		eq_int(code, 0, "mark exits 0")
		valid(out, MARK_FIELDS, "mark")
		st := scan_as_window(data)
		seen := false
		for m in st.messages {
			if msg_key(m) == id {
				seen = .Seen in m.flags && .Flagged in m.flags && strings.has_suffix(m.file, ":2,FS")
			}
		}
		ok(seen, "and the window sees it read and flagged, in the file name")
	}
	{
		out, code := run_cli(data, scratch, {}, "move", id, "Archive/2024", "--json")
		eq_int(code, 0, "move exits 0")
		valid(out, FILED_FIELDS, "move")
		st := scan_as_window(data)
		where_ := ""
		for m in st.messages {
			if msg_key(m) == id {
				where_ = st.folders[m.folder].name
			}
		}
		eq_str(where_, "Archive/2024", "and the window finds it in that folder")
		_, nofolder := run_cli(data, scratch, {}, "move", id, "Nowhere", "--json")
		eq_int(nofolder, kit.EXIT_NOT_FOUND, "a folder that is not there exits 3")
	}
	{
		out, code := run_cli(data, scratch, {}, "trash", id, "--json")
		eq_int(code, 0, "trash exits 0")
		ok(strings.contains(out, `"to": "Trash"`), "and lands in Trash")
	}
	{
		out, code := run_cli(data, scratch, {}, "send", "--to", "ada@work.test", "--subject", "CLI lunch", "--text", "Noon?", "--json")
		eq_int(code, 0, "send exits 0")
		valid(out, SEND_FIELDS, "send")
		ok(strings.contains(out, `"transmitted": false`), "and says nothing was transmitted")
		ok(strings.contains(out, "/.Outbox/new/"), "it was queued in the local Outbox")
		st := scan_as_window(data)
		found := false
		for m in st.messages {
			if m.subject == "CLI lunch" && st.folders[m.folder].role == .Outbox {
				found = true
			}
		}
		ok(found, "and the window lists it in the Outbox")
	}
	{
		path := ""
		st := scan_as_window(data)
		for m in st.messages {
			if msg_key(m) == id {
				path = strings.clone(m.path, context.temp_allocator)
			}
		}
		out, code := run_cli(data, scratch, {}, "purge", id, "--json")
		eq_int(code, kit.EXIT_NEEDS_YES, "purge without --yes exits 4")
		ok(strings.contains(out, "needs --yes"), "and says so")
		ok(path != "" && os.exists(path), "and the file is still there")
		_, dry := run_cli(data, scratch, {}, "purge", id, "--dry-run", "--json")
		eq_int(dry, 0, "a dry run is accepted")
		ok(os.exists(path), "and deletes nothing")
		out2, yes := run_cli(data, scratch, {}, "purge", id, "--yes", "--json")
		eq_int(yes, 0, "purge --yes exits 0")
		valid(out2, PURGE_FIELDS, "purge")
		ok(!os.exists(path), "and the file is gone")
	}
	{
		audit, _ := read_file(fmt.tprintf("%s/audit.jsonl", scratch), context.temp_allocator)
		ok(strings.contains(string(audit), `"verb": "purge"`), "the purge left an audit record")
		ok(!strings.contains(string(audit), `"verb": "read"`), "and a read did not")
	}

	// --- a read never writes ---------------------------------------------
	{
		empty := fmt.tprintf("%s/empty", scratch)
		os.make_directory_all(empty)
		out, code := run_cli(empty, scratch, {}, "list", "--json")
		eq_int(code, 0, "list over an empty data directory exits 0")
		valid(out, LIST_FIELDS, "the empty list")
		ok(!os.exists(fmt.tprintf("%s/accounts.conf", empty)), "and generates no fixtures there")
	}

	// --- scope ------------------------------------------------------------
	{
		pd := fmt.tprintf("%s/palm", scratch)
		for who in ([]string{"alice", "work"}) {
			root := fmt.tprintf("%s/%s@palm.test", pd, who)
			maildir_make(root)
			write_file(
				fmt.tprintf("%s/new/1.M1P1.%s", root, who),
				transmute([]u8)fmt.tprintf("From: Bob <bob@palm.test>\r\nTo: %s@palm.test\r\nSubject: For %s\r\nMessage-ID: <%s-1@t>\r\n\r\nbody\r\n", who, who, who),
			)
		}
		write_file(
			fmt.tprintf("%s/palmy.conf", pd),
			transmute([]u8)string(
				"[session]\nemail = alex@palm.test\n\n" +
				"[identity]\nid = i-1\nhandle = alice\nname = Alice\nkind = personal\ncolor = indigo\naddress = alice@palm.test\npath = alice@palm.test\n\n" +
				"[identity]\nid = i-2\nhandle = work\nname = Work\nkind = work\ncolor = emerald\naddress = work@palm.test\npath = work@palm.test\n",
			),
		)
		out, code := run_cli(pd, scratch, {"PALM_IDENTITY=alice"}, "search", "for", "--json")
		eq_int(code, 0, "a scoped search exits 0")
		ok(strings.contains(out, "For alice") && !strings.contains(out, "For work"), "and sees only its own identity's mail")
		_, refused := run_cli(pd, scratch, {"PALM_IDENTITY=alice"}, "list", "--account", "work", "--json")
		eq_int(refused, kit.EXIT_OUT_OF_SCOPE, "naming another identity's mailbox exits 5")
		_, widened := run_cli(pd, scratch, {"PALM_IDENTITY=alice"}, "accounts", "--identity", "work", "--json")
		eq_int(widened, kit.EXIT_OUT_OF_SCOPE, "and --identity cannot widen the scope")
		_, other := run_cli(pd, scratch, {"PALM_IDENTITY=alice"}, "read", "1.M1P1.work", "--json")
		eq_int(other, kit.EXIT_NOT_FOUND, "another identity's message does not exist from inside this one")
	}
}
