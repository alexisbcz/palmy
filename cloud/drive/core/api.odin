// The drive's calls against PostgREST and Storage. Each is a thin, typed
// wrapper over one endpoint or RPC from 20261019300000_drive.sql: the
// database decides who may do what, so nothing here re-checks access.
package drivecore

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

Client :: struct {
	url, storage, anon: string,
	token:              string,
	identity:           string, // the identity id the token is scoped to
	handle:             string,
	device:             string,
}

Item :: struct {
	id:           string,
	identity_id:  string,
	parent_id:    string,
	name:         string,
	kind:         string,
	version_id:   string,
	size:         i64,
	content_hash: string,
	mime:         string,
	starred:      bool,
	trashed_at:   string,
	trashed_root: string,
	created_at:   string,
	modified_at:  string,
	updated_at:   string,
	accessed_at:  string,
	seq:          i64,
	device:       string,
}

Version :: struct {
	id:           string,
	item_id:      string,
	size:         i64,
	content_hash: string,
	chunk_size:   i64,
	chunks:       []string,
	mime:         string,
	device:       string,
	created_at:   string,
}

Usage :: struct {
	stored_bytes:  i64,
	file_bytes:    i64,
	trash_bytes:   i64,
	version_bytes: i64,
	quota_bytes:   i64,
	files:         i64,
	folders:       i64,
}

Share :: struct {
	id:               string,
	identity_id:      string,
	item_id:          string,
	grantee_identity: string,
	role:             string,
	created_at:       string,
	expires_at:       string,
	revoked_at:       string,
}

Link :: struct {
	id:          string,
	item_id:     string,
	label:       string,
	created_at:  string,
	expires_at:  string,
	revoked_at:  string,
	opened:      i64,
	last_opened: string,
}

Minted :: struct {
	link_id:    string,
	token:      string,
	expires_at: string,
}

Resolved :: struct {
	identity_id:  string,
	item_id:      string,
	path:         string,
	kind:         string,
	size:         i64,
	mime:         string,
	content_hash: string,
	chunk_size:   i64,
	chunks:       []string,
}

Identity_Row :: struct {
	id:           string,
	handle:       string,
	display_name: string,
	kind:         string,
	color:        string,
}

// Error carries the HTTP status (0: the server could not be reached) and
// PostgREST's message. `offline` is what the sync daemon branches on.
Error :: struct {
	status:  int,
	code:    string, // SQLSTATE, e.g. PT409
	message: string,
}

offline :: proc(e: Error) -> bool {
	return e.status == 0 && e.message != ""
}

failed :: proc(e: Error) -> bool {
	return e.message != ""
}

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

@(private)
auth_headers :: proc(c: ^Client, extra: ..Header) -> []Header {
	hs := make([dynamic]Header, context.temp_allocator)
	tok := c.token != "" ? c.token : c.anon
	append(&hs, Header{"Authorization", fmt.tprintf("Bearer %s", tok)})
	if c.anon != "" {
		append(&hs, Header{"apikey", c.anon})
	}
	append(&hs, ..extra)
	return hs[:]
}

@(private)
to_error :: proc(r: Response) -> Error {
	if r.status == 0 {
		return Error{0, "", r.err != "" ? strings.clone(r.err) : "unreachable"}
	}
	if r.status >= 200 && r.status < 300 {
		return {}
	}
	e := Error {
		status = r.status,
	}
	Pg_Err :: struct {
		code:    string,
		message: string,
		error:   string,
	}
	pe: Pg_Err
	if json.unmarshal(r.body, &pe, allocator = context.temp_allocator) == nil {
		e.code = strings.clone(pe.code)
		msg := pe.message != "" ? pe.message : pe.error
		e.message = strings.clone(msg != "" ? msg : fmt.tprintf("HTTP %d", r.status))
	} else {
		e.message = fmt.aprintf("HTTP %d: %s", r.status, string(r.body[:min(len(r.body), 200)]))
	}
	return e
}

// rest calls PostgREST and decodes the JSON answer into `out` (which may be
// nil when the caller does not want it).
rest :: proc(c: ^Client, method, path: string, body: string, out: ^$T, prefer := "return=representation") -> Error {
	hs := auth_headers(c, Header{"Content-Type", "application/json"}, Header{"Prefer", prefer})
	r := request(method, c.url, path, hs, transmute([]u8)body, allocator = context.temp_allocator)
	if e := to_error(r); failed(e) {
		return e
	}
	if out != nil && len(r.body) > 0 {
		if err := json.unmarshal(r.body, out); err != nil {
			return Error{r.status, "", fmt.aprintf("cannot read the answer (%v)", err)}
		}
	}
	return {}
}

