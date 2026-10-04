package main

// `torrent --selftest` — every assertion, then the real transfer.
//
// This file runs with no network and no server: bencoding, info-hashes,
// percent-encoding, peer-message framing from canned byte arrays, piece
// geometry, bitfield arithmetic, rarest-first ordering, the loopback gate. It
// then hands over to `e2e.odin`, which starts the tracker on loopback, runs two
// instances of this very binary — one seeding, one empty — and asserts the
// result is byte-for-byte the source.
//
// Every assertion states the value it expects. Several of those values were
// computed OUTSIDE this program (with `sha1sum` and Python's `urllib.parse`) and
// pasted in as constants, which is the only way a hash test means anything: a
// test that compares the implementation against itself passes no matter how
// wrong both halves are.

import "core:fmt"
import "core:slice"
import "core:strings"

T :: struct {
	passed:   int,
	failed:   int,
	failures: [dynamic]string,
	verbose:  bool,
	section:  string,
}

tsection :: proc(t: ^T, name: string) {
	t.section = name
	fmt.printfln(
		"\n── %s %s",
		name,
		strings.repeat("─", max(0, 58 - len(name)), context.temp_allocator),
	)
}

tcheck :: proc(t: ^T, name: string, ok: bool, detail := "") -> bool {
	if ok {
		t.passed += 1
		if t.verbose {
			fmt.printfln("  pass  %s", name)
		}
	} else {
		t.failed += 1
		append(
			&t.failures,
			asprint("[%s] %s%s%s", t.section, name, detail == "" ? "" : " — ", detail),
		)
		fmt.printfln("  FAIL  %s%s%s", name, detail == "" ? "" : " — ", detail)
	}
	return ok
}

teq :: proc(t: ^T, name, got, want: string) -> bool {
	if got == want {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, asprint("got %q, want %q", got, want))
}

teq_int :: proc(t: ^T, name: string, got, want: int) -> bool {
	if got == want {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, asprint("got %d, want %d", got, want))
}

teq_i64 :: proc(t: ^T, name: string, got, want: i64) -> bool {
	if got == want {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, asprint("got %d, want %d", got, want))
}

teq_f32 :: proc(t: ^T, name: string, got, want, tol: f32) -> bool {
	d := got - want
	if d < 0 {
		d = -d
	}
	if d <= tol {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, asprint("got %f, want %f", got, want))
}

tbytes :: proc(t: ^T, name: string, got: []u8, want: string) -> bool {
	return teq(t, name, string(got), want)
}

tints :: proc(t: ^T, name: string, got, want: []int) -> bool {
	if slice.equal(got, want) {
		return tcheck(t, name, true)
	}
	return tcheck(t, name, false, asprint("got %v, want %v", got, want))
}

// ---------------------------------------------------------------------------

run_selftest :: proc(verbose: bool, with_e2e: bool) -> int {
	t := T {
		verbose  = verbose,
		failures = make([dynamic]string, 0, 16),
	}
	fmt.println("torrent --selftest")
	fmt.println("no socket is opened by any assertion in this phase.")

	test_sha1(&t)
	test_bencode_decode(&t)
	test_bencode_malformed(&t)
	test_bencode_encode_order(&t)
	test_info_hash(&t)
	test_metainfo(&t)
	test_piece_mapping(&t)
	test_bitfield(&t)
	test_percent_encoding(&t)
	test_announce_query(&t)
	test_announce_parse(&t)
	test_udp_tracker(&t)
	test_handshake(&t)
	test_framing(&t)
	test_message_encoding(&t)
	test_rarest_first(&t)
	test_picker_blocks(&t)
	test_magnet(&t)
	test_urls(&t)
	test_storage(&t)
	test_create_torrent(&t)
	test_loopback_gate(&t)

	unit_passed := t.passed
	unit_failed := t.failed
	fmt.printfln("\n%d assertions, %d failed (unit phase)", t.passed + t.failed, t.failed)

	e2e_ok := true
	if with_e2e {
		e2e_ok = run_e2e(&t)
	} else {
		fmt.println("\n(--no-e2e: the end-to-end transfer was skipped)")
	}

	fmt.println("\n────────────────────────────────────────────────────────────")
	fmt.printfln(
		"%d assertions total: %d passed, %d failed",
		t.passed + t.failed,
		t.passed,
		t.failed,
	)
	fmt.printfln("  unit phase      %d passed, %d failed", unit_passed, unit_failed)
	fmt.printfln(
		"  end-to-end      %d passed, %d failed",
		t.passed - unit_passed,
		t.failed - unit_failed,
	)
	if len(t.failures) > 0 {
		fmt.println("\nfailures:")
		for f in t.failures {
			fmt.printfln("  %s", f)
		}
	}

	// The audit: every endpoint this process touched.
	fmt.println("\nnetwork audit — every endpoint this process contacted or refused:")
	for ev in net_audit_snapshot(context.temp_allocator) {
		fmt.printfln(
			"  %-12s %s:%-6d %s%s",
			ev.what,
			ev.host,
			ev.port,
			ev.allowed ? "allowed" : "REFUSED",
			ev.allowed ? "" : asprint(" (%s)", ev.reason),
		)
	}
	all_lo, offender := net_audit_all_loopback()
	if all_lo {
		fmt.println("  every allowed endpoint was in 127.0.0.0/8.")
	} else {
		fmt.printfln("  *** %s IS NOT LOOPBACK ***", offender)
	}

	if t.failed == 0 && e2e_ok && all_lo {
		fmt.println("\nOK")
		return 0
	}
	fmt.println("\nFAILED")
	return 1
}

// ---------------------------------------------------------------------------
// SHA-1
//
// FIPS 180-1 and the usual pangram, computed with `sha1sum` outside this
// program. If the wiring is wrong, nothing downstream means anything.
// ---------------------------------------------------------------------------

