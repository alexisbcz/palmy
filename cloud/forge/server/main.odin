// palmforge: the Palmframe forge server.
//
// Git smart HTTP (protocol v0/v1 and v2 for fetch), git LFS (basic transfer)
// and a small JSON API for the parts of a forge that need the repository on
// disk: trees, blobs, history, diffs, comparisons and merges. Everything
// else — repositories, issues, pull requests, reviews, tokens, grants,
// activity — is rows in Supabase behind row-level security, read and written
// by clients directly through PostgREST.
//
// The one external dependency is git itself: pack negotiation and pack
// generation are delegated to `git upload-pack` and `git receive-pack` in
// --stateless-rpc mode, the same split Gitea, Forgejo and cgit's
// http-backend make. Routing, authentication, authorization, ref policy and
// the record of what was pushed are this program's.
//
//	forge-server [--env FILE] [--selftest]
//
// Configuration is environment variables (or KEY=VALUE lines in --env FILE,
// the format `supabase status -o env` prints):
//
//	FORGE_LISTEN         127.0.0.1:58580
//	FORGE_ROOT           ~/.local/share/palm/forge/repos
//	FORGE_PUBLIC_URL     http://<FORGE_LISTEN>   (used in LFS hrefs)
//	FORGE_MAIL_DOMAIN    palm.test               (merge commit e-mail)
//	API_URL              the Supabase gateway, e.g. http://127.0.0.1:58521
//	ANON_KEY             the public key (PUBLISHABLE_KEY also accepted)
//	JWT_SECRET           the project's JWT secret, for minting token sessions
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import wire "forge:wire"

Config :: struct {
	listen:      string,
	root:        string,
	public_url:  string,
	mail_domain: string,
	supa:        wire.Supa,
	jwt_secret:  string,
}

cfg: Config

env_or :: proc(vars: map[string]string, key, def: string) -> string {
	if v, ok := vars[key]; ok && v != "" {
		return v
	}
	if v := os.get_env(key, context.allocator); v != "" {
		return v
	}
	return def
}

load_env_file :: proc(path: string, into: ^map[string]string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return false
	}
	for line in strings.split_lines(string(data)) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		k, _, v := strings.partition(l, "=")
		v = strings.trim(v, "\"'")
		into[strings.trim_space(k)] = v
	}
	return true
}

load_config :: proc(args: []string) -> (ok: bool) {
	vars := make(map[string]string)
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--env" && i + 1 < len(args) {
			if !load_env_file(args[i + 1], &vars) {
				fmt.eprintfln("forge-server: cannot read %s", args[i + 1])
				return false
			}
			i += 1
		}
	}
	home := os.get_env("HOME", context.allocator)
	cfg.listen = env_or(vars, "FORGE_LISTEN", "127.0.0.1:58580")
	cfg.root = env_or(vars, "FORGE_ROOT", fmt.aprintf("%s/.local/share/palm/forge/repos", home))
	cfg.public_url = env_or(vars, "FORGE_PUBLIC_URL", fmt.aprintf("http://%s", cfg.listen))
	cfg.mail_domain = env_or(vars, "FORGE_MAIL_DOMAIN", "palm.test")
	cfg.supa.url = env_or(vars, "API_URL", env_or(vars, "SUPABASE_URL", ""))
	cfg.supa.anon = env_or(vars, "ANON_KEY", env_or(vars, "PUBLISHABLE_KEY", env_or(vars, "SUPABASE_ANON_KEY", "")))
	cfg.jwt_secret = env_or(vars, "JWT_SECRET", env_or(vars, "SUPABASE_JWT_SECRET", ""))
	if cfg.supa.url == "" || cfg.supa.anon == "" || cfg.jwt_secret == "" {
		fmt.eprintln("forge-server: API_URL, ANON_KEY and JWT_SECRET are required (try --env with `supabase status -o env`)")
		return false
	}
	return true
}

main :: proc() {
	args := os.args[1:]
	for a in args {
		if a == "--selftest" {
			os.exit(selftest())
		}
		if a == "--help" || a == "-h" {
			fmt.println("forge-server [--env FILE] [--selftest]   (see the header of cloud/forge/server/main.odin)")
			return
		}
	}
	if !load_config(args) {
		os.exit(2)
	}
	if err := os.make_directory_all(cfg.root); err != nil && !os.exists(cfg.root) {
		fmt.eprintfln("forge-server: cannot create %s", cfg.root)
		os.exit(1)
	}
	ep, ok := net.parse_endpoint(cfg.listen)
	if !ok {
		fmt.eprintfln("forge-server: bad FORGE_LISTEN %q", cfg.listen)
		os.exit(2)
	}
	sock, err := net.listen_tcp(ep)
	if err != nil {
		fmt.eprintfln("forge-server: cannot listen on %s: %v", cfg.listen, err)
		os.exit(1)
	}
	fmt.eprintfln("forge-server: listening on http://%s, repositories in %s, Supabase at %s", cfg.listen, cfg.root, cfg.supa.url)
	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			continue
		}
		thread.create_and_start_with_poly_data(client, serve, self_cleanup = true)
	}
}

serve :: proc(sock: net.TCP_Socket) {
	defer net.close(sock)
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	start := time.tick_now()
	req, status := read_request(sock)
	if status == 0 {
		return
	}
	if status != 200 {
		respond_error(&req, status, "bad request")
		return
	}
	code := route(&req)
	fmt.eprintfln("%s %s%s%s -> %d (%.1fms)", req.method, req.path, "?" if req.query != "" else "", req.query, code,
		time.duration_milliseconds(time.tick_since(start)))
}

