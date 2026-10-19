// The editing-trace benchmark: the automerge-paper trace (259,778 single
// character edits made while writing a LaTeX paper), replayed through
// cloud/collab/crdt the way dmonad/crdt-benchmarks' B4 replays it through Yjs
// and Automerge.
//
//	curl -LO https://github.com/josephg/editing-traces/raw/master/sequential_traces/automerge-paper.json.gz
//	python3 -I cloud/collab/bench/convert.py automerge-paper.json.gz paper.bin paper.end
//	odin run cloud/collab/bench -o:speed -- paper.bin paper.end
//
// It measures: applying every edit locally; applying each edit as its own
// update on a second replica (B4's method); the update and snapshot sizes;
// loading the snapshot; and the memory the final document holds.
package bench

import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import crdt "../crdt"

Patch :: struct {
	pos, del: u64,
	ins:      []u8,
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("bench <trace.bin> <end.txt>")
		os.exit(2)
	}
	raw, err := os.read_entire_file_from_path(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", os.args[1])
		os.exit(1)
	}
	want, err2 := os.read_entire_file_from_path(os.args[2], context.allocator)
	if err2 != nil {
		os.exit(1)
	}
	n := int(endian.unchecked_get_u32le(raw[0:4]))
	patches := make([]Patch, n)
	i := 4
	for k in 0 ..< n {
		pos := endian.unchecked_get_u32le(raw[i:])
		del := endian.unchecked_get_u32le(raw[i + 4:])
		ln := int(endian.unchecked_get_u32le(raw[i + 8:]))
		i += 12
		patches[k] = Patch{u64(pos), u64(del), raw[i:i + ln]}
		i += ln
	}

	// --- 1. local: every edit applied to one replica ----------------------
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	ta := mem.tracking_allocator(&track)

	d := crdt.doc_make(0x1234_5678_9abc_def0, ta)
	t0 := time.tick_now()
	for &p in patches {
		if p.del > 0 {
			crdt.remove(d, "text", p.pos, p.del)
		}
		if len(p.ins) > 0 {
			crdt.insert(d, "text", p.pos, p.ins)
		}
	}
	local := time.tick_since(t0)
	got := crdt.read_text(d, "text")
	ok := got == string(want)
	held := track.current_memory_allocated
	peak := track.peak_memory_allocated
	whole := crdt.take_update(d, context.allocator)

	items := 0
	for it := d.seqs["text"].head; it != nil; it = it.next {
		items += 1
	}

	// --- 2. B4: each edit as its own update, applied on another replica ---
	src := crdt.doc_make(1)
	ups := make([dynamic][]u8, 0, n)
	upbytes := 0
	for &p in patches {
		if p.del > 0 {
			crdt.remove(src, "text", p.pos, p.del)
		}
		if len(p.ins) > 0 {
			crdt.insert(src, "text", p.pos, p.ins)
		}
		u := crdt.take_update(src)
		upbytes += len(u)
		append(&ups, u)
	}
	dst := crdt.doc_make(2)
	t1 := time.tick_now()
	for u in ups {
		crdt.apply_update(dst, u)
		free_all(context.temp_allocator)
	}
	remote := time.tick_since(t1)
	ok2 := crdt.read_text(dst, "text") == string(want)

	// --- 3. one update holding the whole history ---------------------------
	dst2 := crdt.doc_make(3)
	t2 := time.tick_now()
	crdt.apply_update(dst2, whole)
	one := time.tick_since(t2)
	ok3 := crdt.read_text(dst2, "text") == string(want)

	// --- 4. snapshot -------------------------------------------------------
	t3 := time.tick_now()
	snap := crdt.encode_state(d)
	enc := time.tick_since(t3)
	t4 := time.tick_now()
	back, lok := crdt.doc_load(4, snap)
	load := time.tick_since(t4)
	ok4 := lok && crdt.read_text(back, "text") == string(want)

	fmt.printfln("trace: %d edits, final text %d bytes", n, len(want))
	fmt.printfln("local apply              %8.1f ms   %s", time.duration_milliseconds(local), ok ? "text matches" : "TEXT DIFFERS")
	fmt.printfln("  items in final list    %8d", items)
	fmt.printfln("  memory held / peak     %8.2f MB / %.2f MB", f64(held) / 1e6, f64(peak) / 1e6)
	fmt.printfln("B4: %d updates applied   %8.1f ms   %s", len(ups), time.duration_milliseconds(remote), ok2 ? "text matches" : "TEXT DIFFERS")
	fmt.printfln("  bytes on the wire      %8d (%.1f per edit)", upbytes, f64(upbytes) / f64(n))
	fmt.printfln("whole history as 1 update%8d bytes, applied in %.1f ms %s", len(whole), time.duration_milliseconds(one), ok3 ? "" : "TEXT DIFFERS")
	fmt.printfln("snapshot                 %8d bytes, encode %.1f ms, load %.1f ms %s", len(snap), time.duration_milliseconds(enc), time.duration_milliseconds(load), ok4 ? "" : "TEXT DIFFERS")
	os.exit(ok && ok2 && ok3 && ok4 ? 0 : 1)
}
