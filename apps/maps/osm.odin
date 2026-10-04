package main

// An OSM XML reader, for the `.osm` file a user is most likely to already have
// — a JOSM save, an Overpass export, or `osmium cat -f xml`.
//
// Only the parts that carry geometry are read:
//
//   <node id lat lon>    with its tags; a tagged node becomes a point feature
//   <way id>             <nd ref> into the node table, <tag> for the class
//   <bounds>             ignored; the extent is computed from the geometry
//
// Relations are *not* assembled. A multipolygon relation — a wood with a lake
// in it, a coastline cut into a hundred ways — needs ring assembly from member
// ways with roles, which is a different program. The reader reports how many it
// skipped rather than silently losing them, and the ways themselves still draw.
// That is the honest limit, and it is also why GeoJSON is the primary format
// here: an export has already done the assembly.
//
// A way is a polygon when its first and last node are the same *and* its tags
// say it is an area; `highway=residential` closing on itself is a loop road,
// not a filled blob, and getting that wrong is the classic way an OSM renderer
// paints a city black.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// load_osm_xml reads a file. Returns the feature count and an error string.
load_osm_xml :: proc(m: ^Map, path: string) -> (n: int, err: string) {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return 0, "cannot read file"
	}
	defer delete(data)
	return parse_osm_xml(m, string(data))
}

@(private = "file")
Node_Pos :: struct {
	lon, lat: f64,
}

// Osm_Tags is the tag state of the element being read.
@(private = "file")
Osm_Tags :: struct {
	class:       Class,
	have_class:  bool,
	oneway:      i8,
	layer:       i8,
	speed:       f32,
	area:        bool, // an explicit area=yes
	closed_area: bool, // the class implies an area when the way closes
}

parse_osm_xml :: proc(m: ^Map, text: string) -> (n: int, err: string) {
	b: Builder
	builder_init(&b, m)
	defer builder_destroy(&b)

	nodes := make(map[i64]Node_Pos)
	defer delete(nodes)
	refs := make([dynamic]i64)
	defer delete(refs)

	before := len(m.features)
	skipped_rel := 0
	saw_osm := false

	tg: Osm_Tags
	name_buf: [192]u8
	ref_buf: [40]u8
	name_n, ref_n := 0, 0

	reset :: proc(tg: ^Osm_Tags, name_n, ref_n: ^int) {
		tg^ = {}
		name_n^, ref_n^ = 0, 0
	}

	i := 0
	// `mode` is which element's children we are inside: 0 none, 1 node, 2 way,
	// 3 relation. OSM XML is flat enough that one level is all that is needed.
	mode := 0
	cur_lon, cur_lat := 0.0, 0.0
	cur_id := i64(0)

	for i < len(text) {
		lt := strings.index_byte(text[i:], '<')
		if lt < 0 {
			break
		}
		i += lt + 1
		if i >= len(text) {
			break
		}
		// Comments, declarations and CDATA.
		if strings.has_prefix(text[i:], "!--") {
			e := strings.index(text[i:], "-->")
			if e < 0 {
				return len(m.features) - before, "unterminated comment"
			}
			i += e + 3
			continue
		}
		if text[i] == '?' || text[i] == '!' {
			e := strings.index_byte(text[i:], '>')
			if e < 0 {
				return len(m.features) - before, "unterminated declaration"
			}
			i += e + 1
			continue
		}

		closing := text[i] == '/'
		if closing {
			i += 1
		}
		// The element name.
		ns := i
		for i < len(text) && text[i] != ' ' && text[i] != '\t' && text[i] != '\n' &&
		    text[i] != '\r' && text[i] != '>' && text[i] != '/' {
			i += 1
		}
		elem := text[ns:i]
		// The attributes, up to the closing '>'.
		astart := i
		for i < len(text) && text[i] != '>' {
			i += 1
		}
		if i >= len(text) {
			return len(m.features) - before, "unterminated element"
		}
		attrs := text[astart:i]
		self_closing := strings.has_suffix(strings.trim_space(attrs), "/")
		i += 1 // past '>'

		switch elem {
		case "osm":
			if !closing {
				saw_osm = true
			}

		case "node":
			if closing {
				finish_node(&b, &tg, name_buf[:name_n], ref_buf[:ref_n], cur_lon, cur_lat)
				mode = 0
				continue
			}
			id, idok := attr_i64(attrs, "id")
			lon, lonok := attr_f64(attrs, "lon")
			lat, latok := attr_f64(attrs, "lat")
			if !idok || !lonok || !latok {
				return len(m.features) - before, "a <node> is missing id, lat or lon"
			}
			if lon < -180.001 || lon > 180.001 || lat < -90.001 || lat > 90.001 {
				return len(m.features) - before, "a <node> has coordinates out of range"
			}
			nodes[id] = {lon, lat}
			cur_id, cur_lon, cur_lat = id, lon, lat
			reset(&tg, &name_n, &ref_n)
			if self_closing {
				mode = 0
			} else {
				mode = 1
			}

		case "way":
			if closing {
				finish_way(&b, &tg, name_buf[:name_n], ref_buf[:ref_n], refs[:], &nodes)
				mode = 0
				continue
			}
			clear(&refs)
			reset(&tg, &name_n, &ref_n)
			mode = self_closing ? 0 : 2

		case "relation":
			if closing {
				mode = 0
				continue
			}
			skipped_rel += 1
			mode = self_closing ? 0 : 3

		case "nd":
			if mode == 2 {
				if r, rok := attr_i64(attrs, "ref"); rok {
					append(&refs, r)
				}
			}

		case "tag":
			if mode != 1 && mode != 2 {
				continue
			}
			k, kok := attr_str(attrs, "k")
			v, vok := attr_str(attrs, "v")
			if !kok || !vok {
				continue
			}
			apply_tag(&tg, k, v, &name_buf, &name_n, &ref_buf, &ref_n)
		}
	}

	builder_finish(&b)
	if !saw_osm && len(m.features) == before {
		return 0, "not an OSM XML document"
	}
	if skipped_rel > 0 {
		return len(m.features) - before, fmt.tprintf(
			"%d relations skipped (multipolygons are not assembled)",
			skipped_rel,
		)
	}
	_ = cur_id
	return len(m.features) - before, ""
}

