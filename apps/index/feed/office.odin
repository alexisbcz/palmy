// Text out of office files: .docx .xlsx .pptx (OOXML) and .odt .ods .odp
// (ODF) are zip archives of XML, so this reads the zip's central directory,
// inflates the one or few XML parts that hold the words, and drops the
// markup. Nothing is rendered and no layout is kept: the index needs words.
//
// The office apps' own importers (apps/docs/office.odin, apps/sheets/
// xlsx.odin) are `package main` and can't be imported, and running
// `docs --convert` per file would start a GUI-capable binary for every
// document on the disk. This is a few hundred lines with no dependency
// beyond core:compress/zlib.
//
// PDF text comes from `pdftotext` (poppler) when it is installed, the same
// tool apps/reader uses. Palmy doesn't ship poppler yet, so on the
// image a PDF is found by its name only; search.md lists it as a gap.
package indexfeed

import "core:bytes"
import "core:compress/zlib"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Office_Kind :: enum {
	None,
	Docx,
	Xlsx,
	Pptx,
	Odf,
}

office_kind :: proc(name: string) -> Office_Kind {
	n := strings.to_lower(name, context.temp_allocator)
	switch {
	case strings.has_suffix(n, ".docx"):
		return .Docx
	case strings.has_suffix(n, ".xlsx"):
		return .Xlsx
	case strings.has_suffix(n, ".pptx"):
		return .Pptx
	case strings.has_suffix(n, ".odt"), strings.has_suffix(n, ".ods"), strings.has_suffix(n, ".odp"):
		return .Odf
	}
	return .None
}

Zip_Entry :: struct {
	name:   string,
	method: u16,
	csize:  u32,
	usize:  u32,
	local:  u32,
}

