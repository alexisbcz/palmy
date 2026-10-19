// The forge's core: every call the window and the command line make, in one
// place, so the two front ends cannot drift. Rows go to PostgREST directly
// with the caller's bearer token (row-level security decides); what needs the
// repository on disk goes to the forge server's JSON API with the same token.
//
// Credentials, in order:
//
//	FORGE_TOKEN=palmforge_...   a personal access token, exchanged at the
//	                            forge for a ten-minute session scoped to the
//	                            token's identity. What an agent should use.
//	the session file            `forge login` with an e-mail and password,
//	                            refreshed as it nears expiry. The file is
//	                            $FORGE_SESSION, or
//	                            ~/.local/share/palm/forge/session.json (0600).
//
// Endpoints come from the session file, overridden by FORGE_URL, API_URL and
// ANON_KEY.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import wire "forge:wire"

DEFAULT_FORGE :: "http://127.0.0.1:58580"
DEFAULT_API :: "http://127.0.0.1:58521"

Client :: struct {
	forge:    string,
	supa:     wire.Supa,
	bearer:   string, // what PostgREST, Storage and the forge see
	kind:     string, // "session" | "token" | "" (anonymous)
	email:    string,
	refresh:  string,
	expires:  int,
	token:    string, // the personal access token, when that is how we came in
	token_identity: string,
	token_scope: string,
	path:     string, // the session file
}

