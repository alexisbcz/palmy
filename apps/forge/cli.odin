// The command line, on the shared convention (apps/kit/cli.odin): declared
// verbs, --json on everything, side-effect classes, --dry-run, stable exit
// codes, and scope that can only be narrowed.
//
// Verbs are `noun-verb` (`repo-create`); `forge repo create` is accepted and
// rewritten to it, so both spellings work and the schema has one name.
//
// Scope: PALM_IDENTITY, narrowed by --identity, names the identity this
// command acts as. With a personal access token the token's identity is the
// scope, and asking for another is refused with exit 5 before anything is
// sent. With a person's own session the database still enforces what that
// person may touch; the CLI additionally refuses to act as an identity other
// than the one in scope.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import wire "forge:wire"
import kit "kit:."

NOUNS :: [?]string{"repo", "issue", "pr", "token", "collab"}

// rewrite_argv turns `repo create x` into `repo-create x`.
rewrite_argv :: proc(argv: []string) -> []string {
	if len(argv) < 2 || strings.has_prefix(argv[1], "-") {
		return argv
	}
	for n in NOUNS {
		if argv[0] == n {
			out := make([]string, len(argv) - 1)
			out[0] = fmt.aprintf("%s-%s", argv[0], argv[1])
			copy(out[1:], argv[2:])
			return out
		}
	}
	return argv
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

// kj converts a parsed JSON value into the kit's ordered tree.
kj :: proc(v: json.Value) -> ^kit.Json {
	switch t in v {
	case json.Null:
		return kit.jnull()
	case json.Integer:
		return kit.jint(int(t))
	case json.Float:
		return kit.jnum(f64(t))
	case json.Boolean:
		return kit.jbool(bool(t))
	case json.String:
		return kit.jstr(string(t))
	case json.Array:
		a := kit.jarr()
		for x in t {
			kit.jpush(a, kj(x))
		}
		return a
	case json.Object:
		o := kit.jobj()
		for k, x in t {
			kit.jset(o, k, kj(x))
		}
		return o
	}
	return kit.jnull()
}

// pick copies the named keys of a row, in that order.
pick :: proc(row: json.Value, keys: ..string) -> ^kit.Json {
	o := kit.jobj()
	for k in keys {
		kit.jset(o, k, kj(wire.get(row, k)))
	}
	return o
}

pick_all :: proc(rows: json.Value, keys: ..string) -> ^kit.Json {
	a := kit.jarr()
	for row in wire.arr(rows) {
		kit.jpush(a, pick(row, ..keys))
	}
	return a
}

// fail maps a failed call to the convention's exit codes.
fail :: proc(c: ^kit.Call, r: wire.Result, what: string) -> int {
	switch {
	case r.status == 0:
		return kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "%s: %s", what, r.err)
	case r.code == "42501" || r.status == 401 || r.status == 403:
		return kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "%s: %s", what, r.err)
	case r.status == 404 || r.code == "P0002":
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s: %s", what, r.err)
	}
	return kit.cli_failf(c, kit.EXIT_FAILED, "%s: %s", what, r.err)
}

// open_client opens the client and applies the scope rule.
open_client :: proc(c: ^kit.Call, need_auth := false) -> (cl: Client, code: int) {
	err: string
	cl, err = client_open(c.identity)
	if err != "" {
		// Credentials that were refused are a refusal (5); a server that
		// could not be reached is unavailable (6).
		code := kit.EXIT_UNAVAILABLE if strings.contains(err, "not reachable") else kit.EXIT_OUT_OF_SCOPE
		return cl, kit.cli_fail(c, code, err)
	}
	if need_auth && cl.bearer == "" {
		return cl, kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "sign in first (`accounts signin`), or set FORGE_TOKEN")
	}
	if cl.kind == "token" && c.identity != "" {
		// The token's identity is the scope; a different one is refused here,
		// before anything is sent.
		ids := my_identities(&cl)
		row, _ := wire.first(ids.value)
		if h := wire.str(row, "handle"); h != c.identity {
			kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("this token acts for %q", h))
			kit.cli_err_field(c, "identity", h)
			kit.cli_err_field(c, "requested", c.identity)
			return cl, kit.EXIT_OUT_OF_SCOPE
		}
	}
	return cl, 0
}

repo_arg :: proc(c: ^kit.Call, cl: ^Client) -> (ref: Repo_Ref, row: json.Value, code: int) {
	ok: bool
	ref, ok = parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return ref, nil, kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	row, ok = get_repo(cl, ref)
	if !ok {
		return ref, nil, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s/%s: no such repository, or not visible to you", ref.owner, ref.name)
	}
	return ref, row, 0
}

// writer is the identity this command writes as.
writer :: proc(c: ^kit.Call, cl: ^Client, ref: Repo_Ref) -> (id: string, code: int) {
	err: string
	id, err = acting_identity(cl, ref, c.identity)
	if err != "" {
		return "", kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, err)
	}
	return id, 0
}

number_arg :: proc(c: ^kit.Call) -> int {
	n, _ := strconv.parse_int(strings.trim_prefix(kit.cli_str(c, "number"), "#"))
	return n
}

// ---------------------------------------------------------------------------
// Declarations
// ---------------------------------------------------------------------------

REPO_ARG :: kit.Param{name = "repo", kind = .String, required = true, help = "<identity>/<name>"}
NUMBER_ARG :: kit.Param{name = "number", kind = .Int, required = true, help = "the issue or pull request number"}

REPO_FIELDS := []kit.Field {
	{name = "repo", kind = .String, help = "<identity>/<name>"},
	{name = "visibility", kind = .String, help = "private, shared or public"},
	{name = "role", kind = .String, help = "your access: read, write or admin"},
	{name = "default_branch", kind = .String},
	{name = "open_issues", kind = .Int},
	{name = "open_pulls", kind = .Int},
	{name = "pushed_at", kind = .String, opt = true},
}

