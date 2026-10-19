package install_core

// install_core — what installing Palmy onto a disk means, as a library.
//
// Two front ends drive it: `palm-install` (distro/installer/cli), a command
// line for the serial console and for scripts, and `installer`
// (apps/installer), the graphical one the live medium starts. Both build a
// Plan, ask validate() what is wrong with it, and hand it to install(), which
// does the seven steps of distro/INSTALLER.md in order and reports progress
// through a callback. Everything they show the person — disks, keyboard
// layouts, time zones, languages — also comes from here, so the two can never
// disagree about what is possible.
//
// The steps, and the file that does each:
//
//   Partition   gpt.odin, blk.odin   our own GPT, then BLKRRPART
//   Format      run.odin             mkfs.fat, mkfs.ext4
//   Mount       blk.odin             mount(2) root, then the ESP inside it
//   Packages    run.odin             palm --root ... add palmy
//   Configure   configure.odin       /etc, users, locale, keyboard, clock, fstab
//   Bootloader  boot.odin            limine on the ESP, a UEFI Boot#### entry
//   Unmount     blk.odin             sync, umount
//
// The target is an abstraction (Target: a root directory and an ESP
// directory), not a hard-coded /mnt/target, so that everything after
// partitioning runs on the build host against a scratch directory, and
// partitioning plus formatting runs against a plain image file (Options.
// disk_image). The selftest and `palm-install --disk-image` use exactly the
// code the live system runs; only mount(2) and BLKRRPART are skipped, and
// only because the host is the user's machine and those need root.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

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
	country: string, // France
	country_code: string, // FR, the ISO 3166-1 code (the first, where a zone has several)
}

Language :: struct {
	code:         string, // fr_FR
	native_name:  string, // Français
	english_name: string, // French
	rtl:          bool,
	available:    bool, // a catalogue (and, where needed, a font) is installed
}

Plan :: struct {
	disk:           string, // /dev/vda
	language:       string, // fr_FR
	keyboard:       Keyboard, // {layout="fr", variant=""}
	timezone:       string, // Europe/Paris
	hostname:       string,
	full_name:      string,
	user:           string,
	password:       string, // hashed with SHA-512 crypt before it touches disk
	root_password:  string, // empty = same as user
	repo:           string, // default: the live medium's repository, file:///usr/share/palm/repo
	packages:       []string, // default: {"palmy"}
	efi_boot_entry: bool, // write a UEFI Boot#### variable via efivarfs
	swap_bytes:     u64, // a /swapfile of this size on the root; 0 = none
	// No firmware packages. By default the install adds linux-firmware, or
	// the parts of it the repository has (firmware.odin).
	no_firmware:    bool,
}

Step :: enum {
	Partition,
	Format,
	Mount,
	Packages,
	Configure,
	Bootloader,
	Unmount,
	Done,
}

// fraction is the whole installation's progress, 0 to 1, not the step's:
// a front end can feed it straight to one progress bar.
// message is the English text of `detail`; detail is the same thing as an
// id and arguments (message.odin), for a front end that translates it. Its
// arguments are only valid during the `report` call: clone what you keep.
Progress :: struct {
	step:     Step,
	fraction: f32,
	message:  string,
	detail:   Message,
}

DEFAULT_REPO :: "file:///usr/share/palm/repo"
// A package-level slice, not a literal in normalise_plan: a slice literal
// there would point into that procedure's stack frame.
DEFAULT_PACKAGES := []string{"palmy"}
DEFAULT_TARGET :: "/mnt/target"
DEFAULT_EFIVARS :: "/sys/firmware/efi/efivars"
DEFAULT_LOG :: "/var/log/palm-install.log"
MIN_DISK_BYTES :: 4 * 1024 * 1024 * 1024
// A swap file is at most this big; bigger only wastes the disk on a machine
// that cannot hibernate anyway.
MAX_SWAP_BYTES :: 64 * 1024 * 1024 * 1024

