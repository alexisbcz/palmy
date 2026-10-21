package main

// What the viewer writes: Ctrl-S, a copy of the picture as it is shown.

import "core:os"
import "core:strings"

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

// add_saved puts a file the viewer has just written into the folder's list, in
// the name order a rescan would give it, so the strip shows the copy at once.
// It does not rescan: the selection stays on the picture that was saved from,
// the decoded picture stays on screen, and every thumbnail already decoded is
// kept — only the new one is queued. Returns where it went, or -1 if it was
// already listed or is not in this folder.
add_saved :: proc(st: ^St, path: string) -> int {
	if len(st.shots) > 0 && dir_of(path) != dir_of(st.shots[0].path) {
		return -1
	}
	for s in st.shots {
		if s.path == path {
			return -1
		}
	}
	shot := Shot {
		path = strings.clone(path),
		name = strings.clone(base_of(path)),
	}
	if fi, err := os.stat(path, context.temp_allocator); err == nil {
		shot.size = fi.size
		shot.mtime = fi.modification_time
	}
	at := len(st.shots)
	for s, i in st.shots {
		if natural_less(shot.name, s.name) {
			at = i
			break
		}
	}
	// The old array is left alone, as open_folder leaves it: a self-test may
	// have built it from a literal.
	grown := make([]Shot, len(st.shots) + 1)
	copy(grown[:at], st.shots[:at])
	grown[at] = shot
	copy(grown[at + 1:], st.shots[at:])
	st.shots = grown

	bump :: proc(i: ^int, at: int) {
		if i^ >= at {i^ += 1}
	}
	bump(&st.sel, at)
	bump(&st.cur_idx, at)
	bump(&st.rot_of, at)
	if st.ld.thumbs != nil || st.ld.worker != nil {
		loader_insert(&st.ld, at, st.shots[at].path)
	}
	return at
}
