// Package vcard reads and writes vCard 4.0 (RFC 6350) and 3.0 (RFC 2426),
// on the content-line layer in ../ical, and converts between the two.
//
// Clients disagree on the version: Apple Contacts and most of Android write
// 3.0, Thunderbird and newer clients 4.0. The server stores what the client
// wrote and converts on the way out when a REPORT asks for the other
// version (CardDAV address-data with a version attribute, RFC 6352 section
// 10.4). The Card struct is the app's view: the fields a contacts window
// shows and edits. Everything else on the card rides along untouched in
// `raw`, so editing a phone number in Palmy never loses the custom
// field another client wrote.
package vcard

import "core:strings"
import ical "../ical"

Typed :: struct {
	value: string,
	types: []string, // lower-case: "work", "home", "cell", "voice"...
	pref:  bool,
	group: string, // the "item1." prefix Apple uses to pair a value with its X-AB label
}

Address :: struct {
	types:    []string,
	pref:     bool,
	po_box:   string,
	extended: string,
	street:   string,
	locality: string,
	region:   string,
	postcode: string,
	country:  string,
	group:    string, // pairs it with Apple's itemN.X-ABADR (country code)
}

Card :: struct {
	uid:        string,
	version:    string,
	fn:         string,
	family:     string,
	given:      string,
	additional: string,
	prefix:     string,
	suffix:     string,
	nickname:   string,
	org:        string,
	title:      string,
	note:       string,
	bday:       string, // as written: 19850412, --0412, 1985-04-12
	emails:     []Typed,
	phones:     []Typed,
	urls:       []Typed,
	addresses:  []Address,
	categories: []string,
	kind:       string, // individual | group | org | location
	members:    []string, // group: urn:uuid:<uid> of each member
	photo:      string, // a URI (data: or http:)
	raw:        ^ical.Component,
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

Check_Error :: enum u8 {
	None,
	Not_VCard,
	No_UID,
	No_FN,
	Bad_Version,
}

check_error_text :: proc(e: Check_Error) -> string {
	switch e {
	case .None: return ""
	case .Not_VCard: return "the body is not one vCard"
	case .No_UID: return "the vCard has no UID"
	case .No_FN: return "the vCard has no FN"
	case .Bad_Version: return "the vCard version is not 3.0 or 4.0"
	}
	return "invalid"
}

check :: proc(c: ^ical.Component) -> Check_Error {
	if c == nil || c.name != "VCARD" {
		return .Not_VCard
	}
	v := strings.trim_space(ical.value(c, "VERSION"))
	if v != "3.0" && v != "4.0" {
		return .Bad_Version
	}
	if ical.text(c, "UID") == "" {
		return .No_UID
	}
	if strings.trim_space(ical.text(c, "FN")) == "" && ical.value(c, "N") == "" && ical.value(c, "ORG") == "" {
		return .No_FN
	}
	return .None
}

@(private)
types_of :: proc(p: ^ical.Prop) -> (types: []string, pref: bool) {
	out := make([dynamic]string, 0, 2)
	for q in p.params {
		switch q.name {
		case "TYPE":
			for v in q.values {
				// "TYPE=work,voice" and "TYPE=WORK;TYPE=VOICE" both arrive here.
				for piece in strings.split(v, ",", context.temp_allocator) {
					t := strings.to_lower(strings.trim_space(piece))
					if t == "pref" {
						pref = true
						continue
					}
					if t != "" && t != "internet" && t != "x400" {
						append(&out, t)
					}
				}
			}
		case "PREF":
			pref = true
		}
	}
	return out[:], pref
}

// unescape a structured component (N, ADR, ORG).
@(private)
part :: proc(parts: []string, i: int) -> string {
	return i < len(parts) ? ical.unescape_text(parts[i]) : ""
}

// from_component reads the fields a contacts window shows.
from_component :: proc(c: ^ical.Component) -> Card {
	card: Card
	card.raw = c
	card.version = strings.trim_space(ical.value(c, "VERSION"))
	card.uid = ical.text(c, "UID")
	card.fn = ical.text(c, "FN")
	if np := ical.prop(c, "N"); np != nil {
		parts := ical.split_unescaped(np.value, ';', context.temp_allocator)
		card.family = part(parts, 0)
		card.given = part(parts, 1)
		card.additional = part(parts, 2)
		card.prefix = part(parts, 3)
		card.suffix = part(parts, 4)
	}
	card.nickname = ical.text(c, "NICKNAME")
	if op := ical.prop(c, "ORG"); op != nil {
		parts := ical.split_unescaped(op.value, ';', context.temp_allocator)
		pieces := make([dynamic]string, 0, len(parts), context.temp_allocator)
		for _, i in parts {
			if s := part(parts, i); s != "" {
				append(&pieces, s)
			}
		}
		card.org = strings.join(pieces[:], ", ")
	}
	card.title = ical.text(c, "TITLE")
	card.note = ical.text(c, "NOTE")
	card.bday = ical.value(c, "BDAY")
	card.kind = strings.to_lower(strings.trim_space(ical.value(c, "KIND")))
	if card.kind == "" {
		card.kind = strings.to_lower(strings.trim_space(ical.value(c, "X-ADDRESSBOOKSERVER-KIND")))
	}
	if card.kind == "" {
		card.kind = "individual"
	}

	emails := make([dynamic]Typed, 0, 2)
	phones := make([dynamic]Typed, 0, 2)
	urls := make([dynamic]Typed, 0, 1)
	addrs := make([dynamic]Address, 0, 1)
	members := make([dynamic]string, 0, 0)
	cats := make([dynamic]string, 0, 0)
	for &p in c.props {
		switch p.name {
		case "EMAIL":
			t, pref := types_of(&p)
			append(&emails, Typed{value = strings.trim_space(ical.unescape_text(p.value)), types = t, pref = pref, group = p.group})
		case "TEL":
			t, pref := types_of(&p)
			v := strings.trim_space(p.value)
			if strings.has_prefix(strings.to_lower(v, context.temp_allocator), "tel:") {
				v = v[4:]
			}
			append(&phones, Typed{value = ical.unescape_text(v), types = t, pref = pref, group = p.group})
		case "URL":
			t, pref := types_of(&p)
			append(&urls, Typed{value = ical.unescape_text(p.value), types = t, pref = pref, group = p.group})
		case "ADR":
			t, pref := types_of(&p)
			parts := ical.split_unescaped(p.value, ';', context.temp_allocator)
			append(&addrs, Address {
				types = t, pref = pref,
				po_box = part(parts, 0), extended = part(parts, 1), street = part(parts, 2),
				locality = part(parts, 3), region = part(parts, 4), postcode = part(parts, 5),
				country = part(parts, 6), group = p.group,
			})
		case "MEMBER", "X-ADDRESSBOOKSERVER-MEMBER":
			append(&members, strings.trim_space(p.value))
		case "CATEGORIES":
			for piece in ical.split_unescaped(p.value, ',', context.temp_allocator) {
				if s := strings.trim_space(ical.unescape_text(piece)); s != "" {
					append(&cats, strings.clone(s))
				}
			}
		case "PHOTO":
			if card.photo == "" {
				card.photo = photo_uri(&p)
			}
		}
	}
	card.emails = emails[:]
	card.phones = phones[:]
	card.urls = urls[:]
	card.addresses = addrs[:]
	card.members = members[:]
	card.categories = cats[:]
	if card.fn == "" {
		card.fn = display_name(card)
	}
	return card
}

// photo_uri turns a 3.0 inline photo (ENCODING=b;TYPE=JPEG) into a data URI.
@(private)
photo_uri :: proc(p: ^ical.Prop) -> string {
	enc := strings.to_lower(ical.param(p, "ENCODING"), context.temp_allocator)
	if enc == "b" || enc == "base64" {
		mime := strings.to_lower(ical.param(p, "TYPE"), context.temp_allocator)
		if mime == "" {
			mime = "jpeg"
		}
		if !strings.contains(mime, "/") {
			mime = strings.concatenate({"image/", mime}, context.temp_allocator)
		}
		return strings.concatenate({"data:", mime, ";base64,", strings.trim_space(p.value)})
	}
	return strings.trim_space(p.value)
}

// display_name is what a list shows: FN, else a name built from N, else the
// organisation, else the first address.
display_name :: proc(c: Card) -> string {
	if s := strings.trim_space(c.fn); s != "" {
		return s
	}
	pieces := make([dynamic]string, 0, 4, context.temp_allocator)
	for s in ([]string{c.prefix, c.given, c.additional, c.family, c.suffix}) {
		if strings.trim_space(s) != "" {
			append(&pieces, strings.trim_space(s))
		}
	}
	if len(pieces) > 0 {
		return strings.join(pieces[:], " ")
	}
	if c.org != "" {
		return c.org
	}
	if len(c.emails) > 0 {
		return c.emails[0].value
	}
	return "Unnamed"
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// The properties Card owns. Anything else on `raw` is kept as it was.
@(private)
OWNED := [?]string {
	"VERSION", "UID", "FN", "N", "NICKNAME", "ORG", "TITLE", "NOTE", "BDAY",
	"EMAIL", "TEL", "URL", "ADR", "KIND", "X-ADDRESSBOOKSERVER-KIND", "MEMBER",
	"X-ADDRESSBOOKSERVER-MEMBER", "CATEGORIES", "PRODID", "REV",
}

@(private)
owned :: proc(name: string) -> bool {
	for o in OWNED {
		if o == name {
			return true
		}
	}
	return false
}

@(private)
typed_params :: proc(t: Typed, v4: bool) -> []ical.Param {
	out := make([dynamic]ical.Param, 0, 2)
	types := make([dynamic]string, 0, len(t.types) + 1)
	for ty in t.types {
		append(&types, v4 ? ty : strings.to_upper(ty))
	}
	if t.pref && !v4 {
		append(&types, "PREF")
	}
	if len(types) > 0 {
		append(&out, ical.Param{name = "TYPE", values = types[:]})
	}
	if t.pref && v4 {
		one := make([]string, 1)
		one[0] = "1"
		append(&out, ical.Param{name = "PREF", values = one})
	}
	return out[:]
}

@(private)
structured :: proc(parts: []string) -> string {
	sb := strings.builder_make()
	for p, i in parts {
		if i > 0 {
			strings.write_byte(&sb, ';')
		}
		strings.write_string(&sb, ical.escape_text(p))
	}
	return strings.to_string(sb)
}

// to_component writes a Card in `version` ("4.0" or "3.0"), keeping every
// property of `raw` that the Card does not own.
to_component :: proc(c: Card, version := "4.0", prodid := "-//Palmy//Contacts//EN") -> ^ical.Component {
	v4 := version != "3.0"
	out := new(ical.Component)
	out.name = "VCARD"
	out.props = make([dynamic]ical.Prop, 0, 16)
	add :: proc(out: ^ical.Component, name, value: string, params: []ical.Param = nil, group := "") {
		append(&out.props, ical.Prop{group = group, name = name, value = value, params = params})
	}
	add(out, "VERSION", v4 ? "4.0" : "3.0")
	add(out, "PRODID", prodid)
	add(out, "UID", c.uid)
	kind := c.kind == "" ? "individual" : c.kind
	if v4 && kind != "individual" {
		add(out, "KIND", kind)
	} else if !v4 && kind == "group" {
		add(out, "X-ADDRESSBOOKSERVER-KIND", "group")
	}
	fn := display_name(c)
	add(out, "FN", ical.escape_text(fn))
	n := []string{c.family, c.given, c.additional, c.prefix, c.suffix}
	if kind == "group" && c.family == "" && c.given == "" {
		n = []string{fn, "", "", "", ""}
	}
	add(out, "N", structured(n))
	if c.nickname != "" {
		add(out, "NICKNAME", ical.escape_text(c.nickname))
	}
	if c.org != "" {
		add(out, "ORG", ical.escape_text(c.org))
	}
	if c.title != "" {
		add(out, "TITLE", ical.escape_text(c.title))
	}
	for e in c.emails {
		params := typed_params(e, v4)
		if !v4 {
			// 3.0 clients expect INTERNET on every address.
			ps := make([dynamic]ical.Param, 0, len(params))
			found := false
			for q in params {
				if q.name == "TYPE" {
					vals := make([dynamic]string, 0, len(q.values) + 1)
					append(&vals, "INTERNET")
					append(&vals, ..q.values)
					append(&ps, ical.Param{name = "TYPE", values = vals[:]})
					found = true
				} else {
					append(&ps, q)
				}
			}
			if !found {
				one := make([]string, 1)
				one[0] = "INTERNET"
				append(&ps, ical.Param{name = "TYPE", values = one})
			}
			params = ps[:]
		}
		add(out, "EMAIL", ical.escape_text(e.value), params, e.group)
	}
	for t in c.phones {
		if v4 {
			ps := make([dynamic]ical.Param, 0, 2)
			append(&ps, ..typed_params(t, true))
			one := make([]string, 1)
			one[0] = "uri"
			append(&ps, ical.Param{name = "VALUE", values = one})
			add(out, "TEL", strings.concatenate({"tel:", strings.trim_space(t.value)}), ps[:], t.group)
		} else {
			add(out, "TEL", ical.escape_text(t.value), typed_params(t, false), t.group)
		}
	}
	for u in c.urls {
		add(out, "URL", u.value, typed_params(u, v4), u.group)
	}
	for a in c.addresses {
		add(out, "ADR", structured({a.po_box, a.extended, a.street, a.locality, a.region, a.postcode, a.country}),
			typed_params(Typed{types = a.types, pref = a.pref}, v4), a.group)
	}
	if c.bday != "" {
		add(out, "BDAY", c.bday)
	}
	if c.note != "" {
		add(out, "NOTE", ical.escape_text(c.note))
	}
	if len(c.categories) > 0 {
		esc := make([dynamic]string, 0, len(c.categories), context.temp_allocator)
		for s in c.categories {
			append(&esc, ical.escape_text(s))
		}
		add(out, "CATEGORIES", strings.join(esc[:], ","))
	}
	for m in c.members {
		add(out, v4 ? "MEMBER" : "X-ADDRESSBOOKSERVER-MEMBER", m)
	}
	if c.raw != nil {
		for p in c.raw.props {
			if owned(p.name) {
				continue
			}
			np := p
			if p.name == "PHOTO" || p.name == "LOGO" {
				np = convert_photo(p, v4)
			}
			append(&out.props, np)
		}
	}
	return out
}

// convert_photo moves an inline image between 3.0 (ENCODING=b;TYPE=JPEG) and
// 4.0 (a data: URI).
@(private)
convert_photo :: proc(p: ical.Prop, v4: bool) -> ical.Prop {
	np := p
	enc := strings.to_lower(ical.param(&np, "ENCODING"), context.temp_allocator)
	if v4 && (enc == "b" || enc == "base64") {
		uri := photo_uri(&np)
		np.params = nil
		np.value = uri
		return np
	}
	if !v4 && strings.has_prefix(p.value, "data:") {
		comma := strings.index_byte(p.value, ',')
		semi := strings.index_byte(p.value, ';')
		if comma > 0 && semi > 0 && semi < comma {
			mime := p.value[5:semi]
			sub := mime
			if slash := strings.index_byte(mime, '/'); slash >= 0 {
				sub = mime[slash + 1:]
			}
			e := make([]string, 1)
			e[0] = "b"
			ty := make([]string, 1)
			ty[0] = strings.to_upper(sub)
			// Heap, not a slice literal: a literal lives in this frame.
			ps := make([]ical.Param, 2)
			ps[0] = {name = "ENCODING", values = e}
			ps[1] = {name = "TYPE", values = ty}
			np.params = ps
			np.value = p.value[comma + 1:]
		}
	}
	return np
}

// convert rewrites a card in the other version, keeping what it can.
convert :: proc(c: ^ical.Component, version: string) -> ^ical.Component {
	if strings.trim_space(ical.value(c, "VERSION")) == version {
		return c
	}
	card := from_component(c)
	// PRODID and REV are owned (dropped and rewritten); keep the original
	// PRODID so the converted card still says who wrote it.
	prodid := ical.value(c, "PRODID")
	if prodid == "" {
		prodid = "-//Palmy//Contacts//EN"
	}
	return to_component(card, version, prodid)
}

// ---------------------------------------------------------------------------
// The database index
// ---------------------------------------------------------------------------

Index :: struct {
	uid:     string,
	fn:      string,
	given:   string,
	family:  string,
	org:     string,
	emails:  []string, // lower-cased
	phones:  []string, // digits and a leading +
	kind:    string,
	members: []string,
}

index :: proc(c: ^ical.Component) -> Index {
	card := from_component(c)
	ix := Index {
		uid    = card.uid,
		fn     = display_name(card),
		given  = card.given,
		family = card.family,
		org    = card.org,
		kind   = card.kind,
	}
	emails := make([dynamic]string, 0, len(card.emails))
	for e in card.emails {
		append(&emails, strings.to_lower(e.value))
	}
	phones := make([dynamic]string, 0, len(card.phones))
	for p in card.phones {
		append(&phones, normalise_phone(p.value))
	}
	ix.emails = emails[:]
	ix.phones = phones[:]
	ix.members = card.members
	return ix
}

// normalise_phone keeps digits and a leading '+', for matching duplicates.
normalise_phone :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for c, i in s {
		if c >= '0' && c <= '9' {
			strings.write_rune(&sb, c)
		} else if c == '+' && strings.builder_len(sb) == 0 {
			_ = i
			strings.write_byte(&sb, '+')
		}
	}
	return strings.to_string(sb)
}

// parse_all reads a .vcf file: any number of cards.
parse_all :: proc(text: string) -> (cards: []^ical.Component, ok: bool) {
	roots, _, good := ical.parse(text)
	if !good {
		return nil, false
	}
	out := make([dynamic]^ical.Component, 0, len(roots))
	for r in roots {
		if r.name == "VCARD" {
			append(&out, r)
		}
	}
	return out[:], true
}
