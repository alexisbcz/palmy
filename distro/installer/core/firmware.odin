package install_core

// Firmware for the installed system: what drivers upload to GPUs, Wi-Fi
// and Bluetooth chips and audio DSPs (distro/notes/kernel.md, Firmware).
//
// An installation gets all of it, `linux-firmware`, whenever the repository
// it installs from has that package: the network repository does, and a disk
// has room for 440 MB that a machine may later need for a card plugged in
// after the install. The live medium's repository carries only the parts its
// build chose (distro/live/build.sh, LIVE_FIRMWARE), since the whole medium
// sits in RAM; installing from it gives those parts, and `palm add
// linux-firmware` from the network fills in the rest later. Plan.no_firmware
// (palm-install --no-firmware) installs none.

import "core:os"
import "core:strings"

FIRMWARE_PACKAGE :: "linux-firmware"

// firmware_for_repo is what to add for the repository `repo` (a path, a
// file:// URL, or http(s)://): linux-firmware when its index lists it, else
// every firmware part the index lists (linux-firmware-*, sof-firmware,
// wireless-regdb). A network repository's index is not read here: it is
// assumed to have linux-firmware, as the public one does, and palm fails
// the install with its own words if it has not.
firmware_for_repo :: proc(repo: string, allocator := context.allocator) -> []string {
	dir := repo
	if strings.has_prefix(dir, "file://") {
		dir = dir[len("file://"):]
	}
	if strings.has_prefix(dir, "http://") || strings.has_prefix(dir, "https://") {
		out := make([]string, 1, allocator)
		out[0] = FIRMWARE_PACKAGE
		return out
	}
	// palm reads <base>/x86_64/PALMINDEX when it exists, else <base> itself.
	data, err := os.read_entire_file(join(dir, "x86_64/PALMINDEX"), context.temp_allocator)
	if err != nil {
		data, err = os.read_entire_file(join(dir, "PALMINDEX"), context.temp_allocator)
	}
	if err != nil {
		return nil
	}
	return firmware_from_index(string(data), allocator)
}

// firmware_from_index is firmware_for_repo's choice, given the index's text.
firmware_from_index :: proc(index: string, allocator := context.allocator) -> []string {
	parts := make([dynamic]string, allocator)
	text := index
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "pkgname") {
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq < 0 {
			continue
		}
		name := strings.trim_space(l[eq + 1:])
		if name == FIRMWARE_PACKAGE {
			delete(parts)
			out := make([]string, 1, allocator)
			out[0] = FIRMWARE_PACKAGE
			return out
		}
		if strings.has_prefix(name, "linux-firmware-") || name == "sof-firmware" || name == "wireless-regdb" {
			dup := false
			for p in parts {
				if p == name {dup = true}
			}
			if !dup {
				append(&parts, strings.clone(name, allocator))
			}
		}
	}
	return parts[:]
}
