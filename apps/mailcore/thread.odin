package main

// Conversation threading, following Jamie Zawinski's algorithm
// (https://www.jwz.org/doc/threading.html) step for step.
//
// Containers live in one flat array and refer to each other by index, so the
// splicing in step 4 cannot dangle a pointer and the whole structure can be
// freed in one go. Children are a singly linked list, exactly as JWZ
// describes, because that is what makes "promote my children into my parent's
// child list" a constant-time operation.
//
// Subject-based gathering (step 5) is the only heuristic here, and it is the
// one that produces wrong threads in the wild, so it is opt-in via
// `use_subject` and runs last — after every Message-ID relationship has
// already been used.

import "core:mem"
import "core:strings"

// Threadable is what the caller hands in: one row per message, with whatever
// handle the caller wants back out in `key`.
Threadable :: struct {
	key:         string, // opaque to the threader: a Maildir filename, a UID, ...
	message_id:  string,
	in_reply_to: []string,
	references:  []string,
	subject:     string,
	date:        i64,
}

Container :: struct {
	id:     string,
	msg:    int, // index into the caller's []Threadable, or -1 for a phantom
	parent: int,
	child:  int, // first child
	next:   int, // next sibling
}

Threading :: struct {
	containers: []Container,
	roots:      []int,
	items:      []Threadable,
}

@(private = "file")
Builder :: struct {
	cs:        [dynamic]Container,
	by_id:     map[string]int,
	items:     []Threadable,
	synthetic: int,
	alloc:     mem.Allocator,
}

@(private = "file")
new_container :: proc(b: ^Builder, id: string, msg: int) -> int {
	append(&b.cs, Container{id = id, msg = msg, parent = -1, child = -1, next = -1})
	return len(b.cs) - 1
}

// get_container is JWZ step 1A's id_table lookup, creating on miss.
@(private = "file")
get_container :: proc(b: ^Builder, id: string) -> int {
	if idx, ok := b.by_id[id]; ok {
		return idx
	}
	idx := new_container(b, id, -1)
	b.by_id[id] = idx
	return idx
}

@(private = "file")
is_ancestor :: proc(b: ^Builder, maybe_ancestor, start: int) -> bool {
	// Bounded by the number of containers, so a pre-existing cycle (which
	// cannot happen, but) still terminates.
	n := 0
	for c := start; c >= 0; c = b.cs[c].parent {
		if c == maybe_ancestor {
			return true
		}
		n += 1
		if n > len(b.cs) {
			return false
		}
	}
	return false
}

@(private = "file")
unlink_child :: proc(b: ^Builder, child: int) {
	p := b.cs[child].parent
	if p < 0 {
		return
	}
	if b.cs[p].child == child {
		b.cs[p].child = b.cs[child].next
	} else {
		prev := b.cs[p].child
		for prev >= 0 && b.cs[prev].next != child {
			prev = b.cs[prev].next
		}
		if prev >= 0 {
			b.cs[prev].next = b.cs[child].next
		}
	}
	b.cs[child].parent = -1
	b.cs[child].next = -1
}

// link makes `child` a child of `parent`, refusing anything that would create
// a loop. JWZ is emphatic about this: References headers in the wild are
// mutually recursive often enough to hang a naive implementation.
@(private = "file")
link :: proc(b: ^Builder, parent, child: int) -> bool {
	if parent == child || parent < 0 || child < 0 {
		return false
	}
	if is_ancestor(b, child, parent) {
		return false
	}
	if b.cs[child].parent >= 0 {
		if b.cs[child].parent == parent {
			return true
		}
		unlink_child(b, child)
	}
	b.cs[child].parent = parent
	b.cs[child].next = b.cs[parent].child
	b.cs[parent].child = child
	return true
}

