// `browser shot`: the browser rendered offscreen -- no compositor, no window --
// with a real page from a real engine. Both engine hosts render without a
// display server (CEF with the headless ozone platform, Firefox into the Gecko
// host's private compositor), so this is the actual chrome around actual
// pixels, not a mock-up.
package browser

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

Shot_Options :: struct {
	out:        string,
	url:        string,
	dark:       bool,
	width:      int,
	height:     int,
	wait:       f64,
	engine:     Engine_Kind,
	engine_set: bool,
	omnibox:    string,
	overlay:    string,
}

Shot_Result :: struct {
	error:   string,
	engine:  string,
	version: string,
	frames:  int,
}

shot_fonts :: proc(off: ^p.Offscreen, dark: bool) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string{"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
}

shot :: proc(prof: ^Profile, opt: Shot_Options) -> (res: Shot_Result) {
	profile_ensure(prof)
	s := new(State)
	g_state = s
	state_init(s, prof^)
	s.headless = true
	s.dark = opt.dark
	if opt.engine_set {
		s.engine_kind = opt.engine
	}
	s.window_w = opt.width

	off := p.offscreen_create(opt.width, opt.height, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, opt.dark)

	step :: proc(off: ^p.Offscreen, s: ^State) {
		pump_engine(s)
		ui := p.offscreen_begin(off)
		frame(ui, s)
		p.offscreen_end(off)
	}

	// lay the window out once with a new tab, to learn the page area's size
	t := new_tab(s, PAGE_URLS[.New_Tab])
	step(off, s)
	step(off, s)
	{
		ui := p.offscreen_begin(off)
		frame(ui, s)
		r := p.rect_of(ui, s.page_id)
		p.offscreen_end(off)
		s.page_size = {int(r.w), int(r.h)}
	}

	url := opt.url == "" ? PAGE_URLS[.New_Tab] : opt.url
	_, internal := page_of_url(url)
	// the engine runs for internal pages too, so the chrome shows it running
	if engine_info(s.engine_kind).available {
		s.engine = engine_start(s.engine_kind, &s.prof, nil)
		if !s.engine.ok && !internal {
			res.error = s.engine.error
			return
		}
		engine_theme(s.engine, s.dark)
		res.engine = s.engine.name
		res.version = s.engine.version
	}
	if !internal {
		if s.engine == nil || !s.engine.ok {
			res.error = engine_info(s.engine_kind).detail
			return
		}
		u, _ := resolve_input(url, search_engine(s.prof.settings.search))
		navigate(s, t, u)
		set_focus(s, .Page)
		start := time.tick_now()
		loaded_at: time.Tick
		for time.tick_since(start) < 45 * time.Second {
			step(off, s)
			surf := surface_of(s.engine, t.id)
			if !t.loading && surf.frames > 0 && (t.title != "" || t.error.active) {
				if loaded_at == {} {
					loaded_at = time.tick_now()
				}
				if time.duration_seconds(time.tick_since(loaded_at)) >= opt.wait {
					break
				}
			}
			time.sleep(40 * time.Millisecond)
		}
		res.frames = surface_of(s.engine, t.id).frames
		if res.frames == 0 {
			res.error = strings.clone("the engine produced no frame within 45 s")
		}
	} else {
		navigate(s, t, url)
		set_focus(s, .None)
		if res.engine == "" {
			res.engine = engine_name(s.engine_kind)
		}
	}

	if opt.omnibox != "" {
		focus_omnibox(s, false)
		edit_set(&s.omni, opt.omnibox)
		build_suggestions(s)
		s.omni_open = len(s.suggestions) > 0
	}
	switch opt.overlay {
	case "menu":
		s.overlay = .App_Menu
		s.menu_sel = 1
	case "identity":
		s.overlay = .Identity_Menu
	case "bookmark":
		if t.page == .Web && t.url != "" {
			toggle_bookmark(s)
		}
	case "downloads":
		s.overlay = .Downloads
	case "shortcuts":
		s.overlay = .Shortcuts
	}
	// transitions run on the clock, so let them finish
	for _ in 0 ..< 10 {
		step(off, s)
		time.sleep(60 * time.Millisecond)
	}
	if !p.offscreen_write_png(off, opt.out) {
		res.error = fmt.aprintf("could not write %s", opt.out)
	}
	if s.engine != nil {
		engine_stop(s.engine)
	}
	return
}

// kit_parse_array turns the window's tab snapshot back into kit JSON.
kit_parse_array :: proc(text: string) -> (^kit.Json, bool) {
	Row :: struct {
		url:     string,
		title:   string,
		active:  bool,
		loading: bool,
	}
	rows: []Row
	if json.unmarshal(transmute([]u8)text, &rows, allocator = context.temp_allocator) != nil {
		return nil, false
	}
	arr := kit.jarr()
	for r in rows {
		o := kit.jobj()
		kit.jset_str(o, "url", r.url)
		kit.jset_str(o, "title", r.title)
		kit.jset_bool(o, "active", r.active)
		kit.jset_bool(o, "loading", r.loading)
		kit.jpush(arr, o)
	}
	return arr, true
}