ISSUE_FIELDS := []kit.Field {
	{name = "number", kind = .Int},
	{name = "state", kind = .String, help = "open or closed (a merged pull request is closed)"},
	{name = "title", kind = .String},
	{name = "author", kind = .String, help = "the identity that opened it"},
	{name = "comments", kind = .Int},
	{name = "created_at", kind = .String},
}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "whoami",
		summary = "how this command is signed in, and the identities it can act as",
		effect = .Read,
		out = {{name = "kind", kind = .String}, {name = "scope", kind = .String, opt = true}, {name = "identities", kind = .Array}},
		examples = {"forge whoami --json"},
		run = cmd_whoami,
	},
	{
		verb = "repo-list",
		summary = "repositories visible to you",
		effect = .Read,
		flags = {{name = "owner", kind = .String, help = "only this identity's"}, {name = "visibility", kind = .Enum, values = {"private", "shared", "public"}}},
		out = {{name = "repos", kind = .Array, of = REPO_FIELDS}, {name = "count", kind = .Int}},
		examples = {"forge repo list --json", "forge repo list --owner ada --visibility public"},
		run = cmd_repo_list,
	},
	{
		verb = "repo-create",
		summary = "create a repository owned by the identity in scope",
		effect = .Mutate,
		args = {{name = "name", kind = .String, required = true}},
		flags = {
			{name = "visibility", kind = .Enum, values = {"private", "shared", "public"}, def = "private"},
			{name = "description", kind = .String},
			{name = "readme", kind = .Bool, help = "start with a README commit"},
		},
		out = {{name = "repo", kind = .String}, {name = "id", kind = .String}, {name = "visibility", kind = .String}, {name = "clone_url", kind = .String}},
		examples = {"forge repo create notes --identity ada --readme", "forge repo create site --visibility public"},
		run = cmd_repo_create,
	},
	{
		verb = "repo-show",
		summary = "one repository: settings, your access, branches",
		effect = .Read,
		args = {REPO_ARG},
		out = REPO_FIELDS,
		examples = {"forge repo show ada/notes --json"},
		run = cmd_repo_show,
	},
	{
		verb = "repo-set",
		summary = "change a repository's settings (admin)",
		effect = .Idempotent,
		args = {REPO_ARG},
		flags = {
			{name = "visibility", kind = .Enum, values = {"private", "shared", "public"}},
			{name = "description", kind = .String},
			{name = "default-branch", kind = .String},
			{name = "archive", kind = .Bool, help = "make it read-only; --no-archive undoes it"},
		},
		out = REPO_FIELDS,
		examples = {"forge repo set ada/notes --visibility public"},
		run = cmd_repo_set,
	},
	{
		verb = "repo-delete",
		summary = "delete a repository's record, issues and grants",
		effect = .Destructive,
		args = {REPO_ARG},
		out = {{name = "deleted", kind = .String}},
		examples = {"forge repo delete ada/scratch --yes"},
		run = cmd_repo_delete,
	},
	{
		verb = "clone-url",
		summary = "the URL to give git",
		effect = .Read,
		args = {REPO_ARG},
		out = {{name = "url", kind = .String}},
		examples = {"git clone $(forge clone-url ada/notes)"},
		run = cmd_clone_url,
	},
	{
		verb = "tree",
		summary = "list a directory",
		effect = .Read,
		args = {REPO_ARG, {name = "path", kind = .String}},
		flags = {{name = "ref", kind = .String, help = "branch, tag or sha (default: the default branch)"}},
		out = {{name = "ref", kind = .String}, {name = "sha", kind = .String}, {name = "entries", kind = .Array}},
		examples = {"forge tree ada/notes src --json"},
		run = cmd_tree,
	},
	{
		verb = "cat",
		summary = "print a file",
		effect = .Read,
		args = {REPO_ARG, {name = "path", kind = .String, required = true}},
		flags = {{name = "ref", kind = .String}},
		out = {{name = "path", kind = .String}, {name = "size", kind = .Int}, {name = "binary", kind = .Bool}, {name = "text", kind = .String}},
		examples = {"forge cat ada/notes README.md"},
		run = cmd_cat,
	},
	{
		verb = "log",
		summary = "commits, newest first",
		effect = .Read,
		args = {REPO_ARG},
		flags = {{name = "ref", kind = .String}, {name = "limit", kind = .Int, def = "20"}},
		out = {{name = "commits", kind = .Array}},
		examples = {"forge log ada/notes --limit 5 --json"},
		run = cmd_log,
	},
	{
		verb = "show",
		summary = "one commit, with its diff",
		effect = .Read,
		args = {REPO_ARG, {name = "sha", kind = .String, required = true}},
		out = {{name = "sha", kind = .String}, {name = "message", kind = .String}, {name = "files", kind = .Array}, {name = "diff", kind = .String}},
		examples = {"forge show ada/notes 1a2b3c4 --json"},
		run = cmd_show,
	},
	{
		verb = "branches",
		summary = "branches, most recently committed first",
		effect = .Read,
		args = {REPO_ARG},
		out = {{name = "default", kind = .String}, {name = "branches", kind = .Array}},
		examples = {"forge branches ada/notes"},
		run = cmd_branches,
	},
	{
		verb = "issue-list",
		summary = "issues on a repository",
		effect = .Read,
		args = {REPO_ARG},
		flags = {{name = "state", kind = .Enum, values = {"open", "closed", "all"}, def = "open"}},
		out = {{name = "issues", kind = .Array, of = ISSUE_FIELDS}, {name = "count", kind = .Int}},
		examples = {"forge issue list ada/notes --json"},
		run = cmd_issue_list,
	},
	{
		verb = "issue-create",
		summary = "open an issue, as the identity in scope",
		effect = .Mutate,
		args = {REPO_ARG, {name = "title", kind = .String, required = true}},
		flags = {{name = "body", kind = .String}},
		out = {{name = "number", kind = .Int}, {name = "url", kind = .String}},
		examples = {`forge issue create ada/notes "Sync loses the last line" --body "..."`},
		run = cmd_issue_create,
	},
	{
		verb = "issue-show",
		summary = "an issue or pull request with its comments",
		effect = .Read,
		args = {REPO_ARG, NUMBER_ARG},
		out = {{name = "number", kind = .Int}, {name = "title", kind = .String}, {name = "state", kind = .String}, {name = "comments", kind = .Array}},
		examples = {"forge issue show ada/notes 1 --json"},
		run = cmd_issue_show,
	},
	{
		verb = "issue-comment",
		summary = "comment on an issue or pull request",
		effect = .Mutate,
		args = {REPO_ARG, NUMBER_ARG, {name = "body", kind = .String, required = true}},
		out = {{name = "id", kind = .String}},
		examples = {`forge issue comment ada/notes 1 "Reproduced on main."`},
		run = cmd_issue_comment,
	},
	{
		verb = "issue-close",
		summary = "close an issue",
		effect = .Idempotent,
		args = {REPO_ARG, NUMBER_ARG},
		out = {{name = "number", kind = .Int}, {name = "state", kind = .String}},
		examples = {"forge issue close ada/notes 1"},
		run = cmd_issue_close,
	},
	{
		verb = "issue-reopen",
		summary = "reopen an issue",
		effect = .Idempotent,
		args = {REPO_ARG, NUMBER_ARG},
		out = {{name = "number", kind = .Int}, {name = "state", kind = .String}},
		examples = {"forge issue reopen ada/notes 1"},
		run = cmd_issue_reopen,
	},
	{
		verb = "pr-list",
		summary = "pull requests on a repository",
		effect = .Read,
		args = {REPO_ARG},
		flags = {{name = "state", kind = .Enum, values = {"open", "closed", "all"}, def = "open"}},
		out = {{name = "pulls", kind = .Array}, {name = "count", kind = .Int}},
		examples = {"forge pr list ada/notes --json"},
		run = cmd_pr_list,
	},
	{
		verb = "pr-create",
		summary = "open a pull request from a branch",
		effect = .Mutate,
		args = {REPO_ARG, {name = "title", kind = .String, required = true}},
		flags = {
			{name = "head", kind = .String, required = true, help = "the branch with the changes"},
			{name = "base", kind = .String, help = "the branch to merge into (default: the default branch)"},
			{name = "body", kind = .String},
		},
		out = {{name = "number", kind = .Int}, {name = "head", kind = .String}, {name = "base", kind = .String}},
		examples = {`forge pr create ada/notes "Wrap long lines" --head wrap`},
		run = cmd_pr_create,
	},
	{
		verb = "pr-show",
		summary = "a pull request: branches, mergeability, reviews and conversation",
		effect = .Read,
		args = {REPO_ARG, NUMBER_ARG},
		out = {{name = "number", kind = .Int}, {name = "state", kind = .String}, {name = "mergeable", kind = .Bool}, {name = "files", kind = .Array}},
		examples = {"forge pr show ada/notes 2 --json"},
		run = cmd_pr_show,
	},
	{
		verb = "pr-diff",
		summary = "the pull request's diff against its merge base",
		effect = .Read,
		args = {REPO_ARG, NUMBER_ARG},
		out = {{name = "diff", kind = .String}},
		examples = {"forge pr diff ada/notes 2"},
		run = cmd_pr_diff,
	},
	{
		verb = "pr-review",
		summary = "review a pull request; with --path and --line, comment on a line",
		effect = .Mutate,
		args = {REPO_ARG, NUMBER_ARG},
		flags = {
			{name = "state", kind = .Enum, values = {"approve", "request-changes", "comment"}, def = "comment"},
			{name = "body", kind = .String},
			{name = "path", kind = .String, help = "a file in the diff"},
			{name = "line", kind = .Int, help = "a line in the new version of it"},
		},
		out = {{name = "review", kind = .String}, {name = "state", kind = .String}},
		examples = {"forge pr review ada/notes 2 --state approve --body LGTM"},
		run = cmd_pr_review,
	},
	{
		verb = "pr-merge",
		summary = "merge a pull request on the server",
		effect = .Mutate,
		args = {REPO_ARG, NUMBER_ARG},
		flags = {{name = "method", kind = .Enum, values = {"merge-commit", "fast-forward"}, def = "merge-commit"}},
		out = {{name = "number", kind = .Int}, {name = "method", kind = .String}, {name = "sha", kind = .String}},
		examples = {"forge pr merge ada/notes 2 --method fast-forward"},
		run = cmd_pr_merge,
	},
	{
		verb = "collab-list",
		summary = "who else has access to a repository",
		effect = .Read,
		args = {REPO_ARG},
		out = {{name = "collaborators", kind = .Array}},
		examples = {"forge collab list ada/notes"},
		run = cmd_collab_list,
	},
	{
		verb = "collab-add",
		summary = "grant another identity access (the owner identity only)",
		effect = .Idempotent,
		args = {REPO_ARG, {name = "handle", kind = .String, required = true}},
		flags = {{name = "role", kind = .Enum, values = {"read", "write", "admin"}, def = "read"}},
		out = {{name = "grant", kind = .String}, {name = "role", kind = .String}},
		examples = {"forge collab add ada/notes bob --role write"},
		run = cmd_collab_add,
	},
	{
		verb = "collab-remove",
		summary = "revoke a grant",
		effect = .Idempotent,
		args = {REPO_ARG, {name = "handle", kind = .String, required = true}},
		out = {{name = "revoked", kind = .Bool}},
		examples = {"forge collab remove ada/notes bob"},
		run = cmd_collab_remove,
	},
	{
		verb = "token-list",
		summary = "personal access tokens of the identities you can act as",
		effect = .Read,
		out = {{name = "tokens", kind = .Array}},
		examples = {"forge token list --json"},
		run = cmd_token_list,
	},
	{
		verb = "token-create",
		summary = "a personal access token for one identity; printed once",
		effect = .Mutate,
		args = {{name = "name", kind = .String, required = true}},
		flags = {{name = "scope", kind = .Enum, values = {"read", "write"}, def = "read"}, {name = "days", kind = .Int, help = "expire after this many days"}},
		out = {{name = "id", kind = .String}, {name = "token", kind = .String}, {name = "scope", kind = .String}, {name = "identity", kind = .String}},
		examples = {"forge token create laptop --identity ada --scope write"},
		run = cmd_token_create,
	},
	{
		verb = "token-revoke",
		summary = "revoke a token; sessions made from it stop at once",
		effect = .Destructive,
		args = {{name = "id", kind = .String, required = true}},
		out = {{name = "revoked", kind = .String}},
		examples = {"forge token revoke 4f1c... --yes"},
		run = cmd_token_revoke,
	},
	{
		verb = "activity",
		summary = "the activity feed, everywhere you can see or on one repository",
		effect = .Read,
		args = {{name = "repo", kind = .String, help = "<identity>/<name>"}},
		flags = {{name = "limit", kind = .Int, def = "30"}},
		out = {{name = "events", kind = .Array}},
		examples = {"forge activity ada/notes --json"},
		run = cmd_activity,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "forge",
			summary  = "the Palmframe forge: repositories, issues and pull requests owned by identities",
			gui      = true,
			selftest = selftest,
			commands = COMMANDS,
			notes    = "Nouns may be written apart: `forge repo create` is `forge repo-create`. Credentials: FORGE_TOKEN, else the session from `forge login`.",
		}
	}
	return &g_surface
}

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

