package main

// Importing from other password managers, and exporting.
//
//   bitwarden-json   Bitwarden's unencrypted JSON export (logins, notes,
//                    cards, identities, SSH keys, passkeys, custom fields,
//                    password history, folders as tags)
//   bitwarden-csv    Bitwarden's CSV (logins and notes only, by design)
//   1pux             1Password's export: a zip holding export.data (JSON)
//   kdbx             KeePass / KeePassXC databases, KDBX 4 (kdbx.odin)
//   chrome           Chrome/Chromium "Export passwords" CSV
//   firefox          Firefox "Export Logins" CSV
//   pvz              another palmy vault file, with its own password
//
// An import never touches the network and never writes the source file. Every
// entry it produces is a new item with a new id; nothing is merged into an
// existing item, so an import can be undone by deleting what it added.
//
// The parsers read files a person chose, but they are still parsers of
// someone else's format: a malformed file is an error or a skipped row with a
// warning, never a crash and never a half-built entry.

import "core:bytes"
import "core:compress/zlib"
import "core:crypto"
import "core:encoding/csv"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

BOM :: "\xef\xbb\xbf"

Import_Result :: struct {
	format:   string,
	entries:  [dynamic]Entry,
	warnings: [dynamic]string,
	skipped:  int,
	err:      string,
}

import_result_free :: proc(r: ^Import_Result) {
	for &e in r.entries {
		entry_free(&e)
	}
	delete(r.entries)
	for w in r.warnings {
		delete(w)
	}
	delete(r.warnings)
}

warn :: proc(r: ^Import_Result, format: string, args: ..any) {
	append(&r.warnings, fmt.aprintf(format, ..args))
}

import_path :: proc(path, format: string, source_password := "") -> (r: Import_Result) {
	r.entries = make([dynamic]Entry)
	r.warnings = make([dynamic]string)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		r.err = fmt.tprintf("cannot read %s", path)
		return
	}
	defer {
		zero_bytes(data)
		delete(data)
	}
	f := format
	if f == "" || f == "auto" {
		f = detect_format(path, data)
	}
	r.format = f
	switch f {
	case "bitwarden-json":
		import_bitwarden_json(&r, string(data))
	case "bitwarden-csv", "chrome", "firefox":
		import_csv(&r, string(data), f)
	case "1pux":
		import_1pux(&r, data)
	case "kdbx":
		import_kdbx(&r, data, source_password)
	case "pvz":
		import_pvz(&r, data, source_password)
	case:
		r.err = "the file's format was not recognised; name it with --format"
	}
	return
}

zero_bytes :: proc(b: []byte) {
	if len(b) > 0 {
		crypto.zero_explicit(raw_data(b), len(b))
	}
}

detect_format :: proc(path: string, data: []byte) -> string {
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case len(data) >= 8 && get_u32le(data[0:4]) == 0x9AA2D903 && get_u32le(data[4:8]) == 0xB54BFB67:
		return "kdbx"
	case len(data) >= 8 && string(data[:8]) == MAGIC:
		return "pvz"
	case len(data) >= 4 && data[0] == 'P' && data[1] == 'K' && data[2] == 3 && data[3] == 4:
		return "1pux"
	case strings.has_suffix(lower, ".1pux"):
		return "1pux"
	}
	text := strings.trim_left_space(string(data))
	text = strings.trim_prefix(text, BOM)
	if strings.has_prefix(text, "{") {
		return "bitwarden-json"
	}
	nl := strings.index_byte(text, '\n')
	head := strings.to_lower(strings.trim_space(nl < 0 ? text : text[:nl]), context.temp_allocator)
	head, _ = strings.replace_all(head, "\"", "", context.temp_allocator)
	switch {
	case strings.has_prefix(head, "folder,favorite,type,name"):
		return "bitwarden-csv"
	case strings.has_prefix(head, "url,username,password,httprealm"):
		return "firefox"
	case strings.has_prefix(head, "name,url,username,password"):
		return "chrome"
	}
	return ""
}

// ---------------------------------------------------------------------------
// TOTP in whatever shape it arrives: a bare base32 secret, or an otpauth://
// URI with its own digits, period and algorithm.
// ---------------------------------------------------------------------------

