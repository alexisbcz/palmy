package drivecore

import "core:fmt"
import "core:strings"

// shared_ids is every item of this identity that has a live share or link,
// for the marker beside its name.
shared_ids :: proc(c: ^Client) -> (ids: map[string]bool, e: Error) {
	Row :: struct {
		item_id: string,
	}
	ids = make(map[string]bool)
	rows: []Row
	e = rest(c, "GET", fmt.tprintf("/drive_shares?identity_id=eq.%s&revoked_at=is.null&select=item_id", c.identity), "", &rows)
	for r in rows {
		ids[r.item_id] = true
	}
	links: []Row
	e2 := rest(c, "GET", fmt.tprintf("/drive_links?identity_id=eq.%s&revoked_at=is.null&select=item_id", c.identity), "", &links)
	for r in links {
		ids[r.item_id] = true
	}
	if failed(e2) {
		e = e2
	}
	return
}

// resolve_path walks a slash path from the root of this identity's drive.
// "" and "/" are the root, returned as an empty Item with ok set. With
// `trashed`, the last segment is looked for among trashed items.
resolve_path :: proc(c: ^Client, path: string, trashed := false) -> (it: Item, ok: bool, e: Error) {
	parent := ""
	cur := Item{}
	parts := strings.split(strings.trim(path, "/"), "/", context.temp_allocator)
	for part, i in parts {
		if part == "" {
			continue
		}
		last := i == len(parts) - 1
		kids: []Item
		kids, e = list_children(c, parent, trashed && last)
		if failed(e) {
			return {}, false, e
		}
		found := false
		for k in kids {
			if k.name == part {
				cur = k
				found = true
				break
			}
		}
		if !found {
			return {}, false, {}
		}
		parent = cur.id
	}
	return cur, true, {}
}

// human_size is a byte count the way a file browser says it.
human_size :: proc(n: i64) -> string {
	switch {
	case n < 1000:
		return fmt.tprintf("%d B", n)
	case n < 1000 * 1000:
		return fmt.tprintf("%.0f KB", f64(n) / 1000)
	case n < 1000 * 1000 * 1000:
		return fmt.tprintf("%.1f MB", f64(n) / 1e6)
	}
	return fmt.tprintf("%.2f GB", f64(n) / 1e9)
}

// app_for names the Palmframe application that opens a file, by extension.
// "" means none of ours does; the caller falls back to xdg-open.
app_for :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 {
		return ""
	}
	switch strings.to_lower(name[dot + 1:], context.temp_allocator) {
	case "docx", "odt", "rtf", "doc", "md", "txt":
		return "docs"
	case "xlsx", "xls", "ods", "csv", "tsv":
		return "sheets"
	case "pptx", "odp", "ppt":
		return "slides"
	case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tga":
		return "image"
	case "mp4", "webm", "mkv", "mov", "avi":
		return "video"
	case "pdf", "epub":
		return "reader"
	}
	return ""
}
