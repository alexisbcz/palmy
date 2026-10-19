package main

// Password health: what is weak, what is reused, what was exposed -- and,
// only when the person asks, what has turned up in a breach.
//
// Everything but the breach check runs on data already decrypted in this
// process and sends nothing anywhere.
//
// The breach check is the one outbound call this program makes outside sync,
// so it is built to be refused by default and to say exactly what leaves:
//
//   - it runs only on an explicit action (the Health page's "Check now", or
//     `vault health --breach --yes`); there is no setting that runs it in
//     the background;
//   - for each distinct password it sends the **first five hex digits of the
//     password's SHA-1** to api.pwnedpasswords.com/range/<prefix>, with
//     `Add-Padding: true`, and compares the ~800 suffixes that come back
//     locally (Have I Been Pwned's k-anonymity model). Each prefix is shared
//     by hundreds of thousands of real passwords; the password, its full hash
//     and the item it belongs to never leave;
//   - what the service does learn: that this address checked these prefixes,
//     at this time. The prefixes of one person's passwords, asked together,
//     are a small fingerprint; that is the residual risk, said out loud on
//     the button;
//   - the fetcher is a parameter. The self-test hands it a fixture and makes
//     no network call at all.

import "core:crypto/hash"
import "core:fmt"
import "core:strconv"
import "core:strings"
import kit "kit:."

Health_Issue :: enum u8 {
	Weak,
	Reused,
	Exposed, // readable by someone whose share was revoked
	Breached, // found in Have I Been Pwned's corpus
	Old, // unchanged for over two years
}

HEALTH_ISSUE := [Health_Issue]string {
	.Weak     = "weak",
	.Reused   = "reused",
	.Exposed  = "exposed",
	.Breached = "breached",
	.Old      = "old",
}

Finding :: struct {
	entry:  int,
	issue:  Health_Issue,
	detail: string, // temp-allocated
}

Health :: struct {
	findings: [dynamic]Finding,
	weak:     int,
	reused:   int,
	exposed:  int,
	old:      int,
	breached: int,
	checked:  bool, // the breach check ran
}

health_free :: proc(h: ^Health) {
	delete(h.findings)
	h^ = {}
}

// A handful of the most common passwords from published breach corpora. The
// point is not completeness (the breach check is that) but to catch the
// ones the entropy estimate scores well: "Password1!" is 66 bits by shape.
@(private = "file")
COMMON := [?]string {
	"123456", "123456789", "12345678", "password", "qwerty", "qwerty123", "111111", "1234567890",
	"password1", "password123", "abc123", "iloveyou", "admin", "welcome", "letmein", "monkey",
	"dragon", "football", "baseball", "sunshine", "princess", "trustno1", "000000", "passw0rd",
	"master", "hello123", "freedom", "whatever", "shadow", "azerty", "secret", "changeme",
}

// looks_patterned catches the shape people use to satisfy composition rules:
// a word, then digits, then maybe a symbol ("Summer2024!"). Its entropy upper
// bound looks fine and it is cracked in seconds.
looks_patterned :: proc(pw: string) -> bool {
	i := 0
	letters := 0
	for i < len(pw) && ((pw[i] >= 'a' && pw[i] <= 'z') || (pw[i] >= 'A' && pw[i] <= 'Z')) {
		i += 1
		letters += 1
	}
	digits := 0
	for i < len(pw) && pw[i] >= '0' && pw[i] <= '9' {
		i += 1
		digits += 1
	}
	rest := len(pw) - i
	return letters >= 3 && digits >= 1 && rest <= 2
}

is_weak :: proc(pw: string) -> (bool, string) {
	if pw == "" {
		return false, ""
	}
	lower := strings.to_lower(pw, context.temp_allocator)
	for c in COMMON {
		if strings.trim_right(lower, "!.?#*") == c {
			return true, "one of the most common passwords there is"
		}
	}
	n := strings.rune_count(pw)
	if n < 10 {
		return true, fmt.tprintf("only %d characters", n)
	}
	if looks_patterned(pw) {
		return true, "a word followed by digits: guessed early by every cracker"
	}
	if b := password_bits(pw); b < 50 {
		return true, fmt.tprintf("at most %.0f bits", b)
	}
	return false, ""
}

