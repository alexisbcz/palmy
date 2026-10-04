package main

// A GeoJSON reader (RFC 7946), hand-written and streaming into the Builder.
//
// Why not a generic JSON parser: a city extract is tens of megabytes of
// coordinate arrays, and a generic parser builds a Value tree for every pair of
// numbers before anything looks at them. This reads the document once, left to
// right, and appends straight into the coordinate pool.
//
// What is supported:
//
//   FeatureCollection, Feature, GeometryCollection
//   Point, MultiPoint, LineString, MultiLineString, Polygon, MultiPolygon
//   polygon holes (every ring after the first in a Polygon)
//   a bare geometry at the top level, which several tools write
//   `properties` read for name, class, oneway, maxspeed and layer
//
// What it refuses, with a message and a byte offset rather than a crash:
// trailing or missing commas, unterminated strings and arrays, a coordinate
// that is not a number, a position with fewer than two numbers, numbers out of
// the lon/lat range, unknown geometry types, and nesting deeper than the type
// allows. Malformed input is the normal case for a file a user drops in, so
// refusing it precisely is a feature of the reader and not an afterthought.

import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

Json_Err :: struct {
	msg: string,
	at:  int, // byte offset
	line: int,
}

// Err_State is the error counter at a point in the parse. The reader keeps the
// *first* error and goes on reading what it can, so "did this step fail" has to
// be asked as "did the counter move", not as "is there an error" — otherwise a
// truncated document's one error would make every later step look like a
// failure and the features already read would be thrown away.
@(private = "file")
errn_of :: proc(r: ^Reader) -> int {return r.errn}

Reader :: struct {
	s:     string,
	i:     int,
	depth: int,
	err:   Json_Err,
	errn:  int, // how many errors have been reported; see Err_State above
	b:     ^Builder,
	// Properties of the feature being read, held until the geometry is seen
	// because RFC 7946 does not fix the member order.
	name:   string,
	ref:    string,
	class:  Class,
	oneway: i8,
	speed:  f32,
	layer:  i8,
	have_class: bool,
	// Scratch for the current property name/value, pointing into `s`.
	buf:   strings.Builder,
}

MAX_DEPTH :: 64

// load_geojson reads a file into the map. The map is not cleared, so several
// files can be layered.
load_geojson :: proc(m: ^Map, path: string) -> (n: int, err: Json_Err) {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return 0, {msg = "cannot read file", at = 0, line = 0}
	}
	defer delete(data)
	return parse_geojson(m, string(data))
}

// parse_geojson is the same thing against a string, which is what the
// self-test drives.
parse_geojson :: proc(m: ^Map, text: string) -> (n: int, err: Json_Err) {
	b: Builder
	builder_init(&b, m)
	defer builder_destroy(&b)

	r := Reader{s = text, b = &b}
	r.buf = strings.builder_make()
	defer strings.builder_destroy(&r.buf)

	before := len(m.features)
	skip_ws(&r)
	// A UTF-8 BOM is common from Windows tools and is not a syntax error.
	if strings.has_prefix(r.s[r.i:], "\xef\xbb\xbf") {
		r.i += 3
		skip_ws(&r)
	}
	read_root(&r)
	builder_finish(&b)
	_ = errn_of
	if r.err.msg != "" {
		// A partially read document leaves whatever it managed; the caller
		// decides whether to keep it. The self-test asserts the refusal.
		return len(m.features) - before, r.err
	}
	return len(m.features) - before, {}
}

// ---------------------------------------------------------------------------
// Lexing
// ---------------------------------------------------------------------------

@(private = "file")
fail :: proc(r: ^Reader, msg: string) {
	r.errn += 1
	if r.err.msg != "" {
		return // keep the first error; it is the one that explains the rest
	}
	line := 1
	for c, k in transmute([]u8)r.s {
		if k >= r.i {
			break
		}
		if c == '\n' {
			line += 1
		}
	}
	r.err = {msg = msg, at = r.i, line = line}
}

@(private = "file")
skip_ws :: proc(r: ^Reader) {
	for r.i < len(r.s) {
		switch r.s[r.i] {
		case ' ', '\t', '\n', '\r':
			r.i += 1
		case:
			return
		}
	}
}

@(private = "file")
peek :: proc(r: ^Reader) -> u8 {
	skip_ws(r)
	if r.i >= len(r.s) {
		return 0
	}
	return r.s[r.i]
}