@(private = "file")
apply_tag :: proc(
	tg: ^Osm_Tags,
	k, v: string,
	name_buf: ^[192]u8,
	name_n: ^int,
	ref_buf: ^[40]u8,
	ref_n: ^int,
) {
	switch k {
	case "name":
		if name_n^ == 0 {
			name_n^ = copy(name_buf[:], v)
		}
	case "name:en":
		if name_n^ == 0 {
			name_n^ = copy(name_buf[:], v)
		}
	case "ref":
		if ref_n^ == 0 {
			ref_n^ = copy(ref_buf[:], v)
		}
	case "oneway":
		tg.oneway = parse_oneway(v)
	case "layer":
		if n, ok := strconv.parse_int(v, 10); ok {
			tg.layer = i8(clamp(n, -8, 8))
		}
	case "maxspeed":
		num := 0
		j := 0
		for j < len(v) && v[j] >= '0' && v[j] <= '9' {
			num = num * 10 + int(v[j] - '0')
			j += 1
		}
		if num > 0 {
			sp := f32(num)
			if strings.contains(v[j:], "mph") {
				sp *= 1.609344
			}
			tg.speed = sp
		}
	case "area":
		if v == "yes" {
			tg.area = true
		}
	case:
		if tg.have_class {
			return
		}
		// Classify twice: once as a polygon and once as a line, because the
		// answer differs for `waterway=river`. The geometry decides which is
		// used, and `closed_area` records whether a closed way with this tag
		// should be filled.
		if c, ok := classify(k, v, .Polygon); ok {
			tg.class = c
			tg.have_class = true
			tg.closed_area = is_area_class(c)
			if k == "highway" || k == "railway" {
				tg.closed_area = false
			}
		}
	}
}

@(private = "file")
finish_node :: proc(b: ^Builder, tg: ^Osm_Tags, name, ref: []u8, lon, lat: f64) {
	if !tg.have_class {
		return // an untagged node is geometry for a way, not a feature
	}
	begin_feature(b, .Point, tg.class, string(name), string(ref))
	begin_ring(b)
	add_point(b, lon, lat)
	end_feature(b)
}

