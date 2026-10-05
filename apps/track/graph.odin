// The dependency graph, which is the thing that makes this a tracker rather
// than a list of todos.
//
// An edge `A deps: B` means *A is blocked by B*. Everything here follows from
// that one sentence:
//
//   * **Unblocked** — the headline view, and the only question most people
//     actually have — is: this issue is not itself in a closed state, and
//     every issue it depends on is. A missing dependency does NOT count as
//     satisfied; it counts as blocked, and is reported separately, because
//     "the thing I was waiting for no longer exists" is a problem and
//     silently unblocking is how a tracker starts lying.
//   * **A cycle is refused**, not warned about. Three issues that each wait
//     for the next can never start, and a tracker that lets you write that
//     down has let you write down something with no meaning.
//   * **Depth** — the longest chain of unfinished work in front of an issue —
//     is what the graph view lays out along its horizontal axis and what
//     `track ready` sorts by.
package main

import "core:fmt"
import "core:strings"

Graph :: struct {
	ids:      []string,
	index:    map[string]int,
	deps:     [][]int, // resolved edges: deps[i] are the issues i waits for
	dependants: [][]int, // the reverse, which the UI needs to highlight
	missing:  [][]string, // dependency ids that do not resolve
	closed:   []bool,
	depth:    []int, // longest path to an issue with no open dependency
	ready:    []bool,
	cycle:    []string, // one cycle, as ids, if the graph has any
}

graph_free :: proc(g: ^Graph) {
	delete(g.ids)
	delete(g.index)
	for d in g.deps {delete(d)}
	delete(g.deps)
	for d in g.dependants {delete(d)}
	delete(g.dependants)
	for m in g.missing {delete(m)}
	delete(g.missing)
	delete(g.closed)
	delete(g.depth)
	delete(g.ready)
	delete(g.cycle)
}

// graph_build resolves ids to indices once, so nothing below ever does a
// string comparison inside a loop over edges.
graph_build :: proc(st: ^Store) -> Graph {
	n := len(st.issues)
	g := Graph {
		ids        = make([]string, n),
		index      = make(map[string]int, n),
		deps       = make([][]int, n),
		dependants = make([][]int, n),
		missing    = make([][]string, n),
		closed     = make([]bool, n),
		depth      = make([]int, n),
		ready      = make([]bool, n),
	}
	for it, i in st.issues {
		g.ids[i] = it.id
		g.index[it.id] = i
	}
	rev := make([][dynamic]int, n, context.temp_allocator)
	for i in 0 ..< n {
		rev[i] = make([dynamic]int, context.temp_allocator)
	}
	for it, i in st.issues {
		g.closed[i] = state_is_closed(st.states, it.state)
		res := make([dynamic]int, 0, len(it.deps))
		miss := make([dynamic]string, 0, 0)
		for d in it.deps {
			if j, ok := g.index[d]; ok {
				if j == i {
					// A self-edge is a one-node cycle. It never resolves, so
					// it is recorded as missing rather than as an edge, and
					// graph_cycle reports it.
					append(&miss, d)
					continue
				}
				dup := false
				for e in res {
					if e == j {
						dup = true
					}
				}
				if !dup {
					append(&res, j)
					append(&rev[j], i)
				}
			} else {
				append(&miss, d)
			}
		}
		g.deps[i] = res[:]
		g.missing[i] = miss[:]
	}
	for i in 0 ..< n {
		g.dependants[i] = make([]int, len(rev[i]))
		copy(g.dependants[i], rev[i][:])
	}

	g.cycle = graph_cycle(&g, st)
	graph_rank(&g)
	return g
}

// graph_cycle returns one cycle as a list of ids, in order, or nil. Iterative
// depth-first with an explicit stack: a tracker should not blow the Odin
// stack because somebody pasted a deep chain in.
graph_cycle :: proc(g: ^Graph, st: ^Store) -> []string {
	n := len(g.ids)
	// A dependency on yourself is the shortest cycle there is, and it never
	// becomes an edge, so it is checked first.
	for it, i in st.issues {
		for d in it.deps {
			if d == it.id {
				out := make([]string, 2)
				out[0] = g.ids[i]
				out[1] = g.ids[i]
				return out
			}
		}
	}

	WHITE :: 0
	GREY :: 1
	BLACK :: 2
	colour := make([]u8, n, context.temp_allocator)
	parent := make([]int, n, context.temp_allocator)
	next := make([]int, n, context.temp_allocator) // which dep we are up to
	for i in 0 ..< n {
		parent[i] = -1
	}

	stack := make([dynamic]int, 0, n, context.temp_allocator)
	for start in 0 ..< n {
		if colour[start] != WHITE {
			continue
		}
		clear(&stack)
		append(&stack, start)
		colour[start] = GREY
		next[start] = 0
		for len(stack) > 0 {
			v := stack[len(stack) - 1]
			if next[v] < len(g.deps[v]) {
				w := g.deps[v][next[v]]
				next[v] += 1
				if colour[w] == GREY {
					// Walk the grey chain back from v to w: that is the cycle.
					path := make([dynamic]string, 0, 8)
					at := v
					for {
						append(&path, g.ids[at])
						if at == w {
							break
						}
						at = parent[at]
						if at < 0 {
							break
						}
					}
					// Reverse into dependency order and close the loop, so it
					// reads A -> B -> C -> A.
					out := make([]string, len(path) + 1)
					for k in 0 ..< len(path) {
						out[k] = path[len(path) - 1 - k]
					}
					out[len(path)] = out[0]
					delete(path)
					return out
				}
				if colour[w] == WHITE {
					colour[w] = GREY
					parent[w] = v
					next[w] = 0
					append(&stack, w)
				}
			} else {
				colour[v] = BLACK
				pop(&stack)
			}
		}
	}
	return nil
}

