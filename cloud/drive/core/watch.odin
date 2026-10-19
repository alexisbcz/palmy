// inotify, used as a doorbell and nothing more.
//
// The watcher does not try to turn events into operations; it says "something
// under this tree changed" and the daemon runs a pass, which works out what
// from the files themselves. That is deliberately less clever than replaying
// events: inotify drops events under load (IN_Q_OVERFLOW), knows nothing of
// what happened while the daemon was stopped, and reports a rename as two
// halves that may straddle a read. A pass is correct in all three cases; an
// event replayer is correct in none of them without a rescan anyway.
package drivecore

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

Watcher :: struct {
	fd: linux.Fd,
}

watch_open :: proc() -> (w: Watcher, ok: bool) {
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE {
		return {}, false
	}
	w.fd = fd
	return w, true
}

WATCH_MASK :: linux.Inotify_Event_Mask{.CLOSE_WRITE, .CREATE, .DELETE, .MOVED_FROM, .MOVED_TO, .DELETE_SELF, .ATTRIB}

// watch_tree adds a watch on every directory under root that does not have
// one. Called after every pass, so folders a pass created are covered.
watch_tree :: proc(w: ^Watcher, root: string) {
	add :: proc(w: ^Watcher, dir: string) {
		cdir := strings.clone_to_cstring(dir, context.temp_allocator)
		linux.inotify_add_watch(w.fd, cdir, WATCH_MASK)
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for fi in entries {
			if fi.type == .Directory {
				add(w, fmt.tprintf("%s/%s", dir, fi.name))
			}
		}
	}
	// Re-add everything each time: adding a watch that exists is a no-op
	// for the kernel, and a folder deleted and re-created under the same
	// name is a new inode that needs a new watch.
	add(w, root)
}

// watch_wait blocks up to timeout_ms and reports whether anything changed,
// ignoring the sync's own temporary files. After the first event it keeps
// reading for `settle_ms` more, so a save that is a burst of events (write,
// rename, chmod) produces one pass rather than three.
watch_wait :: proc(w: ^Watcher, timeout_ms: i32, settle_ms: i32 = 400) -> (changed: bool) {
	fds := []linux.Poll_Fd{{fd = w.fd, events = {.IN}}}
	t := timeout_ms
	for {
		n, _ := linux.poll(fds, t)
		if n <= 0 {
			return changed
		}
		if drain(w) {
			changed = true
		}
		if changed {
			t = settle_ms
		}
	}
}

@(private)
drain :: proc(w: ^Watcher) -> bool {
	hit := false
	buf: [8192]u8
	for {
		n, err := linux.read(w.fd, buf[:])
		if err != .NONE || n <= 0 {
			break
		}
		i := 0
		for i + size_of(linux.Inotify_Event) <= n {
			ev := (^linux.Inotify_Event)(&buf[i])
			name := ""
			if ev.len > 0 {
				raw := buf[i + size_of(linux.Inotify_Event):][:ev.len]
				end := 0
				for end < len(raw) && raw[end] != 0 {
					end += 1
				}
				name = string(raw[:end])
			}
			if .Q_OVERFLOW in ev.mask {
				hit = true // lost events: a pass rescans everything anyway
			} else if !strings.has_prefix(name, TEMP_PREFIX) && .IGNORED not_in ev.mask {
				hit = true
			}
			i += size_of(linux.Inotify_Event) + int(ev.len)
		}
	}
	return hit
}

watch_close :: proc(w: ^Watcher) {
	linux.close(w.fd)
}
