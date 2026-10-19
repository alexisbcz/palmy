package main

// --demo: a whole installer with nothing behind it.
//
// Everything here is fabricated so the GUI can be run, clicked through and
// photographed on a development machine. The disks do not exist; the install
// only sleeps and reports progress. Nothing in this file opens a device,
// writes a file outside the process, or starts a program. The only things it
// reads from the host are harmless and read-only: whether a CJK font is
// installed (so the Japanese row is honest about the screen it is on) and,
// for the clock on the time zone page, the TZif file of the selected zone.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// LANGUAGES is the installer's own list, used by --demo and as the fallback
// when the core's list cannot be read. The order is INSTALLER.md's.
LANGUAGES := [?]Language {
	{code = "en_US", native_name = "English", english_name = "English", available = true},
	{code = "fr_FR", native_name = "Français", english_name = "French", available = true},
	{code = "de_DE", native_name = "Deutsch", english_name = "German", available = true},
	{code = "es_ES", native_name = "Español", english_name = "Spanish", available = true},
	{code = "ar", native_name = "العربية", english_name = "Arabic", rtl = true, available = true},
	{code = "ja_JP", native_name = "日本語", english_name = "Japanese", available = false},
}

demo_languages :: proc() -> []Language {
	out := make([]Language, len(LANGUAGES))
	copy(out, LANGUAGES[:])
	for &l in out {
		if l.code == "ja_JP" {
			l.available = cjk_font_installed()
		}
	}
	return out
}

// cjk_font_installed looks for a Noto CJK face where palmy's font scan would
// find one. Without it Japanese renders as tofu, and the row says so instead.
cjk_font_installed :: proc() -> bool {
	found := false
	walk :: proc(dir: string, depth: int, found: ^bool) {
		if found^ || depth > 3 {
			return
		}
		f, err := os.open(dir)
		if err != nil {
			return
		}
		defer os.close(f)
		infos, _ := os.read_dir(f, -1, context.temp_allocator)
		for fi in infos {
			if fi.type == .Directory {
				walk(fi.fullpath, depth + 1, found)
			} else if strings.contains(filepath.base(fi.fullpath), "CJK") {
				found^ = true
				return
			}
		}
	}
	walk("/usr/share/fonts", 0, &found)
	return found
}

// demo_layouts is a slice of xkeyboard-config's base.lst: enough layouts and
// variants to exercise the page, with the same codes and descriptions.
demo_layouts :: proc() -> []Keyboard {
	rows := [?]Keyboard {
		{"us", "", "English (US)"},
		{"us", "intl", "English (US, intl., with dead keys)"},
		{"us", "dvorak", "English (Dvorak)"},
		{"us", "colemak", "English (Colemak)"},
		{"gb", "", "English (UK)"},
		{"gb", "extd", "English (UK, extended, Windows)"},
		{"fr", "", "French"},
		{"fr", "oss", "French (alt.)"},
		{"fr", "bepo", "French (BEPO)"},
		{"fr", "mac", "French (Macintosh)"},
		{"ca", "", "French (Canada)"},
		{"be", "", "Belgian"},
		{"ch", "", "German (Switzerland)"},
		{"ch", "fr", "French (Switzerland)"},
		{"de", "", "German"},
		{"de", "nodeadkeys", "German (no dead keys)"},
		{"de", "neo", "German (Neo 2)"},
		{"at", "", "German (Austria)"},
		{"es", "", "Spanish"},
		{"es", "nodeadkeys", "Spanish (no dead keys)"},
		{"es", "dvorak", "Spanish (Dvorak)"},
		{"latam", "", "Spanish (Latin American)"},
		{"pt", "", "Portuguese"},
		{"br", "", "Portuguese (Brazil)"},
		{"it", "", "Italian"},
		{"nl", "", "Dutch"},
		{"se", "", "Swedish"},
		{"no", "", "Norwegian"},
		{"dk", "", "Danish"},
		{"fi", "", "Finnish"},
		{"pl", "", "Polish"},
		{"cz", "", "Czech"},
		{"ru", "", "Russian"},
		{"ua", "", "Ukrainian"},
		{"gr", "", "Greek"},
		{"tr", "", "Turkish"},
		{"ara", "", "Arabic"},
		{"ara", "azerty", "Arabic (AZERTY)"},
		{"ara", "qwerty", "Arabic (QWERTY)"},
		{"il", "", "Hebrew"},
		{"jp", "", "Japanese"},
		{"jp", "kana", "Japanese (Kana)"},
		{"kr", "", "Korean"},
		{"cn", "", "Chinese"},
	}
	out := make([]Keyboard, len(rows))
	copy(out, rows[:])
	return out
}