test_sha1 :: proc(t: ^T) {
	tsection(t, "sha1")
	teq(
		t,
		"the empty string",
		hash20_hex(sha1_of({}), context.temp_allocator),
		"da39a3ee5e6b4b0d3255bfef95601890afd80709",
	)
	teq(
		t,
		`"abc"`,
		hash20_hex(sha1_of(transmute([]u8)string("abc")), context.temp_allocator),
		"a9993e364706816aba3e25717850c26c9cd0d89d",
	)
	teq(
		t,
		"the pangram",
		hash20_hex(
			sha1_of(transmute([]u8)string("The quick brown fox jumps over the lazy dog")),
			context.temp_allocator,
		),
		"2fd4e1c67a2d28fced849ee1bb76e7391b93eb12",
	)
	// A million 'a's, which is the vector that catches a broken length counter
	// in the padding — and is also how a piece gets hashed in chunks.
	million := make([]u8, 1_000_000, context.temp_allocator)
	for i in 0 ..< len(million) {
		million[i] = 'a'
	}
	teq(
		t,
		"a million 'a' in one call",
		hash20_hex(sha1_of(million), context.temp_allocator),
		"34aa973cd4c4daa4f61eeb2bdbad27316534016f",
	)
	// The same thing fed in awkward chunks, which is what a piece spanning
	// several files does.
	s: Sha1_Stream
	sha1_begin(&s)
	off := 0
	for chunk in ([?]int{1, 2, 3, 7, 999, 65537}) {
		n := min(chunk, len(million) - off)
		sha1_feed(&s, million[off:off + n])
		off += n
	}
	sha1_feed(&s, million[off:])
	teq(
		t,
		"...and in six uneven chunks",
		hash20_hex(sha1_end(&s), context.temp_allocator),
		"34aa973cd4c4daa4f61eeb2bdbad27316534016f",
	)
	h, ok := hash20_from_hex("2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
	tcheck(t, "a hex digest parses", ok)
	tcheck(t, "...and round-trips", hash20_hex(h, context.temp_allocator) == "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
	_, bad := hash20_from_hex("2fd4e1")
	tcheck(t, "a short digest is refused", !bad)
	_, bad2 := hash20_from_hex("zz" + "d4e1c67a2d28fced849ee1bb76e7391b93eb12")
	tcheck(t, "a non-hex digest is refused", !bad2)
}

// ---------------------------------------------------------------------------
// Bencode: decoding
// ---------------------------------------------------------------------------

test_bencode_decode :: proc(t: ^T) {
	tsection(t, "bencode — decoding")
	dec :: proc(s: string) -> (Ben, string) {
		return ben_decode(transmute([]u8)s, context.temp_allocator)
	}

	v, e := dec("i42e")
	teq(t, "i42e parses", e, "")
	teq_i64(t, "i42e is 42", v.num, 42)
	tcheck(t, "...as an integer", v.kind == .Int)

	v, e = dec("i0e")
	teq(t, "i0e parses", e, "")
	teq_i64(t, "i0e is 0", v.num, 0)

	v, e = dec("i-42e")
	teq(t, "i-42e parses", e, "")
	teq_i64(t, "i-42e is -42", v.num, -42)

	v, e = dec("i-1e")
	teq_i64(t, "i-1e is -1", v.num, -1)

	v, e = dec("i9223372036854775807e")
	teq(t, "max i64 parses", e, "")
	teq_i64(t, "...and is max(i64)", v.num, max(i64))

	v, e = dec("4:spam")
	teq(t, "4:spam parses", e, "")
	tbytes(t, "4:spam is spam", v.str, "spam")
	tcheck(t, "...as a string", v.kind == .Str)

	v, e = dec("0:")
	teq(t, "the empty string parses", e, "")
	teq_int(t, "...and is empty", len(v.str), 0)

	// A byte string is bytes, not text: NULs and high bytes pass through.
	raw := make([dynamic]u8, 0, 16, context.temp_allocator)
	append(&raw, ..transmute([]u8)string("5:"))
	append(&raw, 0x00, 0xff, 0x80, 0x0a, 0x7f)
	v, e = ben_decode(raw[:], context.temp_allocator)
	teq(t, "a string of binary bytes parses", e, "")
	teq_int(t, "...with all five bytes", len(v.str), 5)
	tcheck(t, "...including the NUL", len(v.str) == 5 && v.str[0] == 0x00)
	tcheck(t, "...and the high bytes", len(v.str) == 5 && v.str[1] == 0xff && v.str[2] == 0x80)

	v, e = dec("le")
	teq(t, "the empty list parses", e, "")
	tcheck(t, "...as a list", v.kind == .List)
	teq_int(t, "...of nothing", len(v.list), 0)

	v, e = dec("l4:spam4:eggse")
	teq(t, "a list of two strings parses", e, "")
	teq_int(t, "...with two items", len(v.list), 2)
	tbytes(t, "...the first is spam", v.list[0].str, "spam")
	tbytes(t, "...the second is eggs", v.list[1].str, "eggs")

	v, e = dec("de")
	teq(t, "the empty dictionary parses", e, "")
	tcheck(t, "...as a dictionary", v.kind == .Dict)

	v, e = dec("d3:cow3:moo4:spam4:eggse")
	teq(t, "a dictionary parses", e, "")
	teq_int(t, "...with two keys", len(v.dict), 2)
	cow, cok := ben_str_of(v, "cow")
	tcheck(t, "cow is present", cok)
	teq(t, "cow is moo", cow, "moo")
	spam, sok := ben_str_of(v, "spam")
	tcheck(t, "spam is present", sok)
	teq(t, "spam is eggs", spam, "eggs")
	_, mok := ben_get(v, "missing")
	tcheck(t, "a missing key is not found", !mok)

	v, e = dec("d4:spaml1:a1:bee")
	teq(t, "a dictionary of a list parses", e, "")
	l, lok := ben_list_of(v, "spam")
	tcheck(t, "the list is there", lok)
	teq_int(t, "...with two items", len(l), 2)

	// Nesting, and the byte spans.
	nested := "d1:ad1:bi7eee"
	v, e = dec(nested)
	teq(t, "a nested dictionary parses", e, "")
	inner, iok := ben_get(v, "a")
	tcheck(t, "the inner dictionary is found", iok)
	teq_int(t, "its span starts at byte 4", inner.start, 4)
	teq_int(t, "...and ends at byte 12", inner.end, 12)
	teq(
		t,
		"...so its original bytes are recoverable",
		nested[inner.start:inner.end],
		"d1:bi7ee",
	)

	// A prefix parse leaves the rest alone, which is what a stream needs.
	pv, used, perr := ben_decode_prefix(
		transmute([]u8)string("i7eGARBAGE"),
		context.temp_allocator,
	)
	teq(t, "a prefix parse succeeds", perr, "")
	teq_i64(t, "...reading the value", pv.num, 7)
	teq_int(t, "...and reporting 3 bytes used", used, 3)
}

// ---------------------------------------------------------------------------
// Bencode: everything that must be refused
// ---------------------------------------------------------------------------

test_bencode_malformed :: proc(t: ^T) {
	tsection(t, "bencode — malformed input is refused, not guessed")
	bad :: proc(t: ^T, s: string, why: string) {
		_, e := ben_decode(transmute([]u8)s, context.temp_allocator)
		tcheck(t, asprint("%q is refused (%s)", s, why), e != "", "it was accepted")
	}
	// Integers.
	bad(t, "i-0e", "negative zero")
	bad(t, "i03e", "a leading zero")
	bad(t, "i0123e", "leading zeros")
	bad(t, "i-03e", "a negative with a leading zero")
	bad(t, "ie", "no digits")
	bad(t, "i-e", "a sign with no digits")
	bad(t, "i42", "unterminated")
	bad(t, "i4-2e", "a sign in the middle")
	bad(t, "i 42e", "a space")
	bad(t, "i92233720368547758080e", "an overflow of i64")
	// Strings.
	bad(t, "5:abc", "a length longer than the data")
	bad(t, "03:abc", "a leading zero in the length")
	bad(t, "3abc", "no colon")
	bad(t, "-1:a", "a negative length")
	bad(t, ":abc", "no length")
	// Containers.
	bad(t, "l", "an unterminated list")
	bad(t, "l4:spam", "a list missing its terminator")
	bad(t, "d", "an unterminated dictionary")
	bad(t, "d3:cow", "a dictionary key with no value")
	bad(t, "d3:cow3:moo", "a dictionary missing its terminator")
	bad(t, "di42ei1ee", "an integer dictionary key")
	bad(t, "dli1ee3:abce", "a list dictionary key")
	bad(t, "d3:cow3:moo3:cow3:mooe", "a duplicate dictionary key")
	// Nothing, and rubbish.
	bad(t, "", "the empty input")
	bad(t, "x", "a byte that starts no value")
	bad(t, "e", "a bare terminator")
	bad(t, "i7ei8e", "two top-level values")
	bad(t, "4:spamX", "trailing garbage")
	bad(t, "l" + "l" + "l", "truncated nesting")

	// A depth bomb must not recurse the stack to death.
	deep := strings.repeat("l", BEN_MAX_DEPTH + 8, context.temp_allocator)
	_, derr := ben_decode(transmute([]u8)deep, context.temp_allocator)
	tcheck(t, "nesting past the depth cap is refused", derr != "", "it was accepted")

	// A length prefix that claims more than the file holds must not allocate it.
	_, herr := ben_decode(transmute([]u8)string("999999999999:x"), context.temp_allocator)
	tcheck(t, "an absurd string length is refused", herr != "", "it was accepted")

	// And a real torrent whose `info` has been truncated.
	tor := test_torrent_sorted(context.temp_allocator)
	for cut in ([?]int{1, 10, 40, 60, 100, 124}) {
		_, perr := metainfo_parse(clone_bytes(tor[:cut], context.temp_allocator), context.temp_allocator)
		tcheck(
			t,
			asprint("a torrent truncated to %d bytes is refused", cut),
			perr != "",
			"it parsed",
		)
	}
}

// ---------------------------------------------------------------------------
// Bencode: the key-ordering rule
// ---------------------------------------------------------------------------

test_bencode_encode_order :: proc(t: ^T) {
	tsection(t, "bencode — encoding sorts dictionary keys")
	enc :: proc(v: Ben) -> string {
		return string(ben_encode(v, context.temp_allocator))
	}
	teq(t, "an integer", enc(bnum(42)), "i42e")
	teq(t, "zero", enc(bnum(0)), "i0e")
	teq(t, "a negative integer", enc(bnum(-42)), "i-42e")
	teq(t, "min(i64) does not overflow the negation", enc(bnum(min(i64))), "i-9223372036854775808e")
	teq(t, "max(i64)", enc(bnum(max(i64))), "i9223372036854775807e")
	teq(t, "a string", enc(bstr("spam")), "4:spam")
	teq(t, "the empty string", enc(bstr("")), "0:")
	teq(t, "a list", enc(blist({bstr("spam"), bstr("eggs")}, context.temp_allocator)), "l4:spam4:eggse")
	teq(t, "the empty list", enc(blist({}, context.temp_allocator)), "le")
	teq(t, "the empty dictionary", enc(bdict({}, context.temp_allocator)), "de")

	// THE rule: keys come out sorted however they went in.
	teq(
		t,
		"keys given in order stay in order",
		enc(bdict({bp("cow", bstr("moo")), bp("spam", bstr("eggs"))}, context.temp_allocator)),
		"d3:cow3:moo4:spam4:eggse",
	)
	teq(
		t,
		"keys given out of order are SORTED",
		enc(bdict({bp("spam", bstr("eggs")), bp("cow", bstr("moo"))}, context.temp_allocator)),
		"d3:cow3:moo4:spam4:eggse",
	)
	teq(
		t,
		"the order is by raw bytes, so uppercase sorts before lowercase",
		enc(bdict({bp("a", bnum(1)), bp("Z", bnum(2))}, context.temp_allocator)),
		"d1:Zi2e1:ai1ee",
	)
	teq(
		t,
		"a prefix sorts before the longer key",
		enc(bdict({bp("abc", bnum(2)), bp("ab", bnum(1))}, context.temp_allocator)),
		"d2:abi1e3:abci2ee",
	)
	teq(
		t,
		"the metainfo keys land in the canonical order",
		enc(
			bdict(
				{
					bp("pieces", bstr("x")),
					bp("piece length", bnum(16384)),
					bp("name", bstr("n")),
					bp("length", bnum(1)),
				},
				context.temp_allocator,
			),
		),
		"d6:lengthi1e4:name1:n12:piece lengthi16384e6:pieces1:xe",
	)
	// Nested dictionaries are sorted too, at every level.
	teq(
		t,
		"nested dictionaries are sorted at every level",
		enc(
			bdict(
				{
					bp("z", bdict({bp("b", bnum(2)), bp("a", bnum(1))}, context.temp_allocator)),
					bp("a", bnum(0)),
				},
				context.temp_allocator,
			),
		),
		"d1:ai0e1:zd1:ai1e1:bi2eee",
	)

	// ben_key_less, directly.
	less :: proc(a, b: string) -> bool {
		return ben_key_less(transmute([]u8)a, transmute([]u8)b)
	}
	tcheck(t, `"a" < "b"`, less("a", "b"))
	tcheck(t, `not "b" < "a"`, !less("b", "a"))
	tcheck(t, `"ab" < "abc"`, less("ab", "abc"))
	tcheck(t, `not "abc" < "ab"`, !less("abc", "ab"))
	tcheck(t, `not "a" < "a"`, !less("a", "a"))
	tcheck(t, `"Z" < "a" (byte order, not case-insensitive)`, less("Z", "a"))

	// Round trip: decoding an unsorted dictionary and re-encoding sorts it.
	v, e := ben_decode(
		transmute([]u8)string("d4:spam4:eggs3:cow3:mooe"),
		context.temp_allocator,
	)
	teq(t, "an unsorted dictionary still decodes", e, "")
	tcheck(t, "...and is reported as unsorted", !ben_dict_sorted(v))
	teq(t, "...and re-encodes sorted", enc(v), "d3:cow3:moo4:spam4:eggse")
	v2, _ := ben_decode(transmute([]u8)string("d3:cow3:moo4:spam4:eggse"), context.temp_allocator)
	tcheck(t, "a sorted dictionary is reported as sorted", ben_dict_sorted(v2))
	teq(t, "...and re-encodes identically", enc(v2), "d3:cow3:moo4:spam4:eggse")
}

// ---------------------------------------------------------------------------
// The info-hash
// ---------------------------------------------------------------------------

// The test torrent: one 12-byte file, "hello world!", at a 16 KiB piece
// length, so there is exactly one piece. Every constant below was computed
// outside this program:
//
//   SHA-1("hello world!")                       = 430ce34d…d169   (the piece)
//   SHA-1(the sorted info dictionary, 84 bytes) = 6bda25b4…bde7
//   SHA-1(the same keys written out of order)   = 2771705d…8c05
//
// Both info dictionaries describe the SAME torrent and are both 84 bytes long.
// Their hashes differ because the bytes differ. That is the whole point: the
// info-hash is a property of the file on disk, not of the parsed meaning.
TEST_PIECE_HASH :: "430ce34d020724ed75a196dfc2ad67c77772d169"
TEST_INFO_HASH_SORTED :: "6bda25b4af456ed87b98301f0c220694a8bfbde7"
TEST_INFO_HASH_UNSORTED :: "2771705df303d4ad2afc75d1326d83a186fa8c05"

@(private = "file")
bcat :: proc(allocator: runtime_allocator, parts: ..[]u8) -> []u8 {
	out := make([dynamic]u8, 0, 256, allocator)
	for p in parts {
		append(&out, ..p)
	}
	return out[:]
}

@(private = "file")
sv :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

// test_torrent_sorted builds the canonical form: `info` keys already in order.
test_torrent_sorted :: proc(allocator := context.allocator) -> []u8 {
	ph, _ := hex_decode(TEST_PIECE_HASH, context.temp_allocator)
	return bcat(
		allocator,
		sv("d8:announce20:http://127.0.0.1:1/a4:info"),
		sv("d6:lengthi12e4:name9:hello.txt12:piece lengthi16384e6:pieces20:"),
		ph,
		sv("ee"),
	)
}

// test_torrent_unsorted writes the same `info` with its keys out of order,
// which is legal bencoding and is what a sloppy maker produces.
test_torrent_unsorted :: proc(allocator := context.allocator) -> []u8 {
	ph, _ := hex_decode(TEST_PIECE_HASH, context.temp_allocator)
	return bcat(
		allocator,
		sv("d8:announce20:http://127.0.0.1:1/a4:info"),
		sv("d4:name9:hello.txt6:pieces20:"),
		ph,
		sv("12:piece lengthi16384e6:lengthi12ee"),
		sv("e"),
	)
}

test_info_hash :: proc(t: ^T) {
	tsection(t, "the info-hash is SHA-1 over the ORIGINAL info bytes")

	tor := test_torrent_sorted(context.temp_allocator)
	teq_int(t, "the canonical test torrent is 125 bytes", len(tor), 125)
	m, e := metainfo_parse(tor, context.temp_allocator)
	teq(t, "it parses", e, "")
	teq(
		t,
		"its info-hash matches the externally computed value",
		hash20_hex(m.info_hash, context.temp_allocator),
		TEST_INFO_HASH_SORTED,
	)
	teq_int(t, "the info span starts at byte 40", m.info_span[0], 40)
	teq_int(t, "...and ends at byte 124", m.info_span[1], 124)
	teq_int(t, "...which is 84 bytes of info dictionary", m.info_span[1] - m.info_span[0], 84)
	teq(
		t,
		"and hashing that substring by hand gives the same answer",
		hash20_hex(sha1_of(tor[40:124]), context.temp_allocator),
		TEST_INFO_HASH_SORTED,
	)

	// The classic bug, stated as an assertion.
	utor := test_torrent_unsorted(context.temp_allocator)
	teq_int(t, "the out-of-order torrent is also 125 bytes", len(utor), 125)
	um, ue := metainfo_parse(utor, context.temp_allocator)
	teq(t, "it parses too", ue, "")
	teq(
		t,
		"its info-hash is the hash of ITS bytes",
		hash20_hex(um.info_hash, context.temp_allocator),
		TEST_INFO_HASH_UNSORTED,
	)
	tcheck(
		t,
		"...which is NOT the canonical torrent's info-hash",
		!hash20_eq(um.info_hash, m.info_hash),
		"the two out-of-order spellings hashed the same, so the raw bytes are not being used",
	)
	// And now the bug itself: re-encode the parsed info dictionary and hash
	// that. It gives the canonical hash, which is the WRONG answer for this
	// file, and is exactly what a client that re-encodes computes.
	uroot, _ := ben_decode(utor, context.temp_allocator)
	uinfo, _ := ben_get(uroot, "info")
	reenc := ben_encode(uinfo, context.temp_allocator)
	teq_int(t, "the re-encoding is 84 bytes as well", len(reenc), 84)
	teq(
		t,
		"re-encoding gives the canonical (and here WRONG) hash",
		hash20_hex(sha1_of(reenc), context.temp_allocator),
		TEST_INFO_HASH_SORTED,
	)
	tcheck(
		t,
		"so a re-encoding client would compute a different info-hash than this one",
		!hash20_eq(sha1_of(reenc), um.info_hash),
	)
	// The two spellings describe the same torrent, which is why this is a trap.
	teq(t, "both spellings name the same file", um.name, m.name)
	teq_i64(t, "...of the same length", um.total_length, m.total_length)
	teq_i64(t, "...with the same piece length", um.piece_length, m.piece_length)
	teq_int(t, "...and the same number of pieces", len(um.pieces), len(m.pieces))
	teq(
		t,
		"...and the same piece hash",
		hash20_hex(um.pieces[0], context.temp_allocator),
		TEST_PIECE_HASH,
	)
	// Finally: the piece hash really is the SHA-1 of the payload.
	teq(
		t,
		"the piece hash is SHA-1 of the file's 12 bytes",
		hash20_hex(sha1_of(sv("hello world!")), context.temp_allocator),
		TEST_PIECE_HASH,
	)
}

// ---------------------------------------------------------------------------
// Metainfo
// ---------------------------------------------------------------------------

test_metainfo :: proc(t: ^T) {
	tsection(t, "metainfo")

	m, e := metainfo_parse(test_torrent_sorted(context.temp_allocator), context.temp_allocator)
	teq(t, "the single-file torrent parses", e, "")
	tcheck(t, "it is a single-file torrent", m.single_file)
	teq(t, "its name", m.name, "hello.txt")
	teq_i64(t, "its length", m.total_length, 12)
	teq_i64(t, "its piece length", m.piece_length, 16384)
	teq_int(t, "it has one piece", len(m.pieces), 1)
	teq_int(t, "it has one file", len(m.files), 1)
	teq(t, "whose path is the name", m.files[0].path, "hello.txt")
	teq_i64(t, "at offset zero", m.files[0].offset, 0)
	teq(t, "its announce URL", m.announce, "http://127.0.0.1:1/a")
	teq_int(t, "its tracker list has one entry", len(m.announce_list), 1)
	tcheck(t, "it is not private", !m.private)
	teq_i64(t, "the only piece is 12 bytes, not the piece length", piece_size(&m, 0), 12)

	// A multi-file torrent, built with the encoder so the key order is right.
	ph, _ := hex_decode(TEST_PIECE_HASH, context.temp_allocator)
	pieces := bcat(context.temp_allocator, ph, ph, ph)
	mt := ben_encode(
		bdict(
			{
				bp("announce", bstr("http://127.0.0.1:6969/announce")),
				bp(
					"info",
					bdict(
						{
							bp("name", bstr("tree")),
							bp("piece length", bnum(1024)),
							bp("pieces", bbytes(pieces)),
							bp("private", bnum(1)),
							bp(
								"files",
								blist(
									{
										bdict(
											{
												bp("length", bnum(1000)),
												bp("path", blist({bstr("a.bin")}, context.temp_allocator)),
											},
											context.temp_allocator,
										),
										bdict(
											{
												bp("length", bnum(0)),
												bp("path", blist({bstr("dir"), bstr("empty")}, context.temp_allocator)),
											},
											context.temp_allocator,
										),
										bdict(
											{
												bp("length", bnum(1500)),
												bp("path", blist({bstr("dir"), bstr("sub"), bstr("b.bin")}, context.temp_allocator)),
											},
											context.temp_allocator,
										),
									},
									context.temp_allocator,
								),
							),
						},
						context.temp_allocator,
					),
				),
			},
			context.temp_allocator,
		),
		context.temp_allocator,
	)
	mm, me := metainfo_parse(mt, context.temp_allocator)
	teq(t, "the multi-file torrent parses", me, "")
	tcheck(t, "it is not single-file", !mm.single_file)
	teq(t, "its name", mm.name, "tree")
	teq_int(t, "it has three files", len(mm.files), 3)
	teq(t, "the first file's path", mm.files[0].path, "a.bin")
	teq(t, "the second's path is '/'-joined", mm.files[1].path, "dir/empty")
	teq(t, "the third's path is three components", mm.files[2].path, "dir/sub/b.bin")
	teq_i64(t, "the first is at offset 0", mm.files[0].offset, 0)
	teq_i64(t, "the zero-length file sits at 1000", mm.files[1].offset, 1000)
	teq_i64(t, "...and does not advance the offset", mm.files[2].offset, 1000)
	teq_i64(t, "the total is the sum", mm.total_length, 2500)
	teq_int(t, "2500 bytes at 1024 a piece is 3 pieces", len(mm.pieces), 3)
	teq_i64(t, "the last piece is 452 bytes", piece_size(&mm, 2), 452)
	tcheck(t, "it is private", mm.private)
	teq(t, "its tracker", mm.announce, "http://127.0.0.1:6969/announce")

	// Everything that must be refused.
	bad :: proc(t: ^T, info_pairs: []Ben_Pair, why: string) {
		raw := ben_encode(
			bdict({bp("info", bdict(info_pairs, context.temp_allocator))}, context.temp_allocator),
			context.temp_allocator,
		)
		_, err := metainfo_parse(raw, context.temp_allocator)
		tcheck(t, asprint("refused: %s", why), err != "", "it parsed")
	}
	p20 := bbytes(ph)
	bad(t, {bp("piece length", bnum(16384)), bp("pieces", p20), bp("length", bnum(12))}, "no name")
	bad(t, {bp("name", bstr("x")), bp("pieces", p20), bp("length", bnum(12))}, "no piece length")
	bad(t, {bp("name", bstr("x")), bp("piece length", bnum(16384)), bp("length", bnum(12))}, "no pieces")
	bad(
		t,
		{bp("name", bstr("x")), bp("piece length", bnum(16384)), bp("pieces", bstr("short")), bp("length", bnum(12))},
		"a pieces string that is not a multiple of 20",
	)
	bad(
		t,
		{bp("name", bstr("x")), bp("piece length", bnum(16384)), bp("pieces", p20)},
		"neither length nor files",
	)
	bad(
		t,
		{
			bp("name", bstr("x")),
			bp("piece length", bnum(16384)),
			bp("pieces", p20),
			bp("length", bnum(12)),
			bp("files", blist({}, context.temp_allocator)),
		},
		"both length and files",
	)
	bad(
		t,
		{bp("name", bstr("x")), bp("piece length", bnum(16384)), bp("pieces", p20), bp("length", bnum(999999))},
		"a piece count that does not match the length",
	)
	bad(
		t,
		{bp("name", bstr("x")), bp("piece length", bnum(7)), bp("pieces", p20), bp("length", bnum(7))},
		"an implausible piece length",
	)

	// Path traversal. A .torrent comes from a stranger.
	traversal :: proc(t: ^T, comps: []Ben, why: string) {
		ph2, _ := hex_decode(TEST_PIECE_HASH, context.temp_allocator)
		raw := ben_encode(
			bdict(
				{
					bp(
						"info",
						bdict(
							{
								bp("name", bstr("t")),
								bp("piece length", bnum(1024)),
								bp("pieces", bbytes(ph2)),
								bp(
									"files",
									blist(
										{
											bdict(
												{bp("length", bnum(10)), bp("path", blist(comps, context.temp_allocator))},
												context.temp_allocator,
											),
										},
										context.temp_allocator,
									),
								),
							},
							context.temp_allocator,
						),
					),
				},
				context.temp_allocator,
			),
			context.temp_allocator,
		)
		_, err := metainfo_parse(raw, context.temp_allocator)
		tcheck(t, asprint("refused: %s", why), err != "", "it parsed, which would write outside the download directory")
	}
	traversal(t, {bstr(".."), bstr("escaped")}, `a ".." path component`)
	traversal(t, {bstr("a"), bstr(".."), bstr("..")}, "a buried `..`")
	traversal(t, {bstr("/etc"), bstr("passwd")}, "an absolute first component")
	traversal(t, {bstr("")}, "an empty component")
	traversal(t, {bstr(".")}, `a "." component`)
	traversal(t, {bstr("a/b")}, "a slash inside a component")

	// The `name` is a path component too.
	bad(
		t,
		{bp("name", bstr("..")), bp("piece length", bnum(16384)), bp("pieces", p20), bp("length", bnum(12))},
		`a name of ".."`,
	)

	// sanitise_path on its own.
	_, se := sanitise_path("a/b/c")
	teq(t, "a plain relative path is fine", se, "")
	_, se2 := sanitise_path("a/../b")
	tcheck(t, "a path with .. is refused", se2 != "")
	_, se3 := sanitise_path("/abs")
	tcheck(t, "an absolute path is refused", se3 != "")
	_, se4 := sanitise_path("")
	tcheck(t, "an empty path is refused", se4 != "")
}

// ---------------------------------------------------------------------------
// Pieces onto files
// ---------------------------------------------------------------------------

@(private = "file")
layout :: proc(
	piece_len: i64,
	sizes: []i64,
	allocator := context.temp_allocator,
) -> Metainfo {
	// A Metainfo built directly, so the geometry can be tested without a file.
	total: i64 = 0
	files := make([]Torrent_File, len(sizes), allocator)
	for s, i in sizes {
		files[i] = Torrent_File{path = asprint("f%d", i), length = s, offset = total}
		total += s
	}
	np := int((total + piece_len - 1) / piece_len)
	return Metainfo {
		piece_length = piece_len,
		total_length = total,
		files = files,
		pieces = make([]Hash20, np, allocator),
		single_file = len(sizes) == 1,
	}
}

test_piece_mapping :: proc(t: ^T) {
	tsection(t, "pieces onto a multi-file layout")

	// Three files of 100, 100, 100 with a 128-byte piece: 300 bytes, 3 pieces
	// of 128, 128, 44, and every piece but the first straddles a boundary.
	m := layout(128, {100, 100, 100})
	teq_int(t, "300 bytes at 128 a piece is 3 pieces", piece_count(&m), 3)
	teq_i64(t, "piece 0 is 128 bytes", piece_size(&m, 0), 128)
	teq_i64(t, "piece 1 is 128 bytes", piece_size(&m, 1), 128)
	teq_i64(t, "the last piece is 44 bytes", piece_size(&m, 2), 44)
	teq_i64(t, "piece 2 starts at offset 256", piece_offset(&m, 2), 256)

	s0 := piece_spans(&m, 0)
	teq_int(t, "piece 0 covers two files", len(s0), 2)
	teq_int(t, "  span 0 is file 0", s0[0].file, 0)
	teq_i64(t, "  at file offset 0", s0[0].file_off, 0)
	teq_i64(t, "  for 100 bytes", s0[0].length, 100)
	teq_int(t, "  span 1 is file 1", s0[1].file, 1)
	teq_i64(t, "  at file offset 0", s0[1].file_off, 0)
	teq_i64(t, "  for 28 bytes", s0[1].length, 28)

	s1 := piece_spans(&m, 1)
	teq_int(t, "piece 1 covers two files", len(s1), 2)
	teq_int(t, "  span 0 is file 1", s1[0].file, 1)
	teq_i64(t, "  at file offset 28", s1[0].file_off, 28)
	teq_i64(t, "  for 72 bytes", s1[0].length, 72)
	teq_int(t, "  span 1 is file 2", s1[1].file, 2)
	teq_i64(t, "  at file offset 0", s1[1].file_off, 0)
	teq_i64(t, "  for 56 bytes", s1[1].length, 56)

	s2 := piece_spans(&m, 2)
	teq_int(t, "the last piece covers one file", len(s2), 1)
	teq_int(t, "  file 2", s2[0].file, 2)
	teq_i64(t, "  at file offset 56", s2[0].file_off, 56)
	teq_i64(t, "  for the remaining 44 bytes", s2[0].length, 44)

	// The spans of a piece always add up to the piece's length.
	for i in 0 ..< piece_count(&m) {
		total: i64 = 0
		for sp in piece_spans(&m, i) {
			total += sp.length
		}
		teq_i64(t, asprint("piece %d's spans sum to its size", i), total, piece_size(&m, i))
	}

	// A piece covering three files at once.
	m3 := layout(1024, {10, 10, 10, 2000})
	s := piece_spans(&m3, 0)
	teq_int(t, "a 1024-byte piece over 10+10+10+… covers four files", len(s), 4)
	teq_i64(t, "  10 from the first", s[0].length, 10)
	teq_i64(t, "  10 from the second", s[1].length, 10)
	teq_i64(t, "  10 from the third", s[2].length, 10)
	teq_i64(t, "  and 994 from the fourth", s[3].length, 994)

	// A zero-length file in the middle contributes no span at all.
	mz := layout(100, {50, 0, 50})
	sz := piece_spans(&mz, 0)
	teq_int(t, "a zero-length file contributes no span", len(sz), 2)
	teq_int(t, "  the spans skip straight to file 2", sz[1].file, 2)
	teq_i64(t, "  taking all 50 of its bytes", sz[1].length, 50)

	// Several zero-length files in a row.
	mzz := layout(64, {32, 0, 0, 0, 32})
	szz := piece_spans(&mzz, 0)
	teq_int(t, "three empty files in a row are all skipped", len(szz), 2)
	teq_int(t, "  file 0", szz[0].file, 0)
	teq_int(t, "  then file 4", szz[1].file, 4)

	// A file smaller than a block.
	msmall := layout(32768, {7, 100000})
	ss := piece_spans(&msmall, 0)
	teq_int(t, "a 7-byte file is its own span", len(ss), 2)
	teq_i64(t, "  of 7 bytes", ss[0].length, 7)
	teq_i64(t, "  then 32761 of the next file", ss[1].length, 32761)

	// A single file exactly a whole number of pieces: no straddling, no short
	// last piece.
	mexact := layout(1024, {4096})
	teq_int(t, "4096 bytes at 1024 is exactly 4 pieces", piece_count(&mexact), 4)
	teq_i64(t, "...and the last one is full length", piece_size(&mexact, 3), 1024)
	se := piece_spans(&mexact, 3)
	teq_int(t, "...covering one file", len(se), 1)
	teq_i64(t, "...at offset 3072", se[0].file_off, 3072)

	// file_pieces, the inverse.
	first, last := file_pieces(&m, 1)
	teq_int(t, "file 1 of the 100/100/100 layout starts in piece 0", first, 0)
	teq_int(t, "...and ends in piece 1 (exclusive 2)", last, 2)
	f0, l0 := file_pieces(&m, 0)
	teq_int(t, "file 0 starts in piece 0", f0, 0)
	teq_int(t, "...and is wholly inside piece 0", l0, 1)
	f2, l2 := file_pieces(&m, 2)
	teq_int(t, "file 2 starts in piece 1", f2, 1)
	teq_int(t, "...and ends in piece 2", l2, 3)

	// Blocks.
	mb := layout(32768, {100_000})
	teq_int(t, "a 32 KiB piece is 2 blocks of 16 KiB", blocks_in_piece(&mb, 0), 2)
	teq_int(t, "block 0 is 16384 bytes", block_size_at(&mb, 0, 0), 16384)
	teq_int(t, "block 1 is 16384 bytes", block_size_at(&mb, 0, 1), 16384)
	teq_int(t, "100000 bytes at 32768 is 4 pieces", piece_count(&mb), 4)
	teq_i64(t, "the last piece is 1696 bytes", piece_size(&mb, 3), 1696)
	teq_int(t, "...which is one short block", blocks_in_piece(&mb, 3), 1)
	teq_int(t, "...of 1696 bytes", block_size_at(&mb, 3, 0), 1696)
	teq_int(t, "a block past the end is zero bytes", block_size_at(&mb, 3, 1), 0)
}

// ---------------------------------------------------------------------------
// Bitfields
// ---------------------------------------------------------------------------

test_bitfield :: proc(t: ^T) {
	tsection(t, "bitfields")

	b := bf_make(10, context.temp_allocator)
	teq_int(t, "10 pieces need 2 bytes", len(b.bits), 2)
	teq_int(t, "8 pieces need 1 byte", bf_bytes(8), 1)
	teq_int(t, "9 pieces need 2 bytes", bf_bytes(9), 2)
	teq_int(t, "1 piece needs 1 byte", bf_bytes(1), 1)
	teq_int(t, "0 pieces need 0 bytes", bf_bytes(0), 0)

	// Piece 0 is the HIGH bit of byte 0.
	bf_set(&b, 0, true)
	teq_int(t, "setting piece 0 gives byte 0 = 0x80", int(b.bits[0]), 0x80)
	bf_set(&b, 7, true)
	teq_int(t, "adding piece 7 gives byte 0 = 0x81", int(b.bits[0]), 0x81)
	bf_set(&b, 8, true)
	teq_int(t, "piece 8 is the high bit of byte 1", int(b.bits[1]), 0x80)
	teq_int(t, "three pieces are set", bf_count(b), 3)
	tcheck(t, "piece 0 reads back", bf_get(b, 0))
	tcheck(t, "piece 7 reads back", bf_get(b, 7))
	tcheck(t, "piece 8 reads back", bf_get(b, 8))
	tcheck(t, "piece 1 is clear", !bf_get(b, 1))
	tcheck(t, "piece 9 is clear", !bf_get(b, 9))
	tcheck(t, "piece 10 is out of range and reads false", !bf_get(b, 10))
	tcheck(t, "piece -1 reads false rather than crashing", !bf_get(b, -1))
	bf_set(&b, 0, false)
	tcheck(t, "clearing piece 0 works", !bf_get(b, 0))
	teq_int(t, "...leaving byte 0 = 0x01", int(b.bits[0]), 0x01)

	// The spare bits in the final byte.
	s := bf_make(10, context.temp_allocator)
	tcheck(t, "a fresh bitfield has clear spare bits", bf_spare_bits_clear(s))
	s.bits[1] = 0xC0 // pieces 8 and 9, which are real
	tcheck(t, "pieces 8 and 9 set is still legal", bf_spare_bits_clear(s))
	s.bits[1] = 0xC1 // bit 7 of byte 1 is piece 15, which does not exist
	tcheck(
		t,
		"a set spare bit is detected",
		!bf_spare_bits_clear(s),
		"a bitfield claiming a piece past the end was accepted",
	)
	s.bits[1] = 0x20 // piece 10, which does not exist either
	tcheck(t, "a spare bit just past the end is detected", !bf_spare_bits_clear(s))
	bf_clear_spare(&s)
	teq_int(t, "clear_spare zeroes it", int(s.bits[1]), 0)

	// A full byte boundary has no spare bits at all, so nothing can be wrong.
	e8 := bf_make(8, context.temp_allocator)
	e8.bits[0] = 0xff
	tcheck(t, "8 pieces in one byte: all bits are real", bf_spare_bits_clear(e8))
	tcheck(t, "...and it is complete", bf_complete(e8))
	teq_int(t, "...with 8 set", bf_count(e8), 8)

	// bf_fill clears the spare bits for you, which is what a seeder sends.
	f := bf_make(10, context.temp_allocator)
	bf_fill(&f)
	teq_int(t, "a filled 10-piece bitfield counts 10", bf_count(f), 10)
	tcheck(t, "...is complete", bf_complete(f))
	tcheck(t, "...and has clear spare bits", bf_spare_bits_clear(f))
	teq_int(t, "...with byte 0 = 0xff", int(f.bits[0]), 0xff)
	teq_int(t, "...and byte 1 = 0xc0", int(f.bits[1]), 0xc0)

	// From the wire.
	good := [2]u8{0xff, 0xc0}
	w, wok := bf_from_wire(good[:], 10, context.temp_allocator)
	tcheck(t, "a well-formed wire bitfield is accepted", wok)
	teq_int(t, "...and counts 10", bf_count(w), 10)
	bad := [2]u8{0xff, 0xff}
	_, bok := bf_from_wire(bad[:], 10, context.temp_allocator)
	tcheck(t, "a wire bitfield with spare bits set is REJECTED", !bok)
	short := [1]u8{0xff}
	_, sok := bf_from_wire(short[:], 10, context.temp_allocator)
	tcheck(t, "a wire bitfield of the wrong length is rejected", !sok)
	long := [3]u8{0xff, 0xc0, 0}
	_, lok := bf_from_wire(long[:], 10, context.temp_allocator)
	tcheck(t, "...including one byte too long", !lok)

	// Empty and first-missing.
	z := bf_make(5, context.temp_allocator)
	tcheck(t, "a fresh bitfield is empty", bf_empty(z))
	tcheck(t, "...and not complete", !bf_complete(z))
	teq_int(t, "...whose first missing piece is 0", bf_first_missing(z), 0)
	bf_set(&z, 0, true)
	bf_set(&z, 1, true)
	teq_int(t, "after two pieces the first missing is 2", bf_first_missing(z), 2)
	tcheck(t, "...and it is no longer empty", !bf_empty(z))
	bf_fill(&z)
	teq_int(t, "a complete bitfield has no missing piece", bf_first_missing(z), -1)

	// A one-piece torrent, where seven of the eight bits are spare.
	one := bf_make(1, context.temp_allocator)
	bf_set(&one, 0, true)
	teq_int(t, "one piece set is byte 0 = 0x80", int(one.bits[0]), 0x80)
	tcheck(t, "...with clear spare bits", bf_spare_bits_clear(one))
	tcheck(t, "...and it is complete", bf_complete(one))
	one.bits[0] = 0x81
	tcheck(t, "0x81 for a one-piece torrent has a spare bit set", !bf_spare_bits_clear(one))

	// Round trip over a non-trivial pattern.
	big := bf_make(100, context.temp_allocator)
	expect := 0
	for i in 0 ..< 100 {
		if i % 7 == 0 || i % 11 == 3 {
			bf_set(&big, i, true)
			expect += 1
		}
	}
	teq_int(t, "a 100-piece pattern counts correctly", bf_count(big), expect)
	ok := true
	for i in 0 ..< 100 {
		want := i % 7 == 0 || i % 11 == 3
		if bf_get(big, i) != want {
			ok = false
			break
		}
	}
	tcheck(t, "...and every bit reads back", ok)
	tcheck(t, "...with clear spare bits", bf_spare_bits_clear(big))
}

// ---------------------------------------------------------------------------
// Percent-encoding
// ---------------------------------------------------------------------------

test_percent_encoding :: proc(t: ^T) {
	tsection(t, "percent-encoding of binary info-hashes")

	// Computed with Python's urllib.parse.quote(..., safe="-_.~").
	ih1, _ := hex_decode("123456789abcdef123456789abcdef123456789a", context.temp_allocator)
	teq(
		t,
		"the classic info-hash encodes exactly",
		url_encode_bytes(ih1, context.temp_allocator),
		"%124Vx%9A%BC%DE%F1%23Eg%89%AB%CD%EF%124Vx%9A",
	)
	ih2 := make([]u8, 20, context.temp_allocator)
	for i in 0 ..< 20 {
		ih2[i] = u8(i)
	}
	teq(
		t,
		"the bytes 0..19 encode exactly",
		url_encode_bytes(ih2, context.temp_allocator),
		"%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13",
	)
	ih3 := make([]u8, 20, context.temp_allocator)
	for i in 0 ..< 20 {
		ih3[i] = 0xff
	}
	teq(
		t,
		"twenty 0xff bytes encode to twenty %FF",
		url_encode_bytes(ih3, context.temp_allocator),
		"%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF%FF",
	)
	// The unreserved set passes through; everything else does not.
	teq(
		t,
		"the unreserved set is untouched",
		url_encode("ABCZabcz0189-_.~", context.temp_allocator),
		"ABCZabcz0189-_.~",
	)
	teq(t, "a space is %20, not +", url_encode(" ", context.temp_allocator), "%20")
	teq(t, "a plus is escaped", url_encode("+", context.temp_allocator), "%2B")
	teq(t, "a slash is escaped", url_encode("/", context.temp_allocator), "%2F")
	teq(t, "an ampersand is escaped", url_encode("&", context.temp_allocator), "%26")
	teq(t, "an equals is escaped", url_encode("=", context.temp_allocator), "%3D")
	teq(t, "a percent is escaped", url_encode("%", context.temp_allocator), "%25")
	teq(t, "the hex digits are uppercase", url_encode("\xab", context.temp_allocator), "%AB")

	// The bug this is all about: a 20-byte hash must encode to a string that
	// decodes back to exactly those 20 bytes. A UTF-8-aware escaper would turn
	// each invalid byte into U+FFFD and this would be 60 bytes of replacement
	// characters.
	round := url_decode(url_encode_bytes(ih1, context.temp_allocator), context.temp_allocator)
	teq_int(t, "a binary hash round-trips to 20 bytes", len(round), 20)
	tcheck(t, "...and the same 20 bytes", slice.equal(transmute([]u8)round, ih1))
	all := make([]u8, 256, context.temp_allocator)
	for i in 0 ..< 256 {
		all[i] = u8(i)
	}
	round2 := url_decode(url_encode_bytes(all, context.temp_allocator), context.temp_allocator)
	teq_int(t, "every byte value round-trips", len(round2), 256)
	same := len(round2) == 256
	if same {
		for i in 0 ..< 256 {
			if round2[i] != u8(i) {same = false;break}
		}
	}
	tcheck(t, "...byte for byte", same)

	// Decoding.
	teq(t, "%20 decodes to a space", url_decode("a%20b", context.temp_allocator), "a b")
	teq(t, "lowercase hex decodes too", url_decode("%ab", context.temp_allocator), "\xab")
	teq(t, "a stray percent is left alone", url_decode("100%", context.temp_allocator), "100%")
	teq(t, "a truncated escape is left alone", url_decode("a%4", context.temp_allocator), "a%4")
	teq(t, "a non-hex escape is left alone", url_decode("%zz", context.temp_allocator), "%zz")

	// And the query parser, which is what the tracker uses to read it back.
	q := asprint("info_hash=%s&port=6881", url_encode_bytes(ih1, context.temp_allocator))
	got, qok := query_param(q, "info_hash", context.temp_allocator)
	tcheck(t, "the tracker side finds info_hash", qok)
	teq_int(t, "...as 20 bytes", len(got), 20)
	tcheck(t, "...the right 20 bytes", slice.equal(got, ih1))
	teq_i64(t, "...and reads the port", query_param_int(q, "port", 0), 6881)
	teq_i64(t, "a missing parameter takes the default", query_param_int(q, "left", -7), -7)
}

// ---------------------------------------------------------------------------
// The announce request and response
// ---------------------------------------------------------------------------

test_announce_query :: proc(t: ^T) {
	tsection(t, "the announce query")

	ih, _ := hash20_from_hex("123456789abcdef123456789abcdef123456789a")
	pid: [20]u8
	copy(pid[:], "-PY0100-abcdefghijkl")
	req := Announce_Req {
		info_hash  = ih,
		peer_id    = pid,
		port       = 6881,
		uploaded   = 0,
		downloaded = 0,
		left       = 1000,
		event      = .Started,
		numwant    = 50,
		key        = 7,
	}
	q := announce_query("/announce", req, context.temp_allocator)
	tcheck(t, "the query starts at the target", strings.has_prefix(q, "/announce?"))
	tcheck(
		t,
		"the info-hash is the raw-byte encoding",
		strings.contains(q, "info_hash=%124Vx%9A%BC%DE%F1%23Eg%89%AB%CD%EF%124Vx%9A"),
		q,
	)
	tcheck(
		t,
		"the peer id is printable and passes through",
		strings.contains(q, "peer_id=-PY0100-abcdefghijkl"),
		q,
	)
	tcheck(t, "the port is there", strings.contains(q, "&port=6881"))
	tcheck(t, "uploaded is there", strings.contains(q, "&uploaded=0"))
	tcheck(t, "downloaded is there", strings.contains(q, "&downloaded=0"))
	tcheck(t, "left is there", strings.contains(q, "&left=1000"))
	tcheck(t, "compact=1 is asked for", strings.contains(q, "&compact=1"))
	tcheck(t, "the event is `started`", strings.contains(q, "&event=started"))
	tcheck(t, "numwant is there", strings.contains(q, "&numwant=50"))

	req.event = .Completed
	tcheck(
		t,
		"`completed` is spelled right",
		strings.contains(announce_query("/a", req, context.temp_allocator), "&event=completed"),
	)
	req.event = .Stopped
	tcheck(
		t,
		"`stopped` is spelled right",
		strings.contains(announce_query("/a", req, context.temp_allocator), "&event=stopped"),
	)
	req.event = .None
	tcheck(
		t,
		"no event means no event parameter at all",
		!strings.contains(announce_query("/a", req, context.temp_allocator), "event="),
	)
	// A tracker URL that already has a query gets `&`, not a second `?`.
	q2 := announce_query("/announce?x=1", req, context.temp_allocator)
	tcheck(t, "an existing query is appended to with &", strings.has_prefix(q2, "/announce?x=1&"), q2)
	teq_int(t, "...and there is only one `?`", strings.count(q2, "?"), 1)

	// A hash with a byte that happens to be an unreserved character still
	// comes out right, because the rule is per byte.
	ih2: Hash20
	for i in 0 ..< 20 {
		ih2[i] = 'A'
	}
	req.info_hash = ih2
	tcheck(
		t,
		"a hash of printable bytes is not escaped",
		strings.contains(
			announce_query("/a", req, context.temp_allocator),
			"info_hash=AAAAAAAAAAAAAAAAAAAA",
		),
	)
}

test_announce_parse :: proc(t: ^T) {
	tsection(t, "the announce response")

	// A compact response with two peers: 127.0.0.1:6881 and 127.0.0.2:51413.
	peers := make([dynamic]u8, 0, 12, context.temp_allocator)
	append(&peers, 127, 0, 0, 1)
	append_be_u16(&peers, 6881)
	append(&peers, 127, 0, 0, 2)
	append_be_u16(&peers, 51413)
	body := bcat(
		context.temp_allocator,
		sv("d8:completei3e10:incompletei7e8:intervali1800e12:min intervali60e5:peers12:"),
		peers[:],
		sv("e"),
	)
	r, e := announce_parse(body, context.temp_allocator)
	teq(t, "a compact response parses", e, "")
	teq_int(t, "interval is 1800", r.interval, 1800)
	teq_int(t, "min interval is 60", r.min_interval, 60)
	teq_int(t, "3 seeders", r.complete, 3)
	teq_int(t, "7 leechers", r.incomplete, 7)
	teq_int(t, "two peers", len(r.peers), 2)
	teq(t, "the first peer's address", r.peers[0].host, "127.0.0.1")
	teq_int(t, "the first peer's port", r.peers[0].port, 6881)
	teq(t, "the second peer's address", r.peers[1].host, "127.0.0.2")
	teq_int(t, "the second peer's port is big-endian", r.peers[1].port, 51413)

	// The non-compact (dictionary) form, which plenty of trackers still send.
	dict_body := sv(
		"d8:intervali900e5:peersld2:ip9:127.0.0.14:porti6881eed2:ip9:127.0.0.34:porti1234eeee",
	)
	r2, e2 := announce_parse(dict_body, context.temp_allocator)
	teq(t, "the dictionary form parses", e2, "")
	teq_int(t, "two peers again", len(r2.peers), 2)
	teq(t, "the first", r2.peers[0].host, "127.0.0.1")
	teq_int(t, "...on 6881", r2.peers[0].port, 6881)
	teq(t, "the second", r2.peers[1].host, "127.0.0.3")
	teq_int(t, "...on 1234", r2.peers[1].port, 1234)
	teq_int(t, "interval is 900", r2.interval, 900)

	// A failure.
	r3, e3 := announce_parse(sv("d14:failure reason17:torrent not founde"), context.temp_allocator)
	teq(t, "a failure response parses", e3, "")
	teq(t, "...and carries the reason", r3.failure, "torrent not found")
	teq_int(t, "...with no peers", len(r3.peers), 0)

	// A warning alongside a working response.
	r4, _ := announce_parse(
		sv("d15:warning message5:hmmm 8:intervali60e5:peers0:e"),
		context.temp_allocator,
	)
	teq(t, "a warning is reported", r4.warning, "hmmm ")
	teq_int(t, "...and the response still works", r4.interval, 60)

	// Malformed responses are errors, not crashes.
	_, be1 := announce_parse(sv("not bencoded at all"), context.temp_allocator)
	tcheck(t, "a non-bencoded response is refused", be1 != "")
	_, be2 := announce_parse(sv("li1ee"), context.temp_allocator)
	tcheck(t, "a list at the top level is refused", be2 != "")
	_, be3 := announce_parse(sv("d5:peers5:12345e"), context.temp_allocator)
	tcheck(t, "a compact peer list that is not a multiple of 6 is refused", be3 != "")
	r5, _ := announce_parse(sv("d5:peers0:e"), context.temp_allocator)
	teq_int(t, "an empty peer list is zero peers, not an error", len(r5.peers), 0)
	teq_int(t, "...and a missing interval defaults to 1800", r5.interval, 1800)

	// parse_compact_peers on its own.
	short := [5]u8{127, 0, 0, 1, 0}
	_, pe := parse_compact_peers(short[:], context.temp_allocator)
	tcheck(t, "five bytes is not a compact peer", pe != "")
	zero := [6]u8{127, 0, 0, 1, 0, 0}
	zp, _ := parse_compact_peers(zero[:], context.temp_allocator)
	teq_int(t, "a peer on port 0 is dropped", len(zp), 0)
	dup := make([dynamic]u8, 0, 12, context.temp_allocator)
	append(&dup, 127, 0, 0, 1)
	append_be_u16(&dup, 1234)
	append(&dup, 127, 0, 0, 1)
	append_be_u16(&dup, 1234)
	dp, _ := parse_compact_peers(dup[:], context.temp_allocator)
	teq_int(t, "a duplicated peer appears once", len(dp), 1)

	// A compact list carrying a ROUTABLE address. The parser does not filter —
	// filtering is the connect gate's job — so this asserts the address comes
	// through here and dies there.
	routable := make([dynamic]u8, 0, 6, context.temp_allocator)
	append(&routable, 8, 8, 8, 8)
	append_be_u16(&routable, 6881)
	rp, _ := parse_compact_peers(routable[:], context.temp_allocator)
	teq_int(t, "a routable peer is parsed", len(rp), 1)
	teq(t, "...as 8.8.8.8", rp[0].host, "8.8.8.8")
	_, cerr := sock_connect(rp[0].host, rp[0].port)
	tcheck(
		t,
		"...and connecting to it is REFUSED",
		cerr != "",
		"a tracker could have sent us at a real host",
	)
	tcheck(t, "...with loopback named as the reason", strings.contains(cerr, "loopback"), cerr)

	// encode_compact_peers, which the tracker uses.
	enc := encode_compact_peers(
		{{host = "127.0.0.1", port = 6881}, {host = "127.0.0.2", port = 51413}},
		context.temp_allocator,
	)
	teq_int(t, "two peers encode to 12 bytes", len(enc), 12)
	back, _ := parse_compact_peers(enc, context.temp_allocator)
	tcheck(t, "...and round-trip", peer_addrs_equal(back, {{host = "127.0.0.1", port = 6881}, {host = "127.0.0.2", port = 51413}}))
	enc2 := encode_compact_peers({{host = "8.8.8.8", port = 1}}, context.temp_allocator)
	teq_int(t, "the tracker will not even encode a non-loopback peer", len(enc2), 0)
}

// ---------------------------------------------------------------------------
// The UDP tracker protocol
// ---------------------------------------------------------------------------

test_udp_tracker :: proc(t: ^T) {
	tsection(t, "the UDP tracker protocol (BEP 15)")

	c := udp_connect_packet(0xDEADBEEF)
	teq_int(t, "a connect packet is 16 bytes", len(c), 16)
	tcheck(
		t,
		"it begins with the magic protocol id 0x41727101980",
		be_u64(c[0:8]) == 0x41727101980,
		asprint("got 0x%x", be_u64(c[0:8])),
	)
	teq_int(t, "action 0 is connect", int(be_u32(c[8:12])), 0)
	tcheck(t, "the transaction id is carried", be_u32(c[12:16]) == 0xDEADBEEF)

	// A well-formed connect answer.
	ans := make([dynamic]u8, 0, 16, context.temp_allocator)
	append_be_u32(&ans, 0) // action: connect
	append_be_u32(&ans, 0xDEADBEEF)
	append_be_u64(&ans, 0x1122334455667788)
	cid, ce := udp_parse_connect(ans[:], 0xDEADBEEF)
	teq(t, "the connect answer parses", ce, "")
	tcheck(t, "...giving the connection id", cid == 0x1122334455667788, asprint("got 0x%x", cid))

	// A mismatched transaction id must be refused: that is the whole defence
	// against a spoofed datagram.
	_, me := udp_parse_connect(ans[:], 0xCAFEBABE)
	tcheck(t, "a mismatched transaction id is REFUSED", me != "")
	_, se := udp_parse_connect(ans[:8], 0xDEADBEEF)
	tcheck(t, "a truncated connect answer is refused", se != "")
	errp := make([dynamic]u8, 0, 16, context.temp_allocator)
	append_be_u32(&errp, 3) // action: error
	append_be_u32(&errp, 0xDEADBEEF)
	append(&errp, ..sv("go away"))
	_, ee := udp_parse_connect(errp[:], 0xDEADBEEF)
	tcheck(t, "an error action is refused", ee != "")
	tcheck(t, "...and the message is reported", strings.contains(ee, "go away"), ee)

	// The announce packet.
	ih, _ := hash20_from_hex("123456789abcdef123456789abcdef123456789a")
	pid: [20]u8
	copy(pid[:], "-PY0100-abcdefghijkl")
	req := Announce_Req {
		info_hash  = ih,
		peer_id    = pid,
		port       = 6881,
		downloaded = 100,
		left       = 200,
		uploaded   = 300,
		event      = .Started,
		numwant    = 30,
		key        = 0x01020304,
	}
	a := udp_announce_packet(0x1122334455667788, 0xABCDEF01, req)
	teq_int(t, "an announce packet is 98 bytes", len(a), 98)
	tcheck(t, "it carries the connection id", be_u64(a[0:8]) == 0x1122334455667788)
	teq_int(t, "action 1 is announce", int(be_u32(a[8:12])), 1)
	tcheck(t, "it carries the transaction id", be_u32(a[12:16]) == 0xABCDEF01)
	ihv := ih
	tcheck(t, "the info-hash is 20 raw bytes at offset 16", slice.equal(a[16:36], ihv[:]))
	tcheck(t, "the peer id is 20 raw bytes at offset 36", string(a[36:56]) == "-PY0100-abcdefghijkl")
	teq_i64(t, "downloaded is at offset 56", i64(be_u64(a[56:64])), 100)
	teq_i64(t, "left is at offset 64", i64(be_u64(a[64:72])), 200)
	teq_i64(t, "uploaded is at offset 72", i64(be_u64(a[72:80])), 300)
	// The UDP event numbering is its own thing: 0 none, 1 completed,
	// 2 started, 3 stopped.
	teq_int(t, "`started` is event 2 over UDP, not 1", int(be_u32(a[80:84])), 2)
	req.event = .Completed
	a2 := udp_announce_packet(1, 2, req)
	teq_int(t, "`completed` is event 1", int(be_u32(a2[80:84])), 1)
	req.event = .Stopped
	a3 := udp_announce_packet(1, 2, req)
	teq_int(t, "`stopped` is event 3", int(be_u32(a3[80:84])), 3)
	req.event = .None
	a4 := udp_announce_packet(1, 2, req)
	teq_int(t, "no event is 0", int(be_u32(a4[80:84])), 0)
	teq_int(t, "the ip field is 0, meaning `use the source address`", int(be_u32(a[84:88])), 0)
	tcheck(t, "the key is carried", be_u32(a[88:92]) == 0x01020304)
	teq_int(t, "numwant is carried", int(be_u32(a[92:96])), 30)
	teq_int(t, "the port is the last two bytes", int(be_u16(a[96:98])), 6881)
	req.numwant = 0
	a5 := udp_announce_packet(1, 2, req)
	tcheck(t, "numwant 0 becomes -1 (`the default`)", be_u32(a5[92:96]) == 0xffffffff)

	// The announce answer.
	ansa := make([dynamic]u8, 0, 32, context.temp_allocator)
	append_be_u32(&ansa, 1) // action: announce
	append_be_u32(&ansa, 0xABCDEF01)
	append_be_u32(&ansa, 1800) // interval
	append_be_u32(&ansa, 7) // leechers
	append_be_u32(&ansa, 3) // seeders
	append(&ansa, 127, 0, 0, 1)
	append_be_u16(&ansa, 6881)
	ar, aerr := udp_parse_announce(ansa[:], 0xABCDEF01, context.temp_allocator)
	teq(t, "the announce answer parses", aerr, "")
	teq_int(t, "interval 1800", ar.interval, 1800)
	teq_int(t, "7 leechers", ar.incomplete, 7)
	teq_int(t, "3 seeders", ar.complete, 3)
	teq_int(t, "one peer", len(ar.peers), 1)
	teq(t, "...at 127.0.0.1", ar.peers[0].host, "127.0.0.1")
	teq_int(t, "...on 6881", ar.peers[0].port, 6881)
	_, awerr := udp_parse_announce(ansa[:], 0x11111111, context.temp_allocator)
	tcheck(t, "a mismatched transaction id is refused here too", awerr != "")
	_, aterr := udp_parse_announce(ansa[:12], 0xABCDEF01, context.temp_allocator)
	tcheck(t, "a truncated announce answer is refused", aterr != "")
}

// ---------------------------------------------------------------------------
// The handshake
// ---------------------------------------------------------------------------

test_handshake :: proc(t: ^T) {
	tsection(t, "the peer handshake")

	ih, _ := hash20_from_hex("123456789abcdef123456789abcdef123456789a")
	pid := peer_id_new(1234)
	hs := handshake_encode(ih, pid, context.temp_allocator)
	teq_int(t, "the handshake is 68 bytes", len(hs), HANDSHAKE_LEN)
	teq_int(t, "the first byte is 19", int(hs[0]), 19)
	teq(t, "followed by the protocol name", string(hs[1:20]), "BitTorrent protocol")
	reserved_zero := true
	for i in 20 ..< 28 {
		if hs[i] != 0 {reserved_zero = false}
	}
	tcheck(
		t,
		"the eight reserved bytes are all zero",
		reserved_zero,
		"this client advertises no extensions, deliberately: no DHT, no PEX",
	)
	ihv := ih
	tcheck(t, "the info-hash is at offset 28", slice.equal(hs[28:48], ihv[:]))
	pidv := pid
	tcheck(t, "the peer id is at offset 48", slice.equal(hs[48:68], pidv[:]))

	// Decoding it back, one byte at a time, which is also a framing test.
	f: Framer
	framer_init(&f)
	defer framer_destroy(&f)
	for i in 0 ..< 67 {
		framer_feed(&f, hs[i:i + 1])
		_, st := framer_take_handshake(&f, ih)
		if st != .Incomplete {
			tcheck(t, asprint("the handshake is incomplete at %d bytes", i + 1), false, "it was accepted early")
			break
		}
	}
	tcheck(t, "67 bytes of handshake is not a handshake", framer_buffered(&f) == 67)
	framer_feed(&f, hs[67:68])
	h, st := framer_take_handshake(&f, ih)
	tcheck(t, "the 68th byte completes it", st == .Ready)
	tcheck(t, "...giving the peer id", h.peer_id == pid)
	tcheck(t, "...and the info-hash", hash20_eq(h.info_hash, ih))
	teq_int(t, "...and consuming all 68 bytes", framer_buffered(&f), 0)

	// A handshake for the wrong torrent.
	other, _ := hash20_from_hex("0000000000000000000000000000000000000000")
	f2: Framer
	framer_init(&f2)
	defer framer_destroy(&f2)
	framer_feed(&f2, hs)
	_, st2 := framer_take_handshake(&f2, other)
	tcheck(t, "a handshake for another info-hash is rejected", st2 == .Bad)
	tcheck(t, "...and says so", strings.contains(f2.err, "info-hash"), f2.err)

	// Garbage: the very first byte gives it away.
	f3: Framer
	framer_init(&f3)
	defer framer_destroy(&f3)
	framer_feed(&f3, sv("GET / HTTP/1.1\r\n"))
	_, st3 := framer_take_handshake(&f3, ih)
	tcheck(
		t,
		"an HTTP request on the peer port is rejected on byte 1",
		st3 == .Bad,
		"we waited for 68 bytes of nonsense",
	)

	// The right length but the wrong protocol name.
	wrong := make([]u8, HANDSHAKE_LEN, context.temp_allocator)
	copy(wrong, hs)
	wrong[1] = 'X'
	f4: Framer
	framer_init(&f4)
	defer framer_destroy(&f4)
	framer_feed(&f4, wrong)
	_, st4 := framer_take_handshake(&f4, ih)
	tcheck(t, "a handshake naming another protocol is rejected", st4 == .Bad)

	// Peer ids.
	teq(t, "our peer id has the Azureus-style prefix", string(pidv[0:8]), "-PY1000-")
	teq_int(t, "...and is 20 bytes", len(pidv), 20)
	p2 := peer_id_new(1234)
	tcheck(t, "the same seed gives the same id", p2 == pid)
	p3 := peer_id_new(5678)
	tcheck(t, "a different seed gives a different id", p3 != pid)
	teq(t, "a palmy peer id is recognised", peer_client_name(pid, context.temp_allocator), "palmy 1.0.0")
	qb: [20]u8
	copy(qb[:], "-qB4650-k3jf93ks8dkd")
	teq(t, "a qBittorrent peer id is recognised", peer_client_name(qb, context.temp_allocator), "qBittorrent 4.6.5")
	junk: [20]u8
	teq(t, "an unrecognised peer id says so", peer_client_name(junk, context.temp_allocator), "unknown")
}

// ---------------------------------------------------------------------------
// Framing — the heart of it
// ---------------------------------------------------------------------------

// These assertions run against canned byte arrays. There is no socket here, so
// every split that a real network could produce can be reproduced exactly.
test_framing :: proc(t: ^T) {
	tsection(t, "message framing off a byte stream (no socket)")

	// Build a stream by hand, byte by byte, so the expected framing is a
	// property of the bytes and not of the encoder.
	//   unchoke:     00 00 00 01 01
	//   have 7:      00 00 00 05 04 00 00 00 07
	//   keep-alive:  00 00 00 00
	//   interested:  00 00 00 01 02
	stream := make([dynamic]u8, 0, 64, context.temp_allocator)
	append(&stream, 0, 0, 0, 1, 1) // unchoke
	append(&stream, 0, 0, 0, 5, 4, 0, 0, 0, 7) // have 7
	append(&stream, 0, 0, 0, 0) // keep-alive
	append(&stream, 0, 0, 0, 1, 2) // interested
	teq_int(t, "the canned stream is 23 bytes", len(stream), 23)

	// 1. All at once: four messages out of one feed.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		framer_feed(&f, stream[:])
		ids := make([dynamic]int, 0, 8, context.temp_allocator)
		for {
			m, st := framer_next(&f)
			if st != .Ready {
				tcheck(t, "no framing error on the whole stream", st == .Incomplete, f.err)
				break
			}
			append(&ids, int(m.id))
			if m.id == .Have {
				teq_int(t, "the have carries piece 7", int(m.index), 7)
			}
		}
		teq_int(t, "one feed of 22 bytes yields four messages", len(ids), 4)
		tints(
			t,
			"...in order: unchoke, have, keep-alive, interested",
			ids[:],
			{int(Msg_Id.Unchoke), int(Msg_Id.Have), int(Msg_Id.Keep_Alive), int(Msg_Id.Interested)},
		)
	}

	// 2. THREE MESSAGES IN ONE READ, with nothing left over.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		framer_feed(&f, stream[:18]) // unchoke + have + keep-alive
		m1, s1 := framer_next(&f)
		m2, s2 := framer_next(&f)
		m3, s3 := framer_next(&f)
		_, s4 := framer_next(&f)
		tcheck(t, "three messages in one read: the first is there", s1 == .Ready)
		tcheck(t, "...the second too", s2 == .Ready)
		tcheck(t, "...and the third", s3 == .Ready)
		tcheck(t, "...and then nothing more", s4 == .Incomplete)
		tcheck(t, "the first is unchoke", m1.id == .Unchoke)
		tcheck(t, "the second is have", m2.id == .Have)
		teq_int(t, "...for piece 7", int(m2.index), 7)
		tcheck(t, "the third is a keep-alive", m3.id == .Keep_Alive)
		teq_int(t, "nothing is left in the buffer", framer_buffered(&f), 0)
	}

	// 3. ONE MESSAGE SPLIT ACROSS THREE READS. The have message is 9 bytes;
	//    feed 3, then 3, then 3.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		have := stream[5:14] // the 9-byte have message
		teq_int(t, "the have message is 9 bytes", len(have), 9)

		framer_feed(&f, have[0:3]) // not even the length prefix
		_, a := framer_next(&f)
		tcheck(t, "3 of 9 bytes: incomplete", a == .Incomplete)
		teq_int(t, "...and nothing was consumed", framer_buffered(&f), 3)

		framer_feed(&f, have[3:6]) // the length and the id and one byte
		_, b := framer_next(&f)
		tcheck(t, "6 of 9 bytes: still incomplete", b == .Incomplete)
		teq_int(t, "...and still nothing consumed", framer_buffered(&f), 6)

		framer_feed(&f, have[6:9])
		m, c := framer_next(&f)
		tcheck(t, "9 of 9 bytes: READY", c == .Ready)
		tcheck(t, "...and it is a have", m.id == .Have)
		teq_int(t, "...for piece 7", int(m.index), 7)
		teq_int(t, "...having consumed all nine bytes", framer_buffered(&f), 0)
	}

	// 4. A piece message split so the split lands inside the payload, which is
	//    what actually happens on a real network with a 16 KiB block.
	{
		block := make([]u8, BLOCK_SIZE, context.temp_allocator)
		for i in 0 ..< len(block) {
			block[i] = u8(i * 7 + 3)
		}
		wire := make([dynamic]u8, 0, BLOCK_SIZE + 16, context.temp_allocator)
		msg_piece(&wire, 42, 32768, block)
		teq_int(t, "a 16 KiB piece message is 16397 bytes on the wire", len(wire), 4 + 9 + BLOCK_SIZE)

		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		// The classic MTU-sized dribble.
		off := 0
		for chunk in ([?]int{1, 4, 8, 1448, 1448, 1448, 5000}) {
			n := min(chunk, len(wire) - off)
			framer_feed(&f, wire[off:off + n])
			off += n
			_, st := framer_next(&f)
			if st == .Ready {
				tcheck(t, "the piece message was not framed early", false, asprint("ready after %d of %d bytes", off, len(wire)))
				break
			}
		}
		framer_feed(&f, wire[off:])
		m, st := framer_next(&f)
		tcheck(t, "a 16 KiB piece reassembles from seven reads", st == .Ready)
		tcheck(t, "...as a piece message", m.id == .Piece)
		teq_int(t, "...for piece 42", int(m.index), 42)
		teq_int(t, "...at offset 32768", int(m.begin), 32768)
		teq_int(t, "...with a 16384-byte block", len(m.payload), BLOCK_SIZE)
		tcheck(t, "...byte for byte", slice.equal(m.payload, block))
	}

	// 5. A TRUNCATED MESSAGE: the stream ends mid-message and stays
	//    incomplete forever rather than being guessed at.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		trunc := make([dynamic]u8, 0, 8, context.temp_allocator)
		append(&trunc, 0, 0, 0, 13, 6, 0, 0, 0, 1) // a request, 8 bytes short
		framer_feed(&f, trunc[:])
		_, st := framer_next(&f)
		tcheck(t, "a truncated request stays incomplete", st == .Incomplete)
		teq_int(t, "...with every byte still buffered", framer_buffered(&f), 9)
		_, st2 := framer_next(&f)
		tcheck(t, "...and calling again does not change that", st2 == .Incomplete)
		// Only when the rest arrives does it become a message.
		framer_feed(&f, []u8{0, 2, 0, 0, 0, 0, 64, 0})
		m, st3 := framer_next(&f)
		tcheck(t, "...and completing it yields the request", st3 == .Ready)
		teq_int(t, "...for piece 1", int(m.index), 1)
		teq_int(t, "...at offset 131072", int(m.begin), 131072)
		teq_int(t, "...of 16384 bytes", int(m.length), 16384)
	}

	// 6. A ZERO-LENGTH KEEP-ALIVE on its own, and several in a row.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		framer_feed(&f, []u8{0, 0, 0, 0})
		m, st := framer_next(&f)
		tcheck(t, "a zero length is a keep-alive, not an error", st == .Ready)
		tcheck(t, "...identified as such", m.id == .Keep_Alive)
		teq_int(t, "...with no payload", len(m.payload), 0)
		teq_int(t, "...consuming four bytes", framer_buffered(&f), 0)

		framer_feed(&f, []u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
		n := 0
		for {
			_, s := framer_next(&f)
			if s != .Ready {break}
			n += 1
		}
		teq_int(t, "three keep-alives in one read are three messages", n, 3)

		// Three bytes of a keep-alive is not one.
		framer_feed(&f, []u8{0, 0, 0})
		_, s3 := framer_next(&f)
		tcheck(t, "three bytes is not yet a keep-alive", s3 == .Incomplete)
	}

	// 7. A LENGTH PREFIX THAT IS A LIE. 0xFFFFFFFF is 4 GiB; believing it is a
	//    one-packet denial of service.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		framer_feed(&f, []u8{0xff, 0xff, 0xff, 0xff, 7})
		_, st := framer_next(&f)
		tcheck(t, "a 4 GiB length prefix is REFUSED", st == .Bad)
		tcheck(t, "...and says why", strings.contains(f.err, "cap"), f.err)
	}
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		// Just over the cap.
		hdr := [4]u8{}
		put_be_u32(hdr[:], u32(MAX_MESSAGE + 1))
		framer_feed(&f, hdr[:])
		_, st := framer_next(&f)
		tcheck(t, "one byte over the cap is refused", st == .Bad)
	}
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		hdr := [4]u8{}
		put_be_u32(hdr[:], u32(MAX_MESSAGE))
		framer_feed(&f, hdr[:])
		_, st := framer_next(&f)
		tcheck(t, "exactly the cap is merely incomplete", st == .Incomplete)
	}

	// 8. Messages whose payload length is wrong for their id.
	{
		bad :: proc(t: ^T, name: string, bytes: []u8) {
			f: Framer
			framer_init(&f)
			defer framer_destroy(&f)
			framer_feed(&f, bytes)
			_, st := framer_next(&f)
			tcheck(t, name, st == .Bad, "it was accepted")
		}
		bad(t, "an unchoke with a payload is refused", {0, 0, 0, 2, 1, 9})
		bad(t, "a have of 3 bytes is refused", {0, 0, 0, 4, 4, 0, 0, 0})
		bad(t, "a have of 5 bytes is refused", {0, 0, 0, 6, 4, 0, 0, 0, 0, 0})
		bad(t, "a request of 8 bytes is refused", {0, 0, 0, 9, 6, 0, 0, 0, 0, 0, 0, 0, 0})
		bad(t, "a cancel of 4 bytes is refused", {0, 0, 0, 5, 8, 0, 0, 0, 0})
		bad(t, "a piece with no header is refused", {0, 0, 0, 5, 7, 0, 0, 0, 0})
		bad(t, "a port of 1 byte is refused", {0, 0, 0, 2, 9, 0})
	}

	// 9. An unknown message id is ignored, not fatal. Clients do send them.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		framer_feed(&f, []u8{0, 0, 0, 3, 99, 1, 2, 0, 0, 0, 1, 1})
		m, st := framer_next(&f)
		tcheck(t, "an unknown message id is accepted and skipped", st == .Ready)
		teq_int(t, "...with its payload available", len(m.payload), 2)
		m2, st2 := framer_next(&f)
		tcheck(t, "...and the next message still frames", st2 == .Ready)
		tcheck(t, "...as unchoke", m2.id == .Unchoke)
	}

	// 10. A bitfield message, whose payload length is whatever it is.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		framer_feed(&f, []u8{0, 0, 0, 4, 5, 0xff, 0xc0, 0x00})
		m, st := framer_next(&f)
		tcheck(t, "a bitfield message frames", st == .Ready)
		tcheck(t, "...as a bitfield", m.id == .Bitfield)
		teq_int(t, "...with three payload bytes", len(m.payload), 3)
		teq_int(t, "...the first being 0xff", int(m.payload[0]), 0xff)
	}

	// 11. The buffer compaction does not lose a partial message.
	{
		f: Framer
		framer_init(&f)
		defer framer_destroy(&f)
		framer_feed(&f, stream[:])
		for {
			_, st := framer_next(&f)
			if st != .Ready {break}
		}
		framer_feed(&f, []u8{0, 0, 0, 5, 4}) // half a have
		framer_compact(&f)
		teq_int(t, "after compaction only the partial message remains", framer_buffered(&f), 5)
		framer_feed(&f, []u8{0, 0, 0, 11})
		m, st := framer_next(&f)
		tcheck(t, "...and it completes across the compaction", st == .Ready)
		teq_int(t, "...as a have for piece 11", int(m.index), 11)
	}
}

