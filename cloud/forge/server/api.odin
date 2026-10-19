package main

// The JSON API for what needs the repository on disk. Rows (repositories,
// issues, pull requests, comments, grants, tokens) are not here: clients read
// and write those through PostgREST with the same bearer token.
//
//	GET  /api/repos/<h>/<r>/branches
//	GET  /api/repos/<h>/<r>/tree?ref=&path=
//	GET  /api/repos/<h>/<r>/blob?ref=&path=[&raw=1]
//	GET  /api/repos/<h>/<r>/commits?ref=&path=&limit=&skip=
//	GET  /api/repos/<h>/<r>/commit/<sha>
//	GET  /api/repos/<h>/<r>/compare?base=&head=
//	POST /api/repos/<h>/<r>/init           {"readme": true}     admin/write
//	POST /api/repos/<h>/<r>/pulls/<n>/merge {"method": "merge-commit"|"fast-forward"}
//	POST /api/token/exchange               a personal access token for a session
//	GET  /api/whoami

import "core:fmt"
import "core:strconv"
import "core:strings"
import wire "forge:wire"

MAX_BLOB :: 1 << 20
MAX_DIFF :: 2 << 20

api_route :: proc(req: ^Request, segs: []string) -> int {
	if len(segs) == 2 && segs[0] == "token" && segs[1] == "exchange" && req.method == "POST" {
		return api_exchange(req)
	}
	if len(segs) == 1 && segs[0] == "whoami" {
		return api_whoami(req)
	}
	if len(segs) >= 4 && segs[0] == "repos" {
		handle, name := segs[1], strings.trim_suffix(segs[2], ".git")
		what := segs[3]
		switch {
		case what == "branches" && req.method == "GET":
			return api_branches(req, handle, name)
		case what == "tree" && req.method == "GET":
			return api_tree(req, handle, name)
		case what == "blob" && req.method == "GET":
			return api_blob(req, handle, name)
		case what == "commits" && req.method == "GET":
			return api_commits(req, handle, name)
		case what == "commit" && len(segs) == 5 && req.method == "GET":
			return api_commit(req, handle, name, segs[4])
		case what == "compare" && req.method == "GET":
			return api_compare(req, handle, name)
		case what == "init" && req.method == "POST":
			return api_init(req, handle, name)
		case what == "pulls" && len(segs) == 6 && segs[5] == "merge" && req.method == "POST":
			n, ok := strconv.parse_int(segs[4])
			if !ok {
				respond_error(req, 400, "bad pull request number")
				return 400
			}
			return api_merge(req, handle, name, n)
		}
	}
	respond_error(req, 404, "no such endpoint")
	return 404
}

api_exchange :: proc(req: ^Request) -> int {
	c, bad := authenticate(req)
	if bad || c.kind != .Token {
		respond_error(req, 401, "present a personal access token", challenge())
		return 401
	}
	respond_json(req, 200, fmt.tprintf(
		`{{"access_token":%s,"token_type":"bearer","expires_in":%d,"identity_id":%s,"scope":%s,"token_id":%s}}`,
		wire.q(c.bearer), TOKEN_TTL, wire.q(c.identity), wire.q(c.scope), wire.q(c.token_id)))
	return 200
}

api_whoami :: proc(req: ^Request) -> int {
	c, bad := authenticate(req)
	if bad {
		respond_error(req, 401, "bad credentials", challenge())
		return 401
	}
	kind := [Auth_Kind]string{.Anonymous = "anonymous", .Session = "session", .Token = "token"}
	ids := "[]"
	if c.kind != .Anonymous {
		r := wire.rpc(cfg.supa, c.bearer, "forge_my_identities")
		if r.status == 401 {
			respond_error(req, 401, "bad credentials", challenge())
			return 401
		}
		if wire.ok(r) {
			ids = string(r.body)
		}
	}
	respond_json(req, 200, fmt.tprintf(`{{"kind":%s,"scope":%s,"identities":%s}}`, wire.q(kind[c.kind]), wire.qn(c.scope), ids))
	return 200
}

