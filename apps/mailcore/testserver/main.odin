package main

// The mailcore test server: IMAP, POP3, SMTP and a JMAP HTTP endpoint over one
// shared, seeded, entirely synthetic mailbox.
//
//	testserver [--imap N] [--pop3 N] [--smtp N] [--jmap N] [--trace]
//	           [--host 127.0.0.1] [--ports-file PATH] [--once]
//
// A port of 0 asks the kernel for a free one, and the chosen ports are printed
// (and written to --ports-file) so a test harness never has to guess or
// collide. Binding is always 127.0.0.1: `listen_loopback` takes no other
// address, so this server cannot be exposed to a network even by accident.
//
// ACCOUNTS AND PASSWORDS. Two accounts, with passwords invented here and used
// nowhere else on this machine or anywhere:
//
//	alice@localhost / alice   password: loopback-only-7a3f
//	bob@localhost   / bob     password: loopback-only-c91d
//
// Nothing in this program reads the user's mail, contacts a real host, or
// resolves a name. SMTP accepts mail only for those two synthetic addresses
// and relays nowhere; a message accepted over SMTP is put in a Go map in this
// process's memory and nothing else happens to it.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

Cfg :: struct {
	host:       string,
	imap_port:  int,
	pop3_port:  int,
	smtp_port:  int,
	jmap_port:  int,
	trace:      bool,
	ports_file: string,
	once:       bool,
}

cfg: Cfg

ALICE_PASSWORD :: "loopback-only-7a3f"
BOB_PASSWORD :: "loopback-only-c91d"

main :: proc() {
	cfg = Cfg {
		host      = "127.0.0.1",
		imap_port = 0,
		pop3_port = 0,
		smtp_port = 0,
		jmap_port = 0,
	}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next :: proc(args: []string, i: ^int) -> string {
			i^ += 1
			return i^ < len(args) ? args[i^] : ""
		}
		switch args[i] {
		case "--imap":
			cfg.imap_port = atoi(next(args, &i))
		case "--pop3":
			cfg.pop3_port = atoi(next(args, &i))
		case "--smtp":
			cfg.smtp_port = atoi(next(args, &i))
		case "--jmap":
			cfg.jmap_port = atoi(next(args, &i))
		case "--host":
			cfg.host = next(args, &i)
		case "--ports-file":
			cfg.ports_file = next(args, &i)
		case "--trace":
			cfg.trace = true
		case "--once":
			cfg.once = true
		case "-h", "--help":
			fmt.println(
				"testserver [--imap N] [--pop3 N] [--smtp N] [--jmap N] [--host 127.0.0.1]\n" +
				"           [--ports-file PATH] [--trace] [--once]\n" +
				"\n" +
				"A synthetic IMAP/POP3/SMTP/JMAP server on loopback. Port 0 = pick one.",
			)
			return
		case:
			fmt.eprintfln("testserver: unknown argument %q", args[i])
			os.exit(2)
		}
	}
	if cfg.host != "127.0.0.1" && cfg.host != "localhost" {
		fmt.eprintfln(
			"testserver: refusing to bind %q; this server is loopback-only by construction",
			cfg.host,
		)
		os.exit(2)
	}

	seed_accounts()

	imap_l, imap_p, e1 := listen_loopback(cfg.imap_port)
	if e1 != "" {fmt.eprintfln("testserver: imap: %s", e1);os.exit(1)}
	pop3_l, pop3_p, e2 := listen_loopback(cfg.pop3_port)
	if e2 != "" {fmt.eprintfln("testserver: pop3: %s", e2);os.exit(1)}
	smtp_l, smtp_p, e3 := listen_loopback(cfg.smtp_port)
	if e3 != "" {fmt.eprintfln("testserver: smtp: %s", e3);os.exit(1)}
	jmap_l, jmap_p, e4 := listen_loopback(cfg.jmap_port)
	if e4 != "" {fmt.eprintfln("testserver: jmap: %s", e4);os.exit(1)}

	// Printed on one line each, in a shape a harness can parse, and flushed
	// immediately: a client that starts this process waits for these lines.
	fmt.printfln("PORT imap %d", imap_p)
	fmt.printfln("PORT pop3 %d", pop3_p)
	fmt.printfln("PORT smtp %d", smtp_p)
	fmt.printfln("PORT jmap %d", jmap_p)
	total := 0
	for a in store.accounts {
		for b in a.boxes {
			total += len(b.msgs)
		}
	}
	fmt.printfln("READY %d accounts, %d synthetic messages", len(store.accounts), total)
	os.flush(os.stdout)

	if cfg.ports_file != "" {
		sb := strings.builder_make()
		fmt.sbprintfln(&sb, "imap %d", imap_p)
		fmt.sbprintfln(&sb, "pop3 %d", pop3_p)
		fmt.sbprintfln(&sb, "smtp %d", smtp_p)
		fmt.sbprintfln(&sb, "jmap %d", jmap_p)
		if werr := os.write_entire_file(cfg.ports_file, transmute([]u8)strings.to_string(sb));
		   werr != nil {
			fmt.eprintfln("testserver: cannot write %s: %v", cfg.ports_file, werr)
		}
	}

	// One accept thread per protocol, one handler thread per connection. The
	// store is shared behind `store.mu`, which is what makes "send over SMTP,
	// see it over IMAP on another connection" work — and what lets IDLE be a
	// real IDLE rather than a sleep.
	Acceptor :: struct {
		sock:  net.TCP_Socket,
		kind:  int, // 0 imap, 1 pop3, 2 smtp, 3 jmap
		port:  int,
	}
	accept_loop :: proc(acc: Acceptor) {
		for {
			client, _, aerr := net.accept_tcp(acc.sock)
			if aerr != nil {
				return
			}
			Job :: struct {
				sock: net.TCP_Socket,
				kind: int,
				port: int,
			}
			handle :: proc(j: Job) {
				labels := [4]string{"imapd", "pop3d", "smtpd", "jmapd"}
				c := sconn_make(j.sock, labels[j.kind], cfg.trace)
				defer sconn_close(&c)
				switch j.kind {
				case 0:
					imap_serve(&c)
				case 1:
					pop3_serve(&c)
				case 2:
					smtpd_serve(&c)
				case 3:
					jmapd_serve(&c, cfg.host, j.port)
				}
			}
			t := thread.create_and_start_with_poly_data(
				Job{sock = client, kind = acc.kind, port = acc.port},
				handle,
				self_cleanup = true,
			)
			_ = t
			if cfg.once {
				return
			}
		}
	}

	threads := [4]^thread.Thread{}
	threads[0] = thread.create_and_start_with_poly_data(
		Acceptor{sock = imap_l, kind = 0, port = imap_p},
		accept_loop,
	)
	threads[1] = thread.create_and_start_with_poly_data(
		Acceptor{sock = pop3_l, kind = 1, port = pop3_p},
		accept_loop,
	)
	threads[2] = thread.create_and_start_with_poly_data(
		Acceptor{sock = smtp_l, kind = 2, port = smtp_p},
		accept_loop,
	)
	threads[3] = thread.create_and_start_with_poly_data(
		Acceptor{sock = jmap_l, kind = 3, port = jmap_p},
		accept_loop,
	)
	for t in threads {
		if t != nil {
			thread.join(t)
		}
	}
}

