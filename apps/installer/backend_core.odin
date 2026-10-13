package main

// The real backend: install_core, adapted to the GUI's types (model.odin).
//
// TEMPORARY: install_core (distro/installer/core) is being written alongside
// this GUI and does not compile yet, so these are stand-ins that find
// nothing and refuse to install. They are replaced by the adapter once the
// core builds; nothing outside this file changes when that happens.

core_languages :: proc() -> []Language {
	return nil
}

core_layouts :: proc() -> []Keyboard {
	return nil
}

core_zones :: proc() -> []Zone {
	return nil
}

core_disks :: proc() -> []Disk {
	return nil
}

core_validate :: proc(p: Plan) -> (ok: bool, problems: []string) {
	return false, []string{"the install core is not built into this installer"}
}

core_install :: proc(p: Plan, report: proc(pr: Progress, user: rawptr), user: rawptr) -> (ok: bool, err: string) {
	return false, "the install core is not built into this installer"
}