// resolve_ref turns ?ref= (a branch, tag or sha; default the HEAD branch)
// into a commit sha. Empty when the repository has no commits yet.
resolve_ref :: proc(repo: Repo, ref: string) -> (sha: string, name: string) {
	name = ref
	if name == "" {
		head, _ := git_text(repo.path, "symbolic-ref", "--short", "HEAD")
		name = head if head != "" else repo.default_branch
	}
	if strings.has_prefix(name, "-") {
		return "", name
	}
	sha = rev_parse(repo.path, fmt.tprintf("%s^{{commit}}", name))
	return sha, name
}

clean_path :: proc(p: string) -> (string, bool) {
	p := strings.trim(p, "/")
	for seg in strings.split(p, "/") {
		if seg == ".." || seg == "." {
			return "", false
		}
	}
	if strings.has_prefix(p, "-") {
		return "", false
	}
	return p, true
}

api_branches :: proc(req: ^Request, handle, name: string) -> int {
	_, repo, code := open_repo(req, handle, name, "read")
	if code != 0 {
		return code
	}
	out, _ := git_text(repo.path, "for-each-ref", "--sort=-committerdate",
		"--format=%(refname:short)%1f%(objectname)%1f%(committerdate:iso-strict)%1f%(subject)%1f%(authorname)", "refs/heads")
	head, _ := git_text(repo.path, "symbolic-ref", "--short", "HEAD")
	sb := strings.builder_make()
	fmt.sbprintf(&sb, `{{"default":%s,"branches":[`, wire.q(head))
	n := 0
	for line in strings.split_lines(out) {
		f := strings.split(line, "\x1f")
		if len(f) < 5 {
			continue
		}
		if n > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, `{{"name":%s,"sha":%s,"date":%s,"summary":%s,"author":%s}}`,
			wire.q(f[0]), wire.q(f[1]), wire.q(f[2]), wire.q(f[3]), wire.q(f[4]))
		n += 1
	}
	strings.write_string(&sb, "]}")
	respond_json(req, 200, strings.to_string(sb))
	return 200
}

Entry :: struct {
	name, kind, mode, sha: string,
	size:                  int,
}

api_tree :: proc(req: ^Request, handle, name: string) -> int {
	_, repo, code := open_repo(req, handle, name, "read")
	if code != 0 {
		return code
	}
	path, pok := clean_path(query_param(req.query, "path"))
	if !pok {
		respond_error(req, 400, "bad path")
		return 400
	}
	sha, refname := resolve_ref(repo, query_param(req.query, "ref"))
	if sha == "" {
		respond_json(req, 200, fmt.tprintf(`{{"ref":%s,"sha":null,"path":%s,"empty":true,"entries":[]}}`, wire.q(refname), wire.q(path)))
		return 200
	}
	r := git(repo.path, {"ls-tree", "-l", "-z", fmt.tprintf("%s:%s", sha, path)})
	if !r.ok {
		respond_error(req, 404, "no such directory")
		return 404
	}
	entries := make([dynamic]Entry)
	for rec in strings.split(string(r.out), "\x00") {
		if rec == "" {
			continue
		}
		meta, _, ename := strings.partition(rec, "\t")
		f := strings.fields(meta)
		if len(f) < 4 {
			continue
		}
		size, _ := strconv.parse_int(f[3])
		append(&entries, Entry{name = ename, kind = f[1], mode = f[0], sha = f[2], size = size})
	}
	// Directories first, then by name, as every file browser does.
	for i in 1 ..< len(entries) {
		for j := i; j > 0; j -= 1 {
			a, b := entries[j - 1], entries[j]
			ad, bd := a.kind == "tree", b.kind == "tree"
			if ad == bd && strings.compare(strings.to_lower(a.name), strings.to_lower(b.name)) <= 0 || ad && !bd {
				break
			}
			entries[j - 1], entries[j] = b, a
		}
	}
	last := git(repo.path, {"log", "-1", LOG_FORMAT, sha, "--", path if path != "" else "."})
	sb := strings.builder_make()
	fmt.sbprintf(&sb, `{{"ref":%s,"sha":%s,"path":%s,"empty":false,"last_commit":%s,"entries":[`,
		wire.q(refname), wire.q(sha), wire.q(path), strings.trim(log_to_json(string(last.out)), "[]") if len(last.out) > 0 else "null")
	for e, i in entries {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, `{{"name":%s,"type":%s,"mode":%s,"sha":%s,"size":%d}}`, wire.q(e.name), wire.q(e.kind), wire.q(e.mode), wire.q(e.sha), e.size)
	}
	strings.write_string(&sb, "]}")
	respond_json(req, 200, strings.to_string(sb))
	return 200
}