@(private = "file")
want :: proc(r: ^Reader, c: u8) -> bool {
	if peek(r) != c {
		if r.i >= len(r.s) {
			fail(r, "unexpected end of document")
		} else {
			fail(r, "unexpected character")
		}
		return false
	}
	r.i += 1
	return true
}

// read_string decodes a JSON string into `r.buf` and returns a slice of it.
// The slice is only valid until the next read_string.
@(private = "file")
read_string :: proc(r: ^Reader) -> (string, bool) {
	if !want(r, '"') {
		return "", false
	}
	strings.builder_reset(&r.buf)
	for r.i < len(r.s) {
		c := r.s[r.i]
		r.i += 1
		switch c {
		case '"':
			return strings.to_string(r.buf), true
		case '\\':
			if r.i >= len(r.s) {
				fail(r, "unterminated escape")
				return "", false
			}
			e := r.s[r.i]
			r.i += 1
			switch e {
			case '"':
				strings.write_byte(&r.buf, '"')
			case '\\':
				strings.write_byte(&r.buf, '\\')
			case '/':
				strings.write_byte(&r.buf, '/')
			case 'b':
				strings.write_byte(&r.buf, '\b')
			case 'f':
				strings.write_byte(&r.buf, '\f')
			case 'n':
				strings.write_byte(&r.buf, '\n')
			case 'r':
				strings.write_byte(&r.buf, '\r')
			case 't':
				strings.write_byte(&r.buf, '\t')
			case 'u':
				if r.i + 4 > len(r.s) {
					fail(r, "truncated \\u escape")
					return "", false
				}
				cp, uok := strconv.parse_u64_of_base(r.s[r.i:][:4], 16)
				if !uok {
					fail(r, "bad \\u escape")
					return "", false
				}
				r.i += 4
				v := rune(cp)
				// A surrogate pair is two escapes; join them so a name with a
				// character outside the BMP is not mangled.
				if cp >= 0xd800 && cp <= 0xdbff && r.i + 6 <= len(r.s) &&
				   r.s[r.i] == '\\' && r.s[r.i + 1] == 'u' {
					lo, lok := strconv.parse_u64_of_base(r.s[r.i + 2:][:4], 16)
					if lok && lo >= 0xdc00 && lo <= 0xdfff {
						r.i += 6
						v = rune(0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00))
					}
				}
				strings.write_rune(&r.buf, v)
			case:
				fail(r, "unknown escape")
				return "", false
			}
		case:
			strings.write_byte(&r.buf, c)
		}
	}
	fail(r, "unterminated string")
	return "", false
}

@(private = "file")
read_number :: proc(r: ^Reader) -> (f64, bool) {
	skip_ws(r)
	start := r.i
	if r.i < len(r.s) && (r.s[r.i] == '-' || r.s[r.i] == '+') {
		r.i += 1
	}
	digits := 0
	for r.i < len(r.s) && r.s[r.i] >= '0' && r.s[r.i] <= '9' {
		r.i += 1
		digits += 1
	}
	if r.i < len(r.s) && r.s[r.i] == '.' {
		r.i += 1
		for r.i < len(r.s) && r.s[r.i] >= '0' && r.s[r.i] <= '9' {
			r.i += 1
			digits += 1
		}
	}
	if digits == 0 {
		fail(r, "expected a number")
		return 0, false
	}
	if r.i < len(r.s) && (r.s[r.i] == 'e' || r.s[r.i] == 'E') {
		r.i += 1
		if r.i < len(r.s) && (r.s[r.i] == '-' || r.s[r.i] == '+') {
			r.i += 1
		}
		ed := 0
		for r.i < len(r.s) && r.s[r.i] >= '0' && r.s[r.i] <= '9' {
			r.i += 1
			ed += 1
		}
		if ed == 0 {
			fail(r, "exponent has no digits")
			return 0, false
		}
	}
	v, ok := strconv.parse_f64(r.s[start:r.i])
	if !ok {
		fail(r, "unparsable number")
		return 0, false
	}
	if math.is_nan(v) || math.is_inf(v) {
		fail(r, "number is not finite")
		return 0, false
	}
	return v, true
}