@(private)
le16 :: proc(b: []u8, at: int) -> u16 {
	return u16(b[at]) | u16(b[at + 1]) << 8
}
@(private)
le32 :: proc(b: []u8, at: int) -> u32 {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

zip_entries :: proc(data: []u8) -> (out: [dynamic]Zip_Entry, ok: bool) {
	out = make([dynamic]Zip_Entry, context.temp_allocator)
	if len(data) < 22 {
		return out, false
	}
	eocd := -1
	for i := len(data) - 22; i >= max(0, len(data) - 22 - 65535); i -= 1 {
		if le32(data, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		return out, false
	}
	n := int(le16(data, eocd + 10))
	at := int(le32(data, eocd + 16))
	for _ in 0 ..< n {
		if at + 46 > len(data) || le32(data, at) != 0x02014b50 {
			return out, false
		}
		nl := int(le16(data, at + 28))
		xl := int(le16(data, at + 30))
		cl := int(le16(data, at + 32))
		if at + 46 + nl > len(data) {
			return out, false
		}
		append(&out, Zip_Entry {
			name = string(data[at + 46:at + 46 + nl]),
			method = le16(data, at + 10),
			csize = le32(data, at + 20),
			usize = le32(data, at + 24),
			local = le32(data, at + 42),
		})
		at += 46 + nl + xl + cl
	}
	return out, true
}

// Parts bigger than this are not inflated: an XML part that size is a data
// dump, not prose, and the index caps a body at 64 KiB anyway.
MAX_PART :: 32 * 1024 * 1024

zip_read :: proc(data: []u8, e: Zip_Entry) -> (out: []u8, ok: bool) {
	at := int(e.local)
	if at + 30 > len(data) || le32(data, at) != 0x04034b50 || e.usize > MAX_PART {
		return nil, false
	}
	start := at + 30 + int(le16(data, at + 26)) + int(le16(data, at + 28))
	end := start + int(e.csize)
	if end > len(data) {
		return nil, false
	}
	switch e.method {
	case 0:
		return data[start:end], true
	case 8:
		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, int(e.usize), context.temp_allocator)
		if err := zlib.inflate_from_byte_array_raw(data[start:end], &buf, true, int(e.usize)); err != nil {
			return nil, false
		}
		return bytes.buffer_to_bytes(&buf), true
	}
	return nil, false
}

// xml_text keeps the character data of an XML document, with a newline
// where a paragraph, heading, row or slide ends and a space where a cell or
// tab does. Entities are decoded.
xml_text :: proc(x: []u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	n := len(x)
	for i < n {
		c := x[i]
		if c == '<' {
			e := i + 1
			for e < n && x[e] != '>' {
				e += 1
			}
			tag := string(x[i + 1:min(e, n)])
			closing := len(tag) > 0 && tag[0] == '/'
			name := tag[closing ? 1 : 0:]
			if sp := strings.index_any(name, " /\t\n"); sp >= 0 {
				name = name[:sp]
			}
			if colon := strings.index_byte(name, ':'); colon >= 0 {
				name = name[colon + 1:]
			}
			switch name {
			case "p", "h", "br", "tr", "row", "sp", "si":
				if closing || strings.has_suffix(tag, "/") {
					strings.write_byte(&b, '\n')
				}
			case "tab", "tc", "c", "table-cell", "s":
				strings.write_byte(&b, ' ')
			}
			i = e + 1
			continue
		}
		if c == '&' {
			semi := -1
			for k in i + 1 ..< min(i + 10, n) {
				if x[k] == ';' {
					semi = k
					break
				}
			}
			if semi > 0 {
				ent := string(x[i + 1:semi])
				r: rune = -1
				switch ent {
				case "amp":
					r = '&'
				case "lt":
					r = '<'
				case "gt":
					r = '>'
				case "quot":
					r = '"'
				case "apos":
					r = '\''
				case:
					if len(ent) > 1 && ent[0] == '#' {
						if ent[1] == 'x' {
							if v, ok := strconv.parse_int(ent[2:], 16); ok {
								r = rune(v)
							}
						} else if v, ok := strconv.parse_int(ent[1:]); ok {
							r = rune(v)
						}
					}
				}
				if r >= 0 {
					strings.write_rune(&b, r)
					i = semi + 1
					continue
				}
			}
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

// office_text extracts the words of an office file held in memory.
office_text :: proc(data: []u8, kind: Office_Kind) -> (text: string, ok: bool) {
	entries, zok := zip_entries(data)
	if !zok {
		return "", false
	}
	b := strings.builder_make(context.temp_allocator)
	add :: proc(b: ^strings.Builder, data: []u8, e: Zip_Entry) -> bool {
		x, ok := zip_read(data, e)
		if !ok {
			return false
		}
		strings.write_string(b, xml_text(x))
		strings.write_byte(b, '\n')
		return true
	}
	any_ := false
	switch kind {
	case .Docx:
		for e in entries {
			if e.name == "word/document.xml" || strings.has_prefix(e.name, "word/footnotes") {
				any_ = add(&b, data, e) || any_
			}
		}
	case .Xlsx:
		for e in entries {
			if e.name == "xl/sharedStrings.xml" {
				any_ = add(&b, data, e) || any_
			}
		}
	case .Pptx:
		// Slides in order: slide1, slide2 … slide10, not as the zip lists them.
		Slide :: struct {
			n: int,
			e: Zip_Entry,
		}
		slides := make([dynamic]Slide, context.temp_allocator)
		for e in entries {
			if strings.has_prefix(e.name, "ppt/slides/slide") && strings.has_suffix(e.name, ".xml") {
				num, _ := strconv.parse_int(e.name[len("ppt/slides/slide"):len(e.name) - 4])
				append(&slides, Slide{num, e})
			}
		}
		slice.sort_by(slides[:], proc(a, b: Slide) -> bool {return a.n < b.n})
		for s in slides {
			any_ = add(&b, data, s.e) || any_
		}
	case .Odf:
		for e in entries {
			if e.name == "content.xml" {
				any_ = add(&b, data, e) || any_
			}
		}
	case .None:
	}
	return strings.to_string(b), any_
}

// pdf_text runs pdftotext on the first 40 pages, when it is installed.
pdf_text :: proc(path: string) -> (string, bool) {
	tool := ""
	for dir in ([?]string{"/usr/bin", "/usr/local/bin", "/bin"}) {
		p := strings.concatenate({dir, "/pdftotext"}, context.temp_allocator)
		if os.exists(p) {
			tool = p
			break
		}
	}
	if tool == "" {
		return "", false
	}
	state, sout, _, err := os.process_exec({command = {tool, "-q", "-l", "40", "-enc", "UTF-8", path, "-"}}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return "", false
	}
	return string(sout), true
}
