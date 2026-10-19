// palm-davd — CalDAV and CardDAV for Palmframe identities.
//
//	palm-davd serve            listen and serve (the default)
//	palm-davd mint USER IDENTITY
//	                           print a token for that identity (development)
//	palm-davd --help
//
// Configuration is the environment:
//
//	PALM_CLOUD_URL        the Supabase gateway         (http://127.0.0.1:54321)
//	PALM_CLOUD_ANON_KEY   its anon key                 (the local default)
//	PALM_SERVICE_KEY      its service key: used only to check app passwords
//	PALM_JWT_SECRET       the project's JWT secret (HS256)
//	PALM_DAV_PORT         where to listen on 127.0.0.1 (59580)
//	PALM_DAV_LOG          1 to log every request to stderr
//
// URLs (everything under /dav, discovery per RFC 6764):
//
//	/.well-known/caldav, /.well-known/carddav    -> /dav/
//	/dav/principals/<handle>/                     one principal per identity
//	/dav/calendars/<handle>/                      calendar home
//	/dav/calendars/<handle>/<slug>/               a calendar
//	/dav/calendars/<handle>/<owner>~<slug>/       a calendar shared with <handle>
//	/dav/calendars/<handle>/inbox/  outbox/       scheduling (RFC 6638)
//	/dav/addressbooks/<handle>/<slug>/            an address book
//
// Auth: "Authorization: Bearer <GoTrue access token>" (the Palmframe apps),
// or Basic with an identity handle and one of its app passwords (stock
// clients). An app password acts for exactly one identity.
//
// SAFETY: the listener binds 127.0.0.1 only, and the only outgoing
// connections are to the configured gateway. There is no SMTP and no
// outbound iTIP: invitations to addresses outside the platform are queued
// as "not sent: outbound not enabled".
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import web "web"

Config :: struct {
	supabase:    string,
	anon_key:    string,
	service_key: string,
	jwt_secret:  string,
	port:        int,
	log:         bool,
}

cfg: Config

DEFAULT_ANON :: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
DEFAULT_SERVICE :: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
DEFAULT_SECRET :: "super-secret-jwt-token-with-at-least-32-characters-long"

env :: proc(name, def: string) -> string {
	v := os.get_env(name, context.allocator)
	return v != "" ? v : def
}

load_config :: proc() {
	cfg.supabase = strings.trim_right(env("PALM_CLOUD_URL", "http://127.0.0.1:54321"), "/")
	cfg.anon_key = env("PALM_CLOUD_ANON_KEY", DEFAULT_ANON)
	cfg.service_key = env("PALM_SERVICE_KEY", DEFAULT_SERVICE)
	cfg.jwt_secret = env("PALM_JWT_SECRET", DEFAULT_SECRET)
	cfg.port, _ = strconv.parse_int(env("PALM_DAV_PORT", "59580"))
	cfg.log = env("PALM_DAV_LOG", "") == "1"
}

USAGE :: `palm-davd — CalDAV and CardDAV for Palmframe identities

  palm-davd serve               listen on 127.0.0.1:$PALM_DAV_PORT (59580)
  palm-davd mint USER IDENTITY  print a 1-hour token scoped to IDENTITY
  palm-davd --help

Environment: PALM_CLOUD_URL, PALM_CLOUD_ANON_KEY, PALM_SERVICE_KEY,
PALM_JWT_SECRET, PALM_DAV_PORT, PALM_DAV_LOG=1.
See cloud/docs/calendar-contacts.md.
`

main :: proc() {
	load_config()
	args := os.args[1:]
	cmd := len(args) > 0 ? args[0] : "serve"
	switch cmd {
	case "--help", "-h", "help":
		fmt.print(USAGE)
	case "mint":
		if len(args) != 3 {
			fmt.eprint(USAGE)
			os.exit(2)
		}
		fmt.println(web.mint_jwt(cfg.jwt_secret, args[1], args[2], 3600))
	case "serve":
		s, err := web.listen("127.0.0.1", cfg.port)
		if err != "" {
			fmt.eprintfln("palm-davd: %s", err)
			os.exit(6)
		}
		s.log = cfg.log
		fmt.eprintfln("palm-davd: listening on http://127.0.0.1:%d/dav/ (gateway %s)", cfg.port, cfg.supabase)
		web.run(s, handle)
	case:
		fmt.eprint(USAGE)
		os.exit(2)
	}
}
