// The SQLite FTS5 side of the benchmark: the same documents, the same
// queries, the closest equivalent ranking (bm25 with the same field weights,
// plus the same recency term). Only the benchmark links SQLite; nothing that
// ships does (search.md, "The decision").
package main

import "core:c"
import "core:fmt"
import "core:strings"
import ic "../core"

foreign import sqlite "system:sqlite3"

DB :: distinct rawptr
Stmt :: distinct rawptr

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_TRANSIENT :: ~uintptr(0)

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open :: proc(filename: cstring, db: ^DB) -> c.int ---
	sqlite3_close :: proc(db: DB) -> c.int ---
	sqlite3_exec :: proc(db: DB, sql: cstring, cb: rawptr, arg: rawptr, err: ^cstring) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: DB, sql: cstring, n: c.int, stmt: ^Stmt, tail: ^cstring) -> c.int ---
	sqlite3_bind_text :: proc(s: Stmt, i: c.int, text: [^]u8, n: c.int, destructor: uintptr) -> c.int ---
	sqlite3_bind_int64 :: proc(s: Stmt, i: c.int, v: i64) -> c.int ---
	sqlite3_step :: proc(s: Stmt) -> c.int ---
	sqlite3_reset :: proc(s: Stmt) -> c.int ---
	sqlite3_finalize :: proc(s: Stmt) -> c.int ---
	sqlite3_column_text :: proc(s: Stmt, i: c.int) -> cstring ---
	sqlite3_column_double :: proc(s: Stmt, i: c.int) -> f64 ---
	sqlite3_errmsg :: proc(db: DB) -> cstring ---
	sqlite3_libversion :: proc() -> cstring ---
}

exec :: proc(db: DB, sql: string) {
	err: cstring
	if sqlite3_exec(db, strings.clone_to_cstring(sql, context.temp_allocator), nil, nil, &err) != SQLITE_OK {
		fmt.eprintfln("sqlite: %s: %s", sql, err)
	}
}

bind_str :: proc(s: Stmt, i: int, v: string) {
	sqlite3_bind_text(s, c.int(i), raw_data(v), c.int(len(v)), SQLITE_TRANSIENT)
}

fts_open :: proc(path: string) -> DB {
	db: DB
	sqlite3_open(strings.clone_to_cstring(path, context.temp_allocator), &db)
	exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
	return db
}

fts_schema :: proc(db: DB) {
	// Indexed columns first (title, who, body), then the stored ones. The
	// prefix indexes are what make as-you-type usable at all in FTS5;
	// remove_diacritics 2 matches our folding.
	exec(db, `CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
		title, who, body, key UNINDEXED, kind UNINDEXED, flags UNINDEXED, time UNINDEXED,
		detail UNINDEXED, uri UNINDEXED, app UNINDEXED,
		tokenize = "unicode61 remove_diacritics 2", prefix = '2 3')`)
}

fts_insert_stmt :: proc(db: DB) -> Stmt {
	st: Stmt
	sqlite3_prepare_v2(db, "INSERT INTO docs(title, who, body, key, kind, flags, time, detail, uri, app) VALUES(?,?,?,?,?,?,?,?,?,?)", -1, &st, nil)
	return st
}

fts_insert :: proc(st: Stmt, d: ic.Doc) {
	bind_str(st, 1, d.title)
	bind_str(st, 2, d.who)
	bind_str(st, 3, ic.clip(d.body))
	bind_str(st, 4, d.key)
	sqlite3_bind_int64(st, 5, i64(d.kind))
	sqlite3_bind_int64(st, 6, i64(transmute(u8)d.flags))
	sqlite3_bind_int64(st, 7, d.time)
	bind_str(st, 8, d.detail)
	bind_str(st, 9, d.uri)
	bind_str(st, 10, d.app)
	sqlite3_step(st)
	sqlite3_reset(st)
}

// fts_query translates one of the benchmark's queries into FTS5 MATCH
// syntax plus SQL filters. Returns "" for what FTS5 cannot express (typo
// tolerance), which the benchmark reports separately.
Fq :: struct {
	match:  string,
	where_: string,
}

fts_translate :: proc(q: ^ic.Query) -> (out: Fq, ok: bool) {
	sb := strings.builder_make(context.temp_allocator)
	for t, i in q.terms {
		if i > 0 {
			strings.write_byte(&sb, ' ')
		}
		if t.field == .Who {
			strings.write_string(&sb, "who : ")
		}
		fmt.sbprintf(&sb, "\"%s\"", t.text)
		if t.prefix {
			strings.write_byte(&sb, '*')
		}
	}
	for p in q.phrases {
		strings.write_string(&sb, " \"")
		for w, i in p {
			if i > 0 {
				strings.write_byte(&sb, ' ')
			}
			strings.write_string(&sb, w)
		}
		strings.write_string(&sb, "\"")
	}
	wb := strings.builder_make(context.temp_allocator)
	if q.kinds != {} {
		strings.write_string(&wb, " AND kind IN (")
		first := true
		for k in q.kinds {
			if !first {
				strings.write_byte(&wb, ',')
			}
			first = false
			fmt.sbprintf(&wb, "%d", int(k))
		}
		strings.write_string(&wb, ")")
	}
	if .Unread in q.want {
		strings.write_string(&wb, " AND (flags & 1) != 0")
	}
	if q.after != 0 {
		fmt.sbprintf(&wb, " AND time >= %d", q.after)
	}
	return Fq{strings.to_string(sb), strings.to_string(wb)}, true
}

fts_search :: proc(db: DB, fq: Fq, now: i64, limit: int) -> int {
	sql: string
	if fq.match == "" {
		sql = fmt.tprintf("SELECT key, title, '' FROM docs WHERE 1%s ORDER BY time DESC LIMIT %d", fq.where_, limit)
	} else {
		sql = fmt.tprintf(
			"SELECT key, title, snippet(docs, 2, '[', ']', '…', 16) FROM docs WHERE docs MATCH ?1%s " +
			"ORDER BY bm25(docs, 3.0, 2.0, 1.0) - 1.6 * pow(0.5, abs(%d - time) / 86400.0 / 30.0) LIMIT %d",
			fq.where_, now, limit,
		)
	}
	st: Stmt
	if sqlite3_prepare_v2(db, strings.clone_to_cstring(sql, context.temp_allocator), -1, &st, nil) != SQLITE_OK {
		fmt.eprintfln("fts5: %s: %s", sql, sqlite3_errmsg(db))
		return -1
	}
	defer sqlite3_finalize(st)
	if fq.match != "" {
		bind_str(st, 1, fq.match)
	}
	n := 0
	for sqlite3_step(st) == SQLITE_ROW {
		_ = sqlite3_column_text(st, 2)
		n += 1
	}
	return n
}
