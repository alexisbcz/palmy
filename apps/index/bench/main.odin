// index-bench: the evidence for search.md's decision between a hand-written
// index and SQLite FTS5.
//
//	odin build apps/index/bench -o:speed -out:/tmp/index-bench
//	/tmp/index-bench --dir /tmp/ib [--mails 100000] [--files 20000] [--no-fts]
//
// Builds both indexes over the same deterministic corpus, then reports index
// size, build time, query latency (p50/p99 per query class, warm and cold)
// and the cost of incremental updates.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import ic "../core"

cpu_ms :: proc() -> f64 {
	ts, _ := linux.clock_gettime(.PROCESS_CPUTIME_ID)
	return f64(ts.time_sec) * 1000 + f64(ts.time_nsec) / 1e6
}

ms :: proc(d: time.Duration) -> f64 {
	return time.duration_milliseconds(d)
}

dir_size :: proc(path: string) -> i64 {
	n: i64
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return 0
	}
	for e in entries {
		if e.type == .Directory {
			n += dir_size(e.fullpath)
		} else {
			n += e.size
		}
	}
	return n
}

Qcase :: struct {
	class:  string,
	text:   string,
	typing: bool,
}

percentile :: proc(xs: []f64, p: f64) -> f64 {
	if len(xs) == 0 {
		return 0
	}
	s := slice.clone(xs, context.temp_allocator)
	slice.sort(s)
	i := int(p * f64(len(s) - 1) + 0.5)
	return s[min(i, len(s) - 1)]
}

make_queries :: proc(c: ^Corpus) -> [dynamic]Qcase {
	out := make([dynamic]Qcase)
	v := c.vocab[:]
	// Words by frequency band.
	for i in 0 ..< 10 {
		append(&out, Qcase{"common word", v[20 + i * 7], false})
		append(&out, Qcase{"mid word", v[1000 + i * 311], false})
		append(&out, Qcase{"rare word", v[20000 + i * 2011], false})
		append(&out, Qcase{"two words", fmt.aprintf("%s %s", v[150 + i * 13], v[700 + i * 97]), false})
		append(&out, Qcase{"name", strings.to_lower(c.people[i * 3]), false}) // heap: run_mine frees temp per query
		append(&out, Qcase{"filtered", fmt.aprintf("%s type:mail is:unread", v[300 + i * 41]), false})
		append(&out, Qcase{"from:", fmt.aprintf("from:%s %s", strings.to_lower(strings.split(c.people[i], " ", context.temp_allocator)[0]), v[60 + i * 9]), false})
		// A remembered phrase: two adjacent words lifted from a real body.
		{
			body := make_mail(c, 777 * (i + 1)).body
			ws := strings.fields(body, context.temp_allocator)
			k := len(ws) / 2
			if len(ws) > 3 {
				a := strings.trim(ws[k], ".,")
				b := strings.trim(ws[k + 1], ".,")
				append(&out, Qcase{"phrase", fmt.aprintf("\"%s %s\"", a, b), false})
			}
			// And the worst case: two of the commonest words.
			append(&out, Qcase{"phrase stop", fmt.aprintf("\"%s %s\"", v[i], v[i + 1]), false})
		}
		// A typo: two letters swapped in a mid-frequency word.
		w := v[500 + i * 173]
		if len(w) >= 5 {
			b := transmute([]u8)strings.clone(w)
			b[2], b[3] = b[3], b[2]
			append(&out, Qcase{"typo", string(b), false})
		}
	}
	// As-you-type: every prefix of a few words, the way they are typed.
	for i in 0 ..< 8 {
		w := v[200 + i * 157]
		pre := ""
		if i % 2 == 1 {
			pre = fmt.aprintf("%s ", v[40 + i])
		}
		for n in 1 ..= len(w) {
			append(&out, Qcase{"as-you-type", fmt.aprintf("%s%s", pre, w[:n]), true})
		}
	}
	return out
}