cmd_whoami :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	kind := cl.kind if cl.kind != "" else "anonymous"
	kit.jset_str(c.out, "kind", kind)
	if cl.email != "" && cl.kind != "token" {
		kit.jset_str(c.out, "email", cl.email)
	}
	if cl.kind == "token" {
		kit.jset_str(c.out, "token_scope", cl.token_scope)
	}
	if cl.scope != "" {
		kit.jset_str(c.out, "scope", cl.scope)
	}
	r := my_identities(&cl)
	if !wire.ok(r) {
		return fail(c, r, "whoami")
	}
	kit.jset(c.out, "identities", pick_all(r.value, "handle", "display_name", "kind", "color"))
	kit.jset_str(c.out, "forge", cl.forge)
	return 0
}

// ---------------------------------------------------------------------------
// Repositories
// ---------------------------------------------------------------------------

repo_summary :: proc(row: json.Value) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "repo", fmt.tprintf("%s/%s", wire.str(row, "owner_handle"), wire.str(row, "name")))
	kit.jset_str(o, "visibility", wire.str(row, "visibility"))
	kit.jset_str(o, "role", wire.str(row, "role"))
	kit.jset_str(o, "default_branch", wire.str(row, "default_branch"))
	kit.jset_int(o, "open_issues", wire.num(row, "open_issues"))
	kit.jset_int(o, "open_pulls", wire.num(row, "open_pulls"))
	kit.jset(o, "pushed_at", kj(wire.get(row, "pushed_at")))
	return o
}

