package main

// `ai agent` — the assistant itself, as the child the person's process starts.
//
// The first thing it does, before reading its request or opening any file of
// the identity's, is confine itself (cloud/assistant/sandbox). If that fails
// it says so on stdout and exits; it never runs unconfined. After that it
// loads the tools from their --schema, opens the delegated session it was
// handed in PALM_CLOUD_SESSION, and runs the engine, writing events to stdout
// and reading model answers from stdin.
//
// It is not a verb for people: `ai agent` without a parent writing a request
// to it waits for one, and the window never shows it.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import ck "../cloudkit"
import en "../../cloud/assistant/engine"
import sb "../../cloud/assistant/sandbox"

@(private = "file")
Child_IO :: struct {
	rd:  [dynamic]u8,
	seq: int,
}

@(private = "file")
put_line :: proc(s: string) {
	data := transmute([]u8)fmt.tprintf("%s\n", s)
	for len(data) > 0 {
		n, err := os.write(os.stdout, data)
		if err != nil || n <= 0 {os.exit(9)}
		data = data[n:]
	}
}

@(private = "file")
get_line :: proc(st: ^Child_IO) -> (string, bool) {
	for {
		for c, i in st.rd {
			if c == '\n' {
				line := strings.clone(string(st.rd[:i]), context.temp_allocator)
				remove_range(&st.rd, 0, i + 1)
				return line, true
			}
		}
		buf: [65536]u8
		n, err := os.read(os.stdin, buf[:])
		if n <= 0 || err != nil {return "", false}
		append(&st.rd, ..buf[:n])
	}
}

@(private = "file")
child_emit :: proc(io: ^en.IO, line: string) {
	put_line(line)
}

@(private = "file")
child_model :: proc(io: ^en.IO, call: en.Model_Call) -> en.Model_Reply {
	st := cast(^Child_IO)io.data
	st.seq += 1
	trace := os.get_env("PALM_ASSISTANT_TRACE", context.temp_allocator) != ""
	if trace {
		for m in call.messages[1:] {fmt.eprintfln("--- %s (%s)\n%s", m.role, call.purpose, m.content)}
		if call.format != "" {fmt.eprintfln("--- format\n%s", call.format)}
	}
	put_line(en.model_call_json(st.seq, call))
	for {
		line, ok := get_line(st)
		if !ok {return {err = "the parent went away"}}
		v, pok := ck.parse(line, context.temp_allocator)
		if !pok || ck.get_str(v, "t") != "model_result" {continue}
		if trace {fmt.eprintfln("--- reply\n%s%s", ck.get_str(v, "text"), ck.get_str(v, "error"))}
		return {
			text = strings.clone(ck.get_str(v, "text")),
			err = strings.clone(ck.get_str(v, "error")),
			ms = ck.get_int(v, "ms"),
		}
	}
}

@(private = "file")
fail :: proc(msg: string) -> int {
	o := ck.obj()
	ck.put(&o, "t", "error")
	ck.put(&o, "message", msg)
	put_line(ck.obj_done(&o))
	return 3
}

agent_main :: proc(args: []string) -> int {
	handle, ports_s, tools := "", "", ""
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--handle":
			if i + 1 < len(args) {handle = args[i + 1]; i += 1}
		case "--ports":
			if i + 1 < len(args) {ports_s = args[i + 1]; i += 1}
		case "--tools":
			if i + 1 < len(args) {tools = args[i + 1]; i += 1}
		}
	}
	if !ck.handle_ok(handle) || tools == "" {
		return fail("ai agent: --handle and --tools are required")
	}
	ports := make([dynamic]u16, context.temp_allocator)
	for p in strings.split(ports_s, ",", context.temp_allocator) {
		if n, ok := strconv.parse_int(strings.trim_space(p)); ok && n > 0 && n < 65536 {
			append(&ports, u16(n))
		}
	}

	// Confinement first.
	home := os.get_env("HOME", context.temp_allocator)
	pl := sb.places_for(home, handle, context.temp_allocator)
	sb.ensure_places(pl)
	os.make_directory_all(fmt.tprintf("%s/tmp", pl.state), os.perm_number(0o700))
	rep, err := sb.enter(sb.policy_for(pl, {tools}, ports[:], context.temp_allocator))
	{
		o := ck.obj()
		ck.put(&o, "t", "sandbox")
		ck.put(&o, "ok", err == "")
		ck.put(&o, "landlock_abi", i64(rep.abi))
		ck.put(&o, "fs_rules", i64(rep.fs_rules))
		ck.put(&o, "net_rules", i64(rep.net_rules))
		ck.put(&o, "scoped", rep.scoped)
		ck.put(&o, "seccomp", rep.seccomp)
		pb := strings.builder_make(context.temp_allocator)
		for p, i in ports {
			if i > 0 {strings.write_byte(&pb, ',')}
			fmt.sbprintf(&pb, "%d", p)
		}
		ck.put_raw(&o, "ports", fmt.tprintf("[%s]", strings.to_string(pb)))
		ck.put(&o, "identity", handle)
		ck.put(&o, "error", err)
		put_line(ck.obj_done(&o))
	}
	if err != "" {
		return 3
	}

	st := Child_IO{rd = make([dynamic]u8)}
	line, ok := get_line(&st)
	if !ok {return fail("no request")}
	req, rok := en.parse_request(line)
	if !rok {return fail("the request was not understood")}
	if req.identity.handle != handle {
		return fail("the request is for another identity than this assistant's")
	}

	reg := en.load_registry(tools)
	db, dberr := ck.open(app = "assistant")
	if !ck.ok(dberr) || !ck.signed_in(db) || db.session.identity_id == "" {
		msg := dberr.message
		if msg == "" {msg = "the delegated session is missing or not scoped"}
		return fail(fmt.tprintf("the assistant's session: %s", msg))
	}
	if db.scope != handle {
		return fail(fmt.tprintf("the delegated session acts for %q, not %q", db.scope, handle))
	}

	io := en.IO{emit = child_emit, model = child_model, data = &st}
	a: en.Agent
	domain := ""
	if at := strings.index_byte(req.identity.address, '@'); at >= 0 {domain = req.identity.address[at + 1:]}
	en.agent_init(&a, &io, req, &reg, db, fmt.tprintf("%s/tmp", pl.state), domain)
	en.run(&a)
	return 0
}