set_totp_from :: proc(e: ^Entry, s: string) -> bool {
	t := strings.trim_space(s)
	if t == "" {
		return true
	}
	if strings.has_prefix(strings.to_lower(t, context.temp_allocator), "otpauth://") {
		q := strings.index_byte(t, '?')
		if q < 0 {
			return false
		}
		if strings.contains(strings.to_lower(t[:q], context.temp_allocator), "hotp") {
			return false // counter-based codes are not supported
		}
		secret := ""
		for kv in strings.split(t[q + 1:], "&", context.temp_allocator) {
			eq := strings.index_byte(kv, '=')
			if eq < 0 {
				continue
			}
			k, v := strings.to_lower(kv[:eq], context.temp_allocator), url_unescape(kv[eq + 1:])
			switch k {
			case "secret":
				secret = v
			case "digits":
				if n, ok := strconv.parse_int(v); ok && (n == 6 || n == 8) {
					e.totp_digits = u8(n)
				}
			case "period":
				if n, ok := strconv.parse_int(v); ok && n > 0 && n <= 3600 {
					e.totp_period = u32(n)
				}
			case "algorithm":
				switch strings.to_upper(v, context.temp_allocator) {
				case "SHA256":
					e.totp_algo = .SHA256
				case "SHA512":
					e.totp_algo = .SHA512
				}
			}
		}
		t = secret
	}
	if !totp_secret_ok(t) {
		return false
	}
	replace_secret(&e.totp, strings.to_upper(t, context.temp_allocator))
	if e.kind == .Login && e.password == "" && e.username == "" {
		e.kind = .Totp
	}
	return true
}

url_unescape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok {
				strings.write_byte(&sb, u8(v))
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, s[i] == '+' ? ' ' : s[i])
	}
	return strings.to_string(sb)
}

// iso_unix reads "2024-03-01T12:34:56(.sss)Z" (what Bitwarden writes) or a
// plain number of seconds or milliseconds; 0 when it is neither.
iso_unix :: proc(s: string) -> i64 {
	if s == "" {
		return 0
	}
	if n, ok := strconv.parse_i64(s); ok {
		return n > 100_000_000_000 ? n / 1000 : n
	}
	if len(s) < 19 {
		return 0
	}
	y, _ := strconv.parse_int(s[0:4])
	mo, _ := strconv.parse_int(s[5:7])
	d, _ := strconv.parse_int(s[8:10])
	h, _ := strconv.parse_int(s[11:13])
	mi, _ := strconv.parse_int(s[14:16])
	se, _ := strconv.parse_int(s[17:19])
	t, ok := time.datetime_to_time(y, mo, d, h, mi, se)
	if !ok {
		return 0
	}
	return time.time_to_unix(t)
}

// ---------------------------------------------------------------------------
// Bitwarden JSON
// ---------------------------------------------------------------------------

@(private = "file")
jstr :: proc(v: json.Value, keys: ..string) -> string {
	cur := v
	for k in keys {
		o, ok := cur.(json.Object)
		if !ok {
			return ""
		}
		cur = o[k] or_else nil
	}
	#partial switch x in cur {
	case json.String:
		return string(x)
	case json.Integer:
		return fmt.tprintf("%d", x)
	case json.Float:
		return fmt.tprintf("%v", x)
	}
	return ""
}

@(private = "file")
jget :: proc(v: json.Value, keys: ..string) -> json.Value {
	cur := v
	for k in keys {
		o, ok := cur.(json.Object)
		if !ok {
			return nil
		}
		cur = o[k] or_else nil
	}
	return cur
}

@(private = "file")
jarr :: proc(v: json.Value) -> []json.Value {
	if a, ok := v.(json.Array); ok {
		return a[:]
	}
	return nil
}

@(private = "file")
jbool :: proc(v: json.Value, key: string) -> bool {
	if b, ok := jget(v, key).(json.Boolean); ok {
		return bool(b)
	}
	return false
}

