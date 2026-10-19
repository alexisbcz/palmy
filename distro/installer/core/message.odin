package install_core

// Messages a front end shows a person: validate()'s problems and the detail
// line under each progress report.
//
// Each is a Message: a stable id (Msg, whose name is the code a program can
// match on, e.g. `disk_live_medium`), and up to four string arguments. The
// English text is MESSAGE_FORMAT[id] with the arguments filled in, which is
// what message_text returns and what the CLI and the log print. A front end
// that translates looks the *format* up in its catalogue as the msgid and
// fills in the same arguments, so translators see "%s is read-only." and
// never one sentence per disk. MESSAGE_FORMAT is the one list of those
// msgids: the graphical installer's selftest checks that every catalogue
// translates each of them.
//
// Arguments are always strings, formatted by the core (sizes as
// "8.0 GiB", counts as decimal digits), so a format uses only %s and %q.

import "core:fmt"
import "core:strings"

Msg :: enum {
	None,
	// validate
	User_Empty,
	User_Too_Long,
	User_Invalid,
	User_Reserved,
	Full_Name_Invalid,
	Password_Empty,
	Password_Line_Break,
	Root_Password_Line_Break,
	Hostname_Empty,
	Hostname_Too_Long,
	Hostname_Label,
	Hostname_Chars,
	Language_Invalid,
	Layout_Invalid,
	Layout_No_Variant,
	Layout_Unknown,
	Timezone_Invalid,
	Timezone_Unknown,
	Repo_Invalid,
	Package_Invalid,
	Swap_Invalid,
	Swap_Too_Big,
	Disk_None,
	Disk_Image_Device,
	Disk_Image_Not_File,
	Disk_Image_Small,
	Disk_Live_Medium,
	Disk_Readonly,
	Disk_Small,
	Disk_Mounted,
	Disk_Missing,
	// progress
	Step_Partition,
	Step_Format,
	Step_Mount,
	Step_Packages,
	Step_Configure,
	Step_Bootloader,
	Step_Unmount,
	Step_Done,
	Writing_Partition_Table,
	Waiting_For_Partitions,
	Formatting_Esp,
	Formatting_Root,
	Installing_Package,
	Setting_Hostname,
	Creating_User,
	Setting_Locale,
	Creating_Swap,
	Writing_Fstab,
	Copying_Boot_Loader,
	Copying_Kernel,
	Installing_Bios_Boot,
	Adding_Uefi_Entry,
	Uefi_Entry_Failed,
}

