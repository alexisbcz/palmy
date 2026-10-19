package main

// Git LFS, the batch API with the basic transfer adapter.
//
//	POST /<h>/<r>.git/info/lfs/objects/batch      read (download) / write (upload)
//	PUT  /<h>/<r>.git/info/lfs/objects/<oid>      write
//	GET  /<h>/<r>.git/info/lfs/objects/<oid>      read
//
// Objects live in Supabase Storage, bucket forge-lfs, at
// <repo id>/<oid[0:2]>/<oid[2:4]>/<oid>, and are recorded in
// forge_lfs_objects. The server proxies the bytes with the caller's own
// bearer token, so Storage's policies (forge_can_read / forge_can_write on the
// repo id in the path) decide, not the server. Uploads are verified against
// their oid (SHA-256) before they are stored.
//
// Not built: locking (/locks), the multipart and tus adapters, and handing
// the client a signed Storage URL directly instead of proxying.

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import wire "forge:wire"

LFS_TYPE :: "application/vnd.git-lfs+json"

is_oid :: proc(s: string) -> bool {
	if len(s) != 64 {
		return false
	}
	for c in s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

lfs_path :: proc(repo: Repo, oid: string) -> string {
	return fmt.tprintf("%s/%s/%s/%s", repo.id, oid[:2], oid[2:4], oid)
}

lfs_error :: proc(req: ^Request, status: int, message: string, extra: []wire.Header = nil) -> int {
	respond(req, status, LFS_TYPE, transmute([]u8)fmt.tprintf(`{{"message":%s}}`, wire.q(message)), extra)
	return status
}

lfs_batch :: proc(req: ^Request, handle, name: string) -> int {
	body, ok := wire.parse(req.body)
	if !ok {
		return lfs_error(req, 422, "cannot parse the batch request")
	}
	op := wire.str(body, "operation")
	if op != "upload" && op != "download" {
		return lfs_error(req, 422, "operation is upload or download")
	}
	c, repo, code := open_repo(req, handle, name, "write" if op == "upload" else "read")
	if code != 0 {
		return code
	}
	_ = c
	objects := wire.arr(body, "objects")

	// Which of these does the repository already have?
	have := make(map[string]bool)
	if len(objects) > 0 {
		list := strings.builder_make()
		for o, i in objects {
			oid := wire.str(o, "oid")
			if !is_oid(oid) {
				continue
			}
			if i > 0 && strings.builder_len(list) > 0 {
				strings.write_byte(&list, ',')
			}
			strings.write_string(&list, oid)
		}
		r := wire.rest(cfg.supa, c.bearer, "GET", fmt.tprintf("forge_lfs_objects?repo_id=eq.%s&oid=in.(%s)&select=oid", repo.id, strings.to_string(list)))
		for row in wire.arr(r.value) {
			have[wire.str(row, "oid")] = true
		}
	}

	auth := wire.header_get(req.headers, "authorization")
	header := fmt.tprintf(`,"header":{{"Authorization":%s}}`, wire.q(auth)) if auth != "" else ""
	sb := strings.builder_make()
	strings.write_string(&sb, `{"transfer":"basic","objects":[`)
	for o, i in objects {
		oid := wire.str(o, "oid")
		size := wire.num(o, "size")
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		if !is_oid(oid) {
			fmt.sbprintf(&sb, `{{"oid":%s,"size":%d,"error":{{"code":422,"message":"not a sha256 oid"}}}}`, wire.q(oid), size)
			continue
		}
		href := fmt.tprintf("%s/%s/%s.git/info/lfs/objects/%s", cfg.public_url, repo.handle, repo.name, oid)
		switch {
		case op == "upload" && have[oid]:
			fmt.sbprintf(&sb, `{{"oid":%s,"size":%d}}`, wire.q(oid), size)
		case op == "upload":
			fmt.sbprintf(&sb, `{{"oid":%s,"size":%d,"authenticated":true,"actions":{{"upload":{{"href":%s%s,"expires_in":600}}}}}}`,
				wire.q(oid), size, wire.q(href), header)
		case have[oid]:
			fmt.sbprintf(&sb, `{{"oid":%s,"size":%d,"authenticated":true,"actions":{{"download":{{"href":%s%s,"expires_in":600}}}}}}`,
				wire.q(oid), size, wire.q(href), header)
		case:
			fmt.sbprintf(&sb, `{{"oid":%s,"size":%d,"error":{{"code":404,"message":"Object does not exist"}}}}`, wire.q(oid), size)
		}
	}
	strings.write_string(&sb, `],"hash_algo":"sha256"}`)
	respond(req, 200, LFS_TYPE, transmute([]u8)strings.to_string(sb))
	return 200
}

lfs_object :: proc(req: ^Request, handle, name, oid: string) -> int {
	if !is_oid(oid) {
		return lfs_error(req, 422, "not a sha256 oid")
	}
	c, repo, code := open_repo(req, handle, name, "write" if req.method == "PUT" else "read")
	if code != 0 {
		return code
	}
	if req.method == "GET" {
		r := wire.storage_get(cfg.supa, c.bearer, "forge-lfs", lfs_path(repo, oid))
		if !wire.ok(r) {
			return lfs_error(req, 404, "Object does not exist")
		}
		respond(req, 200, "application/octet-stream", r.body)
		return 200
	}
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, req.body, digest[:])
	got := string(hex.encode(digest[:], context.temp_allocator))
	if got != oid {
		return lfs_error(req, 422, fmt.tprintf("the content hashes to %s, not %s", got, oid))
	}
	r := wire.storage_put(cfg.supa, c.bearer, "forge-lfs", lfs_path(repo, oid), req.body)
	if !wire.ok(r) {
		return lfs_error(req, 403 if r.status == 403 || r.status == 400 else 502, fmt.tprintf("storage refused the object: %s", r.err))
	}
	row := wire.rest(cfg.supa, c.bearer, "POST", "forge_lfs_objects",
		fmt.tprintf(`{{"repo_id":%s,"oid":%s,"size":%d}}`, wire.q(repo.id), wire.q(oid), len(req.body)),
		"resolution=ignore-duplicates,return=minimal")
	if !wire.ok(row) && row.status != 409 {
		return lfs_error(req, 502, fmt.tprintf("stored but not recorded: %s", row.err))
	}
	respond(req, 200, LFS_TYPE, nil)
	return 200
}
