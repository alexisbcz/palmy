package main

// The real backend: install_core (distro/installer/core), adapted to the
// GUI's own types (model.odin). This is the only file that imports the core.
//
// Where the core differs from distro/INSTALLER.md, it is the core that is
// followed (and the difference noted in distro/notes/installer-gui.md):
//
//   - Progress.fraction is the whole installation's progress, not the
//     step's; the bar shows it as it comes.
//   - install_with takes Options, whose `on_log` hands over every log line as
//     it is written. The log view shows those, which is the full log rather
//     than one line per progress report.
//   - Zone.country is the country's name from iso3166.tab ("France"), not
//     its code.
//   - Arabic's language code is "ar".

import core "install:core"

core_languages :: proc() -> []Language {
	ls := core.list_languages()
	out := make([]Language, len(ls))
	for l, i in ls {
		out[i] = Language {
			code         = l.code,
			native_name  = l.native_name,
			english_name = l.english_name,
			rtl          = l.rtl,
			available    = l.available,
		}
	}
	return out
}

core_layouts :: proc() -> []Keyboard {
	ks := core.list_layouts()
	out := make([]Keyboard, len(ks))
	for k, i in ks {
		out[i] = Keyboard{layout = k.layout, variant = k.variant, description = k.description}
	}
	return out
}

core_zones :: proc() -> []Zone {
	zs := core.list_zones()
	out := make([]Zone, len(zs))
	for z, i in zs {
		out[i] = Zone{name = z.name, region = z.region, city = z.city, country = z.country}
	}
	return out
}

core_disks :: proc() -> []Disk {
	ds := core.list_disks()
	out := make([]Disk, len(ds))
	for d, i in ds {
		out[i] = Disk {
			path           = d.path,
			name           = d.name,
			model          = d.model,
			size_bytes     = d.size_bytes,
			removable      = d.removable,
			readonly       = d.readonly,
			has_partitions = d.has_partitions,
			is_live_medium = d.is_live_medium,
		}
	}
	return out
}

to_core :: proc(p: Plan) -> core.Plan {
	return core.Plan {
		disk           = p.disk,
		language       = p.language,
		keyboard       = {layout = p.keyboard.layout, variant = p.keyboard.variant, description = p.keyboard.description},
		timezone       = p.timezone,
		hostname       = p.hostname,
		full_name      = p.full_name,
		user           = p.user,
		password       = p.password,
		root_password  = p.root_password,
		repo           = p.repo,
		packages       = p.packages,
		efi_boot_entry = p.efi_boot_entry,
	}
}

core_validate :: proc(p: Plan) -> (ok: bool, problems: []string) {
	return core.validate(to_core(p))
}

// core_install runs on the worker thread, with the worker's own callbacks
// (backend.odin) and the worker itself as their `user`.
core_install :: proc(p: Plan, w: ^Worker) -> (ok: bool, err: string) {
	o := core.default_options()
	o.dry_run = w.backend.dry_run
	o.on_log = proc(line: string, user: rawptr) {
		worker_log((^Worker)(user), line)
	}
	report :: proc(pr: core.Progress, user: rawptr) {
		worker_report(Progress{step = Install_Step(pr.step), fraction = pr.fraction, message = pr.message}, user)
	}
	return core.install_with(to_core(p), o, report, w)
}

// The two Step enums must stay the same list in the same order for the cast
// in `report` to mean anything.
#assert(len(Install_Step) == len(core.Step))
#assert(int(Install_Step.Done) == int(core.Step.Done))
#assert(int(Install_Step.Packages) == int(core.Step.Packages))