health_check :: proc(v: ^Vault) -> (h: Health) {
	h.findings = make([dynamic]Finding)
	now := now_unix()
	seen := make(map[string][dynamic]int, context.temp_allocator)
	for &e, i in v.entries {
		if e.password == "" {
			continue
		}
		if weak, why := is_weak(e.password); weak {
			append(&h.findings, Finding{i, .Weak, why})
			h.weak += 1
		}
		if e.flags & ENTRY_EXPOSED != 0 {
			append(&h.findings, Finding{i, .Exposed, "someone whose access was revoked could read it: change it at the site"})
			h.exposed += 1
		}
		if e.modified > 0 && now - e.modified > 2 * 365 * 86400 {
			append(&h.findings, Finding{i, .Old, fmt.tprintf("unchanged since %s", when_text(e.modified)[:10])})
			h.old += 1
		}
		key := e.password
		if key not_in seen {
			seen[key] = make([dynamic]int, context.temp_allocator)
		}
		append(&seen[key], i)
	}
	for _, idxs in seen {
		if len(idxs) < 2 {
			continue
		}
		for i in idxs {
			others := make([dynamic]string, context.temp_allocator)
			for j in idxs {
				if j != i {
					append(&others, v.entries[j].title)
				}
			}
			append(&h.findings, Finding{i, .Reused, fmt.tprintf("also used by %s", strings.join(others[:], ", ", context.temp_allocator))})
			h.reused += 1
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Have I Been Pwned, range API
// ---------------------------------------------------------------------------

HIBP_URL :: "https://api.pwnedpasswords.com/range/"

// A fetcher takes a five-hex-digit prefix and returns the response body.
Hibp_Fetch :: proc(prefix: string) -> (body: string, err: string)

hibp_sha1 :: proc(pw: string) -> string {
	d: [20]byte
	hash.hash_bytes_to_buffer(.Insecure_SHA1, transmute([]byte)pw, d[:])
	return strings.to_upper(hex_lower(d[:]), context.temp_allocator)
}

// hibp_count looks a full SHA-1 up in a range response. Lines are
// "SUFFIX:COUNT"; padding lines have count 0 and never match a real hash
// anyway, but are skipped explicitly.
hibp_count :: proc(full_sha1: string, body: string) -> int {
	suffix := full_sha1[5:]
	for line in strings.split_lines(body, context.temp_allocator) {
		l := strings.trim_space(line)
		colon := strings.index_byte(l, ':')
		if colon != 35 {
			continue
		}
		if strings.equal_fold(l[:35], suffix) {
			n, _ := strconv.parse_int(l[36:])
			return n
		}
	}
	return 0
}

health_breach :: proc(h: ^Health, v: ^Vault, fetch: Hibp_Fetch) -> string {
	cache := make(map[string]string, context.temp_allocator) // prefix -> body
	done := make(map[string]int, context.temp_allocator) // full hash -> count
	for &e, i in v.entries {
		if e.password == "" {
			continue
		}
		full := hibp_sha1(e.password)
		count, have := done[full]
		if !have {
			prefix := full[:5]
			body, ok := cache[prefix]
			if !ok {
				b, err := fetch(prefix)
				if err != "" {
					return err
				}
				body = b
				cache[prefix] = body
			}
			count = hibp_count(full, body)
			done[full] = count
		}
		if count > 0 {
			append(&h.findings, Finding{i, .Breached, fmt.tprintf("seen %d times in breaches", count)})
			h.breached += 1
		}
	}
	h.checked = true
	return ""
}

// hibp_fetch_curl is the real fetcher: curl, so the TLS is curl's (cloudkit
// has no TLS of its own yet). The prefix is the only variable in the request.
hibp_fetch_curl :: proc(prefix: string) -> (body: string, err: string) {
	for c in transmute([]u8)prefix {
		if !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')) || len(prefix) != 5 {
			return "", "not a SHA-1 prefix"
		}
	}
	out, ok := kit.run({"curl", "-fsS", "--max-time", "15", "-H", "Add-Padding: true",
		"-H", "User-Agent: palm-vault", fmt.tprintf("%s%s", HIBP_URL, prefix)}, context.temp_allocator)
	if !ok {
		return "", "the breach check could not reach api.pwnedpasswords.com"
	}
	return out, ""
}