test_message_encoding :: proc(t: ^T) {
	tsection(t, "message encoding")
	hex :: proc(b: []u8) -> string {
		return hex_encode(b, context.temp_allocator)
	}
	out := make([dynamic]u8, 0, 64, context.temp_allocator)

	clear(&out);msg_keep_alive(&out)
	teq(t, "keep-alive is four zero bytes", hex(out[:]), "00000000")
	clear(&out);msg_simple(&out, .Choke)
	teq(t, "choke", hex(out[:]), "0000000100")
	clear(&out);msg_simple(&out, .Unchoke)
	teq(t, "unchoke", hex(out[:]), "0000000101")
	clear(&out);msg_simple(&out, .Interested)
	teq(t, "interested", hex(out[:]), "0000000102")
	clear(&out);msg_simple(&out, .Not_Interested)
	teq(t, "not interested", hex(out[:]), "0000000103")
	clear(&out);msg_have(&out, 7)
	teq(t, "have 7", hex(out[:]), "000000050400000007")
	clear(&out);msg_have(&out, 0x01020304)
	teq(t, "have 0x01020304 is big-endian", hex(out[:]), "000000050401020304")
	clear(&out);msg_request(&out, 1, 16384, 16384)
	teq(t, "request(1, 16384, 16384)", hex(out[:]), "0000000d06000000010000400000004000")
	clear(&out);msg_cancel(&out, 1, 16384, 16384)
	teq(t, "cancel(1, 16384, 16384)", hex(out[:]), "0000000d08000000010000400000004000")
	clear(&out);msg_piece(&out, 1, 0, {0xaa, 0xbb})
	teq(t, "piece(1, 0, 2 bytes)", hex(out[:]), "0000000b070000000100000000aabb")

	bf := bf_make(10, context.temp_allocator)
	bf_fill(&bf)
	clear(&out);msg_bitfield(&out, bf)
	teq(t, "a full 10-piece bitfield", hex(out[:]), "0000000305ffc0")

	// Everything this encoder writes must frame back identically.
	clear(&out)
	msg_simple(&out, .Unchoke)
	msg_have(&out, 3)
	msg_request(&out, 2, 32768, 16384)
	msg_keep_alive(&out)
	msg_piece(&out, 2, 0, {1, 2, 3})
	msg_cancel(&out, 2, 0, 3)
	msg_bitfield(&out, bf)
	f: Framer
	framer_init(&f)
	defer framer_destroy(&f)
	framer_feed(&f, out[:])
	ids := make([dynamic]int, 0, 8, context.temp_allocator)
	for {
		m, st := framer_next(&f)
		if st != .Ready {
			tcheck(t, "the round trip has no framing error", st == .Incomplete, f.err)
			break
		}
		append(&ids, int(m.id))
	}
	tints(
		t,
		"every encoded message frames back in order",
		ids[:],
		{
			int(Msg_Id.Unchoke),
			int(Msg_Id.Have),
			int(Msg_Id.Request),
			int(Msg_Id.Keep_Alive),
			int(Msg_Id.Piece),
			int(Msg_Id.Cancel),
			int(Msg_Id.Bitfield),
		},
	)
}