import_bitwarden_json :: proc(r: ^Import_Result, text: string) {
	v, err := json.parse_string(text, .JSON5, true, context.temp_allocator)
	if err != .None {
		r.err = "the Bitwarden file is not valid JSON"
		return
	}
	if jbool(v, "encrypted") || jget(v, "passwordProtected") != nil {
		r.err = "this is an encrypted Bitwarden export, which only Bitwarden can open: export again as \"JSON\" (unencrypted), import, then delete that file"
		return
	}
	folders := make(map[string]string, context.temp_allocator)
	for f in jarr(jget(v, "folders")) {
		folders[jstr(f, "id")] = jstr(f, "name")
	}
	for it in jarr(jget(v, "items")) {
		name := strings.trim_space(jstr(it, "name"))
		if name == "" {
			name = "Untitled"
		}
		e := entry_new(name)
		replace_secret(&e.notes, jstr(it, "notes"))
		e.favorite = jbool(it, "favorite")
		if fid := jstr(it, "folderId"); fid != "" {
			if fname, ok := folders[fid]; ok && fname != "" {
				entry_set_tags(&e, fname)
			}
		}
		if c := iso_unix(jstr(it, "creationDate")); c > 0 {
			e.created = c
		}
		if m := iso_unix(jstr(it, "revisionDate")); m > 0 {
			e.modified = m
		}
		t, _ := strconv.parse_int(jstr(it, "type"))
		switch t {
		case 1:
			e.kind = .Login
			replace_string(&e.username, jstr(it, "login", "username"))
			replace_secret(&e.password, jstr(it, "login", "password"))
			for u, i in jarr(jget(it, "login", "uris")) {
				uri := jstr(u, "uri")
				if uri == "" {
					continue
				}
				if i == 0 || e.url == "" {
					replace_string(&e.url, uri)
				} else {
					append(&e.urls, strings.clone(uri))
				}
			}
			if !set_totp_from(&e, jstr(it, "login", "totp")) {
				warn(r, "%s: the TOTP secret was not understood and was kept as a note field", name)
				field_set(&e, "TOTP (unrecognised)", jstr(it, "login", "totp"), true)
			}
			for pk in jarr(jget(it, "login", "fido2Credentials")) {
				if e.passkey.credential_id != "" {
					warn(r, "%s: has more than one passkey; only the first was imported", name)
					break
				}
				e.passkey = Passkey {
					credential_id = strings.clone(jstr(pk, "credentialId")),
					rp_id         = strings.clone(jstr(pk, "rpId")),
					rp_name       = strings.clone(jstr(pk, "rpName")),
					user_handle   = strings.clone(jstr(pk, "userHandle")),
					user_name     = strings.clone(jstr(pk, "userName")),
					key           = strings.clone(jstr(pk, "keyValue")),
					created       = iso_unix(jstr(pk, "creationDate")),
					discoverable  = jstr(pk, "discoverable") == "true" || jbool(pk, "discoverable"),
				}
				if n, ok := strconv.parse_int(jstr(pk, "counter")); ok {
					e.passkey.counter = u32(n)
				}
				if e.password == "" {
					e.kind = .Passkey
				}
			}
		case 2:
			e.kind = .Note
		case 3:
			e.kind = .Card
			for pair in ([?][2]string{{"cardholderName", "Cardholder"}, {"brand", "Brand"}, {"number", "Number"},
				{"expMonth", "Expiry month"}, {"expYear", "Expiry year"}, {"code", "Security code"}}) {
				if val := jstr(it, "card", pair[0]); val != "" {
					field_set(&e, pair[1], val, pair[0] == "number" || pair[0] == "code")
				}
			}
		case 4, 6, 7, 8:
			e.kind = .Document
			sub := t == 4 ? "identity" : (t == 6 ? "bankAccount" : (t == 7 ? "driversLicense" : "passport"))
			if o, ok := jget(it, sub).(json.Object); ok {
				for k, val in o {
					s := jstr(val)
					if s == "" {
						continue
					}
					secret := k == "ssn" || k == "passportNumber" || k == "licenseNumber" || strings.contains(strings.to_lower(k, context.temp_allocator), "number")
					field_set(&e, k, s, secret)
				}
			}
		case 5:
			e.kind = .Note
			field_set(&e, "Private key", jstr(it, "sshKey", "privateKey"), true)
			field_set(&e, "Public key", jstr(it, "sshKey", "publicKey"), false)
			field_set(&e, "Fingerprint", jstr(it, "sshKey", "keyFingerprint"), false)
		case:
			warn(r, "%s: Bitwarden item type %d is not known here; imported as a note", name, t)
			e.kind = .Note
		}
		for f in jarr(jget(it, "fields")) {
			ft, _ := strconv.parse_int(jstr(f, "type"))
			if ft == 3 {
				continue // a "linked" field points at another field; nothing to store
			}
			label := jstr(f, "name")
			if label == "" {
				label = "Field"
			}
			field_set(&e, label, jstr(f, "value"), ft == 1)
		}
		for h in jarr(jget(it, "passwordHistory")) {
			pw := jstr(h, "password")
			if pw != "" && len(e.history) < MAX_HISTORY {
				append(&e.history, Hist{iso_unix(jstr(h, "lastUsedDate")), strings.clone(pw)})
			}
		}
		if jstr(it, "deletedDate") != "" {
			warn(r, "%s: was in Bitwarden's trash and was skipped", name)
			entry_free(&e)
			r.skipped += 1
			continue
		}
		append(&r.entries, e)
	}
}

