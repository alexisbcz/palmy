// The shortest path from Odin to lit pixels on a Wayland surface.
//
// No layout, no widgets: `direct_frames` hands you the compositor's shared
// memory buffer every vsync and presents whatever you wrote into it.
package main

import "core:fmt"
import "core:math"
import "core:os"
import p "../../palmy"

main :: proc() {
	app, err := p.create({title = "palmy · pixels", width = 720, height = 480})
	if err != "" {
		fmt.eprintfln("palmy: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	for c in p.direct_frames(app) {
		t := p.app_elapsed(app)
		m := p.pointer(app)
		sc := c.scale

		// A plasma, written one pixel at a time straight into the window.
		for y in 0 ..< c.h {
			fy := f32(y) / sc
			row := c.px[y * c.w:][:c.w]
			for x in 0 ..< c.w {
				fx := f32(x) / sc

				v := math.sin(fx * 0.015 + t)
				v += math.sin((fy * 0.017) + t * 1.3)
				v += math.sin((fx + fy) * 0.011 + t * 0.7)

				// A ripple centred on the pointer.
				dx := fx - m.x
				dy := fy - m.y
				d := math.sqrt(dx * dx + dy * dy)
				v += math.sin(d * 0.05 - t * 3) * 1.2 / (1 + d * 0.01)

				v = v * 0.25 + 0.5
				row[x] = palette(v)
			}
		}

		// The drawing primitives work on the same buffer, so the UI layer's
		// shapes and text are available here too.
		p.fill_round_rect(c, {16 * sc, 16 * sc, 220 * sc, 34 * sc}, {8 * sc, 8 * sc, 8 * sc, 8 * sc}, {0, 0, 0, 120})
		p.draw_text(
			c,
			&app.fonts,
			fmt.tprintf("%.0f fps · %d x %d @%.0fx", p.frames_per_second(&app.ctx), c.w, c.h, sc),
			28 * sc,
			38 * sc,
			14 * sc,
			p.WHITE,
		)

		if p.pressed_key(app, p.KEY_ESCAPE) {
			p.quit_app(app)
		}
	}
}

// palette maps 0..1 to a smooth cosine gradient, packed as 0x00RRGGBB.
palette :: proc(t: f32) -> u32 {
	ch :: proc(t, phase: f32) -> u32 {
		v := 0.5 + 0.5 * math.cos(6.28318 * (t + phase))
		return u32(clamp(v, 0, 1) * 255)
	}
	return 0xff00_0000 | (ch(t, 0.0) << 16) | (ch(t, 0.33) << 8) | ch(t, 0.67)
}
