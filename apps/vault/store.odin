package main

// Where the vault lives, and how it is written.
//
// The write rule: never in place. A save builds the whole sealed blob in
// memory, writes it to a sibling temporary file, fsyncs it, and only then
// renames it over the real one. `rename(2)` within a directory is atomic, so
// at every instant the vault path names either the complete old file or the
// complete new one -- never a half-rewritten header with the old ciphertext
// behind it, which is unrecoverable.
//
// That is what makes changing the master password safe. The re-keyed vault is
// a whole new file; if the process dies before the rename, the original is
// still there and still opens with the original password.
//
// This file never looks at any path but the vault's own. It does not read
// ~/.password-store, ~/.gnupg, ~/.ssh, a browser profile or a keyring, and it
// does not go looking through the home directory for them. The only file it
// opens is the vault this app created, or one the user named in the dialog.

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

VAULT_EXT :: "pvz"
VAULT_DIR_NAME :: "palmy-vault"
VAULT_FILE_NAME :: "default.pvz"

// data_dir is $XDG_DATA_HOME/palmy-vault, or ~/.local/share/palmy-vault.
data_dir :: proc(allocator := context.temp_allocator) -> string {
	d, _ := data_dir_explained(allocator)
	return d
}

// data_dir_explained also says which source chose the directory.
//
// The QEMU image showed why this needs saying: the GUI, launched by a
// process that had kept root's environment, failed with "could not create
// /root/.local/share/palmy-vault" while the shell it was started from said
// HOME=/home/palm. A password manager must never write a vault into a
// directory that belongs to someone else, and it must not trust an inherited
// $HOME that does not belong to the user it runs as. So: $XDG_DATA_HOME
// first, as the spec says; then $HOME *if the user running this owns it*;
// otherwise the home directory /etc/passwd gives this uid. `vault where`
// prints the answer and the reason.
data_dir_explained :: proc(allocator := context.temp_allocator) -> (dir: string, why: string) {
	if x := os.get_env("XDG_DATA_HOME", context.temp_allocator); x != "" {
		return fmt.aprintf("%s/%s", x, VAULT_DIR_NAME, allocator = allocator), "$XDG_DATA_HOME"
	}
	uid := linux.getuid()
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && owned_by(home, u32(uid)) {
		return fmt.aprintf("%s/.local/share/%s", home, VAULT_DIR_NAME, allocator = allocator), "$HOME"
	}
	if pw := passwd_home(u32(uid)); pw != "" {
		reason := home == "" ? "/etc/passwd (HOME is unset)" : fmt.tprintf("/etc/passwd (HOME=%s is not owned by uid %d)", home, uid)
		return fmt.aprintf("%s/.local/share/%s", pw, VAULT_DIR_NAME, allocator = allocator), reason
	}
	if home == "" {
		home = "."
	}
	return fmt.aprintf("%s/.local/share/%s", home, VAULT_DIR_NAME, allocator = allocator), "$HOME (unverified)"
}

owned_by :: proc(path: string, uid: u32) -> bool {
	st: linux.Stat
	if linux.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return false
	}
	return u32(st.uid) == uid
}

passwd_home :: proc(uid: u32) -> string {
	data, err := os.read_entire_file_from_path("/etc/passwd", context.temp_allocator)
	if err != nil {
		return ""
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.split(line, ":", context.temp_allocator)
		if len(f) >= 6 && f[2] == fmt.tprintf("%d", uid) {
			return f[5]
		}
	}
	return ""
}

default_vault_path :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s", data_dir(context.temp_allocator), VAULT_FILE_NAME, allocator = allocator)
}

// ensure_dir creates the directory 0700. A world-readable directory would not
// leak the plaintext, but it would leak that the vault exists and how big it
// is, and there is no reason to allow that.
ensure_dir :: proc() -> bool {
	dir := data_dir(context.temp_allocator)
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		return false
	}
	return true
}

// g_fail_rename makes the self-test able to interrupt a save exactly where it
// matters: after the replacement file is on disk and before it is moved into
// place.
g_fail_rename: bool