@(private = "file")
finish_way :: proc(
	b: ^Builder,
	tg: ^Osm_Tags,
	name, ref: []u8,
	refs: []i64,
	nodes: ^map[i64]Node_Pos,
) {
	if len(refs) < 2 {
		return
	}
	closed := refs[0] == refs[len(refs) - 1] && len(refs) >= 4
	geom := Geom.Line
	cls := tg.class
	if !tg.have_class {
		cls = closed ? .Landuse : .Residential_Road
	}
	if closed && (tg.area || tg.closed_area) {
		geom = .Polygon
	}
	if geom == .Line && cls == .Water {
		cls = .River
	}
	if geom == .Polygon && cls == .River {
		cls = .Water
	}

	begin_feature(b, geom, cls, string(name), string(ref))
	b.f.oneway = tg.oneway
	b.f.layer = tg.layer
	b.f.speed = tg.speed
	begin_ring(b)
	for r in refs {
		if pos, ok := nodes[r]; ok {
			add_point(b, pos.lon, pos.lat)
		}
	}
	end_feature(b)
}

// ---------------------------------------------------------------------------
// Attributes
// ---------------------------------------------------------------------------

// attr_str finds `name="value"` in an attribute run and unescapes the five XML
// entities. The value is temp-allocated only when it actually needs unescaping,
// which is almost never.
attr_str :: proc(attrs, name: string) -> (string, bool) {
	i := 0
	for i < len(attrs) {
		// Skip to the start of a name.
		for i < len(attrs) &&
		    (attrs[i] == ' ' || attrs[i] == '\t' || attrs[i] == '\n' || attrs[i] == '\r') {
			i += 1
		}
		ns := i
		for i < len(attrs) && attrs[i] != '=' && attrs[i] != ' ' && attrs[i] != '/' &&
		    attrs[i] != '\t' && attrs[i] != '\n' && attrs[i] != '\r' {
			i += 1
		}
		key := attrs[ns:i]
		for i < len(attrs) && attrs[i] != '=' {
			if attrs[i] == '/' {
				return "", false
			}
			i += 1
		}
		if i >= len(attrs) {
			return "", false
		}
		i += 1 // past '='
		for i < len(attrs) && (attrs[i] == ' ' || attrs[i] == '\t') {
			i += 1
		}
		if i >= len(attrs) || (attrs[i] != '"' && attrs[i] != '\'') {
			return "", false
		}
		qt := attrs[i]
		i += 1
		vs := i
		for i < len(attrs) && attrs[i] != qt {
			i += 1
		}
		if i >= len(attrs) {
			return "", false
		}
		val := attrs[vs:i]
		i += 1
		if key == name {
			if strings.index_byte(val, '&') < 0 {
				return val, true
			}
			return xml_unescape(val), true
		}
	}
	return "", false
}

xml_unescape :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] != '&' {
			strings.write_byte(&sb, s[i])
			i += 1
			continue
		}
		rest := s[i:]
		switch {
		case strings.has_prefix(rest, "&amp;"):
			strings.write_byte(&sb, '&')
			i += 5
		case strings.has_prefix(rest, "&lt;"):
			strings.write_byte(&sb, '<')
			i += 4
		case strings.has_prefix(rest, "&gt;"):
			strings.write_byte(&sb, '>')
			i += 4
		case strings.has_prefix(rest, "&quot;"):
			strings.write_byte(&sb, '"')
			i += 6
		case strings.has_prefix(rest, "&apos;"):
			strings.write_byte(&sb, '\'')
			i += 6
		case strings.has_prefix(rest, "&#"):
			semi := strings.index_byte(rest, ';')
			if semi < 0 {
				strings.write_byte(&sb, '&')
				i += 1
				break
			}
			body := rest[2:semi]
			cp := u64(0)
			cok := false
			if len(body) > 0 && (body[0] == 'x' || body[0] == 'X') {
				cp, cok = strconv.parse_u64_of_base(body[1:], 16)
			} else {
				cp, cok = strconv.parse_u64_of_base(body, 10)
			}
			if cok && cp > 0 && cp < 0x110000 {
				strings.write_rune(&sb, rune(cp))
			}
			i += semi + 1
		case:
			strings.write_byte(&sb, '&')
			i += 1
		}
	}
	return strings.to_string(sb)
}

attr_f64 :: proc(attrs, name: string) -> (f64, bool) {
	s, ok := attr_str(attrs, name)
	if !ok {
		return 0, false
	}
	return strconv.parse_f64(strings.trim_space(s))
}

attr_i64 :: proc(attrs, name: string) -> (i64, bool) {
	s, ok := attr_str(attrs, name)
	if !ok {
		return 0, false
	}
	v, pok := strconv.parse_i64(strings.trim_space(s), 10)
	return v, pok
}
