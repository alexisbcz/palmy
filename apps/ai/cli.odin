package main

// `ai <verb>` — the assistant from the command line, on the kit convention.
//
//	ai ask --identity camille.roux "Summarise my unread mail" --json
//	ai actions --identity camille.roux --pending --json
//	ai confirm <action-id> --identity camille.roux --yes
//	ai decline <action-id> --identity camille.roux
//
// There is no assistant for "all identities". Every verb needs one identity,
// from --identity or PALM_IDENTITY, and asking without one is answered with
// the list of identities to choose from rather than with anything else.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import en "../../cloud/assistant/engine"
import kit "kit:."

@(private = "file")
ACTION_FIELDS :: []kit.Field {
	{name = "id", kind = .String},
	{name = "tool", kind = .String},
	{name = "class", kind = .String, help = "read, draft or confirm"},
	{name = "status", kind = .String},
	{name = "summary", kind = .String},
	{name = "tainted", kind = .Bool, help = "proposed after reading content from outside the person"},
	{name = "warnings", kind = .Array},
	{name = "created", kind = .String},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "ask",
		summary = "ask one identity's assistant; it reads and drafts, and proposes anything outbound",
		effect = .Mutate,
		args = {{name = "request", kind = .String, required = true, variadic = true, help = "what to ask"}},
		flags = {
			{name = "conversation", kind = .String, help = "continue this conversation"},
			{name = "max-steps", kind = .Int, def = "5", help = "tool calls at most"},
		},
		out = {
			{name = "identity", kind = .String},
			{name = "conversation", kind = .String},
			{name = "answer", kind = .String},
			{name = "refused", kind = .Bool, help = "the request named another identity and was not run"},
			{name = "proposals", kind = .Array, of = ACTION_FIELDS, help = "waiting for `ai confirm`"},
			{name = "steps", kind = .Array, help = "the tool calls, in order, with their outcome"},
			{name = "model", kind = .String},
			{name = "provider", kind = .String, help = "local, or the remote provider this identity opted into"},
			{name = "model_calls", kind = .Int},
			{name = "ms", kind = .Int},
			{name = "sandbox", kind = .Object, opt = true},
		},
		examples = {`ai ask --identity camille.roux "Summarise my unread mail" --json`},
		run = cmd_ask,
	},
	{
		verb = "actions",
		summary = "the identity's action log: what its assistant read, drafted and proposed",
		effect = .Read,
		flags = {
			{name = "pending", kind = .Bool, help = "only proposals waiting for a decision"},
			{name = "limit", kind = .Int, def = "50"},
			{name = "conversation", kind = .String},
		},
		out = {{name = "identity", kind = .String}, {name = "actions", kind = .Array, of = ACTION_FIELDS}, {name = "count", kind = .Int}},
		aliases = {"log"},
		examples = {"ai actions --identity camille.roux --pending --json"},
		run = cmd_actions,
	},
	{
		verb = "confirm",
		summary = "do what a proposal says, as you: it leaves the identity, so it needs --yes",
		effect = .Destructive,
		args = {{name = "id", kind = .String, required = true, help = "an action id from `ai actions --pending`"}},
		out = {{name = "id", kind = .String}, {name = "status", kind = .String}, {name = "result", kind = .Any}},
		examples = {"ai confirm 0d4e… --identity camille.roux --yes --json"},
		run = cmd_confirm,
	},
	{
		verb = "decline",
		summary = "decline a proposal; nothing is done",
		effect = .Idempotent,
		args = {{name = "id", kind = .String, required = true}},
		out = {{name = "id", kind = .String}, {name = "status", kind = .String}},
		run = cmd_decline,
	},
	{
		verb = "conversations",
		summary = "the identity's conversations, newest first",
		effect = .Read,
		out = {{name = "identity", kind = .String}, {name = "conversations", kind = .Array}, {name = "count", kind = .Int}},
		run = cmd_conversations,
	},
	{
		verb = "show",
		summary = "one conversation, message by message",
		effect = .Read,
		args = {{name = "conversation", kind = .String, required = true}},
		out = {{name = "id", kind = .String}, {name = "title", kind = .String}, {name = "messages", kind = .Array}},
		run = cmd_show,
	},
	{
		verb = "status",
		summary = "whether the identity's assistant is on, which model answers, and how it is confined",
		effect = .Read,
		out = {
			{name = "identity", kind = .String},
			{name = "enabled", kind = .Bool},
			{name = "provider", kind = .String},
			{name = "model", kind = .String},
			{name = "remote_opt_in", kind = .String, opt = true},
			{name = "tools", kind = .Array, help = "what it can call, with each tool's class"},
			{name = "pending", kind = .Int},
		},
		run = cmd_status,
	},
	{
		verb = "enable",
		summary = "turn the identity's assistant on (it is off by default)",
		effect = .Idempotent,
		out = {{name = "identity", kind = .String}, {name = "enabled", kind = .Bool}},
		run = cmd_enable,
	},
	{
		verb = "disable",
		summary = "turn the identity's assistant off; nothing else changes",
		effect = .Idempotent,
		out = {{name = "identity", kind = .String}, {name = "enabled", kind = .Bool}},
		run = cmd_disable,
	},
	{
		verb = "model",
		summary = "choose the local model that answers for this identity",
		effect = .Idempotent,
		args = {{name = "name", kind = .String, required = true, help = "an ollama model, e.g. qwen3:0.6b"}},
		out = {{name = "identity", kind = .String}, {name = "model", kind = .String}},
		run = cmd_model,
	},
	{
		verb = "remote",
		summary = "opt this identity into a remote model (Anthropic), or back out; never on by default",
		effect = .Destructive,
		flags = {
			{name = "model", kind = .String, def = REMOTE_MODEL_DEFAULT},
			{name = "off", kind = .Bool, help = "back to the local model"},
		},
		out = {{name = "identity", kind = .String}, {name = "provider", kind = .String}, {name = "model", kind = .String}},
		examples = {"ai remote --identity camille.roux --yes", "ai remote --identity camille.roux --off"},
		run = cmd_remote,
	},
	{
		verb = "sandbox-check",
		summary = "start a confined assistant on a throwaway home and probe what it can reach",
		effect = .Read,
		out = {{name = "landlock_abi", kind = .Int}, {name = "probes", kind = .Array}, {name = "passed", kind = .Int}, {name = "failed", kind = .Int}},
		run = cmd_sandbox_check,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "ai",
			summary  = "the assistant: one per identity, confined to it",
			gui      = true,
			selftest = run_selftest,
			commands = COMMANDS,
			notes    = "Every verb acts for one identity: --identity, or PALM_IDENTITY. The assistant runs in a sandbox with a session delegated to that identity alone; anything that leaves the identity is a proposal you confirm with `ai confirm`. Models: ollama on 127.0.0.1:11434 by default; a remote provider only after `ai remote --yes` for that identity, with ANTHROPIC_API_KEY in this process's environment.",
		}
	}
	return &g_surface
}