// route dispatches and returns the status it answered with, for the log.
route :: proc(req: ^Request) -> int {
	path := strings.trim_prefix(req.path, "/")
	if path == "" || path == "health" {
		respond_text(req, 200, "palmforge\n")
		return 200
	}
	segs := strings.split(path, "/")
	for s in segs {
		if s == ".." || s == "." {
			respond_error(req, 400, "bad path")
			return 400
		}
	}

	if segs[0] == "api" {
		return api_route(req, segs[1:])
	}

	// /<handle>/<repo>[.git]/<git or lfs endpoint>
	if len(segs) < 3 {
		respond_error(req, 404, "not found")
		return 404
	}
	handle := segs[0]
	name := strings.trim_suffix(segs[1], ".git")
	rest := strings.join(segs[2:], "/")

	switch {
	case rest == "info/refs" && req.method == "GET":
		return git_info_refs(req, handle, name)
	case (rest == "git-upload-pack" || rest == "git-receive-pack") && req.method == "POST":
		return git_rpc(req, handle, name, rest[4:])
	case rest == "info/lfs/objects/batch" && req.method == "POST":
		return lfs_batch(req, handle, name)
	case strings.has_prefix(rest, "info/lfs/objects/") && (req.method == "PUT" || req.method == "GET"):
		return lfs_object(req, handle, name, strings.trim_prefix(rest, "info/lfs/objects/"))
	case rest == "HEAD" || strings.has_prefix(rest, "objects/"):
		respond_text(req, 403, "the dumb HTTP protocol is not served; use a git newer than 1.6.6\n")
		return 403
	}
	respond_error(req, 404, "not found")
	return 404
}

// ---------------------------------------------------------------------------
// Repositories: resolution through the database, storage on disk
// ---------------------------------------------------------------------------

Repo :: struct {
	id:             string,
	identity_id:    string,
	handle:         string,
	name:           string,
	visibility:     string,
	default_branch: string,
	role:           string, // read | write | admin
	acting:         string, // identity this session acts as on it
	archived:       bool,
	path:           string,
}

can_write :: proc(r: Repo) -> bool {
	return r.role == "write" || r.role == "admin"
}

// repo_path keeps repositories under their id, not their name, so a rename
// or a transfer between identities never moves anything on disk:
// <root>/<first two hex digits of the id>/<id>.git
repo_path :: proc(id: string) -> string {
	return fmt.tprintf("%s/%s/%s.git", cfg.root, id[:2], id)
}

Resolve_Status :: enum {
	Found,
	Missing, // no such repository, or not visible to this caller
	Bad_Credentials,
	Unavailable,
}

resolve :: proc(c: ^Caller, handle, name: string) -> (repo: Repo, st: Resolve_Status) {
	r := wire.rpc(cfg.supa, c.bearer, "forge_resolve", fmt.tprintf(`{{"owner_handle":%s,"repo_name":%s}}`, wire.q(handle), wire.q(name)))
	if r.err != "" && r.status == 0 {
		return {}, .Unavailable
	}
	if r.status == 401 {
		return {}, .Bad_Credentials
	}
	row, found := wire.first(r.value)
	if !wire.ok(r) || !found {
		return {}, .Missing
	}
	repo = Repo {
		id             = wire.str(row, "repo_id"),
		identity_id    = wire.str(row, "identity_id"),
		handle         = wire.str(row, "handle"),
		name           = wire.str(row, "name"),
		visibility     = wire.str(row, "visibility"),
		default_branch = wire.str(row, "default_branch"),
		role           = wire.str(row, "role"),
		acting         = wire.str(row, "acting_identity"),
		archived       = wire.flag(row, "archived"),
	}
	repo.path = repo_path(repo.id)
	return repo, .Found
}

// open_repo authenticates and resolves, answering the error itself. `need`
// is "read" or "write".
open_repo :: proc(req: ^Request, handle, name, need: string) -> (c: Caller, repo: Repo, code: int) {
	bad: bool
	c, bad = authenticate(req)
	if bad {
		respond_error(req, 401, "bad credentials", challenge())
		return c, repo, 401
	}
	st: Resolve_Status
	repo, st = resolve(&c, handle, name)
	switch st {
	case .Unavailable:
		respond_error(req, 502, "the database is not reachable")
		return c, repo, 502
	case .Bad_Credentials:
		respond_error(req, 401, "bad credentials", challenge())
		return c, repo, 401
	case .Missing:
		// Anonymous callers are asked to authenticate, so `git clone` of a
		// private repository prompts for a token instead of claiming it does
		// not exist. Authenticated callers get 404 whether it is missing or
		// merely not theirs: existence is not disclosed.
		if c.kind == .Anonymous {
			respond_error(req, 401, "authentication required", challenge())
			return c, repo, 401
		}
		respond_error(req, 404, "repository not found")
		return c, repo, 404
	case .Found:
	}
	if need == "write" && !can_write(repo) {
		if c.kind == .Anonymous {
			respond_error(req, 401, "authentication required", challenge())
			return c, repo, 401
		}
		why := "read-only token" if c.scope == "read" else "you have read access only"
		if repo.archived {
			why = "the repository is archived"
		}
		respond_error(req, 403, why)
		return c, repo, 403
	}
	if !ensure_repo(repo) {
		respond_error(req, 500, "cannot initialise the repository on disk")
		return c, repo, 500
	}
	return c, repo, 0
}