@(private = "file")
read_literal :: proc(r: ^Reader) -> (val: bool, is_null: bool, ok: bool) {
	skip_ws(r)
	rest := r.s[r.i:]
	switch {
	case strings.has_prefix(rest, "true"):
		r.i += 4
		return true, false, true
	case strings.has_prefix(rest, "false"):
		r.i += 5
		return false, false, true
	case strings.has_prefix(rest, "null"):
		r.i += 4
		return false, true, true
	}
	fail(r, "expected true, false or null")
	return false, false, false
}

// scan_value is a *structural* skip: it matches brackets and strings and does
// not look inside a number or a literal.
//
// It exists because of partial reads. `read_object` has to find where each
// member ends before it knows which member matters — RFC 7946 does not fix the
// order — and if that first pass validated everything, a FeatureCollection
// whose last feature is truncated would be refused in its entirety, losing the
// eleven thousand good features before it. With a structural scan the first
// pass gets far enough to hand the real parser the `features` array, which
// then reads as many features as it can and reports where it stopped.
//
// Leniency here costs nothing: every member that carries meaning is read again
// strictly by the procedure that interprets it, and `read_object`'s own member
// loop is strict about commas and colons.
@(private = "file")
scan_value :: proc(r: ^Reader) -> bool {
	r.depth += 1
	defer r.depth -= 1
	if r.depth > MAX_DEPTH {
		fail(r, "nested too deeply")
		return false
	}
	switch peek(r) {
	case '{', '[':
		open := r.s[r.i]
		closer := u8(open == '{' ? '}' : ']')
		r.i += 1
		for {
			c := peek(r)
			switch c {
			case 0:
				fail(r, open == '{' ? "unterminated object" : "unterminated array")
				return false
			case ',', ':':
				r.i += 1
				continue
			}
			if c == closer {
				r.i += 1
				return true
			}
			if c == '}' || c == ']' {
				fail(r, "mismatched bracket")
				return false
			}
			if !scan_value(r) {
				return false
			}
		}
	case '"':
		_, ok := read_string(r)
		return ok
	case 0:
		fail(r, "unexpected end of document")
		return false
	case:
		start := r.i
		for r.i < len(r.s) {
			c := r.s[r.i]
			if c == ',' || c == '}' || c == ']' || c == ':' ||
			   c == ' ' || c == '\t' || c == '\n' || c == '\r' {
				break
			}
			r.i += 1
		}
		if r.i == start {
			fail(r, "unexpected character")
			return false
		}
		return true
	}
}

// skip_value consumes any JSON value without interpreting it, which is how
// unknown members are ignored. Unlike `scan_value` it is strict, so it is what
// a value *inside* an interpreted member (a nested object in `properties`) goes
// through. It is also where the depth limit is enforced, so a pathological
// document cannot exhaust the stack.
@(private = "file")
skip_value :: proc(r: ^Reader) -> bool {
	r.depth += 1
	defer r.depth -= 1
	if r.depth > MAX_DEPTH {
		fail(r, "nested too deeply")
		return false
	}
	switch peek(r) {
	case '{':
		r.i += 1
		if peek(r) == '}' {
			r.i += 1
			return true
		}
		for {
			if _, ok := read_string(r); !ok {
				return false
			}
			if !want(r, ':') {
				return false
			}
			if !skip_value(r) {
				return false
			}
			c := peek(r)
			if c == ',' {
				r.i += 1
				continue
			}
			if c == '}' {
				r.i += 1
				return true
			}
			fail(r, "expected , or } in object")
			return false
		}
	case '[':
		r.i += 1
		if peek(r) == ']' {
			r.i += 1
			return true
		}
		for {
			if !skip_value(r) {
				return false
			}
			c := peek(r)
			if c == ',' {
				r.i += 1
				continue
			}
			if c == ']' {
				r.i += 1
				return true
			}
			fail(r, "expected , or ] in array")
			return false
		}
	case '"':
		_, ok := read_string(r)
		return ok
	case 't', 'f', 'n':
		_, _, ok := read_literal(r)
		return ok
	case 0:
		fail(r, "unexpected end of document")
		return false
	case:
		_, ok := read_number(r)
		return ok
	}
}

// ---------------------------------------------------------------------------
// GeoJSON structure
// ---------------------------------------------------------------------------

