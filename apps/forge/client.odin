package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import wire "forge:wire"


// ---------------------------------------------------------------------------
// Rows (PostgREST)
// ---------------------------------------------------------------------------

get_rows :: proc(c: ^Client, path: string) -> wire.Result {
	return wire.rest(c.supa, c.bearer, "GET", path)
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
	if c.kind == "scoped" {
		return c.ck.session.identity_id, ""
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
	return "", "sign in first (`accounts signin`), or set FORGE_TOKEN"
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
	r := wire.request(method, fmt.tprintf("%s%s", c.forge, path), hs[:], transmute([]u8)body)
	if r.status == 0 {
		r.err = fmt.aprintf("the forge at %s is not reachable", c.forge)
	} else if msg := wire.str(r.value, "error"); !wire.ok(r) && msg != "" {
		r.err = msg
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
