package engine

// Retrieval by meaning: the identity's own search index, embedded.
//
// The search index (apps/index, cloud/docs/search.md) finds words. A person
// asks for "the bill from the Norwegian supplier" and the mail says "Halden
// invoice"; no word is shared and the keyword search finds nothing. recall
// embeds every document of the identity's index with a local embedding
// model, keeps the vectors in the assistant's own state directory, and ranks
// the documents by cosine similarity to the query's vector.
//
// Where it runs, and what that means for the scope:
//
//   - The documents come from one identity's index, opened by handle from
//     the index root. Inside the sandbox that is the only index Landlock lets
//     the process read (sandbox.odin: own index read-only, the others not at
//     all); outside it, `ai recall` opens the index of the identity it was
//     given and no other.
//   - The vectors are cached in that identity's assistant state directory,
//     the one directory the sandbox lets the assistant write, keyed by the
//     document's key and the index's own source signature, so a changed
//     mail or file is embedded again and a deleted one drops out.
//   - The model is reached through the IO's `embed`, which the person's
//     process brokers (protocol.odin): the sandbox needs no route to ollama,
//     exactly as for the chat model. Embeddings are always local: an
//     identity that opted into a remote chat model still has its documents
//     embedded by ollama on this machine.
//
// The default model is nomic-embed-text (137M parameters, 768 dimensions;
// `ollama pull nomic-embed-text`). A generative model such as qwen3:0.6b
// cannot embed — ollama answers "does not support embeddings" — which is
// what TODO.md recorded before an embedding model was pulled.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import ck "../../../apps/cloudkit"
import ic "../../../apps/index/core"

EMBED_MODEL_DEFAULT :: "nomic-embed-text"

// What a document contributes to its vector: enough to say what it is
// about, small enough that a model with a 2048-token window takes it whole.
@(private)
DOC_TEXT_MAX :: 1500
@(private)
EMBED_BATCH :: 16
@(private)
RECALL_DOCS_MAX :: 20000

// Purpose tells the embedder whether a text is a document or a query. Some
// models (nomic-embed-text) are trained with a different prefix for each;
// the embedder knows its model and adds the right one.
Embed_Purpose :: enum u8 {
	Document,
	Query,
}

Embed_Reply :: struct {
	vectors: [][]f32,
	model:   string,
	err:     string,
	ms:      i64,
}

Embedder :: proc(data: rawptr, texts: []string, purpose: Embed_Purpose) -> Embed_Reply

Recall_Hit :: struct {
	key, kind, title, who, detail, uri, app, snippet: string,
	time:                                           i64,
	score:                                          f32,
}

Recall_Stats :: struct {
	docs:     int, // live documents in the index
	embedded: int, // embedded on this call
	cached:   int, // taken from the cache
	model:    string,
	ms:       i64,
}

// ---------------------------------------------------------------------------
// The cache: <dir>/vectors
//
//	"PRV1" u32 model-length model
//	repeated: u32 key-length key, u64 signature, u32 dimension, f32 × dimension
//
// Little-endian, rewritten whole after a call that embedded anything.
// ---------------------------------------------------------------------------

@(private)
Cached :: struct {
	sig: u64,
	vec: []f32,
}

@(private)
CACHE_MAGIC :: "PRV1"

@(private)
cache_load :: proc(path: string, allocator := context.allocator) -> (model: string, m: map[string]Cached) {
	m = make(map[string]Cached, allocator = allocator)
	data, err := os.read_entire_file_from_path(path, allocator)
	if err != nil || len(data) < 8 || string(data[:4]) != CACHE_MAGIC {return "", m}
	at := 4
	u32_at :: proc(d: []u8, at: ^int) -> (v: u32, ok: bool) {
		if at^ + 4 > len(d) {return 0, false}
		v = u32(d[at^]) | u32(d[at^ + 1]) << 8 | u32(d[at^ + 2]) << 16 | u32(d[at^ + 3]) << 24
		at^ += 4
		return v, true
	}
	n, _ := u32_at(data, &at)
	if at + int(n) > len(data) {return "", m}
	model = string(data[at:][:n])
	at += int(n)
	for at < len(data) {
		kl, ok1 := u32_at(data, &at)
		if !ok1 || at + int(kl) + 12 > len(data) {break}
		key := string(data[at:][:kl])
		at += int(kl)
		lo, _ := u32_at(data, &at)
		hi, _ := u32_at(data, &at)
		dim, _ := u32_at(data, &at)
		if at + int(dim) * 4 > len(data) {break}
		vec := make([]f32, int(dim), allocator) // copied: the file's floats need not be aligned
		copy(slice.to_bytes(vec), data[at:][:int(dim) * 4])
		at += int(dim) * 4
		m[key] = Cached{sig = u64(lo) | u64(hi) << 32, vec = vec}
	}
	return model, m
}

