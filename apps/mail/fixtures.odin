// The fixture Maildir generator.
//
// Maildir is a documented standard — `new/`, `cur/`, `tmp/`, one RFC 5322
// message per file, flags in the `:2,S` filename suffix — so the UI can be
// built and tested against a mailbox this app writes itself, long before an
// engine exists to write a real one. Run `mail --fixtures` and the whole tree
// appears under the app's data directory.
//
// The generator is deliberately *mean*: threads six deep, subjects longer than
// any column, unicode names, an HTML-only message with no plain-text part, a
// quoted-printable body, an RFC 2047 encoded subject, a message with no Date
// header at all. Everything the reader has to survive is on disk, which is
// also what lets the self-test assert exact numbers.
//
// It writes three accounts whose shapes differ by protocol: two with a full
// folder tree (IMAP, JMAP) and one with nothing but an inbox (POP3), because
// POP3 defines no mailboxes and the UI must not pretend otherwise.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------------------
// A deterministic generator, so the fixtures are reproducible and the
// self-test can assert counts rather than ranges.
// ---------------------------------------------------------------------------

Rng :: struct {
	s: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	return Rng{s = seed == 0 ? 0x9e3779b97f4a7c15 : seed}
}

rng_next :: proc(r: ^Rng) -> u64 {
	x := r.s
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	r.s = x
	return x
}

rng_int :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

rng_pick :: proc(r: ^Rng, xs: []string) -> string {
	return xs[rng_int(r, len(xs))]
}

// ---------------------------------------------------------------------------
// The cast. Unicode names on purpose: an accented or CJK display name is the
// first thing a hand-rolled header parser gets wrong.
// ---------------------------------------------------------------------------

Person :: struct {
	name:  string,
	email: string,
	// encode says the From header is written as an RFC 2047 encoded word
	// rather than raw UTF-8, which is what a real sender's client does.
	encode: bool,
}

PEOPLE :: [?]Person {
	{"Ada Lovelace", "ada@analytical.test", false},
	{"Grace Hopper", "grace@navy.test", false},
	{"Søren Kierkegaard", "soren@copenhagen.test", true},
	{"Zoë Ngô", "zoe@ngo.test", true},
	{"李雯", "liwen@example.test", true},
	{"Иван Петров", "ivan@pochta.test", true},
	{"José Ramírez", "jose@correo.test", true},
	{"Marie Curie", "marie@radium.test", false},
	{"Ken Thompson", "ken@unix.test", false},
	{"Barbara Liskov", "barbara@substitution.test", false},
	{"Ólafur Arnalds", "olafur@reykjavik.test", true},
	{"Åsa Lindqvist", "asa@stockholm.test", true},
	{"Νίκος Παπαδόπουλος", "nikos@athina.test", true},
	{"Tomasz Kowalczyk", "tomasz@poczta.test", false},
	{"Priya Raghunathan", "priya@example.test", false},
	{"Jean-Luc Péron", "jeanluc@courriel.test", true},
}

SUBJECTS :: [?]string {
	"Deployment window on Thursday",
	"Re-reading the layout spec",
	"Lunch?",
	"Quarterly numbers, with the caveat I mentioned on the call and the revised forecast attached for the regional breakdown",
	"Flexbox: automatic minimum size",
	"Shared-memory buffers and the release protocol",
	"Can we talk about the font metrics",
	"Keyboard layout handling on the new machines",
	"Invoice 2024-0831",
	"Weekend plans",
	"Книга, которую ты просил",
	"Résumé du projet — étape deux",
	"会議の議事録",
	"Paper draft: signed distance fields for rounded rectangles",
	"The scrollbar is one pixel out",
	"Hiring: two more on the rasteriser team",
	"Notes from the compositor working group, including the bits about fractional scaling that nobody wants to implement",
	"Please review before Friday",
	"Travel: Reykjavík, 14–19 March",
	"A question about kerning",
	"Antw: Serverwartung am Wochenende",
	"Fwd: that thing we discussed",
	"Build is red on main",
	"Thanks!",
	"Postmortem: the frame callback deadlock",
	"Design review, round three",
	"Your subscription renews soon",
	"Nested archive test subject",
}

PARAS :: [?]string {
	"I had another look at this over the weekend and I think the approach holds up. The part I am less sure about is what happens when the buffer is released before the frame callback fires — in theory that cannot happen, but in practice I have seen it twice.",
	"Short version: it works. Longer version: it works if you remember to reset the arena, and the reason it looked broken yesterday is that I had not.",
	"Could you send over the numbers again? I think the copy I have is from before the revision and I would rather not quote the wrong figure in front of everyone.",
	"Thanks for picking that up. I have pushed a fix and added a case to the suite so it cannot come back quietly.",
	"The measurement is the interesting bit. Median error went from eleven to about two, which is roughly where glyph antialiasing puts the floor, so there is not a lot left to win there.",
	"Let me know if Thursday still works. I can move things around if it does not, but earlier in the week is easier for me than later.",
	"Attached is the draft. It is long and I am not attached to any particular section, so be as blunt as you like.",
	"One small thing: the subject line on these is getting out of hand and I cannot tell the threads apart in the list any more. Not your fault, just noting it.",
	"I disagree, but not strongly, and I would rather we shipped your version than argued about mine.",
	"On the font question — we load four weights and fall back to the built-in face when a glyph is missing, which is why the CJK text in your message renders as boxes for me. That is a known gap.",
	"Reykjavík was extraordinary. Cold, obviously, but extraordinary. I have photographs I will inflict on you when I am back.",
	"Here is the summary I promised, with the caveats inline rather than in a footnote, because nobody reads footnotes.",
	"We should talk about this properly rather than over mail. Do you have twenty minutes tomorrow?",
	"Confirmed, and thank you for being patient with the back and forth.",
}