@(private = "file")
read_root :: proc(r: ^Reader) {
	if peek(r) != '{' {
		fail(r, "a GeoJSON document is a JSON object")
		return
	}
	e0 := errn_of(r)
	read_object(r, 0)
	if errn_of(r) != e0 {
		return
	}
	skip_ws(r)
	if r.i < len(r.s) {
		fail(r, "trailing content after the document")
	}
}

// Kind is what a GeoJSON object's "type" said.
@(private = "file")
Kind :: enum u8 {
	None,
	Feature_Collection,
	Feature,
	Geometry_Collection,
	Point,
	Multi_Point,
	Line_String,
	Multi_Line_String,
	Polygon,
	Multi_Polygon,
}

@(private = "file")
kind_of :: proc(s: string) -> Kind {
	switch s {
	case "FeatureCollection":
		return .Feature_Collection
	case "Feature":
		return .Feature
	case "GeometryCollection":
		return .Geometry_Collection
	case "Point":
		return .Point
	case "MultiPoint":
		return .Multi_Point
	case "LineString":
		return .Line_String
	case "MultiLineString":
		return .Multi_Line_String
	case "Polygon":
		return .Polygon
	case "MultiPolygon":
		return .Multi_Polygon
	}
	return .None
}

// read_object handles any GeoJSON object. The members may arrive in any order,
// so "type", "coordinates"/"geometry"/"features" and "properties" are each
// remembered as a byte range and replayed once the type is known.
@(private = "file")
read_object :: proc(r: ^Reader, nest: int) {
	r.depth += 1
	defer r.depth -= 1
	if r.depth > MAX_DEPTH || nest > 8 {
		fail(r, "nested too deeply")
		return
	}
	if !want(r, '{') {
		return
	}

	kind := Kind.None
	coords_at := -1
	geom_at := -1
	feats_at := -1
	props_at := -1
	geoms_at := -1

	if peek(r) == '}' {
		r.i += 1
		fail(r, "an empty object is not a GeoJSON object")
		return
	}
	for {
		key, ok := read_string(r)
		if !ok {
			return
		}
		k := strings.clone(key, context.temp_allocator)
		if !want(r, ':') {
			return
		}
		scanned := true
		switch k {
		case "type":
			v, sok := read_string(r)
			if !sok {
				return
			}
			kind = kind_of(v)
			if kind == .None {
				fail(r, "unknown GeoJSON type")
				return
			}
		case "coordinates":
			coords_at = r.i
			scanned = scan_value(r)
		case "geometry":
			geom_at = r.i
			scanned = scan_value(r)
		case "features":
			feats_at = r.i
			scanned = scan_value(r)
		case "geometries":
			geoms_at = r.i
			scanned = scan_value(r)
		case "properties":
			props_at = r.i
			scanned = scan_value(r)
		case:
			scanned = scan_value(r)
		}
		if !scanned {
			// The document is already refused. Carry on to the dispatch below
			// anyway, so whatever was readable before the damage is kept.
			break
		}
		c := peek(r)
		if c == ',' {
			r.i += 1
			continue
		}
		if c == '}' {
			r.i += 1
			break
		}
		fail(r, "expected , or } in object")
		return
	}

	end := r.i
	defer r.i = end

	switch kind {
	case .None:
		fail(r, "object has no \"type\"")

	case .Feature_Collection:
		if feats_at < 0 {
			fail(r, "FeatureCollection has no \"features\"")
			return
		}
		r.i = feats_at
		read_array_of_objects(r, nest + 1)

	case .Feature:
		// Properties first, so the class is known before the geometry is
		// appended. A Feature with a null geometry is valid and is skipped.
		reset_props(r)
		if props_at >= 0 {
			r.i = props_at
			e0 := errn_of(r)
			read_properties(r)
			if errn_of(r) != e0 {
				return
			}
		}
		if geom_at < 0 {
			fail(r, "Feature has no \"geometry\"")
			return
		}
		r.i = geom_at
		if peek(r) == 'n' {
			_, _, _ = read_literal(r)
			return
		}
		if peek(r) != '{' {
			fail(r, "Feature geometry is not an object")
			return
		}
		read_object(r, nest + 1)

	case .Geometry_Collection:
		if geoms_at < 0 {
			fail(r, "GeometryCollection has no \"geometries\"")
			return
		}
		r.i = geoms_at
		read_array_of_objects(r, nest + 1)

	case .Point, .Multi_Point, .Line_String, .Multi_Line_String, .Polygon, .Multi_Polygon:
		if coords_at < 0 {
			fail(r, "geometry has no \"coordinates\"")
			return
		}
		// A bare geometry at the top level carries no properties, and
		// `reset_props` has not run for it.
		if nest == 0 {
			reset_props(r)
		}
		r.i = coords_at
		read_geometry(r, kind)
	}
}

