package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_command_cases :: proc "contextless" () {
	add_case("command-default", proc(ui: ^p.Ctx) {
		sc.command_open(ui, true)
		defer p.end(ui)

		sc.command_input(ui, "Type a command")

		sc.command_list_open(ui)
		defer p.end(ui)

		sc.command_group_open(ui)
		sc.command_group_heading(ui, "Suggestions")
		sc.command_items_open(ui)

		sc.command_item_open(ui, true)
		p.icon(ui, sc.ICON_CALENDAR, "size-4 shrink-0")
		sc.command_item_text(ui, "Calendar")
		p.end(ui)

		sc.command_item_open(ui)
		p.icon(ui, sc.ICON_MAIL, "size-4 shrink-0")
		sc.command_item_text(ui, "Mail")
		p.end(ui)

		p.end(ui)
		p.end(ui)

		sc.command_separator(ui)

		sc.command_group_open(ui)
		sc.command_group_heading(ui, "Settings")
		sc.command_items_open(ui)

		sc.command_item_open(ui)
		p.icon(ui, sc.ICON_USER, "size-4 shrink-0")
		sc.command_item_text(ui, "Profile")
		sc.command_shortcut(ui, "P")
		p.end(ui)

		p.end(ui)
		p.end(ui)
	})

	add_case("command-dialog", proc(ui: ^p.Ctx) {
		// Inside the dialog the palette has no ring of its own and inherits
		// `text-sm`; its items take the dialog's 10px radius.
		idx := sc.command_open(ui, false)
		p.apply(ui, "text-sm", idx)
		defer p.end(ui)

		sc.command_input(ui, "Type a command")

		sc.command_list_open(ui)
		defer p.end(ui)

		sc.command_group_open(ui)
		defer p.end(ui)

		sc.command_group_heading(ui, "Suggestions")
		sc.command_items_open(ui)
		defer p.end(ui)

		sc.command_item_open(ui, true, true)
		p.icon(ui, sc.ICON_CALENDAR, "size-4 shrink-0")
		sc.command_item_text(ui, "Calendar")
		p.end(ui)

		sc.command_item_open(ui, false, true)
		p.icon(ui, sc.ICON_TERMINAL, "size-4 shrink-0")
		sc.command_item_text(ui, "Terminal")
		sc.command_shortcut(ui, "T")
		p.end(ui)
	})
}