// thread_messages runs the whole algorithm and returns the root set.
thread_messages :: proc(
	items: []Threadable,
	use_subject := true,
	allocator := context.allocator,
) -> Threading {
	b := Builder {
		cs    = make([dynamic]Container, 0, len(items) * 2 + 4, allocator),
		by_id = make(map[string]int, len(items) * 2 + 4, allocator),
		items = items,
		alloc = allocator,
	}
	defer delete(b.by_id)

	// --- Step 1 -------------------------------------------------------------
	for it, mi in items {
		// 1A: the container for this message.
		mid := it.message_id
		self: int
		if mid == "" {
			// No Message-ID at all: it can only ever be a leaf.
			self = new_container(&b, "", mi)
		} else if existing, ok := b.by_id[mid]; ok && b.cs[existing].msg < 0 {
			self = existing
			b.cs[self].msg = mi
		} else if ok {
			// A duplicate Message-ID. JWZ: give it a container of its own,
			// not in the table, so the two do not collapse into one node.
			self = new_container(&b, mid, mi)
		} else {
			self = get_container(&b, mid)
			b.cs[self].msg = mi
		}

		// 1B: chain the References together, oldest first. In-Reply-To is
		// appended when it is not already the last reference, which is the
		// rule that makes threads work for mailers that send only one of the
		// two headers.
		refs := make([dynamic]string, 0, len(it.references) + len(it.in_reply_to), context.temp_allocator)
		for r in it.references {
			if r != "" && r != mid {
				append(&refs, r)
			}
		}
		for r in it.in_reply_to {
			if r == "" || r == mid {
				continue
			}
			if len(refs) == 0 || refs[len(refs) - 1] != r {
				append(&refs, r)
			}
		}

		prev := -1
		for r in refs {
			c := get_container(&b, r)
			if prev >= 0 {
				link(&b, prev, c)
			}
			prev = c
		}

		// 1C: the last reference is this message's parent.
		if prev >= 0 {
			if b.cs[self].parent >= 0 {
				unlink_child(&b, self)
			}
			link(&b, prev, self)
		}
	}

	// --- Step 2: the root set ----------------------------------------------
	// --- Step 4: prune phantoms --------------------------------------------
	roots := make([dynamic]int, 0, 8, allocator)
	for i in 0 ..< len(b.cs) {
		if b.cs[i].parent < 0 {
			append(&roots, i)
		}
	}

	// Prune depth-first. A phantom with no message and no children goes; a
	// phantom with exactly one child collapses into it; a phantom with several
	// children keeps its place at the root (it is the "missing first post" of
	// a thread) but is spliced away anywhere deeper.
	prune :: proc(b: ^Builder, idx: int, at_root: bool) -> int {
		// Returns the replacement index, or -1 if the container vanishes.
		kids := make([dynamic]int, 0, 4, context.temp_allocator)
		for c := b.cs[idx].child; c >= 0; c = b.cs[c].next {
			append(&kids, c)
		}
		b.cs[idx].child = -1
		kept := make([dynamic]int, 0, len(kids), context.temp_allocator)
		for k in kids {
			b.cs[k].parent = -1
			b.cs[k].next = -1
			r := prune(b, k, false)
			if r >= 0 {
				append(&kept, r)
			}
		}
		// Re-attach, preserving order.
		#reverse for k in kept {
			b.cs[k].parent = idx
			b.cs[k].next = b.cs[idx].child
			b.cs[idx].child = k
		}

		if b.cs[idx].msg >= 0 {
			return idx
		}
		if len(kept) == 0 {
			return -1 // 4A: empty container with no children
		}
		if len(kept) == 1 {
			// 4B: collapse. Safe even at the root, since there is only one.
			only := kept[0]
			b.cs[only].parent = -1
			b.cs[only].next = -1
			b.cs[idx].child = -1
			return only
		}
		if at_root {
			return idx // keep the phantom as the thread's stand-in root
		}
		// Deeper down, promote the children into the grandparent. The caller
		// handles that by splicing: signal it by returning -2.
		return -2
	}

	// Because `prune` may ask for promotion (-2) we do a second flattening
	// pass that walks the tree and splices any phantom with >1 child that is
	// not at the root.
	new_roots := make([dynamic]int, 0, len(roots), allocator)
	for r in roots {
		res := prune(&b, r, true)
		if res >= 0 {
			append(&new_roots, res)
		}
	}
	splice_phantoms(&b)

	// --- Step 5: subject gathering, strictly as a last resort --------------
	if use_subject {
		gather_by_subject(&b, &new_roots)
	}

	// --- Step 6: sort -------------------------------------------------------
	sort_children(&b)
	// Sort roots by their newest message, newest thread last, which is what a
	// mail list wants.
	sort_roots(&b, new_roots[:])

	return Threading{containers = b.cs[:], roots = new_roots[:], items = items}
}