// demo_zones is a slice of tzdata's zone1970.tab, one city per row, with the
// country named as iso3166.tab names it (which is what the core reports).
demo_zones :: proc() -> []Zone {
	names := [?][2]string {
		{"Africa/Abidjan", "Côte d'Ivoire"},
		{"Africa/Cairo", "Egypt"},
		{"Africa/Casablanca", "Morocco"},
		{"Africa/Johannesburg", "South Africa"},
		{"Africa/Lagos", "Nigeria"},
		{"Africa/Nairobi", "Kenya"},
		{"America/Argentina/Buenos_Aires", "Argentina"},
		{"America/Bogota", "Colombia"},
		{"America/Chicago", "United States"},
		{"America/Denver", "United States"},
		{"America/Los_Angeles", "United States"},
		{"America/Mexico_City", "Mexico"},
		{"America/New_York", "United States"},
		{"America/Sao_Paulo", "Brazil"},
		{"America/Toronto", "Canada"},
		{"Asia/Baghdad", "Iraq"},
		{"Asia/Bangkok", "Thailand"},
		{"Asia/Dubai", "United Arab Emirates"},
		{"Asia/Kolkata", "India"},
		{"Asia/Riyadh", "Saudi Arabia"},
		{"Asia/Seoul", "Korea (South)"},
		{"Asia/Shanghai", "China"},
		{"Asia/Singapore", "Singapore"},
		{"Asia/Tokyo", "Japan"},
		{"Atlantic/Reykjavik", "Iceland"},
		{"Australia/Melbourne", "Australia"},
		{"Australia/Sydney", "Australia"},
		{"Europe/Amsterdam", "Netherlands"},
		{"Europe/Athens", "Greece"},
		{"Europe/Berlin", "Germany"},
		{"Europe/Brussels", "Belgium"},
		{"Europe/Dublin", "Ireland"},
		{"Europe/Helsinki", "Finland"},
		{"Europe/Istanbul", "Turkey"},
		{"Europe/Lisbon", "Portugal"},
		{"Europe/London", "Britain (UK)"},
		{"Europe/Madrid", "Spain"},
		{"Europe/Moscow", "Russia"},
		{"Europe/Paris", "France"},
		{"Europe/Rome", "Italy"},
		{"Europe/Stockholm", "Sweden"},
		{"Europe/Warsaw", "Poland"},
		{"Europe/Zurich", "Switzerland"},
		{"Pacific/Auckland", "New Zealand"},
		{"Pacific/Honolulu", "United States"},
	}
	out := make([]Zone, len(names))
	for n, i in names {
		region, city := split_zone(n[0])
		out[i] = Zone{name = n[0], region = region, city = city, country = n[1]}
	}
	return out
}

// split_zone turns "America/Argentina/Buenos_Aires" into "America" and
// "Buenos Aires": the first component is the region, the last the city.
split_zone :: proc(name: string) -> (region, city: string) {
	slash := strings.index_byte(name, '/')
	last := strings.last_index_byte(name, '/')
	if slash < 0 {
		return "", name
	}
	region = name[:slash]
	city, _ = strings.replace_all(name[last + 1:], "_", " ")
	return
}

