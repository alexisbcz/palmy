package main

// The installer's view of the machine, and the plan it builds.
//
// These types mirror install_core's (distro/INSTALLER.md, "install_core API")
// field for field. The GUI keeps its own copies rather than using the core's
// directly for one reason: --demo. The demo must run on a development machine
// with nothing behind it — fabricated disks, a fake install that only sleeps —
// and it is much easier to be sure the demo never reaches the real core when
// the two halves meet in exactly one file (backend.odin) and everything else
// only ever sees these structs.

Disk :: struct {
	path:           string, // /dev/vda
	name:           string, // vda
	model:          string,
	size_bytes:     u64,
	removable:      bool,
	readonly:       bool,
	has_partitions: bool,
	is_live_medium: bool,
}

Keyboard :: struct {
	layout:      string,
	variant:     string,
	description: string,
}

Zone :: struct {
	name:    string, // Europe/Paris
	region:  string, // Europe
	city:    string, // Paris
	country: string, // France (the core reads the name from iso3166.tab)
	country_code: string, // FR: the key of countries.msg, which translates the name
}

Language :: struct {
	code:         string, // fr_FR, ar
	native_name:  string, // Français
	english_name: string, // French
	rtl:          bool,
	available:    bool, // false when its script has no font on this system
}

Plan :: struct {
	disk:           string,
	language:       string,
	keyboard:       Keyboard,
	timezone:       string,
	hostname:       string,
	full_name:      string,
	user:           string,
	password:       string,
	root_password:  string, // empty = same as the user's
	repo:           string, // empty = the core's default (the live medium's repository)
	packages:       []string, // nil = the core's default ({"palmframe"})
	efi_boot_entry: bool,
	swap_bytes:     u64, // a swap file of this size on the new root; 0 = none
}

// Text is one of install_core's messages (its Message): an English msgid,
// translated where it is drawn (text_tr), and the strings that fill its
// %s/%q verbs. The msgids are the core's MESSAGE_FORMAT, which the selftest
// checks every catalogue for.
Text :: struct {
	msgid: string,
	args:  [4]string,
	nargs: int,
}

// Install_Step is the core's `Step`: where `install` has got to.
Install_Step :: enum {
	Partition,
	Format,
	Mount,
	Packages,
	Configure,
	Bootloader,
	Unmount,
	Done,
}

// Progress is the core's: `fraction` is the whole installation's progress,
// 0..1, not the current step's, so it goes straight to the bar.
Progress :: struct {
	step:     Install_Step,
	fraction: f32,
	message:  string, // English; the demo's only text
	detail:   Text, // the core's message, translatable; empty in the demo
}

// MIN_DISK is the smallest disk the core accepts (validate: size >= 4 GiB).
// The GUI greys smaller disks out instead of letting the user pick one and
// find out on the summary page.
MIN_DISK :: u64(4) << 30

// disk_usable says whether a disk can be the install target, and if not,
// which of the reasons applies. The reasons are msgids, marked with N() and tr()d by the caller.
disk_usable :: proc(d: Disk) -> (ok: bool, why: string) {
	if d.is_live_medium {
		return false, N("The live system is running from this disk")
	}
	if d.readonly {
		return false, N("This disk is read-only")
	}
	if d.size_bytes < MIN_DISK {
		return false, N("Too small: Palmframe needs at least 4 GiB")
	}
	return true, ""
}
