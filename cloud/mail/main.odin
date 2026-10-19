package main

// palm-maild — the Palmy mail server.
//
//	palm-maild serve                 SMTP (MX), SMTP submission and JMAP
//	palm-maild mint --sub UUID [--identity UUID] [--role authenticated|service_role] [--ttl S]
//	palm-maild login EMAIL PASSWORD  sign in through GoTrue, print the access token
//	palm-maild summary FILE          print the header summary the server would store
//
// Configuration is the environment (cloud/mail/dev/env.sh has the dev values):
//
//	PALM_REST_PORT    PostgREST on 127.0.0.1           (55521)
//	PALM_AUTH_PORT    GoTrue on 127.0.0.1              (55529)
//	PALM_JWT_SECRET   the project's JWT secret (HS256)
//	PALM_MAIL_DOMAIN  the domain announced in greetings (palm.test); which
//	                  domains are local is the mail_domains table's business
//	PALM_SMTP_PORT    MX listener                      (55525)
//	PALM_SUBMIT_PORT  submission listener              (55587)
//	PALM_JMAP_PORT    JMAP over HTTP                   (55580)
//
// SAFETY, enforced by code:
//
//   - Every listener binds 127.0.0.1 (`listen_loopback` takes no address).
//   - Every outgoing connection goes to 127.0.0.1 (`sdial_loopback` takes no
//     host): PostgREST and GoTrue on the same machine, nothing else. There
//     is no MX lookup, no DNS, and no SMTP client in this program. Mail for a
//     recipient outside the local domains is refused on the MX port and held,
//     visibly, in the sender's Outbox on the submission paths.

import "core:crypto"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Cfg :: struct {
	rest_port:     int,
	auth_port:     int,
	smtp_port:     int,
	submit_port:   int,
	jmap_port:     int,
	domain:        string,
	jwt_secret:    string,
	service_token: string,
	public_url:    string,
	trace:         bool,
}

cfg: Cfg
log_mu: sync.Mutex

env_int :: proc(name: string, def: int) -> int {
	v := os.get_env(name, context.temp_allocator)
	if n, ok := strconv.parse_int(v, 10); ok {
		return n
	}
	return def
}

load_cfg :: proc() {
	cfg.rest_port = env_int("PALM_REST_PORT", 55521)
	cfg.auth_port = env_int("PALM_AUTH_PORT", 55529)
	cfg.smtp_port = env_int("PALM_SMTP_PORT", 55525)
	cfg.submit_port = env_int("PALM_SUBMIT_PORT", 55587)
	cfg.jmap_port = env_int("PALM_JMAP_PORT", 55580)
	cfg.domain = os.get_env("PALM_MAIL_DOMAIN", context.allocator)
	if cfg.domain == "" {
		cfg.domain = "palm.test"
	}
	cfg.jwt_secret = os.get_env("PALM_JWT_SECRET", context.allocator)
	cfg.public_url = fmt.aprintf("http://127.0.0.1:%d", cfg.jmap_port)
	cfg.trace = os.get_env("PALM_MAIL_TRACE", context.temp_allocator) != ""
}

log_line :: proc(format: string, args: ..any) {
	sync.mutex_lock(&log_mu)
	defer sync.mutex_unlock(&log_mu)
	fmt.eprintf("palm-maild: ")
	fmt.eprintfln(format, ..args)
}

time_now_unix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

new_token_hex :: proc(n: int) -> string {
	buf := make([]u8, n, context.temp_allocator)
	crypto.rand_bytes(buf)
	sb := strings.builder_make(context.temp_allocator)
	for b in buf {
		fmt.sbprintf(&sb, "%02x", b)
	}
	return strings.to_string(sb)
}

