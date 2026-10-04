package main

// Deskew: finding how crooked the page is, before anything tries to read it.
//
// This exists because of a measurement. Rendering the plain corpus page at a
// series of angles and running the whole pipeline over each one:
//
//     0.0°   CER  0.00%
//     1.5°   CER  0.00%
//     3.0°   CER  0.60%
//     5.0°   CER   100%        tesseract returned no words at all
//     8.0°   CER   100%
//
// The cliff at four or five degrees is not the line grouper giving up — the
// grouper chains locally and follows drift fine. It is tesseract: past about
// four degrees its own line finder fails and it returns an empty TSV. A page
// laid on a flatbed by hand is crooked by one to three degrees most of the
// time and by five or six often enough to matter, so without this the
// application simply fails on a page a person would call "slightly wonky".
//
// THE METHOD: a projection profile, which is the oldest trick in document
// imaging and still the right one here.
//
// Text on a straight page is horizontal bands of ink separated by horizontal
// bands of paper, so the count of ink pixels per row swings hard from row to
// row. Rotate the page and those bands smear across each other, and the swing
// flattens out. So: shear the ink by a candidate angle, build the per-row
// count, and score it by how much consecutive rows differ. The angle with the
// sharpest profile is the one that puts the text lines level.
//
// Three things make it cheap enough to run on every page:
//
//   * it works on a 1-bit ink mask downsampled by four, which is a hundredth
//     of the pixels and loses nothing — a text line is still tens of rows;
//   * shearing by `y - x·tan a` is one multiply per ink pixel and needs no
//     resampling, because the profile does not care about image quality;
//   * the search is coarse to fine: one degree across the range, then a tenth
//     of a degree around the winner.
//
// Only the final correcting rotation resamples, and only when the angle is
// worth correcting. A page within a third of a degree is left exactly alone:
// resampling costs sharpness, and sharpness is what the recogniser reads.

import "core:fmt"
import "core:math"
import "core:os"
import p "palmy:."

// Below this the page is straight enough that rotating it would lose more to
// resampling than it gains.
DESKEW_MIN :: f32(0.35)
// Past this, a page is not skewed, it is sideways, and a projection profile
// is the wrong instrument: that is an orientation problem for tesseract's own
// OSD, not a deskew.
DESKEW_MAX :: f32(12)
// The mask is built at a quarter scale in each direction.
DESKEW_SHRINK :: 4

Ink_Mask :: struct {
	bits: []u8, // 1 per pixel, 1 = ink
	w, h: int,
}

// ink_mask thresholds the page and shrinks it. The threshold is a fixed mid
// grey rather than an Otsu split: these are documents, the histogram is
// bimodal with a huge white mode, and the exact cut makes no difference to a
// profile that only cares where the lines are.
ink_mask :: proc(img: p.Image, allocator := context.temp_allocator) -> Ink_Mask {
	w := max(1, img.w / DESKEW_SHRINK)
	h := max(1, img.h / DESKEW_SHRINK)
	m := Ink_Mask {
		bits = make([]u8, w * h, allocator),
		w    = w,
		h    = h,
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			// Any dark pixel in the 4x4 block makes the cell ink. OR rather
			// than average, because a one-pixel stem must survive the shrink.
			hit := u8(0)
			for dy in 0 ..< DESKEW_SHRINK {
				sy := y * DESKEW_SHRINK + dy
				if sy >= img.h {
					break
				}
				row := img.px[sy * img.w:]
				for dx in 0 ..< DESKEW_SHRINK {
					sx := x * DESKEW_SHRINK + dx
					if sx >= img.w {
						break
					}
					v := row[sx]
					lum := (int((v >> 16) & 0xff) * 299 + int((v >> 8) & 0xff) * 587 + int(v & 0xff) * 114) / 1000
					if lum < 128 {
						hit = 1
					}
				}
			}
			m.bits[y * w + x] = hit
		}
	}
	return m
}

