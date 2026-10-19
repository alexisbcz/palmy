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

// paths_of is the slash path from the drive root of each item, by id, the
// way resolve_path reads it back ("Q3 Board pack/deck.pptx"). One request
// per level of folders above the items, not one per item: the ancestors
// not yet known are asked for together. A path whose ancestor cannot be
// read (or a cycle, which the database forbids) stops at what is known.
paths_of :: proc(c: ^Client, items: []Item, allocator := context.allocator) -> (paths: map[string]string, e: Error) {
	Row :: struct {
		id:        string,
		parent_id: string,
		name:      string,
	}
	known := make(map[string]Row, len(items) * 2, context.temp_allocator)
	for it in items {
		known[it.id] = {it.id, it.parent_id, it.name}
	}
	for _ in 0 ..< 64 {
		want := make([dynamic]string, context.temp_allocator)
		seen := make(map[string]bool, 16, context.temp_allocator)
		for _, r in known {
			if r.parent_id != "" && !(r.parent_id in known) && !seen[r.parent_id] {
				seen[r.parent_id] = true
				append(&want, r.parent_id)
			}
		}
		if len(want) == 0 {
			break
		}
		rows: []Row
		e = rest(c, "GET", fmt.tprintf("/drive_items?identity_id=eq.%s&id=in.(%s)&select=id,parent_id,name", c.identity, strings.join(want[:], ",", context.temp_allocator)), "", &rows)
		if failed(e) {
			break
		}
		if len(rows) == 0 {
			break
		}
		for r in rows {
			known[r.id] = r
		}
	}
	paths = make(map[string]string, len(items), allocator)
	for it in items {
		parts := make([dynamic]string, context.temp_allocator)
		cur, ok := known[it.id]
		for depth := 0; ok && depth < 64; depth += 1 {
			inject_at(&parts, 0, cur.name)
			if cur.parent_id == "" {break}
			cur, ok = known[cur.parent_id]
		}
		paths[it.id] = strings.join(parts[:], "/", allocator)
	}
	return
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

// app_for names the Palmy application that opens a file, by extension.
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
