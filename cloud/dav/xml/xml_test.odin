package xml

import "core:strings"
import "core:testing"

@(test)
namespaces :: proc(t: ^testing.T) {
	body := `<?xml version="1.0" encoding="utf-8" ?>
<!-- a comment -->
<propfind xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:x="http://apple.com/ns/ical/">
  <prop>
    <resourcetype/>
    <C:calendar-home-set />
    <x:calendar-color/>
    <displayname xmlns="urn:example:other"/>
  </prop>
</propfind>`
	root, err := parse(body)
	testing.expect_value(t, err, "")
	testing.expect(t, is(root, NS_DAV, "propfind"))
	prop := find(root, NS_DAV, "prop")
	testing.expect(t, prop != nil)
	testing.expect_value(t, len(prop.children), 4)
	testing.expect(t, is(prop.children[1], NS_CALDAV, "calendar-home-set"))
	testing.expect(t, is(prop.children[2], NS_APPLE, "calendar-color"))
	testing.expect(t, is(prop.children[3], "urn:example:other", "displayname"), "a redeclared default namespace")
}

@(test)
text_and_entities :: proc(t: ^testing.T) {
	root, err := parse(`<D:href xmlns:D="DAV:">/a%20b/&amp;&lt;&#233;&#x41;<![CDATA[<x>]]></D:href>`)
	testing.expect_value(t, err, "")
	testing.expect_value(t, root.text, "/a%20b/&<éA<x>")
	_, bad := parse(`<a:b xmlns:c="x"/>`)
	testing.expect(t, bad != "", "an undeclared prefix is an error")
	_, bad2 := parse(`<a><b></a>`)
	testing.expect(t, bad2 != "")
	_, bad3 := parse(`<!DOCTYPE x [<!ENTITY a "aaaa">]><x>&a;</x>`)
	testing.expect_value(t, bad3, "")
}

@(test)
writing :: proc(t: ^testing.T) {
	w := writer_make(context.temp_allocator)
	open(&w, NS_DAV, "multistatus")
	open(&w, NS_DAV, "response")
	leaf(&w, NS_DAV, "href", "/a&b")
	empty(&w, "urn:x", "unknown")
	out := finish(&w)
	testing.expect(t, strings.contains(out, `<d:multistatus xmlns:d="DAV:"`))
	testing.expect(t, strings.contains(out, `<d:href>/a&amp;b</d:href>`))
	testing.expect(t, strings.contains(out, `<x1:unknown xmlns:x1="urn:x"/>`))
	back, err := parse(out)
	testing.expect_value(t, err, "")
	testing.expect(t, is(find(find(back, NS_DAV, "response"), "urn:x", "unknown"), "urn:x", "unknown"))
}
