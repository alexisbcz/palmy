// Drawing the dependency graph so it can be read.
//
// A DAG that asserts correct and renders as spaghetti is worth nothing, so
// this is a real layered layout rather than nodes scattered on a grid with
// lines between them. Four passes, which is the Sugiyama shape:
//
//  1. **Layering.** Longest path: an issue sits one column to the right of
//     the furthest thing it waits for. Column 0 is therefore "nothing is in
//     front of this", which is the same question the headline view asks, so
//     the picture and `track ready` agree by construction. Time flows left to
//     right; every arrow points left, at what it is waiting for.
//
//  2. **Dummy nodes.** An edge spanning more than one column is cut into
//     one-column pieces with invisible nodes in between. This is the single
//     thing that most separates a readable graph from a hairball: without it
//     a long edge draws straight through whatever boxes happen to lie on the
//     line, and the reader cannot tell which box the line belongs to. With
//     it, the long edge is ordered along with everything else and routes
//     through the gaps.
//
//  3. **Ordering.** Barycentre sweeps, forward and back, keeping whichever
//     pass crossed least. Crossings are counted exactly, between each
//     adjacent pair of layers, so the best arrangement is chosen by
//     measurement rather than by having run the loop a fixed number of times.
//
//  4. **Coordinates.** Each node is pulled toward the median of its
//     neighbours and then pushed apart until nothing overlaps, a few times.
//     A straight edge reads as one relationship; a staircase reads as four,
//     so straightening the long chains is most of what makes the picture
//     calm.
//
// Then the drawing itself, where three choices do the work: edges go behind
// the nodes and in a colour close to the background, the focused node's own
// edges come forward in full strength while everything else fades, and an
// edge is a smooth curve whose ends are horizontal, so it leaves and arrives
// perpendicular to the box and the eye can follow it out of a crowd.
package main

import "core:math"
import "core:strings"
import p "palmy:."

NODE_W :: 176.0
NODE_H :: 50.0
COL_GAP :: 64.0
ROW_GAP :: 16.0
PAD :: 22.0
// LANE_HEAD is the strip at the top of the viewport the column headings
// sit in. It is screen space, not graph space: the headings do not scroll.
LANE_HEAD :: 30.0

Dag_Node :: struct {
	issue: int, // index into the store, or -1 for a routing dummy
	edge:  int, // which edge a dummy belongs to
	layer: int,
	order: int,
	x, y:  f32,
}

Dag_Edge :: struct {
	from, to: int, // store indices: `from` is blocked by `to`
	chain:    []int, // dag node indices, from the `from` end to the `to` end
}

Dag :: struct {
	nodes:    [dynamic]Dag_Node,
	edges:    [dynamic]Dag_Edge,
	layers:   [][]int,
	of_issue: map[int]int, // store index -> dag node index
	w, h:     f32,
	crossings: int,
}

dag_free :: proc(d: ^Dag) {
	delete(d.nodes)
	for e in d.edges {delete(e.chain)}
	delete(d.edges)
	for l in d.layers {delete(l)}
	delete(d.layers)
	delete(d.of_issue)
}

