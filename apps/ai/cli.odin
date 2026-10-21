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
			{name = "max-steps", kind = .Int, def = "6", help = "tool calls at most"},
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
			{name = "caveat", kind = .String, opt = true, help = "said whenever a small local model wrote the answer: it is frequently wrong"},
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
		summary = "the identity's conversations, newest first; --search finds them by a phrase in the title or any message",
		effect = .Read,
		flags = {
			{name = "search", kind = .String, help = "a phrase, matched case-insensitively in titles first, then in messages"},
			{name = "limit", kind = .Int, def = "100"},
		},
		out = {
			{name = "identity", kind = .String},
			{name = "conversations", kind = .Array, help = "id, title, model, provider, updated_at; with --search: id, title, updated_at, matched (title or the message's role), snippet"},
			{name = "count", kind = .Int},
			{name = "search", kind = .String, opt = true},
		},
		examples = {"ai conversations --identity camille.roux --json", `ai conversations --identity camille.roux --search "Halden invoice" --json`},
		run = cmd_conversations,
	},
	{
		verb = "rename",
		summary = "give a conversation a title of your own (one line, up to 200 characters)",
		effect = .Idempotent,
		args = {
			{name = "conversation", kind = .String, required = true, help = "a conversation id from `ai conversations`"},
			{name = "title", kind = .String, required = true, variadic = true},
		},
		out = {{name = "id", kind = .String}, {name = "title", kind = .String}},
		examples = {`ai rename 0d4e… "Halden invoice, September" --identity camille.roux --json`},
		run = cmd_rename,
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
		examples = {"ai remote --identity camille.roux --yes", "ai remote --identity camille.roux --off --yes"},
		run = cmd_remote,
	},
	{
		verb = "recall",
		summary = "what this identity's assistant retrieves by meaning: its own search index, ranked by a local embedding model",
		effect = .Read,
		args = {{name = "query", kind = .String, required = true, variadic = true, help = "a description of what you are looking for, in any words"}},
		flags = {{name = "limit", kind = .Int, def = "5"}},
		out = {
			{name = "identity", kind = .String},
			{name = "query", kind = .String},
			{name = "model", kind = .String, help = "the embedding model (ollama, on this machine)"},
			{name = "results", kind = .Array, help = "kind, title, who, detail, date, uri, key, similarity (cosine), snippet; best first"},
			{name = "count", kind = .Int},
			{name = "docs", kind = .Int, help = "documents in the identity's index"},
			{name = "embedded", kind = .Int, help = "embedded now; the rest came from the identity's vector cache"},
			{name = "ms", kind = .Int},
		},
		examples = {`ai recall --identity camille.roux "the bill from the Norwegian supplier" --json`},
		run = cmd_recall,
	},
	{
		verb = "prompts",
		summary = "the prompt library: requests saved to ask again (this device's, shared by every identity's composer)",
		effect = .Read,
		out = {{name = "prompts", kind = .Array, help = "name, body, in the library's order"}, {name = "count", kind = .Int}},
		examples = {"ai prompts --json"},
		run = cmd_prompts,
	},
	{
		verb = "prompt-save",
		summary = "save a prompt: an existing name is edited in place (same position), a new one is added at the end",
		effect = .Idempotent,
		args = {{name = "name", kind = .String, required = true}},
		flags = {{name = "text", kind = .String, required = true, help = "the prompt's body, as it goes into the composer"}},
		out = {{name = "name", kind = .String}, {name = "created", kind = .Bool, help = "false when an existing prompt was edited"}, {name = "position", kind = .Int, help = "1-based place in the library"}},
		examples = {`ai prompt-save "Unread mail" --text "Summarise my unread mail, newest first." --json`},
		run = cmd_prompt_save,
	},
	{
		verb = "prompt-rename",
		summary = "rename a prompt in place; refused when the new name is taken",
		effect = .Idempotent,
		args = {{name = "name", kind = .String, required = true}, {name = "new-name", kind = .String, required = true}},
		out = {{name = "name", kind = .String}, {name = "position", kind = .Int}},
		examples = {`ai prompt-rename "Unread mail" "Morning mail" --json`},
		run = cmd_prompt_rename,
	},
	{
		verb = "prompt-delete",
		summary = "remove a prompt from the library",
		effect = .Destructive,
		args = {{name = "name", kind = .String, required = true}},
		out = {{name = "name", kind = .String}, {name = "count", kind = .Int, help = "prompts left"}},
		examples = {`ai prompt-delete "Morning mail" --yes`},
		run = cmd_prompt_delete,
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
			notes    = "qwen3:0.6b, the default model, is small and frequently wrong: the steps, refusals and proposals are what happened; the answer is its account of them. Every verb acts for one identity: --identity, or PALM_IDENTITY. The assistant runs in a sandbox with a session delegated to that identity alone; anything that leaves the identity is a proposal you confirm with `ai confirm`. Models: ollama on 127.0.0.1:11434 by default; a remote provider only after `ai remote --yes` for that identity, with ANTHROPIC_API_KEY in this process's environment.",
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
		max_steps = kit.cli_int(c, "max-steps", 6),
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
	caveat := model_caveat(res.provider, res.model)
	if caveat != "" && !res.refused {kit.jset_str(out, "caveat", caveat)}
	c.out = out
	if !c.json {
		// A person reading a terminal wants the answer and what waits for them.
		fmt.printfln("%s\n", res.answer)
		if caveat != "" && !res.refused {fmt.printfln("(%s)\n", caveat)}
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
	limit := clamp(kit.cli_int(c, "limit", 100), 1, 1000)
	if kit.cli_has(c, "search") {
		q := kit.cli_str(c, "search")
		hits, serr := conv_search(mc, ident, q, limit, context.temp_allocator)
		if serr != "" {return kit.cli_fail(c, strings.trim_space(q) == "" ? kit.EXIT_USAGE : kit.EXIT_FAILED, serr)}
		arr := kit.jarr()
		for h in hits {
			o := kit.jobj()
			kit.jset_str(o, "id", h.id)
			kit.jset_str(o, "title", h.title)
			kit.jset_str(o, "updated_at", h.updated)
			kit.jset_str(o, "matched", h.in_title ? "title" : h.role)
			kit.jset_str(o, "snippet", h.snippet)
			kit.jpush(arr, o)
		}
		out := kit.jobj()
		kit.jset_str(out, "identity", ident.handle)
		kit.jset_str(out, "search", q)
		kit.jset(out, "conversations", arr)
		kit.jset_int(out, "count", len(hits))
		c.out = out
		return kit.EXIT_OK
	}
	v, e := ck.select(mc, "assistant_conversations", fmt.tprintf("select=id,title,model,provider,updated_at&identity_id=eq.%s&order=updated_at.desc&limit=%d", ident.id, limit), context.temp_allocator)
	if !ck.ok(e) {return kit.cli_fail(c, kit.EXIT_FAILED, e.message)}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset(out, "conversations", value_to_kit(v))
	kit.jset_int(out, "count", len(ck.array(v)))
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_rename :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	mc, merr := machine_session(&p, ident)
	if merr != "" {return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, merr)}
	id := kit.cli_str(c, "conversation")
	words := make([dynamic]string, context.temp_allocator)
	for r in kit.cli_rest(c) {append(&words, r)}
	if len(words) == 0 {append(&words, kit.cli_str(c, "title"))}
	title := strings.join(words[:], " ", context.temp_allocator)
	if title_clean(title, context.temp_allocator) == "" {return kit.cli_fail(c, kit.EXIT_USAGE, "a title needs at least one character")}
	out := kit.jobj()
	kit.jset_str(out, "id", id)
	if c.dry_run {
		kit.jset_str(out, "title", title_clean(title, context.temp_allocator))
		c.out = out
		return kit.EXIT_OK
	}
	stored, err, missing := conv_rename(mc, ident, id, title)
	if err != "" {return kit.cli_fail(c, missing ? kit.EXIT_NOT_FOUND : kit.EXIT_FAILED, err)}
	kit.jset_str(out, "title", stored)
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
	if err != "" {
		// No tool directory: the assistant is not installed here, which is
		// unavailable (6), not a probe that came out wrong.
		return kit.cli_fail(c, strings.has_prefix(err, "no tools in") ? kit.EXIT_UNAVAILABLE : kit.EXIT_FAILED, err)
	}
	v, ok := ck.parse(out_text, context.temp_allocator)
	if !ok {return kit.cli_fail(c, kit.EXIT_FAILED, "the probe said nothing readable")}
	c.out = value_to_kit(v)
	if ck.get_int(v, "failed") != 0 {
		kit.cli_failf(c, kit.EXIT_FAILED, "%d probe(s) came out wrong", ck.get_int(v, "failed"))
		return kit.EXIT_FAILED
	}
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// The prompt library
// ---------------------------------------------------------------------------

@(private = "file")
prompts_json :: proc(ps: []Prompt) -> ^kit.Json {
	arr := kit.jarr()
	for pr in ps {
		o := kit.jobj()
		kit.jset_str(o, "name", pr.name)
		kit.jset_str(o, "body", pr.body)
		kit.jpush(arr, o)
	}
	return arr
}

@(private = "file")
cmd_prompts :: proc(c: ^kit.Call) -> int {
	ps := prompts_load(context.temp_allocator)
	out := kit.jobj()
	kit.jset(out, "prompts", prompts_json(ps[:]))
	kit.jset_int(out, "count", len(ps))
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_prompt_save :: proc(c: ^kit.Call) -> int {
	name := strings.trim_space(kit.cli_str(c, "name"))
	if name == "" || strings.contains_any(name, "\t\r\n") {return kit.cli_fail(c, kit.EXIT_USAGE, "a prompt's name is one line with at least one character")}
	body := kit.cli_str(c, "text")
	if strings.trim_space(body) == "" {return kit.cli_fail(c, kit.EXIT_USAGE, "a prompt needs a body (--text)")}
	ps := prompts_load()
	created := prompt_set(&ps, name, body)
	if !c.dry_run {prompts_save(ps[:])}
	out := kit.jobj()
	kit.jset_str(out, "name", ps[prompt_find(ps[:], name)].name)
	kit.jset_bool(out, "created", created)
	kit.jset_int(out, "position", prompt_find(ps[:], name) + 1)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_prompt_rename :: proc(c: ^kit.Call) -> int {
	to := kit.cli_str(c, "new-name")
	if strings.contains_any(to, "\t\r\n") {return kit.cli_fail(c, kit.EXIT_USAGE, "a prompt's name is one line")}
	ps := prompts_load()
	if err := prompt_rename(&ps, kit.cli_str(c, "name"), to); err != "" {
		return kit.cli_fail(c, err == "no such prompt" ? kit.EXIT_NOT_FOUND : kit.EXIT_USAGE, err)
	}
	if !c.dry_run {prompts_save(ps[:])}
	out := kit.jobj()
	kit.jset_str(out, "name", strings.trim_space(to))
	kit.jset_int(out, "position", prompt_find(ps[:], to) + 1)
	c.out = out
	return kit.EXIT_OK
}

@(private = "file")
cmd_prompt_delete :: proc(c: ^kit.Call) -> int {
	ps := prompts_load()
	name := kit.cli_str(c, "name")
	if !prompt_delete(&ps, name) {return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such prompt")}
	if !c.dry_run {prompts_save(ps[:])}
	out := kit.jobj()
	kit.jset_str(out, "name", strings.trim_space(name))
	kit.jset_int(out, "count", len(ps))
	c.out = out
	return kit.EXIT_OK
}

// ---------------------------------------------------------------------------
// Retrieval
// ---------------------------------------------------------------------------

@(private = "file")
cmd_recall :: proc(c: ^kit.Call) -> int {
	p, ok := open_person(c)
	if !ok {return kit.EXIT_UNAVAILABLE}
	ident, iok := need_identity(c, &p)
	if !iok {return kit.EXIT_USAGE}
	words := make([dynamic]string, context.temp_allocator)
	for r in kit.cli_rest(c) {append(&words, r)}
	if len(words) == 0 {append(&words, kit.cli_str(c, "query"))}
	q := strings.join(words[:], " ", context.temp_allocator)
	limit := clamp(kit.cli_int(c, "limit", 5), 1, 50)
	hits, stats, err := en.recall(index_dir(), ident.handle, fmt.tprintf("%s/recall", state_dir(ident.handle)), q, limit, person_embed, nil, context.temp_allocator)
	if err != "" {
		code := kit.EXIT_FAILED
		if strings.has_prefix(err, "ollama") || strings.has_prefix(err, "no embedding") {code = kit.EXIT_UNAVAILABLE}
		if strings.has_prefix(err, "no search index") {code = kit.EXIT_NOT_FOUND}
		return kit.cli_fail(c, code, err)
	}
	arr := kit.jarr()
	for h in hits {
		o := kit.jobj()
		kit.jset_str(o, "kind", h.kind)
		kit.jset_str(o, "title", h.title)
		kit.jset_str(o, "who", h.who)
		kit.jset_str(o, "detail", h.detail)
		kit.jset_str(o, "date", en.date_text(int(h.time / 86400)))
		kit.jset_str(o, "uri", h.uri)
		kit.jset_str(o, "key", h.key)
		kit.jset(o, "similarity", kit.jnum(f64(h.score)))
		kit.jset_str(o, "snippet", h.snippet)
		kit.jpush(arr, o)
	}
	out := kit.jobj()
	kit.jset_str(out, "identity", ident.handle)
	kit.jset_str(out, "query", q)
	kit.jset_str(out, "model", stats.model)
	kit.jset(out, "results", arr)
	kit.jset_int(out, "count", len(hits))
	kit.jset_int(out, "docs", stats.docs)
	kit.jset_int(out, "embedded", stats.embedded)
	kit.jset_int(out, "ms", int(stats.ms))
	c.out = out
	return kit.EXIT_OK
}
