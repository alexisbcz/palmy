package main

import p "palmy:."
import sc "shadcn:."

@(init)
register_attachment_cases :: proc "contextless" () {
	add_case("attachment-default", proc(ui: ^p.Ctx) {
		a := sc.Attachment{width = 165.359, title_up = 1}
		sc.attachment_open(ui, a) // cropOffset x 0.313 is left alone: see pixel_snap
		sc.attachment_media(ui, a, sc.ICON_FILE_TEXT)
		sc.attachment_content(ui, a, "report.pdf", "248 KB")
		sc.attachment_actions(ui, sc.ICON_TRASH)
		sc.attachment_end(ui)
	})
	add_case("attachment-sm", proc(ui: ^p.Ctx) {
		a := sc.Attachment{size = .SM, width = 160, title_up = 1, desc_up = 1}
		pixel_snap(ui, sc.attachment_open(ui, a), 0.5)
		sc.attachment_media(ui, a, sc.ICON_FILE_TEXT)
		sc.attachment_content(ui, a, "notes.txt", "12 KB")
		sc.attachment_end(ui)
	})
	add_case("attachment-xs", proc(ui: ^p.Ctx) {
		a := sc.Attachment{size = .XS, width = 160}
		sc.attachment_open(ui, a)
		sc.attachment_media(ui, a, sc.ICON_IMAGE)
		sc.attachment_content(ui, a, "cover.png", "")
		sc.attachment_end(ui)
	})
	add_case("attachment-vertical", proc(ui: ^p.Ctx) {
		a := sc.Attachment{vertical = true, width = 120, title_up = 1}
		pixel_snap(ui, sc.attachment_open(ui, a), 0.25)
		sc.attachment_media(ui, a, sc.ICON_IMAGE)
		sc.attachment_content(ui, a, "cover.png", "1.2 MB")
		sc.attachment_end(ui)
	})
	add_case("attachment-error", proc(ui: ^p.Ctx) {
		a := sc.Attachment{state = .Error, width = 160, title_up = 1}
		sc.attachment_open(ui, a)
		sc.attachment_media(ui, a, sc.ICON_TRIANGLE_ALERT)
		sc.attachment_content(ui, a, "huge.zip", "Upload failed")
		sc.attachment_end(ui)
	})
}