cmd_repo_list :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	owner := kit.cli_str(c, "owner")
	r := list_repos(&cl, owner, kit.cli_str(c, "visibility"))
	if !wire.ok(r) {
		return fail(c, r, "repo list")
	}
	a := kit.jarr()
	for row in wire.arr(r.value) {
		kit.jpush(a, repo_summary(row))
	}
	kit.jset(c.out, "repos", a)
	kit.jset_int(c.out, "count", len(wire.arr(r.value)))
	return 0
}

cmd_repo_create :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	owner_id, owner_handle := "", ""
	if cl.kind == "token" {
		owner_id = cl.token_identity
	} else if c.identity != "" {
		row, ok := identity_by_handle(&cl, c.identity)
		if !ok {
			return kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "%s is not one of your identities", c.identity)
		}
		owner_id = wire.str(row, "id")
	} else {
		ids := wire.arr(my_identities(&cl).value)
		if len(ids) == 0 {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "this account has no identity yet")
		}
		if len(ids) > 1 {
			return kit.cli_fail(c, kit.EXIT_USAGE, "you have several identities: say which owns it with --identity")
		}
		owner_id = wire.str(ids[0], "id")
	}
	for row in wire.arr(my_identities(&cl).value) {
		if wire.str(row, "id") == owner_id {
			owner_handle = wire.str(row, "handle")
		}
	}
	name := kit.cli_str(c, "name")
	ref := Repo_Ref{owner_handle, name}
	kit.jset_str(c.out, "repo", fmt.tprintf("%s/%s", owner_handle, name))
	if c.dry_run {
		kit.jset_str(c.out, "visibility", kit.cli_str(c, "visibility"))
		kit.jset_str(c.out, "clone_url", clone_url(&cl, ref))
		return 0
	}
	r := create_repo(&cl, owner_id, name, kit.cli_str(c, "visibility"), kit.cli_str(c, "description"))
	if !wire.ok(r) {
		if r.status == 409 {
			return kit.cli_failf(c, kit.EXIT_FAILED, "%s/%s already exists", owner_handle, name)
		}
		return fail(c, r, "repo create")
	}
	row, _ := wire.first(r.value)
	kit.jset_str(c.out, "id", wire.str(row, "id"))
	kit.jset_str(c.out, "visibility", wire.str(row, "visibility"))
	kit.jset_str(c.out, "clone_url", clone_url(&cl, ref))
	if ir := init_repo(&cl, ref, kit.cli_bool(c, "readme")); !wire.ok(ir) {
		kit.cli_note(c, "created, but the forge did not initialise it on disk: %s", ir.err)
	} else if kit.cli_bool(c, "readme") {
		kit.jset_str(c.out, "initial_commit", wire.str(ir.value, "commit"))
	}
	return 0
}