// dag_build lays the graph out. `visible` selects which issues take part, so
// the window can hide the closed ones without the layout knowing why.
dag_build :: proc(st: ^Store, g: ^Graph, visible: []bool) -> Dag {
	d := Dag{}
	d.nodes = make([dynamic]Dag_Node, 0, len(st.issues) * 2)
	d.edges = make([dynamic]Dag_Edge, 0, 32)
	d.of_issue = make(map[int]int)

	// ---- 1. layering -------------------------------------------------
	// Longest path over every resolved edge, not only the open ones: the
	// picture shows the structure, including the part that is finished, and a
	// closed dependency that still has an arrow drawn to it is the only way
	// to see why something became unblocked.
	n := len(st.issues)
	layer := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		layer[i] = -1
	}
	// A cycle would make this never terminate, so it is refused upstream;
	// defensively, the recursion depth is capped.
	resolve :: proc(g: ^Graph, visible: []bool, layer: []int, i: int, depth: int) -> int {
		if layer[i] >= 0 {
			return layer[i]
		}
		if depth > 256 {
			layer[i] = 0
			return 0
		}
		best := 0
		for dep in g.deps[i] {
			if !visible[dep] {
				continue
			}
			if v := resolve(g, visible, layer, dep, depth + 1) + 1; v > best {
				best = v
			}
		}
		layer[i] = best
		return best
	}
	maxl := 0
	for i in 0 ..< n {
		if !visible[i] {
			continue
		}
		if v := resolve(g, visible, layer, i, 0); v > maxl {
			maxl = v
		}
	}

	for i in 0 ..< n {
		if !visible[i] {
			continue
		}
		d.of_issue[i] = len(d.nodes)
		append(&d.nodes, Dag_Node{issue = i, edge = -1, layer = layer[i]})
	}

	// ---- 2. dummy nodes ----------------------------------------------
	for i in 0 ..< n {
		if !visible[i] {
			continue
		}
		for dep in g.deps[i] {
			if !visible[dep] {
				continue
			}
			ei := len(d.edges)
			hi := layer[i] // the dependant, further right
			lo := layer[dep] // what it waits for, further left
			chain := make([dynamic]int, 0, hi - lo + 1)
			append(&chain, d.of_issue[i])
			// One dummy per intervening column, right to left, so the chain
			// reads from the dependant to the dependency.
			for l := hi - 1; l > lo; l -= 1 {
				append(&chain, len(d.nodes))
				append(&d.nodes, Dag_Node{issue = -1, edge = ei, layer = l})
			}
			append(&chain, d.of_issue[dep])
			append(&d.edges, Dag_Edge{from = i, to = dep, chain = chain[:]})
		}
	}

	// ---- layer buckets -----------------------------------------------
	counts := make([]int, maxl + 1, context.temp_allocator)
	for nd in d.nodes {
		counts[nd.layer] += 1
	}
	d.layers = make([][]int, maxl + 1)
	for l in 0 ..= maxl {
		d.layers[l] = make([]int, 0)
	}
	buckets := make([][dynamic]int, maxl + 1, context.temp_allocator)
	for l in 0 ..= maxl {
		buckets[l] = make([dynamic]int, 0, counts[l], context.temp_allocator)
	}
	for nd, k in d.nodes {
		append(&buckets[nd.layer], k)
	}
	for l in 0 ..= maxl {
		d.layers[l] = make([]int, len(buckets[l]))
		copy(d.layers[l], buckets[l][:])
	}
	dag_renumber(&d)

	// ---- adjacency between adjacent layers ---------------------------
	// Built once from the chains, because after step 2 every edge is a
	// sequence of one-column hops and that is the only adjacency the
	// ordering and the coordinate passes need.
	left := make([][dynamic]int, len(d.nodes), context.temp_allocator)
	right := make([][dynamic]int, len(d.nodes), context.temp_allocator)
	for k in 0 ..< len(d.nodes) {
		left[k] = make([dynamic]int, 0, 4, context.temp_allocator)
		right[k] = make([dynamic]int, 0, 4, context.temp_allocator)
	}
	for e in d.edges {
		for k in 0 ..< len(e.chain) - 1 {
			hi := e.chain[k] // the further-right node
			lo := e.chain[k + 1] // the further-left node
			append(&left[hi], lo)
			append(&right[lo], hi)
		}
	}

	// ---- 3. ordering -------------------------------------------------
	best_order := make([]int, len(d.nodes), context.temp_allocator)
	for nd, k in d.nodes {
		best_order[k] = nd.order
	}
	best_cross := dag_crossings(&d, left)
	for pass in 0 ..< 16 {
		if pass % 2 == 0 {
			// Forward: each layer takes its order from the layer on its left.
			for l in 1 ..< len(d.layers) {
				dag_sort_by_barycentre(&d, d.layers[l], left)
			}
		} else {
			for l := len(d.layers) - 2; l >= 0; l -= 1 {
				dag_sort_by_barycentre(&d, d.layers[l], right)
			}
		}
		if c := dag_crossings(&d, left); c < best_cross {
			best_cross = c
			for nd, k in d.nodes {
				best_order[k] = nd.order
			}
		}
	}
	// Restore the best arrangement seen, which is not necessarily the last.
	for k in 0 ..< len(d.nodes) {
		d.nodes[k].order = best_order[k]
	}
	for l in 0 ..< len(d.layers) {
		arr := d.layers[l]
		for a in 1 ..< len(arr) {
			j := a
			for j > 0 && d.nodes[arr[j]].order < d.nodes[arr[j - 1]].order {
				arr[j], arr[j - 1] = arr[j - 1], arr[j]
				j -= 1
			}
		}
	}
	dag_renumber(&d)
	d.crossings = best_cross

	// ---- 4. coordinates ----------------------------------------------
	// A dummy is a point on a line, not a box, so it needs far less room than
	// a node. Giving it a node's height is what makes a graph with a few long
	// edges three times taller than it has to be.
	height_of :: proc(d: ^Dag, k: int) -> f32 {
		return d.nodes[k].issue >= 0 ? NODE_H : 10
	}
	for l in 0 ..< len(d.layers) {
		y := f32(PAD)
		for k in d.layers[l] {
			d.nodes[k].x = PAD + f32(l) * (NODE_W + COL_GAP)
			d.nodes[k].y = y
			y += height_of(&d, k) + ROW_GAP
		}
	}
	// Pull toward the median of the neighbours, then separate. Alternating
	// the direction matters: pulling only from the left leaves the last
	// column ragged, and pulling only from the right leaves the first.
	for round in 0 ..< 6 {
		fwd := round % 2 == 0
		order := make([]int, len(d.layers), context.temp_allocator)
		for l in 0 ..< len(d.layers) {
			order[l] = fwd ? l : len(d.layers) - 1 - l
		}
		for l in order {
			adj := fwd ? left : right
			for k in d.layers[l] {
				if len(adj[k]) == 0 {
					continue
				}
				sum := f32(0)
				for m in adj[k] {
					sum += d.nodes[m].y + height_of(&d, m) / 2
				}
				want := sum / f32(len(adj[k])) - height_of(&d, k) / 2
				// Move most of the way rather than all of it: a full jump
				// fights the separation pass and the two oscillate.
				d.nodes[k].y += (want - d.nodes[k].y) * 0.7
			}
			dag_separate(&d, d.layers[l], height_of)
		}
	}
	// Everything above may have gone negative; shift the whole picture down.
	lo := f32(1e9)
	for nd in d.nodes {
		if nd.y < lo {
			lo = nd.y
		}
	}
	if lo < PAD {
		for k in 0 ..< len(d.nodes) {
			d.nodes[k].y += PAD - lo
		}
	}

	d.w = PAD * 2 + f32(max(len(d.layers), 1)) * NODE_W + f32(max(len(d.layers) - 1, 0)) * COL_GAP
	d.h = PAD
	for nd in d.nodes {
		if b := nd.y + (nd.issue >= 0 ? NODE_H : 10) + PAD; b > d.h {
			d.h = b
		}
	}
	return d
}