// graph_rank fills `depth` and `ready`.
//
// depth is the length of the longest chain of OPEN dependencies in front of
// an issue. A closed dependency contributes nothing, because it is done: the
// column an issue sits in should say how long the queue in front of it is
// now, not how long it was before anybody started.
graph_rank :: proc(g: ^Graph) {
	n := len(g.ids)
	if len(g.cycle) > 0 {
		// With a cycle present, longest-path is not defined. Everything gets
		// depth 0 and nothing is ready, which is the honest answer: the graph
		// has to be fixed before it means anything.
		return
	}
	// Kahn, over open dependencies only.
	indeg := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		for d in g.deps[i] {
			if !g.closed[d] {
				indeg[i] += 1
			}
		}
	}
	queue := make([dynamic]int, 0, n, context.temp_allocator)
	for i in 0 ..< n {
		if indeg[i] == 0 {
			append(&queue, i)
		}
	}
	head := 0
	for head < len(queue) {
		v := queue[head]
		head += 1
		// A closed dependency never counted toward anybody's indeg and never
		// adds to anybody's depth, so it releases nothing and contributes
		// nothing. That is the whole reason depth means "the queue in front
		// of this now".
		if g.closed[v] {
			continue
		}
		for w in g.dependants[v] {
			if g.depth[w] < g.depth[v] + 1 {
				g.depth[w] = g.depth[v] + 1
			}
			indeg[w] -= 1
			if indeg[w] == 0 {
				append(&queue, w)
			}
		}
	}

	for i in 0 ..< n {
		if g.closed[i] {
			continue
		}
		blocked := len(g.missing[i]) > 0
		for d in g.deps[i] {
			if !g.closed[d] {
				blocked = true
				break
			}
		}
		g.ready[i] = !blocked
	}
}

// graph_blockers lists what is actually in an issue's way right now: its open
// dependencies and its dangling ones, and nothing else. "Why can I not start
// this" should be answerable in one line.
graph_blockers :: proc(g: ^Graph, i: int, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for d in g.deps[i] {
		if !g.closed[d] {
			append(&out, g.ids[d])
		}
	}
	for m in g.missing[i] {
		append(&out, fmt.tprintf("%s (missing)", m))
	}
	return out[:]
}

// would_cycle answers the question every write asks: if `from` were to depend
// on `to`, would the graph still be acyclic? It is a reachability test from
// `to` back to `from` over the existing edges, which is cheaper than
// rebuilding and re-detecting, and it is the only thing standing between a
// tracker and a set of issues that can never be started.
//
// It takes the issue list directly rather than a Graph, so it can be called
// before anything is written and on a store that has not been ranked.
would_cycle :: proc(st: ^Store, from, to: string) -> (cycle: []string, yes: bool) {
	if from == to {
		out := make([]string, 2)
		out[0] = from
		out[1] = from
		return out, true
	}
	index := make(map[string]int, len(st.issues), context.temp_allocator)
	for it, i in st.issues {
		index[it.id] = i
	}
	fi, ok_f := index[from]
	ti, ok_t := index[to]
	if !ok_f || !ok_t {
		return nil, false
	}
	// Breadth-first from `to` following ITS dependencies. If `from` is
	// reachable, then adding from -> to closes a loop.
	prev := make([]int, len(st.issues), context.temp_allocator)
	seen := make([]bool, len(st.issues), context.temp_allocator)
	for i in 0 ..< len(prev) {
		prev[i] = -1
	}
	queue := make([dynamic]int, 0, len(st.issues), context.temp_allocator)
	append(&queue, ti)
	seen[ti] = true
	head := 0
	for head < len(queue) {
		v := queue[head]
		head += 1
		if v == fi {
			// Reconstruct to -> ... -> from, then prepend from and append to,
			// so the reported cycle reads the way the edges point.
			path := make([dynamic]string, 0, 8, context.temp_allocator)
			at := v
			for at >= 0 {
				append(&path, st.issues[at].id)
				at = prev[at]
			}
			out := make([]string, len(path) + 1)
			out[0] = strings.clone(from)
			for k in 0 ..< len(path) {
				out[k + 1] = strings.clone(path[len(path) - 1 - k])
			}
			return out, true
		}
		for d in st.issues[v].deps {
			if j, got := index[d]; got && !seen[j] {
				seen[j] = true
				prev[j] = v
				append(&queue, j)
			}
		}
	}
	return nil, false
}

cycle_text :: proc(c: []string, allocator := context.temp_allocator) -> string {
	return strings.join(c, " -> ", allocator)
}
