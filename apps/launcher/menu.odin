package main

// The context menu.
//
// There is no `xdg_popup` in palmy, so the menu is an absolutely positioned
// panel inside the window with a `z-` class, and the submenu is a second panel
// beside the first. Everything a macOS context menu has is here: a header,
// section labels, separators, leading icons, right-aligned shortcut hints,
// checkbox and radio indicators, a destructive item, items that are disabled
// because the action genuinely is not available, and submenus that open to the
// side.
//
// The menu is a *description* rebuilt every frame from the selected entry, and
// keyboard navigation walks that description. Nothing about the geometry is
// hidden inside the renderer: `menu_height` and `item_offset` agree with the
// classes below, which is what lets the panel be anchored and clamped before a
// single node is created.

import p "palmy:."

MI_Kind :: enum u8 {
	Item,
	Check,
	Radio,
	Sub,
	Sep,
	Head,
	Header,
}

Sub :: enum u8 {
	None,
	Open_With,
	Actions,
	Copy,
	Sort,
}

Act :: enum u8 {
	None,
	Launch,
	Launch_Term,
	Run_In, // arg: index into st.terms
	Desktop_Act, // arg: index into entry.actions
	Copy_Name,
	Copy_Exec,
	Copy_Id,
	Copy_Path,
	Show_Path,
	Open_Folder,
	Edit_Entry,
	Toggle_Term,
	Toggle_Keep,
	Toggle_Pin,
	Sort_Rel,
	Sort_Name,
	Sort_Freq,
	Clear_History,
}

MI :: struct {
	kind:        MI_Kind,
	label:       string,
	note:        string, // second line, Header only
	ic:          p.Icon,
	has_ic:      bool,
	sk:          string, // shortcut hint, right-aligned
	act:         Act,
	arg:         int,
	sub:         Sub,
	on:          bool,
	disabled:    bool,
	destructive: bool,
}

// Geometry, kept in step with the classes in render_menu.
MENU_W :: 286
SUB_W :: 238
ITEM_H :: 28
HEAD_H :: 22
SEP_H :: 9
MENU_HEADER_H :: 40
PANEL_PAD :: 6

row_h :: proc(k: MI_Kind) -> f32 {
	switch k {
	case .Sep:
		return SEP_H
	case .Head:
		return HEAD_H
	case .Header:
		return MENU_HEADER_H
	case .Item, .Check, .Radio, .Sub:
		return ITEM_H
	}
	return ITEM_H
}

menu_height :: proc(items: []MI) -> f32 {
	h := f32(PANEL_PAD * 2)
	for m in items {
		h += row_h(m.kind)
	}
	return h
}

// item_offset is the distance from the top of the panel to the top of item i,
// which is what anchors a submenu to its parent row.
item_offset :: proc(items: []MI, i: int) -> f32 {
	y := f32(PANEL_PAD)
	for m, j in items {
		if j == i {
			break
		}
		y += row_h(m.kind)
	}
	return y
}

selectable :: proc(m: MI) -> bool {
	if m.disabled {
		return false
	}
	switch m.kind {
	case .Item, .Check, .Radio, .Sub:
		return true
	case .Sep, .Head, .Header:
		return false
	}
	return false
}

// first_selectable / step_selection give the menu its keyboard feel: motion
// skips headings and separators, and wraps at the ends the way a real menu
// does.
first_selectable :: proc(items: []MI) -> int {
	for m, i in items {
		if selectable(m) {
			return i
		}
	}
	return -1
}

step_selection :: proc(items: []MI, from, dir: int) -> int {
	if len(items) == 0 {
		return -1
	}
	i := from
	for _ in 0 ..< len(items) {
		i += dir
		if i < 0 {
			i = len(items) - 1
		}
		if i >= len(items) {
			i = 0
		}
		if selectable(items[i]) {
			return i
		}
	}
	return from
}

// ---------------------------------------------------------------------------
// The menu description
// ---------------------------------------------------------------------------