dag_renumber :: proc(d: ^Dag) {
	for l in 0 ..< len(d.layers) {
		for k, i in d.layers[l] {
			d.nodes[k].order = i
		}
	}
}

// dag_sort_by_barycentre orders one layer by the mean position of each node's
// neighbours on the side being swept from. A node with no neighbour there
// keeps the place it had, which is what stops isolated nodes drifting to the
// top on every pass.
dag_sort_by_barycentre :: proc(d: ^Dag, layer: []int, adj: [][dynamic]int) {
	bary := make([]f32, len(layer), context.temp_allocator)
	for k, i in layer {
		if len(adj[k]) == 0 {
			bary[i] = f32(d.nodes[k].order)
			continue
		}
		sum := f32(0)
		for m in adj[k] {
			sum += f32(d.nodes[m].order)
		}
		bary[i] = sum / f32(len(adj[k]))
	}
	// Insertion sort, stable, which keeps equal barycentres in their current
	// order and therefore keeps the layout stable between frames.
	for a in 1 ..< len(layer) {
		j := a
		for j > 0 && bary[j] < bary[j - 1] {
			layer[j], layer[j - 1] = layer[j - 1], layer[j]
			bary[j], bary[j - 1] = bary[j - 1], bary[j]
			j -= 1
		}
	}
	// Renumber THIS layer now, not after the whole sweep. The next layer's
	// barycentres are read off these positions, and computing them from the
	// previous iteration's numbering is the difference between a sweep that
	// converges and one that mostly stirs: it took this graph from nine
	// crossings to three.
	for k, i in layer {
		d.nodes[k].order = i
	}
}