main :: proc() {
	load_cfg()
	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(2)
	}
	switch args[0] {
	case "--selftest":
		os.exit(selftest())
	case "serve":
		os.exit(serve())
	case "mint":
		os.exit(cmd_mint(args[1:]))
	case "login":
		if len(args) < 3 {
			usage()
			os.exit(2)
		}
		tok, err := auth_password_grant(args[1], args[2])
		if err != "" {
			fmt.eprintfln("palm-maild: %s", err)
			os.exit(1)
		}
		fmt.println(tok)
	case "summary":
		if len(args) < 2 {
			usage()
			os.exit(2)
		}
		data, err := os.read_entire_file(args[1], context.allocator)
		if err != nil {
			fmt.eprintfln("palm-maild: cannot read %s", args[1])
			os.exit(1)
		}
		fmt.println(summary_meta(summarise(data)))
	case:
		usage()
		os.exit(2)
	}
}

usage :: proc() {
	fmt.eprintln("usage: palm-maild serve | mint --sub UUID [--identity UUID] [--role ROLE] [--ttl S] | login EMAIL PASSWORD | summary FILE | --selftest")
}

cmd_mint :: proc(args: []string) -> int {
	if cfg.jwt_secret == "" {
		fmt.eprintln("palm-maild: PALM_JWT_SECRET is not set")
		return 2
	}
	sub, identity, role := "", "", "authenticated"
	ttl: i64 = 3600
	for i := 0; i < len(args); i += 1 {
		val := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "--sub":
			sub = val
		case "--identity":
			identity = val
		case "--role":
			role = val
		case "--ttl":
			n, _ := strconv.parse_i64(val, 10)
			ttl = n
		case:
			continue
		}
		i += 1
	}
	fmt.println(jwt_mint(cfg.jwt_secret, sub, role, identity, ttl))
	return 0
}

Job :: struct {
	sock: net.TCP_Socket,
	kind: int, // 0 MX, 1 submission, 2 JMAP
}

serve :: proc() -> int {
	if cfg.jwt_secret == "" {
		fmt.eprintln("palm-maild: PALM_JWT_SECRET is not set; source cloud/mail/dev/env.sh")
		return 2
	}
	// The server's own credential for the MX path, minted rather than stored.
	// Long-lived because the server is; it never leaves this process.
	cfg.service_token = jwt_mint(cfg.jwt_secret, "", "service_role", "", 10 * 365 * 86400)

	ports := [3]int{cfg.smtp_port, cfg.submit_port, cfg.jmap_port}
	names := [3]string{"smtp-mx", "submission", "jmap"}
	socks: [3]net.TCP_Socket
	for p, i in ports {
		s, actual, err := listen_loopback(p)
		if err != "" {
			fmt.eprintfln("palm-maild: %s", err)
			return 1
		}
		socks[i] = s
		log_line("%-10s listening on 127.0.0.1:%d", names[i], actual)
	}
	log_line("domain %s, PostgREST :%d, GoTrue :%d; outbound delivery: DISABLED", cfg.domain, cfg.rest_port, cfg.auth_port)

	accept_loop :: proc(a: Job) {
		for {
			client, _, aerr := net.accept_tcp(a.sock)
			if aerr != nil {
				continue
			}
			handle :: proc(j: Job) {
				labels := [3]string{"mx", "submit", "jmap"}
				c := sconn_make(j.sock, labels[j.kind], cfg.trace)
				defer sconn_close(&c)
				switch j.kind {
				case 0:
					smtpd_serve(&c, .MX)
				case 1:
					smtpd_serve(&c, .Submission)
				case 2:
					jmapd_serve(&c)
				}
				free_all(context.temp_allocator)
			}
			thread.create_and_start_with_poly_data(Job{sock = client, kind = a.kind}, handle, self_cleanup = true)
		}
	}
	threads: [3]^thread.Thread
	for i in 0 ..< 3 {
		threads[i] = thread.create_and_start_with_poly_data(Job{sock = socks[i], kind = i}, accept_loop)
	}
	for t in threads {
		thread.join(t)
	}
	return 0
}
