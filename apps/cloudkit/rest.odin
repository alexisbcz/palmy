package cloudkit

// PostgREST: tables and functions in the `public` schema. Every call carries
// the session's token, so RLS sees the caller and its scope; nothing here
// filters by identity, and nothing needs to.
//
//	rows, e := cloudkit.select(c, "profiles", "select=bio,locale&identity_id=eq." + id)
//	row,  e := cloudkit.insert(c, "notes", `{"identity_id":"...","title":"x"}`)
//	rows, e := cloudkit.update(c, "profiles", "identity_id=eq." + id, `{"bio":"hi"}`)
//	n,    e := cloudkit.delete_rows(c, "notes", "id=eq." + note)
//	out,  e := cloudkit.rpc(c, "whoami")
//
// Query strings use PostgREST's own syntax (https://postgrest.org); values in
// them should go through `escape`.

import "core:fmt"
import "core:strings"

// select reads rows. `query` is everything after the `?`.
select :: proc(c: ^Client, table: string, query := "select=*", allocator := context.allocator) -> (rows: Value, e: Error) {
	return call(c, "GET", rest_path(table, query), "", allocator = allocator)
}

// insert writes one object or an array of them and returns what was stored.
insert :: proc(c: ^Client, table: string, body: string, allocator := context.allocator) -> (rows: Value, e: Error) {
	return call(c, "POST", rest_path(table, ""), body, extra = PREFER_REPRESENTATION, allocator = allocator)
}

// upsert is insert that updates on a primary-key (or `on_conflict`) clash.
upsert :: proc(c: ^Client, table: string, body: string, on_conflict := "", allocator := context.allocator) -> (rows: Value, e: Error) {
	q := on_conflict != "" ? fmt.tprintf("on_conflict=%s", on_conflict) : ""
	return call(c, "POST", rest_path(table, q), body, extra = PREFER_UPSERT, allocator = allocator)
}

// update changes the rows `filter` matches and returns them. A row the
// session may not see is simply not matched: an update outside the scope
// comes back as an empty array, not an error, which is exactly what RLS does.
update :: proc(c: ^Client, table: string, filter: string, body: string, allocator := context.allocator) -> (rows: Value, e: Error) {
	if filter == "" {
		return nil, Error{kind = .Invalid, message = strings.clone("update without a filter is refused")}
	}
	return call(c, "PATCH", rest_path(table, filter), body, extra = PREFER_REPRESENTATION, allocator = allocator)
}

// delete_rows removes the rows `filter` matches and returns how many went.
delete_rows :: proc(c: ^Client, table: string, filter: string) -> (n: int, e: Error) {
	if filter == "" {
		return 0, Error{kind = .Invalid, message = strings.clone("delete without a filter is refused")}
	}
	v: Value
	v, e = call(c, "DELETE", rest_path(table, filter), "", extra = PREFER_REPRESENTATION)
	defer value_destroy(v)
	return len(array(v)), e
}

// rpc calls a database function with named arguments as a JSON object.
rpc :: proc(c: ^Client, function: string, args := "{}", allocator := context.allocator) -> (result: Value, e: Error) {
	return call(c, "POST", fmt.tprintf("/rest/v1/rpc/%s", function), args, allocator = allocator)
}

@(private)
PREFER_REPRESENTATION := []Header{{"Prefer", "return=representation"}}
@(private)
PREFER_UPSERT := []Header{{"Prefer", "return=representation,resolution=merge-duplicates"}}

@(private)
rest_path :: proc(table, query: string) -> string {
	if query == "" {
		return fmt.tprintf("/rest/v1/%s", table)
	}
	return fmt.tprintf("/rest/v1/%s?%s", table, query)
}

// escape percent-encodes a value for a query string or a path segment.
// `keep_slash` leaves `/` alone, for Storage object names.
escape :: proc(s: string, keep_slash := false, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		unreserved :=
			(ch >= 'a' && ch <= 'z') ||
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '-' || ch == '.' || ch == '_' || ch == '~' ||
			(keep_slash && ch == '/')
		if unreserved {
			strings.write_byte(&b, ch)
		} else {
			fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}