// ---------------------------------------------------------------------------
// Rarest first
// ---------------------------------------------------------------------------

test_rarest_first :: proc(t: ^T) {
	tsection(t, "rarest-first piece selection")

	mkbf :: proc(n: int, set: []int) -> Bitfield {
		b := bf_make(n, context.temp_allocator)
		for i in set {
			bf_set(&b, i, true)
		}
		return b
	}

	// Six pieces. Availability 5, 1, 3, 1, 9, 2; we have none; the peer has
	// all of them. Rarest first with ties by index gives 1, 3, 5, 2, 0, 4.
	avail := []int{5, 1, 3, 1, 9, 2}
	have := mkbf(6, {})
	peer := mkbf(6, {0, 1, 2, 3, 4, 5})
	tints(
		t,
		"rarest first, ties broken by index",
		picker_order(avail, have, peer, context.temp_allocator),
		{1, 3, 5, 2, 0, 4},
	)

	// Pieces we already have drop out.
	have2 := mkbf(6, {1, 4})
	tints(
		t,
		"pieces we already have are not candidates",
		picker_order(avail, have2, peer, context.temp_allocator),
		{3, 5, 2, 0},
	)

	// Pieces this peer does not have drop out, however rare they are.
	peer3 := mkbf(6, {0, 2, 4})
	tints(
		t,
		"only what this peer has is a candidate",
		picker_order(avail, have, peer3, context.temp_allocator),
		{2, 0, 4},
	)

	// Availability zero is not a candidate even if the peer claims it: the
	// availability table is the one we trust, since it is built from bitfields
	// we counted.
	avail0 := []int{0, 0, 1, 0, 0, 0}
	tints(
		t,
		"a piece with zero availability is skipped",
		picker_order(avail0, have, peer, context.temp_allocator),
		{2},
	)

	// Nothing to do.
	teq_int(
		t,
		"with everything in hand there are no candidates",
		len(picker_order(avail, mkbf(6, {0, 1, 2, 3, 4, 5}), peer, context.temp_allocator)),
		0,
	)
	teq_int(
		t,
		"a peer with nothing offers no candidates",
		len(picker_order(avail, have, mkbf(6, {}), context.temp_allocator)),
		0,
	)

	// All equal: the order is by index, which keeps it deterministic.
	flat := []int{4, 4, 4, 4}
	tints(
		t,
		"equal availability falls back to piece order",
		picker_order(flat, mkbf(4, {}), mkbf(4, {0, 1, 2, 3}), context.temp_allocator),
		{0, 1, 2, 3},
	)

	// The availability counters themselves.
	m := layout(1024, {4096})
	pk: Picker
	picker_init(&pk, &m)
	defer picker_destroy(&pk)
	teq_int(t, "a fresh picker has zero availability everywhere", pk.avail[0], 0)
	b1 := bf_make(4, context.temp_allocator)
	bf_set(&b1, 0, true)
	bf_set(&b1, 2, true)
	picker_add_bitfield(&pk, b1)
	tints(t, "one peer's bitfield counts once", pk.avail, {1, 0, 1, 0})
	b2 := bf_make(4, context.temp_allocator)
	bf_fill(&b2)
	picker_add_bitfield(&pk, b2)
	tints(t, "a seed's bitfield adds one everywhere", pk.avail, {2, 1, 2, 1})
	picker_add_have(&pk, 1)
	tints(t, "a have message adds one", pk.avail, {2, 2, 2, 1})
	picker_remove_bitfield(&pk, b1)
	tints(t, "a disconnect takes it back off", pk.avail, {1, 2, 1, 1})
	picker_remove_bitfield(&pk, b1)
	tints(t, "...and never goes negative", pk.avail, {0, 2, 0, 1})
}