// ---------------------------------------------------------------------------
// CSV: Bitwarden, Chrome, Firefox
// ---------------------------------------------------------------------------

import_csv :: proc(r: ^Import_Result, text: string, format: string) {
	t := strings.trim_prefix(text, BOM)
	rd: csv.Reader
	csv.reader_init_with_string(&rd, t, context.temp_allocator)
	rd.lazy_quotes = true
	rd.fields_per_record = -1
	rd.reuse_record = false
	defer csv.reader_destroy(&rd)
	header: []string
	col := make(map[string]int, context.temp_allocator)
	line := 0
	for {
		rec, err := csv.read(&rd, context.temp_allocator)
		if err != nil {
			if csv.is_io_error(err, .EOF) {
				break
			}
			r.err = fmt.tprintf("the CSV is malformed near record %d", line + 1)
			return
		}
		line += 1
		if header == nil {
			header = rec
			for h, i in header {
				col[strings.to_lower(strings.trim_space(h), context.temp_allocator)] = i
			}
			continue
		}
		get :: proc(rec: []string, col: map[string]int, name: string) -> string {
			if i, ok := col[name]; ok && i < len(rec) {
				return rec[i]
			}
			return ""
		}
		switch format {
		case "chrome":
			url := get(rec, col, "url")
			title := get(rec, col, "name")
			if title == "" {
				title = host_of(url)
			}
			e := entry_new(title)
			replace_string(&e.url, url)
			replace_string(&e.username, get(rec, col, "username"))
			replace_secret(&e.password, get(rec, col, "password"))
			replace_secret(&e.notes, get(rec, col, "note"))
			append(&r.entries, e)
		case "firefox":
			url := get(rec, col, "url")
			if strings.has_prefix(url, "chrome://") {
				r.skipped += 1
				continue // Firefox's own internal logins
			}
			e := entry_new(host_of(url))
			replace_string(&e.url, url)
			replace_string(&e.username, get(rec, col, "username"))
			replace_secret(&e.password, get(rec, col, "password"))
			if c := iso_unix(get(rec, col, "timecreated")); c > 0 {
				e.created = c
			}
			if m := iso_unix(get(rec, col, "timepasswordchanged")); m > 0 {
				e.modified = m
			}
			append(&r.entries, e)
		case "bitwarden-csv":
			name := get(rec, col, "name")
			if name == "" {
				name = "Untitled"
			}
			e := entry_new(name)
			if get(rec, col, "type") == "note" {
				e.kind = .Note
			}
			if f := get(rec, col, "folder"); f != "" {
				entry_set_tags(&e, f)
			}
			e.favorite = get(rec, col, "favorite") == "1"
			replace_secret(&e.notes, get(rec, col, "notes"))
			replace_string(&e.url, first_line(get(rec, col, "login_uri")))
			replace_string(&e.username, get(rec, col, "login_username"))
			replace_secret(&e.password, get(rec, col, "login_password"))
			if !set_totp_from(&e, get(rec, col, "login_totp")) {
				warn(r, "%s: the TOTP secret was not understood", name)
			}
			// Custom fields arrive as "name: value" lines.
			for fl in strings.split_lines(get(rec, col, "fields"), context.temp_allocator) {
				colon := strings.index(fl, ": ")
				if colon > 0 {
					field_set(&e, fl[:colon], fl[colon + 2:], false)
				}
			}
			append(&r.entries, e)
		}
	}
	if header == nil {
		r.err = "the CSV is empty"
	}
}