session_path :: proc() -> string {
	if p := os.get_env("FORGE_SESSION", context.temp_allocator); p != "" {
		return strings.clone(p)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.local/share/palm/forge/session.json", home)
}

session_save :: proc(c: ^Client) -> bool {
	dir := c.path[:strings.last_index_byte(c.path, '/')]
	os.make_directory_all(dir)
	body := fmt.tprintf(
		`{{"forge":%s,"api":%s,"anon":%s,"email":%s,"access_token":%s,"refresh_token":%s,"expires_at":%d}}`,
		wire.q(c.forge), wire.q(c.supa.url), wire.q(c.supa.anon), wire.q(c.email), wire.q(c.bearer), wire.q(c.refresh), c.expires)
	return os.write_entire_file(c.path, transmute([]u8)body, os.Permissions{.Read_User, .Write_User}) == nil
}

// client_open builds a client from the session file and the environment.
// An empty bearer means anonymous: public repositories only.
client_open :: proc() -> (c: Client, err: string) {
	c.path = session_path()
	c.forge = DEFAULT_FORGE
	c.supa.url = DEFAULT_API
	if data, rerr := os.read_entire_file(c.path, context.allocator); rerr == nil {
		if v, ok := wire.parse(data); ok {
			c.forge = wire.str(v, "forge") if wire.str(v, "forge") != "" else c.forge
			c.supa.url = wire.str(v, "api") if wire.str(v, "api") != "" else c.supa.url
			c.supa.anon = wire.str(v, "anon")
			c.email = wire.str(v, "email")
			c.bearer = wire.str(v, "access_token")
			c.refresh = wire.str(v, "refresh_token")
			c.expires = wire.num(v, "expires_at")
			if c.bearer != "" {
				c.kind = "session"
			}
		}
	}
	if v := os.get_env("FORGE_URL", context.allocator); v != "" {
		c.forge = v
	}
	if v := os.get_env("API_URL", context.allocator); v != "" {
		c.supa.url = v
	}
	if v := os.get_env("ANON_KEY", context.allocator); v != "" {
		c.supa.anon = v
	}
	if c.supa.anon == "" {
		return c, "no Supabase key: run `forge login`, or set API_URL and ANON_KEY"
	}
	if tok := os.get_env("FORGE_TOKEN", context.allocator); tok != "" {
		return c, client_use_token(&c, tok)
	}
	if c.kind == "session" && c.expires > 0 && i64(c.expires) - time.time_to_unix(time.now()) < 120 && c.refresh != "" {
		s, rerr := wire.refresh(c.supa, c.refresh)
		if rerr != "" {
			return c, fmt.aprintf("the session has expired (%s); run `forge login` again", rerr)
		}
		c.bearer, c.refresh, c.expires = s.access_token, s.refresh_token, s.expires_at
		session_save(&c)
	}
	return c, ""
}

// client_use_token exchanges a personal access token at the forge.
client_use_token :: proc(c: ^Client, tok: string) -> string {
	h := []wire.Header{{"Authorization", fmt.tprintf("Bearer %s", tok)}}
	resp, err := wire.request("POST", fmt.tprintf("%s/api/token/exchange", c.forge), h, nil)
	if err != "" {
		return fmt.aprintf("the forge at %s is not reachable", c.forge)
	}
	if resp.status != 200 {
		return "the token was refused (wrong, revoked or expired)"
	}
	v, _ := wire.parse(resp.body)
	c.bearer = wire.str(v, "access_token")
	c.token = tok
	c.token_identity = wire.str(v, "identity_id")
	c.token_scope = wire.str(v, "scope")
	c.kind = "token"
	return ""
}

client_login :: proc(c: ^Client, email, password: string, signup: bool) -> string {
	s: wire.Session
	err: string
	if signup {
		s, err = wire.sign_up(c.supa, email, password)
	} else {
		s, err = wire.sign_in(c.supa, email, password)
	}
	if err != "" {
		return err
	}
	c.bearer, c.refresh, c.expires, c.email, c.kind = s.access_token, s.refresh_token, s.expires_at, email, "session"
	if !session_save(c) {
		return fmt.aprintf("signed in, but cannot write %s", c.path)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Rows (PostgREST)
// ---------------------------------------------------------------------------

get_rows :: proc(c: ^Client, path: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "GET", path)
}

my_identities :: proc(c: ^Client) -> wire.Result {
	if c.bearer == "" {
		return {status = 200, value = json.Array{}}
	}
	return wire.rpc(c.supa, c.bearer, "forge_my_identities")
}

// identity_by_handle finds one of the caller's own identities.
identity_by_handle :: proc(c: ^Client, handle: string) -> (json.Value, bool) {
	r := my_identities(c)
	for row in wire.arr(r.value) {
		if wire.str(row, "handle") == handle {
			return row, true
		}
	}
	return nil, false
}

REPO_COLS :: "id,identity_id,owner_handle,owner_name,owner_color,name,description,visibility,default_branch,created_at,updated_at,pushed_at,archived_at,role,open_issues,open_pulls"

list_repos :: proc(c: ^Client, owner := "", visibility := "") -> wire.Result {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "forge_repo_list?select=%s&order=pushed_at.desc.nullslast,created_at.desc", REPO_COLS)
	if owner != "" {
		fmt.sbprintf(&sb, "&owner_handle=eq.%s", wire.enc(owner))
	}
	if visibility != "" {
		fmt.sbprintf(&sb, "&visibility=eq.%s", wire.enc(visibility))
	}
	return get_rows(c, strings.to_string(sb))
}

Repo_Ref :: struct {
	owner, name: string,
}

parse_repo_ref :: proc(s: string) -> (Repo_Ref, bool) {
	o, _, n := strings.partition(strings.trim_suffix(s, ".git"), "/")
	if o == "" || n == "" || strings.contains(n, "/") {
		return {}, false
	}
	return Repo_Ref{o, n}, true
}

// get_repo reads one repository row as this caller sees it, or nothing.
get_repo :: proc(c: ^Client, ref: Repo_Ref) -> (json.Value, bool) {
	r := get_rows(c, fmt.tprintf("forge_repo_list?select=%s&owner_handle=eq.%s&name=ilike.%s", REPO_COLS, wire.enc(ref.owner), wire.enc(ref.name)))
	return wire.first(r.value)
}

// acting_identity is who this caller writes as on a repository: the scope
// in force if there is one, else the database's answer (the owner, or the
// identity holding the strongest grant).
acting_identity :: proc(c: ^Client, ref: Repo_Ref, scope: string) -> (id: string, err: string) {
	if c.kind == "token" {
		return c.token_identity, ""
	}
	if scope != "" {
		row, ok := identity_by_handle(c, scope)
		if !ok {
			return "", fmt.aprintf("%s is not one of your identities", scope)
		}
		return wire.str(row, "id"), ""
	}
	r := wire.rpc(c.supa, c.bearer, "forge_resolve", fmt.tprintf(`{{"owner_handle":%s,"repo_name":%s}}`, wire.q(ref.owner), wire.q(ref.name)))
	if row, ok := wire.first(r.value); ok {
		if a := wire.str(row, "acting_identity"); a != "" {
			return a, ""
		}
	}
	ids := my_identities(c)
	if row, ok := wire.first(ids.value); ok {
		return wire.str(row, "id"), ""
	}
	return "", "sign in first (`forge login`), or set FORGE_TOKEN"
}

create_repo :: proc(c: ^Client, identity_id, name, visibility, description: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "POST", "forge_repos",
		fmt.tprintf(`{{"identity_id":%s,"name":%s,"visibility":%s,"description":%s}}`,
			wire.q(identity_id), wire.q(name), wire.q(visibility), wire.q(description)),
		"return=representation")
}

update_repo :: proc(c: ^Client, id, patch_json: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "PATCH", fmt.tprintf("forge_repos?id=eq.%s", id), patch_json, "return=representation")
}

delete_repo :: proc(c: ^Client, id: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "DELETE", fmt.tprintf("forge_repos?id=eq.%s", id), "", "return=representation")
}