SIGNOFFS :: [?]string{"Best,", "Cheers,", "Thanks,", "All the best,", "— "}

// QUALIFIERS widen the subject pool. A real inbox has hundreds of distinct
// subjects, not a couple of dozen repeated; without this every "Lunch?" in the
// fixtures looks like a candidate for the same conversation and the threading
// pass is never honestly exercised.
QUALIFIERS :: [?]string {
	"week 12",
	"second pass",
	"follow-up",
	"with numbers",
	"before the review",
	"take three",
	"revised",
	"for Tuesday",
	"the short version",
	"after the call",
	"and one more thing",
	"final",
	"draft 2",
	"east region",
	"north region",
	"Q3",
	"Q4",
	"2026",
}

// ---------------------------------------------------------------------------
// Writing files
// ---------------------------------------------------------------------------

Fixture_Writer :: struct {
	seq:     int,
	written: int,
}

maildir_make :: proc(path: string) {
	for sub in ([?]string{"cur", "new", "tmp"}) {
		os.make_directory_all(tfmt("%s/%s", path, sub))
	}
}

// write_fixture places a message. Unread mail goes into `new/` with no info
// suffix, which is exactly what Maildir says; everything else goes into `cur/`
// with its flags spelled out in the filename.
write_fixture :: proc(w: ^Fixture_Writer, folder: string, content: string, fl: Flags, when_: time.Time) {
	w.seq += 1
	secs := when_._nsec / 1_000_000_000
	base := fmt.tprintf("%d.M%06dP%d.palmy-fixture", secs, w.seq, os.get_pid())

	path: string
	if fl == {} {
		path = tfmt("%s/new/%s", folder, base)
	} else {
		path = tfmt("%s/cur/%s", folder, maildir_name_with_flags(base, fl, context.temp_allocator))
	}
	if write_file(path, transmute([]u8)content) {
		w.written += 1
	}
}

// ---------------------------------------------------------------------------
// Message bodies
// ---------------------------------------------------------------------------

Fixture_Msg :: struct {
	id:          string,
	in_reply_to: string,
	references:  string,
	from:        Person,
	to:          []Person,
	cc:          []Person,
	subject:     string,
	date:        time.Time,
	body:        string,
	// Shape switches. Each one exists because it is a thing the reader has to
	// cope with and would otherwise never see in a fixture.
	html_only:   bool,
	alternative: bool,
	attachments: []string,
	qp:          bool,
	no_date:     bool,
	no_subject:  bool,
}

render_person :: proc(pp: Person, allocator := context.allocator) -> string {
	if pp.encode {
		return fmt.aprintf(
			"=?utf-8?B?%s?= <%s>",
			encode_base64(transmute([]u8)pp.name, context.temp_allocator),
			pp.email,
			allocator = allocator,
		)
	}
	return fmt.aprintf("%s <%s>", pp.name, pp.email, allocator = allocator)
}

render_people :: proc(ps: []Person, allocator := context.allocator) -> string {
	parts := make([dynamic]string, 0, len(ps), context.temp_allocator)
	for pp in ps {
		append(&parts, render_person(pp, context.temp_allocator))
	}
	return strings.join(parts[:], ", ", allocator)
}

// qp_encode writes a body as quoted-printable, which is how a real message
// with an accented word and a 76-column limit arrives.
qp_encode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	col := 0
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\n' {
			strings.write_string(&b, "\r\n")
			col = 0
			continue
		}
		enc := c >= 0x80 || c == '=' || c < 0x20
		need := enc ? 3 : 1
		if col + need > 73 {
			strings.write_string(&b, "=\r\n")
			col = 0
		}
		if enc {
			strings.write_byte(&b, '=')
			strings.write_byte(&b, HEX[c >> 4])
			strings.write_byte(&b, HEX[c & 15])
			col += 3
		} else {
			strings.write_byte(&b, c)
			col += 1
		}
	}
	return strings.to_string(b)
}

// html_version is the HTML an ordinary newsletter sends: block tags, entities,
// a <style> block, a <script> that must never run and never be fetched, and an
// <img> whose src is dropped on the floor by the text fallback — which is the
// tracking-pixel problem solved by not having a loader at all.
html_version :: proc(subject, body: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "<html><head><style>body{font-family:sans-serif}</style>")
	strings.write_string(&b, "<script>window.track('open')</script></head><body>")
	fmt.sbprintf(&b, "<h1>%s</h1>", subject)
	strings.write_string(&b, "<img src=\"http://tracker.invalid/pixel.gif?id=42\" width=1 height=1>")
	rest := body
	for para in strings.split_iterator(&rest, "\n\n") {
		fmt.sbprintf(&b, "<p>%s</p>", para)
	}
	strings.write_string(
		&b,
		"<ul><li>First&nbsp;item</li><li>Second &amp; third</li><li>Caf&eacute;, 3&nbsp;&euro;</li></ul>",
	)
	strings.write_string(&b, "<blockquote>Quoted &ldquo;inline&rdquo; &mdash; with an em dash.</blockquote>")
	strings.write_string(&b, "<p>Unsubscribe <a href=\"http://lists.invalid/u\">here</a>.</p>")
	strings.write_string(&b, "</body></html>")
	return strings.to_string(b)
}

