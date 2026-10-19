package drivecore

import "core:fmt"
import "core:os"
import "core:strings"

// One drive to mirror: an identity, the token scoped to it, and where its
// folder is on this machine.
Identity :: struct {
	handle: string,
	id:     string,
	name:   string,
	kind:   string,
	color:  string,
	token:  string, // a JWT scoped to this identity (claim palm_identity)
	root:   string, // ~/Drive/<handle> unless the config says otherwise
}

Config :: struct {
	path:       string,
	url:        string, // PostgREST
	storage:    string, // Storage API
	anon:       string,
	account:    string, // the unscoped token, for listing identities
	device:     string,
	drive_dir:  string,
	state_dir:  string,
	identities: [dynamic]Identity,
}

// config_path is $PALM_DRIVE_CONFIG, or ~/.config/palm-drive/drive.conf.
config_path :: proc() -> string {
	if p := os.get_env("PALM_DRIVE_CONFIG", context.temp_allocator); p != "" {
		return strings.clone(p)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.config/palm-drive/drive.conf", home)
}

// load_config reads the `key = value` file with `[identity]` blocks that
// cloud/drive/dev/seed.sh writes. The accounts area will hand these out
// (sign-in, then one scoped device token per identity); until then the file
// is the hand-off.
load_config :: proc(path: string) -> (cfg: Config, err: string) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return {}, fmt.aprintf("cannot read %s", path)
	}
	cfg.path = path
	home := os.get_env("HOME", context.temp_allocator)
	cfg.drive_dir = fmt.aprintf("%s/Drive", home)
	cfg.state_dir = fmt.aprintf("%s/.local/state/palm-drive", home)
	host, _ := os.read_entire_file("/etc/hostname", context.temp_allocator)
	cfg.device = strings.clone(strings.trim_space(string(host)))
	if cfg.device == "" {
		cfg.device = "this device"
	}
	cur: ^Identity
	for raw in strings.split_lines(string(data), context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		if line == "[identity]" {
			append(&cfg.identities, Identity{})
			cur = &cfg.identities[len(cfg.identities) - 1]
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		k := strings.trim_space(line[:eq])
		v := strings.clone(strings.trim_space(line[eq + 1:]))
		if cur == nil {
			switch k {
			case "url":
				cfg.url = v
			case "storage":
				cfg.storage = v
			case "anon":
				cfg.anon = v
			case "account":
				cfg.account = v
			case "device":
				cfg.device = v
			case "drive_dir":
				cfg.drive_dir = v
			case "state_dir":
				cfg.state_dir = v
			}
		} else {
			switch k {
			case "handle":
				cur.handle = v
			case "id":
				cur.id = v
			case "name":
				cur.name = v
			case "kind":
				cur.kind = v
			case "color":
				cur.color = v
			case "token":
				cur.token = v
			case "root":
				cur.root = v
			}
		}
	}
	// Environment overrides, so tests can point several "devices" at one
	// config without editing it.
	if v := os.get_env("PALM_DRIVE_DIR", context.temp_allocator); v != "" {
		cfg.drive_dir = strings.clone(v)
	}
	if v := os.get_env("PALM_DRIVE_STATE", context.temp_allocator); v != "" {
		cfg.state_dir = strings.clone(v)
	}
	if v := os.get_env("PALM_DRIVE_DEVICE", context.temp_allocator); v != "" {
		cfg.device = strings.clone(v)
	}
	for &id in cfg.identities {
		if id.root == "" {
			id.root = fmt.aprintf("%s/%s", cfg.drive_dir, id.handle)
		}
		if id.name == "" {
			id.name = id.handle
		}
	}
	if cfg.url == "" || cfg.storage == "" {
		return cfg, fmt.aprintf("%s: url and storage are required", path)
	}
	return cfg, ""
}

find_identity :: proc(cfg: ^Config, handle: string) -> ^Identity {
	for &id in cfg.identities {
		if id.handle == handle || id.id == handle {
			return &id
		}
	}
	return nil
}

client_for :: proc(cfg: ^Config, id: ^Identity) -> Client {
	return Client {
		url = cfg.url,
		storage = cfg.storage,
		anon = cfg.anon,
		token = id.token,
		identity = id.id,
		handle = id.handle,
		device = cfg.device,
	}
}