@(private)
cache_save :: proc(path, model: string, m: map[string]Cached) -> bool {
	b := make([dynamic]u8, context.temp_allocator)
	put32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	append(&b, ..transmute([]u8)string(CACHE_MAGIC))
	put32(&b, u32(len(model)))
	append(&b, ..transmute([]u8)model)
	for key, c in m {
		put32(&b, u32(len(key)))
		append(&b, ..transmute([]u8)key)
		put32(&b, u32(c.sig))
		put32(&b, u32(c.sig >> 32))
		put32(&b, u32(len(c.vec)))
		append(&b, ..slice.to_bytes(c.vec))
	}
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, b[:], os.perm_number(0o600)) != nil {return false}
	return os.rename(tmp, path) == nil
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

cosine :: proc(a, b: []f32) -> f32 {
	if len(a) != len(b) || len(a) == 0 {return 0}
	dot, na, nb: f32
	for i in 0 ..< len(a) {
		dot += a[i] * b[i]
		na += a[i] * a[i]
		nb += b[i] * b[i]
	}
	if na == 0 || nb == 0 {return 0}
	return dot / (math.sqrt(na) * math.sqrt(nb))
}

@(private)
Doc_Ref :: struct {
	key, kind, title, who, detail, uri, app, body: string,
	sig:                                           u64,
	time:                                          i64,
}

@(private)
doc_text :: proc(d: Doc_Ref) -> string {
	body := d.body
	if len(body) > DOC_TEXT_MAX {
		cut := DOC_TEXT_MAX
		for cut > 0 && body[cut] & 0xc0 == 0x80 {cut -= 1}
		body = body[:cut]
	}
	return fmt.tprintf("%s: %s\n%s\n%s\n%s", d.kind, d.title, d.who, d.detail, body)
}

@(private)
snippet_of :: proc(body: string, allocator := context.allocator) -> string {
	flat := strings.join(strings.fields(body, context.temp_allocator), " ", context.temp_allocator)
	if len(flat) <= 200 {return strings.clone(flat, allocator)}
	cut := 200
	for cut > 0 && flat[cut] & 0xc0 == 0x80 {cut -= 1}
	return fmt.aprintf("%s…", flat[:cut], allocator = allocator)
}