ATTACH_KINDS :: [?]string {
	"quarterly-forecast.pdf",
	"screenshot.png",
	"notes.txt",
	"résumé.pdf",
	"会議資料.pdf",
	"patch.diff",
	"budget.csv",
}

attachment_mime :: proc(name: string) -> string {
	ext := ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		ext = strings.to_lower(name[dot + 1:], context.temp_allocator)
	}
	switch ext {
	case "pdf":
		return "application/pdf"
	case "png":
		return "image/png"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "txt":
		return "text/plain"
	case "csv":
		return "text/csv"
	case "diff", "patch":
		return "text/x-diff"
	}
	return "application/octet-stream"
}

render_fixture :: proc(m: Fixture_Msg, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	if !m.no_date {
		fmt.sbprintf(&b, "Date: %s\r\n", format_rfc5322_date(m.date, context.temp_allocator))
	}
	fmt.sbprintf(&b, "From: %s\r\n", render_person(m.from, context.temp_allocator))
	fmt.sbprintf(&b, "To: %s\r\n", render_people(m.to, context.temp_allocator))
	if len(m.cc) > 0 {
		fmt.sbprintf(&b, "Cc: %s\r\n", render_people(m.cc, context.temp_allocator))
	}
	if !m.no_subject {
		if is_ascii(m.subject) {
			// A long subject is folded, which is the case an unfolding parser
			// has to get right.
			if len(m.subject) > 60 {
				cut := 48
				for cut < len(m.subject) && m.subject[cut] != ' ' {
					cut += 1
				}
				fmt.sbprintf(&b, "Subject: %s\r\n\t%s\r\n", m.subject[:cut], strings.trim_space(m.subject[cut:]))
			} else {
				fmt.sbprintf(&b, "Subject: %s\r\n", m.subject)
			}
		} else {
			fmt.sbprintf(
				&b,
				"Subject: =?utf-8?B?%s?=\r\n",
				encode_base64(transmute([]u8)m.subject, context.temp_allocator),
			)
		}
	}
	fmt.sbprintf(&b, "Message-ID: <%s>\r\n", m.id)
	if m.in_reply_to != "" {
		fmt.sbprintf(&b, "In-Reply-To: <%s>\r\n", m.in_reply_to)
	}
	if m.references != "" {
		fmt.sbprintf(&b, "References: %s\r\n", m.references)
	}
	strings.write_string(&b, "MIME-Version: 1.0\r\n")

	html := m.html_only || m.alternative \
		? html_version(m.subject, m.body, context.temp_allocator) \
		: ""

	switch {
	case len(m.attachments) > 0:
		boundary := fmt.tprintf("=_mixed_%s", m.id)
		fmt.sbprintf(&b, "Content-Type: multipart/mixed; boundary=\"%s\"\r\n\r\n", boundary)
		strings.write_string(&b, "This is a MIME message. Preamble text is not content.\r\n\r\n")

		fmt.sbprintf(&b, "--%s\r\n", boundary)
		if m.alternative {
			alt := fmt.tprintf("=_alt_%s", m.id)
			fmt.sbprintf(&b, "Content-Type: multipart/alternative; boundary=\"%s\"\r\n\r\n", alt)
			write_text_part(&b, alt, m.body, m.qp)
			write_html_part(&b, alt, html)
			fmt.sbprintf(&b, "--%s--\r\n\r\n", alt)
		} else {
			write_plain_inline(&b, m.body, m.qp)
		}
		for name in m.attachments {
			// The bytes are filler: the reader records the name, the type and
			// the decoded size and never opens them.
			payload := make([dynamic]u8, 0, 1024, context.temp_allocator)
			n := 600 + len(name) * 37
			for i in 0 ..< n {
				append(&payload, u8('A' + i % 26))
			}
			fmt.sbprintf(&b, "--%s\r\n", boundary)
			fmt.sbprintf(&b, "Content-Type: %s; name=\"%s\"\r\n", attachment_mime(name), name)
			fmt.sbprintf(&b, "Content-Disposition: attachment; filename=\"%s\"\r\n", name)
			strings.write_string(&b, "Content-Transfer-Encoding: base64\r\n\r\n")
			enc := encode_base64(payload[:], context.temp_allocator)
			for i := 0; i < len(enc); i += 76 {
				strings.write_string(&b, enc[i:min(i + 76, len(enc))])
				strings.write_string(&b, "\r\n")
			}
			strings.write_string(&b, "\r\n")
		}
		fmt.sbprintf(&b, "--%s--\r\n", boundary)

	case m.html_only:
		// No plain-text part at all: the reader has to fall back.
		strings.write_string(&b, "Content-Type: text/html; charset=utf-8\r\n")
		strings.write_string(&b, "Content-Transfer-Encoding: quoted-printable\r\n\r\n")
		strings.write_string(&b, qp_encode(html, context.temp_allocator))

	case m.alternative:
		boundary := fmt.tprintf("=_alt_%s", m.id)
		fmt.sbprintf(&b, "Content-Type: multipart/alternative; boundary=\"%s\"\r\n\r\n", boundary)
		write_text_part(&b, boundary, m.body, m.qp)
		write_html_part(&b, boundary, html)
		fmt.sbprintf(&b, "--%s--\r\n", boundary)

	case:
		write_plain_inline(&b, m.body, m.qp)
	}

	return strings.to_string(b)
}