// ---------------------------------------------------------------------------

@(private = "file")
need_identity :: proc(c: ^kit.Call, p: ^Person) -> (ck.Identity, bool) {
	if c.identity == "" {
		names := make([dynamic]string, context.temp_allocator)
		for i in p.identities {
			if !i.archived {append(&names, fmt.tprintf("%s (%s)", i.handle, i.display_name))}
		}
		kit.cli_failf(c, kit.EXIT_USAGE, "the assistant works inside one identity; choose one with --identity: %s", strings.join(names[:], ", ", context.temp_allocator))
		kit.cli_err_field(c, "reason", "no identity")
		return {}, false
	}
	ident, ok := find_ident(p, c.identity)
	if !ok {
		kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "no identity %q in reach of this session", c.identity)
		kit.cli_err_field(c, "requested", c.identity)
		return {}, false
	}
	return ident, true
}

@(private = "file")
open_person :: proc(c: ^kit.Call) -> (p: Person, ok: bool) {
	pp, err := person_open()
	if err != "" {
		kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
		return pp, false
	}
	return pp, true
}

@(private = "file")
action_json :: proc(a: Action) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", a.id)
	kit.jset_str(o, "tool", a.tool)
	kit.jset_str(o, "class", a.class)
	kit.jset_str(o, "status", a.status)
	kit.jset_str(o, "summary", a.summary)
	kit.jset_bool(o, "tainted", a.tainted)
	ws := kit.jarr()
	for w in ck.array(a.warnings) {
		wo := kit.jobj()
		kit.jset_str(wo, "level", ck.get_str(w, "level"))
		kit.jset_str(wo, "text", ck.get_str(w, "text"))
		kit.jpush(ws, wo)
	}
	kit.jset(o, "warnings", ws)
	kit.jset_str(o, "created", a.created)
	return o
}