// Options are the knobs neither front end shows a person: where things are,
// and the test paths. default_options() is what install() uses.
Options :: struct {
	target:     string, // the root is mounted (or, for a disk image, built) here
	// The disk is a regular file, not a block device: partition and format
	// it in place (mkfs at byte offsets), never mount it; the later steps
	// build the system in `target` as a plain directory. Refused for /dev/*.
	disk_image: bool,
	steps:      bit_set[Step], // which steps run; {} = all of them
	palm:       string, // the package manager; "" = palm from PATH
	keys_dir:   string, // trusted repository keys passed to palm
	limine_dir: string, // where BOOTX64.EFI and limine-bios.sys are found if the target has none
	// limine's host tool, which writes the BIOS boot code (`limine
	// bios-install`); "" = `limine` from PATH (the limine package's).
	limine_tool: string,
	// Skip `limine bios-install`. The BIOS boot partition is still made, so
	// it can be run later.
	no_bios_boot: bool,
	efivars:    string, // efivarfs mount point
	log_path:   string,
	dry_run:    bool, // say what would happen, change nothing
	// Every log line also goes here when set (the CLI's --verbose, the GUI's
	// log view). Called on the installing thread.
	on_log:     proc(line: string, user: rawptr),
}

default_options :: proc() -> Options {
	return Options {
		target = DEFAULT_TARGET,
		keys_dir = "/etc/palm/keys",
		limine_dir = "/usr/share/limine",
		efivars = DEFAULT_EFIVARS,
		log_path = DEFAULT_LOG,
	}
}

// default_plan fills what a front end does not ask for.
default_plan :: proc() -> Plan {
	return Plan {
		language = "en_US",
		keyboard = {layout = "us"},
		timezone = "UTC",
		hostname = "palmy",
		repo = DEFAULT_REPO,
		packages = nil,
		efi_boot_entry = os.is_dir("/sys/firmware/efi"),
	}
}

// Target is where the new system lives while it is being built.
Target :: struct {
	root: string, // /mnt/target
	esp:  string, // /mnt/target/boot/efi
}

// Partition_Info is what the later steps need to know about the table the
// first step wrote: device nodes for mkfs and mount, PARTUUIDs for fstab and
// the kernel command line, and the ESP's position for the UEFI device path.
Partition_Info :: struct {
	sector_size:    u64,
	esp_dev:        string,
	root_dev:       string,
	esp_guid:       Guid,
	root_guid:      Guid,
	has_bios_boot:  bool, // partition BIOS_BOOT_NUMBER holds limine's BIOS stage 2
	esp_first_lba:  u64,
	esp_sectors:    u64,
	root_first_lba: u64,
	root_sectors:   u64,
}

// ------------------------------------------------------------- the install --

@(private)
Ctx :: struct {
	p:            Plan,
	o:            Options,
	report:       proc(Progress, rawptr),
	user:         rawptr,
	t:            Target,
	parts:        Partition_Info,
	have_parts:   bool,
	log:          ^os.File,
	log_path:     string,
	step:         Step,
	mounted_root: bool,
	mounted_esp:  bool,
	// The partition GUIDs of the table this run erased: a UEFI entry that
	// points at one of them pointed at this disk, and is reused.
	old_guids:    [dynamic]Guid,
}

@(private = "file")
STEP_SPAN := [Step][2]f32 {
	.Partition  = {0.00, 0.04},
	.Format     = {0.04, 0.10},
	.Mount      = {0.10, 0.12},
	.Packages   = {0.12, 0.82},
	.Configure  = {0.82, 0.88},
	.Bootloader = {0.88, 0.96},
	.Unmount    = {0.96, 1.00},
	.Done       = {1.00, 1.00},
}

// install runs the plan with default_options(). It runs on the caller's
// thread (a front end gives it a worker thread) and calls `report` there.
// On failure `err` says what went wrong and where the full log is.
install :: proc(p: Plan, report: proc(Progress, rawptr), user: rawptr) -> (ok: bool, err: string) {
	return install_with(p, default_options(), report, user)
}

// One installation at a time per process: the steps share /mnt/target.
@(private = "file")
running: sync.Mutex