@(private = "file")
write_plain_inline :: proc(b: ^strings.Builder, body: string, qp: bool) {
	strings.write_string(b, "Content-Type: text/plain; charset=utf-8\r\n")
	if qp {
		strings.write_string(b, "Content-Transfer-Encoding: quoted-printable\r\n\r\n")
		strings.write_string(b, qp_encode(body, context.temp_allocator))
	} else {
		strings.write_string(b, "Content-Transfer-Encoding: 8bit\r\n\r\n")
		strings.write_string(b, crlf(body, context.temp_allocator))
	}
	strings.write_string(b, "\r\n")
}

@(private = "file")
write_text_part :: proc(b: ^strings.Builder, boundary, body: string, qp: bool) {
	fmt.sbprintf(b, "--%s\r\n", boundary)
	write_plain_inline(b, body, qp)
	strings.write_string(b, "\r\n")
}

@(private = "file")
write_html_part :: proc(b: ^strings.Builder, boundary, html: string) {
	fmt.sbprintf(b, "--%s\r\n", boundary)
	strings.write_string(b, "Content-Type: text/html; charset=utf-8\r\n")
	strings.write_string(b, "Content-Transfer-Encoding: base64\r\n\r\n")
	enc := encode_base64(transmute([]u8)html, context.temp_allocator)
	for i := 0; i < len(enc); i += 76 {
		strings.write_string(b, enc[i:min(i + 76, len(enc))])
		strings.write_string(b, "\r\n")
	}
	strings.write_string(b, "\r\n")
}

crlf :: proc(s: string, allocator := context.allocator) -> string {
	out, _ := strings.replace_all(s, "\n", "\r\n", allocator)
	return out
}

// ---------------------------------------------------------------------------
// The one message shape a reader cannot fake its way through
//
// Everything else in these fixtures is text, and text forgives. This one is
// not: an inline image the message's own HTML points at with a `cid:` URL —
// which must be recognised as part of the message rather than listed as a file
// to save — and a real binary attachment beside it, whose bytes have to come
// back off disk byte for byte.
// ---------------------------------------------------------------------------

// fixture_payload is every byte value once, then a `\r\n\r\n` run and a NUL.
// Those last bytes are the point: a NUL truncates anything that treats the
// buffer as a C string, and a CRLF run is what a text path quietly normalises
// to a bare LF. Bytes that come back equal to this have not been through one.
fixture_payload :: proc(allocator := context.temp_allocator) -> []u8 {
	tail := [?]u8{'\r', '\n', '\r', '\n', 0x00, 0xff}
	out := make([]u8, 256 + len(tail), allocator)
	for i in 0 ..< 256 {
		out[i] = u8(i)
	}
	for b, i in tail {
		out[256 + i] = b
	}
	return out
}

// render_related_fixture builds multipart/related wrapping a plain/html
// alternative, an inline PNG the HTML references, a binary attachment under
// `attach_name`, and one attachment part with no name at all.
//
// The sections come out as the reader will ask for them: 1.1 plain, 1.2 html,
// 2 the inline png, 3 the attachment, 4 the unnamed part.
render_related_fixture :: proc(
	m: Fixture_Msg,
	attach_name: string,
	payload: []u8,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "Date: %s\r\n", format_rfc5322_date(m.date, context.temp_allocator))
	fmt.sbprintf(&b, "From: %s\r\n", render_person(m.from, context.temp_allocator))
	fmt.sbprintf(&b, "To: %s\r\n", render_people(m.to, context.temp_allocator))
	fmt.sbprintf(&b, "Subject: %s\r\n", m.subject)
	fmt.sbprintf(&b, "Message-ID: <%s>\r\n", m.id)
	strings.write_string(&b, "MIME-Version: 1.0\r\n")
	strings.write_string(&b, "Content-Type: multipart/related; type=\"multipart/alternative\"; boundary=\"REL\"\r\n\r\n")

	strings.write_string(&b, "--REL\r\n")
	strings.write_string(&b, "Content-Type: multipart/alternative; boundary=\"ALT\"\r\n\r\n")
	strings.write_string(&b, "--ALT\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n")
	strings.write_string(&b, crlf(m.body, context.temp_allocator))
	strings.write_string(&b, "\r\n--ALT\r\nContent-Type: text/html; charset=utf-8\r\n\r\n")
	fmt.sbprintf(
		&b,
		"<html><body><p><img src=\"cid:logo@fixtures.test\" alt=\"logo\"></p><p>%s</p></body></html>\r\n",
		m.body,
	)
	strings.write_string(&b, "--ALT--\r\n\r\n")

	strings.write_string(&b, "--REL\r\n")
	strings.write_string(&b, "Content-Type: image/png\r\n")
	strings.write_string(&b, "Content-ID: <logo@fixtures.test>\r\n")
	strings.write_string(&b, "Content-Disposition: inline; filename=\"logo.png\"\r\n")
	strings.write_string(&b, "Content-Transfer-Encoding: base64\r\n\r\n")
	strings.write_string(&b, "iVBORw0KGgoAAAANSUhEUg==\r\n")

	strings.write_string(&b, "--REL\r\n")
	strings.write_string(&b, "Content-Type: application/octet-stream\r\n")
	fmt.sbprintf(&b, "Content-Disposition: attachment; filename=\"%s\"\r\n", attach_name)
	strings.write_string(&b, "Content-Transfer-Encoding: base64\r\n\r\n")
	enc := encode_base64(payload, context.temp_allocator)
	for i := 0; i < len(enc); i += 76 {
		strings.write_string(&b, enc[i:min(i + 76, len(enc))])
		strings.write_string(&b, "\r\n")
	}

	strings.write_string(&b, "--REL\r\n")
	strings.write_string(&b, "Content-Type: application/pdf\r\n")
	strings.write_string(&b, "Content-Disposition: attachment\r\n")
	strings.write_string(&b, "Content-Transfer-Encoding: base64\r\n\r\n")
	strings.write_string(&b, "JVBERi0xLjQK\r\n")

	strings.write_string(&b, "--REL--\r\n")
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Generating conversations
// ---------------------------------------------------------------------------