build_menu :: proc(st: ^St, e: ^Entry, allocator := context.temp_allocator) -> []MI {
	m := make([dynamic]MI, allocator)

	append(&m, MI{kind = .Header, label = e.name, note = e.id})
	append(&m, MI{kind = .Sep})

	append(
		&m,
		MI {
			kind = .Item,
			label = "Open",
			ic = IC_ROCKET,
			has_ic = true,
			sk = "Enter",
			act = .Launch,
		},
	)
	append(
		&m,
		MI {
			kind = .Item,
			label = "Open in Terminal",
			ic = IC_TERMINAL,
			has_ic = true,
			sk = "Ctrl Enter",
			act = .Launch_Term,
			disabled = len(st.terms) == 0,
		},
	)
	append(
		&m,
		MI {
			kind = .Sub,
			label = "Open With",
			ic = IC_EXTERNAL_LINK,
			has_ic = true,
			sub = .Open_With,
			disabled = len(st.terms) == 0,
		},
	)
	append(
		&m,
		MI {
			kind = .Sub,
			label = "Desktop Actions",
			ic = IC_BLOCKS,
			has_ic = true,
			sub = .Actions,
			// Most entries declare none; the item stays visible and reads as
			// unavailable rather than disappearing from under the cursor.
			disabled = len(e.actions) == 0,
		},
	)

	append(&m, MI{kind = .Sep})
	append(&m, MI{kind = .Head, label = "Reveal"})
	append(&m, MI{kind = .Sub, label = "Copy", ic = IC_COPY, has_ic = true, sub = .Copy})
	append(
		&m,
		MI {
			kind = .Item,
			label = "Show .desktop Path",
			ic = IC_INFO,
			has_ic = true,
			sk = "Ctrl I",
			act = .Show_Path,
		},
	)
	append(
		&m,
		MI {
			kind = .Item,
			label = "Open Containing Folder",
			ic = IC_FOLDER_OPEN,
			has_ic = true,
			sk = "Ctrl O",
			act = .Open_Folder,
		},
	)
	append(
		&m,
		MI {
			kind = .Item,
			label = "Edit Desktop Entry",
			ic = IC_PENCIL,
			has_ic = true,
			sk = "Ctrl E",
			act = .Edit_Entry,
			// System entries under /usr are read-only, so there is nothing
			// honest to do here.
			disabled = !e.editable || len(st.terms) == 0,
		},
	)

	append(&m, MI{kind = .Sep})
	append(&m, MI{kind = .Head, label = "Options"})
	append(
		&m,
		MI {
			kind = .Check,
			label = "Always Launch in Terminal",
			act = .Toggle_Term,
			on = st.force_term,
			disabled = len(st.terms) == 0,
		},
	)
	append(
		&m,
		MI{kind = .Check, label = "Keep Launcher Open", act = .Toggle_Keep, on = st.keep_open},
	)
	append(
		&m,
		MI {
			kind = .Sub,
			label = "Sort Results By",
			ic = IC_LIST_SORT_ASCENDING,
			has_ic = true,
			sub = .Sort,
		},
	)

	append(&m, MI{kind = .Sep})
	pinned := st.pinned[e.id]
	append(
		&m,
		MI {
			kind = .Item,
			label = pinned ? "Unpin from Top" : "Pin to Top",
			ic = pinned ? IC_PIN_OFF : IC_PIN,
			has_ic = true,
			sk = "Ctrl D",
			act = .Toggle_Pin,
		},
	)

	append(&m, MI{kind = .Sep})
	append(
		&m,
		MI {
			kind = .Item,
			label = "Clear Usage History",
			ic = IC_TRASH,
			has_ic = true,
			sk = "Ctrl Bksp",
			act = .Clear_History,
			destructive = true,
		},
	)
	return m[:]
}