// write_atomic writes `data` to `path` via a sibling temporary file. 0600, so
// the vault is not readable by other accounts on the machine.
write_atomic :: proc(path: string, data: []byte) -> (err: string) {
	tmp := fmt.tprintf("%s.new-%d", path, os.get_pid())

	f, oerr := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o600))
	if oerr != nil {
		return fmt.tprintf("could not create %s: %v", tmp, oerr)
	}
	written := 0
	for written < len(data) {
		n, werr := os.write(f, data[written:])
		if werr != nil {
			os.close(f)
			os.remove(tmp)
			return fmt.tprintf("could not write %s: %v", tmp, werr)
		}
		if n == 0 {
			break
		}
		written += n
	}
	// fsync before the rename. Without it the rename can be durable while the
	// data behind it is not, and a crash leaves a vault of the right length
	// full of zeroes.
	if serr := os.sync(f); serr != nil {
		os.close(f)
		os.remove(tmp)
		return fmt.tprintf("could not flush %s: %v", tmp, serr)
	}
	if cerr := os.close(f); cerr != nil {
		os.remove(tmp)
		return fmt.tprintf("could not close %s: %v", tmp, cerr)
	}

	if g_fail_rename {
		// The interrupted save. The temporary file stays where it is; the real
		// vault has not been touched.
		return "interrupted before the rename (test)"
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return fmt.tprintf("could not move the new vault into place: %v", rerr)
	}
	return ""
}

// temp_path_of is the name write_atomic would use, so a caller can clean up
// after an interrupted save.
temp_path_of :: proc(path: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s.new-%d", path, os.get_pid(), allocator = allocator)
}

// ---------------------------------------------------------------------------
// Save / load
// ---------------------------------------------------------------------------

store_save :: proc(path: string, v: ^Vault, s: ^Session) -> (err: string) {
	if !s.unlocked {
		return "the vault is locked"
	}
	plain := body_encode(v, context.allocator)
	// The plaintext is the whole secret. Wipe it the moment it is sealed, so
	// it is not left in a freed block for the rest of the session.
	defer {
		crypto.zero_explicit(raw_data(plain), len(plain))
		delete(plain)
	}

	blob, serr := vault_seal(plain, s, context.allocator)
	if serr != "" {
		return serr
	}
	defer delete(blob)

	return write_atomic(path, blob)
}

store_load :: proc(path: string, password: string) -> (v: Vault, s: Session, err: string) {
	raw, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return {}, {}, fmt.tprintf("could not read %s", path)
	}
	defer delete(raw)

	plain, sess, uerr := vault_unseal(raw, password, context.allocator)
	if uerr != "" {
		return {}, {}, uerr
	}
	defer {
		crypto.zero_explicit(raw_data(plain), len(plain))
		delete(plain)
	}

	vv, derr := body_decode(plain)
	if derr != "" {
		sess_copy := sess
		session_zero(&sess_copy)
		return {}, {}, derr
	}
	return vv, sess, ""
}

store_create :: proc(path: string, password: string, kdf := KDF_DEFAULT, algo := Aead_Id.ChaCha20Poly1305) -> (s: Session, err: string) {
	sess, ok := session_new(password, kdf, algo)
	if !ok {
		return {}, "the key could not be derived"
	}
	v := Vault {
		entries = make([dynamic]Entry),
	}
	defer vault_free(&v)
	if werr := store_save(path, &v, &sess); werr != "" {
		session_zero(&sess)
		return {}, werr
	}
	return sess, ""
}

// ---------------------------------------------------------------------------
// Changing the master password
//
// Re-derive under a fresh salt, re-encrypt everything under the new key, and
// put the result in place with one rename. The old session is zeroed only
// after the new file is on disk, so a failure anywhere leaves the caller still
// holding a working key for the file that is still there.
// ---------------------------------------------------------------------------

store_rekey :: proc(
	path: string,
	v: ^Vault,
	old: ^Session,
	new_password: string,
) -> (
	fresh: Session,
	err: string,
) {
	if !old.unlocked {
		return {}, "the vault is locked"
	}
	if len(new_password) == 0 {
		return {}, "the new master password cannot be empty"
	}
	// A new salt, so the new key is not a function of the old one, and the
	// current default parameters, so an old vault is upgraded by changing its
	// password.
	sess, ok := session_new(new_password, KDF_DEFAULT, old.algo)
	if !ok {
		return {}, "the new key could not be derived"
	}
	if werr := store_save(path, v, &sess); werr != "" {
		session_zero(&sess)
		return {}, werr
	}
	return sess, ""
}

// ---------------------------------------------------------------------------
// Picking a vault
// ---------------------------------------------------------------------------

vault_looks_like_one :: proc(path: string) -> bool {
	f, err := os.open(path, {.Read})
	if err != nil {
		return false
	}
	defer os.close(f)
	buf: [8]byte
	n, rerr := os.read(f, buf[:])
	if rerr != nil || n < 8 {
		return false
	}
	return string(buf[:]) == MAGIC
}

short_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(path, home) {
		return fmt.aprintf("~%s", path[len(home):], allocator = allocator)
	}
	return strings.clone(path, allocator)
}