Fixture_Shape :: struct {
	account:   string,
	protocol:  string,
	address:   string,
	port:      int,
	// Folder names relative to the account root, in Maildir++ spelling. The
	// root itself is the inbox.
	folders:   []string,
	threads:   int,
	seed:      u64,
}

FIXTURE_SHAPES :: [?]Fixture_Shape {
	{
		account = "Work",
		protocol = "imap",
		address = "alex@work.test",
		port = 10143,
		folders = {".Sent", ".Drafts", ".Archive", ".Archive.2024", ".Junk", ".Trash"},
		threads = 150,
		seed = 0x51ed270b,
	},
	{
		account = "Personal",
		protocol = "jmap",
		address = "alex@personal.test",
		port = 10843,
		folders = {".Sent", ".Drafts", ".Archive", ".Archive.Travel", ".Trash"},
		threads = 96,
		seed = 0x2545f491,
	},
	{
		// POP3: one inbox, no folders, no server-side flags. The generator
		// writes nothing else, because the protocol has nothing else.
		account = "Newsletters",
		protocol = "pop3",
		address = "alex@lists.test",
		port = 10110,
		folders = {},
		threads = 70,
		seed = 0x9e3779b9,
	},
}

slug_of :: proc(name: string) -> string {
	return strings.to_lower(name, context.temp_allocator)
}

// write_fixtures builds the whole tree. It is additive only in the sense that
// it creates directories; message files are written fresh, and an existing
// fixture tree is removed first so counts stay deterministic.
write_fixtures :: proc(data_dir: string) -> (accounts, folders, messages: int) {
	os.make_directory_all(data_dir)

	// The config that describes them. Loopback only, and said so in the file.
	conf := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&conf,
		"# palmy-mail accounts, written by `mail --fixtures`.\n" +
		"#\n" +
		"# Every host here is loopback. This client reads the Maildir below and\n" +
		"# never opens a socket; host and port are recorded only so the sidebar\n" +
		"# can show which local test server an account belongs to.\n\n",
	)

	shapes := FIXTURE_SHAPES
	for sh in shapes {
		slug := slug_of(sh.account)
		root := tfmt("%s/%s", data_dir, slug)
		remove_tree(root)

		fmt.sbprintf(
			&conf,
			"[account]\nname = %s\nprotocol = %s\naddress = %s\nhost = 127.0.0.1\nport = %d\npath = %s\n\n",
			sh.account,
			sh.protocol,
			sh.address,
			sh.port,
			slug,
		)

		maildir_make(root)
		folders += 1
		for f in sh.folders {
			maildir_make(tfmt("%s/%s", root, f))
			folders += 1
		}

		n := fill_account(root, sh)
		messages += n
		accounts += 1
	}

	// Keep any account block in an existing config that is not one of ours.
	// The engine writes into the same data directory, and a generator that
	// silently deleted someone else's account from the config would be a
	// very annoying thing to debug.
	for block in foreign_accounts(data_dir, shapes[:], context.temp_allocator) {
		strings.write_string(&conf, block)
		strings.write_string(&conf, "\n")
	}

	write_file(
		config_path(data_dir, context.temp_allocator),
		transmute([]u8)strings.to_string(conf),
	)
	// Local flag sidecars from a previous run would pin the old read state
	// onto the new messages.
	for i in 0 ..< len(shapes) {
		os.remove(fmt.tprintf("%s/local-flags-%d.tsv", data_dir, i))
	}
	return
}