// dag_crossings counts, exactly, how many pairs of edges cross between each
// adjacent pair of layers. Two edges (a->b) and (c->d) cross when a is above
// c and b is below d. Quadratic in the edges between two layers, which for a
// graph a person is going to look at is nothing.
dag_crossings :: proc(d: ^Dag, left: [][dynamic]int) -> int {
	total := 0
	for l in 1 ..< len(d.layers) {
		pairs := make([dynamic][2]int, 0, 32, context.temp_allocator)
		for k in d.layers[l] {
			for m in left[k] {
				append(&pairs, [2]int{d.nodes[k].order, d.nodes[m].order})
			}
		}
		for a in 0 ..< len(pairs) {
			for b in a + 1 ..< len(pairs) {
				x, y := pairs[a], pairs[b]
				if (x[0] - y[0]) * (x[1] - y[1]) < 0 {
					total += 1
				}
			}
		}
	}
	return total
}

// dag_separate pushes a layer's nodes apart until none overlaps, preserving
// their order, and keeps the result centred on where it started so the pull
// pass above is not undone every time.
dag_separate :: proc(d: ^Dag, layer: []int, height_of: proc(d: ^Dag, k: int) -> f32) {
	if len(layer) == 0 {
		return
	}
	before := f32(0)
	for k in layer {
		before += d.nodes[k].y
	}
	// Downward sweep.
	for i in 1 ..< len(layer) {
		prev, cur := layer[i - 1], layer[i]
		floor := d.nodes[prev].y + height_of(d, prev) + ROW_GAP
		if d.nodes[cur].y < floor {
			d.nodes[cur].y = floor
		}
	}
	// Upward sweep, so a node pushed down does not drag the whole column.
	for i := len(layer) - 2; i >= 0; i -= 1 {
		next, cur := layer[i + 1], layer[i]
		ceil := d.nodes[next].y - height_of(d, cur) - ROW_GAP
		if d.nodes[cur].y > ceil {
			d.nodes[cur].y = ceil
		}
	}
	after := f32(0)
	for k in layer {
		after += d.nodes[k].y
	}
	shift := (before - after) / f32(len(layer))
	for k in layer {
		d.nodes[k].y += shift
	}
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

Dag_Theme :: struct {
	bg:        p.Color,
	card:      p.Color,
	card_done: p.Color,
	ring:      p.Color,
	ring_ready: p.Color,
	ring_focus: p.Color,
	edge:      p.Color,
	edge_hot:  p.Color,
	fg:        p.Color,
	muted:     p.Color,
	ready:     p.Color,
	stale:     p.Color,
	lane:      p.Color,
}

dag_theme_light :: proc() -> Dag_Theme {
	return Dag_Theme {
		bg = p.hex(0xfafafa),
		card = p.hex(0xffffff),
		card_done = p.hex(0xf4f4f5),
		ring = p.Color{9, 9, 11, 34},
		ring_ready = p.hex(0x16a34a),
		ring_focus = p.hex(0x2563eb),
		edge = p.Color{82, 82, 91, 150},
		edge_hot = p.hex(0x2563eb),
		fg = p.hex(0x18181b),
		muted = p.hex(0x71717a),
		ready = p.hex(0x16a34a),
		stale = p.hex(0xdc2626),
		lane = p.Color{9, 9, 11, 9},
	}
}

Dag_View :: struct {
	dag:    ^Dag,
	store:  ^Store,
	graph:  ^Graph,
	fonts:  ^p.Fonts,
	theme:  Dag_Theme,
	focus:  int, // store index of the focused issue, or -1
	scroll: [2]f32,
	// zoom of 0 means "fit": the whole graph is scaled down to the viewport
	// and centred, which is what a reader wants the first time they look at
	// one. Panning or zooming by hand sets a real number and turns it off.
	zoom:   f32,
}

// dag_fit is the scale and the offset that put the whole graph in `r`,
// centred, never magnified past 1:1 — a four-node graph blown up to fill a
// wall reads worse than a four-node graph at its natural size.
dag_fit :: proc(d: ^Dag, r: p.Rect, want_zoom: f32) -> (z, ox, oy: f32) {
	if want_zoom > 0 {
		return want_zoom, 0, 0
	}
	if d.w <= 0 || d.h <= 0 {
		return 1, 0, 0
	}
	// The column headings own a band at the top of the viewport, in screen
	// space, so they stay put while the graph pans. The fit has to know
	// about it or the first row of boxes is drawn through them.
	usable := max(r.h - LANE_HEAD, 40)
	z = min(min(r.w / d.w, usable / d.h), 1)
	z = max(z, 0.3)
	ox = (r.w - d.w * z) / 2
	oy = LANE_HEAD + (usable - d.h * z) / 2
	return z, max(ox, 0), max(oy, LANE_HEAD)
}

// dag_draw paints the whole graph into `r`, scrolled and scaled. Edges first,
// then nodes, so a line never crosses a box it does not belong to.
dag_draw :: proc(c: ^p.Canvas, r: p.Rect, v: ^Dag_View) {
	d := v.dag
	th := v.theme
	z, ox, oy := dag_fit(d, r, v.zoom)
	p.fill_rect(c, r, th.bg)
	p.push_clip(c, r)
	defer p.pop_clip(c)

	at :: proc(v: ^Dag_View, r: p.Rect, z, ox, oy, x, y: f32) -> (f32, f32) {
		return r.x + ox + (x - v.scroll.x) * z, r.y + oy + (y - v.scroll.y) * z
	}

	// Column bands. A faint alternating stripe is what tells the reader the
	// horizontal axis means something; without it the columns read as an
	// accident of the layout.
	for l in 0 ..< len(d.layers) {
		if l % 2 == 1 {
			continue
		}
		x0, _ := at(v, r, z, ox, oy, PAD + f32(l) * (NODE_W + COL_GAP) - COL_GAP / 2, 0)
		p.fill_rect(c, {x0, r.y, (NODE_W + COL_GAP) * z, r.h}, th.lane)
	}

	// Column headings, in the same words the CLI uses.
	for l in 0 ..< len(d.layers) {
		x0, _ := at(v, r, z, ox, oy, PAD + f32(l) * (NODE_W + COL_GAP), 0)
		label := l == 0 ? "unblocked now" : tfmt("after %d", l)
		// A fixed 11px, not 11*z: a heading scaled down with the graph stops
		// being readable exactly when the graph is big enough to need it.
		p.draw_text(c, v.fonts, label, x0, r.y + 19, 11, th.muted, .Sans, .Semibold, 0.4)
	}

	// ---- edges -------------------------------------------------------
	for e in d.edges {
		hot := v.focus >= 0 && (e.from == v.focus || e.to == v.focus)
		col := hot ? th.edge_hot : th.edge
		if v.focus >= 0 && !hot {
			col.a = col.a / 3
		}
		width := (hot ? 2.4 : 1.6) * max(z, 0.6)
		// The chain runs from the dependant to the dependency; draw it in
		// that direction so the arrowhead lands on the thing being waited
		// for, which is where the reader's eye is going.
		for k in 0 ..< len(e.chain) - 1 {
			a := e.chain[k]
			b := e.chain[k + 1]
			ax, ay := dag_port(d, a, false)
			bx, by := dag_port(d, b, true)
			sx, sy := at(v, r, z, ox, oy, ax, ay)
			ex, ey := at(v, r, z, ox, oy, bx, by)
			dag_curve(c, sx, sy, ex, ey, width, col)
		}
		// One arrowhead, at the dependency end.
		last := e.chain[len(e.chain) - 1]
		px, py := dag_port(d, last, false)
		hx, hy := at(v, r, z, ox, oy, px, py)
		dag_arrow(c, hx, hy, 5.5 * max(z, 0.6), col)
	}

	// ---- nodes -------------------------------------------------------
	for nd in d.nodes {
		if nd.issue < 0 {
			continue
		}
		it := &v.store.issues[nd.issue]
		gi := nd.issue
		x, y := at(v, r, z, ox, oy, nd.x, nd.y)
		w, h := NODE_W * z, NODE_H * z
		box := p.Rect{x, y, w, h}
		if !p.rect_overlaps(box, r) {
			continue
		}
		closed := v.graph.closed[gi]
		focused := v.focus == gi
		rad := p.Radius{8 * z, 8 * z, 8 * z, 8 * z}

		if focused {
			p.drop_shadow(c, box, rad, 14 * z, 0, {0, 3 * z}, p.Color{37, 99, 235, 70})
		}
		p.fill_round_rect(c, box, rad, closed ? th.card_done : th.card)
		ring := th.ring
		rw := f32(1)
		if v.graph.ready[gi] {
			ring = th.ring_ready
			rw = 1.6
		}
		if focused {
			ring = th.ring_focus
			rw = 2.2
		}
		p.stroke_round_rect(c, box, rad, rw * z, ring)

		// A four-pixel spine down the left edge, coloured by whether the
		// issue is ready. It survives being small on screen, which the ring
		// does not.
		if !closed {
			spine := p.Rect{x, y + 8 * z, 3 * z, h - 16 * z}
			p.fill_rect(c, spine, v.graph.ready[gi] ? th.ready : th.muted)
		}

		tx := x + 12 * z
		p.draw_text(c, v.fonts, it.id, tx, y + 19 * z, 11.5 * z, th.muted, .Mono, .Medium, 0.2)
		idw := p.text_width(v.fonts, it.id, 11.5 * z, .Mono, .Medium, 0.2)

		// The verification badge sits beside the id, because "this issue is
		// lying" outranks everything else on the card.
		if it.verify != "" {
			bx := tx + idw + 7 * z
			switch it.verdict {
			case .Stale:
				bw := p.text_width(v.fonts, "STALE", 9 * z, .Sans, .Bold, 0.5) + 10 * z
				p.fill_round_rect(c, {bx, y + 8 * z, bw, 14 * z}, {7 * z, 7 * z, 7 * z, 7 * z}, th.stale)
				p.draw_text(c, v.fonts, "STALE", bx + 5 * z, y + 18.5 * z, 9 * z, p.hex(0xffffff), .Sans, .Bold, 0.5)
			case .True:
				p.fill_circle(c, bx + 4 * z, y + 14 * z, 3.5 * z, th.ready)
			case .Unverified:
				p.fill_circle(c, bx + 4 * z, y + 14 * z, 3.5 * z, p.Color{113, 113, 122, 110})
			}
		}

		title := ellipsis_to_width(v.fonts, it.title, 13 * z, NODE_W * z - 24 * z)
		p.draw_text(c, v.fonts, title, tx, y + 36 * z, 13 * z, closed ? th.muted : th.fg, .Sans, .Medium)
	}
}

// dag_port is where an edge attaches: the right edge of a node for the
// dependant end, the left edge for the dependency end. Horizontal ports are
// what let the curve leave and arrive perpendicular to the box, which is
// most of why a dense graph stays readable.
dag_port :: proc(d: ^Dag, k: int, incoming: bool) -> (x, y: f32) {
	nd := d.nodes[k]
	if nd.issue < 0 {
		return nd.x + NODE_W / 2, nd.y + 5
	}
	if incoming {
		return nd.x + NODE_W, nd.y + NODE_H / 2 // leaving the dependant
	}
	return nd.x, nd.y + NODE_H / 2 // arriving at the dependency
}

// dag_curve draws a horizontal cubic between two points. The control points
// sit a fixed fraction of the horizontal gap away, so every edge in a column
// has the same shape and the eye reads them as a family.
dag_curve :: proc(c: ^p.Canvas, x0, y0, x1, y1, width: f32, col: p.Color) {
	dx := x1 - x0
	c0x := x0 + dx * 0.45
	c1x := x1 - dx * 0.45
	steps := 1 + int(clamp((abs(dx) + abs(y1 - y0)) / 7, 6, 48))
	px, py := x0, y0
	for i in 1 ..= steps {
		t := f32(i) / f32(steps)
		u := 1 - t
		// Cubic Bézier with both control points on the endpoints' own rows.
		bx := u * u * u * x0 + 3 * u * u * t * c0x + 3 * u * t * t * c1x + t * t * t * x1
		by := u * u * u * y0 + 3 * u * u * t * y0 + 3 * u * t * t * y1 + t * t * t * y1
		p.draw_line(c, px, py, bx, by, width, col)
		px, py = bx, by
	}
}

// dag_arrow is a filled triangle whose tip is at (x, y) and which points
// left, at the thing being waited for. Drawn as a stack of vertical spans a
// pixel apart rather than as a path: it is the cheapest correct triangle and
// it needs nothing palmy does not already have.
dag_arrow :: proc(c: ^p.Canvas, x, y, size: f32, col: p.Color) {
	solid := col
	solid.a = max(col.a, 200)
	n := max(int(math.ceil(size * 2)), 4)
	length := size * 1.9
	for i in 0 ..= n {
		t := f32(i) / f32(n)
		half := size * t * 0.72
		px := x + length * t
		p.draw_line(c, px, y - half, px, y + half, 1.25, solid)
	}
}

ellipsis_to_width :: proc(f: ^p.Fonts, s: string, size, max_w: f32, allocator := context.temp_allocator) -> string {
	if p.text_width(f, s, size, .Sans, .Medium) <= max_w {
		return s
	}
	cut := len(s)
	for cut > 1 {
		cut -= 1
		for cut > 1 && (s[cut] & 0xC0) == 0x80 {
			cut -= 1
		}
		cand := strings.concatenate({s[:cut], "…"}, allocator)
		if p.text_width(f, cand, size, .Sans, .Medium) <= max_w {
			return cand
		}
	}
	return "…"
}

// dag_hit is which node the pointer is over, as a store index, or -1.
dag_hit :: proc(v: ^Dag_View, r: p.Rect, mx, my: f32) -> int {
	z, ox, oy := dag_fit(v.dag, r, v.zoom)
	for nd in v.dag.nodes {
		if nd.issue < 0 {
			continue
		}
		x := r.x + ox + (nd.x - v.scroll.x) * z
		y := r.y + oy + (nd.y - v.scroll.y) * z
		if p.rect_contains({x, y, NODE_W * z, NODE_H * z}, mx, my) {
			return nd.issue
		}
	}
	return -1
}