@(private = "file")
read_array_of_objects :: proc(r: ^Reader, nest: int) {
	if !want(r, '[') {
		return
	}
	if peek(r) == ']' {
		r.i += 1
		return // an empty FeatureCollection is legal
	}
	for {
		if peek(r) != '{' {
			fail(r, "expected an object in the array")
			return
		}
		e0 := errn_of(r)
		read_object(r, nest)
		if errn_of(r) != e0 {
			return
		}
		c := peek(r)
		if c == ',' {
			r.i += 1
			continue
		}
		if c == ']' {
			r.i += 1
			return
		}
		fail(r, "expected , or ] in array")
		return
	}
}

@(private = "file")
reset_props :: proc(r: ^Reader) {
	r.name, r.ref = "", ""
	r.class = .Unknown
	r.oneway, r.layer = 0, 0
	r.speed = 0
	r.have_class = false
}

// read_properties pulls out the members this renderer understands. Everything
// else is skipped: a real extract carries dozens of tags per feature and
// keeping them would cost more memory than the geometry.
@(private = "file")
read_properties :: proc(r: ^Reader) {
	if peek(r) == 'n' {
		_, _, _ = read_literal(r)
		return
	}
	if !want(r, '{') {
		return
	}
	if peek(r) == '}' {
		r.i += 1
		return
	}
	name_buf: [192]u8
	name_n := 0
	ref_buf: [40]u8
	ref_n := 0

	for {
		key, ok := read_string(r)
		if !ok {
			return
		}
		k := strings.clone(key, context.temp_allocator)
		if !want(r, ':') {
			return
		}
		// Only string and number values are interpreted; a tag whose value is
		// an object or an array is skipped wholesale.
		c := peek(r)
		if c == '"' {
			v, vok := read_string(r)
			if !vok {
				return
			}
			switch k {
			case "name", "name:en", "NAME", "Name":
				if name_n == 0 {
					name_n = copy(name_buf[:], v)
				}
			case "ref", "REF":
				if ref_n == 0 {
					ref_n = copy(ref_buf[:], v)
				}
			case "oneway":
				r.oneway = parse_oneway(v)
			case "maxspeed":
				// "50", "50 mph", "RO:urban" — take the leading number, and
				// convert if the unit says miles.
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
					r.speed = sp
				}
			case "layer":
				if n, nok := strconv.parse_int(v, 10); nok {
					r.layer = i8(clamp(n, -8, 8))
				}
			case:
				if !r.have_class {
					if cl, cok := classify(k, v, .Polygon); cok {
						r.class = cl
						r.have_class = true
					}
				}
			}
		} else if c == 't' || c == 'f' || c == 'n' {
			b, is_null, lok := read_literal(r)
			if !lok {
				return
			}
			if !is_null && k == "oneway" && b {
				r.oneway = 1
			}
			if !is_null && !r.have_class && k == "building" && b {
				r.class = .Building
				r.have_class = true
			}
		} else if c == '{' || c == '[' {
			if !skip_value(r) {
				return
			}
		} else {
			v, nok := read_number(r)
			if !nok {
				return
			}
			switch k {
			case "maxspeed":
				r.speed = f32(v)
			case "layer":
				r.layer = i8(clamp(int(v), -8, 8))
			}
		}
		cc := peek(r)
		if cc == ',' {
			r.i += 1
			continue
		}
		if cc == '}' {
			r.i += 1
			break
		}
		fail(r, "expected , or } in properties")
		return
	}
	r.name = strings.clone(string(name_buf[:name_n]), context.temp_allocator)
	r.ref = strings.clone(string(ref_buf[:ref_n]), context.temp_allocator)
}