// profile_score shears the mask by `deg` and scores how sharply the row
// profile alternates between ink and paper.
//
// The score is the sum of squared differences between consecutive rows, not
// the variance of the rows themselves. Variance rewards a page with a dense
// block of text anywhere on it; the squared difference rewards *alternation*,
// which is what a stack of text lines is and what a smeared one is not.
profile_score :: proc(m: Ink_Mask, deg: f32) -> f64 {
	if m.w == 0 || m.h == 0 {
		return 0
	}
	t := math.tan(deg * math.PI / 180)
	// The shear moves rows by up to w·tan(a), so the profile needs room at
	// both ends or lines slide off it and the score drops for the wrong
	// reason.
	pad := int(math.abs(t) * f32(m.w)) + 2
	n := m.h + 2 * pad
	rows := make([]i32, n, context.temp_allocator)

	for y in 0 ..< m.h {
		row := m.bits[y * m.w:]
		for x in 0 ..< m.w {
			if row[x] == 0 {
				continue
			}
			ry := y + pad - int(f32(x) * t)
			if ry >= 0 && ry < n {
				rows[ry] += 1
			}
		}
	}
	score := f64(0)
	for i in 1 ..< n {
		d := f64(rows[i] - rows[i - 1])
		score += d * d
	}
	return score
}

// deskew_find returns the angle the page is rotated by, in degrees, positive
// meaning the text runs down to the right.
deskew_find :: proc(img: p.Image) -> (deg: f32, ok: bool) {
	m := ink_mask(img, context.temp_allocator)
	ink := 0
	for b in m.bits {
		ink += int(b)
	}
	// A blank page, or one that is nearly all ink (a photograph), has no line
	// structure to find and must not be rotated on the strength of noise.
	frac := f32(ink) / f32(max(1, m.w * m.h))
	if frac < 0.005 || frac > 0.6 {
		return 0, false
	}

	best := f32(0)
	best_score := profile_score(m, 0)
	// Coarse: one degree at a time across the whole range.
	for i := -int(DESKEW_MAX); i <= int(DESKEW_MAX); i += 1 {
		a := f32(i)
		s := profile_score(m, a)
		if s > best_score {
			best_score, best = s, a
		}
	}
	// Fine: a tenth of a degree either side of the winner.
	start := best
	for i := -10; i <= 10; i += 1 {
		a := start + f32(i) * 0.1
		if math.abs(a) > DESKEW_MAX {
			continue
		}
		s := profile_score(m, a)
		if s > best_score {
			best_score, best = s, a
		}
	}
	return best, math.abs(best) >= DESKEW_MIN
}

// deskew_page straightens `src` into `dst` when it is worth doing. It returns
// the angle it corrected and whether it wrote anything; when it returns false
// the caller must go on using the original file.
deskew_page :: proc(src, dst: string) -> (deg: f32, wrote: bool) {
	img, ok := p.load_image(src)
	if !ok {
		return 0, false
	}
	defer p.image_destroy(&img)

	angle, worth := deskew_find(img)
	if !worth {
		return angle, false
	}
	rgba := make([]u8, img.w * img.h * 4, context.temp_allocator)
	// Negative, because the page is rotated by `angle` and has to come back.
	rotate_into(img.px, img.w, img.h, -angle, rgba)
	if !p.write_png_rgba(dst, rgba, img.w, img.h) {
		return angle, false
	}
	return angle, true
}

// deskew_for is the pipeline's entry point: it returns the path to use for
// recognition, which is the original unless a straightened copy was worth
// making. The copy lives in the cache directory and the caller removes it.
deskew_for :: proc(src: string, page: int, allocator := context.allocator) -> (path: string, deg: f32, made: bool) {
	out := cache_path(fmt.tprintf("deskew-%d-%d.png", os.get_pid(), page), context.temp_allocator)
	angle, wrote := deskew_page(src, out)
	if !wrote {
		return src, angle, false
	}
	return fmt.aprintf("%s", out, allocator = allocator), angle, true
}
