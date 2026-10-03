// pixdiff — compare two PNGs and report how far apart they are.
//
//   pixdiff <a.png> <b.png> [--out diff.png] [--json]
//
// `a` is the reference (the browser), `b` is the candidate (palmy). The report
// covers mean absolute error, the share of pixels within tolerance, and the
// worst row, so a regression can be localised rather than just noticed.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import stbi "vendor:stb/image"

Image :: struct {
	px:   []u8, // RGBA
	w, h: int,
}

load_png :: proc(path: string) -> (img: Image, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data)

	w, h, comp: i32
	raw := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &comp, 4)
	if raw == nil {
		return {}, false
	}
	n := int(w) * int(h) * 4
	img.px = make([]u8, n)
	copy(img.px, raw[:n])
	img.w, img.h = int(w), int(h)
	stbi.image_free(raw)
	return img, true
}

// composite flattens RGBA onto white, which is what both sides are shown on.
@(private)
flatten :: proc(px: []u8, i: int) -> [3]f32 {
	a := f32(px[i + 3]) / 255
	out: [3]f32
	for c in 0 ..< 3 {
		out[c] = f32(px[i + c]) * a + 255 * (1 - a)
	}
	return out
}

Metrics :: struct {
	width, height:   int,
	size_match:      bool,
	mae:             f32, // mean absolute error, 0..255
	rmse:            f32,
	max_delta:       f32,
	within_2:        f32, // share of pixels whose worst channel is within 2
	within_8:        f32,
	within_16:       f32,
	changed_pixels:  int,
	worst_row:       int,
	worst_row_mae:   f32,
}

main :: proc() {
	args := os.args
	if len(args) < 3 {
		fmt.eprintln("usage: pixdiff <reference.png> <candidate.png> [--out diff.png] [--json]")
		os.exit(2)
	}

	out_path := ""
	as_json := false
	for i := 3; i < len(args); i += 1 {
		switch args[i] {
		case "--out":
			if i + 1 < len(args) {
				out_path = args[i + 1]
				i += 1
			}
		case "--json":
			as_json = true
		}
	}

	a, aok := load_png(args[1])
	if !aok {
		fmt.eprintfln("cannot read %s", args[1])
		os.exit(2)
	}
	b, bok := load_png(args[2])
	if !bok {
		fmt.eprintfln("cannot read %s", args[2])
		os.exit(2)
	}

	m: Metrics
	m.size_match = a.w == b.w && a.h == b.h
	w := min(a.w, b.w)
	h := min(a.h, b.h)
	m.width, m.height = w, h
	if w == 0 || h == 0 {
		fmt.eprintln("one of the images is empty")
		os.exit(2)
	}

	// The heat map is the candidate, dimmed, with differences lit up.
	heat := make([]u8, w * h * 4)

	total := f64(0)
	sq := f64(0)
	within2, within8, within16 := 0, 0, 0
	row_err := make([]f64, h)

	for y in 0 ..< h {
		for x in 0 ..< w {
			ia := (y * a.w + x) * 4
			ib := (y * b.w + x) * 4
			ca := flatten(a.px, ia)
			cb := flatten(b.px, ib)

			worst := f32(0)
			sum := f32(0)
			for c in 0 ..< 3 {
				d := abs(ca[c] - cb[c])
				worst = max(worst, d)
				sum += d
			}
			total += f64(sum / 3)
			sq += f64(sum / 3) * f64(sum / 3)
			row_err[y] += f64(sum / 3)
			m.max_delta = max(m.max_delta, worst)

			if worst <= 2 {within2 += 1}
			if worst <= 8 {within8 += 1}
			if worst <= 16 {within16 += 1}
			if worst > 2 {m.changed_pixels += 1}

			// Grey base, red where the candidate differs.
			o := (y * w + x) * 4
			grey := u8((cb[0] * 0.3 + cb[1] * 0.5 + cb[2] * 0.2) * 0.35 + 150)
			heat[o + 0] = grey
			heat[o + 1] = grey
			heat[o + 2] = grey
			heat[o + 3] = 255
			if worst > 2 {
				t := clamp(worst / 64, 0, 1)
				heat[o + 0] = u8(clamp(190 + t * 65, 0, 255))
				heat[o + 1] = u8(clamp(f32(grey) * (1 - t) * 0.5, 0, 255))
				heat[o + 2] = u8(clamp(f32(grey) * (1 - t) * 0.5, 0, 255))
			}
		}
	}

	n := f64(w * h)
	m.mae = f32(total / n)
	m.rmse = f32(math.sqrt(sq / n))
	m.within_2 = f32(f64(within2) / n * 100)
	m.within_8 = f32(f64(within8) / n * 100)
	m.within_16 = f32(f64(within16) / n * 100)

	worst := f64(0)
	for e, y in row_err {
		if e > worst {
			worst = e
			m.worst_row = y
		}
	}
	m.worst_row_mae = f32(worst / f64(w))

	if out_path != "" {
		write_report(out_path, a, b, heat, w, h)
	}

	if as_json {
		fmt.printfln(
			`{{"width":%d,"height":%d,"size_match":%v,"mae":%.4f,"rmse":%.4f,"max_delta":%.1f,` +
			`"within_2_pct":%.3f,"within_8_pct":%.3f,"within_16_pct":%.3f,"changed_pixels":%d,` +
			`"worst_row":%d,"worst_row_mae":%.3f}}`,
			m.width, m.height, m.size_match, m.mae, m.rmse, m.max_delta,
			m.within_2, m.within_8, m.within_16, m.changed_pixels, m.worst_row, m.worst_row_mae,
		)
	} else {
		if !m.size_match {
			fmt.printfln("SIZE MISMATCH: reference %dx%d, candidate %dx%d", a.w, a.h, b.w, b.h)
		}
		fmt.printfln("%dx%d  mae %.3f  rmse %.3f  max %.0f", m.width, m.height, m.mae, m.rmse, m.max_delta)
		fmt.printfln("within 2/255: %.2f%%   within 8/255: %.2f%%   within 16/255: %.2f%%",
			m.within_2, m.within_8, m.within_16)
		fmt.printfln("worst row %d (mae %.2f)", m.worst_row, m.worst_row_mae)
	}
}