// value_to_kit copies a parsed JSON value into the kit's ordered tree.
value_to_kit :: proc(v: json.Value) -> ^kit.Json {
	#partial switch x in v {
	case json.Object:
		o := kit.jobj()
		for k, item in x {kit.jset(o, k, value_to_kit(item))}
		return o
	case json.Array:
		a := kit.jarr()
		for item in x {kit.jpush(a, value_to_kit(item))}
		return a
	case json.String:
		return kit.jstr(x)
	case json.Integer:
		return kit.jint(int(x))
	case json.Float:
		return kit.jnum(x)
	case json.Boolean:
		return kit.jbool(x)
	}
	return kit.jnull()
}

@(private = "file")
cmd_ask :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return c.err != nil && strings.contains(kit.json_text(c.err, 0), "\"code\":5") ? kit.EXIT_OUT_OF_SCOPE : kit.EXIT_USAGE}
	words := make([dynamic]string, context.temp_allocator)
	// The variadic tail starts with the first word itself.
	for r in kit.cli_rest(c) {append(&words, r)}
	if len(words) == 0 {append(&words, kit.cli_str(c, "request"))}
	request := strings.join(words[:], " ", context.temp_allocator)

	steps := kit.jarr()
	sink :: proc(data: rawptr, line: string, v: ck.Value) {
		steps := cast(^kit.Json)data
		t := ck.get_str(v, "t")
		switch t {
		case "result", "draft", "refused", "proposal":
			o := kit.jobj()
			kit.jset_str(o, "kind", t)
			kit.jset_str(o, "tool", ck.get_str(v, "tool"))
			s := ck.get_str(v, "summary")
			if s == "" {s = ck.get_str(v, "why")}
			kit.jset_str(o, "summary", s)
			if t == "result" || t == "draft" {kit.jset_bool(o, "ok", ck.get_bool(v, "ok"))}
			kit.jpush(steps, o)
		case "step":
			o := kit.jobj()
			kit.jset_str(o, "kind", "call")
			kit.jset_str(o, "tool", ck.get_str(v, "tool"))
			kit.jset_str(o, "args", ck.get_str(v, "shown"))
			kit.jpush(steps, o)
		case "error":
			fmt.eprintfln("ai: %s", ck.get_str(v, "message"))
		}
	}
	res := assist(&p, Ask{
		handle = ident.handle,
		request = request,
		conversation_id = kit.cli_str(c, "conversation"),
		max_steps = kit.cli_int(c, "max-steps", 5),
		sink = sink,
		sink_data = steps,
	})
	if res.error != "" && res.answer == "" {
		code := strings.contains(res.error, "is off") ? kit.EXIT_UNAVAILABLE : kit.EXIT_FAILED
		if strings.contains(res.error, "ollama") {code = kit.EXIT_UNAVAILABLE}
		kit.cli_fail(c, code, res.error)
		return code
	}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset_str(out, "conversation", res.conversation_id)
	kit.jset_str(out, "answer", res.answer)
	kit.jset_bool(out, "refused", res.refused)
	props := kit.jarr()
	if len(res.proposals) > 0 {
		mc, _ := machine_session(&p, ident)
		acts, _ := actions_list(mc, ident, true, 50, res.conversation_id)
		for id in res.proposals {
			for a in acts {if a.id == id {kit.jpush(props, action_json(a))}}
		}
	}
	kit.jset(out, "proposals", props)
	kit.jset(out, "steps", steps)
	kit.jset_str(out, "model", res.model)
	kit.jset_str(out, "provider", res.provider)
	kit.jset_int(out, "model_calls", res.model_calls)
	kit.jset_int(out, "ms", int(res.ms))
	if res.sandbox != "" {
		sv, sok := ck.parse(res.sandbox, context.temp_allocator)
		if sok {kit.jset(out, "sandbox", value_to_kit(sv))}
	}
	if res.error != "" {kit.jset_str(out, "warning", res.error)}
	c.out = out
	if !c.json {
		// A person reading a terminal wants the answer and what waits for them.
		fmt.printfln("%s\n", res.answer)
		for i in 0 ..< kit.jlen(props) {
			pr := props.items[i]
			id, _ := kit.jget(pr, "id")
			sm, _ := kit.jget(pr, "summary")
			fmt.printfln("waiting for you: %s\n  ai confirm %s --identity %s --yes", kit.json_scalar(sm), kit.json_scalar(id), ident.handle)
			ws, _ := kit.jget(pr, "warnings")
			for w in ws.items {
				lv, _ := kit.jget(w, "level")
				tx, _ := kit.jget(w, "text")
				fmt.printfln("  %s %s", kit.json_scalar(lv) == "warn" ? "!" : "·", kit.json_scalar(tx))
			}
		}
		c.out = kit.jobj() // already printed; an empty object renders as nothing
	}
	return kit.EXIT_OK
}