build_submenu :: proc(
	st: ^St,
	e: ^Entry,
	which: Sub,
	allocator := context.temp_allocator,
) -> []MI {
	m := make([dynamic]MI, allocator)
	switch which {
	case .None:
	case .Open_With:
		append(&m, MI{kind = .Head, label = "Terminal Emulator"})
		for t, i in st.terms {
			append(
				&m,
				MI {
					kind = .Item,
					label = t.name,
					ic = IC_TERMINAL,
					has_ic = true,
					act = .Run_In,
					arg = i,
				},
			)
		}
		if len(st.terms) == 0 {
			append(&m, MI{kind = .Item, label = "None installed", disabled = true})
		}
	case .Actions:
		append(&m, MI{kind = .Head, label = "Declared by the entry"})
		for a, i in e.actions {
			append(
				&m,
				MI {
					kind = .Item,
					label = a.name,
					ic = IC_SQUARE_ARROW_OUT_UP_RIGHT,
					has_ic = true,
					act = .Desktop_Act,
					arg = i,
				},
			)
		}
	case .Copy:
		append(&m, MI{kind = .Head, label = "Copy to Clipboard"})
		append(
			&m,
			MI {
				kind = .Item,
				label = "Name",
				ic = IC_TAG,
				has_ic = true,
				act = .Copy_Name,
				disabled = !st.have_clip,
			},
		)
		append(
			&m,
			MI {
				kind = .Item,
				label = "Exec Line",
				ic = IC_TERMINAL,
				has_ic = true,
				sk = "Ctrl C",
				act = .Copy_Exec,
				disabled = !st.have_clip,
			},
		)
		append(
			&m,
			MI {
				kind = .Item,
				label = "Desktop ID",
				ic = IC_HASH,
				has_ic = true,
				act = .Copy_Id,
				disabled = !st.have_clip,
			},
		)
		append(&m, MI{kind = .Sep})
		append(
			&m,
			MI {
				kind = .Item,
				label = "Full File Path",
				ic = IC_FILE_TEXT,
				has_ic = true,
				act = .Copy_Path,
				disabled = !st.have_clip,
			},
		)
	case .Sort:
		append(&m, MI{kind = .Head, label = "Order"})
		append(
			&m,
			MI {
				kind = .Radio,
				label = "Relevance",
				act = .Sort_Rel,
				on = st.sort == .Relevance,
			},
		)
		append(&m, MI{kind = .Radio, label = "Name", act = .Sort_Name, on = st.sort == .Name})
		append(
			&m,
			MI{kind = .Radio, label = "Most Used", act = .Sort_Freq, on = st.sort == .Frequency},
		)
	}
	return m[:]
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

PANEL_CLASS ::
	"absolute flex-col rounded-xl bg-popover p-1.5 shadow-2xl " +
	"ring-1 ring-foreground/15 overflow-hidden"

// check_indicator and radio_indicator are the real shadcn control shapes at
// menu scale, rather than a bare tick: both states are visible, so an unchecked
// option still reads as an option.
check_indicator :: proc(ui: ^p.Ctx, on: bool) {
	cls := on ? "bg-primary border-primary" : "border-muted-foreground/60"
	p.div(ui, "size-4 shrink-0 flex-row items-center justify-center rounded-[5] border")
	p.apply(ui, cls)
	if on {
		p.icon(ui, IC_CHECK, "size-3 text-primary-foreground")
	}
	p.end(ui)
}

radio_indicator :: proc(ui: ^p.Ctx, on: bool) {
	cls := on ? "border-primary" : "border-muted-foreground/60"
	p.div(ui, "size-4 shrink-0 flex-row items-center justify-center rounded-full border")
	p.apply(ui, cls)
	if on {
		p.div(ui, "size-2 rounded-full bg-primary")
		p.end(ui)
	}
	p.end(ui)
}

// render_menu draws one panel. `hot` is the index the keyboard is on; the
// returned value is the index the pointer is over, or -1.
render_menu :: proc(
	ui: ^p.Ctx,
	items: []MI,
	x, y, w: f32,
	hot: int,
	open_sub: bool,
	tag: string,
) -> (
	hovered: int,
) {
	hovered = -1

	p.key(ui, tag)
	panel := p.div(ui, PANEL_CLASS)
	p.apply(ui, "z-50", panel)
	ps := p.style(ui, panel)
	ps.inset[p.LEFT] = p.px(x)
	ps.inset[p.TOP] = p.px(y)
	ps.w = p.px(w)
	defer p.end(ui)

	for m, i in items {
		p.key(ui, menu_key(i))
		switch m.kind {
		case .Sep:
			sep := p.div(ui, "h-px shrink-0 bg-border")
			ss := p.style(ui, sep)
			ss.margin[p.LEFT] = -4
			ss.margin[p.RIGHT] = -4
			ss.margin[p.TOP] = 4
			ss.margin[p.BOTTOM] = 4
			p.end(ui)

		case .Head:
			p.div(ui, "flex-col shrink-0 h-[22] justify-center px-2")
			p.text(
				ui,
				m.label,
				"text-[11] font-medium uppercase tracking-wider text-muted-foreground whitespace-nowrap",
			)
			p.end(ui)

		case .Header:
			p.col(ui, "shrink-0 h-[40] justify-center px-2 gap-px")
			p.text(ui, m.label, "text-sm font-semibold whitespace-nowrap truncate")
			p.text(ui, m.note, "text-[11] tracking-wide text-muted-foreground whitespace-nowrap truncate")
			p.end(ui)

		case .Item, .Check, .Radio, .Sub:
			sel := i == hot
			idx := p.div(ui, "flex-row shrink-0 items-center gap-2.5 h-7 px-2 rounded-md")
			if m.destructive {
				p.apply(ui, "text-destructive", idx)
			}
			if m.disabled {
				p.apply(ui, "opacity-40", idx)
			} else {
				p.clickable(ui, idx)
				if p.is_hovered(ui, idx) {
					hovered = i
				}
				if sel {
					p.apply(ui, m.destructive ? "bg-destructive/15" : "bg-accent", idx)
				}
			}

			// The 16px leading gutter: an icon, a control indicator, or
			// nothing — but always the same width, so the labels line up.
			switch m.kind {
			case .Check:
				check_indicator(ui, m.on)
			case .Radio:
				radio_indicator(ui, m.on)
			case .Item, .Sub, .Sep, .Head, .Header:
				if m.has_ic {
					p.icon(
						ui,
						m.ic,
						m.destructive ? "size-4 shrink-0" : "size-4 shrink-0 text-muted-foreground",
					)
				} else {
					p.div(ui, "size-4 shrink-0")
					p.end(ui)
				}
			}

			p.text(ui, m.label, "flex-1 text-sm whitespace-nowrap truncate")

			if m.sk != "" {
				p.text(
					ui,
					m.sk,
					"text-[11] tracking-wide text-muted-foreground whitespace-nowrap",
				)
				p.style(ui).shrink = 0
			}
			if m.kind == .Sub {
				chev := p.icon(ui, IC_CHEVRON_RIGHT, "size-4 shrink-0")
				p.apply(
					ui,
					sel && open_sub ? "text-foreground" : "text-muted-foreground",
					chev,
				)
			}
			p.end(ui)
		}
	}
	return hovered
}

MENU_KEYS := [?]string {
	"m00", "m01", "m02", "m03", "m04", "m05", "m06", "m07", "m08", "m09",
	"m10", "m11", "m12", "m13", "m14", "m15", "m16", "m17", "m18", "m19",
	"m20", "m21", "m22", "m23", "m24", "m25", "m26", "m27", "m28", "m29",
}

menu_key :: proc(i: int) -> string {
	if i >= 0 && i < len(MENU_KEYS) {
		return MENU_KEYS[i]
	}
	return "mx"
}
