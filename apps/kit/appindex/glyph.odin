package appindex

import "core:strings"
import p "palmy:."

// icon_for picks an entry's glyph: the lucide icon its Icon= line names
// (Palmy's own .desktop files name one), then a few names recognisable
// enough to deserve their own, then the category.
icon_for :: proc(e: ^Entry) -> p.Icon {
	if ic, ok := icon_named(e.icon); ok {
		return ic
	}
	// Palmy's own entries that name themselves (Icon=mixer) rather than
	// a lucide glyph.
	for a in ICON_ALIASES {
		if a.name == e.icon || (e.icon == "" && a.name == exec_name(e)) {
			if ic, ok := icon_named(a.lucide); ok {
				return ic
			}
		}
	}
	n := e.lower
	switch {
	case has_any(n, "terminal", "console", "ghostty", "foot", "alacritty", "kitty"):
		return ICON_SQUARE_TERMINAL
	case has_any(n, "files", "nautilus", "thunar", "dolphin", "nemo"):
		return ICON_FOLDER
	case has_any(n, "browser", "firefox", "chromium", "chrome", "web"):
		return ICON_GLOBE
	case has_any(n, "mail", "thunderbird"):
		return ICON_MAIL
	case has_any(n, "music", "spotify", "audio", "rhythmbox"):
		return ICON_MUSIC
	case has_any(n, "calculator", "calc"):
		return ICON_CALCULATOR
	case has_any(n, "monitor", "system", "htop", "btop", "task"):
		return ICON_ACTIVITY
	case has_any(n, "image", "photo", "picture", "gimp", "viewer"):
		return ICON_IMAGE
	case has_any(n, "keyboard", "input"):
		return ICON_KEYBOARD
	case has_any(n, "network", "wifi"):
		return ICON_WIFI
	case has_any(n, "bluetooth"):
		return ICON_BLUETOOTH
	case has_any(n, "settings", "preferences", "control"):
		return ICON_SETTINGS
	case has_any(n, "color", "theme", "appearance", "wallpaper"):
		return ICON_PALETTE
	case has_any(n, "code", "editor", "vim", "studio"):
		return ICON_CODE
	}
	switch e.cat {
	case .Dev:
		return ICON_CODE
	case .Web:
		return ICON_GLOBE
	case .Media:
		return ICON_CLAPPERBOARD
	case .Office:
		return ICON_BOOK_OPEN
	case .System:
		return ICON_SETTINGS
	case .Utility:
		return ICON_LAYOUT_GRID
	case .Game:
		return ICON_SPARKLES
	case .Demo:
		return ICON_SPARKLES
	case .Other:
		return ICON_PACKAGE
	}
	return ICON_PACKAGE
}

// ICON_ALIASES maps the names Palmy's applications go by to the lucide
// glyph that stands for them.
ICON_ALIASES := [?]struct {
	name, lucide: string,
} {
	{"ai", "bot"},
	{"audio", "music"},
	{"call", "phone"},
	{"mixer", "volume-2"},
	{"vault", "key-round"},
	{"video", "clapperboard"},
	{"videoedit", "scissors"},
	{"calc", "calculator"},
	{"docs", "file-text"},
	{"editor", "code"},
	{"files", "folder"},
	{"launcher", "layout-grid"},
	{"maps", "map-pin"},
	{"money", "wallet"},
	{"notes", "notebook-pen"},
	{"photoshop", "palette"},
	{"reader", "book-open"},
	{"sheets", "file-spreadsheet"},
	{"slides", "presentation"},
	{"store", "store"},
	{"sysmon", "activity"},
	{"term", "square-terminal"},
	{"torrent", "download"},
	{"chat", "message-circle"},
	{"contacts", "contact"},
	{"accounts", "circle-user"},
	{"forge", "anvil"},
	{"home", "house"},
	{"browser", "globe"},
	{"settings", "settings"},
	{"power", "battery"},
	{"ocr", "scan-text"},
	{"colorpick", "pipette"},
	{"track", "flag"},
	{"emoji", "sparkles"},
	{"drive", "hard-drive"},
	{"network", "wifi"},
	{"screenshot", "camera"},
	{"captions", "captions"},
}

// hue_for is a stable tile colour per entry, from the same eight hues the
// window manager tints its monograms with, so an app's tile in the start
// menu and its icon in the taskbar agree.
HUES :: [8]u32{0x6366f1, 0x0ea5e9, 0x10b981, 0xf59e0b, 0xef4444, 0xa855f7, 0x14b8a6, 0xec4899}

hue_for :: proc(key: string) -> u32 {
	h: u32 = 2166136261
	for b in transmute([]u8)key {
		h = (h ~ u32(b)) * 16777619
	}
	hues := HUES
	return hues[h % len(hues)]
}

has_any :: proc(s: string, needles: ..string) -> bool {
	for n in needles {
		if strings.contains(s, n) {
			return true
		}
	}
	return false
}