// read_position reads one `[lon, lat]`, tolerating the optional third
// (elevation) element RFC 7946 allows and rejecting anything shorter.
@(private = "file")
read_position :: proc(r: ^Reader) -> (lon, lat: f64, ok: bool) {
	if !want(r, '[') {
		return 0, 0, false
	}
	n := 0
	vals: [3]f64
	// The empty-array case is tested once, before the loop. Testing it at the
	// top of every iteration instead would quietly accept `[1,2,]`, because
	// the trailing comma would be followed by the closing bracket.
	if peek(r) == ']' {
		r.i += 1
	} else {
		for {
			v, vok := read_number(r)
			if !vok {
				return 0, 0, false
			}
			if n < 3 {
				vals[n] = v
			}
			n += 1
			c := peek(r)
			if c == ',' {
				r.i += 1
				continue
			}
			if c == ']' {
				r.i += 1
				break
			}
			fail(r, "expected , or ] in a position")
			return 0, 0, false
		}
	}
	if n < 2 {
		fail(r, "a position needs at least longitude and latitude")
		return 0, 0, false
	}
	if vals[0] < -180.0001 || vals[0] > 180.0001 {
		fail(r, "longitude out of range")
		return 0, 0, false
	}
	if vals[1] < -90.0001 || vals[1] > 90.0001 {
		fail(r, "latitude out of range")
		return 0, 0, false
	}
	return vals[0], vals[1], true
}

// read_ring reads `[[lon,lat], ...]` into the current ring.
@(private = "file")
read_ring :: proc(r: ^Reader, hole: bool) -> bool {
	if !want(r, '[') {
		return false
	}
	begin_ring(r.b, hole)
	if peek(r) == ']' {
		r.i += 1
		return true
	}
	for {
		lon, lat, ok := read_position(r)
		if !ok {
			return false
		}
		add_point(r.b, lon, lat)
		c := peek(r)
		if c == ',' {
			r.i += 1
			if peek(r) == ']' {
				fail(r, "trailing comma in a coordinate list")
				return false
			}
			continue
		}
		if c == ']' {
			r.i += 1
			return true
		}
		fail(r, "expected , or ] in a coordinate list")
		return false
	}
}

@(private = "file")
read_geometry :: proc(r: ^Reader, kind: Kind) {
	geom: Geom
	switch kind {
	case .Point, .Multi_Point:
		geom = .Point
	case .Line_String, .Multi_Line_String:
		geom = .Line
	case .Polygon, .Multi_Polygon:
		geom = .Polygon
	case .None, .Feature, .Feature_Collection, .Geometry_Collection:
		fail(r, "not a geometry")
		return
	}

	class := r.class
	if !r.have_class {
		// With no recognisable tag, guess from the shape: a closed ring is an
		// area, a line is a road, a point is a place.
		switch geom {
		case .Polygon:
			class = .Landuse
		case .Line:
			class = .Residential_Road
		case .Point:
			class = .Poi
		}
	}
	// A class learned from a polygon tag table may not suit a line: a
	// `waterway=river` drawn as a line is a River, as an area it is Water.
	if geom == .Line && class == .Water {
		class = .River
	}
	if geom == .Polygon && class == .River {
		class = .Water
	}

	begin_feature(r.b, geom, class, r.name, r.ref)
	r.b.f.oneway = r.oneway
	r.b.f.layer = r.layer
	r.b.f.speed = r.speed

	switch kind {
	case .Point:
		lon, lat, ok := read_position(r)
		if !ok {
			r.b.open = false
			resize(&r.b.m.rings, int(r.b.f.first_ring))
			return
		}
		begin_ring(r.b)
		add_point(r.b, lon, lat)

	case .Multi_Point:
		if !want(r, '[') {
			discard(r)
			return
		}
		for peek(r) != ']' {
			lon, lat, ok := read_position(r)
			if !ok {
				discard(r)
				return
			}
			begin_ring(r.b)
			add_point(r.b, lon, lat)
			if peek(r) == ',' {
				r.i += 1
				continue
			}
			break
		}
		if !want(r, ']') {
			discard(r)
			return
		}

	case .Line_String:
		if !read_ring(r, false) {
			discard(r)
			return
		}

	case .Multi_Line_String, .Polygon:
		// Identical shape: an array of rings. In a Polygon every ring after
		// the first is a hole; in a MultiLineString none of them are.
		if !want(r, '[') {
			discard(r)
			return
		}
		idx := 0
		for peek(r) != ']' {
			if !read_ring(r, kind == .Polygon && idx > 0) {
				discard(r)
				return
			}
			idx += 1
			if peek(r) == ',' {
				r.i += 1
				continue
			}
			break
		}
		if !want(r, ']') {
			discard(r)
			return
		}

	case .Multi_Polygon:
		if !want(r, '[') {
			discard(r)
			return
		}
		for peek(r) != ']' {
			if !want(r, '[') {
				discard(r)
				return
			}
			idx := 0
			for peek(r) != ']' {
				if !read_ring(r, idx > 0) {
					discard(r)
					return
				}
				idx += 1
				if peek(r) == ',' {
					r.i += 1
					continue
				}
				break
			}
			if !want(r, ']') {
				discard(r)
				return
			}
			if peek(r) == ',' {
				r.i += 1
				continue
			}
			break
		}
		if !want(r, ']') {
			discard(r)
			return
		}

	case .None, .Feature, .Feature_Collection, .Geometry_Collection:
		discard(r)
		return
	}

	end_feature(r.b)
}