// agent_tool_main is `ai agent-tool --handle X --ports P --tools DIR -- <tool> args...`:
// confine exactly as `ai agent` does, then run one tool binary from the tool
// directory with the assistant's environment, and pass its output and exit
// code through. It is how cloud/assistant/e2e.sh asks "what does the
// assistant's process get if it tries this?" without a model in the loop.
// The environment is the one `ai ask` builds (the caller sets it).
agent_tool_main :: proc(args: []string) -> int {
	handle, ports_s, tools := "", "", ""
	rest: []string
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--handle": if i + 1 < len(args) {handle = args[i + 1]; i += 1}
		case "--ports": if i + 1 < len(args) {ports_s = args[i + 1]; i += 1}
		case "--tools": if i + 1 < len(args) {tools = args[i + 1]; i += 1}
		case "--":
			rest = args[i + 1:]
			i = len(args)
		}
	}
	if !ck.handle_ok(handle) || tools == "" || len(rest) == 0 {
		fmt.eprintln("ai agent-tool --handle H --ports P --tools DIR -- <tool> [args]")
		return 2
	}
	ports := make([dynamic]u16, context.temp_allocator)
	for p in strings.split(ports_s, ",", context.temp_allocator) {
		if n, ok := strconv.parse_int(strings.trim_space(p)); ok && n > 0 && n < 65536 {append(&ports, u16(n))}
	}
	home := os.get_env("HOME", context.temp_allocator)
	pl := sb.places_for(home, handle, context.temp_allocator)
	sb.ensure_places(pl)
	if _, err := sb.enter(sb.policy_for(pl, {tools}, ports[:], context.temp_allocator)); err != "" {
		fmt.eprintfln("ai agent-tool: %s", err)
		return 3
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, fmt.tprintf("%s/%s", tools, rest[0]))
	append(&argv, ..rest[1:])
	state, out, errb, perr := os.process_exec({command = argv[:], env = en.tool_env(), working_dir = pl.state}, context.temp_allocator)
	if perr != nil {
		fmt.eprintfln("ai agent-tool: could not run %s (%v)", rest[0], perr)
		return 126
	}
	os.write(os.stdout, out)
	os.write(os.stderr, errb)
	return state.exit_code
}

// sandbox_probe_main is `ai sandbox-probe`: confine to an identity exactly as
// `ai agent` does, then try the standard probes and print what happened.
// The self-test and cloud/assistant/e2e.sh use it to show the sandbox holds
// on this machine, with this binary.
sandbox_probe_main :: proc(args: []string) -> int {
	handle, other, tools, tool := "", "", "", ""
	open_port, shut_port, parent := 0, 0, 0
	for i := 0; i + 1 < len(args); i += 1 {
		switch args[i] {
		case "--handle": handle = args[i + 1]; i += 1
		case "--other": other = args[i + 1]; i += 1
		case "--tools": tools = args[i + 1]; i += 1
		case "--tool": tool = args[i + 1]; i += 1
		case "--open-port": open_port, _ = strconv.parse_int(args[i + 1]); i += 1
		case "--shut-port": shut_port, _ = strconv.parse_int(args[i + 1]); i += 1
		case "--parent": parent, _ = strconv.parse_int(args[i + 1]); i += 1
		}
	}
	home := os.get_env("HOME", context.temp_allocator)
	pl := sb.places_for(home, handle, context.temp_allocator)
	sb.ensure_places(pl)
	rep, err := sb.enter(sb.policy_for(pl, {tools}, {u16(open_port)}, context.temp_allocator))
	if err != "" {
		fmt.printfln(`{{"error":%s}}`, ck.quote(err))
		return 3
	}
	setup := sb.Probe_Setup{home = home, own = handle, other = other, tool = tool, open_port = u16(open_port), shut_port = u16(shut_port), parent_pid = parent}
	results := sb.run_probes(sb.standard_probes(setup))
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"landlock_abi":%d,"fs_rules":%d,"net_rules":%d,"scoped":%v,"seccomp":%v,"probes":[`, rep.abi, rep.fs_rules, rep.net_rules, rep.scoped, rep.seccomp)
	failed := 0
	for r, i in results {
		if !r.pass {failed += 1}
		fmt.sbprintf(&b, `%s{{"what":%s,"must":%s,"outcome":%s,"pass":%v}}`, i > 0 ? "," : "", ck.quote(r.probe.what),
			r.probe.allow ? `"allow"` : `"refuse"`, ck.quote(r.worked ? "allowed" : fmt.tprintf("refused (%s)", sb.errno_name(r.errno))), r.pass)
	}
	fmt.sbprintf(&b, `],"passed":%d,"failed":%d}}`, len(results) - failed, failed)
	fmt.println(strings.to_string(b))
	return failed == 0 ? 0 : 1
}