cmd_repo_show :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, row, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	c.out = repo_summary(row)
	kit.jset_str(c.out, "description", wire.str(row, "description"))
	kit.jset_str(c.out, "owner_name", wire.str(row, "owner_name"))
	kit.jset_str(c.out, "clone_url", clone_url(&cl, ref))
	br := get_branches(&cl, ref)
	names := kit.jarr()
	for b in wire.arr(br.value, "branches") {
		kit.jpush(names, kit.jstr(wire.str(b, "name")))
	}
	kit.jset(c.out, "branches", names)
	return 0
}

cmd_repo_set :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	_, row, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	parts := make([dynamic]string)
	if kit.cli_has(c, "visibility") {
		append(&parts, fmt.tprintf(`"visibility":%s`, wire.q(kit.cli_str(c, "visibility"))))
	}
	if kit.cli_has(c, "description") {
		append(&parts, fmt.tprintf(`"description":%s`, wire.q(kit.cli_str(c, "description"))))
	}
	if kit.cli_has(c, "default-branch") {
		append(&parts, fmt.tprintf(`"default_branch":%s`, wire.q(kit.cli_str(c, "default-branch"))))
	}
	if kit.cli_has(c, "archive") {
		append(&parts, `"archived_at":"now()"` if kit.cli_bool(c, "archive") else `"archived_at":null`)
	}
	if len(parts) == 0 {
		return kit.cli_fail(c, kit.EXIT_USAGE, "nothing to change")
	}
	if c.dry_run {
		c.out = repo_summary(row)
		return 0
	}
	body := fmt.tprintf("{{%s}}", strings.join(parts[:], ","))
	body, _ = strings.replace_all(body, `"now()"`, fmt.tprintf("%q", "now"))
	r := update_repo(&cl, wire.str(row, "id"), body)
	if !wire.ok(r) {
		return fail(c, r, "repo set")
	}
	if len(wire.arr(r.value)) == 0 {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "only the owning identity (or an admin grant) can change settings")
	}
	updated, _ := get_repo(&cl, Repo_Ref{wire.str(row, "owner_handle"), wire.str(row, "name")})
	c.out = repo_summary(updated)
	return 0
}

cmd_repo_delete :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	ref, row, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	kit.jset_str(c.out, "deleted", fmt.tprintf("%s/%s", ref.owner, ref.name))
	if c.dry_run {
		return 0
	}
	r := delete_repo(&cl, wire.str(row, "id"))
	if !wire.ok(r) {
		return fail(c, r, "repo delete")
	}
	if len(wire.arr(r.value)) == 0 {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "only the owning identity can delete it")
	}
	return 0
}

cmd_clone_url :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, ok := parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	kit.jset_str(c.out, "url", clone_url(&cl, ref))
	return 0
}

// ---------------------------------------------------------------------------
// Contents
// ---------------------------------------------------------------------------

cmd_tree :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, ok := parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	r := get_tree(&cl, ref, kit.cli_str(c, "ref"), kit.cli_str(c, "path"))
	if !wire.ok(r) {
		return fail(c, r, "tree")
	}
	kit.jset_str(c.out, "ref", wire.str(r.value, "ref"))
	kit.jset(c.out, "sha", kj(wire.get(r.value, "sha")))
	kit.jset(c.out, "entries", pick_all(wire.get(r.value, "entries"), "type", "name", "size"))
	return 0
}

cmd_cat :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, ok := parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	r := get_blob(&cl, ref, kit.cli_str(c, "ref"), kit.cli_str(c, "path"))
	if !wire.ok(r) {
		return fail(c, r, "cat")
	}
	if !c.json && !wire.flag(r.value, "binary") {
		// A file is printed as itself, not as `text: ...`.
		fmt.print(wire.str(r.value, "text"))
		c.out = kit.jobj()
		return 0
	}
	c.out = pick(r.value, "path", "ref", "sha", "size", "binary", "truncated", "text")
	return 0
}

cmd_log :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, ok := parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	r := get_commits(&cl, ref, kit.cli_str(c, "ref"), kit.cli_int(c, "limit", 20))
	if !wire.ok(r) {
		return fail(c, r, "log")
	}
	a := kit.jarr()
	for row in wire.arr(r.value, "commits") {
		o := kit.jobj()
		kit.jset_str(o, "sha", wire.str(row, "sha")[:min(len(wire.str(row, "sha")), 10)] if !c.json else wire.str(row, "sha"))
		kit.jset_str(o, "author", wire.str(row, "author_name"))
		kit.jset_str(o, "date", wire.str(row, "authored_at"))
		kit.jset_str(o, "summary", wire.str(row, "summary"))
		kit.jpush(a, o)
	}
	kit.jset(c.out, "commits", a)
	return 0
}

cmd_show :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, ok := parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	r := get_commit(&cl, ref, kit.cli_str(c, "sha"))
	if !wire.ok(r) {
		return fail(c, r, "show")
	}
	c.out = pick(r.value, "sha", "parents", "author_name", "author_email", "authored_at", "message", "files", "diff")
	return 0
}

cmd_branches :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, ok := parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	r := get_branches(&cl, ref)
	if !wire.ok(r) {
		return fail(c, r, "branches")
	}
	kit.jset_str(c.out, "default", wire.str(r.value, "default"))
	kit.jset(c.out, "branches", pick_all(wire.get(r.value, "branches"), "name", "summary", "author", "date"))
	return 0
}

// ---------------------------------------------------------------------------
// Issues
// ---------------------------------------------------------------------------

issue_summary :: proc(row: json.Value) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_int(o, "number", wire.num(row, "number"))
	state := wire.str(row, "state")
	if !wire.is_null(row, "merged_at") {
		state = "merged"
	}
	kit.jset_str(o, "state", state)
	kit.jset_str(o, "title", wire.str(row, "title"))
	kit.jset_str(o, "author", wire.str(row, "author_handle"))
	kit.jset_int(o, "comments", wire.num(row, "comment_count"))
	kit.jset_str(o, "created_at", wire.str(row, "created_at"))
	return o
}