// write_report lays reference, candidate and heat map side by side.
write_report :: proc(path: string, a, b: Image, heat: []u8, w, h: int) {
	pad :: 12
	total_w := w * 3 + pad * 4
	total_h := h + pad * 2
	canvas := make([]u8, total_w * total_h * 4)
	defer delete(canvas)

	for i := 0; i < len(canvas); i += 4 {
		canvas[i + 0] = 24
		canvas[i + 1] = 24
		canvas[i + 2] = 27
		canvas[i + 3] = 255
	}

	blit :: proc(dst: []u8, dw: int, src: []u8, sw, sh, x0, y0, copy_w, copy_h: int) {
		for y in 0 ..< copy_h {
			for x in 0 ..< copy_w {
				s := (y * sw + x) * 4
				d := ((y0 + y) * dw + (x0 + x)) * 4
				// Flatten onto white so transparent regions read correctly.
				al := f32(src[s + 3]) / 255
				for c in 0 ..< 3 {
					dst[d + c] = u8(f32(src[s + c]) * al + 255 * (1 - al))
				}
				dst[d + 3] = 255
			}
		}
	}

	blit(canvas, total_w, a.px, a.w, a.h, pad, pad, min(w, a.w), min(h, a.h))
	blit(canvas, total_w, b.px, b.w, b.h, pad * 2 + w, pad, min(w, b.w), min(h, b.h))
	blit(canvas, total_w, heat, w, h, pad * 3 + w * 2, pad, w, h)

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	stbi.write_png(cpath, i32(total_w), i32(total_h), 4, raw_data(canvas), i32(total_w * 4))
}
