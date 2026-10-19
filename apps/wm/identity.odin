// identity.odin — who the start menu says this session belongs to.
//
// cloud/docs/shell.md proposes that the compositor, not the app, decides a
// window's identity, and that the bar carries a switcher. This file is the
// visible part that needs no cloud plumbing, with the seam where the rest
// will plug in:
//
//   - The current identity is what `accounts switch` last chose: the handle
//     in <cloud dir>/current (apps/cloudkit's token store: $PALM_CLOUD_DIR,
//     else $XDG_DATA_HOME/palm/cloud, else ~/.local/share/palm/cloud). Its
//     display name and colour come from the registry apps/accounts keeps at
//     $XDG_CONFIG_HOME/palmframe/identities.json — the same file the browser
//     reads for its profile colours.
//   - With no account on the machine it is the local user, by their passwd
//     name, and no colour: "no identity" is a state of its own (shell.md).
//   - The start menu draws it as a monogram and a name, and clicking it opens
//     the Accounts app, where switching happens today.
//
// What is left for the cloud work: launching with PALM_IDENTITY and a scoped
// token, recording pid -> identity at spawn (Client.pid is already read from
// SO_PEERCRED, main.odin), and tinting frames and taskbar entries from it.
package wm

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Shell_Identity :: struct {
	ok:      bool, // a Palmframe identity is current (else: the local user)
	handle:  string,
	name:    string,
	color:   u32, // 0 when there is none
	subtitle: string,
}

// IDENTITY_HUES are shell.md's palette, the dark-theme and light-theme value
// of each named colour.
@(private = "file")
IDENTITY_HUES := [?]struct {
	name:        string,
	light, dark: u32,
} {
	{"teal", 0x0f9488, 0x2dd4bf},
	{"blue", 0x2563eb, 0x60a5fa},
	{"amber", 0xc2620a, 0xfbbf24},
	{"violet", 0x7c3aed, 0xa78bfa},
	{"rose", 0xe11d48, 0xfb7185},
	{"emerald", 0x059669, 0x34d399},
	{"indigo", 0x4f46e5, 0x818cf8},
	{"slate", 0x475569, 0x94a3b8},
}

cloud_dir :: proc() -> string {
	if d := os.get_env("PALM_CLOUD_DIR", context.temp_allocator); d != "" {
		return d
	}
	if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" {
		return fmt.tprintf("%s/palm/cloud", x)
	}
	return fmt.tprintf("%s/.local/share/palm/cloud", os.get_env("HOME", context.temp_allocator))
}

// identity_parse_color reads "#rrggbb" or one of the palette's names.
identity_parse_color :: proc(s: string, dark: bool) -> u32 {
	t := strings.trim_space(s)
	if len(t) == 7 && t[0] == '#' {
		return cfg_color(t, 0)
	}
	for h in IDENTITY_HUES {
		if h.name == t {
			return dark ? h.dark : h.light
		}
	}
	return 0
}

// shell_identity reads the current identity, all in the temp allocator.
shell_identity :: proc() -> Shell_Identity {
	id: Shell_Identity
	if data, err := os.read_entire_file(fmt.tprintf("%s/current", cloud_dir()), context.temp_allocator); err == nil {
		id.handle = strings.trim_space(string(data))
	}
	if id.handle != "" {
		id.ok = true
		id.name = id.handle
		id.subtitle = "Switch identity"
		cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if cfg == "" {
			cfg = fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
		}
		if reg, rerr := os.read_entire_file(fmt.tprintf("%s/palmframe/identities.json", cfg), context.temp_allocator); rerr == nil {
			Entry :: struct {
				handle:       string,
				name:         string,
				display_name: string,
				color:        string,
			}
			entries: []Entry
			if json.unmarshal(reg, &entries, allocator = context.temp_allocator) == nil {
				for e in entries {
					if e.handle == id.handle {
						if e.display_name != "" {
							id.name = e.display_name
						} else if e.name != "" {
							id.name = e.name
						}
						id.color = identity_parse_color(e.color, pal.dark)
					}
				}
			}
		}
		return id
	}
	// No account: the person at the keyboard, by the name the system has.
	user := os.get_env("USER", context.temp_allocator)
	if user == "" {
		user = os.get_env("LOGNAME", context.temp_allocator)
	}
	id.handle = user
	id.name = user != "" ? user : "This computer"
	if pw, err := os.read_entire_file("/etc/passwd", context.temp_allocator); err == nil && user != "" {
		rest := string(pw)
		for line in strings.split_lines_iterator(&rest) {
			f := strings.split(line, ":", context.temp_allocator)
			if len(f) >= 5 && f[0] == user {
				gecos := f[4]
				if c := strings.index_byte(gecos, ','); c >= 0 {
					gecos = gecos[:c]
				}
				if strings.trim_space(gecos) != "" {
					id.name = strings.trim_space(gecos)
				}
			}
		}
	}
	id.subtitle = "Local account"
	return id
}

// monogram is the identity's initial, upper-cased.
monogram :: proc(name: string) -> string {
	for r in name {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			up := r >= 'a' && r <= 'z' ? r - 32 : r
			return fmt.tprintf("%c", up)
		}
	}
	return "?"
}