first_line :: proc(s: string) -> string {
	if i := strings.index_any(s, ",\n"); i >= 0 {
		return s[:i]
	}
	return s
}

host_of :: proc(url: string) -> string {
	u := url
	if i := strings.index(u, "://"); i >= 0 {
		u = u[i + 3:]
	}
	if i := strings.index_any(u, "/?#"); i >= 0 {
		u = u[:i]
	}
	if i := strings.last_index_byte(u, '@'); i >= 0 {
		u = u[i + 1:]
	}
	if u == "" {
		return "Untitled"
	}
	return u
}

// ---------------------------------------------------------------------------
// 1Password 1PUX: a zip with export.data
// ---------------------------------------------------------------------------

import_1pux :: proc(r: ^Import_Result, data: []byte) {
	export, ok := zip_read(data, "export.data", context.temp_allocator)
	if !ok {
		r.err = "this is not a 1Password export: there is no export.data inside the zip"
		return
	}
	defer zero_bytes(export)
	v, err := json.parse(export, .JSON5, true, context.temp_allocator)
	if err != .None {
		r.err = "export.data is not valid JSON"
		return
	}
	for acc in jarr(jget(v, "accounts")) {
		for vault in jarr(jget(acc, "vaults")) {
			vname := jstr(vault, "attrs", "name")
			for it in jarr(jget(vault, "items")) {
				if jstr(it, "state") == "archived" {
					r.skipped += 1
					continue
				}
				ov := jget(it, "overview")
				det := jget(it, "details")
				title := jstr(ov, "title")
				if title == "" {
					title = "Untitled"
				}
				e := entry_new(title)
				if c := iso_unix(jstr(it, "createdAt")); c > 0 {
					e.created = c
				}
				if m := iso_unix(jstr(it, "updatedAt")); m > 0 {
					e.modified = m
				}
				_, fav := jget(it, "favIndex").(json.Integer)
				e.favorite = fav
				replace_string(&e.url, jstr(ov, "url"))
				for u in jarr(jget(ov, "urls")) {
					uu := jstr(u, "url")
					if uu != "" && uu != e.url {
						append(&e.urls, strings.clone(uu))
					}
				}
				tags := make([dynamic]string, context.temp_allocator)
				for t in jarr(jget(ov, "tags")) {
					if s, is := t.(json.String); is {
						append(&tags, string(s))
					}
				}
				if vname != "" && len(tags) == 0 {
					append(&tags, vname)
				}
				entry_set_tags(&e, strings.join(tags[:], ",", context.temp_allocator))
				replace_secret(&e.notes, jstr(det, "notesPlain"))
				switch jstr(it, "categoryUuid") {
				case "001":
					e.kind = .Login
				case "002":
					e.kind = .Card
				case "003":
					e.kind = .Note
				case "004", "006", "103", "106", "108":
					e.kind = .Document
				case "005":
					e.kind = .Login
				case:
					e.kind = .Note
				}
				for lf in jarr(jget(det, "loginFields")) {
					switch jstr(lf, "designation") {
					case "username":
						replace_string(&e.username, jstr(lf, "value"))
					case "password":
						replace_secret(&e.password, jstr(lf, "value"))
					}
				}
				if p := jstr(det, "password"); p != "" && e.password == "" {
					replace_secret(&e.password, p)
				}
				for sec in jarr(jget(det, "sections")) {
					for f in jarr(jget(sec, "fields")) {
						label := jstr(f, "title")
						val := jget(f, "value")
						o, isobj := val.(json.Object)
						if !isobj {
							continue
						}
						for kind, inner in o {
							s := jstr(inner)
							if kind == "creditCardNumber" || kind == "creditCardType" {
								s = jstr(inner)
							}
							if kind == "monthYear" {
								if n, isn := inner.(json.Integer); isn {
									s = fmt.tprintf("%02d/%04d", n % 100, n / 100)
								}
							}
							if kind == "totp" {
								if !set_totp_from(&e, s) {
									warn(r, "%s: a one-time password field was not understood", title)
								}
								continue
							}
							if s == "" {
								continue
							}
							if label == "" {
								label = kind
							}
							field_set(&e, label, s, kind == "concealed" || kind == "creditCardNumber" || kind == "sshKey")
						}
					}
				}
				for h in jarr(jget(det, "passwordHistory")) {
					pw := jstr(h, "value")
					if pw != "" && len(e.history) < MAX_HISTORY {
						append(&e.history, Hist{iso_unix(jstr(h, "time")), strings.clone(pw)})
					}
				}
				append(&r.entries, e)
			}
		}
	}
}

