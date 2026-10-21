#+build !darwin
package palmy

import "core:os"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// ~/.Xauthority parsing.
//
// An X server with access control on refuses an unauthenticated connection, so
// a client has to find its own cookie. The file is a flat sequence of records,
// every field a big-endian 16-bit length followed by that many bytes:
//
//	family  u16be
//	address u16be length + bytes
//	number  u16be length + bytes   (the display number, as ASCII)
//	name    u16be length + bytes   ("MIT-MAGIC-COOKIE-1")
//	data    u16be length + bytes   (16 opaque bytes for that scheme)
//
// A record matches this connection when the family and address name this host
// (or are the wildcard), the number matches the display we are opening, and the
// scheme is one we can speak.
// ---------------------------------------------------------------------------

@(private)
XAUTH_FAMILY_INTERNET :: 0
@(private)
XAUTH_FAMILY_LOCAL :: 256
@(private)
XAUTH_FAMILY_WILD :: 65535

@(private)
XAUTH_COOKIE :: "MIT-MAGIC-COOKIE-1"

@(private)
Xauth :: struct {
	name: string,
	data: []u8,
}

// xauth_path is the file to read, following the same rule libXau does.
@(private)
xauth_path :: proc(allocator := context.temp_allocator) -> string {
	if p := os.get_env("XAUTHORITY", context.temp_allocator); p != "" {
		return strings.clone(p, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return strings.concatenate({home, "/.Xauthority"}, allocator)
}

// hostname reads the node name without a libc call, so that nothing is linked
// for it. /proc/sys/kernel/hostname is what uname(2) reports.
@(private)
hostname :: proc(allocator := context.temp_allocator) -> string {
	raw, rerr := os.read_entire_file_from_path("/proc/sys/kernel/hostname", context.temp_allocator)
	if rerr != nil {
		return ""
	}
	return strings.clone(strings.trim_space(string(raw)), allocator)
}

@(private)
xauth_u16 :: proc(b: []u8, p: ^int) -> (v: int, ok: bool) {
	if p^ + 2 > len(b) {
		return 0, false
	}
	v = int(b[p^]) << 8 | int(b[p^ + 1])
	p^ += 2
	return v, true
}

@(private)
xauth_blob :: proc(b: []u8, p: ^int) -> (v: []u8, ok: bool) {
	n: int
	if n, ok = xauth_u16(b, p); !ok {
		return nil, false
	}
	if p^ + n > len(b) {
		return nil, false
	}
	v = b[p^:p^ + n]
	p^ += n
	return v, true
}

// xauth_find returns the cookie for a display number, or an empty name when
// there is none — which is not an error, because a server started without
// access control (Xvfb's default, or `xhost +local:`) accepts anyone.
//
// The returned slices point into `file`, which the caller owns.
@(private)
xauth_find :: proc(file: []u8, display: string, host: string) -> (auth: Xauth) {
	p := 0
	for p < len(file) {
		family, ok := xauth_u16(file, &p)
		if !ok {
			break
		}
		addr, aok := xauth_blob(file, &p)
		if !aok {
			break
		}
		number, nok := xauth_blob(file, &p)
		if !nok {
			break
		}
		name, mok := xauth_blob(file, &p)
		if !mok {
			break
		}
		data, dok := xauth_blob(file, &p)
		if !dok {
			break
		}

		if string(name) != XAUTH_COOKIE {
			continue
		}
		// An empty number in the file matches any display.
		if len(number) > 0 && string(number) != display {
			continue
		}
		switch family {
		case XAUTH_FAMILY_WILD:
		// Matches everything.
		case XAUTH_FAMILY_LOCAL:
			if host != "" && string(addr) != host {
				continue
			}
		case XAUTH_FAMILY_INTERNET:
			// A cookie issued for a TCP address still works over the unix
			// socket of the same host, which is how `ssh -X` entries behave.
			if host != "" && string(addr) != host {
				continue
			}
		case:
			continue
		}

		return Xauth{name = string(name), data = data}
	}
	return Xauth{}
}

// xauth_for_display loads the cookie for a display number. The returned
// strings and bytes are owned by the caller's allocator.
@(private)
xauth_for_display :: proc(display: string, allocator := context.allocator) -> (auth: Xauth) {
	path := xauth_path(context.temp_allocator)
	if path == "" {
		return Xauth{}
	}
	raw, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
	if rerr != nil {
		return Xauth{}
	}
	found := xauth_find(raw, display, hostname(context.temp_allocator))
	if found.name == "" {
		return Xauth{}
	}
	return Xauth {
		name = strings.clone(found.name, allocator),
		data = slice.clone(found.data, allocator),
	}
}
