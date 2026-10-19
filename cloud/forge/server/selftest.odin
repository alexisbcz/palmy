package main

// Offline checks of the parts that need no database and no git: pkt-lines,
// the push command parser, ref policy, path and query handling, the token
// signer, and the JSON the API builds. The end-to-end behaviour is checked by
// cloud/forge/demo.sh against a running stack.

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import wire "forge:wire"

@(private = "file")
passed, failed: int

@(private = "file")
check :: proc(ok: bool, what: string) {
	if ok {
		passed += 1
	} else {
		failed += 1
		fmt.eprintfln("FAIL %s", what)
	}
}

selftest :: proc() -> int {
	context.allocator = context.temp_allocator

	// pkt-lines
	{
		sb := strings.builder_make()
		pkt_line(&sb, "# service=git-upload-pack\n")
		check(strings.to_string(sb) == "001e# service=git-upload-pack\n", "pkt-line length prefix")
	}

	// receive-pack commands
	{
		a := strings.repeat("a", 40)
		b := strings.repeat("b", 40)
		sb := strings.builder_make()
		pkt_line(&sb, fmt.tprintf("%s %s refs/heads/main\x00report-status side-band-64k\n", ZERO_SHA, a))
		pkt_line(&sb, fmt.tprintf("%s %s refs/heads/topic\n", a, b))
		strings.write_string(&sb, "0000PACK....")
		cmds, ok := parse_commands(transmute([]u8)strings.to_string(sb))
		check(ok && len(cmds) == 2, "two push commands")
		check(ok && cmds[0].old == ZERO_SHA && cmds[0].new == a && cmds[0].ref == "refs/heads/main", "capabilities stripped from the first command")
		check(ok && cmds[1].ref == "refs/heads/topic", "second command")
		_, bad := parse_commands(transmute([]u8)string("zzzz"))
		check(!bad, "garbage is refused")
		_, short := parse_commands(transmute([]u8)string("0010abc"))
		check(!short, "a truncated pkt-line is refused")
		sb2 := strings.builder_make()
		pkt_line(&sb2, fmt.tprintf("shallow %s\n", a))
		pkt_line(&sb2, fmt.tprintf("%s %s refs/heads/x\n", a, b))
		strings.write_string(&sb2, "0000")
		c2, ok2 := parse_commands(transmute([]u8)strings.to_string(sb2))
		check(ok2 && len(c2) == 1, "shallow lines are skipped")
	}

	// ref policy
	{
		repo := Repo {
			default_branch = "main",
		}
		a := strings.repeat("a", 40)
		check(ref_policy(repo, {{ZERO_SHA, a, "refs/heads/feature"}}) == "", "a new branch is allowed")
		check(ref_policy(repo, {{ZERO_SHA, a, "refs/tags/v1"}}) == "", "a tag is allowed")
		check(ref_policy(repo, {{a, ZERO_SHA, "refs/heads/main"}}) != "", "deleting the default branch is refused")
		check(ref_policy(repo, {{a, ZERO_SHA, "refs/heads/old"}}) == "", "deleting another branch is allowed")
		check(ref_policy(repo, {{ZERO_SHA, a, "refs/notes/x"}}) != "", "only heads and tags")
		check(ref_policy(repo, {{ZERO_SHA, a, "refs/heads/a/../b"}}) != "", "dot-dot refused")
	}

	// paths and queries
	{
		check(url_decode("a%20b+c") == "a b c", "url decoding")
		check(url_decode("100%") == "100%", "a stray percent survives")
		check(query_param("service=git-upload-pack&x=1", "service") == "git-upload-pack", "query parameter")
		check(query_param("path=src%2Fmain.odin", "path") == "src/main.odin", "encoded path parameter")
		p, ok := clean_path("/src/app/")
		check(ok && p == "src/app", "path trimmed")
		_, bad := clean_path("src/../../etc")
		check(!bad, "dot-dot path refused")
		_, opt := clean_path("--output=x")
		check(!opt, "a path that looks like an option is refused")
		check(is_hex("abc123") && !is_hex("HEAD") && !is_hex("--all"), "sha check")
		check(is_oid(strings.repeat("0", 64)) && !is_oid("abc"), "oid check")
	}

	// the token signer: a well-formed HS256 JWT whose signature verifies
	{
		t := mint_token("secret-of-at-least-thirty-two-characters", "u1", "i1", "t1")
		parts := strings.split(t, ".")
		check(len(parts) == 3, "three parts")
		if len(parts) == 3 {
			payload := parts[1]
			for len(payload) % 4 != 0 {
				payload = strings.concatenate({payload, "="})
			}
			raw, err := base64.decode(payload, base64.DEC_URL_TABLE)
			v, ok := wire.parse(raw)
			check(err == nil && ok, "payload decodes")
			check(wire.str(v, "role") == "forge_pat", "role is forge_pat")
			check(wire.str(v, "palm_identity") == "i1", "palm_identity carried")
			check(wire.str(v, "forge_token") == "t1", "token id carried")
			check(wire.num(v, "exp") - wire.num(v, "iat") == TOKEN_TTL, "short-lived")
			mac: [32]u8
			signing := fmt.tprintf("%s.%s", parts[0], parts[1])
			hmac.sum(hash.Algorithm.SHA256, mac[:], transmute([]u8)signing, transmute([]u8)string("secret-of-at-least-thirty-two-characters"))
			check(b64url(mac[:]) == parts[2], "signature verifies")
			check(!strings.contains(t, "="), "no base64 padding")
		}
		check(looks_like_jwt(t) && !looks_like_jwt("palmforge_abc"), "jwt shape")
	}

	// JSON the API builds
	{
		js := log_to_json("aaaa\x1fAda\x1fada@palm.test\x1f2026-10-19T10:00:00+02:00\x1fsay \"hi\"\x1e\nbbbb\x1fBo\x1fbo@x\x1f2026-10-19T09:00:00+02:00\x1ffirst\x1e\n")
		v, ok := wire.parse(transmute([]u8)js)
		check(ok && len(wire.arr(v)) == 2, "log parsed into two commits")
		if ok && len(wire.arr(v)) == 2 {
			check(wire.str(wire.arr(v)[0], "summary") == `say "hi"`, "quotes survive")
		}
		fs := files_json("3\t1\tsrc/a.odin\n-\t-\timg.png\n")
		fv, fok := wire.parse(transmute([]u8)fs)
		check(fok && len(wire.arr(fv)) == 2, "numstat parsed")
		if fok && len(wire.arr(fv)) == 2 {
			check(wire.num(wire.arr(fv)[0], "additions") == 3 && wire.flag(wire.arr(fv)[1], "binary"), "numstat fields")
		}
		check(wire.q("a\nb\x01") == `"a\nb\u0001"`, "string escaping")
	}

	// the request reader, over a real loopback socket: a chunked body (what
	// git sends for a push over http.postBuffer) and a Content-Length one
	{
		read_one :: proc(raw: string) -> (Request, int) {
			ep, _ := net.parse_endpoint("127.0.0.1:0")
			ls, lerr := net.listen_tcp(ep)
			if lerr != nil {
				return {}, -1
			}
			defer net.close(ls)
			bound, _ := net.bound_endpoint(ls)
			cs, derr := net.dial_tcp(bound)
			if derr != nil {
				return {}, -1
			}
			defer net.close(cs)
			send_all(cs, transmute([]u8)raw)
			net.shutdown(cs, .Send)
			ss, _, aerr := net.accept_tcp(ls)
			if aerr != nil {
				return {}, -1
			}
			defer net.close(ss)
			return read_request(ss)
		}
		req, st := read_one("POST /ada/notes.git/git-receive-pack?x=1 HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\nContent-Type: application/x-git-receive-pack-request\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n")
		check(st == 200 && string(req.body) == "hello world", "chunked request body")
		check(req.path == "/ada/notes.git/git-receive-pack" && req.query == "x=1", "request target split")
		check(wire.header_get(req.headers, "content-type") == "application/x-git-receive-pack-request", "headers read")
		req2, st2 := read_one("GET /api/whoami HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}extra")
		check(st2 == 200 && string(req2.body) == "{}", "content-length request body")
		_, st3 := read_one("NONSENSE\r\n\r\n")
		check(st3 == 400, "a malformed request line is 400")
	}

	fmt.printfln("forge-server selftest: %d passed, %d failed", passed, failed)
	return 0 if failed == 0 else 1
}
