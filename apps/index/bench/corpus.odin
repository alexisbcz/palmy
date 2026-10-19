// A deterministic, realistic-shaped corpus for the benchmark: the same seed
// gives the same documents on every machine, so the numbers in
// cloud/docs/search.md can be reproduced.
//
// Shape, taken from what a working inbox looks like rather than invented
// uniformly: word frequencies follow Zipf's law over a 55k-word vocabulary
// (common English words first), mail bodies are log-normally long (median
// about 90 words, a tail past 2,000), subjects are short, a few hundred
// correspondents write most of the mail, file names look like file names,
// and timestamps spread over three years with more recent than old.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import ic "../core"

Rng :: struct {
	s: u64,
}

next :: proc(r: ^Rng) -> u64 {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return r.s
}

unit :: proc(r: ^Rng) -> f64 {
	return f64(next(r) >> 11) / f64(1 << 53)
}

below :: proc(r: ^Rng, n: int) -> int {
	return int(next(r) % u64(max(n, 1)))
}

COMMON := [?]string {
	"the", "of", "and", "to", "a", "in", "is", "it", "you", "that", "he", "was", "for", "on", "are", "with",
	"as", "i", "his", "they", "be", "at", "one", "have", "this", "from", "or", "had", "by", "not", "but",
	"what", "all", "were", "we", "when", "your", "can", "said", "there", "use", "an", "each", "which",
	"she", "do", "how", "their", "if", "will", "up", "other", "about", "out", "many", "then", "them",
	"these", "so", "some", "her", "would", "make", "like", "him", "into", "time", "has", "look", "two",
	"more", "write", "go", "see", "number", "no", "way", "could", "people", "my", "than", "first",
	"been", "call", "who", "its", "now", "find", "long", "down", "day", "did", "get", "come", "made",
	"may", "part", "meeting", "thanks", "please", "review", "project", "update", "next", "week",
	"team", "budget", "draft", "contract", "release", "schedule", "invoice", "report", "plan",
	"question", "attached", "today", "tomorrow", "monday", "friday", "call", "notes", "design",
	"customer", "data", "offline", "sync", "server", "deadline", "launch", "quarter", "numbers",
}

FIRST := [?]string {
	"Priya", "Jonas", "Mei", "Ines", "Théo", "Amara", "Lukas", "Sofia", "Noah", "Yuki", "Omar", "Elena",
	"Mateo", "Chloé", "Arjun", "Hana", "Felix", "Zoé", "Ravi", "Leila", "Marco", "Anaïs", "Kenji", "Nadia",
	"Oscar", "Lina", "Tomás", "Aiko", "Samir", "Greta", "Diego", "Maëlle", "Ivan", "Fatima", "Hugo", "Sara",
}
LAST := [?]string {
	"Shah", "Weber", "Tanaka", "Roux", "Martin", "Okafor", "Becker", "Rossi", "Kim", "Sato", "Haddad",
	"Novak", "García", "Dubois", "Iyer", "Lindqvist", "Moreau", "Costa", "Petrov", "Mensah", "Nguyen",
	"Fischer", "Bernard", "Kowalski", "Silva", "Andersen", "Lefèvre", "Mori", "Popescu", "Schmidt",
}

EXT := [?]string{".pdf", ".docx", ".xlsx", ".pptx", ".md", ".png", ".jpg", ".zip", ".csv", ".txt", ".odt"}

Corpus :: struct {
	vocab: [dynamic]string,
	cdf:   [dynamic]f64, // Zipf cumulative
	people: [dynamic]string,
	pcdf:  [dynamic]f64,
	rng:   Rng,
	now:   i64,
}

corpus_init :: proc(c: ^Corpus, seed: u64, now: i64) {
	c.rng = Rng{seed | 1}
	c.now = now
	for w in COMMON {
		append(&c.vocab, w)
	}
	data, err := os.read_entire_file_from_path("/usr/share/dict/cracklib-small", context.allocator)
	words := make([dynamic]string)
	if err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if len(line) >= 3 && !strings.contains(line, "'") {
				append(&words, line)
			}
		}
	} else {
		// Synthetic words when no dictionary is installed: syllables.
		syl := [?]string{"ka", "ro", "mi", "ten", "lo", "sa", "vin", "de", "ra", "po", "ne", "tu", "ga", "shi", "bel"}
		for i in 0 ..< 50000 {
			b := strings.builder_make()
			n := 2 + i % 3
			x := i
			for _ in 0 ..< n {
				strings.write_string(&b, syl[x % len(syl)])
				x = x / len(syl) + i * 7
			}
			append(&words, strings.to_string(b))
		}
	}
	// Deterministic shuffle so frequency is not alphabetical.
	for i := len(words) - 1; i > 0; i -= 1 {
		j := below(&c.rng, i + 1)
		words[i], words[j] = words[j], words[i]
	}
	append(&c.vocab, ..words[:])
	// Zipf with s = 1.07 over the ranks.
	total := 0.0
	for i in 0 ..< len(c.vocab) {
		total += 1 / math.pow(f64(i + 1), 1.07)
		append(&c.cdf, total)
	}
	for &x in c.cdf {
		x /= total
	}
	// Correspondents: a few write most of the mail.
	for i in 0 ..< 400 {
		f := FIRST[below(&c.rng, len(FIRST))]
		l := LAST[below(&c.rng, len(LAST))]
		append(&c.people, fmt.aprintf("%s %s", f, l))
	}
	t := 0.0
	for i in 0 ..< len(c.people) {
		t += 1 / math.pow(f64(i + 1), 0.9)
		append(&c.pcdf, t)
	}
	for &x in c.pcdf {
		x /= t
	}
}

