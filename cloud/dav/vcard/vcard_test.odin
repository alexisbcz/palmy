package vcard

import "core:strings"
import "core:testing"
import ical "../ical"

APPLE_CARD :: "BEGIN:VCARD\r\nVERSION:3.0\r\nPRODID:-//Apple Inc.//iPhone OS 17.0//EN\r\n" +
	"N:Lovelace;Ada;;Countess;\r\nFN:Ada Lovelace\r\nORG:Analytical Engines;\r\n" +
	"EMAIL;type=INTERNET;type=WORK;type=pref:ada@engines.example\r\n" +
	"TEL;type=CELL;type=VOICE;type=pref:+44 20 7946 0000\r\n" +
	"item1.ADR;type=HOME:;;12 St James's Square;London;;SW1Y 4JH;United Kingdom\r\n" +
	"item1.X-ABADR:gb\r\nPHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQSkZJRg==\r\n" +
	"X-SOCIALPROFILE;type=twitter:x-apple:ada\r\nUID:ada-1815\r\nEND:VCARD\r\n"

@(test)
apple_3_to_4_and_back :: proc(t: ^testing.T) {
	c, _, ok := ical.parse_one(APPLE_CARD)
	testing.expect(t, ok)
	testing.expect_value(t, check(c), Check_Error.None)
	card := from_component(c)
	testing.expect_value(t, card.given, "Ada")
	testing.expect_value(t, card.family, "Lovelace")
	testing.expect_value(t, card.org, "Analytical Engines")
	testing.expect_value(t, len(card.emails), 1)
	testing.expect(t, card.emails[0].pref)
	testing.expect_value(t, card.addresses[0].locality, "London")
	testing.expect(t, strings.has_prefix(card.photo, "data:image/jpeg;base64,"))

	v4 := convert(c, "4.0")
	out := ical.write(v4, context.temp_allocator)
	testing.expect(t, strings.contains(out, "VERSION:4.0"))
	testing.expect(t, strings.contains(out, "TEL;TYPE=cell,voice;PREF=1;VALUE=uri:tel:+44 20 7946 0000"))
	testing.expect(t, strings.contains(out, "PHOTO:data:image/jpeg;base64,/9j/4AAQSkZJRg=="))
	testing.expect(t, strings.contains(out, "X-SOCIALPROFILE"), "an unknown property survives")
	testing.expect(t, strings.contains(out, "item1.X-ABADR:gb"), "and keeps its group")

	back := convert(v4, "3.0")
	out3 := ical.write(back, context.temp_allocator)
	testing.expect(t, strings.contains(out3, "VERSION:3.0"))
	testing.expect(t, strings.contains(out3, "EMAIL;TYPE=INTERNET,WORK,PREF:ada@engines.example"))
	testing.expect(t, strings.contains(out3, "PHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQSkZJRg=="))
	again := from_component(back)
	testing.expect_value(t, again.phones[0].value, "+44 20 7946 0000")
}

@(test)
groups :: proc(t: ^testing.T) {
	g := Card {
		uid     = "g1",
		fn      = "Climbing club",
		kind    = "group",
		members = []string{"urn:uuid:ada-1815", "urn:uuid:b2"},
	}
	v4 := ical.write(to_component(g, "4.0"), context.temp_allocator)
	testing.expect(t, strings.contains(v4, "KIND:group"))
	testing.expect(t, strings.contains(v4, "MEMBER:urn:uuid:ada-1815"))
	v3 := ical.write(to_component(g, "3.0"), context.temp_allocator)
	testing.expect(t, strings.contains(v3, "X-ADDRESSBOOKSERVER-KIND:group"))
	testing.expect(t, strings.contains(v3, "X-ADDRESSBOOKSERVER-MEMBER:urn:uuid:b2"))
	c, _, _ := ical.parse_one(v3)
	back := from_component(c)
	testing.expect_value(t, back.kind, "group")
	testing.expect_value(t, len(back.members), 2)
	ix := index(c)
	testing.expect_value(t, ix.kind, "group")
}

@(test)
escapes_and_index :: proc(t: ^testing.T) {
	card := Card {
		uid    = "x",
		given  = "Jean;Paul",
		family = "Sartre, J.",
		note   = "line one\nline two",
		emails = []Typed{{value = "JP@Example.ORG", types = []string{"home"}}},
		phones = []Typed{{value = "+33 (0)1 23-45"}},
	}
	text := ical.write(to_component(card), context.temp_allocator)
	c, _, ok := ical.parse_one(text)
	testing.expect(t, ok)
	back := from_component(c)
	testing.expect_value(t, back.given, "Jean;Paul")
	testing.expect_value(t, back.family, "Sartre, J.")
	testing.expect_value(t, back.note, "line one\nline two")
	ix := index(c)
	testing.expect_value(t, ix.emails[0], "jp@example.org")
	testing.expect_value(t, ix.phones[0], "+33012345")
	testing.expect_value(t, ix.fn, "Jean;Paul Sartre, J.")
	many, mok := parse_all(strings.concatenate({APPLE_CARD, text}, context.temp_allocator))
	testing.expect(t, mok && len(many) == 2)
}