// discard rolls a half-read feature's geometry back out of the pools so a
// refused document does not leave a fragment behind.
@(private = "file")
discard :: proc(r: ^Reader) {
	if !r.b.open {
		return
	}
	r.b.open = false
	if r.b.f.first_ring < i32(len(r.b.m.rings)) {
		first := r.b.m.rings[r.b.f.first_ring].first
		resize(&r.b.m.pts, int(first))
		resize(&r.b.m.rings, int(r.b.f.first_ring))
	}
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// write_geojson serialises the map back out. The generator uses it, and it is
// also how a round-trip is asserted: parse(write(m)) has the same features.
write_geojson :: proc(m: ^Map, path: string) -> bool {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, "{\"type\":\"FeatureCollection\",\"features\":[\n")
	for f, fi in m.features {
		if fi > 0 {
			strings.write_string(&sb, ",\n")
		}
		strings.write_string(&sb, "{\"type\":\"Feature\",\"properties\":{")
		first := true
		put := proc(sb: ^strings.Builder, first: ^bool, k, v: string) {
			if !first^ {
				strings.write_string(sb, ",")
			}
			first^ = false
			strings.write_string(sb, "\"")
			strings.write_string(sb, k)
			strings.write_string(sb, "\":\"")
			for c in transmute([]u8)v {
				switch c {
				case '"':
					strings.write_string(sb, "\\\"")
				case '\\':
					strings.write_string(sb, "\\\\")
				case '\n':
					strings.write_string(sb, "\\n")
				case:
					strings.write_byte(sb, c)
				}
			}
			strings.write_string(sb, "\"")
		}
		if f.name != "" {
			put(&sb, &first, "name", f.name)
		}
		if f.ref != "" {
			put(&sb, &first, "ref", f.ref)
		}
		key, val := class_tag(f.class)
		put(&sb, &first, key, val)
		if f.oneway == 1 {
			put(&sb, &first, "oneway", "yes")
		} else if f.oneway == -1 {
			put(&sb, &first, "oneway", "-1")
		}
		if f.speed > 0 && is_road(f.class) {
			buf: [24]u8
			put(&sb, &first, "maxspeed", strconv.write_int(buf[:], i64(f.speed), 10))
		}
		strings.write_string(&sb, "},\"geometry\":{\"type\":\"")

		multi := f.ring_count > 1
		switch f.geom {
		case .Point:
			strings.write_string(&sb, multi ? "MultiPoint" : "Point")
		case .Line:
			strings.write_string(&sb, multi ? "MultiLineString" : "LineString")
		case .Polygon:
			strings.write_string(&sb, "Polygon")
		}
		strings.write_string(&sb, "\",\"coordinates\":")

		write_ring := proc(sb: ^strings.Builder, m: ^Map, r: Ring) {
			strings.write_string(sb, "[")
			for i in 0 ..< r.count {
				if i > 0 {
					strings.write_string(sb, ",")
				}
				lon, lat := world_to_lonlat(m.pts[r.first + i])
				strings.write_string(sb, "[")
				write_coord(sb, lon)
				strings.write_string(sb, ",")
				write_coord(sb, lat)
				strings.write_string(sb, "]")
			}
			strings.write_string(sb, "]")
		}

		switch f.geom {
		case .Point:
			if multi {
				strings.write_string(&sb, "[")
				for ri in f.first_ring ..< f.first_ring + f.ring_count {
					if ri > f.first_ring {
						strings.write_string(&sb, ",")
					}
					r := m.rings[ri]
					lon, lat := world_to_lonlat(m.pts[r.first])
					strings.write_string(&sb, "[")
					write_coord(&sb, lon)
					strings.write_string(&sb, ",")
					write_coord(&sb, lat)
					strings.write_string(&sb, "]")
				}
				strings.write_string(&sb, "]")
			} else {
				r := m.rings[f.first_ring]
				lon, lat := world_to_lonlat(m.pts[r.first])
				strings.write_string(&sb, "[")
				write_coord(&sb, lon)
				strings.write_string(&sb, ",")
				write_coord(&sb, lat)
				strings.write_string(&sb, "]")
			}
		case .Line:
			if multi {
				strings.write_string(&sb, "[")
				for ri in f.first_ring ..< f.first_ring + f.ring_count {
					if ri > f.first_ring {
						strings.write_string(&sb, ",")
					}
					write_ring(&sb, m, m.rings[ri])
				}
				strings.write_string(&sb, "]")
			} else {
				write_ring(&sb, m, m.rings[f.first_ring])
			}
		case .Polygon:
			strings.write_string(&sb, "[")
			for ri in f.first_ring ..< f.first_ring + f.ring_count {
				if ri > f.first_ring {
					strings.write_string(&sb, ",")
				}
				write_ring(&sb, m, m.rings[ri])
			}
			strings.write_string(&sb, "]")
		}
		strings.write_string(&sb, "}}")
	}
	strings.write_string(&sb, "\n]}\n")
	return os.write_entire_file(path, transmute([]u8)strings.to_string(sb)) == nil
}