// rpc posts named arguments to /rpc/<name>.
rpc :: proc(c: ^Client, name: string, args: string, out: ^$T) -> Error {
	return rest(c, "POST", fmt.tprintf("/rpc/%s", name), args, out)
}

// q is a JSON string literal, or null for "".
q :: proc(s: string) -> string {
	if s == "" {
		return "null"
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if r < 0x20 {
				fmt.sbprintf(&b, "\\u%04x", int(r))
			} else {
				strings.write_rune(&b, r)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// pct percent-encodes a query value.
pct :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~':
			strings.write_byte(&b, ch)
		case:
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

@(private)
one :: proc(items: []Item) -> Item {
	return len(items) > 0 ? items[0] : {}
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

// changes is the feed: every item of this identity with seq > since, in
// order. Trashed items are included, which is how a sync client learns of a
// delete.
changes :: proc(c: ^Client, since: i64) -> (items: []Item, e: Error) {
	path := fmt.tprintf("/drive_items?identity_id=eq.%s&seq=gt.%d&order=seq.asc", c.identity, since)
	e = rest(c, "GET", path, "", &items)
	return
}

// list_children lists a folder. `owner` is the identity whose drive it is in,
// when that is not the caller's own: a folder shared with this identity.
list_children :: proc(c: ^Client, parent: string, trashed := false, owner := "") -> (items: []Item, e: Error) {
	pf := parent == "" ? "parent_id=is.null" : fmt.tprintf("parent_id=eq.%s", parent)
	tf := trashed ? "trashed_at=not.is.null" : "trashed_at=is.null"
	who := owner != "" ? owner : c.identity
	path := fmt.tprintf("/drive_items?identity_id=eq.%s&%s&%s&order=kind.desc,name.asc", who, pf, tf)
	e = rest(c, "GET", path, "", &items)
	return
}

get_item :: proc(c: ^Client, id: string) -> (it: Item, e: Error) {
	items: []Item
	e = rest(c, "GET", fmt.tprintf("/drive_items?id=eq.%s", id), "", &items)
	if !failed(e) && len(items) == 0 {
		e = Error{404, "PT404", "no such item"}
	}
	return one(items), e
}

// trash_roots lists what was trashed, one entry per trashing.
list_trash :: proc(c: ^Client) -> (items: []Item, e: Error) {
	path := fmt.tprintf("/drive_items?identity_id=eq.%s&trashed_at=not.is.null&order=trashed_at.desc", c.identity)
	all: []Item
	e = rest(c, "GET", path, "", &all)
	out := make([dynamic]Item)
	for it in all {
		if it.trashed_root == it.id {
			append(&out, it)
		}
	}
	return out[:], e
}

list_recent :: proc(c: ^Client, limit := 30) -> (items: []Item, e: Error) {
	path := fmt.tprintf(
		"/drive_items?identity_id=eq.%s&kind=eq.file&trashed_at=is.null&order=accessed_at.desc.nullslast,modified_at.desc&limit=%d",
		c.identity,
		limit,
	)
	e = rest(c, "GET", path, "", &items)
	return
}

list_starred :: proc(c: ^Client) -> (items: []Item, e: Error) {
	path := fmt.tprintf("/drive_items?identity_id=eq.%s&starred=is.true&trashed_at=is.null&order=name.asc", c.identity)
	e = rest(c, "GET", path, "", &items)
	return
}

search :: proc(c: ^Client, text: string) -> (items: []Item, e: Error) {
	path := fmt.tprintf(
		"/drive_items?identity_id=eq.%s&trashed_at=is.null&name=ilike.*%s*&order=kind.desc,name.asc&limit=200",
		c.identity,
		pct(text),
	)
	e = rest(c, "GET", path, "", &items)
	return
}

all_live :: proc(c: ^Client) -> (items: []Item, e: Error) {
	path := fmt.tprintf("/drive_items?identity_id=eq.%s&trashed_at=is.null&order=name.asc", c.identity)
	e = rest(c, "GET", path, "", &items)
	return
}

mkdir :: proc(c: ^Client, parent, name: string) -> (it: Item, e: Error) {
	body := fmt.tprintf(
		`{{"identity_id":%s,"parent_id":%s,"name":%s,"kind":"folder","device":%s}}`,
		q(c.identity),
		q(parent),
		q(name),
		q(c.device),
	)
	items: []Item
	e = rest(c, "POST", "/drive_items", body, &items)
	return one(items), e
}

commit :: proc(
	c: ^Client,
	parent, name, item: string,
	base_seq: i64,
	h: File_Hash,
	mime: string,
	modified: string = "",
) -> (
	it: Item,
	e: Error,
) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{{"p_identity":%s,"p_parent":%s,"p_name":%s,"p_item":%s,"p_base_seq":%s,"p_size":%d,"p_hash":%s,"p_mime":%s,"p_chunk_size":%d,"p_device":%s,`,
		q(c.identity),
		q(parent),
		q(name),
		q(item),
		base_seq > 0 ? fmt.tprint(base_seq) : "null",
		h.size,
		q(h.hash),
		q(mime),
		CHUNK_SIZE,
		q(c.device),
	)
	if modified != "" {
		fmt.sbprintf(&b, `"p_modified":%s,`, q(modified))
	}
	strings.write_string(&b, `"p_chunks":[`)
	for ch, i in h.chunks {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, q(ch))
	}
	strings.write_string(&b, "]}")
	e = rpc(c, "drive_commit", strings.to_string(b), &it)
	return
}

move :: proc(c: ^Client, item, parent, name: string, base_seq: i64 = 0) -> (it: Item, e: Error) {
	args := fmt.tprintf(
		`{{"p_item":%s,"p_parent":%s,"p_name":%s,"p_base_seq":%s,"p_device":%s}}`,
		q(item),
		q(parent),
		q(name),
		base_seq > 0 ? fmt.tprint(base_seq) : "null",
		q(c.device),
	)
	e = rpc(c, "drive_move", args, &it)
	return
}

trash :: proc(c: ^Client, item: string) -> Error {
	n: int
	return rpc(c, "drive_trash", fmt.tprintf(`{{"p_item":%s,"p_device":%s}}`, q(item), q(c.device)), &n)
}

restore :: proc(c: ^Client, item: string) -> (it: Item, e: Error) {
	e = rpc(c, "drive_restore", fmt.tprintf(`{{"p_item":%s}}`, q(item)), &it)
	return
}

empty_trash :: proc(c: ^Client) -> (n: int, e: Error) {
	e = rpc(c, "drive_empty_trash", fmt.tprintf(`{{"p_identity":%s}}`, q(c.identity)), &n)
	return
}

set_starred :: proc(c: ^Client, item: string, on: bool) -> Error {
	items: []Item
	return rest(c, "PATCH", fmt.tprintf("/drive_items?id=eq.%s", item), fmt.tprintf(`{{"starred":%v}}`, on), &items)
}

touch :: proc(c: ^Client, item: string) -> Error {
	return rest(c, "POST", "/rpc/drive_touch", fmt.tprintf(`{{"p_item":%s}}`, q(item)), (^int)(nil), "")
}

versions :: proc(c: ^Client, item: string) -> (vs: []Version, e: Error) {
	e = rest(c, "GET", fmt.tprintf("/drive_versions?item_id=eq.%s&order=created_at.desc", item), "", &vs)
	return
}

current_version :: proc(c: ^Client, it: Item) -> (v: Version, e: Error) {
	vs: []Version
	e = rest(c, "GET", fmt.tprintf("/drive_versions?id=eq.%s", it.version_id), "", &vs)
	if !failed(e) && len(vs) == 0 {
		e = Error{404, "PT404", "no version"}
	}
	if len(vs) > 0 {
		v = vs[0]
	}
	return
}

usage :: proc(c: ^Client) -> (u: Usage, e: Error) {
	us: []Usage
	e = rpc(c, "drive_usage", fmt.tprintf(`{{"p_identity":%s}}`, q(c.identity)), &us)
	if len(us) > 0 {
		u = us[0]
	}
	return
}

// item_path is the slash path from the drive root.
item_path :: proc(c: ^Client, item: string) -> (p: string, e: Error) {
	e = rpc(c, "drive_path", fmt.tprintf(`{{"p_item":%s}}`, q(item)), &p)
	return
}

// ---------------------------------------------------------------------------
// Sharing
// ---------------------------------------------------------------------------

share :: proc(c: ^Client, item, handle, role: string, expires: string = "") -> (s: Share, e: Error) {
	args := fmt.tprintf(
		`{{"p_item":%s,"p_handle":%s,"p_role":%s,"p_expires":%s}}`,
		q(item),
		q(handle),
		q(role),
		q(expires),
	)
	e = rpc(c, "drive_share", args, &s)
	return
}

// shares_of lists the live shares on an item, naming each grantee.
Share_Row :: struct {
	id:               string,
	item_id:          string,
	grantee_identity: string,
	grantee_handle:   string,
	grantee_name:     string,
	role:             string,
	created_at:       string,
	expires_at:       string,
}

shares_of :: proc(c: ^Client, item: string) -> (rows: []Share_Row, e: Error) {
	e = rpc(c, "drive_shares_of", fmt.tprintf(`{{"p_item":%s}}`, q(item)), &rows)
	return
}

// shared_with_me is what other identities have shared to this one.
Incoming :: struct {
	share_id:       string,
	role:           string,
	shared_at:      string,
	expires_at:     string,
	owner_identity: string,
	owner_handle:   string,
	owner_name:     string,
	item_id:        string,
	name:           string,
	kind:           string,
	size:           i64,
	mime:           string,
	modified_at:    string,
}

shared_with_me :: proc(c: ^Client) -> (rows: []Incoming, e: Error) {
	e = rpc(c, "drive_shared_with", fmt.tprintf(`{{"p_identity":%s}}`, q(c.identity)), &rows)
	return
}

revoke_share :: proc(c: ^Client, share_id: string) -> Error {
	rows: []Share
	e := rest(c, "PATCH", fmt.tprintf("/drive_shares?id=eq.%s&revoked_at=is.null", share_id), `{"revoked_at":"now()"}`, &rows)
	if !failed(e) && len(rows) == 0 {
		return Error{404, "PT404", "no such live share"}
	}
	return e
}

link_mint :: proc(c: ^Client, item: string, expires_in: string, label: string = "") -> (m: Minted, e: Error) {
	ms: []Minted
	args := fmt.tprintf(`{{"p_item":%s,"p_expires_in":%s,"p_label":%s}}`, q(item), q(expires_in), q(label))
	e = rpc(c, "drive_link_mint", args, &ms)
	if len(ms) > 0 {
		m = ms[0]
	}
	return
}

links_of :: proc(c: ^Client, item: string) -> (ls: []Link, e: Error) {
	filter := item != "" ? fmt.tprintf("item_id=eq.%s&", item) : ""
	e = rest(c, "GET", fmt.tprintf("/drive_links?%sidentity_id=eq.%s&order=created_at.desc", filter, c.identity), "", &ls)
	return
}

revoke_link :: proc(c: ^Client, link_id: string) -> Error {
	ls: []Link
	e := rest(c, "PATCH", fmt.tprintf("/drive_links?id=eq.%s&revoked_at=is.null", link_id), `{"revoked_at":"now()"}`, &ls)
	if !failed(e) && len(ls) == 0 {
		return Error{404, "PT404", "no such live link"}
	}
	return e
}

// link_resolve is the anonymous side: what a link token gives access to.
link_resolve :: proc(c: ^Client, token: string) -> (rs: []Resolved, e: Error) {
	anon := c^
	anon.token = ""
	e = rpc(&anon, "drive_link_resolve", fmt.tprintf(`{{"p_token":%s}}`, q(token)), &rs)
	return
}

identities :: proc(c: ^Client) -> (rows: []Identity_Row, e: Error) {
	e = rest(c, "GET", "/identities?archived_at=is.null&order=created_at.asc", "", &rows)
	return
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

chunk_path :: proc(identity, hash: string) -> string {
	return fmt.tprintf("/object/drive/%s/chunks/%s", identity, hash)
}

missing_chunks :: proc(c: ^Client, hashes: []string) -> (missing: []string, e: Error) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"p_identity":%s,"p_hashes":[`, q(c.identity))
	for h, i in hashes {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, q(h))
	}
	strings.write_string(&b, "]}")
	e = rpc(c, "drive_missing_chunks", strings.to_string(b), &missing)
	return
}

// put_chunk uploads one chunk. A 409 means it is already there, which for
// content-addressed data is success.
put_chunk :: proc(c: ^Client, hash: string, data: []u8) -> Error {
	hs := auth_headers(c, Header{"Content-Type", "application/octet-stream"})
	r := request("POST", c.storage, chunk_path(c.identity, hash), hs, data, 120 * time.Second, context.temp_allocator)
	if r.status == 409 || r.status == 400 && strings.contains(string(r.body), "Duplicate") {
		return {}
	}
	return to_error(r)
}

get_chunk :: proc(c: ^Client, identity, hash: string, allocator := context.allocator) -> (data: []u8, e: Error) {
	hs := auth_headers(c)
	path := fmt.tprintf("/object/authenticated/drive/%s/chunks/%s", identity, hash)
	r := request("GET", c.storage, path, hs, nil, 120 * time.Second, allocator)
	if e = to_error(r); failed(e) {
		return nil, e
	}
	return r.body, {}
}

delete_chunk :: proc(c: ^Client, hash: string) -> Error {
	hs := auth_headers(c)
	r := request("DELETE", c.storage, chunk_path(c.identity, hash), hs, nil, allocator = context.temp_allocator)
	return to_error(r)
}

unreferenced_chunks :: proc(c: ^Client) -> (names: []string, e: Error) {
	e = rpc(c, "drive_unreferenced_chunks", fmt.tprintf(`{{"p_identity":%s}}`, q(c.identity)), &names)
	return
}