install_with :: proc(p: Plan, o: Options, report: proc(Progress, rawptr), user: rawptr) -> (ok: bool, err: string) {
	if !sync.mutex_try_lock(&running) {
		return false, "an installation is already running"
	}
	defer sync.mutex_unlock(&running)

	c := Ctx {
		p      = normalise_plan(p),
		o      = o,
		report = report,
		user   = user,
	}
	if c.o.target == "" {c.o.target = DEFAULT_TARGET}
	if c.o.keys_dir == "" {c.o.keys_dir = "/etc/palm/keys"}
	if c.o.limine_dir == "" {c.o.limine_dir = "/usr/share/limine"}
	c.old_guids = make([dynamic]Guid, context.temp_allocator)
	if c.o.efivars == "" {c.o.efivars = DEFAULT_EFIVARS}
	if c.o.steps == {} {c.o.steps = ~bit_set[Step]{}}
	c.t = Target {
		root = c.o.target,
		esp  = join(c.o.target, "boot/efi"),
	}
	if !c.o.dry_run {
		open_log(&c) // a dry run changes nothing, not even a log file
	}
	defer if c.log != nil {os.close(c.log)}

	logf(&c, "palm-install: %s, disk %s, target %s%s%s", time_stamp(), c.p.disk, c.t.root,
		c.o.disk_image ? " (disk image)" : "", c.o.dry_run ? " (dry run)" : "")
	logf(&c, "plan: language=%s keyboard=%s:%s timezone=%s hostname=%s user=%s packages=%v repo=%s efi_entry=%v swap=%s",
		c.p.language, c.p.keyboard.layout, c.p.keyboard.variant, c.p.timezone, c.p.hostname,
		c.p.user, c.p.packages, c.p.repo, c.p.efi_boot_entry, c.p.swap_bytes > 0 ? human_size(c.p.swap_bytes) : "none")

	// The safety rules that do not depend on the plan's content: a disk image
	// must really be a file, and a disk must really be a block device. The
	// first is what keeps a test path from ever touching /dev on a host.
	if e := check_disk_kind(&c); e != "" {
		return fail(&c, e)
	}

	steps := [?]struct {
		s: Step,
		f: proc(c: ^Ctx) -> string,
	} {
		{.Partition, step_partition},
		{.Format, step_format},
		{.Mount, step_mount},
		{.Packages, step_packages},
		{.Configure, step_configure},
		{.Bootloader, step_bootloader},
		{.Unmount, step_unmount},
	}
	for st in steps {
		if st.s not_in c.o.steps {
			continue
		}
		c.step = st.s
		progress(&c, 0, msg(step_msg(st.s)))
		start := time.tick_now()
		if e := st.f(&c); e != "" {
			cleanup(&c)
			return fail(&c, fmt.tprintf("%s: %s", step_title(st.s), e))
		}
		logf(&c, "%s: done in %.1f s", step_title(st.s), time.duration_seconds(time.tick_since(start)))
	}
	c.step = .Done
	progress(&c, 1, msg(.Step_Done))
	logf(&c, "installation finished")
	return true, ""
}

step_title :: proc(s: Step) -> string {
	return MESSAGE_FORMAT[step_msg(s)]
}

step_msg :: proc(s: Step) -> Msg {
	switch s {
	case .Partition: return .Step_Partition
	case .Format: return .Step_Format
	case .Mount: return .Step_Mount
	case .Packages: return .Step_Packages
	case .Configure: return .Step_Configure
	case .Bootloader: return .Step_Bootloader
	case .Unmount: return .Step_Unmount
	case .Done: return .Step_Done
	}
	return .None
}

step_name :: proc(s: Step) -> string {
	switch s {
	case .Partition: return "partition"
	case .Format: return "format"
	case .Mount: return "mount"
	case .Packages: return "packages"
	case .Configure: return "configure"
	case .Bootloader: return "bootloader"
	case .Unmount: return "unmount"
	case .Done: return "done"
	}
	return ""
}

// normalise_plan fills defaults so the steps never see an empty field that
// has an obvious meaning.
normalise_plan :: proc(p: Plan) -> Plan {
	q := p
	if q.repo == "" {q.repo = DEFAULT_REPO}
	if len(q.packages) == 0 {
		q.packages = DEFAULT_PACKAGES
	}
	if q.root_password == "" {q.root_password = q.password}
	if q.keyboard.layout == "" {q.keyboard.layout = "us"}
	if q.timezone == "" {q.timezone = "UTC"}
	if q.language == "" {q.language = "en_US"}
	if q.full_name == "" {q.full_name = q.user}
	return q
}