ISSUE_COLS :: "id,repo_id,number,title,body,state,is_pull,created_at,updated_at,closed_at,author_identity_id,author_handle,author_name,author_color,head_ref,base_ref,head_sha,base_sha,merge_method,merged_sha,merged_at,comment_count,labels"

list_issues :: proc(c: ^Client, repo_id: string, pulls: bool, state := "open") -> wire.Result {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "forge_issue_list?select=%s&repo_id=eq.%s&is_pull=eq.%v&order=number.desc", ISSUE_COLS, repo_id, pulls)
	if state == "open" || state == "closed" {
		fmt.sbprintf(&sb, "&state=eq.%s", state)
	}
	return get_rows(c, strings.to_string(sb))
}

get_issue :: proc(c: ^Client, repo_id: string, number: int) -> (json.Value, bool) {
	r := get_rows(c, fmt.tprintf("forge_issue_list?select=%s&repo_id=eq.%s&number=eq.%d", ISSUE_COLS, repo_id, number))
	return wire.first(r.value)
}

list_comments :: proc(c: ^Client, issue_id: string) -> wire.Result {
	return get_rows(c, fmt.tprintf("forge_comment_list?issue_id=eq.%s&order=created_at", issue_id))
}

list_reviews :: proc(c: ^Client, issue_id: string) -> wire.Result {
	return get_rows(c, fmt.tprintf("forge_reviews?issue_id=eq.%s&order=created_at&select=id,state,body,commit_sha,created_at,author_identity_id", issue_id))
}

create_issue :: proc(c: ^Client, repo_id, author, title, body: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "POST", "forge_issues",
		fmt.tprintf(`{{"repo_id":%s,"author_identity_id":%s,"title":%s,"body":%s}}`, wire.q(repo_id), wire.q(author), wire.q(title), wire.q(body)),
		"return=representation")
}

set_issue_state :: proc(c: ^Client, issue_id, state: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "PATCH", fmt.tprintf("forge_issues?id=eq.%s", issue_id), fmt.tprintf(`{{"state":%s}}`, wire.q(state)), "return=representation")
}

add_comment :: proc(c: ^Client, repo_id, issue_id, author, body: string, path := "", line := 0, review_id := "") -> wire.Result {
	extra := ""
	if path != "" {
		extra = fmt.tprintf(`,"path":%s,"line":%d`, wire.q(path), line)
	}
	if review_id != "" {
		extra = fmt.tprintf(`%s,"review_id":%s`, extra, wire.q(review_id))
	}
	return wire.rest(c.supa, c.bearer, "POST", "forge_comments",
		fmt.tprintf(`{{"repo_id":%s,"issue_id":%s,"author_identity_id":%s,"body":%s%s}}`, wire.q(repo_id), wire.q(issue_id), wire.q(author), wire.q(body), extra),
		"return=representation")
}

add_review :: proc(c: ^Client, repo_id, issue_id, author, state, body, sha: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "POST", "forge_reviews",
		fmt.tprintf(`{{"repo_id":%s,"issue_id":%s,"author_identity_id":%s,"state":%s,"body":%s,"commit_sha":%s}}`,
			wire.q(repo_id), wire.q(issue_id), wire.q(author), wire.q(state), wire.q(body), wire.qn(sha)),
		"return=representation")
}

open_pull :: proc(c: ^Client, repo_id, author, title, body, head, base: string) -> wire.Result {
	return wire.rpc(c.supa, c.bearer, "forge_pull_open",
		fmt.tprintf(`{{"repo":%s,"title":%s,"body":%s,"head":%s,"base":%s,"author":%s}}`,
			wire.q(repo_id), wire.q(title), wire.q(body), wire.q(head), wire.q(base), wire.q(author)))
}

list_collaborators :: proc(c: ^Client, repo_id: string) -> wire.Result {
	return get_rows(c, fmt.tprintf("forge_collaborator_list?repo_id=eq.%s&revoked_at=is.null&order=created_at", repo_id))
}

grant :: proc(c: ^Client, repo_id, handle, role: string) -> wire.Result {
	return wire.rpc(c.supa, c.bearer, "forge_grant", fmt.tprintf(`{{"repo":%s,"grantee_handle":%s,"grant_role":%s}}`, wire.q(repo_id), wire.q(handle), wire.q(role)))
}

revoke :: proc(c: ^Client, repo_id, handle: string) -> wire.Result {
	return wire.rpc(c.supa, c.bearer, "forge_revoke", fmt.tprintf(`{{"repo":%s,"grantee_handle":%s}}`, wire.q(repo_id), wire.q(handle)))
}

list_tokens :: proc(c: ^Client) -> wire.Result {
	return get_rows(c, "forge_tokens?select=id,identity_id,name,prefix,scope,created_at,last_used_at,expires_at,revoked_at&order=created_at.desc")
}

