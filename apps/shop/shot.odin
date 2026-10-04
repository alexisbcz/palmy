// `shop --shots <dir>`: render the interface offscreen and write PNGs.
//
// The same `measure`, `handle_keys` and `frame` the window runs, through
// palmy's offscreen renderer — no compositor, no window, and still no network
// of any kind. The catalogue is the generated fixture, as it is everywhere
// else in this binary, and the basket and list are written into a private
// directory under the output directory rather than into the real store.
//
// `--uitest` next door does the same thing at much greater length, with the
// frame-cost benchmarks and the whole walkthrough. This is the short one,
// whose first file is the representative frame.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1440
SHOT_H :: 900

@(private = "file")
load_shot_fonts :: proc(off: ^p.Offscreen) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in MONO_FONTS {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
}

run_shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("shop --shots: impossible de créer %s", dir)
		return 1
	}

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	load_shot_fonts(off)

	st := new(State)
	state_init(st)
	// Nothing of the user's is read, and nothing of the user's is written.
	clear(&st.basket)
	clear(&st.list)
	clear(&st.alerts)
	delete(st.data_dir)
	st.data_dir = strings.clone(fmt.tprintf("%s/.store/palmy-shop", dir))
	_ = os.make_directory_all(st.data_dir, os.perm(0o700))

	step :: proc(off: ^p.Offscreen, st: ^State) {
		ui := p.offscreen_begin(off)
		measure(ui, st)
		handle_keys(ui, st, nil)
		frame(ui, st)
		p.offscreen_end(off)
	}

	// Hover and hit testing run against the previous frame, so the settled
	// picture is never the first one.
	settle :: proc(off: ^p.Offscreen, st: ^State, n := 3) {
		for _ in 0 ..< n {
			step(off, st)
		}
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		path := fmt.tprintf("%s/%s", dir, name)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  impossible d'écrire %s", path)
		}
	}

	// The catalogue, which is the application's front door: the result list,
	// the filters and the detail panel of the selected product.
	set_view(st, .Catalogue)
	st.sel = 0
	settle(off, st)
	shot(off, dir, "app-shop.png", &n)

	// The same product between chains, compared on its price per litre.
	target := -1
	for pr, i in st.cat.products {
		if pr.brand == "Lactel" && strings.contains(pr.title, "demi-écrémé") && pr.qty.count == 1 {
			target = i
			break
		}
	}
	if target >= 0 {
		st.compare_of = target
		set_view(st, .Compare)
		settle(off, st)
		shot(off, dir, "02-shop-comparer.png", &n)
		set_view(st, .Catalogue)
	}

	// A basket across several TVA rates, with the breakdown.
	added := 0
	rates := [Tva]bool{}
	for pr, i in st.cat.products {
		if pr.avail != .In_Stock {
			continue
		}
		if rates[pr.tva] && added >= 3 {
			continue
		}
		rates[pr.tva] = true
		basket_add(st, i, added == 0 ? 3 : 1)
		added += 1
		if added >= 6 {
			break
		}
	}
	set_view(st, .Basket)
	settle(off, st)
	shot(off, dir, "03-shop-panier.png", &n)

	// A Nutri-Score, with the points that produced it.
	set_view(st, .Catalogue)
	clear(&st.query)
	append(&st.query, ..transmute([]u8)string("cola 1,5"))
	refilter(st)
	st.sel = 0
	settle(off, st)
	shot(off, dir, "04-shop-nutriscore.png", &n)
	clear(&st.query)
	refilter(st)

	fmt.printfln("shop --shots: %d PNG dans %s", n, dir)
	return 0
}