list_items :: proc(c: ^kit.Call, pulls: bool) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	_, row, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	r := list_issues(&cl, wire.str(row, "id"), pulls, kit.cli_str(c, "state"))
	if !wire.ok(r) {
		return fail(c, r, "list")
	}
	a := kit.jarr()
	for x in wire.arr(r.value) {
		o := issue_summary(x)
		if pulls {
			kit.jset_str(o, "head", wire.str(x, "head_ref"))
			kit.jset_str(o, "base", wire.str(x, "base_ref"))
		}
		kit.jpush(a, o)
	}
	kit.jset(c.out, "pulls" if pulls else "issues", a)
	kit.jset_int(c.out, "count", len(wire.arr(r.value)))
	return 0
}

cmd_issue_list :: proc(c: ^kit.Call) -> int {return list_items(c, false)}
cmd_pr_list :: proc(c: ^kit.Call) -> int {return list_items(c, true)}

cmd_issue_create :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	ref, row, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	author, wc := writer(c, &cl, ref)
	if wc != 0 {
		return wc
	}
	if c.dry_run {
		kit.jset_int(c.out, "number", 0)
		return 0
	}
	r := create_issue(&cl, wire.str(row, "id"), author, kit.cli_str(c, "title"), kit.cli_str(c, "body"))
	if !wire.ok(r) {
		return fail(c, r, "issue create")
	}
	x, _ := wire.first(r.value)
	kit.jset_int(c.out, "number", wire.num(x, "number"))
	kit.jset_str(c.out, "repo", fmt.tprintf("%s/%s", ref.owner, ref.name))
	return 0
}

find_issue :: proc(c: ^kit.Call, cl: ^Client) -> (ref: Repo_Ref, repo, issue: json.Value, code: int) {
	ref, repo, code = repo_arg(c, cl)
	if code != 0 {
		return
	}
	ok: bool
	issue, ok = get_issue(cl, wire.str(repo, "id"), number_arg(c))
	if !ok {
		code = kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s/%s has no #%d", ref.owner, ref.name, number_arg(c))
	}
	return
}

comments_json :: proc(cl: ^Client, issue_id: string) -> ^kit.Json {
	a := kit.jarr()
	for x in wire.arr(list_comments(cl, issue_id).value) {
		o := kit.jobj()
		kit.jset_str(o, "author", wire.str(x, "author_handle"))
		kit.jset_str(o, "created_at", wire.str(x, "created_at"))
		if p := wire.str(x, "path"); p != "" {
			kit.jset_str(o, "path", p)
			kit.jset_int(o, "line", wire.num(x, "line"))
		}
		kit.jset_str(o, "body", wire.str(x, "body"))
		kit.jpush(a, o)
	}
	return a
}

cmd_issue_show :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	_, _, x, rc := find_issue(c, &cl)
	if rc != 0 {
		return rc
	}
	c.out = issue_summary(x)
	kit.jset_str(c.out, "body", wire.str(x, "body"))
	kit.jset(c.out, "labels", kj(wire.get(x, "labels")))
	kit.jset(c.out, "comments", comments_json(&cl, wire.str(x, "id")))
	return 0
}

cmd_issue_comment :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	ref, repo, x, rc := find_issue(c, &cl)
	if rc != 0 {
		return rc
	}
	author, wc := writer(c, &cl, ref)
	if wc != 0 {
		return wc
	}
	if c.dry_run {
		kit.jset_str(c.out, "id", "")
		return 0
	}
	r := add_comment(&cl, wire.str(repo, "id"), wire.str(x, "id"), author, kit.cli_str(c, "body"))
	if !wire.ok(r) {
		return fail(c, r, "comment")
	}
	row, _ := wire.first(r.value)
	kit.jset_str(c.out, "id", wire.str(row, "id"))
	return 0
}

set_state :: proc(c: ^kit.Call, state: string) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	_, _, x, rc := find_issue(c, &cl)
	if rc != 0 {
		return rc
	}
	kit.jset_int(c.out, "number", wire.num(x, "number"))
	kit.jset_str(c.out, "state", state)
	if c.dry_run || wire.str(x, "state") == state {
		return 0
	}
	r := set_issue_state(&cl, wire.str(x, "id"), state)
	if !wire.ok(r) {
		return fail(c, r, "issue state")
	}
	if len(wire.arr(r.value)) == 0 {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "only its author or a writer can change it")
	}
	return 0
}

cmd_issue_close :: proc(c: ^kit.Call) -> int {return set_state(c, "closed")}
cmd_issue_reopen :: proc(c: ^kit.Call) -> int {return set_state(c, "open")}

// ---------------------------------------------------------------------------
// Pull requests
// ---------------------------------------------------------------------------

cmd_pr_create :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	ref, repo, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	author, wc := writer(c, &cl, ref)
	if wc != 0 {
		return wc
	}
	base := kit.cli_str(c, "base")
	if base == "" {
		base = wire.str(repo, "default_branch")
	}
	head := kit.cli_str(c, "head")
	kit.jset_str(c.out, "head", head)
	kit.jset_str(c.out, "base", base)
	if c.dry_run {
		kit.jset_int(c.out, "number", 0)
		return 0
	}
	r := open_pull(&cl, wire.str(repo, "id"), author, kit.cli_str(c, "title"), kit.cli_str(c, "body"), head, base)
	if !wire.ok(r) {
		return fail(c, r, "pr create")
	}
	kit.jset_int(c.out, "number", wire.num(r.value, "number"))
	kit.jset_str(c.out, "head_sha", wire.str(r.value, "head_sha"))
	return 0
}