pick :: proc(cdf: []f64, u: f64) -> int {
	lo, hi := 0, len(cdf) - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if cdf[mid] < u {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

word :: proc(c: ^Corpus) -> string {
	return c.vocab[pick(c.cdf[:], unit(&c.rng))]
}

person :: proc(c: ^Corpus) -> string {
	return c.people[pick(c.pcdf[:], unit(&c.rng))]
}

sentence :: proc(c: ^Corpus, b: ^strings.Builder, n: int) {
	for i in 0 ..< n {
		if i > 0 {
			strings.write_byte(b, ' ')
		}
		w := word(c)
		if i == 0 && len(w) > 0 {
			strings.write_string(b, strings.to_upper(w[:1], context.temp_allocator))
			strings.write_string(b, w[1:])
		} else {
			strings.write_string(b, w)
		}
	}
	strings.write_string(b, ". ")
}

lognormal :: proc(c: ^Corpus, median, sigma: f64) -> int {
	// Box–Muller
	u1 := max(unit(&c.rng), 1e-12)
	u2 := unit(&c.rng)
	z := math.sqrt(-2 * math.ln(u1)) * math.cos(2 * math.PI * u2)
	return max(1, int(median * math.exp(sigma * z)))
}

// when spreads times over three years, recent ones denser.
when_ :: proc(c: ^Corpus) -> i64 {
	u := unit(&c.rng)
	days := 1095 * u * u
	return c.now - i64(days * 86400) - i64(below(&c.rng, 86400))
}

// noise is what makes a real dictionary large: order and invoice numbers,
// dates, amounts, links, tracking codes. Real mail has hundreds of
// thousands of such one-off terms; without them a dictionary benchmark
// flatters whatever scans the dictionary (typo tolerance, prefixes).
noise :: proc(c: ^Corpus, b: ^strings.Builder) {
	switch below(&c.rng, 7) {
	case 0:
		fmt.sbprintf(b, "INV-%d ", 10000 + below(&c.rng, 900000))
	case 1:
		fmt.sbprintf(b, "%d-%02d-%02d ", 2023 + below(&c.rng, 4), 1 + below(&c.rng, 12), 1 + below(&c.rng, 28))
	case 2:
		fmt.sbprintf(b, "€%d.%02d ", below(&c.rng, 20000), below(&c.rng, 100))
	case 3:
		fmt.sbprintf(b, "https://%s.example/%s/%x ", word(c), word(c), next(&c.rng) & 0xffffff)
	case 4:
		fmt.sbprintf(b, "#%d ", below(&c.rng, 5000))
	case 5:
		fmt.sbprintf(b, "%c%c%d%c%c ", 'A' + rune(below(&c.rng, 26)), 'A' + rune(below(&c.rng, 26)), below(&c.rng, 100000000), 'A' + rune(below(&c.rng, 26)), 'A' + rune(below(&c.rng, 26)))
	case 6:
		fmt.sbprintf(b, "+33 6 %02d %02d %02d %02d ", below(&c.rng, 100), below(&c.rng, 100), below(&c.rng, 100), below(&c.rng, 100))
	}
}

text_of :: proc(c: ^Corpus, words: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	left := words
	for left > 0 {
		n := min(left, 6 + below(&c.rng, 14))
		sentence(c, &b, n)
		if below(&c.rng, 4) == 0 {
			noise(c, &b)
		}
		left -= n
		if below(&c.rng, 6) == 0 {
			strings.write_string(&b, "\n\n")
		}
	}
	return strings.to_string(b)
}

make_mail :: proc(c: ^Corpus, i: int) -> ic.Doc {
	from := person(c)
	sb := strings.builder_make()
	if below(&c.rng, 3) == 0 {
		strings.write_string(&sb, "Re: ")
	}
	sentence(c, &sb, 3 + below(&c.rng, 6))
	subj := strings.trim_right(strings.to_string(sb), ". ")
	body := text_of(c, lognormal(c, 90, 1.0))
	flags: ic.Flags
	t := when_(c)
	if c.now - t < 14 * 86400 && below(&c.rng, 3) == 0 {
		flags += {.Unread}
	}
	if below(&c.rng, 8) == 0 {
		flags += {.Attachment}
	}
	return ic.Doc {
		key = fmt.aprintf("mail:%08d", i),
		kind = .Mail,
		flags = flags,
		time = t,
		sig = u64(i),
		title = subj,
		who = fmt.aprintf("%s %s@example.org", from, strings.to_lower(strings.split(from, " ", context.temp_allocator)[0], context.temp_allocator)),
		body = body,
		detail = "INBOX",
		uri = fmt.aprintf("palm://bench/mail/%08d", i),
		app = "mail",
	}
}

make_file :: proc(c: ^Corpus, i: int) -> ic.Doc {
	sb := strings.builder_make()
	n := 1 + below(&c.rng, 4)
	for k in 0 ..< n {
		if k > 0 {
			strings.write_byte(&sb, below(&c.rng, 2) == 0 ? '-' : ' ')
		}
		strings.write_string(&sb, word(c))
	}
	ext := EXT[below(&c.rng, len(EXT))]
	strings.write_string(&sb, ext)
	name := strings.to_string(sb)
	body := ""
	switch ext {
	case ".docx", ".odt", ".md", ".txt", ".pdf", ".xlsx", ".pptx", ".csv":
		body = text_of(c, lognormal(c, 300, 1.2))
	}
	folder := fmt.aprintf("%s/%s", word(c), word(c))
	return ic.Doc {
		key = fmt.aprintf("file:%s/%s", folder, name),
		kind = ext == ".docx" || ext == ".odt" || ext == ".xlsx" || ext == ".pptx" ? .Doc : .File,
		time = when_(c),
		sig = u64(i),
		title = name,
		who = person(c),
		body = body,
		detail = folder,
		uri = fmt.aprintf("/home/bench/Drive/bench/%s/%s", folder, name),
		app = "files",
	}
}

make_note :: proc(c: ^Corpus, i: int) -> ic.Doc {
	sb := strings.builder_make()
	sentence(c, &sb, 2 + below(&c.rng, 4))
	title := strings.trim_right(strings.to_string(sb), ". ")
	return ic.Doc {
		key = fmt.aprintf("note:%06d", i),
		kind = .Note,
		time = when_(c),
		sig = u64(i),
		title = title,
		body = text_of(c, lognormal(c, 200, 1.0)),
		detail = "Notes",
		uri = fmt.aprintf("/home/bench/notes/%06d.md", i),
		app = "notes",
	}
}

make_event :: proc(c: ^Corpus, i: int) -> ic.Doc {
	sb := strings.builder_make()
	sentence(c, &sb, 2 + below(&c.rng, 4))
	return ic.Doc {
		key = fmt.aprintf("event:%06d", i),
		kind = .Event,
		time = c.now + i64(below(&c.rng, 200 * 86400)) - 100 * 86400,
		dur = i32(30 * (1 + below(&c.rng, 4))),
		sig = u64(i),
		title = strings.trim_right(strings.to_string(sb), ". "),
		who = person(c),
		body = text_of(c, below(&c.rng, 40)),
		detail = word(c),
		uri = fmt.aprintf("palm://bench/event/%06d", i),
		app = "calendar",
	}
}

make_person :: proc(c: ^Corpus, i: int) -> ic.Doc {
	name := fmt.aprintf("%s %s", FIRST[below(&c.rng, len(FIRST))], LAST[below(&c.rng, len(LAST))])
	return ic.Doc {
		key = fmt.aprintf("person:%06d", i),
		kind = .Person,
		sig = u64(i),
		title = name,
		who = name,
		body = fmt.aprintf("%s@example.org %s", strings.to_lower(name, context.temp_allocator), word(c)),
		detail = word(c),
		uri = fmt.aprintf("palm://bench/person/%06d", i),
		app = "contacts",
	}
}

// corpus_docs makes the benchmark corpus: `mails` mails, `files` files and
// the notes, events and people a person with that much mail would have.
corpus_docs :: proc(c: ^Corpus, mails, files, notes, events, people: int) -> [dynamic]ic.Doc {
	out := make([dynamic]ic.Doc, 0, mails + files + notes + events + people)
	for i in 0 ..< mails {
		append(&out, make_mail(c, i))
	}
	for i in 0 ..< files {
		append(&out, make_file(c, i))
	}
	for i in 0 ..< notes {
		append(&out, make_note(c, i))
	}
	for i in 0 ..< events {
		append(&out, make_event(c, i))
	}
	for i in 0 ..< people {
		append(&out, make_person(c, i))
	}
	return out
}