// foreign_accounts returns the `[account]` blocks of an existing config whose
// name is not one of the fixture accounts, verbatim, so they survive a
// regeneration.
foreign_accounts :: proc(
	data_dir: string,
	shapes: []Fixture_Shape,
	allocator := context.allocator,
) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	raw, ok := read_file(config_path(data_dir, context.temp_allocator), context.temp_allocator)
	if !ok {
		return out[:]
	}

	block := strings.builder_make(context.temp_allocator)
	name := ""
	flush :: proc(out: ^[dynamic]string, block: ^strings.Builder, name: string, shapes: []Fixture_Shape, allocator: Allocator) {
		if strings.trim_space(strings.to_string(block^)) == "" {
			return
		}
		for sh in shapes {
			if strings.equal_fold(name, sh.account) {
				return
			}
		}
		append(out, strings.clone(strings.to_string(block^), allocator))
	}

	rest := string(raw)
	for {
		line, more := next_line(&rest)
		if !more {
			break
		}
		t := strings.trim_space(line)
		if strings.has_prefix(t, "[") {
			flush(&out, &block, name, shapes, allocator)
			strings.builder_reset(&block)
			name = ""
		}
		if strings.has_prefix(t, "name") {
			if eq := strings.index_byte(t, '='); eq > 0 {
				name = strings.trim_space(t[eq + 1:])
			}
		}
		if t != "" && t[0] != '#' && t[0] != ';' {
			strings.write_string(&block, line)
			strings.write_byte(&block, '\n')
		}
	}
	flush(&out, &block, name, shapes, allocator)
	return out[:]
}

// remove_tree deletes a directory recursively. It refuses anything that is not
// under the app's data directory, because a generator that can be pointed at
// an arbitrary path is a generator that eventually deletes the wrong one.
remove_tree :: proc(path: string) {
	guard := default_data_dir(context.temp_allocator)
	if !strings.has_prefix(path, guard) || len(path) <= len(guard) {
		return
	}
	f, err := os.open(path)
	if err != nil {
		return
	}
	infos, rerr := os.read_dir(f, -1, context.temp_allocator)
	os.close(f)
	if rerr != nil && len(infos) == 0 {
		os.remove(path)
		return
	}
	for info in infos {
		if info.type == .Directory {
			remove_tree(info.fullpath)
		} else {
			os.remove(info.fullpath)
		}
	}
	os.remove(path)
}

