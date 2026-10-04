package main

// Everything that reads the filesystem: finding the images next to the one you
// opened, sniffing the real container format from the bytes rather than the
// extension, and formatting the numbers a properties panel shows.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import p "palmy:."

// Shot is one image file in the folder being browsed. Nothing here decodes
// anything: the dimensions arrive later, from the loader thread.
Shot :: struct {
	path:   string,
	name:   string,
	size:   i64,
	mtime:  time.Time,
	// Filled in once the header has been read.
	w, h:   int,
	ch:     int,
	format: string,
	probed: bool,
	broken: bool,
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

dir_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i > 0 {
		return path[:i]
	}
	if strings.has_prefix(path, "/") {
		return "/"
	}
	return "."
}

base_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

ext_of :: proc(path: string) -> string {
	name := base_of(path)
	if i := strings.last_index_byte(name, '.'); i > 0 {
		return strings.to_lower(name[i + 1:], context.temp_allocator)
	}
	return ""
}

// scan_dir lists every image in a directory, name-sorted the way a file
// manager would show it, so "next" means what the eye expects.
scan_dir :: proc(dir: string, allocator := context.allocator) -> []Shot {
	out := make([dynamic]Shot, allocator)
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for fi in infos {
		if fi.type == .Directory {
			continue
		}
		if !p.is_image_path(fi.name) {
			continue
		}
		append(
			&out,
			Shot {
				path = strings.clone(fi.fullpath, allocator),
				name = strings.clone(fi.name, allocator),
				size = fi.size,
				mtime = fi.modification_time,
			},
		)
	}
	slice.sort_by(out[:], proc(a, b: Shot) -> bool {
		return natural_less(a.name, b.name)
	})
	return out[:]
}

// natural_less compares names with runs of digits read as numbers, so
// `shot-9.png` sorts before `shot-10.png`.
natural_less :: proc(a, b: string) -> bool {
	la := strings.to_lower(a, context.temp_allocator)
	lb := strings.to_lower(b, context.temp_allocator)
	i, j := 0, 0
	for i < len(la) && j < len(lb) {
		da := la[i] >= '0' && la[i] <= '9'
		db := lb[j] >= '0' && lb[j] <= '9'
		if da && db {
			i0, j0 := i, j
			for i < len(la) && la[i] >= '0' && la[i] <= '9' {i += 1}
			for j < len(lb) && lb[j] >= '0' && lb[j] <= '9' {j += 1}
			na := strings.trim_left(la[i0:i], "0")
			nb := strings.trim_left(lb[j0:j], "0")
			if len(na) != len(nb) {
				return len(na) < len(nb)
			}
			if na != nb {
				return na < nb
			}
			continue
		}
		if la[i] != lb[j] {
			return la[i] < lb[j]
		}
		i += 1
		j += 1
	}
	return len(la) - i < len(lb) - j
}

// ---------------------------------------------------------------------------
// Format sniffing
//
// The extension is a claim, not a fact — a .png that is really a JPEG opens
// fine through stb_image and should say so in the properties panel. These are
// the magic numbers for everything stb decodes.
// ---------------------------------------------------------------------------

sniff_format :: proc(path: string) -> string {
	f, err := os.open(path)
	if err != nil {
		return ""
	}
	defer os.close(f)
	buf: [32]u8
	n, rerr := os.read(f, buf[:])
	if rerr != nil || n < 4 {
		return ""
	}
	b := buf[:n]

	has :: proc(b: []u8, sig: []u8) -> bool {
		if len(b) < len(sig) {
			return false
		}
		for i in 0 ..< len(sig) {
			if b[i] != sig[i] {
				return false
			}
		}
		return true
	}

	switch {
	case has(b, {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}):
		return "PNG"
	case has(b, {0xff, 0xd8, 0xff}):
		return "JPEG"
	case has(b, {'G', 'I', 'F', '8'}):
		return "GIF"
	case has(b, {'B', 'M'}):
		return "BMP"
	case has(b, {'8', 'B', 'P', 'S'}):
		return "PSD"
	case has(b, {'#', '?', 'R', 'A', 'D'}):
		return "Radiance HDR"
	case n >= 2 && b[0] == 'P' && b[1] >= '1' && b[1] <= '6':
		return "Netpbm"
	case n >= 12 && has(b[8:], {'W', 'E', 'B', 'P'}):
		return "WebP"
	case n >= 18 && (b[2] == 2 || b[2] == 3 || b[2] == 10 || b[2] == 11):
		// Targa has no magic; the image-type byte is the only hint.
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".tga") {
			return "TGA"
		}
	}
	return ""
}

// probe fills in what can be known without decoding the pixels.
probe :: proc(s: ^Shot) {
	if s.probed {
		return
	}
	s.probed = true
	s.format = sniff_format(s.path)
	w, h, ch, ok := p.image_size(s.path)
	if !ok {
		s.broken = true
		return
	}
	s.w, s.h, s.ch = w, h, ch
	if s.format == "" {
		s.format = strings.to_upper(ext_of(s.path), context.allocator)
	}
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

human_bytes :: proc(n: i64) -> string {
	f := f64(n)
	switch {
	case n < 1024:
		return fmt.tprintf("%d B", n)
	case n < 1024 * 1024:
		return fmt.tprintf("%.1f KB", f / 1024)
	case n < 1024 * 1024 * 1024:
		return fmt.tprintf("%.1f MB", f / (1024 * 1024))
	}
	return fmt.tprintf("%.2f GB", f / (1024 * 1024 * 1024))
}

human_pixels :: proc(w, h: int) -> string {
	mp := f64(w) * f64(h) / 1e6
	if mp < 0.1 {
		return fmt.tprintf("%d × %d", w, h)
	}
	return fmt.tprintf("%d × %d  ·  %.1f MP", w, h, mp)
}

channels_label :: proc(ch: int) -> string {
	switch ch {
	case 1:
		return "1 · grey"
	case 2:
		return "2 · grey + alpha"
	case 3:
		return "3 · RGB"
	case 4:
		return "4 · RGBA"
	}
	return fmt.tprintf("%d", ch)
}

human_time :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, _ := time.clock_from_time(t)
	MONTHS := [?]string {
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	}
	m := int(mo)
	name := m >= 1 && m <= 12 ? MONTHS[m - 1] : "?"
	return fmt.tprintf("%d %s %d, %02d:%02d", d, name, y, h, mi)
}

aspect_label :: proc(w, h: int) -> string {
	if w <= 0 || h <= 0 {
		return "—"
	}
	g := gcd(w, h)
	aw, ah := w / g, h / g
	if aw <= 64 && ah <= 64 {
		return fmt.tprintf("%d:%d", aw, ah)
	}
	return fmt.tprintf("%.3f:1", f64(w) / f64(h))
}

gcd :: proc(a, b: int) -> int {
	x, y := a, b
	for y != 0 {
		x, y = y, x % y
	}
	return max(1, x)
}

// shorten keeps the tail of a long path, which is the half that identifies it.
shorten :: proc(path: string, keep: int) -> string {
	if len(path) <= keep {
		return path
	}
	return fmt.tprintf("…%s", path[len(path) - keep + 1:])
}

home_relative :: proc(path: string) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err == nil && strings.has_prefix(path, home) {
		return fmt.tprintf("~%s", path[len(home):])
	}
	return path
}