cmd_pr_show :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, _, x, rc := find_issue(c, &cl)
	if rc != 0 {
		return rc
	}
	if !wire.flag(x, "is_pull") {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "#%d is an issue, not a pull request", number_arg(c))
	}
	c.out = issue_summary(x)
	kit.jset_str(c.out, "head", wire.str(x, "head_ref"))
	kit.jset_str(c.out, "base", wire.str(x, "base_ref"))
	if !wire.is_null(x, "merged_at") {
		kit.jset_str(c.out, "merged_sha", wire.str(x, "merged_sha"))
		kit.jset_str(c.out, "merge_method", wire.str(x, "merge_method"))
		kit.jset_bool(c.out, "mergeable", false)
	} else {
		cmp := get_compare(&cl, ref, wire.str(x, "base_ref"), wire.str(x, "head_ref"))
		kit.jset_int(c.out, "ahead", wire.num(cmp.value, "ahead"))
		kit.jset_int(c.out, "behind", wire.num(cmp.value, "behind"))
		kit.jset_bool(c.out, "mergeable", wire.flag(cmp.value, "mergeable") && wire.num(cmp.value, "ahead") > 0)
		kit.jset_bool(c.out, "fast_forward", wire.flag(cmp.value, "fast_forward"))
		kit.jset(c.out, "conflicts", kj(wire.get(cmp.value, "conflicts")))
		kit.jset(c.out, "files", pick_all(wire.get(cmp.value, "files"), "path", "additions", "deletions"))
	}
	reviews := kit.jarr()
	for rv in wire.arr(list_reviews(&cl, wire.str(x, "id")).value) {
		kit.jpush(reviews, pick(rv, "state", "body", "created_at"))
	}
	kit.jset(c.out, "reviews", reviews)
	kit.jset(c.out, "conversation", comments_json(&cl, wire.str(x, "id")))
	return 0
}

cmd_pr_diff :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	ref, _, x, rc := find_issue(c, &cl)
	if rc != 0 {
		return rc
	}
	diff := ""
	if !wire.is_null(x, "merged_at") {
		r := get_commit(&cl, ref, wire.str(x, "merged_sha"))
		diff = wire.str(r.value, "diff")
	} else {
		r := get_compare(&cl, ref, wire.str(x, "base_ref"), wire.str(x, "head_ref"))
		if !wire.ok(r) {
			return fail(c, r, "pr diff")
		}
		diff = wire.str(r.value, "diff")
	}
	if !c.json {
		fmt.print(diff)
		c.out = kit.jobj()
		return 0
	}
	kit.jset_str(c.out, "diff", diff)
	return 0
}

cmd_pr_review :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	ref, repo, x, rc := find_issue(c, &cl)
	if rc != 0 {
		return rc
	}
	author, wc := writer(c, &cl, ref)
	if wc != 0 {
		return wc
	}
	state := kit.cli_str(c, "state")
	db_state := "commented"
	switch state {
	case "approve":
		db_state = "approved"
	case "request-changes":
		db_state = "changes_requested"
	}
	kit.jset_str(c.out, "state", db_state)
	if c.dry_run {
		kit.jset_str(c.out, "review", "")
		return 0
	}
	r := add_review(&cl, wire.str(repo, "id"), wire.str(x, "id"), author, db_state, kit.cli_str(c, "body"), wire.str(x, "head_sha"))
	if !wire.ok(r) {
		return fail(c, r, "review")
	}
	rv, _ := wire.first(r.value)
	kit.jset_str(c.out, "review", wire.str(rv, "id"))
	if p := kit.cli_str(c, "path"); p != "" {
		body := kit.cli_str(c, "body")
		if body == "" {
			return kit.cli_fail(c, kit.EXIT_USAGE, "a line comment needs --body")
		}
		cr := add_comment(&cl, wire.str(repo, "id"), wire.str(x, "id"), author, body, p, kit.cli_int(c, "line", 1), wire.str(rv, "id"))
		if !wire.ok(cr) {
			return fail(c, cr, "line comment")
		}
	}
	return 0
}

cmd_pr_merge :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	ref, ok := parse_repo_ref(kit.cli_str(c, "repo"))
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a repository is <identity>/<name>")
	}
	kit.jset_int(c.out, "number", number_arg(c))
	kit.jset_str(c.out, "method", kit.cli_str(c, "method"))
	if c.dry_run {
		kit.jset_str(c.out, "sha", "")
		return 0
	}
	r := merge_pull(&cl, ref, number_arg(c), kit.cli_str(c, "method"))
	if !wire.ok(r) {
		if r.status == 409 {
			return kit.cli_fail(c, kit.EXIT_FAILED, r.err)
		}
		return fail(c, r, "merge")
	}
	kit.jset_str(c.out, "sha", wire.str(r.value, "sha"))
	kit.jset_str(c.out, "base", wire.str(r.value, "base"))
	return 0
}

// ---------------------------------------------------------------------------
// Grants and tokens
// ---------------------------------------------------------------------------

cmd_collab_list :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	_, repo, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	r := list_collaborators(&cl, wire.str(repo, "id"))
	if !wire.ok(r) {
		return fail(c, r, "collaborators")
	}
	kit.jset(c.out, "collaborators", pick_all(r.value, "grantee_handle", "grantee_name", "role", "created_at"))
	return 0
}

cmd_collab_add :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	_, repo, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	kit.jset_str(c.out, "role", kit.cli_str(c, "role"))
	if c.dry_run {
		kit.jset_str(c.out, "grant", "")
		return 0
	}
	r := grant(&cl, wire.str(repo, "id"), kit.cli_str(c, "handle"), kit.cli_str(c, "role"))
	if !wire.ok(r) {
		return fail(c, r, "grant")
	}
	kit.jset_str(c.out, "grant", wire.str(r.value))
	kit.jset_str(c.out, "grantee", kit.cli_str(c, "handle"))
	return 0
}

cmd_collab_remove :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	_, repo, rc := repo_arg(c, &cl)
	if rc != 0 {
		return rc
	}
	if c.dry_run {
		kit.jset_bool(c.out, "revoked", true)
		return 0
	}
	r := revoke(&cl, wire.str(repo, "id"), kit.cli_str(c, "handle"))
	if !wire.ok(r) {
		return fail(c, r, "revoke")
	}
	kit.jset_bool(c.out, "revoked", wire.str(r.value) == "true")
	return 0
}

