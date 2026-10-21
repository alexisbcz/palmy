package main

// What the viewer writes: Ctrl-S, a copy of the picture as it is shown.

// save_copy encodes the decoded picture, turned by the viewer's rotation, to
// copy_path beside the original. Rotation is `rotated` and encoding `img_save`
// (core.odin), the two procedures `image rotate` runs.
save_copy :: proc(st: ^St) -> (out: string, ok: bool, why: string) {
	s := current_shot(st)
	if s == nil || !st.cur_ok || st.cur_idx != st.sel {
		return "", false, "the picture is not decoded yet"
	}
	img := display(st)
	out = copy_path(s.path, st.rot)
	ok, why = img_save(img, out)
	return
}