test_picker_blocks :: proc(t: ^T) {
	tsection(t, "block assembly, the request pipeline and endgame")

	// One piece of 40000 bytes: three blocks of 16384, 16384 and 7232.
	m := layout(40000, {40000})
	teq_int(t, "one piece", piece_count(&m), 1)
	teq_int(t, "...of three blocks", blocks_in_piece(&m, 0), 3)
	teq_int(t, "block 0 is 16384", block_size_at(&m, 0, 0), 16384)
	teq_int(t, "block 2 is 7232", block_size_at(&m, 0, 2), 7232)

	pk: Picker
	picker_init(&pk, &m)
	defer picker_destroy(&pk)
	a := picker_begin(&pk, 0)
	tcheck(t, "beginning a piece gives an active piece", a != nil)
	teq_int(t, "...with three block slots", len(a.blocks), 3)
	teq_int(t, "...and a 40000-byte buffer", len(a.buf), 40000)
	tcheck(t, "beginning it again returns the same one", picker_begin(&pk, 0) == a)
	teq_int(t, "...so there is one active piece", len(pk.active), 1)

	b0, ok0 := picker_next_block(&pk, a, false)
	tcheck(t, "the first block to ask for is available", ok0)
	teq_int(t, "...and it is block 0", b0, 0)
	picker_mark_requested(a, 0, 100)
	b1, ok1 := picker_next_block(&pk, a, false)
	tcheck(t, "the next is available", ok1)
	teq_int(t, "...and it is block 1, not 0 again", b1, 1)
	picker_mark_requested(a, 1, 100)
	picker_mark_requested(a, 2, 100)
	_, ok3 := picker_next_block(&pk, a, false)
	tcheck(t, "with all three outstanding there is nothing to ask for", !ok3)
	// Endgame hands out an already-outstanding block on purpose.
	be, oke := picker_next_block(&pk, a, true)
	tcheck(t, "in endgame mode there is", oke)
	teq_int(t, "...starting again from block 0", be, 0)

	// Storing blocks.
	blk := make([]u8, 16384, context.temp_allocator)
	for i in 0 ..< len(blk) {
		blk[i] = u8(i)
	}
	fresh, done, err := picker_store_block(&pk, a, 0, blk)
	teq(t, "storing block 0 works", err, "")
	tcheck(t, "...it is fresh", fresh)
	tcheck(t, "...and the piece is not done", !done)
	teq_int(t, "...one block in hand", a.got, 1)
	fresh2, _, _ := picker_store_block(&pk, a, 0, blk)
	tcheck(t, "storing it again is not fresh", !fresh2)
	teq_int(t, "...and does not double-count", a.got, 1)
	_, _, e2 := picker_store_block(&pk, a, 16384, blk)
	teq(t, "block 1 stores", e2, "")
	_, done3, e3 := picker_store_block(&pk, a, 32768, blk[:7232])
	teq(t, "the short last block stores", e3, "")
	tcheck(t, "...and completes the piece", done3)
	teq_int(t, "...with three blocks in hand", a.got, 3)
	tcheck(t, "the buffer holds the first block's bytes", slice.equal(a.buf[0:16384], blk))

	// Everything that must be refused.
	a2 := picker_begin(&pk, 0)
	_, _, be1 := picker_store_block(&pk, a2, 1, blk)
	tcheck(t, "a block at a misaligned offset is refused", be1 != "")
	_, _, be2 := picker_store_block(&pk, a2, 65536, blk)
	tcheck(t, "a block past the end of the piece is refused", be2 != "")
	_, _, be3 := picker_store_block(&pk, a2, 0, blk[:100])
	tcheck(t, "a block of the wrong length is refused", be3 != "")

	// Timeouts put a block back on the list.
	picker_drop(&pk, 0)
	teq_int(t, "dropping the piece empties the active list", len(pk.active), 0)
	a3 := picker_begin(&pk, 0)
	picker_mark_requested(a3, 0, 100)
	picker_release_timed_out(&pk, 100 + REQUEST_TIMEOUT - 1)
	tcheck(t, "a request inside the timeout stays outstanding", a3.blocks[0] == .Requested)
	picker_release_timed_out(&pk, 100 + REQUEST_TIMEOUT + 1)
	tcheck(t, "a request past the timeout goes back on the list", a3.blocks[0] == .Missing)

	// Endgame switches on near the end and not before.
	have := bf_make(20, context.temp_allocator)
	picker_update_endgame(&pk, have)
	tcheck(t, "with 20 pieces left it is not endgame", !pk.endgame)
	for i in 0 ..< 20 - ENDGAME_PIECES {
		bf_set(&have, i, true)
	}
	picker_update_endgame(&pk, have)
	tcheck(t, asprint("with %d pieces left it is endgame", ENDGAME_PIECES), pk.endgame)
	bf_fill(&have)
	picker_update_endgame(&pk, have)
	tcheck(t, "with nothing left it is not endgame any more", !pk.endgame)
}