// splice_phantoms removes every message-less container that still has a
// parent, hoisting its children. After this the only phantoms left are thread
// roots standing in for a message nobody has.
@(private = "file")
splice_phantoms :: proc(b: ^Builder) {
	changed := true
	passes := 0
	for changed && passes < len(b.cs) + 2 {
		changed = false
		passes += 1
		for i in 0 ..< len(b.cs) {
			if b.cs[i].msg >= 0 || b.cs[i].parent < 0 {
				continue
			}
			if b.cs[i].child < 0 {
				unlink_child(b, i)
				changed = true
				continue
			}
			p := b.cs[i].parent
			kids := make([dynamic]int, 0, 4, context.temp_allocator)
			for c := b.cs[i].child; c >= 0; c = b.cs[c].next {
				append(&kids, c)
			}
			b.cs[i].child = -1
			unlink_child(b, i)
			for k in kids {
				b.cs[k].parent = -1
				b.cs[k].next = -1
				link(b, p, k)
			}
			changed = true
		}
	}
}

@(private = "file")
container_date :: proc(b: ^Builder, idx: int) -> i64 {
	if b.cs[idx].msg >= 0 {
		return b.items[b.cs[idx].msg].date
	}
	// A phantom takes the date of its earliest child.
	best := max(i64)
	for c := b.cs[idx].child; c >= 0; c = b.cs[c].next {
		d := container_date(b, c)
		if d < best {
			best = d
		}
	}
	return best == max(i64) ? 0 : best
}

@(private = "file")
container_newest :: proc(b: ^Builder, idx: int) -> i64 {
	best: i64 = b.cs[idx].msg >= 0 ? b.items[b.cs[idx].msg].date : min(i64)
	for c := b.cs[idx].child; c >= 0; c = b.cs[c].next {
		d := container_newest(b, c)
		if d > best {
			best = d
		}
	}
	return best == min(i64) ? 0 : best
}

@(private = "file")
sort_children :: proc(b: ^Builder) {
	for i in 0 ..< len(b.cs) {
		if b.cs[i].child < 0 {
			continue
		}
		kids := make([dynamic]int, 0, 4, context.temp_allocator)
		for c := b.cs[i].child; c >= 0; c = b.cs[c].next {
			append(&kids, c)
		}
		if len(kids) < 2 {
			continue
		}
		// Insertion sort on date: stable, and these lists are tiny.
		for a in 1 ..< len(kids) {
			v := kids[a]
			vd := container_date(b, v)
			j := a - 1
			for j >= 0 && container_date(b, kids[j]) > vd {
				kids[j + 1] = kids[j]
				j -= 1
			}
			kids[j + 1] = v
		}
		b.cs[i].child = -1
		#reverse for k in kids {
			b.cs[k].next = b.cs[i].child
			b.cs[i].child = k
		}
	}
}

@(private = "file")
sort_roots :: proc(b: ^Builder, roots: []int) {
	for a in 1 ..< len(roots) {
		v := roots[a]
		vd := container_newest(b, v)
		j := a - 1
		for j >= 0 && container_newest(b, roots[j]) > vd {
			roots[j + 1] = roots[j]
			j -= 1
		}
		roots[j + 1] = v
	}
}

// ---------------------------------------------------------------------------
// Subject gathering
// ---------------------------------------------------------------------------

// normalise_subject strips every leading Re:/Fwd:/Fw:/Aw:/Sv: (and bracketed
// list tags) and reports whether anything was stripped. Only used by step 5.
normalise_subject :: proc(s: string, allocator := context.allocator) -> (base: string, was_reply: bool) {
	cur := strings.trim_space(s)
	for {
		before := cur
		low := strings.to_lower(cur, context.temp_allocator)
		for pfx in ([?]string{"re:", "re :", "fwd:", "fw:", "aw:", "sv:", "vs:", "antw:"}) {
			if strings.has_prefix(low, pfx) {
				cur = strings.trim_space(cur[len(pfx):])
				was_reply = true
				break
			}
		}
		// A list tag like "[odin-lang] " is not part of the subject.
		if strings.has_prefix(cur, "[") {
			if close := strings.index_byte(cur, ']'); close > 0 {
				cur = strings.trim_space(cur[close + 1:])
			}
		}
		if cur == before {
			break
		}
	}
	return strings.to_lower(strings.trim_space(cur), allocator), was_reply
}