main :: proc() {
	args := os.args[1:]
	dir := "/tmp/index-bench"
	mails, files := 100_000, 20_000
	fts := true
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--dir":
			i += 1
			dir = args[i]
		case "--mails":
			i += 1
			mails, _ = strconv.parse_int(args[i])
		case "--files":
			i += 1
			files, _ = strconv.parse_int(args[i])
		case "--no-fts":
			fts = false
		}
	}
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--query" {
			// Profile one query against an index a previous run left.
			root := fmt.aprintf("%s/mine", dir)
			ix, _ := ic.index_open(root, "bench")
			for rep in 0 ..< 4 {
				p: ic.Prof
				ic.profile = &p
				t := time.tick_now()
				q := ic.parse_query(args[i + 1], 1792396800, true)
				out := make([dynamic]ic.Result, context.temp_allocator)
				st: ic.Stats
				ic.search_all({{ident = {handle = "bench"}, ix = ix}}, &q, {limit = 20, per_kind = 8, typing = true, now = 1792396800, snippets = true}, &out, &st)
				fmt.printfln("%.2f ms: expand %.2f postings %.2f filter %.2f verify %.2f (%d checked) final %.2f; matched %d, %d results",
					ms(time.tick_since(t)), ms(p.expand), ms(p.postings), ms(p.filter), ms(p.verify), p.checked, ms(p.final), st.matched, len(out))
			}
			os.exit(0)
		}
	}
	notes, events, people := mails / 30, mails / 40, mails / 100
	os.remove_all(dir)
	os.make_directory_all(dir, os.perm_number(0o700))

	now := i64(1792396800) // 2026-10-19 00:00 UTC, fixed so runs agree
	c: Corpus
	corpus_init(&c, 0x5eed_1dea, now)
	t0 := time.tick_now()
	docs := corpus_docs(&c, mails, files, notes, events, people)
	text_bytes := 0
	for d in docs {
		text_bytes += len(d.title) + len(d.who) + len(ic.clip(d.body))
	}
	fmt.printfln("corpus: %d mails, %d files, %d notes, %d events, %d people = %d docs, %.1f MB of text (generated in %.0f ms)",
		mails, files, notes, events, people, len(docs), f64(text_bytes) / 1e6, ms(time.tick_since(t0)))
	queries := make_queries(&c)

	// --- hand-written -------------------------------------------------------
	root := fmt.aprintf("%s/mine", dir)
	t0 = time.tick_now()
	c0 := cpu_ms()
	w, err := ic.writer_open(root, "bench")
	if w == nil {
		fmt.eprintln(err)
		os.exit(1)
	}
	for d in docs {
		ic.writer_put(w, d)
	}
	t_put := time.tick_since(t0)
	ic.writer_flush(w)
	t_build := time.tick_since(t0)
	c_build := cpu_ms() - c0
	size := dir_size(root)
	fmt.printfln("\nhand-written: build %.0f ms wall, %.0f ms CPU (tokenize+invert %.0f ms), size %.1f MB (%.2f× text), %d segments",
		ms(t_build), c_build, ms(t_put), f64(size) / 1e6, f64(size) / f64(text_bytes), len(w.ix.segs))

	run_mine :: proc(root: string, queries: []Qcase, now: i64, label: string) {
		ix, _ := ic.index_open(root, "bench")
		defer ic.index_close(ix)
		targets := []ic.Target{{ident = {handle = "bench"}, ix = ix}}
		lat := make(map[string][dynamic]f64)
		all := make([dynamic]f64)
		hits := make(map[string]int)
		for rep in 0 ..< 3 {
			for qc in queries {
				t := time.tick_now()
				q := ic.parse_query(qc.text, now, qc.typing)
				out := make([dynamic]ic.Result, context.temp_allocator)
				st: ic.Stats
				ic.search_all(targets, &q, {limit = 20, per_kind = 8, typing = qc.typing, now = now, snippets = true}, &out, &st)
				d := ms(time.tick_since(t))
				if rep > 0 {
					if qc.class not_in lat {
						lat[qc.class] = make([dynamic]f64)
					}
					append(&lat[qc.class], d)
					append(&all, d)
					hits[qc.class] += len(out) > 0 ? 1 : 0
				}
				free_all(context.temp_allocator)
			}
		}
		fmt.printfln("  %s query latency (ms), warm, limit 20 + snippets:", label)
		print_lat(lat, all[:], hits)
	}
	ic.writer_close(w)
	run_mine(root, queries[:], now, "hand-written")

	// Cold: what one `index search` invocation pays: open, map, query, close.
	{
		cold := make([dynamic]f64)
		for qc, i in queries {
			if i % 3 != 0 {
				continue
			}
			t := time.tick_now()
			ix, _ := ic.index_open(root, "bench")
			q := ic.parse_query(qc.text, now, qc.typing)
			out := make([dynamic]ic.Result, context.temp_allocator)
			st: ic.Stats
			ic.search_all({{ident = {handle = "bench"}, ix = ix}}, &q, {limit = 20, now = now, snippets = true}, &out, &st)
			ic.index_close(ix)
			append(&cold, ms(time.tick_since(t)))
		}
		fmt.printfln("  hand-written cold (open+map+query+close): p50 %.2f  p99 %.2f ms", percentile(cold[:], 0.5), percentile(cold[:], 0.99))
	}

	// Incremental.
	{
		w2, _ := ic.writer_open(root, "bench")
		t := time.tick_now()
		d := make_mail(&c, mails + 1)
		ic.writer_put(w2, d)
		ic.writer_flush(w2)
		one := ms(time.tick_since(t))
		t = time.tick_now()
		for i in 0 ..< 100 {
			m := make_mail(&c, i * 997 % mails)
			m.flags = {} // marked read: the common update
			ic.writer_put(w2, m)
		}
		ic.writer_flush(w2)
		hundred := ms(time.tick_since(t))
		t = time.tick_now()
		ic.writer_remove(w2, "mail:00000007")
		ic.writer_flush(w2)
		rm := ms(time.tick_since(t))
		for i in 0 ..< 8 {
			ic.writer_put(w2, make_mail(&c, mails + 10 + i))
			ic.writer_flush(w2)
		}
		segs := len(w2.ix.segs)
		t = time.tick_now()
		merged := ic.writer_merge(w2)
		mt := ms(time.tick_since(t))
		fmt.printfln("  hand-written incremental: add 1 mail + flush %.2f ms; update 100 + flush %.1f ms; remove 1 + flush %.2f ms; tiered merge of %d small segments %.1f ms (merged=%v)",
			one, hundred, rm, segs, mt, merged)
		t = time.tick_now()
		ic.writer_compact(w2)
		fmt.printfln("  hand-written compaction to %d segments %.0f ms", len(w2.ix.segs), ms(time.tick_since(t)))
		ic.writer_close(w2)
	}

	if !fts {
		return
	}
	// --- SQLite FTS5 --------------------------------------------------------
	fmt.printfln("\nSQLite %s FTS5:", sqlite3_libversion())
	path := fmt.aprintf("%s/fts5.db", dir)
	t0 = time.tick_now()
	c0 = cpu_ms()
	db := fts_open(path)
	fts_schema(db)
	exec(db, "BEGIN")
	st := fts_insert_stmt(db)
	for d in docs {
		fts_insert(st, d)
	}
	sqlite3_finalize(st)
	exec(db, "COMMIT")
	t_ins := time.tick_since(t0)
	exec(db, "INSERT INTO docs(docs) VALUES('optimize')")
	exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
	t_fb := time.tick_since(t0)
	fmt.printfln("  build CPU %.0f ms", cpu_ms() - c0)
	fsize := dir_size(dir) - dir_size(root)
	fmt.printfln("  build %.0f ms (inserts %.0f ms, optimize %.0f ms), size %.1f MB (%.2f× text)",
		ms(t_fb), ms(t_ins), ms(t_fb) - ms(t_ins), f64(fsize) / 1e6, f64(fsize) / f64(text_bytes))
	{
		lat := make(map[string][dynamic]f64)
		all := make([dynamic]f64)
		hits := make(map[string]int)
		for rep in 0 ..< 3 {
			for qc in queries {
				t := time.tick_now()
				q := ic.parse_query(qc.text, now, qc.typing)
				fq, _ := fts_translate(&q)
				n := fts_search(db, fq, now, 20)
				d := ms(time.tick_since(t))
				if rep > 0 {
					if qc.class not_in lat {
						lat[qc.class] = make([dynamic]f64)
					}
					append(&lat[qc.class], d)
					append(&all, d)
					hits[qc.class] += n > 0 ? 1 : 0
				}
			}
		}
		fmt.println("  FTS5 query latency (ms), warm, limit 20 + snippet():")
		print_lat(lat, all[:], hits)
	}
	{
		cold := make([dynamic]f64)
		for qc, i in queries {
			if i % 3 != 0 {
				continue
			}
			t := time.tick_now()
			db2: DB
			sqlite3_open(strings.clone_to_cstring(path, context.temp_allocator), &db2)
			q := ic.parse_query(qc.text, now, qc.typing)
			fq, _ := fts_translate(&q)
			fts_search(db2, fq, now, 20)
			sqlite3_close(db2)
			append(&cold, ms(time.tick_since(t)))
		}
		fmt.printfln("  FTS5 cold (open+query+close): p50 %.2f  p99 %.2f ms", percentile(cold[:], 0.5), percentile(cold[:], 0.99))
	}
	{
		t := time.tick_now()
		ins := fts_insert_stmt(db)
		fts_insert(ins, make_mail(&c, mails + 1))
		sqlite3_finalize(ins)
		one := ms(time.tick_since(t))
		t = time.tick_now()
		exec(db, "BEGIN")
		up: Stmt
		sqlite3_prepare_v2(db, "UPDATE docs SET flags = 0 WHERE key = ?", -1, &up, nil)
		for i in 0 ..< 100 {
			bind_str(up, 1, fmt.tprintf("mail:%08d", i * 997 % mails))
			sqlite3_step(up)
			sqlite3_reset(up)
		}
		sqlite3_finalize(up)
		exec(db, "COMMIT")
		hundred := ms(time.tick_since(t))
		fmt.printfln("  FTS5 incremental: add 1 mail (autocommit) %.2f ms; update 100 (one transaction, key not indexed: a scan each) %.1f ms", one, hundred)
	}
	sqlite3_close(db)
}

print_lat :: proc(lat: map[string][dynamic]f64, all: []f64, hits: map[string]int) {
	classes := []string{"common word", "mid word", "rare word", "two words", "name", "filtered", "from:", "phrase", "phrase stop", "typo", "as-you-type"}
	for cl in classes {
		xs, ok := lat[cl]
		if !ok {
			continue
		}
		fmt.printfln("    %-12s p50 %6.2f  p99 %6.2f  max %6.2f   (%d/%d found something)", cl, percentile(xs[:], 0.5), percentile(xs[:], 0.99), slice.max(xs[:]), hits[cl], len(xs) / 2)
	}
	fmt.printfln("    %-12s p50 %6.2f  p99 %6.2f", "ALL", percentile(all, 0.5), percentile(all, 0.99))
}