is_binary :: proc(data: []u8) -> bool {
	n := min(len(data), 8000)
	for b in data[:n] {
		if b == 0 {
			return true
		}
	}
	return false
}

api_blob :: proc(req: ^Request, handle, name: string) -> int {
	_, repo, code := open_repo(req, handle, name, "read")
	if code != 0 {
		return code
	}
	path, pok := clean_path(query_param(req.query, "path"))
	if !pok || path == "" {
		respond_error(req, 400, "bad path")
		return 400
	}
	sha, refname := resolve_ref(repo, query_param(req.query, "ref"))
	if sha == "" {
		respond_error(req, 404, "no such ref")
		return 404
	}
	spec := fmt.tprintf("%s:%s", sha, path)
	size_text, sok := git_text(repo.path, "cat-file", "-s", spec)
	if !sok {
		respond_error(req, 404, "no such file")
		return 404
	}
	size, _ := strconv.parse_int(size_text)
	r := git(repo.path, {"cat-file", "blob", spec})
	data := r.out
	if query_param(req.query, "raw") == "1" {
		respond(req, 200, "application/octet-stream", data)
		return 200
	}
	binary := is_binary(data)
	truncated := len(data) > MAX_BLOB
	if truncated {
		data = data[:MAX_BLOB]
	}
	text := "" if binary else string(data)
	respond_json(req, 200, fmt.tprintf(`{{"ref":%s,"sha":%s,"path":%s,"size":%d,"binary":%v,"truncated":%v,"text":%s}}`,
		wire.q(refname), wire.q(sha), wire.q(path), size, binary, truncated, wire.q(text)))
	return 200
}

api_commits :: proc(req: ^Request, handle, name: string) -> int {
	_, repo, code := open_repo(req, handle, name, "read")
	if code != 0 {
		return code
	}
	sha, refname := resolve_ref(repo, query_param(req.query, "ref"))
	if sha == "" {
		respond_json(req, 200, fmt.tprintf(`{{"ref":%s,"commits":[]}}`, wire.q(refname)))
		return 200
	}
	limit, _ := strconv.parse_int(query_param(req.query, "limit"))
	skip, _ := strconv.parse_int(query_param(req.query, "skip"))
	limit = clamp(limit if limit > 0 else 50, 1, 500)
	args := make([dynamic]string)
	append(&args, "log", fmt.tprintf("--max-count=%d", limit), fmt.tprintf("--skip=%d", max(skip, 0)), LOG_FORMAT, sha)
	if p, ok := clean_path(query_param(req.query, "path")); ok && p != "" {
		append(&args, "--", p)
	}
	r := git(repo.path, args[:])
	respond_json(req, 200, fmt.tprintf(`{{"ref":%s,"sha":%s,"commits":%s}}`, wire.q(refname), wire.q(sha), log_to_json(string(r.out))))
	return 200
}