MESSAGE_FORMAT := [Msg]string {
	.None                     = "",
	.User_Empty               = "The user name is empty.",
	.User_Too_Long            = "The user name has more than 32 characters.",
	.User_Invalid             = "The user name %q must start with a lower-case letter or '_' and contain only a-z, 0-9, '-' and '_'.",
	.User_Reserved            = "The user name %q is used by the system.",
	.Full_Name_Invalid        = "The full name may not contain ':' or line breaks, and has at most 128 characters.",
	.Password_Empty           = "The password is empty.",
	.Password_Line_Break      = "The password may not contain line breaks.",
	.Root_Password_Line_Break = "The root password may not contain line breaks.",
	.Hostname_Empty           = "The host name is empty.",
	.Hostname_Too_Long        = "The host name is longer than 253 characters.",
	.Hostname_Label           = "The host name %q is not valid: each part has 1 to 63 characters and does not start or end with '-'.",
	.Hostname_Chars           = "The host name %q may contain only letters, digits and '-'.",
	.Language_Invalid         = "The language %q is not a locale name like fr_FR.",
	.Layout_Invalid           = "The keyboard layout %q is not a valid name.",
	.Layout_No_Variant        = "The keyboard layout %s has no variant %q.",
	.Layout_Unknown           = "There is no keyboard layout %q.",
	.Timezone_Invalid         = "The time zone %q is not a zone name like Europe/Paris.",
	.Timezone_Unknown         = "There is no time zone %q.",
	.Repo_Invalid             = "The repository %q is neither an http:// URL nor an absolute path.",
	.Package_Invalid          = "%q is not a package name.",
	.Swap_Invalid             = "The swap size %q is not a size like 2G or 512M.",
	.Swap_Too_Big             = "A swap file of %s leaves too little room on %s.",
	.Disk_None                = "No disk is chosen.",
	.Disk_Image_Device        = "%s is a device; a disk image must be a plain file.",
	.Disk_Image_Not_File      = "The disk image %s is not a plain file.",
	.Disk_Image_Small         = "The disk image %s holds %s; at least 4 GiB is needed.",
	.Disk_Live_Medium         = "%s holds the running system; choose another disk.",
	.Disk_Readonly            = "%s is read-only.",
	.Disk_Small               = "%s holds %s; at least 4 GiB is needed.",
	.Disk_Mounted             = "%s has a mounted file system; unmount it first.",
	.Disk_Missing             = "There is no disk %s.",
	.Step_Partition           = "Partitioning",
	.Step_Format              = "Formatting",
	.Step_Mount               = "Mounting",
	.Step_Packages            = "Installing packages",
	.Step_Configure           = "Configuring the system",
	.Step_Bootloader          = "Installing the boot loader",
	.Step_Unmount             = "Unmounting",
	.Step_Done                = "Done",
	.Writing_Partition_Table  = "Writing the partition table",
	.Waiting_For_Partitions   = "Waiting for the kernel to see the new partitions",
	.Formatting_Esp           = "Formatting the EFI system partition",
	.Formatting_Root          = "Formatting the root partition",
	.Installing_Package       = "Installing %s (%s of %s)",
	.Setting_Hostname         = "Setting the host name",
	.Creating_User            = "Creating the user account",
	.Setting_Locale           = "Setting language, keyboard and time zone",
	.Creating_Swap            = "Creating a %s swap file",
	.Writing_Fstab            = "Writing the file system table",
	.Copying_Boot_Loader      = "Copying the boot loader",
	.Copying_Kernel           = "Copying the kernel",
	.Installing_Bios_Boot     = "Making the disk start on BIOS computers",
	.Adding_Uefi_Entry        = "Adding the UEFI boot entry",
	.Uefi_Entry_Failed        = "UEFI boot entry not written; the disk still boots through the fallback path",
}

MESSAGE_MAX_ARGS :: 4

Message :: struct {
	id:    Msg,
	args:  [MESSAGE_MAX_ARGS]string,
	nargs: int,
}

// msg builds a Message. The arguments are referenced, not copied: clone the
// Message (message_clone) to keep it past the call that produced it.
msg :: proc(id: Msg, args: ..string) -> Message {
	m := Message{id = id}
	for a, i in args {
		if i >= MESSAGE_MAX_ARGS {break}
		m.args[i] = a
		m.nargs = i + 1
	}
	return m
}

message_clone :: proc(m: Message, allocator := context.allocator) -> Message {
	out := m
	for i in 0 ..< m.nargs {
		out.args[i] = strings.clone(m.args[i], allocator)
	}
	return out
}

// message_code is the stable, machine-readable name: "disk_live_medium".
message_code :: proc(id: Msg) -> string {
	return strings.to_lower(fmt.tprint(id), context.temp_allocator)
}

// message_format is the English format, which is also the msgid a front end
// translates.
message_format :: proc(id: Msg) -> string {
	return MESSAGE_FORMAT[id]
}

// message_text is the English sentence with its arguments, in the temp
// allocator unless told otherwise.
message_text :: proc(m: Message, allocator := context.temp_allocator) -> string {
	return message_format_with(MESSAGE_FORMAT[m.id], m, allocator)
}

// message_format_with fills `format` (a translation of the message's msgid)
// with the message's arguments.
message_format_with :: proc(format: string, m: Message, allocator := context.temp_allocator) -> string {
	a: [MESSAGE_MAX_ARGS]any
	for i in 0 ..< m.nargs {
		a[i] = m.args[i]
	}
	return fmt.aprintf(format, ..a[:m.nargs], allocator = allocator)
}