cmd_token_list :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	r := list_tokens(&cl)
	if !wire.ok(r) {
		return fail(c, r, "tokens")
	}
	handles := make(map[string]string)
	for row in wire.arr(my_identities(&cl).value) {
		handles[wire.str(row, "id")] = wire.str(row, "handle")
	}
	a := kit.jarr()
	for t in wire.arr(r.value) {
		o := kit.jobj()
		kit.jset_str(o, "id", wire.str(t, "id"))
		kit.jset_str(o, "identity", handles[wire.str(t, "identity_id")])
		kit.jset_str(o, "name", wire.str(t, "name"))
		kit.jset_str(o, "prefix", wire.str(t, "prefix"))
		kit.jset_str(o, "scope", wire.str(t, "scope"))
		kit.jset(o, "last_used_at", kj(wire.get(t, "last_used_at")))
		kit.jset_bool(o, "revoked", !wire.is_null(t, "revoked_at"))
		kit.jpush(a, o)
	}
	kit.jset(c.out, "tokens", a)
	return 0
}

cmd_token_create :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	if cl.kind == "token" {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "a token cannot mint tokens; sign in with `forge login`")
	}
	ids := wire.arr(my_identities(&cl).value)
	target: json.Value
	if c.identity != "" {
		ok: bool
		target, ok = identity_by_handle(&cl, c.identity)
		if !ok {
			return kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "%s is not one of your identities", c.identity)
		}
	} else if len(ids) == 1 {
		target = ids[0]
	} else {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a token belongs to one identity: say which with --identity")
	}
	kit.jset_str(c.out, "identity", wire.str(target, "handle"))
	kit.jset_str(c.out, "scope", kit.cli_str(c, "scope"))
	if c.dry_run {
		kit.jset_str(c.out, "id", "")
		kit.jset_str(c.out, "token", "")
		return 0
	}
	r := create_token(&cl, wire.str(target, "id"), kit.cli_str(c, "name"), kit.cli_str(c, "scope"), kit.cli_int(c, "days", 0))
	if !wire.ok(r) {
		return fail(c, r, "token create")
	}
	kit.jset_str(c.out, "id", wire.str(r.value, "id"))
	kit.jset_str(c.out, "token", wire.str(r.value, "token"))
	kit.jset(c.out, "expires_at", kj(wire.get(r.value, "expires_at")))
	kit.cli_note(c, "this is the only time the token is shown")
	return 0
}

cmd_token_revoke :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c, true)
	if code != 0 {
		return code
	}
	kit.jset_str(c.out, "revoked", kit.cli_str(c, "id"))
	if c.dry_run {
		return 0
	}
	r := revoke_token(&cl, kit.cli_str(c, "id"))
	if !wire.ok(r) {
		return fail(c, r, "token revoke")
	}
	if wire.str(r.value) != "true" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no such token among yours")
	}
	return 0
}

cmd_activity :: proc(c: ^kit.Call) -> int {
	cl, code := open_client(c)
	if code != 0 {
		return code
	}
	repo_id := ""
	if kit.cli_str(c, "repo") != "" {
		_, repo, rc := repo_arg(c, &cl)
		if rc != 0 {
			return rc
		}
		repo_id = wire.str(repo, "id")
	}
	r := list_events(&cl, repo_id, kit.cli_int(c, "limit", 30))
	if !wire.ok(r) {
		return fail(c, r, "activity")
	}
	a := kit.jarr()
	for e in wire.arr(r.value) {
		o := kit.jobj()
		kit.jset_str(o, "when", wire.str(e, "created_at"))
		kit.jset_str(o, "actor", wire.str(e, "actor_handle"))
		kit.jset_str(o, "repo", fmt.tprintf("%s/%s", wire.str(e, "owner_handle"), wire.str(e, "repo_name")))
		kit.jset_str(o, "kind", wire.str(e, "kind"))
		kit.jset_str(o, "what", event_text(e))
		kit.jpush(a, o)
	}
	kit.jset(c.out, "events", a)
	return 0
}

// event_text is one line describing an activity event, shared with the window.
event_text :: proc(e: json.Value) -> string {
	pl := wire.get(e, "payload")
	switch wire.str(e, "kind") {
	case "push":
		n := wire.num(pl, "commits")
		ref := strings.trim_prefix(wire.str(pl, "ref"), "refs/heads/")
		if wire.str(pl, "after") == strings.repeat("0", 40, context.temp_allocator) {
			return fmt.tprintf("deleted %s", ref)
		}
		return fmt.tprintf("pushed %d commit%s to %s", n, "" if n == 1 else "s", ref)
	case "repo.created":
		return fmt.tprintf("created the %s repository", wire.str(pl, "visibility"))
	case "issue.opened":
		return fmt.tprintf("opened issue #%d %s", wire.num(pl, "number"), wire.str(pl, "title"))
	case "issue.closed":
		return fmt.tprintf("closed issue #%d", wire.num(pl, "number"))
	case "issue.reopened":
		return fmt.tprintf("reopened issue #%d", wire.num(pl, "number"))
	case "pull.opened":
		return fmt.tprintf("opened pull request #%d %s", wire.num(pl, "number"), wire.str(pl, "title"))
	case "pull.closed":
		return fmt.tprintf("closed pull request #%d", wire.num(pl, "number"))
	case "pull.merged":
		return fmt.tprintf("merged pull request #%d (%s)", wire.num(pl, "number"), wire.str(pl, "method"))
	case "comment.created":
		return fmt.tprintf("commented on #%d", wire.num(pl, "number"))
	case "review.approved":
		return fmt.tprintf("approved #%d", wire.num(pl, "number"))
	case "review.changes_requested":
		return fmt.tprintf("requested changes on #%d", wire.num(pl, "number"))
	case "review.commented":
		return fmt.tprintf("reviewed #%d", wire.num(pl, "number"))
	case "collaborator.added":
		return fmt.tprintf("granted %s access", wire.str(pl, "role"))
	case "collaborator.revoked":
		return "revoked a grant"
	}
	return wire.str(e, "kind")
}