create_token :: proc(c: ^Client, identity_id, name, scope: string, days: int) -> wire.Result {
	d := "null" if days <= 0 else fmt.tprintf("%d", days)
	return wire.rpc(c.supa, c.bearer, "forge_token_create",
		fmt.tprintf(`{{"target":%s,"token_name":%s,"token_scope":%s,"expires_in_days":%s}}`, wire.q(identity_id), wire.q(name), wire.q(scope), d))
}

revoke_token :: proc(c: ^Client, id: string) -> wire.Result {
	return wire.rpc(c.supa, c.bearer, "forge_token_revoke", fmt.tprintf(`{{"token":%s}}`, wire.q(id)))
}

list_events :: proc(c: ^Client, repo_id := "", limit := 50) -> wire.Result {
	if repo_id != "" {
		return get_rows(c, fmt.tprintf("forge_event_list?repo_id=eq.%s&order=created_at.desc&limit=%d", repo_id, limit))
	}
	return get_rows(c, fmt.tprintf("forge_event_list?order=created_at.desc&limit=%d", limit))
}

// ---------------------------------------------------------------------------
// The repository on disk (the forge server)
// ---------------------------------------------------------------------------

forge_call :: proc(c: ^Client, method, path: string, body := "") -> wire.Result {
	hs := make([dynamic]wire.Header, context.temp_allocator)
	if c.bearer != "" {
		append(&hs, wire.Header{"Authorization", fmt.tprintf("Bearer %s", c.bearer)})
	}
	if body != "" {
		append(&hs, wire.Header{"Content-Type", "application/json"})
	}
	resp, err := wire.request(method, fmt.tprintf("%s%s", c.forge, path), hs[:], transmute([]u8)body)
	r := wire.Result {
		status = resp.status,
		body   = resp.body,
		err    = err,
	}
	if err != "" {
		r.err = fmt.aprintf("the forge at %s is not reachable", c.forge)
		return r
	}
	r.value, _ = wire.parse(resp.body)
	if resp.status < 200 || resp.status >= 300 {
		r.err = wire.str(r.value, "error")
		if r.err == "" {
			r.err = fmt.aprintf("HTTP %d", resp.status)
		}
	}
	return r
}

repo_api :: proc(c: ^Client, ref: Repo_Ref, what: string, query := "") -> wire.Result {
	q := "" if query == "" else fmt.tprintf("?%s", query)
	return forge_call(c, "GET", fmt.tprintf("/api/repos/%s/%s/%s%s", ref.owner, ref.name, what, q))
}

get_tree :: proc(c: ^Client, ref: Repo_Ref, rev, path: string) -> wire.Result {
	return repo_api(c, ref, "tree", fmt.tprintf("ref=%s&path=%s", wire.enc(rev), wire.enc(path)))
}

get_blob :: proc(c: ^Client, ref: Repo_Ref, rev, path: string) -> wire.Result {
	return repo_api(c, ref, "blob", fmt.tprintf("ref=%s&path=%s", wire.enc(rev), wire.enc(path)))
}

get_commits :: proc(c: ^Client, ref: Repo_Ref, rev: string, limit := 50) -> wire.Result {
	return repo_api(c, ref, "commits", fmt.tprintf("ref=%s&limit=%d", wire.enc(rev), limit))
}

get_commit :: proc(c: ^Client, ref: Repo_Ref, sha: string) -> wire.Result {
	return repo_api(c, ref, fmt.tprintf("commit/%s", sha))
}

get_branches :: proc(c: ^Client, ref: Repo_Ref) -> wire.Result {
	return repo_api(c, ref, "branches")
}

get_compare :: proc(c: ^Client, ref: Repo_Ref, base, head: string) -> wire.Result {
	return repo_api(c, ref, "compare", fmt.tprintf("base=%s&head=%s", wire.enc(base), wire.enc(head)))
}

init_repo :: proc(c: ^Client, ref: Repo_Ref, readme: bool) -> wire.Result {
	return forge_call(c, "POST", fmt.tprintf("/api/repos/%s/%s/init", ref.owner, ref.name), fmt.tprintf(`{{"readme":%v}}`, readme))
}

merge_pull :: proc(c: ^Client, ref: Repo_Ref, number: int, method: string) -> wire.Result {
	return forge_call(c, "POST", fmt.tprintf("/api/repos/%s/%s/pulls/%d/merge", ref.owner, ref.name, number), fmt.tprintf(`{{"method":%s}}`, wire.q(method)))
}

clone_url :: proc(c: ^Client, ref: Repo_Ref) -> string {
	return fmt.tprintf("%s/%s/%s.git", c.forge, ref.owner, ref.name)
}