// zip_read finds one member of a zip archive by name and inflates it. Stored
// and deflated members only; that is all a 1PUX uses. The central directory is
// what is trusted for sizes, as every zip reader should.
zip_read :: proc(data: []byte, want: string, allocator := context.allocator) -> (out: []byte, ok: bool) {
	if len(data) < 22 {
		return nil, false
	}
	// End of central directory: search back over a possible comment.
	eocd := -1
	for i := len(data) - 22; i >= max(0, len(data) - 22 - 65535); i -= 1 {
		if get_u32le(data[i:]) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		return nil, false
	}
	count := int(get_u16le(data[eocd + 10:]))
	cd := int(get_u32le(data[eocd + 16:]))
	at := cd
	for _ in 0 ..< count {
		if at + 46 > len(data) || get_u32le(data[at:]) != 0x02014b50 {
			return nil, false
		}
		method := get_u16le(data[at + 10:])
		csize := int(get_u32le(data[at + 20:]))
		usize := int(get_u32le(data[at + 24:]))
		nlen := int(get_u16le(data[at + 28:]))
		xlen := int(get_u16le(data[at + 30:]))
		clen := int(get_u16le(data[at + 32:]))
		local := int(get_u32le(data[at + 42:]))
		if at + 46 + nlen > len(data) {
			return nil, false
		}
		name := string(data[at + 46:at + 46 + nlen])
		at += 46 + nlen + xlen + clen
		if name != want {
			continue
		}
		if local + 30 > len(data) || get_u32le(data[local:]) != 0x04034b50 {
			return nil, false
		}
		lstart := local + 30 + int(get_u16le(data[local + 26:])) + int(get_u16le(data[local + 28:]))
		if lstart + csize > len(data) || usize > 512 << 20 {
			return nil, false
		}
		comp := data[lstart:lstart + csize]
		switch method {
		case 0:
			o := make([]byte, csize, allocator)
			copy(o, comp)
			return o, true
		case 8:
			buf: bytes.Buffer
			if err := zlib.inflate_from_byte_array(comp, &buf, raw = true, expected_output_size = usize); err != nil {
				bytes.buffer_destroy(&buf)
				return nil, false
			}
			o := make([]byte, len(buf.buf), allocator)
			copy(o, buf.buf[:])
			zero_bytes(buf.buf[:])
			bytes.buffer_destroy(&buf)
			return o, true
		}
		return nil, false
	}
	return nil, false
}

// ---------------------------------------------------------------------------
// Another palmy vault
// ---------------------------------------------------------------------------