// demo_disks are invented, and look it: a laptop's NVMe drive with an
// operating system on it, the empty virtio disk a QEMU run would offer, the
// USB stick the live system booted from, and an SD card too small to use.
demo_disks :: proc() -> []Disk {
	rows := [?]Disk {
		{
			path = "/dev/nvme0n1",
			name = "nvme0n1",
			model = "Samsung SSD 980 PRO 1TB",
			size_bytes = 1_000_204_886_016,
			has_partitions = true,
		},
		{path = "/dev/vda", name = "vda", model = "Virtio disk", size_bytes = 20 << 30},
		{
			path = "/dev/sda",
			name = "sda",
			model = "SanDisk Ultra USB 3.0",
			size_bytes = 30_752_636_928,
			removable = true,
			has_partitions = true,
			is_live_medium = true,
		},
		{path = "/dev/mmcblk0", name = "mmcblk0", model = "SD card SL02G", size_bytes = 1_977_614_336, removable = true},
	}
	out := make([]Disk, len(rows))
	copy(out, rows[:])
	return out
}

// demo_time_scale shortens the fake install's naps; the selftest runs it at
// a fiftieth of the speed a person watches.
demo_time_scale: f32 = 1

// demo_install stands in for install_core.install. It walks the same steps,
// reports the same kind of progress, sleeps instead of working, and touches
// nothing. With `fail` it stops partway through the packages with an error,
// so the failure screen can be seen too.
demo_install :: proc(p: Plan, report: proc(pr: Progress, user: rawptr), user: rawptr, fail: bool) -> (ok: bool, err: string) {
	say :: proc(report: proc(pr: Progress, user: rawptr), user: rawptr, step: Install_Step, f: f32, msg: string) {
		report(Progress{step = step, fraction = overall_fraction(step, f), message = msg}, user)
	}
	nap :: proc(ms: int) {
		time.sleep(time.Duration(f32(ms) * demo_time_scale) * time.Millisecond)
	}

	say(report, user, .Partition, 0, fmt.tprintf("demo: would write a fresh GPT to %s (nothing is written)", p.disk))
	nap(500)
	say(report, user, .Partition, 0.5, "demo: partition 1  EFI system  512 MiB  start 1 MiB")
	nap(300)
	say(report, user, .Partition, 1, "demo: partition 2  Linux root  rest of the disk")
	nap(300)

	say(report, user, .Format, 0, fmt.tprintf("demo: would run mkfs.fat -F32 -n PALMEFI %s1", p.disk))
	nap(500)
	say(report, user, .Format, 0.5, fmt.tprintf("demo: would run mkfs.ext4 -F -L palmroot %s2", p.disk))
	nap(700)

	say(report, user, .Mount, 0, "demo: would mount the root at /mnt/target and the ESP at /mnt/target/boot/efi")
	nap(400)

	packages := [?]string {
		"filesystem", "glibc", "busybox", "palm-init", "palm", "palm-login", "fonts",
		"xkeyboard-config", "tzdata", "libxkbcommon", "wm", "greeter", "term",
		"launcher", "files", "editor", "calc", "calendar", "notes", "settings",
		"palmy",
	}
	for name, i in packages {
		f := f32(i) / f32(len(packages))
		say(report, user, .Packages, f, fmt.tprintf("demo: palm add %s (%d/%d)", name, i + 1, len(packages)))
		nap(220)
		if fail && i == 9 {
			return false, "demo: palm exited with status 1 (simulated by --demo-fail)"
		}
	}

	say(report, user, .Configure, 0, fmt.tprintf("demo: would write /etc/hostname (%s)", p.hostname))
	nap(250)
	say(report, user, .Configure, 0.3, fmt.tprintf("demo: would create the user %s in wheel, video, input, audio", p.user))
	nap(250)
	say(report, user, .Configure, 0.6, fmt.tprintf("demo: would link /etc/localtime to %s", p.timezone))
	nap(250)
	say(
		report,
		user,
		.Configure,
		0.8,
		fmt.tprintf("demo: would write /etc/palm/keyboard (layout = %s, variant = %s)", p.keyboard.layout, p.keyboard.variant),
	)
	nap(250)

	say(report, user, .Bootloader, 0, "demo: would copy BOOTX64.EFI to EFI/BOOT and EFI/palmy")
	nap(400)
	say(report, user, .Bootloader, 0.6, "demo: would write limine.conf with root=PARTUUID=…")
	nap(400)

	say(report, user, .Unmount, 0, "demo: would unmount /mnt/target and sync")
	nap(400)
	say(report, user, .Done, 1, "demo: finished; nothing was written to any disk")
	return true, ""
}
