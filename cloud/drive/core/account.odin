// The drive configured from the person's Palmy account, through
// apps/cloudkit, rather than from a hand-written drive.conf.
//
// After `accounts sign-in`, cloudkit's token store holds the person's session.
// The drive lists the identities with it, and for each one uses the session
// scoped to that identity -- this machine's own (scoped/<handle>.json), minting
// one with mint_scoped_session the first time if there is none. Every drive
// request then goes out with a token that can only ever act for that one
// identity; the unscoped session is used for nothing else.
//
// With PALM_IDENTITY set, only that identity is configured, from its scoped
// session alone: the person's session is not even opened.
package drivecore

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../../../apps/cloudkit"

config_from_account :: proc() -> (cfg: Config, err: string) {
	home := os.get_env("HOME", context.temp_allocator)
	cfg.path = strings.clone("cloudkit")
	cfg.drive_dir = fmt.aprintf("%s/Drive", home)
	cfg.state_dir = fmt.aprintf("%s/.local/state/palm-drive", home)
	cfg.device = strings.clone(ck.machine_name())
	if cfg.device == "" {
		cfg.device = "this device"
	}

	scope := os.get_env("PALM_IDENTITY", context.temp_allocator)
	c, oe := ck.open(scope = scope, app = "drive")
	if !ck.ok(oe) {
		return cfg, fmt.aprintf("cloudkit: %s", oe.message)
	}
	cfg.url = fmt.aprintf("%s/rest/v1", strings.trim_right(c.url_text, "/"))
	cfg.storage = fmt.aprintf("%s/storage/v1", strings.trim_right(c.url_text, "/"))
	cfg.anon = strings.clone(c.anon_key)
	if !ck.signed_in(c) {
		return cfg, strings.clone("not signed in to a Palmy account: run `accounts sign-in` first")
	}

	ids, ie := ck.identities(c)
	if !ck.ok(ie) {
		return cfg, fmt.aprintf("listing identities: %s", ie.message)
	}
	if !ck.scoped(c) {
		cfg.account = strings.clone(c.session.access_token)
	}
	for ident in ids {
		if ident.archived || (scope != "" && ident.handle != scope) {
			continue
		}
		append(
			&cfg.identities,
			Identity {
				handle = ident.handle,
				id = ident.id,
				name = ident.display_name,
				kind = ident.kind,
				color = ident.color,
				cloudkit = true,
				root = fmt.aprintf("%s/%s", cfg.drive_dir, ident.handle),
			},
		)
		// Make sure this machine holds a session scoped to the identity. A
		// scoped session cannot mint another, which is the point.
		if !ck.scoped(c) {
			sc, _ := ck.open(scope = ident.handle, app = "drive")
			if !ck.signed_in(sc) {
				if _, me := ck.scope_to(c, ident, fmt.tprintf("palm-drive on %s", cfg.device)); !ck.ok(me) {
					return cfg, fmt.aprintf("minting a session for %s: %s", ident.handle, me.message)
				}
			}
		}
	}
	if v := os.get_env("PALM_DRIVE_DIR", context.temp_allocator); v != "" {
		cfg.drive_dir = strings.clone(v)
		for &id in cfg.identities {
			id.root = fmt.aprintf("%s/%s", cfg.drive_dir, id.handle)
		}
	}
	if v := os.get_env("PALM_DRIVE_STATE", context.temp_allocator); v != "" {
		cfg.state_dir = strings.clone(v)
	}
	if v := os.get_env("PALM_DRIVE_DEVICE", context.temp_allocator); v != "" {
		cfg.device = strings.clone(v)
	}
	return cfg, ""
}

// account_token is the identity's scoped access token, refreshed when it has
// under a minute left. Called for every client, so a daemon running for
// weeks keeps working across token expiry.
account_token :: proc(handle: string) -> string {
	c, oe := ck.open(scope = handle, app = "drive")
	if !ck.ok(oe) || !ck.signed_in(c) {
		return ""
	}
	ck.ensure_fresh(c) // a refresh is written back to the store by cloudkit
	return strings.clone(c.session.access_token)
}
