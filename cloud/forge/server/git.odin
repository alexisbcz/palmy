package main

// Git smart HTTP.
//
//	GET  /<handle>/<repo>.git/info/refs?service=git-upload-pack     read
//	POST /<handle>/<repo>.git/git-upload-pack                       read
//	GET  /<handle>/<repo>.git/info/refs?service=git-receive-pack    write
//	POST /<handle>/<repo>.git/git-receive-pack                      write
//
// The ref advertisement and the pack exchange are git's own, run as
// `git upload-pack|receive-pack --stateless-rpc`, with protocol v2 passed
// through in GIT_PROTOCOL for fetches. Before receive-pack runs, the server
// reads the push's command list (old, new, ref) out of the request and
// applies its ref policy; after it runs, it checks which refs actually moved
// and records them with forge_record_push under the pusher's own session,
// so the database re-checks write access rather than taking the server's word.
// No hook scripts are installed in the repositories.

import "core:fmt"
import "core:os"
import "core:strings"
import wire "forge:wire"

ZERO_SHA :: "0000000000000000000000000000000000000000"

pkt_line :: proc(sb: ^strings.Builder, s: string) {
	fmt.sbprintf(sb, "%04x%s", len(s) + 4, s)
}

// ---------------------------------------------------------------------------
// Running git
// ---------------------------------------------------------------------------

git_env :: proc(extra: []string = nil) -> []string {
	base, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(base) + len(extra) + 2)
	for e in base {
		// The server's own git configuration and prompts must not leak in.
		if strings.has_prefix(e, "GIT_") {
			continue
		}
		append(&env, e)
	}
	append(&env, "GIT_TERMINAL_PROMPT=0")
	append(&env, "GIT_CONFIG_NOSYSTEM=1")
	for e in extra {
		append(&env, e)
	}
	return env[:]
}

// temp_input writes `data` to an unlinked temporary file positioned at 0,
// to hand a child process as stdin without a writer thread.
temp_input :: proc(data: []u8) -> (^os.File, bool) {
	f, err := os.create_temp_file("", "palmforge-*")
	if err != nil {
		return nil, false
	}
	os.remove(os.name(f))
	off := 0
	for off < len(data) {
		n, werr := os.write(f, data[off:])
		if werr != nil || n <= 0 {
			os.close(f)
			return nil, false
		}
		off += n
	}
	os.seek(f, 0, .Start)
	return f, true
}

Git_Result :: struct {
	out:  []u8,
	err:  string,
	code: int,
	ok:   bool,
}

// git runs `git -C dir args...` and captures its output.
git :: proc(dir: string, args: []string, stdin: []u8 = nil, env: []string = nil) -> Git_Result {
	cmd := make([dynamic]string, 0, len(args) + 3)
	append(&cmd, "git", "-C", dir)
	append(&cmd, ..args)
	desc := os.Process_Desc {
		command = cmd[:],
		env     = git_env(env),
	}
	in_file: ^os.File
	if stdin != nil {
		f, ok := temp_input(stdin)
		if !ok {
			return {err = "cannot buffer input"}
		}
		in_file = f
		desc.stdin = f
	}
	defer if in_file != nil {
		os.close(in_file)
	}
	state, out, serr, err := os.process_exec(desc, context.temp_allocator)
	if err != nil {
		return {err = "cannot run git"}
	}
	return {out = out, err = string(serr), code = state.exit_code, ok = state.exited && state.exit_code == 0}
}

git_text :: proc(dir: string, args: ..string) -> (string, bool) {
	r := git(dir, args)
	return strings.trim_space(string(r.out)), r.ok
}

ensure_repo :: proc(repo: Repo) -> bool {
	if os.exists(fmt.tprintf("%s/HEAD", repo.path)) {
		return true
	}
	parent := repo.path[:strings.last_index_byte(repo.path, '/')]
	if err := os.make_directory_all(parent); err != nil && !os.exists(parent) {
		return false
	}
	branch := repo.default_branch if repo.default_branch != "" else "main"
	r := git(cfg.root, {"init", "--quiet", "--bare", fmt.tprintf("--initial-branch=%s", branch), repo.path})
	if !r.ok {
		fmt.eprintfln("git init %s: %s", repo.path, r.err)
		return false
	}
	// Partial clone, and the forge's identity in the reflog.
	git(repo.path, {"config", "uploadpack.allowFilter", "true"})
	git(repo.path, {"config", "uploadpack.allowAnySHA1InWant", "true"})
	git(repo.path, {"config", "receive.fsckObjects", "true"})
	git(repo.path, {"config", "core.logAllRefUpdates", "true"})
	git(repo.path, {"config", "palmforge.repo", repo.id})
	return true
}

rev_parse :: proc(dir, rev: string) -> string {
	out, ok := git_text(dir, "rev-parse", "--verify", "--quiet", rev)
	return out if ok else ""
}