atoi :: proc(s: string) -> int {
	n, _ := strconv.parse_int(strings.trim_space(s), 10)
	return n
}

// ---------------------------------------------------------------------------
// Seeding
// ---------------------------------------------------------------------------

// seed_accounts builds the two synthetic accounts and loads the corpus.
//
// The folder set is the same for both accounts so that every protocol has the
// same shape to describe: INBOX, Archive, Sent, Trash, Drafts, and one nested
// folder (Lists.odin) so the IMAP hierarchy delimiter and the Maildir++ dotted
// name both get exercised.
seed_accounts :: proc() {
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	store.accounts = make([dynamic]Account, 0, 2)

	make_account :: proc(user, password, email: string) -> Account {
		a := Account {
			user     = user,
			password = password,
			email    = email,
			boxes    = make([dynamic]Mailbox, 0, 8),
			changes  = make([dynamic]Change, 0, 64),
		}
		specs := [?][2]string {
			{"INBOX", "inbox"},
			{"Archive", "archive"},
			{"Sent", "sent"},
			{"Drafts", "drafts"},
			{"Trash", "trash"},
			{"Lists", ""},
			{"Lists.odin", ""},
		}
		for s, i in specs {
			parent := ""
			if dot := strings.last_index_byte(s[0], '.'); dot >= 0 {
				parent = fmt.aprintf("MB-%s-%s", user, s[0][:dot])
			}
			append(
				&a.boxes,
				Mailbox {
					name = strings.clone(s[0]),
					jid = fmt.aprintf("MB-%s-%s", user, s[0]),
					role = strings.clone(s[1]),
					parent_jid = parent,
					uidnext = 1,
					uidvalidity = u32(10_000 + i),
					msgs = make([dynamic]Message, 0, 32),
				},
			)
		}
		return a
	}

	append(&store.accounts, make_account("alice", ALICE_PASSWORD, "alice@localhost"))
	append(&store.accounts, make_account("bob", BOB_PASSWORD, "bob@localhost"))

	alice := &store.accounts[0]
	for e in CORPUS {
		folder := e.folder
		// The threaded conversation goes into the nested list folder as well
		// as INBOX, so a folder walk has something non-trivial to find and
		// POP3's INBOX-only view is visibly narrower.
		raw := to_crlf(e.raw_lf)
		b := account_box(alice, folder)
		if b == nil {
			continue
		}
		store_deliver(alice, b, raw, e.flags, corpus_decomp(e))
		if strings.has_prefix(e.name, "thread-") {
			lb := account_box(alice, "Lists.odin")
			if lb != nil {
				copy_raw := make([]u8, len(raw))
				copy(copy_raw, raw)
				store_deliver(alice, lb, copy_raw, e.flags, corpus_decomp(e))
			}
		}
	}
	// Bob gets one message so his account is not empty.
	bob := &store.accounts[1]
	if b := account_box(bob, "INBOX"); b != nil {
		raw := to_crlf(
			"Date: Tue, 3 Feb 2026 21:00:00 +0000\n" +
			"From: Alice Loopback <alice@localhost>\n" +
			"To: Bob Loopback <bob@localhost>\n" +
			"Subject: Hello Bob\n" +
			"Message-ID: <bob-0001@localhost>\n" +
			"MIME-Version: 1.0\n" +
			"Content-Type: text/plain; charset=us-ascii\n" +
			"\n" +
			"One message, so Bob's account is not empty.\n",
		)
		store_deliver(bob, b, raw, {}, mm_derive_decomp(raw, 1770152400))
	}

	// \Recent is "no client has seen this since the last session". The seeded
	// corpus has been in the mailbox since before any client connected, so it
	// is cleared here; only mail that arrives during a run is Recent.
	for i in 0 ..< len(store.accounts) {
		for k in 0 ..< len(store.accounts[i].boxes) {
			for j in 0 ..< len(store.accounts[i].boxes[k].msgs) {
				store.accounts[i].boxes[k].msgs[j].flags &~= {.Recent}
			}
		}
	}
}