// progress reports `within` (0..1) of the current step.
@(private)
progress :: proc(c: ^Ctx, within: f32, m: Message) {
	span := STEP_SPAN[c.step]
	f := span[0] + (span[1] - span[0]) * clamp(within, 0, 1)
	if c.report != nil {
		c.report(Progress{step = c.step, fraction = f, message = message_text(m), detail = m}, c.user)
	}
}

@(private)
logf :: proc(c: ^Ctx, format: string, args: ..any) {
	line := fmt.tprintf(format, ..args)
	if c.log != nil {
		os.write_string(c.log, line)
		os.write_string(c.log, "\n")
	}
	if c.o.on_log != nil {
		c.o.on_log(line, c.user)
	}
}

@(private = "file")
open_log :: proc(c: ^Ctx) {
	candidates := [?]string{c.o.log_path, "/tmp/palm-install.log"}
	for path in candidates {
		if path == "" {continue}
		_ = mkdir_p(dir_of(path))
		f, err := os.open(path, {.Write, .Create, .Append}, os.perm_number(0o600))
		if err == nil {
			c.log = f
			c.log_path = strings.clone(path)
			return
		}
	}
}

@(private = "file")
fail :: proc(c: ^Ctx, e: string) -> (bool, string) {
	logf(c, "FAILED: %s", e)
	if c.log_path != "" {
		return false, fmt.aprintf("%s (log: %s)", e, c.log_path)
	}
	return false, strings.clone(e)
}

// cleanup unmounts whatever this run mounted, so a failed installation
// leaves the disk free for another attempt.
@(private = "file")
cleanup :: proc(c: ^Ctx) {
	if c.mounted_esp {
		_ = umount(c, c.t.esp)
		c.mounted_esp = false
	}
	if c.mounted_root {
		_ = umount(c, c.t.root)
		c.mounted_root = false
	}
}

@(private = "file")
check_disk_kind :: proc(c: ^Ctx) -> string {
	need := c.o.steps & {.Partition, .Format, .Mount}
	if need == {} && !(.Bootloader in c.o.steps && c.p.efi_boot_entry) && !(.Configure in c.o.steps) {
		return ""
	}
	if c.p.disk == "" {
		if need == {} {return ""}
		return "no disk given"
	}
	st: linux.Stat
	if err := linux.stat(strings.clone_to_cstring(c.p.disk, context.temp_allocator), &st); err != .NONE {
		if need == {} {return ""} // configure-only runs may name no real disk
		return fmt.tprintf("%s: %v", c.p.disk, err)
	}
	is_blk := linux.S_ISBLK(st.mode)
	is_reg := linux.S_ISREG(st.mode)
	if c.o.disk_image {
		if !is_reg || strings.has_prefix(c.p.disk, "/dev/") {
			return fmt.tprintf("%s is not a plain image file; --disk-image refuses devices", c.p.disk)
		}
	} else if need != {} && !is_blk {
		return fmt.tprintf("%s is not a block device (use a disk image test path for files)", c.p.disk)
	}
	return ""
}

// ------------------------------------------------------------ small helpers --

join :: proc(parts: ..string) -> string {
	sb := strings.builder_make()
	for p, i in parts {
		if p == "" {continue}
		s := p
		if strings.builder_len(sb) > 0 {
			for strings.has_prefix(s, "/") {s = s[1:]}
			if !strings.has_suffix(strings.to_string(sb), "/") {
				strings.write_byte(&sb, '/')
			}
		}
		strings.write_string(&sb, s)
		_ = i
	}
	return strings.to_string(sb)
}

dir_of :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	if i <= 0 {
		return i == 0 ? "/" : "."
	}
	return path[:i]
}

@(private)
time_stamp :: proc() -> string {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock(now)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d UTC", y, int(mo), d, h, mi, s)
}

// mkdir_p is make_directory_all without the complaint when the directory is
// already there, which is the normal case on a second run.
mkdir_p :: proc(path: string) -> os.Error {
	e := os.make_directory_all(path)
	if e != nil && os.is_dir(path) {
		return nil
	}
	return e
}