// recall ranks the documents of `handle`'s index under `root` by meaning.
// `cache_dir` is where this identity's vectors live (created if missing).
// Nothing but that one index is opened.
recall :: proc(
	root, handle, cache_dir, query: string,
	k: int,
	embed: Embedder,
	data: rawptr,
	allocator := context.allocator,
) -> (
	hits: []Recall_Hit,
	stats: Recall_Stats,
	err: string,
) {
	start := time.tick_now()
	defer stats.ms = i64(time.duration_milliseconds(time.tick_since(start)))
	if embed == nil {return nil, stats, "no embedding model is reachable from here"}
	if strings.trim_space(query) == "" {return nil, stats, "nothing to recall"}
	// An index that was never built is not an empty one: say so, rather
	// than answer "nothing found" for an identity nothing was looked in.
	if !ic.handle_ok(handle) || !os.is_dir(ic.identity_dir(root, handle, context.temp_allocator)) {
		return nil, stats, fmt.aprintf("no search index for %s (the index daemon builds it: `index rebuild --identity %s`)", handle, handle, allocator = allocator)
	}
	ix, ok := ic.index_open(root, handle)
	if !ok {return nil, stats, fmt.aprintf("no search index for %s", handle, allocator = allocator)}
	defer ic.index_close(ix)

	docs := make([dynamic]Doc_Ref, context.temp_allocator)
	for s in ix.segs {
		for d in 0 ..< len(s.docs) {
			if s.dead[d] {continue}
			st := ic.doc_stored(s, d)
			r := s.docs[d]
			append(&docs, Doc_Ref{key = st.key, kind = ic.KIND_NAME[r.kind], title = st.title, who = st.who, detail = st.detail, uri = st.uri, app = st.app, body = st.body, sig = r.sig, time = r.time})
			if len(docs) >= RECALL_DOCS_MAX {break}
		}
	}
	stats.docs = len(docs)
	if len(docs) == 0 {return nil, stats, ""}

	qr := embed(data, {query}, .Query)
	if qr.err != "" || len(qr.vectors) != 1 {
		e := qr.err != "" ? qr.err : "the embedding model returned nothing"
		return nil, stats, strings.clone(e, allocator)
	}
	qv := qr.vectors[0]
	stats.model = strings.clone(qr.model, allocator)

	os.make_directory_all(cache_dir, os.perm_number(0o700))
	path := fmt.tprintf("%s/vectors", cache_dir)
	cmodel, cache := cache_load(path, context.temp_allocator)
	if cmodel != qr.model {clear(&cache)}

	fresh := make(map[string]Cached, allocator = context.temp_allocator)
	todo := make([dynamic]int, context.temp_allocator)
	for d, i in docs {
		if c, found := cache[d.key]; found && c.sig == d.sig && len(c.vec) == len(qv) {
			fresh[d.key] = c
			stats.cached += 1
		} else {
			append(&todo, i)
		}
	}
	for lo := 0; lo < len(todo); lo += EMBED_BATCH {
		hi := min(lo + EMBED_BATCH, len(todo))
		texts := make([]string, hi - lo, context.temp_allocator)
		for j in lo ..< hi {texts[j - lo] = doc_text(docs[todo[j]])}
		r := embed(data, texts, .Document)
		if r.err != "" || len(r.vectors) != len(texts) {
			e := r.err != "" ? r.err : "the embedding model returned the wrong number of vectors"
			return nil, stats, strings.clone(e, allocator)
		}
		for j in lo ..< hi {
			fresh[docs[todo[j]].key] = Cached{sig = docs[todo[j]].sig, vec = r.vectors[j - lo]}
		}
		stats.embedded += hi - lo
	}
	// Rewritten when anything changed: something embedded, or something gone.
	if stats.embedded > 0 || len(fresh) != len(cache) {
		cache_save(path, qr.model, fresh)
	}

	Scored :: struct {
		i: int,
		s: f32,
	}
	scored := make([dynamic]Scored, context.temp_allocator)
	for d, i in docs {
		append(&scored, Scored{i, cosine(qv, fresh[d.key].vec)})
	}
	slice.sort_by(scored[:], proc(x, y: Scored) -> bool {return x.s > y.s})
	n := min(max(k, 1), len(scored))
	out := make([]Recall_Hit, n, allocator)
	for j in 0 ..< n {
		d := docs[scored[j].i]
		out[j] = Recall_Hit {
			key     = strings.clone(d.key, allocator),
			kind    = strings.clone(d.kind, allocator),
			title   = strings.clone(d.title, allocator),
			who     = strings.clone(d.who, allocator),
			detail  = strings.clone(d.detail, allocator),
			uri     = strings.clone(d.uri, allocator),
			app     = strings.clone(d.app, allocator),
			snippet = snippet_of(d.body, allocator),
			time    = d.time,
			score   = scored[j].s,
		}
	}
	return out, stats, ""
}

// ---------------------------------------------------------------------------
// In the loop: index_search finds by words and by meaning
//
// The model is offered no new tool — the menu's order was measured on
// qwen3:0.6b and a new entry moves its choices (agent.odin, MENU) — so
// retrieval rides on the general search it already has. When the IO can
// embed, index_search's keyword results are fused with the identity's
// documents ranked by meaning (reciprocal rank fusion, k = 60), and each
// result says how it was found: "words", "meaning" or "both". When the IO
// cannot embed, or the embedding model is missing, the keyword results
// stand alone and the step's summary says why.
// ---------------------------------------------------------------------------

