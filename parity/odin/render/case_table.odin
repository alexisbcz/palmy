package main

import p "palmy:."
import sc "shadcn:."

// Column widths and row heights come straight from out/web/<case>.json: they
// are what Chromium's automatic table layout and collapsed borders resolved to.
//
// The rules sit a quarter pixel above the row boundary (39.25 rather than
// 39.5). The collapsed border is centred on the boundary, which puts it on a
// quarter pixel once the capture's 0.75 crop offset is added; Chromium snaps a
// painted hairline to the device pixel grid, so it lands wholly in one row.
// palmy antialiases instead, and the quarter pixel is that snap.
@(init)
register_table_cases :: proc "contextless" () {
	add_case("table-default", proc(ui: ^p.Ctx) {
		W1, W2, W3 :: f32(156.63), f32(162.609375), f32(160.765625)
		sc.table_open(ui, "w-[480]")

		sc.table_row_open(ui, 40)
		sc.table_head(ui, "Invoice", W1)
		sc.table_head(ui, "Status", W2)
		sc.table_head(ui, "Amount", W3, true)
		sc.table_row_end(ui)

		sc.table_row_open(ui, 37)
		sc.table_data(ui, "INV001", W1)
		sc.table_data(ui, "Paid", W2)
		sc.table_data(ui, "250.00", W3, true)
		sc.table_row_end(ui)

		sc.table_row_open(ui, 37)
		sc.table_data(ui, "INV002", W1)
		sc.table_data(ui, "Pending", W2)
		sc.table_data(ui, "150.00", W3, true)
		sc.table_row_end(ui)

		sc.table_row_open(ui, 36.5)
		sc.table_data(ui, "INV003", W1)
		sc.table_data(ui, "Unpaid", W2)
		sc.table_data(ui, "350.00", W3, true)
		sc.table_row_end(ui)

		sc.table_rule(ui, 39.25)
		sc.table_rule(ui, 76.25)
		sc.table_rule(ui, 113.25)
		sc.table_end(ui)
	})

	add_case("table-footer", proc(ui: ^p.Ctx) {
		W1, W2 :: f32(236.890625), f32(243.109375)
		sc.table_open(ui, "w-[480]")

		sc.table_row_open(ui, 40)
		sc.table_head(ui, "Invoice", W1)
		sc.table_head(ui, "Amount", W2, true)
		sc.table_row_end(ui)

		sc.table_row_open(ui, 37)
		sc.table_data(ui, "INV001", W1)
		sc.table_data(ui, "250.00", W2, true)
		sc.table_row_end(ui)

		// `data-[state=selected]:bg-muted`
		sc.table_row_open(ui, 37, "bg-muted")
		sc.table_data(ui, "INV002", W1)
		sc.table_data(ui, "150.00", W2, true)
		sc.table_row_end(ui)

		// <tfoot>: `border-t bg-muted/50 font-medium`
		sc.table_row_open(ui, 36.5, "bg-muted/50 font-medium")
		sc.table_data(ui, "Total", W1)
		sc.table_data(ui, "400.00", W2, true)
		sc.table_row_end(ui)

		sc.table_rule(ui, 39.25)
		sc.table_rule(ui, 76.25)
		sc.table_rule(ui, 113.25)

		sc.table_caption(ui, "A list of recent invoices.")
		sc.table_end(ui)
	})
}