@(private = "file")
root_subject :: proc(b: ^Builder, idx: int) -> (base: string, was_reply: bool, ok: bool) {
	mi := b.cs[idx].msg
	if mi < 0 {
		if b.cs[idx].child < 0 {
			return "", false, false
		}
		mi = b.cs[b.cs[idx].child].msg
		if mi < 0 {
			return "", false, false
		}
	}
	base, was_reply = normalise_subject(b.items[mi].subject, context.temp_allocator)
	return base, was_reply, base != ""
}

@(private = "file")
gather_by_subject :: proc(b: ^Builder, roots: ^[dynamic]int) {
	table := make(map[string]int, len(roots) * 2 + 4, context.temp_allocator)
	for r in roots^ {
		base, was_reply, ok := root_subject(b, r)
		if !ok {
			continue
		}
		old, exists := table[base]
		if !exists {
			table[base] = r
			continue
		}
		// Prefer a phantom root (it is the real thread head), then a non-reply.
		_, old_reply, _ := root_subject(b, old)
		if b.cs[old].msg >= 0 && b.cs[r].msg < 0 {
			table[base] = r
		} else if old_reply && !was_reply {
			table[base] = r
		}
	}

	merged := make(map[int]bool, len(roots) * 2 + 4, context.temp_allocator)
	for r in roots^ {
		base, was_reply, ok := root_subject(b, r)
		if !ok {
			continue
		}
		target, exists := table[base]
		if !exists || target == r || merged[r] {
			continue
		}
		_, t_reply, _ := root_subject(b, target)
		switch {
		case b.cs[target].msg < 0 && b.cs[r].msg < 0:
			// Both phantoms: fold r's children under target.
			kids := make([dynamic]int, 0, 4, context.temp_allocator)
			for c := b.cs[r].child; c >= 0; c = b.cs[c].next {
				append(&kids, c)
			}
			b.cs[r].child = -1
			for k in kids {
				b.cs[k].parent = -1
				b.cs[k].next = -1
				link(b, target, k)
			}
			merged[r] = true
		case b.cs[target].msg < 0:
			link(b, target, r)
			merged[r] = true
		case b.cs[r].msg < 0:
			// target is a real message, r is the phantom head: r wins.
			link(b, r, target)
			table[base] = r
			merged[target] = true
		case t_reply && !was_reply:
			link(b, r, target)
			table[base] = r
			merged[target] = true
		case !t_reply && was_reply:
			link(b, target, r)
			merged[r] = true
		case:
			// Two unrelated non-replies with the same subject. JWZ makes a new
			// phantom parent; we decline, because that is exactly the case
			// where subject matching invents conversations that do not exist.
		}
	}

	if len(merged) == 0 {
		return
	}
	kept := make([dynamic]int, 0, len(roots), b.alloc)
	for r in roots^ {
		if !merged[r] && b.cs[r].parent < 0 {
			append(&kept, r)
		}
	}
	clear(roots)
	for k in kept {
		append(roots, k)
	}
}

// ---------------------------------------------------------------------------
// Reading the result
// ---------------------------------------------------------------------------

// thread_flatten walks one thread depth-first and returns (container index,
// depth) pairs — the shape a threaded message list wants.
Thread_Row :: struct {
	container: int,
	depth:     int,
	item:      int, // index into Threading.items, or -1 for a phantom
}

thread_flatten :: proc(t: Threading, root: int, allocator := context.allocator) -> []Thread_Row {
	out := make([dynamic]Thread_Row, 0, 8, allocator)
	walk :: proc(t: Threading, idx, depth: int, out: ^[dynamic]Thread_Row) {
		if depth > MAX_MIME_DEPTH * 4 {
			return
		}
		append(out, Thread_Row{container = idx, depth = depth, item = t.containers[idx].msg})
		for c := t.containers[idx].child; c >= 0; c = t.containers[c].next {
			walk(t, c, depth + 1, out)
		}
	}
	walk(t, root, 0, &out)
	return out[:]
}

thread_size :: proc(t: Threading, root: int) -> (n: int) {
	if t.containers[root].msg >= 0 {
		n = 1
	}
	for c := t.containers[root].child; c >= 0; c = t.containers[c].next {
		n += thread_size(t, c)
	}
	return
}
