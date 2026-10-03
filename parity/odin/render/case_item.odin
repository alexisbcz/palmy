package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_item_cases :: proc "contextless" () {
	add_case("item-default", proc(ui: ^p.Ctx) {
		sc.item_open(ui, .Default, .Default, "w-80")
		sc.item_media_icon(ui, sc.ICON_FOLDER)
		sc.item_content_open(ui)
		sc.item_title(ui, "Documents")
		sc.item_description(ui, "12 files")
		sc.item_content_end(ui)
		sc.item_actions_open(ui)
		sc.button_open(ui, .Ghost, .Icon_SM, sc.State{})
		p.icon(ui, sc.ICON_ARROW_RIGHT, "size-4")
		sc.button_end(ui)
		sc.item_actions_end(ui)
		sc.item_end(ui)
	})
	add_case("item-outline", proc(ui: ^p.Ctx) {
		sc.item_open(ui, .Outline, .Default, "w-80")
		sc.item_media_icon(ui, sc.ICON_FOLDER)
		sc.item_content_open(ui)
		sc.item_title(ui, "Documents")
		sc.item_description(ui, "12 files")
		sc.item_content_end(ui)
		sc.item_end(ui)
	})
	add_case("item-muted", proc(ui: ^p.Ctx) {
		sc.item_open(ui, .Muted, .Default, "w-80")
		sc.item_content_open(ui)
		sc.item_title(ui, "Documents")
		sc.item_description(ui, "12 files")
		sc.item_content_end(ui)
		sc.item_end(ui)
	})
	add_case("item-xs", proc(ui: ^p.Ctx) {
		sc.item_open(ui, .Outline, .XS, "w-80")
		sc.item_content_open(ui, .XS)
		sc.item_title(ui, "Documents")
		sc.item_description(ui, "12 files", .XS)
		sc.item_content_end(ui)
		sc.item_end(ui)
	})
}
