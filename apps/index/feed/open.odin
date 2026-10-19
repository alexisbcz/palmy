// Opening a result: the command that shows it in the right application, in
// its own identity (product.md P1: the identity is a property of the
// object, so the window opens in the object's identity, whatever the
// caller's).
//
// `exact` says the application goes to the item itself. Where it is false
// the application opens at the nearest place it can be told about, and
// search.md lists the flag each application would need.
package indexfeed

import "core:fmt"
import "core:strings"
import ic "../core"

Open :: struct {
	argv:  []string,
	exact: bool,
}

open_command :: proc(r: ic.Result, id: Ident, p: Paths, allocator := context.temp_allocator) -> Open {
	context.allocator = allocator
	env := fmt.aprintf("PALM_IDENTITY=%s", r.handle)
	cmd :: proc(env: string, args: ..string) -> []string {
		out := make([dynamic]string)
		append(&out, "env", env)
		append(&out, ..args)
		return out[:]
	}
	switch r.kind {
	case .Mail:
		if id.mail_dir != "" {
			return {cmd(env, "mail", fmt.aprintf("--maildir=%s", id.mail_dir)), false}
		}
		return {cmd(env, "mail"), false}
	case .Event:
		return {cmd(env, "calendar"), false}
	case .Person:
		return {cmd(env, "contacts"), false}
	case .Page:
		return {cmd(env, "browser", "open", r.uri), true}
	case .Chat:
		return {cmd(env, "chat", "--cloud", "--identity", r.handle), false}
	case .Issue:
		return {cmd(env, "forge"), false}
	case .Task:
		if r.app == "track" {
			id_ := r.uri[strings.last_index_byte(r.uri, '/') + 1:]
			return {cmd(env, "term", "-e", "track", "show", id_), true}
		}
		return {cmd(env, "calendar"), false}
	case .Note:
		return {cmd(env, "notes"), false}
	case .Doc, .File:
		drive_root := fmt.aprintf("%s/%s/", p.drive, r.handle)
		if strings.has_prefix(r.uri, drive_root) {
			// drive open picks the application by type, the same mapping.
			return {cmd(env, "drive", "open", r.uri[len(drive_root):]), true}
		}
		if r.app == "files" {
			return {cmd(env, "files", r.uri), false}
		}
		return {cmd(env, r.app, r.uri), true}
	}
	return {cmd(env, "home"), false}
}