// write_coord prints a coordinate with seven decimals, which is about a
// centimetre — RFC 7946 section 11.2 asks for no more precision than the data
// has, and seven is what osmium writes.
@(private = "file")
write_coord :: proc(sb: ^strings.Builder, v: f64) {
	neg := v < 0
	a := abs(v)
	// Round at the seventh decimal by hand; %f would print seventeen.
	scaled := u64(a * 1e7 + 0.5)
	whole := scaled / 10_000_000
	frac := scaled % 10_000_000
	if neg && scaled != 0 {
		strings.write_string(sb, "-")
	}
	buf: [24]u8
	strings.write_string(sb, strconv.write_int(buf[:], i64(whole), 10))
	if frac == 0 {
		return
	}
	strings.write_string(sb, ".")
	digits: [7]u8
	d := frac
	for i := 6; i >= 0; i -= 1 {
		digits[i] = u8('0' + d % 10)
		d /= 10
	}
	n := 7
	for n > 1 && digits[n - 1] == '0' {
		n -= 1
	}
	strings.write_bytes(sb, digits[:n])
}

// class_tag is the inverse of `classify` for the classes the generator emits.
class_tag :: proc(c: Class) -> (key, value: string) {
	switch c {
	case .Ocean:
		// Not `natural=water`: that reads back as an ordinary lake, and the
		// sea has to survive a round trip as the sea.
		return "natural", "coastline"
	case .Water:
		return "natural", "water"
	case .Wetland:
		return "natural", "wetland"
	case .Landuse:
		return "landuse", "residential"
	case .Grass:
		return "landuse", "grass"
	case .Park:
		return "leisure", "park"
	case .Forest:
		return "landuse", "forest"
	case .Sand:
		return "natural", "beach"
	case .Pitch:
		return "leisure", "pitch"
	case .Building:
		return "building", "yes"
	case .River:
		return "waterway", "river"
	case .Rail:
		return "railway", "rail"
	case .Path:
		return "highway", "footway"
	case .Service:
		return "highway", "service"
	case .Residential_Road:
		return "highway", "residential"
	case .Tertiary:
		return "highway", "tertiary"
	case .Secondary:
		return "highway", "secondary"
	case .Primary:
		return "highway", "primary"
	case .Trunk:
		return "highway", "trunk"
	case .Motorway:
		return "highway", "motorway"
	case .City:
		return "place", "city"
	case .Town:
		return "place", "town"
	case .Village:
		return "place", "village"
	case .Suburb:
		return "place", "suburb"
	case .Poi:
		return "amenity", "yes"
	case .Unknown:
		return "class", "unknown"
	}
	return "class", "unknown"
}