// ---------------------------------------------------------------------------
// info/refs
// ---------------------------------------------------------------------------

protocol_header :: proc(req: ^Request) -> string {
	p := wire.header_get(req.headers, "git-protocol")
	// Only what git itself sends: "version=2", optionally ":"-joined params.
	for ch in p {
		if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '=' || ch == ':' || ch == '-' || ch == '_' || ch == '.') {
			return ""
		}
	}
	return p
}

git_info_refs :: proc(req: ^Request, handle, name: string) -> int {
	service := query_param(req.query, "service")
	if service != "git-upload-pack" && service != "git-receive-pack" {
		respond_text(req, 403, "only the smart HTTP protocol is served\n")
		return 403
	}
	need := "write" if service == "git-receive-pack" else "read"
	_, repo, code := open_repo(req, handle, name, need)
	if code != 0 {
		return code
	}
	proto := protocol_header(req)
	env: []string
	if proto != "" {
		env = []string{fmt.tprintf("GIT_PROTOCOL=%s", proto)}
	}
	r := git(repo.path, {service[4:], "--stateless-rpc", "--advertise-refs", "."}, nil, env)
	if !r.ok {
		respond_error(req, 500, "git failed")
		return 500
	}
	sb := strings.builder_make()
	// Protocol v2 has no service line; v0 and v1 begin with one and a flush.
	if !(strings.contains(proto, "version=2") && service == "git-upload-pack") {
		pkt_line(&sb, fmt.tprintf("# service=%s\n", service))
		strings.write_string(&sb, "0000")
	}
	strings.write_bytes(&sb, r.out)
	no_cache := []wire.Header{{"Cache-Control", "no-cache, max-age=0, must-revalidate"}, {"Expires", "Fri, 01 Jan 1980 00:00:00 GMT"}, {"Pragma", "no-cache"}}
	respond(req, 200, fmt.tprintf("application/x-%s-advertisement", service), transmute([]u8)strings.to_string(sb), no_cache)
	return 200
}

// ---------------------------------------------------------------------------
// The pack exchange
// ---------------------------------------------------------------------------

Command :: struct {
	old, new, ref: string,
}

// parse_commands reads receive-pack's command list: pkt-lines of
// "<old> <new> <ref>", the first carrying capabilities after a NUL, ending in
// a flush. Shallow lines may precede it.
parse_commands :: proc(body: []u8) -> (cmds: []Command, ok: bool) {
	out := make([dynamic]Command)
	i := 0
	for i + 4 <= len(body) {
		n := 0
		for k in 0 ..< 4 {
			c := body[i + k]
			d: int
			switch c {
			case '0' ..= '9':
				d = int(c - '0')
			case 'a' ..= 'f':
				d = int(c - 'a' + 10)
			case:
				return nil, false
			}
			n = n * 16 + d
		}
		if n == 0 {
			return out[:], true
		}
		if n < 4 || i + n > len(body) {
			return nil, false
		}
		line := string(body[i + 4:i + n])
		i += n
		if nul := strings.index_byte(line, 0); nul >= 0 {
			line = line[:nul]
		}
		line = strings.trim_right(line, "\n")
		if strings.has_prefix(line, "shallow ") || strings.has_prefix(line, "push-cert") {
			continue
		}
		parts := strings.split(line, " ")
		if len(parts) != 3 || len(parts[0]) != 40 || len(parts[1]) != 40 {
			return nil, false
		}
		append(&out, Command{parts[0], parts[1], parts[2]})
	}
	return out[:], false
}

// ref_policy is the pre-receive check. Content checks (file size, signed
// commits) would need a quarantine hook and are not built; see forge.md.
ref_policy :: proc(repo: Repo, cmds: []Command) -> string {
	for c in cmds {
		if !strings.has_prefix(c.ref, "refs/heads/") && !strings.has_prefix(c.ref, "refs/tags/") {
			return fmt.tprintf("%s: only branches and tags may be pushed", c.ref)
		}
		if strings.contains(c.ref, "..") || strings.has_suffix(c.ref, "/") {
			return fmt.tprintf("%s: not a valid ref name", c.ref)
		}
		if c.new == ZERO_SHA && c.ref == fmt.tprintf("refs/heads/%s", repo.default_branch) {
			return fmt.tprintf("%s is the default branch and cannot be deleted", c.ref)
		}
	}
	return ""
}