fill_account :: proc(root: string, sh: Fixture_Shape) -> int {
	r := rng_make(sh.seed)
	w := Fixture_Writer{}
	people := PEOPLE
	subjects := SUBJECTS
	paras := PARAS
	signs := SIGNOFFS
	pop3 := sh.protocol == "pop3"

	// Spread the conversations over the last ten weeks, newest last, so the
	// relative-date column exercises every branch it has.
	now := time.now()
	span := i64(70) * 86_400 * 1_000_000_000

	me := Person{"Alex", sh.address, false}

	targets := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&targets, root) // the inbox
	for f in sh.folders {
		if f == ".Drafts" || f == ".Trash" || f == ".Junk" {
			continue // these get a handful each, below
		}
		append(&targets, tfmt("%s/%s", root, f))
	}

	for ti in 0 ..< sh.threads {
		// A thread is one to six messages, most of them short, a few deep.
		depth := 1
		switch rng_int(&r, 10) {
		case 0, 1, 2, 3, 4:
			depth = 1
		case 5, 6:
			depth = 2
		case 7:
			depth = 3
		case 8:
			depth = 4
		case:
			depth = 4 + rng_int(&r, 3) // up to six
		}

		quals := QUALIFIERS
		subject := subjects[rng_int(&r, len(subjects))]
		if rng_int(&r, 4) > 0 {
			subject = fmt.tprintf("%s — %s", subject, quals[rng_int(&r, len(quals))])
		}
		starter := people[rng_int(&r, len(people))]
		other := people[rng_int(&r, len(people))]
		for other.email == starter.email {
			other = people[rng_int(&r, len(people))]
		}
		third := people[rng_int(&r, len(people))]

		base := now._nsec - span + i64(ti) * (span / i64(max(1, sh.threads))) -
			i64(rng_int(&r, 36)) * 3600 * 1_000_000_000

		// A thread lives in one folder, the way a conversation does when a
		// client archives it whole. Sent gets our own messages.
		// Weight the inbox heavily. A mail client is judged on its inbox, and
		// a fixture that spreads four hundred messages evenly over a dozen
		// folders never exercises scrolling in any of them.
		folder := rng_int(&r, 100) < 58 ? root : targets[rng_int(&r, len(targets))]
		if pop3 {
			folder = root
		}
		in_sent := strings.has_suffix(folder, ".Sent")

		chain := make([dynamic]string, 0, 8, context.temp_allocator)
		prev_id := ""
		for d in 0 ..< depth {
			id := fmt.tprintf("%s-t%d-m%d@fixtures.test", slug_of(sh.account), ti, d)
			from := starter
			to := []Person{me}
			switch {
			case in_sent:
				from = d % 2 == 0 ? me : starter
				to = d % 2 == 0 ? []Person{starter} : []Person{me}
			case d % 2 == 1:
				from = me
				to = []Person{starter}
			case d > 0:
				from = rng_int(&r, 2) == 0 ? starter : other
			}
			cc: []Person
			if depth >= 3 && d >= 1 {
				cc = []Person{other, third}
			}

			// The body: a couple of paragraphs, a sign-off, and on a reply the
			// quoted parent, because that is what a real thread looks like and
			// it is what the snippet logic has to see through.
			body := strings.builder_make(context.temp_allocator)
			np := 1 + rng_int(&r, 2)
			for k in 0 ..< np {
				if k > 0 {
					strings.write_string(&body, "\n\n")
				}
				strings.write_string(&body, paras[rng_int(&r, len(paras))])
			}
			fmt.sbprintf(&body, "\n\n%s\n%s\n", signs[rng_int(&r, len(signs))], addr_label({from.name, from.email}))
			if d > 0 {
				fmt.sbprintf(
					&body,
					"\n> On an earlier day, %s wrote:\n> %s\n",
					starter.name,
					paras[rng_int(&r, len(paras))],
				)
			}

			fm := Fixture_Msg {
				id          = id,
				in_reply_to = prev_id,
				references  = len(chain) > 0 ? strings.join(chain[:], " ", context.temp_allocator) : "",
				from        = from,
				to          = to,
				cc          = cc,
				subject     = d == 0 ? subject : fmt.tprintf("Re: %s", subject),
				date        = time.Time{_nsec = base + i64(d) * 5 * 3600 * 1_000_000_000},
				body        = strings.to_string(body),
			}

			// Shapes, sprinkled deterministically.
			kinds := ATTACH_KINDS
			switch rng_int(&r, 14) {
			case 0:
				fm.attachments = []string {
					kinds[rng_int(&r, len(kinds))],
					kinds[rng_int(&r, len(kinds))],
				}
			case 1:
				fm.attachments = []string{kinds[rng_int(&r, len(kinds))]}
			case 2:
				fm.alternative = true
			case 3:
				fm.qp = true
			}

			fl: Flags
			if in_sent {
				fl = {.Seen}
			} else {
				switch rng_int(&r, 10) {
				case 0, 1, 2:
					fl = {} // unread, so it lands in new/
				case 3:
					fl = {.Seen, .Flagged}
				case 4:
					fl = {.Seen, .Answered}
				case 5:
					fl = {.Flagged} // flagged and unread
				case:
					fl = {.Seen}
				}
			}
			// A thread's earlier messages are read; only the tail is new.
			if d < depth - 1 && fl == {} {
				fl = {.Seen}
			}

			content := render_fixture(fm, context.temp_allocator)
			write_fixture(&w, folder, content, fl, fm.date)

			append(&chain, fmt.tprintf("<%s>", id))
			prev_id = id
		}
	}

	// The awkward ones, placed explicitly so they are always present and the
	// self-test can look for them by name rather than by luck.
	inbox := root
	specials := 0

	// 1. HTML only, no plain-text part — the text fallback's whole reason to
	//    exist, complete with a tracking pixel that can never be fetched.
	{
		fm := Fixture_Msg {
			id = fmt.tprintf("%s-html-only@fixtures.test", slug_of(sh.account)),
			from = Person{"Reykjavík Letters", "post@reykjavik.test", true},
			to = []Person{me},
			subject = "Þetta er aðeins HTML — no plain part",
			date = time.Time{_nsec = now._nsec - 3 * 86_400 * 1_000_000_000},
			body = "Hello from a sender that only ever sends HTML.\n\nThe second paragraph.",
			html_only = true,
		}
		write_fixture(&w, inbox, render_fixture(fm, context.temp_allocator), {}, fm.date)
		specials += 1
	}

	// 2. A second HTML-only one, read, so the list shows both states.
	{
		fm := Fixture_Msg {
			id = fmt.tprintf("%s-html-only-2@fixtures.test", slug_of(sh.account)),
			from = Person{"Weekly Digest", "digest@lists.test", false},
			to = []Person{me},
			subject = "Your weekly digest",
			date = time.Time{_nsec = now._nsec - 9 * 86_400 * 1_000_000_000},
			body = "Three things happened this week.\n\nHere they are.",
			html_only = true,
		}
		write_fixture(&w, inbox, render_fixture(fm, context.temp_allocator), {.Seen}, fm.date)
		specials += 1
	}

	// 3. No Subject and no Date header.
	{
		fm := Fixture_Msg {
			id = fmt.tprintf("%s-bare@fixtures.test", slug_of(sh.account)),
			from = Person{"", "anonymous@nowhere.test", false},
			to = []Person{me},
			subject = "",
			body = "No subject, no date, no display name. A reader still has to show something sensible.",
			no_subject = true,
			no_date = true,
			date = time.Time{_nsec = now._nsec - 11 * 86_400 * 1_000_000_000},
		}
		write_fixture(&w, inbox, render_fixture(fm, context.temp_allocator), {}, fm.date)
		specials += 1
	}

	// 4. A quoted-printable body full of accents, flagged.
	{
		fm := Fixture_Msg {
			id = fmt.tprintf("%s-qp@fixtures.test", slug_of(sh.account)),
			from = Person{"Jean-Luc Péron", "jeanluc@courriel.test", true},
			to = []Person{me},
			subject = "Résumé du projet — étape deux",
			date = time.Time{_nsec = now._nsec - 2 * 86_400 * 1_000_000_000},
			body = "Bonjour,\n\nVoici le résumé de l'étape deux. Les mesures sont à peu près stables : l'écart médian est passé de onze à deux, ce qui est très satisfaisant.\n\nÀ bientôt,\nJean-Luc",
			qp = true,
		}
		write_fixture(&w, inbox, render_fixture(fm, context.temp_allocator), {.Flagged}, fm.date)
		specials += 1
	}

	// 5. A message with five attachments, so the attachment list has to wrap.
	{
		kinds := ATTACH_KINDS
		fm := Fixture_Msg {
			id = fmt.tprintf("%s-attach@fixtures.test", slug_of(sh.account)),
			from = Person{"李雯", "liwen@example.test", true},
			to = []Person{me},
			cc = []Person{{"Grace Hopper", "grace@navy.test", false}},
			subject = "会議資料をお送りします",
			date = time.Time{_nsec = now._nsec - 86_400 * 1_000_000_000},
			body = "お世話になっております。\n\n会議の資料を添付いたします。ご確認ください。\n\n李",
			attachments = kinds[:5],
			alternative = true,
		}
		write_fixture(&w, inbox, render_fixture(fm, context.temp_allocator), {}, fm.date)
		specials += 1
	}

	// 5b. An inline image the HTML points at, plus a real binary attachment.
	//     This is the message the reader's attachment list is judged on: the
	//     logo must not be offered as a file, and `measurements.bin` must come
	//     back off disk byte for byte, NUL and CRLF run intact.
	{
		fm := Fixture_Msg {
			id = fmt.tprintf("%s-inline@fixtures.test", slug_of(sh.account)),
			from = Person{"Grace Hopper", "grace@navy.test", false},
			to = []Person{me},
			subject = "Instrument trace, raw",
			date = time.Time{_nsec = now._nsec - 3 * 3600 * 1_000_000_000},
			body = "The trace came off the logger unmodified. Do not open it in an editor; it is not text.\n\nThe banner above is inline, not an attachment.",
		}
		write_fixture(
			&w,
			inbox,
			render_related_fixture(fm, "measurements.bin", fixture_payload(), context.temp_allocator),
			{},
			fm.date,
		)
		specials += 1
	}

	// 6. An orphaned reply: a client that answered without writing In-Reply-To
	//    or References, which is the one case the subject fallback exists for.
	{
		fm := Fixture_Msg {
			id = fmt.tprintf("%s-orphan-root@fixtures.test", slug_of(sh.account)),
			from = Person{"Marie Curie", "marie@radium.test", false},
			to = []Person{me},
			subject = "The polonium order never arrived",
			date = time.Time{_nsec = now._nsec - 6 * 86_400 * 1_000_000_000},
			body = "It was due on Tuesday and there is no sign of it. Could you chase the supplier?",
		}
		write_fixture(&w, inbox, render_fixture(fm, context.temp_allocator), {.Seen}, fm.date)
		orphan := Fixture_Msg {
			id = fmt.tprintf("%s-orphan-reply@fixtures.test", slug_of(sh.account)),
			from = me,
			to = []Person{{"Marie Curie", "marie@radium.test", false}},
			// No In-Reply-To, no References. Only the subject says where this
			// belongs, which is exactly the broken-client case.
			subject = "Re: The polonium order never arrived",
			date = time.Time{_nsec = now._nsec - 5 * 86_400 * 1_000_000_000},
			body = "Chased. They say Thursday, and they have said Thursday before.",
		}
		write_fixture(&w, inbox, render_fixture(orphan, context.temp_allocator), {.Seen}, orphan.date)
		specials += 2
	}

	if !pop3 {
		// Drafts, Junk and Trash get a few each so the folders are not empty
		// and the unread counts differ between them.
		for name, k in ([?]string{".Drafts", ".Junk", ".Trash"}) {
			dir := tfmt("%s/%s", root, name)
			if !os.is_dir(dir) {
				continue
			}
			for i in 0 ..< 4 + k {
				pp := people[rng_int(&r, len(people))]
				fm := Fixture_Msg {
					id = fmt.tprintf("%s-%s-%d@fixtures.test", slug_of(sh.account), name[1:], i),
					from = name == ".Drafts" ? me : pp,
					to = name == ".Drafts" ? []Person{pp} : []Person{me},
					subject = name == ".Junk" \
					? "You have won a prize" \
					: tfmt("%s (%d)", subjects[rng_int(&r, len(subjects))], i + 1),
					date = time.Time{_nsec = now._nsec - i64(i + k * 3) * 86_400 * 1_000_000_000},
					body = paras[rng_int(&r, len(paras))],
				}
				fl: Flags = name == ".Drafts" ? {.Draft, .Seen} : {.Seen}
				if name == ".Junk" && i % 2 == 0 {
					fl = {}
				}
				write_fixture(&w, dir, render_fixture(fm, context.temp_allocator), fl, fm.date)
				specials += 1
			}
		}
	}

	return w.written
}

// run_fixtures is the `--fixtures` entry point.
run_fixtures :: proc() -> int {
	dir := default_data_dir(context.temp_allocator)
	accounts, folders, messages := write_fixtures(dir)
	fmt.printfln("mail: wrote %d messages in %d folders across %d accounts", messages, folders, accounts)
	fmt.printfln("mail: %s", dir)
	fmt.printfln("mail: config %s", config_path(dir, context.temp_allocator))
	return 0
}
