// x11-hidden-check: a window that animates for ever, for x11-hidden-check.sh.
package x11_hidden_check

import "core:fmt"
import "core:os"
import p "palmy:."

main :: proc() {
	app, err := p.create({title = "x11-hidden-check", app_id = "x11-hidden-check", width = 300, height = 200, always = true})
	if err != "" {
		fmt.eprintln(err)
		os.exit(1)
	}
	defer p.destroy(app)
	for ui in p.frames(app) {
		p.text(ui, fmt.tprintf("%.2f", p.elapsed(ui)), "text-3xl text-white")
	}
}