git_rpc :: proc(req: ^Request, handle, name, service: string) -> int {
	need := "write" if service == "receive-pack" else "read"
	c, repo, code := open_repo(req, handle, name, need)
	if code != 0 {
		return code
	}
	want_type := fmt.tprintf("application/x-git-%s-request", service)
	if wire.header_get(req.headers, "content-type") != want_type {
		respond_error(req, 415, "wrong content type")
		return 415
	}

	cmds: []Command
	if service == "receive-pack" {
		ok: bool
		cmds, ok = parse_commands(req.body)
		if !ok {
			respond_error(req, 400, "cannot read the push commands")
			return 400
		}
		if why := ref_policy(repo, cmds); why != "" {
			respond_text(req, 403, fmt.tprintf("palmforge: %s\n", why))
			return 403
		}
	}

	proto := protocol_header(req)
	env: []string
	if proto != "" {
		env = []string{fmt.tprintf("GIT_PROTOCOL=%s", proto)}
	}
	in_file, iok := temp_input(req.body)
	if !iok {
		respond_error(req, 500, "cannot buffer the request")
		return 500
	}
	defer os.close(in_file)
	rd, wr, perr := os.pipe()
	if perr != nil {
		respond_error(req, 500, "cannot create a pipe")
		return 500
	}
	defer os.close(rd)
	p, serr := os.process_start(
		os.Process_Desc {
			command = []string{"git", service, "--stateless-rpc", repo.path},
			env = git_env(env),
			stdin = in_file,
			stdout = wr,
			stderr = os.stderr,
		},
	)
	os.close(wr)
	if serr != nil {
		respond_error(req, 500, "cannot run git")
		return 500
	}
	// Streamed until the connection closes: packs can be large.
	write_head(req.sock, 200, fmt.tprintf("application/x-git-%s-result", service), -1, {{"Cache-Control", "no-cache"}})
	buf: [64 * 1024]u8
	client_gone := false
	for {
		n, rerr := os.read(rd, buf[:])
		if n > 0 && !client_gone {
			if !wire.send_all(req.sock, buf[:n]) {
				client_gone = true
			}
		}
		if rerr != nil || n <= 0 {
			break
		}
	}
	state, _ := os.process_wait(p)
	if service == "receive-pack" && state.exited {
		record_push(&c, repo, cmds)
	}
	return 200
}

// ---------------------------------------------------------------------------
// After a push
// ---------------------------------------------------------------------------

LOG_FORMAT :: "--format=%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e"

// commits_json lists what a ref update brought in, newest first, at most 100.
commits_json :: proc(dir: string, cmd: Command) -> string {
	args := make([dynamic]string)
	append(&args, "log", "--max-count=100", LOG_FORMAT, cmd.new)
	if cmd.old != ZERO_SHA {
		append(&args, fmt.tprintf("^%s", cmd.old))
	} else {
		// A new ref: what no other ref already had.
		append(&args, "--not", fmt.tprintf("--exclude=%s", cmd.ref), "--all")
	}
	r := git(dir, args[:])
	return log_to_json(string(r.out))
}

log_to_json :: proc(out: string) -> string {
	sb := strings.builder_make()
	strings.write_byte(&sb, '[')
	n := 0
	for rec in strings.split(out, "\x1e") {
		rec := strings.trim_left(rec, "\n")
		if rec == "" {
			continue
		}
		f := strings.split(rec, "\x1f")
		if len(f) < 5 {
			continue
		}
		if n > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, `{{"sha":%s,"author_name":%s,"author_email":%s,"authored_at":%s,"summary":%s}}`,
			wire.q(f[0]), wire.q(f[1]), wire.q(f[2]), wire.q(f[3]), wire.q(f[4]))
		n += 1
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

record_push :: proc(c: ^Caller, repo: Repo, cmds: []Command) {
	created_branch := ""
	for cmd in cmds {
		actual := rev_parse(repo.path, cmd.ref)
		applied := actual == "" if cmd.new == ZERO_SHA else actual == cmd.new
		if !applied {
			continue
		}
		commits := "[]" if cmd.new == ZERO_SHA else commits_json(repo.path, cmd)
		r := wire.rpc(cfg.supa, c.bearer, "forge_record_push",
			fmt.tprintf(`{{"repo":%s,"ref":%s,"old_sha":%s,"new_sha":%s,"commits":%s}}`,
				wire.q(repo.id), wire.q(cmd.ref), wire.q(cmd.old), wire.q(cmd.new), commits))
		if !wire.ok(r) {
			fmt.eprintfln("record push %s %s: %s", repo.id, cmd.ref, r.err)
		}
		if cmd.old == ZERO_SHA && strings.has_prefix(cmd.ref, "refs/heads/") && created_branch == "" {
			created_branch = cmd.ref
		}
	}
	// The first branch pushed to an empty repository becomes its HEAD when
	// the default branch does not exist.
	if created_branch != "" {
		head, _ := git_text(repo.path, "symbolic-ref", "HEAD")
		if rev_parse(repo.path, head) == "" {
			git(repo.path, {"symbolic-ref", "HEAD", created_branch})
			branch := strings.trim_prefix(created_branch, "refs/heads/")
			wire.rest(cfg.supa, c.bearer, "PATCH", fmt.tprintf("forge_repos?id=eq.%s", repo.id),
				fmt.tprintf(`{{"default_branch":%s}}`, wire.q(branch)))
		}
	}
}
