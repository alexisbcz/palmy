package main

// The Emergency Kit: one printable page with the Secret Key on it, and the
// same as plain text. It is rendered by palmy offscreen in fixed colours
// (paper is white whatever the theme), at A4 and 150 dpi.
//
// It deliberately has no place filled in for the master password: there is
// a box to write it by hand, which is the point of a paper kit (1Password
// does the same). Both files are 0600 and the page says to delete them once
// the kit is printed or copied somewhere safe.

import "core:fmt"
import "core:os"
import "core:time"
import ck "../cloudkit"
import kit "kit:."
import p "palmy:."

KIT_W :: 1240
KIT_H :: 1754

kit_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{{"Geist-400.ttf", .Regular}, {"Geist-500.ttf", .Medium}, {"Geist-600.ttf", .Semibold}, {"Geist-700.ttf", .Bold}}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSans-Mono.ttf",
	}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
}

today :: proc() -> string {
	y, m, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
}

write_kit :: proc(dir, secret, email, url: string) -> (png, txt: string, err: string) {
	if e := os.make_directory_all(dir, os.perm(0o700)); e != nil && !os.exists(dir) {
		return "", "", fmt.tprintf("cannot create %s", dir)
	}
	png = fmt.aprintf("%s/Palmframe Emergency Kit.png", dir)
	txt = fmt.aprintf("%s/Palmframe Emergency Kit.txt", dir)
	host := ck.machine_name()

	// The text, first: it is what survives every printer.
	b := make([dynamic]u8, context.temp_allocator)
	line :: proc(b: ^[dynamic]u8, s: string) {
		append(b, ..transmute([]u8)s)
		append(b, '\n')
	}
	line(&b, tr("Palmframe Emergency Kit"))
	line(&b, trf("Created %s on %s", today(), host))
	line(&b, "")
	line(&b, fmt.tprintf("%s: %s", tr("Account"), email))
	line(&b, fmt.tprintf("%s: %s", tr("Server"), url))
	line(&b, fmt.tprintf("%s: %s", tr("Secret Key"), secret))
	line(&b, fmt.tprintf("%s: ______________________________", tr("Master password")))
	line(&b, "")
	line(&b, tr("To open your vault on a new computer you need this Secret Key and your master password."))
	line(&b, tr("Keep this page somewhere safe: a drawer, a safe, with your passport. Then delete this file."))
	line(&b, tr("Palmframe cannot recover either of them for you."))
	if !write_text(txt, string(b[:]), private = true) {
		return "", "", fmt.tprintf("cannot write %s", txt)
	}

	off := p.offscreen_create(KIT_W, KIT_H, 1, "w-full h-full bg-white text-[#18181b]")
	defer p.offscreen_destroy(off)
	kit_fonts(&off.fonts)
	p.set_text_gamma(1.8)
	ui := p.offscreen_begin(off)
	kit_page(ui, secret, email, url, host)
	p.offscreen_end(off)
	if !p.offscreen_write_png(off, png) {
		return "", "", fmt.tprintf("cannot write %s", png)
	}
	os.chmod(png, {.Read_User, .Write_User})
	return
}

kit_page :: proc(ui: ^p.Ctx, secret, email, url, host: string) {
	p.col(ui, "w-full h-full bg-white px-[110] py-[120] gap-14")
	if is_rtl() {
		p.apply(ui, "dir-rtl")
	}
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-5")
	p.div(ui, "size-16 rounded-2xl bg-[#18181b] items-center justify-center")
	p.icon(ui, WI_PACKAGE, "size-9 text-white")
	p.end(ui)
	p.col(ui, "flex-1 gap-1")
	txt(ui, tr("Palmframe Emergency Kit"), "text-5xl font-semibold tracking-tight text-[#18181b]")
	txt(ui, trf("Created %s on %s", today(), host), "text-xl text-[#71717a]")
	p.end(ui)
	p.end(ui)

	txt(ui, tr("To open your vault on a new computer you need this Secret Key and your master password."), "text-2xl text-[#3f3f46]")

	p.col(ui, "w-full gap-8 p-12 rounded-3xl border-2 border-[#e4e4e7]")
	kit_line(ui, tr("Account"), email)
	kit_line(ui, tr("Server"), url)
	p.col(ui, "w-full gap-3")
	txt(ui, tr("Secret Key"), "text-xl font-medium text-[#71717a]")
	p.div(ui, "w-full px-8 py-7 rounded-2xl bg-[#f4f4f5] border-2 border-[#d4d4d8]")
	text(ui, secret, "text-[44px] font-mono font-semibold text-[#18181b] dir-ltr")
	p.end(ui)
	p.end(ui)
	p.col(ui, "w-full gap-3")
	txt(ui, tr("Master password"), "text-xl font-medium text-[#71717a]")
	p.div(ui, "w-full h-[110] rounded-2xl border-2 border-dashed border-[#a1a1aa]")
	p.end(ui)
	txt(ui, tr("Write it here by hand, or keep it only in your head."), "text-lg text-[#71717a]")
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full gap-4")
	for s in ([?]string {
			N("Keep this page somewhere safe: a drawer, a safe, with your passport. Then delete this file."),
			N("Palmframe cannot recover either of them for you."),
		}) {
		p.row(ui, "w-full items-start gap-4")
		p.div(ui, "size-3 mt-3 rounded-full bg-[#18181b] shrink-0")
		p.end(ui)
		txt(ui, tr(s), "flex-1 text-2xl text-[#3f3f46]")
		p.end(ui)
	}
	p.end(ui)
}

kit_line :: proc(ui: ^p.Ctx, label, value: string) {
	p.col(ui, "w-full gap-2")
	txt(ui, label, "text-xl font-medium text-[#71717a]")
	text(ui, value, "text-3xl font-mono text-[#18181b] dir-ltr")
	p.end(ui)
}