@(private = "file")
cmd_actions :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	acts, err := actions_list(mc, ident, kit.cli_bool(c, "pending"), kit.cli_int(c, "limit", 50), kit.cli_str(c, "conversation"))
	if err != "" {return kit.cli_fail(c, kit.EXIT_FAILED, err)}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	arr := kit.jarr()
	for a in acts {kit.jpush(arr, action_json(a))}
	kit.jset(out, "actions", arr)
	kit.jset_int(out, "count", len(acts))
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_confirm :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	id := kit.cli_str(c, "id")
	res, err := confirm(&p, ident.handle, id)
	out := kit.jobj()
	kit.jset_str(out, "id", id)
	kit.jset_str(out, "status", err == "" ? "executed" : "failed")
	rv, rok := ck.parse(res, context.temp_allocator)
	kit.jset(out, "result", rok ? value_to_kit(rv) : kit.jnull())
	if err != "" {
		c.out = out
		return kit.cli_fail(c, strings.contains(err, "no such") ? kit.EXIT_NOT_FOUND : kit.EXIT_FAILED, err)
	}
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_decline :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	id := kit.cli_str(c, "id")
	if err := decline(&p, ident.handle, id); err != "" {
		return kit.cli_fail(c, strings.contains(err, "no such") ? kit.EXIT_NOT_FOUND : kit.EXIT_FAILED, err)
	}
	out := kit.jobj()
	kit.jset_str(out, "id", id)
	kit.jset_str(out, "status", "declined")
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_conversations :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	v, e := ck.select(mc, "assistant_conversations", fmt.tprintf("select=id,title,model,provider,updated_at&identity_id=eq.%s&order=updated_at.desc&limit=100", ident.id), context.temp_allocator)
	if !ck.ok(e) {return kit.cli_fail(c, kit.EXIT_FAILED, e.message)}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset(out, "conversations", value_to_kit(v))
	kit.jset_int(out, "count", len(ck.array(v)))
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_show :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	conv := kit.cli_str(c, "conversation")
	cv, e := ck.select(mc, "assistant_conversations", fmt.tprintf("select=id,title&id=eq.%s&identity_id=eq.%s", conv, ident.id), context.temp_allocator)
	if !ck.ok(e) || len(ck.array(cv)) == 0 {return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such conversation in this identity")}
	mv, _ := ck.select(mc, "assistant_messages", fmt.tprintf("select=seq,role,content,tainted,created_at&conversation_id=eq.%s&order=seq", conv), context.temp_allocator)
	out := kit.jobj()
	kit.jset_str(out, "id", conv)
	kit.jset_str(out, "title", ck.get_str(ck.array(cv)[0], "title"))
	kit.jset(out, "messages", value_to_kit(mv))
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_status :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	s, _ := settings_get(mc, ident)
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset_bool(out, "enabled", s.enabled)
	kit.jset_str(out, "provider", s.provider)
	kit.jset_str(out, "model", s.provider == "anthropic" ? s.remote_model : s.model)
	if s.opted_in_at != "" {kit.jset_str(out, "remote_opt_in", s.opted_in_at)}
	reg := en.load_registry(tools_dir(), context.temp_allocator)
	tools := kit.jarr()
	for t in reg.tools {kit.jpush(tools, kit.jstr(fmt.tprintf("%s (%s)", t.name, en.class_name(t.class))))}
	kit.jset(out, "tools", tools)
	pend, _ := actions_list(mc, ident, true, 100)
	kit.jset_int(out, "pending", len(pend))
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
set_enabled :: proc(c: ^kit.Call, on: bool) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	s, _ := settings_get(mc, ident)
	s.enabled = on
	if !c.dry_run {
		if err := settings_put(mc, ident, s); err != "" {return kit.cli_fail(c, kit.EXIT_FAILED, err)}
	}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset_bool(out, "enabled", on)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_enable :: proc(c: ^kit.Call) -> int {return set_enabled(c, true)}
@(private = "file")
cmd_disable :: proc(c: ^kit.Call) -> int {return set_enabled(c, false)}

@(private = "file")
cmd_model :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	s, _ := settings_get(mc, ident)
	s.model = kit.cli_str(c, "name")
	if err := settings_put(mc, ident, s); err != "" {return kit.cli_fail(c, kit.EXIT_FAILED, err)}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset_str(out, "model", s.model)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_remote :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	s, _ := settings_get(mc, ident)
	if kit.cli_bool(c, "off") {
		s.provider = "local"
		s.opted_in_at = ""
		s.remote_model = ""
	} else {
		s.provider = "anthropic"
		s.remote_model = kit.cli_str(c, "model")
		s.opted_in_at = now_iso()
	}
	if err := settings_put(mc, ident, s); err != "" {return kit.cli_fail(c, kit.EXIT_FAILED, err)}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset_str(out, "provider", s.provider)
	kit.jset_str(out, "model", s.provider == "anthropic" ? s.remote_model : s.model)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_sandbox_check :: proc(c: ^kit.Call) -> int {
	out_text, err := sandbox_check_run()
	if err != "" {return kit.cli_fail(c, kit.EXIT_FAILED, err)}
	v, ok := ck.parse(out_text, context.temp_allocator)
	if !ok {return kit.cli_fail(c, kit.EXIT_FAILED, "the probe said nothing readable")}
	c.out = value_to_kit(v)
	if ck.get_int(v, "failed") != 0 {
		kit.cli_failf(c, kit.EXIT_FAILED, "%d probe(s) came out wrong", ck.get_int(v, "failed"))
		return kit.EXIT_FAILED
	}
	return kit.EXIT_OK
}