RECALL_K :: 5
@(private)
RRF_K :: 60

@(private)
io_embed :: proc(data: rawptr, texts: []string, purpose: Embed_Purpose) -> Embed_Reply {
	io := cast(^IO)data
	return io.embed(data, texts, purpose)
}

// recall_merge returns the fused run and a phrase for the step's summary.
recall_merge :: proc(a: ^Agent, r: Run, query: string) -> (out: Run, note: string) {
	out = r
	if a.io.embed == nil || !r.ok {return}
	state := os.get_env("PALM_ASSISTANT_STATE", context.temp_allocator)
	if state == "" {return out, "by words only (no state directory for the vectors)"}
	sem, stats, err := recall(ic.index_root(context.temp_allocator), a.req.identity.handle, fmt.tprintf("%s/recall", state), query, RECALL_K, io_embed, a.io, context.temp_allocator)
	if err != "" {return out, fmt.tprintf("by words only: %s", err)}

	Fused :: struct {
		v:     ck.Value,
		score: f64,
		words: bool,
		sense: bool,
	}
	fused := make([dynamic]Fused, context.temp_allocator)
	at := make(map[string]int, allocator = context.temp_allocator)
	for item, i in ck.array(ck.get(r.value, "results")) {
		key := ck.get_str(item, "key")
		at[key] = len(fused)
		append(&fused, Fused{v = item, score = 1.0 / f64(RRF_K + i + 1), words = true})
	}
	for h, i in sem {
		if j, found := at[h.key]; found {
			fused[j].score += 1.0 / f64(RRF_K + i + 1)
			fused[j].sense = true
			continue
		}
		o := ck.obj(context.temp_allocator)
		ck.put(&o, "identity", a.req.identity.handle)
		ck.put(&o, "kind", h.kind)
		ck.put(&o, "title", h.title)
		ck.put(&o, "who", h.who)
		ck.put(&o, "detail", h.detail)
		ck.put(&o, "snippet", h.snippet)
		ck.put(&o, "date", date_text(int(h.time / 86400)))
		ck.put(&o, "key", h.key)
		ck.put(&o, "uri", h.uri)
		ck.put(&o, "app", h.app)
		ck.put_raw(&o, "similarity", fmt.tprintf("%.3f", h.score))
		v, _ := ck.parse(ck.obj_done(&o), context.temp_allocator)
		at[h.key] = len(fused)
		append(&fused, Fused{v = v, score = 1.0 / f64(RRF_K + i + 1), sense = true})
	}
	slice.stable_sort_by(fused[:], proc(x, y: Fused) -> bool {return x.score > y.score})

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	by_meaning := 0
	n := 0
	top := "" // the best result that meaning found, for the step's summary
	for f in fused {
		how := f.words && f.sense ? "both" : (f.words ? "words" : "meaning")
		raw := raw_json(f.v, context.temp_allocator)
		// Every result is a non-empty object; the field goes in before its
		// closing brace.
		if len(raw) < 3 || raw[len(raw) - 1] != '}' {continue}
		if f.sense {
			by_meaning += 1
			if top == "" {top = ck.get_str(f.v, "title")}
		}
		if n > 0 {strings.write_byte(&b, ',')}
		n += 1
		fmt.sbprintf(&b, "%s,\"how\":%s}}", raw[:len(raw) - 1], ck.quote(how))
	}
	strings.write_string(&b, "]")
	o := ck.obj(context.temp_allocator)
	ck.put(&o, "query", ck.get_str(r.value, "query"))
	ck.put_raw(&o, "results", strings.to_string(b))
	ck.put(&o, "count", i64(n))
	ck.put(&o, "by_meaning", i64(by_meaning))
	ck.put(&o, "embedding_model", stats.model)
	ck.put(&o, "embedded", i64(stats.embedded))
	doc := ck.obj_done(&o)
	v, ok := ck.parse(doc, context.temp_allocator)
	if !ok {return out, "by words only: the fused results did not parse"}
	out.value = v
	out.stdout = doc
	if top != "" {return out, fmt.tprintf("%d by meaning (%s), nearest “%s”", by_meaning, stats.model, short(top, 60))}
	return out, fmt.tprintf("%d by meaning (%s)", by_meaning, stats.model)
}
