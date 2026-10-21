// clip-check: one end of a clipboard transfer, for apps/tools/clip-check.sh.
//
//	clip-check set <file> [seconds]   own the clipboard with the file's bytes
//	                                  and serve it for that long (default 10)
//	clip-check get [primary]          print the clipboard's size and FNV-1a hash
//	clip-check watch <seconds>        print each offer: types, size, hash
//
// Whichever backend palmy picks (PALMY_BACKEND=x11 forces X11). Output lines:
// OWNED, GOT <bytes> <hash>, NONE, OFFER <types> <bytes> <hash>.
package clip_check

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."

fnv :: proc(b: string) -> u64 {
	h := u64(0xcbf29ce484222325)
	for c in transmute([]u8)b {
		h = (h ~ u64(c)) * 0x100000001b3
	}
	return h
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: clip-check set <file> [seconds] | get [primary] | watch <seconds>")
		os.exit(2)
	}
	mode := os.args[1]
	app, err := p.create({title = "clip-check", app_id = "clip-check", width = 200, height = 100})
	if err != "" {
		fmt.eprintln(err)
		os.exit(1)
	}
	defer p.destroy(app)

	switch mode {
	case "set":
		data, rerr := os.read_entire_file(os.args[2], context.allocator)
		if rerr != nil {
			fmt.eprintln("cannot read", os.args[2])
			os.exit(1)
		}
		secs := 10
		if len(os.args) > 3 {
			secs, _ = strconv.parse_int(os.args[3])
		}
		// One frame first, so the window exists and is mapped.
		ui, _ := p.frames(app)
		p.text(ui, "clip-check: serving")
		if !p.clipboard_set(app, string(data)) {
			fmt.println("REFUSED")
			os.exit(1)
		}
		fmt.printfln("OWNED %d %x", len(data), fnv(string(data)))
		os.flush(os.stdout)
		deadline := time.time_add(time.now(), time.Duration(secs) * time.Second)
		for ui in p.frames(app) {
			p.text(ui, "clip-check: serving")
			if time.since(deadline) > 0 {
				break
			}
			p.wake_after(ui, 200 * time.Millisecond)
		}
	case "get":
		ui, _ := p.frames(app)
		p.text(ui, "clip-check: reading")
		primary := len(os.args) > 2 && os.args[2] == "primary"
		text: string
		ok: bool
		if primary {
			text, ok = p.primary_get(app)
		} else {
			text, ok = p.clipboard_get(app)
		}
		if !ok {
			fmt.println("NONE")
		} else {
			fmt.printfln("GOT %d %x", len(text), fnv(text))
		}
	case "watch":
		secs := 5
		if len(os.args) > 2 {
			secs, _ = strconv.parse_int(os.args[2])
		}
		fmt.printfln("WATCH %v", p.clipboard_watch(app))
		os.flush(os.stdout)
		deadline := time.time_add(time.now(), time.Duration(secs) * time.Second)
		for ui in p.frames(app) {
			p.text(ui, "clip-check: watching")
			for offer in p.clipboard_next_offer(ui) {
				mime := ""
				for t in offer.types {
					if strings.has_prefix(t, "text/plain") || t == "UTF8_STRING" {
						mime = t
						break
					}
				}
				data, rerr := p.clipboard_offer_read(ui, offer, mime)
				fmt.printfln("OFFER %v %d %x %v", offer.types, len(data), fnv(string(data)), rerr)
				delete(data)
				os.flush(os.stdout)
			}
			if time.since(deadline) > 0 {
				break
			}
			p.wake_after(ui, 200 * time.Millisecond)
		}
	}
	os.flush(os.stdout)
}