import_pvz :: proc(r: ^Import_Result, data: []byte, password: string) {
	if password == "" {
		r.err = "a palmy vault needs its own password (--source-password-file)"
		return
	}
	plain, s, err := vault_unseal(data, password, context.allocator)
	if err != "" {
		r.err = err
		return
	}
	sess := s
	session_zero(&sess)
	defer {
		zero_bytes(plain)
		delete(plain)
	}
	v, derr := body_decode(plain)
	if derr != "" {
		r.err = derr
		return
	}
	for &e in v.entries {
		// New ids: an import makes new items, it never claims an existing one.
		delete(e.id)
		e.id = new_uuid()
		append(&r.entries, e)
	}
	delete(v.entries)
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

// export_pvz writes the entries as a new local vault file under its own
// password: the encrypted way to move a vault, or to keep an offline copy.
export_pvz :: proc(v: ^Vault, path: string, password: string) -> string {
	if len(password) < 8 {
		return "an export password shorter than 8 characters is not worth encrypting anything with"
	}
	sess, ok := session_new(password)
	if !ok {
		return "the key could not be derived"
	}
	defer session_zero(&sess)
	return store_save(path, v, &sess)
}

// export_bitwarden_json writes Bitwarden's unencrypted format, which every
// password manager imports. It is the plaintext of everything: the CLI demands
// --yes for it and says so.
export_bitwarden_json :: proc(v: ^Vault) -> string {
	sb := strings.builder_make()
	q :: proc(s: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		json_quote(&b, s)
		return strings.to_string(b)
	}
	strings.write_string(&sb, "{\n  \"encrypted\": false,\n  \"folders\": [],\n  \"items\": [")
	for &e, i in v.entries {
		t := 1
		switch e.kind {
		case .Note:
			t = 2
		case .Card:
			t = 3
		case .Document:
			t = 4
		case .Login, .Passkey, .Totp:
			t = 1
		}
		fmt.sbprintf(&sb, "%s\n    {{\"id\": %s, \"type\": %d, \"name\": %s, \"notes\": %s, \"favorite\": %v, \"folderId\": null",
			i > 0 ? "," : "", q(e.id), t, q(e.title), e.notes == "" ? "null" : q(e.notes), e.favorite)
		fmt.sbprintf(&sb, ", \"creationDate\": %s, \"revisionDate\": %s", q(time_iso(e.created)), q(time_iso(e.modified)))
		if t == 1 {
			strings.write_string(&sb, ", \"login\": {\"uris\": [")
			n := 0
			if e.url != "" {
				fmt.sbprintf(&sb, "{{\"match\": null, \"uri\": %s}}", q(e.url))
				n += 1
			}
			for u in e.urls {
				fmt.sbprintf(&sb, "%s{{\"match\": null, \"uri\": %s}}", n > 0 ? ", " : "", q(u))
				n += 1
			}
			fmt.sbprintf(&sb, "], \"username\": %s, \"password\": %s, \"totp\": %s", q(e.username), q(e.password), e.totp == "" ? "null" : q(e.totp))
			if e.passkey.credential_id != "" {
				pk := &e.passkey
				fmt.sbprintf(&sb, ", \"fido2Credentials\": [{{\"credentialId\": %s, \"keyType\": \"public-key\", \"keyAlgorithm\": \"ECDSA\", \"keyCurve\": \"P-256\", \"keyValue\": %s, \"rpId\": %s, \"rpName\": %s, \"userHandle\": %s, \"userName\": %s, \"counter\": \"%d\", \"discoverable\": \"%v\", \"creationDate\": %s}}]",
					q(pk.credential_id), q(pk.key), q(pk.rp_id), q(pk.rp_name), q(pk.user_handle), q(pk.user_name), pk.counter, pk.discoverable, q(time_iso(pk.created)))
			}
			strings.write_string(&sb, "}")
		} else if t == 2 {
			strings.write_string(&sb, ", \"secureNote\": {\"type\": 0}")
		}
		strings.write_string(&sb, ", \"fields\": [")
		for f, j in e.fields {
			fmt.sbprintf(&sb, "%s{{\"name\": %s, \"value\": %s, \"type\": %d}}", j > 0 ? ", " : "", q(f.label), q(f.value), f.secret ? 1 : 0)
		}
		strings.write_string(&sb, "], \"passwordHistory\": [")
		for h, j in e.history {
			fmt.sbprintf(&sb, "%s{{\"lastUsedDate\": %s, \"password\": %s}}", j > 0 ? ", " : "", q(time_iso(h.when_)), q(h.password))
		}
		strings.write_string(&sb, "]}")
	}
	strings.write_string(&sb, "\n  ]\n}\n")
	return strings.to_string(sb)
}

json_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(b, `\u%04x`, int(r))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}