is_hex :: proc(s: string) -> bool {
	if len(s) < 4 || len(s) > 40 {
		return false
	}
	for c in s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// files_json reads `git diff --numstat -z`-free output: "<add>\t<del>\t<path>".
files_json :: proc(numstat: string) -> string {
	sb := strings.builder_make()
	strings.write_byte(&sb, '[')
	n := 0
	for line in strings.split_lines(numstat) {
		f := strings.split_n(line, "\t", 3)
		if len(f) < 3 {
			continue
		}
		if n > 0 {
			strings.write_byte(&sb, ',')
		}
		add, _ := strconv.parse_int(f[0])
		del, _ := strconv.parse_int(f[1])
		fmt.sbprintf(&sb, `{{"path":%s,"additions":%d,"deletions":%d,"binary":%v}}`, wire.q(f[2]), add, del, f[0] == "-")
		n += 1
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

diff_text :: proc(out: []u8) -> (string, bool) {
	if len(out) > MAX_DIFF {
		return string(out[:MAX_DIFF]), true
	}
	return string(out), false
}

api_commit :: proc(req: ^Request, handle, name, rev: string) -> int {
	_, repo, code := open_repo(req, handle, name, "read")
	if code != 0 {
		return code
	}
	if !is_hex(rev) {
		respond_error(req, 400, "give a commit sha")
		return 400
	}
	sha := rev_parse(repo.path, fmt.tprintf("%s^{{commit}}", rev))
	if sha == "" {
		respond_error(req, 404, "no such commit")
		return 404
	}
	meta := git(repo.path, {"log", "-1", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%B", sha})
	f := strings.split_n(string(meta.out), "\x1f", 7)
	if len(f) < 7 {
		respond_error(req, 500, "cannot read the commit")
		return 500
	}
	parents := strings.fields(f[1])
	base := parents[0] if len(parents) > 0 else ""
	diff, numstat: Git_Result
	if base == "" {
		diff = git(repo.path, {"diff-tree", "-p", "--no-color", "--root", "-M", sha})
		numstat = git(repo.path, {"diff-tree", "--numstat", "-r", "--root", "-M", "--no-commit-id", sha})
	} else {
		diff = git(repo.path, {"diff", "--no-color", "-M", base, sha})
		numstat = git(repo.path, {"diff", "--numstat", "-M", base, sha})
	}
	text, truncated := diff_text(diff.out)
	sb := strings.builder_make()
	strings.write_byte(&sb, '[')
	for p, i in parents {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		strings.write_string(&sb, wire.q(p))
	}
	strings.write_byte(&sb, ']')
	respond_json(req, 200, fmt.tprintf(
		`{{"sha":%s,"parents":%s,"author_name":%s,"author_email":%s,"authored_at":%s,"committer_name":%s,"message":%s,"files":%s,"diff":%s,"truncated":%v}}`,
		wire.q(f[0]), strings.to_string(sb), wire.q(f[2]), wire.q(f[3]), wire.q(f[4]), wire.q(f[5]), wire.q(strings.trim_space(f[6])),
		files_json(string(numstat.out)), wire.q(text), truncated))
	return 200
}

Comparison :: struct {
	base_sha, head_sha, merge_base: string,
	ahead, behind:                  int,
	fast_forward, clean:            bool,
	conflicts:                      []string,
}

compare :: proc(repo: Repo, base, head: string) -> (cmp: Comparison, ok: bool) {
	cmp.base_sha = rev_parse(repo.path, fmt.tprintf("refs/heads/%s^{{commit}}", base))
	cmp.head_sha = rev_parse(repo.path, fmt.tprintf("refs/heads/%s^{{commit}}", head))
	if cmp.base_sha == "" || cmp.head_sha == "" {
		return cmp, false
	}
	cmp.merge_base, _ = git_text(repo.path, "merge-base", cmp.base_sha, cmp.head_sha)
	a, _ := git_text(repo.path, "rev-list", "--count", fmt.tprintf("%s..%s", cmp.base_sha, cmp.head_sha))
	b, _ := git_text(repo.path, "rev-list", "--count", fmt.tprintf("%s..%s", cmp.head_sha, cmp.base_sha))
	cmp.ahead, _ = strconv.parse_int(a)
	cmp.behind, _ = strconv.parse_int(b)
	cmp.fast_forward = cmp.merge_base == cmp.base_sha
	mt := git(repo.path, {"merge-tree", "--write-tree", "--name-only", "--no-messages", cmp.base_sha, cmp.head_sha})
	cmp.clean = mt.ok
	if !mt.ok && mt.code == 1 {
		lines := strings.split_lines(strings.trim_space(string(mt.out)))
		if len(lines) > 1 {
			cmp.conflicts = lines[1:]
		}
	}
	return cmp, true
}

api_compare :: proc(req: ^Request, handle, name: string) -> int {
	_, repo, code := open_repo(req, handle, name, "read")
	if code != 0 {
		return code
	}
	base, head := query_param(req.query, "base"), query_param(req.query, "head")
	if base == "" || head == "" || strings.has_prefix(base, "-") || strings.has_prefix(head, "-") {
		respond_error(req, 400, "give base and head branches")
		return 400
	}
	cmp, ok := compare(repo, base, head)
	if !ok {
		respond_error(req, 404, "no such branch")
		return 404
	}
	log := git(repo.path, {"log", "--max-count=250", LOG_FORMAT, fmt.tprintf("%s..%s", cmp.base_sha, cmp.head_sha)})
	from := cmp.merge_base if cmp.merge_base != "" else cmp.base_sha
	diff := git(repo.path, {"diff", "--no-color", "-M", from, cmp.head_sha})
	numstat := git(repo.path, {"diff", "--numstat", "-M", from, cmp.head_sha})
	text, truncated := diff_text(diff.out)
	conf := strings.builder_make()
	strings.write_byte(&conf, '[')
	for c, i in cmp.conflicts {
		if i > 0 {
			strings.write_byte(&conf, ',')
		}
		strings.write_string(&conf, wire.q(c))
	}
	strings.write_byte(&conf, ']')
	respond_json(req, 200, fmt.tprintf(
		`{{"base":%s,"head":%s,"base_sha":%s,"head_sha":%s,"merge_base":%s,"ahead":%d,"behind":%d,"fast_forward":%v,"mergeable":%v,"conflicts":%s,"commits":%s,"files":%s,"diff":%s,"truncated":%v}}`,
		wire.q(base), wire.q(head), wire.q(cmp.base_sha), wire.q(cmp.head_sha), wire.qn(cmp.merge_base), cmp.ahead, cmp.behind,
		cmp.fast_forward, cmp.clean, strings.to_string(conf), log_to_json(string(log.out)), files_json(string(numstat.out)),
		wire.q(text), truncated))
	return 200
}

// identity_card fetches a handle and display name for commit authorship.
identity_card :: proc(c: ^Caller, id: string) -> (handle, display: string) {
	if id == "" {
		return "palmforge", "Palmy forge"
	}
	r := wire.rpc(cfg.supa, c.bearer, "forge_identity_card", fmt.tprintf(`{{"who":%s}}`, wire.q(id)))
	if row, ok := wire.first(r.value); ok {
		return wire.str(row, "handle"), wire.str(row, "display_name")
	}
	return "palmforge", "Palmy forge"
}

api_init :: proc(req: ^Request, handle, name: string) -> int {
	c, repo, code := open_repo(req, handle, name, "write")
	if code != 0 {
		return code
	}
	body, _ := wire.parse(req.body)
	if !wire.flag(body, "readme") || rev_parse(repo.path, "HEAD") != "" {
		respond_json(req, 200, fmt.tprintf(`{{"path_id":%s,"initialised":true}}`, wire.q(repo.id)))
		return 200
	}
	// An initial commit with a README, written straight into the bare
	// repository: blob, tree, commit, ref.
	h, display := identity_card(&c, repo.acting)
	readme := fmt.tprintf("# %s\n\n%s\n", repo.name, "A repository on the Palmy forge.")
	blob := git(repo.path, {"hash-object", "-w", "--stdin"}, transmute([]u8)readme)
	tree := git(repo.path, {"mktree"}, transmute([]u8)fmt.tprintf("100644 blob %s\tREADME.md\n", strings.trim_space(string(blob.out))))
	env := author_env(h, display)
	commit := git(repo.path, {"commit-tree", strings.trim_space(string(tree.out)), "-m", "Initial commit"}, nil, env)
	sha := strings.trim_space(string(commit.out))
	branch := repo.default_branch
	if !blob.ok || !tree.ok || !commit.ok || !git(repo.path, {"update-ref", fmt.tprintf("refs/heads/%s", branch), sha, ZERO_SHA}).ok {
		respond_error(req, 500, "cannot write the initial commit")
		return 500
	}
	git(repo.path, {"symbolic-ref", "HEAD", fmt.tprintf("refs/heads/%s", branch)})
	record_push(&c, repo, {{ZERO_SHA, sha, fmt.tprintf("refs/heads/%s", branch)}})
	respond_json(req, 201, fmt.tprintf(`{{"initialised":true,"commit":%s,"branch":%s}}`, wire.q(sha), wire.q(branch)))
	return 201
}

author_env :: proc(handle, display: string) -> []string {
	email := fmt.tprintf("%s@%s", handle, cfg.mail_domain)
	env := make([]string, 4, context.temp_allocator)
	env[0] = fmt.tprintf("GIT_AUTHOR_NAME=%s", display)
	env[1] = fmt.tprintf("GIT_AUTHOR_EMAIL=%s", email)
	env[2] = fmt.tprintf("GIT_COMMITTER_NAME=%s", display)
	env[3] = fmt.tprintf("GIT_COMMITTER_EMAIL=%s", email)
	return env
}

// api_merge merges a pull request on the server, in the bare repository, with
// no working tree: `git merge-tree --write-tree` computes the result,
// `commit-tree` writes the merge commit, and `update-ref` moves the base
// branch only if it still points where it did (compare-and-swap), so two
// merges racing cannot lose a commit.
api_merge :: proc(req: ^Request, handle, name: string, number: int) -> int {
	c, repo, code := open_repo(req, handle, name, "write")
	if code != 0 {
		return code
	}
	body, _ := wire.parse(req.body)
	method := wire.str(body, "method")
	if method == "" {
		method = "merge-commit"
	}
	if method != "merge-commit" && method != "fast-forward" {
		respond_error(req, 400, "method is merge-commit or fast-forward")
		return 400
	}
	pr := wire.rest(cfg.supa, c.bearer, "GET",
		fmt.tprintf("forge_issue_list?repo_id=eq.%s&number=eq.%d&is_pull=eq.true&select=id,title,state,head_ref,base_ref,merged_at", repo.id, number))
	row, found := wire.first(pr.value)
	if !wire.ok(pr) || !found {
		respond_error(req, 404, "no such pull request")
		return 404
	}
	if wire.str(row, "state") != "open" {
		respond_error(req, 409, "the pull request is not open")
		return 409
	}
	head_ref, base_ref, title := wire.str(row, "head_ref"), wire.str(row, "base_ref"), wire.str(row, "title")
	cmp, ok := compare(repo, base_ref, head_ref)
	if !ok {
		respond_error(req, 409, "a branch of this pull request no longer exists")
		return 409
	}
	if cmp.ahead == 0 {
		respond_error(req, 409, "nothing to merge: the head branch has no new commits")
		return 409
	}
	new_sha := ""
	switch method {
	case "fast-forward":
		if !cmp.fast_forward {
			respond_error(req, 409, fmt.tprintf("cannot fast-forward: %s has %d commit(s) not in %s", base_ref, cmp.behind, head_ref))
			return 409
		}
		new_sha = cmp.head_sha
	case "merge-commit":
		mt := git(repo.path, {"merge-tree", "--write-tree", "--no-messages", cmp.base_sha, cmp.head_sha})
		if !mt.ok {
			respond_error(req, 409, "the branches conflict; merge locally and push")
			return 409
		}
		tree := strings.split_lines(strings.trim_space(string(mt.out)))[0]
		h, display := identity_card(&c, repo.acting)
		msg := fmt.tprintf("Merge pull request #%d from %s\n\n%s\n", number, head_ref, title)
		commit := git(repo.path, {"commit-tree", tree, "-p", cmp.base_sha, "-p", cmp.head_sha, "-F", "-"}, transmute([]u8)msg, author_env(h, display))
		if !commit.ok {
			respond_error(req, 500, "cannot write the merge commit")
			return 500
		}
		new_sha = strings.trim_space(string(commit.out))
	}
	ref := fmt.tprintf("refs/heads/%s", base_ref)
	if !git(repo.path, {"update-ref", "-m", fmt.tprintf("palmforge: merge #%d", number), ref, new_sha, cmp.base_sha}).ok {
		respond_error(req, 409, fmt.tprintf("%s moved while merging; try again", base_ref))
		return 409
	}
	record_push(&c, repo, {{cmp.base_sha, new_sha, ref}})
	r := wire.rpc(cfg.supa, c.bearer, "forge_record_merge",
		fmt.tprintf(`{{"repo":%s,"num":%d,"method":%s,"merged":%s}}`, wire.q(repo.id), number, wire.q(method), wire.q(new_sha)))
	if !wire.ok(r) {
		respond_error(req, 500, fmt.tprintf("merged on disk but not recorded: %s", r.err))
		return 500
	}
	respond_json(req, 200, fmt.tprintf(`{{"number":%d,"method":%s,"sha":%s,"base":%s,"head":%s}}`,
		number, wire.q(method), wire.q(new_sha), wire.q(base_ref), wire.q(head_ref)))
	return 200
}
