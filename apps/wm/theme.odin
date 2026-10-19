// theme.odin — the shell's two looks, dark and light, and its accent.
//
// Everything the compositor draws itself that a person reads — the bar, the
// title bars, the menus, the start menu, tooltips and toasts — takes its
// colours from `pal`, which `pal_apply` fills from two lines of wm.conf:
//
//     theme  = dark | light
//     accent = #6366f1
//
// The dark values are the ones the shell has always had (UX.md P0-9), so a
// config without these lines draws exactly what it drew before. The light
// values are shadcn's neutral light theme, the one every palmy app opens in,
// so a light shell and a light window look like one system. Overlays that sit
// on a dimmed desktop (the overview, the switcher, the cheat sheet) stay dark
// in both: they are drawn over a scrim, not beside the windows.
//
// The accent tints the current workspace, the focus ring, selections and
// checks. Settings writes both lines; the config reload applies them within
// a second, without restarting anything.
package wm

Shell_Pal :: struct {
	dark:         bool,

	// The bar.
	bar_bg:       u32,
	bar_line:     u32,
	bar_text:     u32,
	bar_dim:      u32, // empty workspaces, secondary labels
	chip_line:    u32, // outlines of workspace and layout chips
	chip_hover:   u32,
	chip_fill:    u32, // the layout badge's rest fill
	entry_focus:  u32, // the focused taskbar entry
	entry_text:   u32,

	// Title bars.
	frame_on:     u32,
	frame_off:    u32,
	frame_text_on:  u32,
	frame_text_off: u32,
	frame_rule_on:  u32, // the line under the title bar
	frame_rule_off: u32,
	frame_glyph:  u32,
	frame_btn_hover: u32, // translucent: 0xAARRGGBB
	frame_btn_down:  u32,

	// Menus, the start menu, tooltips, toasts.
	pop_bg:       u32,
	pop_line:     u32,
	pop_hover:    u32,
	pop_text:     u32,
	pop_dim:      u32, // shortcut text, captions
	pop_faint:    u32, // disabled items, placeholders
	pop_field:    u32, // the start menu's search field
	pop_section:  u32, // the start menu's footer band
	shadow:       u32, // 0xAARRGGBB

	// The accent and what is derived from it.
	accent:       u32,
	accent_soft:  u32, // a check mark, a pinned glyph: readable on pop_bg
	accent_wash:  u32, // occupied workspace fill
	accent_edge:  u32, // occupied workspace outline
	accent_text:  u32, // occupied workspace label
	on_accent:    u32, // text on an accent fill
}

pal: Shell_Pal

ACCENT_DEFAULT :: u32(0x6366f1)

// ACCENT is the accent in force. It used to be a constant; the places that
// read it did not need to change.
ACCENT: u32 = ACCENT_DEFAULT

// mix blends two 0xRRGGBB colours: t = 0 is a, t = 1 is b.
mix :: proc(a, b: u32, t: f32) -> u32 {
	ch :: proc(c: u32, sh: u32) -> f32 {return f32((c >> sh) & 0xff)}
	out: u32
	for sh in ([3]u32{16, 8, 0}) {
		v := ch(a, sh) * (1 - t) + ch(b, sh) * t
		out |= u32(clamp(v + 0.5, 0, 255)) << sh
	}
	return out
}

// luma is the perceived brightness of a colour, 0..1.
luma :: proc(c: u32) -> f32 {
	r := f32((c >> 16) & 0xff) / 255
	g := f32((c >> 8) & 0xff) / 255
	b := f32(c & 0xff) / 255
	return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

pal_apply :: proc(light: bool, accent: u32) {
	ACCENT = accent
	if light {
		pal = Shell_Pal {
			dark           = false,
			bar_bg         = 0xfafafa,
			bar_line       = 0xe4e4e7,
			bar_text       = 0x18181b,
			bar_dim        = 0xa1a1aa,
			chip_line      = 0xd4d4d8,
			chip_hover     = 0xf4f4f5,
			chip_fill      = 0xffffff,
			entry_focus    = 0xe4e4e7,
			entry_text     = 0x3f3f46,
			frame_on       = 0xf4f4f5,
			frame_off      = 0xfafafa,
			frame_text_on  = 0x18181b,
			frame_text_off = 0xa1a1aa,
			frame_rule_on  = 0xd4d4d8,
			frame_rule_off = 0xe4e4e7,
			frame_glyph    = 0x52525b,
			frame_btn_hover = 0x14000000,
			frame_btn_down = 0x24000000,
			pop_bg         = 0xffffff,
			pop_line       = 0xe4e4e7,
			pop_hover      = 0xf4f4f5,
			pop_text       = 0x09090b,
			pop_dim        = 0x71717a,
			pop_faint      = 0xa1a1aa,
			pop_field      = 0xf4f4f5,
			pop_section    = 0xfafafa,
			shadow         = 0x40000000,
		}
		pal.accent_soft = mix(accent, 0x000000, 0.15)
		pal.accent_wash = mix(accent, 0xffffff, 0.86)
		pal.accent_edge = mix(accent, 0xffffff, 0.45)
		pal.accent_text = mix(accent, 0x000000, 0.25)
	} else {
		pal = Shell_Pal {
			dark           = true,
			bar_bg         = 0x0a0a0c,
			bar_line       = 0x27272a,
			bar_text       = 0xfafafa,
			bar_dim        = 0x52525b,
			chip_line      = 0x27272a,
			chip_hover     = 0x1f1f23,
			chip_fill      = 0x18181b,
			entry_focus    = 0x27272a,
			entry_text     = 0xd4d4d8,
			frame_on       = 0x27272a,
			frame_off      = 0x18181b,
			frame_text_on  = 0xfafafa,
			frame_text_off = 0x71717a,
			frame_rule_on  = 0x3f3f46,
			frame_rule_off = 0x27272a,
			frame_glyph    = 0xa1a1aa,
			frame_btn_hover = 0x1affffff,
			frame_btn_down = 0x0dffffff,
			pop_bg         = 0x0f0f12,
			pop_line       = 0x27272a,
			pop_hover      = 0x27272a,
			pop_text       = 0xfafafa,
			pop_dim        = 0x71717a,
			pop_faint      = 0x52525b,
			pop_field      = 0x18181b,
			pop_section    = 0x0b0b0e,
			shadow         = 0x99000000,
		}
		pal.accent_soft = mix(accent, 0xffffff, 0.45)
		pal.accent_wash = mix(accent, 0x0a0a0c, 0.80)
		pal.accent_edge = mix(accent, 0x0a0a0c, 0.30)
		pal.accent_text = mix(accent, 0xffffff, 0.65)
	}
	pal.accent = accent
	pal.on_accent = luma(accent) > 0.6 ? 0x09090b : 0xffffff
}

@(init)
pal_init :: proc "contextless" () {
	// The dark look until a config says otherwise; pal_apply needs a
	// context, so the few fields the very first frame could read are set
	// by hand and the rest follow at config load.
	pal.dark = true
	pal.accent = ACCENT_DEFAULT
}
