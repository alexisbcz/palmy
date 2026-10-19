package main

// A small libpq binding: connect, run a parameterised statement, read text
// results, and receive LISTEN notifications. Everything the gateway asks of
// Postgres is text in and text out; the JSON is shaped by SQL functions
// (migrations/20261019700100_rtc_wire.sql) and spliced into frames as is.

import "core:c"
import "core:strings"

foreign import pq "system:pq"

PGconn :: struct {}
PGresult :: struct {}

PGnotify :: struct {
	relname: cstring,
	be_pid:  c.int,
	extra:   cstring,
	next:    ^PGnotify,
}

CONNECTION_OK :: 0
PGRES_COMMAND_OK :: 1
PGRES_TUPLES_OK :: 2

PG_DIAG_SQLSTATE :: 'C'
PG_DIAG_MESSAGE_PRIMARY :: 'M'

@(default_calling_convention = "c")
foreign pq {
	PQconnectdb :: proc(conninfo: cstring) -> ^PGconn ---
	PQstatus :: proc(conn: ^PGconn) -> c.int ---
	PQerrorMessage :: proc(conn: ^PGconn) -> cstring ---
	PQfinish :: proc(conn: ^PGconn) ---
	PQreset :: proc(conn: ^PGconn) ---
	PQexec :: proc(conn: ^PGconn, query: cstring) -> ^PGresult ---
	PQexecParams :: proc(conn: ^PGconn, command: cstring, nParams: c.int, paramTypes: [^]u32, paramValues: [^]cstring, paramLengths: [^]c.int, paramFormats: [^]c.int, resultFormat: c.int) -> ^PGresult ---
	PQresultStatus :: proc(res: ^PGresult) -> c.int ---
	PQresultErrorField :: proc(res: ^PGresult, fieldcode: c.int) -> cstring ---
	PQntuples :: proc(res: ^PGresult) -> c.int ---
	PQnfields :: proc(res: ^PGresult) -> c.int ---
	PQgetvalue :: proc(res: ^PGresult, row, col: c.int) -> cstring ---
	PQgetisnull :: proc(res: ^PGresult, row, col: c.int) -> c.int ---
	PQclear :: proc(res: ^PGresult) ---
	PQsocket :: proc(conn: ^PGconn) -> c.int ---
	PQconsumeInput :: proc(conn: ^PGconn) -> c.int ---
	PQnotifies :: proc(conn: ^PGconn) -> ^PGnotify ---
	PQfreemem :: proc(ptr: rawptr) ---
}

Db :: struct {
	conn: ^PGconn,
	url:  string,
}

// Result holds a statement's outcome with every value copied out of libpq
// into the temp allocator, so nothing has to be freed by the caller. A NULL
// is an empty string; SQL here is written so that never matters.
Result :: struct {
	ok:   bool,
	rows: [][]string,
	code: string, // SQLSTATE on failure
	msg:  string,
}

db_open :: proc(url: string) -> (db: Db, err: string) {
	db.url = url
	db.conn = PQconnectdb(strings.clone_to_cstring(url, context.temp_allocator))
	if db.conn == nil || PQstatus(db.conn) != CONNECTION_OK {
		err = db.conn != nil ? strings.clone(string(PQerrorMessage(db.conn))) : "out of memory"
		return
	}
	return
}

db_alive :: proc(db: ^Db) -> bool {
	return db.conn != nil && PQstatus(db.conn) == CONNECTION_OK
}

// db_q runs one statement with text parameters ($1, $2, …).
db_q :: proc(db: ^Db, sql: string, params: ..string) -> (r: Result) {
	if !db_alive(db) {
		PQreset(db.conn)
		if !db_alive(db) {
			r.code, r.msg = "08006", "the database connection is down"
			return
		}
	}
	vals := make([]cstring, len(params), context.temp_allocator)
	for p, i in params {
		vals[i] = strings.clone_to_cstring(p, context.temp_allocator)
	}
	res := PQexecParams(
		db.conn,
		strings.clone_to_cstring(sql, context.temp_allocator),
		c.int(len(params)),
		nil,
		len(vals) > 0 ? raw_data(vals) : nil,
		nil,
		nil,
		0,
	)
	defer PQclear(res)
	st := PQresultStatus(res)
	if st != PGRES_COMMAND_OK && st != PGRES_TUPLES_OK {
		r.code = strings.clone(string(PQresultErrorField(res, PG_DIAG_SQLSTATE)), context.temp_allocator)
		r.msg = strings.clone(string(PQresultErrorField(res, PG_DIAG_MESSAGE_PRIMARY)), context.temp_allocator)
		if r.msg == "" {
			r.msg = strings.clone(string(PQerrorMessage(db.conn)), context.temp_allocator)
		}
		return
	}
	n, nf := int(PQntuples(res)), int(PQnfields(res))
	r.rows = make([][]string, n, context.temp_allocator)
	for i in 0 ..< n {
		row := make([]string, nf, context.temp_allocator)
		for j in 0 ..< nf {
			if PQgetisnull(res, c.int(i), c.int(j)) == 0 {
				row[j] = strings.clone(string(PQgetvalue(res, c.int(i), c.int(j))), context.temp_allocator)
			}
		}
		r.rows[i] = row
	}
	r.ok = true
	return
}

// one returns the first column of the first row, or "".
one :: proc(r: Result) -> string {
	if !r.ok || len(r.rows) == 0 || len(r.rows[0]) == 0 {
		return ""
	}
	return r.rows[0][0]
}

db_simple :: proc(db: ^Db, sql: string) -> bool {
	res := PQexec(db.conn, strings.clone_to_cstring(sql, context.temp_allocator))
	defer PQclear(res)
	st := PQresultStatus(res)
	return st == PGRES_COMMAND_OK || st == PGRES_TUPLES_OK
}
