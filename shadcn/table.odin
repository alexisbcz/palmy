package shadcn

// Table, from app/components/ui/table.tsx.
//
// Two things about a real <table> have no equivalent in flexbox and are handled
// explicitly here.
//
// Column widths. Chromium's automatic table layout measures every cell's
// max-content width and distributes the slack between the columns. palmy has no
// table algorithm, so each column is given the width the browser resolved; the
// cells are plain flex items of a fixed size.
//
// Collapsed borders. Tailwind's preflight sets `border-collapse: collapse`, so
// the 1px rule that `border-b` puts on a <tr> is shared with the next row and
// is painted centred on the boundary between them, half inside each row's box.
// That is why the row rects in the capture are 37px for a 36px row and the last
// row is 36.5px. The rows here are laid out at exactly those heights and the
// rules are drawn as absolutely positioned hairlines over them, which is also
// how the browser paints them: on top of both rows' backgrounds.

import p "palmy:."

table_open :: proc(ui: ^p.Ctx, class := "") -> int {
	idx := p.col(ui, "relative text-sm")
	p.apply(ui, class)
	return idx
}

table_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// table_row_open lays out one <tr>. `h` is the height from the capture, which
// already accounts for the half of each collapsed border that falls inside it.
table_row_open :: proc(ui: ^p.Ctx, h: f32, class := "") -> int {
	idx := p.row(ui, "w-full items-stretch")
	p.apply(ui, class)
	p.style(ui).h = p.px(h)
	p.style(ui).shrink = 0
	return idx
}

table_row_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// table_cell is a <th> or <td>: `px-2` with the text on the vertical centre
// line (`align-middle`). A <th> adds `font-medium`, a <td> `py-2`.
table_cell :: proc(ui: ^p.Ctx, label: string, w: f32, right := false, class := "") {
	p.col(ui, "px-2 justify-center")
	p.apply(ui, class)
	p.style(ui).w = p.px(w)
	p.style(ui).shrink = 0
	defer p.end(ui)

	p.text(ui, label, right ? "text-right whitespace-nowrap" : "whitespace-nowrap")
}

// <th>: `h-10 px-2 text-left align-middle font-medium text-foreground`.
table_head :: proc(ui: ^p.Ctx, label: string, w: f32, right := false) {
	table_cell(ui, label, w, right, "font-medium text-foreground")
}

// <td>: `p-2 align-middle`.
table_data :: proc(ui: ^p.Ctx, label: string, w: f32, right := false) {
	table_cell(ui, label, w, right, "py-2")
}

// table_rule draws one collapsed 1px row border. `y` is the top of the hairline
// in the table's own coordinates.
table_rule :: proc(ui: ^p.Ctx, y: f32) {
	p.div(ui, "absolute left-0 w-full h-px bg-border")
	p.style(ui).inset[p.TOP] = p.px(y)
	p.end(ui)
}

// `mt-4 text-sm text-muted-foreground`, centred, below the table body.
table_caption :: proc(ui: ^p.Ctx, label: string) {
	p.text(ui, label, "mt-4 text-sm text-muted-foreground text-center w-full")
}