// ---------------------------------------------------------------------------
// Magnets and URLs
// ---------------------------------------------------------------------------

test_magnet :: proc(t: ^T) {
	tsection(t, "magnet URIs")
	mg, e := magnet_parse(
		"magnet:?xt=urn:btih:123456789abcdef123456789abcdef123456789a&dn=hello%20world&tr=http%3A%2F%2F127.0.0.1%3A6969%2Fannounce",
		context.temp_allocator,
	)
	teq(t, "a magnet parses", e, "")
	teq(
		t,
		"...with the info-hash",
		hash20_hex(mg.info_hash, context.temp_allocator),
		"123456789abcdef123456789abcdef123456789a",
	)
	teq(t, "...the display name, percent-decoded", mg.name, "hello world")
	teq_int(t, "...and one tracker", len(mg.trackers), 1)
	teq(t, "...decoded too", mg.trackers[0], "http://127.0.0.1:6969/announce")

	// base32, the older spelling.
	mg2, e2 := magnet_parse(
		"magnet:?xt=urn:btih:CEBFVIOHWC7IDXU3MWJ7WAG3YTKCDVA5",
		context.temp_allocator,
	)
	teq(t, "a base32 magnet parses", e2, "")
	teq_int(t, "...to 20 bytes", 20, 20)
	tcheck(t, "...and has a hash", mg2.have_hash)

	bad :: proc(t: ^T, uri, why: string) {
		_, err := magnet_parse(uri, context.temp_allocator)
		tcheck(t, asprint("refused: %s", why), err != "", "it parsed")
	}
	bad(t, "http://example.com/x.torrent", "not a magnet at all")
	bad(t, "magnet:?dn=x", "no xt")
	bad(t, "magnet:?xt=urn:btih:abc", "a short info-hash")
	bad(t, "magnet:?xt=urn:btih:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "a non-hex info-hash")
	bad(t, "magnet:?xt=urn:sha1:123456789abcdef123456789abcdef123456789a", "the wrong urn")

	// And the other direction, from a real metainfo.
	m, _ := metainfo_parse(test_torrent_sorted(context.temp_allocator), context.temp_allocator)
	link := magnet_of(&m, context.temp_allocator)
	tcheck(
		t,
		"a magnet built from a torrent carries its info-hash",
		strings.contains(link, TEST_INFO_HASH_SORTED),
		link,
	)
	back, berr := magnet_parse(link, context.temp_allocator)
	teq(t, "...and parses back", berr, "")
	tcheck(t, "...to the same hash", hash20_eq(back.info_hash, m.info_hash))
	teq(t, "...and the same name", back.name, m.name)
}

test_urls :: proc(t: ^T) {
	tsection(t, "tracker URLs")
	u, e := url_split("http://127.0.0.1:6969/announce")
	teq(t, "an http tracker URL splits", e, "")
	teq(t, "...scheme", u.scheme, "http")
	teq(t, "...host", u.host, "127.0.0.1")
	teq_int(t, "...port", u.port, 6969)
	teq(t, "...target", u.target, "/announce")

	u2, e2 := url_split("http://127.0.0.1/announce?x=1")
	teq(t, "a URL with no port splits", e2, "")
	teq_int(t, "...defaulting to 80", u2.port, 80)
	teq(t, "...and keeping the query", u2.target, "/announce?x=1")

	u3, e3 := url_split("http://127.0.0.1:1234")
	teq(t, "a URL with no path splits", e3, "")
	teq(t, "...targeting /", u3.target, "/")

	u4, e4 := url_split("udp://127.0.0.1:6969")
	teq(t, "a udp tracker URL splits", e4, "")
	teq(t, "...with the udp scheme", u4.scheme, "udp")
	teq_int(t, "...and its port", u4.port, 6969)

	_, e5 := url_split("udp://127.0.0.1")
	tcheck(t, "a udp URL with no port is refused", e5 != "")
	_, e6 := url_split("https://127.0.0.1/announce")
	tcheck(t, "an https tracker is refused (there is no TLS here)", e6 != "")
	_, e7 := url_split("127.0.0.1:6969/announce")
	tcheck(t, "a URL with no scheme is refused", e7 != "")
	_, e8 := url_split("ws://127.0.0.1:1/x")
	tcheck(t, "a websocket tracker is refused", e8 != "")
	_, e9 := url_split("http://:80/x")
	tcheck(t, "a URL with no host is refused", e9 != "")
	_, e10 := url_split("http://127.0.0.1:99999/x")
	tcheck(t, "a URL with an out-of-range port is refused", e10 != "")

	// The HTTP response parser.
	status, body, done := http_try_parse(
		sv("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"),
	)
	tcheck(t, "a complete response is recognised", done)
	teq_int(t, "...with its status", status, 200)
	tbytes(t, "...and its body", body, "hello")
	_, _, done2 := http_try_parse(sv("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel"))
	tcheck(t, "a short body is not yet complete", !done2)
	_, _, done3 := http_try_parse(sv("HTTP/1.1 200 OK\r\nContent-Len"))
	tcheck(t, "a partial header is not complete", !done3)
	st4, _, _ := http_try_parse(sv("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))
	teq_int(t, "a 404 is read as 404", st4, 404)
	status5, body5, done5 := http_try_parse(
		sv("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi"),
	)
	tcheck(t, "a lowercase header name works", done5)
	teq_int(t, "...status", status5, 200)
	tbytes(t, "...body", body5, "hi")
}

// ---------------------------------------------------------------------------
// Storage, on a real temporary directory
// ---------------------------------------------------------------------------

test_storage :: proc(t: ^T) {
	tsection(t, "storage: pieces across file boundaries, verify-then-write")

	root := asprint("/tmp/palmy-torrent-selftest-%d", unix_now())
	rm_rf(root)
	defer rm_rf(root)

	// A three-file tree whose pieces straddle every boundary, built from
	// synthetic bytes so the expected content is known.
	src := path_join(root, "src", allocator = context.temp_allocator)
	sizes := [?]i64{100, 0, 250, 7}
	names := [?]string{"a.bin", "e.bin", "sub/b.bin", "sub/c.bin"}
	for i in 0 ..< len(sizes) {
		p := path_join(src, "payload", names[i], allocator = context.temp_allocator)
		werr := write_synthetic_file(p, sizes[i], u64(0x1000 + i))
		teq(t, asprint("wrote the synthetic %s", names[i]), werr, "")
	}
	tor, cerr := metainfo_create(
		path_join(src, "payload", allocator = context.temp_allocator),
		Make_Opts{piece_length = 1024, announce = "http://127.0.0.1:1/a"},
		context.temp_allocator,
	)
	teq(t, "a torrent is made from the tree", cerr, "")
	m, merr := metainfo_parse(tor, context.temp_allocator)
	teq(t, "...and parses", merr, "")
	teq_i64(t, "...totalling 357 bytes", m.total_length, 357)
	teq_int(t, "...in one piece", piece_count(&m), 1)
	teq_int(t, "...over four files", len(m.files), 4)
	// The files sort by relative path, so a.bin, e.bin, then sub/.
	teq(t, "the first file is a.bin", m.files[0].path, "a.bin")
	teq(t, "the second is e.bin, the empty one", m.files[1].path, "e.bin")
	teq_i64(t, "...of zero bytes", m.files[1].length, 0)
	teq(t, "then sub/b.bin", m.files[2].path, "sub/b.bin")
	teq(t, "then sub/c.bin", m.files[3].path, "sub/c.bin")

	// Read it back through Storage from the source, which is what a seeder
	// does after a recheck.
	seed_store: Storage
	serr := storage_open(&seed_store, &m, src)
	teq(t, "the seeder's storage opens", serr, "")
	defer storage_destroy(&seed_store)
	shave := bf_make(piece_count(&m), context.temp_allocator)
	verified := storage_check_all(&seed_store, &shave)
	teq_int(t, "the recheck verifies every piece from the source", verified, piece_count(&m))
	tcheck(t, "...so the seeder is complete", bf_complete(shave))

	// Now the leecher: a fresh directory, pieces written through
	// storage_write_piece, then compared byte for byte with the source.
	dst := path_join(root, "dst", allocator = context.temp_allocator)
	leech_store: Storage
	lerr := storage_open(&leech_store, &m, dst)
	teq(t, "the leecher's storage opens", lerr, "")
	defer storage_destroy(&leech_store)
	teq(t, "...and creates the layout", storage_create_files(&leech_store), "")
	for f, i in m.files {
		p := path_join(dst, m.name, f.path, allocator = context.temp_allocator)
		tcheck(t, asprint("%s was created", f.path), path_exists(p))
		sz, _ := path_size(p)
		teq_i64(t, asprint("...at its final length of %d", f.length), sz, f.length)
	}
	lhave := bf_make(piece_count(&m), context.temp_allocator)
	teq_int(
		t,
		"a fresh layout verifies nothing (the files are zeros)",
		storage_check_all(&leech_store, &lhave),
		0,
	)

	buf := make([]u8, int(m.piece_length), context.temp_allocator)
	for i in 0 ..< piece_count(&m) {
		n, rerr := storage_read_piece(&seed_store, i, buf)
		teq(t, asprint("piece %d reads from the seeder", i), rerr, "")
		teq_i64(t, asprint("...as %d bytes", piece_size(&m, i)), i64(n), piece_size(&m, i))
		werr := storage_write_piece(&leech_store, i, buf[:n])
		teq(t, asprint("...and writes to the leecher", i), werr, "")
	}
	// Verify-then-write: corrupting a byte must be refused.
	buf[0] ~= 0xff
	bad_err := storage_write_piece(&leech_store, 0, buf[:piece_size(&m, 0)])
	tcheck(
		t,
		"a piece with one flipped bit is REFUSED, not written",
		bad_err != "",
		"corrupt data would have gone to disk",
	)
	tcheck(t, "...and the error names the hash mismatch", strings.contains(bad_err, "verification"), bad_err)
	buf[0] ~= 0xff
	teq(t, "a piece of the wrong length is refused", storage_write_piece(&leech_store, 0, buf[:5]) != "" ? "refused" : "accepted", "refused")

	// The files now match, byte for byte.
	teq_int(
		t,
		"a recheck of the leecher verifies every piece",
		storage_check_all(&leech_store, &lhave),
		piece_count(&m),
	)
	all_same := true
	for f in m.files {
		if f.length == 0 {
			continue
		}
		a := path_join(src, "payload", f.path, allocator = context.temp_allocator)
		b := path_join(dst, m.name, f.path, allocator = context.temp_allocator)
		same, detail := files_identical(a, b)
		if !tcheck(t, asprint("%s is byte-for-byte identical", f.path), same, detail) {
			all_same = false
		}
	}
	tcheck(t, "every file in the layout matches the source", all_same)

	// storage_read_block, which is what serving a request does.
	blk := make([]u8, MAX_MESSAGE, context.temp_allocator)
	got, berr := storage_read_block(&leech_store, 0, 0, 100, blk)
	teq(t, "a block from the start of the piece reads", berr, "")
	teq_int(t, "...of 100 bytes", len(got), 100)
	got2, berr2 := storage_read_block(&leech_store, 0, 300, 57, blk)
	teq(t, "a block spanning the last two files reads", berr2, "")
	teq_int(t, "...of 57 bytes", len(got2), 57)
	// A block that runs off the end of the piece must be refused rather than
	// quietly reading the next file.
	_, oob := storage_read_block(&leech_store, 0, 300, 1000, blk)
	tcheck(t, "a request past the end of the piece is refused", oob != "")
	_, oob2 := storage_read_block(&leech_store, 0, -1, 16, blk)
	tcheck(t, "a negative offset is refused", oob2 != "")
	_, oob3 := storage_read_block(&leech_store, 999, 0, 16, blk)
	tcheck(t, "a request for a piece that does not exist is refused", oob3 != "")
	_, oob4 := storage_read_block(&leech_store, 0, 0, 0, blk)
	tcheck(t, "a zero-length request is refused", oob4 != "")

	// Per-file progress.
	teq_f32(t, "a complete file reads 100%", file_progress(&m, lhave, 0), 1, 0.001)
	empty := bf_make(piece_count(&m), context.temp_allocator)
	teq_f32(t, "a file with no pieces reads 0%", file_progress(&m, empty, 0), 0, 0.001)
	teq_f32(t, "a zero-length file is always complete", file_progress(&m, empty, 1), 1, 0.001)

	// Priorities, and what "don't download" means for a piece.
	tcheck(t, "every piece is wanted by default", piece_wanted(&leech_store, 0))
	for i in 0 ..< len(leech_store.prio) {
		leech_store.prio[i] = .Skip
	}
	tcheck(t, "with every file skipped, no piece is wanted", !piece_wanted(&leech_store, 0))
	leech_store.prio[0] = .Normal
	tcheck(
		t,
		"a piece straddling a skipped file and a wanted one is still wanted",
		piece_wanted(&leech_store, 0),
	)
	teq(t, "the priority names read properly", file_prio_name(.Skip), "Don't download")

	// storage_delete_targets names exactly what removal would delete.
	targets := storage_delete_targets(&leech_store, context.temp_allocator)
	teq_int(t, "a multi-file torrent deletes one directory", len(targets), 1)
	teq(t, "...which is the torrent's own folder", targets[0], path_join(dst, m.name, allocator = context.temp_allocator))
	tcheck(t, "...and it is under the download directory", strings.has_prefix(targets[0], dst))
}

// ---------------------------------------------------------------------------
// Creating a torrent
// ---------------------------------------------------------------------------

test_create_torrent :: proc(t: ^T) {
	tsection(t, "creating a torrent from a tree")

	root := asprint("/tmp/palmy-torrent-create-%d", unix_now())
	rm_rf(root)
	defer rm_rf(root)

	perr := make_payload(root)
	teq(t, "the synthetic payload is written", perr, "")
	base := path_join(root, PAYLOAD_NAME, allocator = context.temp_allocator)
	for p in PAYLOAD {
		full := path_join(base, p.rel, allocator = context.temp_allocator)
		sz, ok := path_size(full)
		tcheck(t, asprint("%s exists", p.rel), ok)
		teq_i64(t, asprint("...at %d bytes", p.size), sz, p.size)
	}

	data, cerr := metainfo_create(
		base,
		Make_Opts {
			piece_length = PAYLOAD_PIECE_LENGTH,
			announce = "http://127.0.0.1:6969/announce",
			comment = "synthetic",
		},
		context.temp_allocator,
	)
	teq(t, "the torrent is created", cerr, "")
	m, merr := metainfo_parse(data, context.temp_allocator)
	teq(t, "...and parses back", merr, "")
	teq(t, "...with the right name", m.name, PAYLOAD_NAME)
	teq_i64(t, "...the right total length", m.total_length, payload_total())
	teq_i64(t, "...the right piece length", m.piece_length, PAYLOAD_PIECE_LENGTH)
	want_pieces := int((payload_total() + PAYLOAD_PIECE_LENGTH - 1) / PAYLOAD_PIECE_LENGTH)
	teq_int(t, "...and the right number of pieces", len(m.pieces), want_pieces)
	teq_int(t, "...listing every file including the empty one", len(m.files), len(PAYLOAD))
	teq(t, "...with the announce URL", m.announce, "http://127.0.0.1:6969/announce")
	teq(t, "...and the comment", m.comment, "synthetic")

	// The root dictionary that came out is in bencoding order, which is what
	// makes the info-hash reproducible by any other client.
	root_ben, _ := ben_decode(data, context.temp_allocator)
	tcheck(t, "the torrent we wrote has its root keys sorted", ben_dict_sorted(root_ben))
	info, _ := ben_get(root_ben, "info")
	tcheck(t, "...and its info keys sorted", ben_dict_sorted(info))
	teq(
		t,
		"...so re-encoding the info dictionary is byte-identical",
		string(ben_encode(info, context.temp_allocator)),
		string(data[info.start:info.end]),
	)
	teq(
		t,
		"...and therefore gives the same info-hash",
		hash20_hex(sha1_of(ben_encode(info, context.temp_allocator)), context.temp_allocator),
		hash20_hex(m.info_hash, context.temp_allocator),
	)

	// Creating it twice gives the same bytes, because the file order and the
	// key order are both defined. (The creation date differs, so compare the
	// info dictionary, which is what the info-hash is over.)
	data2, _ := metainfo_create(
		base,
		Make_Opts{piece_length = PAYLOAD_PIECE_LENGTH, announce = "http://127.0.0.1:6969/announce", comment = "synthetic"},
		context.temp_allocator,
	)
	m2, _ := metainfo_parse(data2, context.temp_allocator)
	tcheck(
		t,
		"making the same torrent twice gives the same info-hash",
		hash20_eq(m.info_hash, m2.info_hash),
		asprint(
			"%s vs %s",
			hash20_hex(m.info_hash, context.temp_allocator),
			hash20_hex(m2.info_hash, context.temp_allocator),
		),
	)

	// And the piece hashes really are the hashes of the payload: check the
	// first and last piece by reading the concatenation by hand.
	st: Storage
	teq(t, "a storage over the payload opens", storage_open(&st, &m, root), "")
	defer storage_destroy(&st)
	pbuf := make([]u8, int(m.piece_length), context.temp_allocator)
	n0, _ := storage_read_piece(&st, 0, pbuf)
	teq(
		t,
		"piece 0's SHA-1 matches the torrent",
		hash20_hex(sha1_of(pbuf[:n0]), context.temp_allocator),
		hash20_hex(m.pieces[0], context.temp_allocator),
	)
	last := piece_count(&m) - 1
	nl, _ := storage_read_piece(&st, last, pbuf)
	teq_i64(t, "the last piece is short", i64(nl), piece_size(&m, last))
	teq(
		t,
		"...and its SHA-1 matches too",
		hash20_hex(sha1_of(pbuf[:nl]), context.temp_allocator),
		hash20_hex(m.pieces[last], context.temp_allocator),
	)

	// Refusals.
	_, e1 := metainfo_create(base, Make_Opts{piece_length = 1000}, context.temp_allocator)
	tcheck(t, "a piece length that is not a power of two is refused", e1 != "")
	_, e2 := metainfo_create(base, Make_Opts{piece_length = 64}, context.temp_allocator)
	tcheck(t, "a piece length below the floor is refused", e2 != "")
	_, e3 := metainfo_create(
		path_join(root, "does-not-exist", allocator = context.temp_allocator),
		Make_Opts{piece_length = 1024},
		context.temp_allocator,
	)
	tcheck(t, "a path that does not exist is refused", e3 != "")
}

// ---------------------------------------------------------------------------
// The safety gate
// ---------------------------------------------------------------------------

// test_loopback_gate asserts the property the whole task rests on. Every case
// is checked WITHOUT attempting a connection; the two that go through
// `sock_connect` are refused before a socket exists.
test_loopback_gate :: proc(t: ^T) {
	tsection(t, "the loopback-only safety gate")

	for good in ([?]string{"127.0.0.1", "127.0.0.2", "127.1.2.3", "127.255.255.254", "localhost", "localhost.localdomain", " 127.0.0.1 "}) {
		addr, err := loopback_address(good)
		tcheck(t, asprint("%q is allowed", good), err == "", err)
		tcheck(t, asprint("%q is in 127/8", good), addr[0] == 127, asprint("%v", addr))
	}

	// Real trackers and real DHT bootstrap nodes. None of these is resolved —
	// the refusal happens on the shape of the string, before any lookup.
	for bad in ([?]string {
			// public trackers
			"tracker.opentrackr.org",
			"tracker.openbittorrent.com",
			"open.stealth.si",
			"exodus.desync.com",
			"tracker.torrent.eu.org",
			"explodie.org",
			"bt1.archive.org",
			// DHT bootstrap nodes
			"router.bittorrent.com",
			"router.utorrent.com",
			"dht.transmissionbt.com",
			"dht.libtorrent.org",
			// routable and otherwise forbidden literals
			"8.8.8.8",
			"1.1.1.1",
			"0.0.0.0",
			"255.255.255.255",
			"192.168.1.1",
			"10.0.0.1",
			"172.16.0.1",
			"169.254.1.1",
			"224.0.0.1",
			"::1",
			"::",
			"fe80::1",
			"2001:4860:4860::8888",
			// lookalikes
			"127.0.0.1.evil.com",
			"localhost.evil.com",
			"evil.com#127.0.0.1",
			"127.0.0",
			"127.0.0.1.2",
			"127.0.0.256",
			"127.0.0.-1",
			"127.0.0.01x",
			"0x7f.0.0.1",
			"2130706433", // 127.0.0.1 as a single integer
			"127.0.0.1:80",
			"",
			" ",
			"127.o.0.1",
		}) {
		_, err := loopback_address(bad)
		tcheck(t, asprint("%q is REFUSED", bad), err != "", "the gate let it through")
	}

	// And now the call sites themselves, which is what actually matters.
	_, ce := sock_connect("tracker.opentrackr.org", 1337)
	tcheck(t, "sock_connect refuses a real tracker hostname", ce != "", "it tried to connect")
	tcheck(t, "...naming loopback as the reason", strings.contains(ce, "loopback"), ce)
	_, ce2 := sock_connect("8.8.8.8", 6881)
	tcheck(t, "sock_connect refuses a routable IP", ce2 != "", "it tried to connect")
	tcheck(t, "...and says it is not loopback", strings.contains(ce2, "not loopback"), ce2)
	_, ce3 := sock_connect("router.bittorrent.com", 6881)
	tcheck(t, "sock_connect refuses a DHT bootstrap node", ce3 != "")
	_, ce4 := sock_connect("127.0.0.1", 0)
	tcheck(t, "sock_connect refuses port 0", ce4 != "")
	_, ce5 := sock_connect("127.0.0.1", 70000)
	tcheck(t, "sock_connect refuses an out-of-range port", ce5 != "")

	// Listening. 0.0.0.0 is what every other client binds; this one will not.
	_, _, le := sock_listen("0.0.0.0", 0)
	tcheck(t, "sock_listen REFUSES 0.0.0.0", le != "", "it bound every interface")
	_, _, le2 := sock_listen("192.168.1.1", 0)
	tcheck(t, "sock_listen refuses a LAN address", le2 != "")
	l, bound, le3 := sock_listen("127.0.0.1", 0)
	teq(t, "sock_listen allows 127.0.0.1", le3, "")
	tcheck(t, "...and the kernel gave it a port", bound > 0, asprint("port %d", bound))
	sock_close(l)

	// UDP, the other way out.
	u: Udp
	ue := udp_open(&u, "0.0.0.0", 0)
	tcheck(t, "udp_open refuses 0.0.0.0", ue != "")
	ue2 := udp_open(&u, "127.0.0.1", 0)
	teq(t, "udp_open allows 127.0.0.1", ue2, "")
	se := udp_send_to(&u, "tracker.opentrackr.org", 1337, {1, 2, 3})
	tcheck(t, "udp_send_to refuses a real UDP tracker", se != "", "a datagram left the machine")
	se2 := udp_send_to(&u, "8.8.8.8", 53, {1, 2, 3})
	tcheck(t, "udp_send_to refuses a routable IP", se2 != "")
	udp_close(&u)

	// The tracker client, through the gate.
	req := Announce_Req {
		port    = 6881,
		numwant = 50,
	}
	_, te := tracker_announce_http("http://tracker.opentrackr.org:1337/announce", req, 100, context.temp_allocator)
	tcheck(t, "an HTTP announce to a real tracker is refused", te != "", "it announced")
	_, te2 := tracker_announce_udp("udp://tracker.opentrackr.org:1337", req, 100, context.temp_allocator)
	tcheck(t, "a UDP announce to a real tracker is refused", te2 != "")
	_, te3 := tracker_announce("https://tracker.example.com/announce", req, 100, context.temp_allocator)
	tcheck(t, "an https tracker is refused outright", te3 != "")

	// There is no DHT, no PEX and no port mapping in this program, and the
	// handshake says so.
	ih, _ := hash20_from_hex("123456789abcdef123456789abcdef123456789a")
	hs := handshake_encode(ih, peer_id_new(1), context.temp_allocator)
	tcheck(
		t,
		"the handshake's DHT bit is clear (byte 27, bit 0)",
		hs[27] & 0x01 == 0,
	)
	tcheck(
		t,
		"the handshake's extension-protocol bit is clear (byte 25, bit 4)",
		hs[25] & 0x10 == 0,
		"peer exchange would arrive over it",
	)
}
