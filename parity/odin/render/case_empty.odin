package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_empty_cases :: proc "contextless" () {
	add_case("empty-default", proc(ui: ^p.Ctx) {
		sc.empty_open(ui, "border border-border")
		sc.empty_header_open(ui)
		sc.empty_title(ui, "No projects")
		sc.empty_description(ui, "Create one to get started.")
		sc.empty_header_end(ui)
		sc.empty_content_open(ui)
		sc.button(ui, "New project", .Default, .SM)
		sc.empty_content_end(ui)
		sc.empty_end(ui)
	})
	add_case("empty-icon", proc(ui: ^p.Ctx) {
		sc.empty_open(ui, "border border-border")
		sc.empty_header_open(ui)
		sc.empty_media_icon(ui, sc.ICON_INBOX)
		sc.empty_title(ui, "Inbox is clear")
		sc.empty_description(ui, "Nothing left to read.")
		sc.empty_header_end(ui)
		sc.empty_end(ui)
	})
}
