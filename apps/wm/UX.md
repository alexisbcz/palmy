# The window manager's interaction model

This is the spec for how Palmframe's window manager should feel under the
hands. It starts from an audit of what `apps/wm` does today, booted with
`wm --drm` in QEMU with three clients (term, gallery, counter) and driven over
QMP, and then says what it should do instead, in priority order.

The model borrows from four places and tries to stay one thing:

- **GNOME** for the keyboard: Super alone is the way in, the overview is the
  hub, nothing needs the mouse.
- **Windows 11** for direct manipulation: snap to edges and corners, drag a
  maximized window out, a taskbar that shows every window.
- **macOS** for restraint: few, short animations; title bar double-click; a
  window menu that is always the same.
- **KDE** for completeness: a window menu with "always on top" and "move to
  workspace", window rules, per-window opacity.

And from the tiling WMs this compositor already is (master, monocle, grid), a
rule that matters more than any of the above: **the layout never moves a window
the user did not ask to move.** Several of the faults below are that rule
being broken.

Priorities:

- **P0** — broken, missing, or surprising enough that a first-time user hits it
  in the first five minutes. Ship nothing else until these are done.
- **P1** — what makes it feel like a finished desktop rather than a demo.
- **P2** — polish and power-user features.

Every item ends with an **acceptance test**: QMP steps a script can drive in
`qemu-test.sh` at 1280x800, and what the screendump must show. The step
vocabulary is `qemu-qmp.py`'s (`move:`, `click:`, `key:`, `type:`, `shot:`,
`wait:`), plus four steps the harness does not have yet and should (P0-0):
`down:<btn>` and `up:<btn>` (a button held across moves), `drag:x1,y1,x2,y2`
(press, twenty interpolated moves, no release), and `dbl` (two left
press/release pairs 60 ms apart).

---

## 1. Audit: what the wm does today

Booted with `--drm --exec term --exec gallery --exec counter`, master layout,
default config. Screenshots were taken at every step and read. In the order a
user meets them:

### Broken

1. **Clicking a tiled window's title bar pops it out of the layout.** A plain
   press on the title starts a move, and `ws_float_for_drag` floats the window
   on press, before the pointer has moved a pixel. The layout then reflows
   around a window that is now floating at a different size: one click on
   Terminal's title made it a half-height floating window and moved gallery
   into its tile. A double-click does the same, so it can never mean
   "maximize".
2. **Super+Shift+digit types into the client instead of moving the window.**
   With a US keymap, Shift+2 produces `at`, and `wm_bind_for` matches on the
   shifted keysym, so `bind = $mod SHIFT, 2, movetoworkspace 2` never fires.
   The terminal received `@`. Every `movetoworkspace N` binding is dead on the
   keyboard most people have.
3. **Minimized windows cannot be restored with the mouse.** The dock chips at
   the bottom left are drawn but never hit-tested: clicking "Terminal" clicked
   whatever window was under it. The only way back is Super+Tab cycling.
4. **The dock chips sit on top of window content**, over the tiled windows'
   bottom-left corner, and receive no input, so they hide part of a client and
   block nothing.
5. **Dragging a maximized window moves it at maximized size.** It stays
   1280 wide, slides off the left of the screen with its title, and stays
   flagged maximized; clicking maximize afterwards "restores" it instead of
   maximizing.
6. **Frame buttons act on press.** Pressing minimize and dragging off it still
   minimizes; there is no way to cancel. I minimized Terminal by accident this
   way, starting a drag a few pixels too far right.
7. **Tiled windows overlap.** gallery's minimum width is larger than its
   master-stack cell, and the layout places it anyway, so its left 190 px lie
   under counter, and its content is clipped at the cell's right and bottom.
8. **Clicking the bar or the empty desktop drops keyboard focus to nothing.**
   Afterwards no window is focused, so Super+Shift+N, Super+Q and Super+M do
   nothing, and nothing on screen says why.
9. **The bar is not interactive.** Clicking a workspace indicator does nothing;
   scrolling on it does nothing.
10. **Client buttons stop at the content edge.** A press inside a client and a
    release over the title bar or outside the window never reaches the client
    (`ptr_button` is only called while the region is `.Content`), and motion is
    not sent while a button is held outside the surface. Any drag that leaves
    the content (a slider, a text selection) gets stuck pressed.

### Missing

11. Double-click, middle-click and right-click on a title bar do nothing.
12. No edge snapping, no snap preview, no quarter tiling.
13. One cursor shape. The software cursor is a fixed arrow over edges, corners,
    title bars and text; `wl_pointer.set_cursor` is read and discarded and
    `cursor-shape-v1` is not offered.
14. No window switcher overlay: Super+Tab cycles in stacking order, invisibly.
    When the next window is tiled and a floating window covers it, focus goes
    somewhere the user cannot see (the focused gallery was hidden behind the
    floating Terminal, with only a sliver of its outline showing).
15. No overview, no taskbar, no desktop menu, no cheat sheet (Super+/ does
    nothing), no animations of any kind.
16. Resizing is only possible from a 7 px band, of which the top edge inside
    the frame is 3 px.
17. Maximize/restore loses the tiled state: restoring a window that was tiled
    before it was floated leaves it floating forever unless the user knows
    Super+V.

### Awkward or ugly

18. **The bar is a debugging HUD.** "3 windows 3 clients 2 fps" and an F-key
    legend ("F1 spawn counter F2 spawn gallery ...") are developer
    instrumentation. The brand reads "palmy wm" on a system called Palmframe.
    The fps counter reads 2 when idle, which is correct and alarming.
19. **Focus is hard to see.** Focused and unfocused title bars are near
    identical dark greys; the only cue is a 1 px indigo outline and slightly
    whiter title text. The shadow is invisible on the dark desktop.
20. **The buttons are three grey dots** that turn red/green/amber only on
    hover. Unfocused, they are almost background.
21. **Closing a window reflows the layout under the pointer.** After closing
    gallery, Terminal slid into its place with its close button exactly under
    the pointer; a double-click on close would have closed two windows.
22. Status toasts ("moving Terminal", "focus palmy · gallery") replace the
    right half of the bar for three seconds on every action, including ones
    that need no confirmation.
23. Notes worth keeping: the 32 px title bar, Geist type, the workspace strip
    (filled / outlined / dim), the layout badge, Super+drag and Super+right-drag
    are all good and should stay.

---

## 2. Principles

1. **Keyboard first, mouse complete.** Every action has a key; every action a
   key does, the mouse can also do, and vice versa.
2. **The layout does not move what you did not touch.** Clicking, focusing and
   double-clicking never float, re-tile or resize another window. A window
   leaves the layout only when it is actually dragged (pointer travel past
   a threshold) or explicitly floated.
3. **Act on release, preview on hold.** Buttons fire on release over the same
   button. Snaps show their target before the release commits them. Escape
   during any drag cancels it and puts the window back.
4. **Exact restore.** Every transition that changes geometry (maximize, snap,
   tile, minimize, fullscreen, workspace move) records what it replaced and
   undoes to exactly that, pixel for pixel.
5. **Fast enough to forget.** Animations are 120-200 ms, ease-out, and turn
   themselves off when the rasterizer cannot hold the frame rate.
6. **One vocabulary.** The window menu, the taskbar context menu, the overview
   and the keybindings all offer the same actions with the same names, taken
   from the same `Cfg_Act` set, and the cheat sheet is generated from the live
   binding table.

---

## 3. P0 — the first five minutes

### P0-0. Test harness: held buttons and double-clicks

`qemu-qmp.py` gains `down:`, `up:`, `drag:` and `dbl` as described above, so
every test in this file can be scripted. A drag is the only way to test
snapping, edge resize and title-bar drag-out.

**Test:** `move:900,60 down:left move:700,200 shot:a.png up:left` — the
screendump shows the window under the pointer mid-move.

### P0-1. Clicks never re-tile; a drag needs travel

A press on the title bar focuses and raises the window and arms a move. The
move — and, for a tiled window, floating it — begins only after the pointer
travels 6 px (logical) with the button held. A press and release without
travel is a click and changes nothing but focus. Click-to-focus raises the
window within its layer (tiled stay below floating, as now) and a focused
tiled window that is covered by a floating one is revealed when focus
arrives without a click (Alt+Tab, the overview, directional focus, a new
window): it is drawn, and hit, above the floating windows for as long as it
keeps focus. (Drawing the floating windows at 30% instead was tried; two
windows' text printed over each other read as a rendering fault.)

**Test:** master layout, three windows. `move:900,60 click wait:0.5 shot:a.png`
— every window's frame rectangle is identical to the previous screendump;
only the focus styling moved.

### P0-2. Title bar double-click: maximize / restore

Two left clicks on the title bar (not on a button) within the double-click
interval (default 400 ms, `double_click_ms` in the config) and within 4 px of
each other toggle maximize. The first click focuses; neither click floats.
Restore returns the window to exactly the geometry it had: a floating window to
its x, y, w, h; a tiled window back into the layout at its tiling position; a
snapped window to its snap. Double-click on a maximized window's title
restores. The same applies to the Maximize button, Super+Up / Super+M and the
window menu.

**Test:** floating workspace (Super+F), terminal at a known rect.
`move:900,60 dbl wait:0.4 shot:max.png move:640,50 dbl wait:0.4 shot:back.png`
— `max.png`: the frame fills the area under the bar edge to edge. `back.png`:
the frame is pixel-identical to the starting screendump. Repeat on a tiled
window: `back.png` shows it back in its tile, and no other window moved at any
point.

### P0-3. Middle-click lowers; right-click opens the window menu

Middle-click on a title bar sends the window to the bottom of its layer
(KDE, X11 tradition). Right-click on a title bar, or Alt+Space with a window
focused, opens the **window menu** at the pointer (at the title bar's left for
Alt+Space):

    Minimize                 Super+N
    Maximize / Restore       Super+Up
    ---------------------------------
    Always on top            (check)
    Float / Tile             Super+V
    Move to workspace   >    1 ... 9, New
    ---------------------------------
    Close                    Super+Q

Drawn by the wm in the same style as palmy menus (shadcn): 8 px radius, 1 px
border, 28 px rows, shortcut column right-aligned and dimmed, hover row
highlighted, keyboard navigation (Up/Down, Right opens the submenu,
Enter, Escape, the underlined letter). Items that do not apply (Maximize on a
fixed-size window) are disabled, not hidden. The menu is a compositor overlay:
it takes the pointer and keyboard until dismissed, and a click outside dismisses
it without passing the click through. `xdg_toplevel.show_window_menu` from a
client-side-decorated client opens the same menu.

**Test:** `move:300,60 click:right wait:0.3 shot:menu.png` — a menu with the
seven items and the shortcut column at the pointer; the window under it has
not moved or floated. `key:esc shot:` — menu gone, nothing else changed.
`key:alt+spc key:down key:ret wait:0.3 shot:` — the focused window is
maximized (Minimize, then Maximize). Move to workspace: `move:300,60
click:right`, click "Move to workspace", click "3" — `shot:` shows the window
gone and the "3" indicator outlined (occupied); `key:meta_l+3 shot:` shows it
there.

**Test (lower):** two overlapping floating windows, `move:<top title> click:middle shot:` — the other window is now drawn on top.

### P0-4. Dragging a maximized or snapped window restores it under the pointer

Starting a move (P0-1's travel threshold) on a maximized, snapped or tiled
window first restores it to its saved floating size, then places it so the
grab point keeps the same *relative* position across the title bar:
`new_x = pointer_x - (grab_x - old_x) * restored_w / old_w`, clamped so the
pointer stays on the title bar and away from the buttons. The window then
follows. The `maximized` flag is cleared at that moment, so the Maximize button
means maximize again.

**Test:** maximize terminal (`key:meta_l+up`), `drag:960,50,500,300 shot:a.png up:left shot:b.png`
— `a.png`: the window is at its pre-maximize size, the pointer is over its
title bar at ~75% of its width (960/1280), no part of the title bar is
off-screen. `b.png` = `a.png`. Then `move:<max button> click shot:c.png` —
maximized again.

### P0-5. Edge snapping with a preview

While moving a window with the pointer:

| pointer within 8 px of        | target                                   |
| ----------------------------- | ---------------------------------------- |
| left / right edge             | left / right half of the work area       |
| top edge (incl. the bar)      | maximize                                 |
| a corner (40 px square)       | that quarter                             |
| bottom edge                   | nothing (leaves room for the taskbar)    |

After the pointer rests in a zone for 80 ms a **preview** appears: the target
rectangle drawn as a 12 px-radius rounded rect, accent at 18% fill and 60%
1 px border, inset by the gaps, under the dragged window. It grows from the
pointer to the target in 120 ms. Leaving the zone removes it. Releasing in a
zone commits: the window animates to the target and records its pre-snap float
rect. Escape during the drag cancels both. Hold Ctrl while dragging to suppress
snapping (and edge resistance, P1-9).

On a tiled workspace, dragging a window onto another tiled window swaps them
instead (the drop target outlined), and dragging it to an edge snaps it
floating as above.

From the keyboard, for floating windows. On a tiled window Super+Up
maximizes, Super+Down restores or minimizes, and Super+Left/Right snap it to
that half, out of the layout, so two windows side by side (P1-10) are two
keystrokes whatever the workspace; moving focus is Super+H/J/K/L.

| key           | floating window                                         |
| ------------- | ------------------------------------------------------- |
| Super+Left    | snap left half; again: left third, left two thirds (cycle); from right half: restore |
| Super+Right   | mirror                                                  |
| Super+Up      | maximize; from a bottom quarter: the top quarter          |
| Super+Down    | from maximized/snapped: restore; from restored: minimize |

Super+Left then Super+Up is the top-left quarter (Windows 11).

**Test:** floating workspace, terminal at (400,200).
`drag:600,215,2,400 wait:0.3 shot:preview.png up:left wait:0.3 shot:snap.png`
— `preview.png`: a translucent accent rectangle covering the left half below
the bar, the window still under the pointer. `snap.png`: the window fills the
left half minus gaps. Then `drag:300,60,1279,799 wait:0.3 shot:q.png` —
preview fills the bottom-right quarter. `key:esc shot:` — window back where
the drag began, no preview. Keyboard: `key:meta_l+left shot:` equals
`snap.png`; `key:meta_l+down shot:` equals the pre-snap rect.

### P0-6. Resize from every edge and corner, with a generous margin

The grab margin is 8 px **outside** the frame on all four sides (invisible,
part of the shadow), plus 4 px inside on the sides and bottom, plus the top
4 px of the title bar. Corners are 16 x 16 px L-shaped areas so they are easy
to hit. A tiled window resized at an internal edge resizes the split
(`master_ratio` for the master column edge) rather than floating it; an outer
edge of a tiled window does nothing. Clients' `min_size`/`max_size` are
honoured, and a fixed-size window shows no resize affordance.

**Test:** floating terminal with frame at (400,170)-(1000,600).
`move:396,598 wait:0.2 shot:hover.png` (cursor must be the bottom-left
diagonal, P0-7) `drag:396,598,300,700 up:left shot:` — frame now
(300,170)-(1000,700) within 2 px. Repeat for each of the 8 handles. Tiled:
`drag:<x of the master/stack boundary>,400,800,400 up:left` — both columns
changed width, neither floated.

### P0-7. Cursor shapes, in --drm too

The software cursor becomes a set of shapes, drawn by the wm at 24 px (scaled
with the output), each with a hotspot:

`default` (arrow), `move` (four-way, while dragging a title), `grabbing`,
`n-resize`, `s-resize`, `e-resize`, `w-resize`, `ne-resize`, `nw-resize`,
`se-resize`, `sw-resize`, `text` (I-beam), `pointer` (hand), `not-allowed`,
`wait`.

The wm picks the shape over its own chrome (edges, corners, title bar during a
drag, menus). Over a client surface, the client's choice wins:

- `wp_cursor_shape_manager_v1` is advertised; `set_shape` maps onto the list
  above (unknown shapes fall back to `default`).
- `wl_pointer.set_cursor` with a surface is honoured: the wm keeps the
  surface's latest buffer and hotspot and draws it as the cursor, and a null
  surface hides the cursor. This is how term's I-beam reaches the screen.

Nested mode keeps letting the host draw its cursor but sets the host's shape
through palmy's cursor API where one exists.

**Test:** `move:600,400` over term's text area `shot:` — I-beam. `move:<right
edge+4>,400 shot:` — horizontal double arrow. `move:<bottom-right corner+4>
shot:` — diagonal. `move:900,60 down:left move:880,80 shot:` — four-way move.
Cursor crops are compared against reference bitmaps from the shape table.

### P0-8. Title bar buttons that behave like buttons

Close, maximize, minimize on the right (Windows and GNOME order, configurable
`buttons = minimize,maximize,close`; `buttons = close,minimize,maximize:left`
gives macOS). Each is a 28 x 24 px hit target, larger than its 16 px glyph.
States: rest, hover (glyph brightens, round 6 px plate at 10% white; close
plate is red `#e7000b` with a white glyph), pressed (plate darker, glyph shifts
nothing), disabled (maximize on a fixed-size window: 35% opacity). The action
fires on **release over the same button**; dragging off cancels. Buttons of
unfocused windows are visible (60% opacity), not near-invisible. Hovering a
button for 600 ms shows a tooltip with its name and shortcut.

**Test:** `move:<minimize> down:left move:700,300 up:left shot:` — window
still there. `move:<close> wait:0.1 shot:` — red plate. `down:left shot:` —
darker red, window still open. `up:left wait:0.3 shot:` — window closed.

### P0-9. Focused vs unfocused, legible at a glance

| element          | focused                                  | unfocused                      |
| ---------------- | ---------------------------------------- | ------------------------------ |
| title bar        | `#27272a`                                | `#18181b`                      |
| title text       | `#fafafa`, Semibold 12.5, centred        | `#71717a`                      |
| outline          | 1 px `border_focus` (accent) at 70%      | 1 px `#27272a`                 |
| shadow           | 0 12 32 rgba(0,0,0,0.55) + 0 0 0 1 accent at 15% | 0 4 12 rgba(0,0,0,0.35) |
| corners          | 10 px top, 10 px bottom (clip client) — maximized and tiled: 0 | same |

Title text is centred with the app icon (16 px, from the app's `.desktop`
Icon if found, else a monogram) to its left, and ellipsized in the middle
(`Documents — …report.txt`), never truncated into the buttons. Rounded bottom
corners clip the client's pixels (a per-row span table; cheap). Maximized and
tiled windows drop the radius and the shadow; tiled ones keep the 1 px outline.

**Test:** two windows. `shot:` — focused title bar is measurably lighter
(pixel at title midpoint ≥ 0x26 luma vs ≤ 0x19), focused title text is white,
both windows' corners are rounded (pixel at frame corner = desktop colour).

### P0-10. A taskbar in the bar; the dock goes

The minimized-window dock is removed. The bar becomes:

    [◆ Palmframe] [1 2 3 … 9] [layout]  [▣ Terminal] [▣ gallery] [▢ counter]   … [tray] [kbd] [clock]

- One entry per window on the current workspace, in tiling/creation order
  (stable, not stacking order), each up to 200 px: icon + title,
  ellipsized. Focused: filled `#27272a` with a 2 px accent underline.
  Minimized: title at 50% opacity, icon desaturated. Urgent
  (`xdg_activation` from another app): accent-tinted until focused.
- Click: focus and raise (restoring if minimized). Click the focused entry:
  minimize it (Windows). Middle-click: close. Right-click: the window menu.
  Drag an entry along the bar to reorder; onto a workspace indicator to move
  the window there.
- Workspace indicators are clickable (switch), scroll on them switches
  previous/next (wrapping off), right-click offers "Rename…" (P2).
- The window count, client count and fps move to a debug overlay
  (`debug_hud = on`, or Super+Ctrl+Shift+D). The F-key legend goes; its job
  is done by the cheat sheet (P1-8) and the welcome card.
- Status notes appear only for actions that have no other visible result
  (reload, "nothing to close"), as a small toast under the bar, 2 s.

**Test:** three windows, minimize counter. `shot:` — three taskbar entries,
counter's dimmed, no chips at the bottom of the screen. `move:<counter entry>
click wait:0.3 shot:` — counter restored and focused, its entry highlighted.
`click shot:` — minimized again. `move:<gallery entry> click:middle wait:1
shot:` — gallery gone. `move:146,17 click shot:` — workspace 2 shown.
`move:146,17` + scroll down (QMP `btn` `wheel-down`) `shot:` — workspace 3.

### P0-11. Keybindings that work on real keyboards

Bindings match on the **level-1 keysym of the pressed key** (the keycode
looked up in the current group with no modifiers), with Shift treated as a
modifier, so `$mod SHIFT, 2` fires on US, UK and German keyboards. On layouts
whose number row is not digits at level 1 (French AZERTY: `ampersand`,
`eacute`, …), a binding naming a digit also matches the keycode of that digit
on the US layout (keycodes 10-18 for 1-9), which is what GNOME and KDE do. A
binding can also name a keycode directly (`code:10`).

The default table is reconciled with the new model:

| key                   | action                                                 |
| --------------------- | ------------------------------------------------------ |
| Super (tap)           | overview                                               |
| Super+Return          | terminal                                               |
| Super+Space / Super+D | launcher (layout cycling moves to Super+Backslash)     |
| Super+Q               | close                                                  |
| Super+Up / Down / Left / Right | P0-5 on floating windows; on tiled: Up maximize, Down restore, Left/Right snap to that half |
| Super+H/J/K/L         | focus left/down/up/right (always)                      |
| Super+Shift+H/J/K/L   | move/swap window                                       |
| Super+Ctrl+Left/Right | previous/next workspace                                |
| Super+1…9             | workspace N; Super+Shift+1…9 move window there; Super+Ctrl+Shift+1…9 move and follow |
| Super+N               | minimize                                               |
| Super+V               | float/tile                                             |
| Super+F               | fullscreen                                             |
| Alt+Tab, Super+Tab    | switcher (P1-1)                                        |
| Alt+F4                | close (Windows muscle memory)                          |
| Alt+Space             | window menu                                            |
| Super+/               | cheat sheet                                            |
| Super+W               | overview                                               |
| F11                   | fullscreen (not maximize)                              |

Today's Super+F (`toggletiling`, workspace floating/tiled) moves to
Super+Shift+Space and Super+Space (`nextlayout`) to Super+Backslash;
`windowmode` survives on Super+Alt+W; the bare F-key twins move out of the
default config into a `demo.conf` used by the recorder.

Bindings to punctuation work the same way: a symbol the layout types only
with Shift or AltGr (`/` on AZERTY is Shift+:) matches its key in the US
position, and also the chord that types it — Super+Shift+: fires `$mod,
Slash` there, the Shift spent on the symbol.

**Test:** focus terminal, `key:meta_l+shift+2 wait:0.4 shot:` — terminal gone
from workspace 1, no `@` typed anywhere; `key:meta_l+2 shot:` — terminal there,
prompt unchanged. Repeat with `--keyboard fr` and `--keyboard de`.

### P0-12. Implicit pointer grab for clients

A button pressed over a client surface grabs the pointer to that surface until
every button is released: motion and the release are delivered to it wherever
the pointer goes (coordinates may be negative or past the surface size), as
`wl_pointer` requires. Hover effects on the wm's chrome are suppressed during
the grab.

**Test:** gallery's Volume slider: `move:<knob> down:left move:1270,700
up:left move:<knob x>,<knob y + 200> shot:` — the slider stays where it was
released (at its maximum) and does not follow the pointer afterwards.

### P0-13. Focus and placement never surprise

- Click-to-focus raises (P0-1). Clicking the bar or the desktop does **not**
  unfocus the window (macOS); Escape from the desktop menu returns focus.
- A new window takes focus only if it was launched by the user in the last
  2 s (keybinding, launcher, desktop menu, `xdg_activation` token from the
  focused client) **or** the user has not typed in the last 1 s. Otherwise it
  opens behind the focused window, its taskbar entry marked urgent.
  `focus_new = smart | always | never`.
- Placement: on the output under the pointer; centred if it is the first
  window of a floating workspace, otherwise cascaded 32 px down-right from the
  last placed window, wrapping before any edge; never off-screen, never under
  the bar; a window larger than the work area is shrunk to it (and asked to
  be that size), not centred off its edges.
- When a tiled layout cannot honour a client's minimum size, the layout gives
  that cell what it needs and shrinks the others, and when that is impossible
  the window floats, centred, rather than overlapping a tile (fixes 1.7).
- After a close or minimize reflows the layout, a click within 300 ms on a
  frame button that moved under the pointer is ignored (fixes 1.21).

**Test:** type continuously into term (`type:` a 3 s string) while a guest
script runs `sleep 1; counter`; `shot:` — term still focused, every typed
character in term, counter's taskbar entry urgent. `key:meta_l+ret shot:` — the
new terminal is focused, fully on-screen, below the bar.

---

## 4. P1 — a finished desktop

### P1-1. Alt+Tab / Super+Tab switcher

Holding Alt (or Super) and pressing Tab opens a centred overlay listing the
windows of the current workspace (Super+Tab: all workspaces, grouped) in
**most-recently-used** order, the current window first and the selection on
the second. Each entry: a thumbnail scaled from the window's last buffer
(box-filtered once per open, capped at 200 x 130, cached until the next
commit), the app icon over its corner, the title under it. Tab advances,
Shift+Tab or Shift goes back, arrow keys move, the pointer can hover/click an
entry, Q (or Super+Q) closes the selected window in place. Releasing the
modifier commits (focus, raise, un-minimize, switch workspace if needed);
Escape cancels and leaves focus untouched. A quick Alt+Tab tap (released
within 120 ms) switches without drawing the overlay. Minimized windows appear
last, dimmed.

**Test:** focus A, then B, then C (clicks). `hold:alt key:tab wait:0.3
shot:sw.png` — overlay with three entries in order C, B, A, B selected.
`key:tab shot:` — A selected. `release:alt wait:0.3 shot:` — A focused and on
top. `hold:alt key:tab key:esc release:alt shot:` — focus unchanged.

### P1-2. Overview

Opened by tapping Super (press and release with no other key within 400 ms),
by Super+W, or by pushing the pointer into the top-left hot corner (1 px,
150 ms dwell, `hot_corner = off` to disable). Every window of the current
workspace is laid out scaled down, without overlap, preserving relative
positions (a simple grid-fill sorted by window centre), each with its title
under it and a close button on hover. Above them, a strip of workspace
thumbnails (each a scaled render of that workspace, the current one outlined),
plus an empty one at the end.

- Click a window: focus it and close the overview. Middle-click: close it.
- Drag a window onto a workspace thumbnail: move it there.
- Click a workspace thumbnail: switch to it (stays in overview).
- **Type to filter:** any printable key filters windows by title and app_id
  (substring, case-folded), shown in a search field that appears at the top;
  Enter focuses the first match; if nothing matches, Enter opens the
  launcher with the typed text.
- Arrow keys move the selection; Escape or Super closes.

Enter/exit animate (P1-6): windows fly from their real rect to their overview
rect in 180 ms. Thumbnails are scaled from client buffers with a cached
box-filter, rebuilt on commit, so the overview costs one scaled blit per
window per frame.

**Test:** three windows. `key:meta_l wait:0.5 shot:ov.png` — three
non-overlapping scaled windows with titles, a 9+1 workspace strip.
`type:gal wait:0.2 shot:` — only gallery remains highlighted, others dimmed.
`key:ret wait:0.3 shot:` — normal desktop, gallery focused. `move:0,0 wait:0.4
shot:` — overview again.

### P1-3. Desktop right-click menu and a wallpaper

Right-clicking the desktop (no window under the pointer) opens a menu in the
window-menu style:

    Open Terminal             Super+Return
    Launcher                  Super+Space
    Software                  (if `software` is on PATH)
    ---------------------------------------
    Layout   >  Master · Monocle · Grid · Floating (current checked)
    Arrange windows (cascade)
    ---------------------------------------
    Wallpaper…                (if `settings` exists; else hidden)
    Settings                  (if `settings` exists; else hidden)

Items whose program is not installed are hidden (`cfg_which`), never shown
broken.

The wallpaper replaces today's dot grid: `wallpaper = <path>` (PNG/JPEG
through palmy's image loader; `fill`, `fit`, `center`, `tile`), and by
default a generated one — a tasteful diagonal gradient from `#0b1020` to
`#1e1b4b` with two large, very soft radial glows (accent at 12% top-left,
teal `#0d9488` at 8% bottom-right) and a 2% luma noise dither so the gradient
does not band on 8-bit outputs. Rendered once per output size (as now).
`wallpaper_color` for a flat colour.

**Test:** `--wm-args "--drm"` (no windows). `move:640,400 click:right
wait:0.3 shot:` — menu with Open Terminal, Launcher, Layout, Arrange; no
Settings entry in the test image. `key:ret wait:2 shot:` — a terminal opened.
A crop of the empty desktop shows no repeating dot pattern and no visible
banding (adjacent-row luma steps ≤ 1).

### P1-4. Always on top, sticky, fullscreen

- **Always on top:** a third stacking layer above floating windows, toggled
  from the window menu or Super+Shift+T; a pin glyph in the title bar.
- **Sticky (all workspaces):** window menu "Show on all workspaces"; the
  window travels with workspace switches. Picture-in-picture videos and
  sticky notes want it.
- **Fullscreen** (`xdg_toplevel.set_fullscreen`, F11, Super+F): no frame,
  above the bar, on its output; the bar comes back on Super. Exits restore
  exactly.

**Test:** float two windows, set A always-on-top via menu, click B — A is
still drawn over B. `key:f11 shot:` — focused client covers 1280x800, no bar.

### P1-5. Minimize and restore everywhere

Minimize from the button, Super+N, Super+Down from restored, the window menu,
the taskbar, and `xdg_toplevel.set_minimized`. Restore from the taskbar, the
switcher, the overview and `focus_window`. A minimized tiled window gives up
its cell; restoring returns it to its tiling position (seq), not the end.

**Test:** master layout A (master), B, C. Minimize A, restore A from taskbar —
A is master again, same cells as before.

### P1-6. Animations a software rasterizer can afford

All animations interpolate rectangles and opacity only; content is the
client's last buffer, scaled with nearest/bilinear during the animation
(never re-rendered by the client per frame). Durations and curves:

| transition                  | what moves                                      | ms  | curve      |
| --------------------------- | ----------------------------------------------- | --- | ---------- |
| open                        | scale 0.95 → 1 about centre, opacity 0 → 1      | 160 | ease-out   |
| close                       | scale 1 → 0.95, opacity 1 → 0 (from a snapshot) | 120 | ease-in    |
| minimize / restore          | rect ↔ its taskbar entry, opacity (minimize: solid while it shrinks, fades on arrival) | 200 | in-out / ease-out |
| maximize / snap / tile      | frame rect old → new (client gets the final configure up front; old buffer stretched until the new one arrives) | 160 | ease-out |
| workspace switch            | both workspaces slide horizontally by output width | 200 | ease-out (cubic) |
| switcher / menus            | opacity 0 → 1, 4 px drop                        | 100 | ease-out   |
| overview                    | windows real rect ↔ overview rect               | 180 | ease-out   |
| snap preview                | rect grows from pointer                         | 120 | ease-out   |

Interruptible: a new transition on the same window starts from wherever the
current one is. Input during an animation goes to the final geometry.

`animations = on | off | reduced` (reduced: opacity only, 100 ms). Automatic
reduction: the frame time of the last 30 animated frames is tracked; if the
median exceeds the budget (16.7 ms at 60 Hz) the wm drops to `reduced` for
the session and says so once in the debug HUD. Software scaling for the
animated windows uses a 2x-downsampled copy when the window is larger than a
quarter of the output.

**Test:** `--wm-args "--drm --exec term"`; QMP screendumps taken at 40 ms
intervals after `key:meta_l+ret`: the first contains a partially transparent,
slightly smaller new window, a later one the full-size opaque one; after 250
ms every shot is identical. With `animations = off` in the guest config, the
first screendump after the window maps already shows it complete.
`key:meta_l+2` mid-sequence screendump: both workspaces partially visible.

### P1-7. Super+drag, Super+right-drag, and Alt fallback

Kept as now, improved: Super+left-drag moves from anywhere in the window (with
P0-4 and P0-5 applying); Super+right-drag resizes from the **nearest corner**
(today it always resizes from bottom-right); Super+middle-drag lowers. The
cursor shows `move` / the corner's resize arrow during the drag. `mod_drag =
alt` for people coming from X11 WMs.

**Test:** floating terminal (400,170)-(1000,600). `hold:meta_l
move:420,190 down:right move:300,100 up:right release:meta_l shot:` — top-left
corner moved to about (300,100), bottom-right unchanged.

### P1-8. Cheat sheet: Super+/

A centred, two-column overlay generated from the live binding table, grouped
by action family (Windows, Focus, Workspaces, Layout, Launch, Session), each
row a key chord rendered as shadcn `kbd` caps and the action's human label
("Move window to workspace 3", not `movetoworkspace 3`). Mouse gestures
(double-click title, Super+drag...) are a fixed section at the end. Type to
filter; Escape or any chord that is listed executes it and closes. It is also
reachable from the overview's "?" and the welcome card.

**Test:** `key:meta_l+slash wait:0.3 shot:` — overlay with ≥ 6 group
headings; it lists `Super` `Shift` `2` next to "Move window to workspace 2".
Add a `bind` line to the guest's `~/.config/palmy/wm.conf` (a
`--guest-script`), wait 1.5 s for the mtime reload, reopen — the new binding
is listed.

A user file adds to the default table rather than replacing it: a `bind` on a
chord the default uses replaces that one, `unbind = <mods>, <key>` removes
one, and `default_binds = replace` asks for an empty table to start from. (It
used to be the other way round, and one added shortcut cost every default —
the cheat sheet itself, close, the workspace keys.) A reload re-applies only
the layout settings the file changed, so it never re-tiles a workspace the
user had set floating.

### P1-9. Edge resistance and window-to-window snapping

While moving a floating window, its edges stick (8 px) to the work-area edges
and to other windows' edges on the same workspace, so tidy arrangements are
easy without a grid. Ctrl disables it.

**Test:** drag a window's left edge to within 6 px of another's right edge —
release — the gap is exactly the inner gap (6 px) or 0, never 1-5.

### P1-10. Resize between snapped windows

Two windows snapped left/right (or four quarters) share their boundary: dragging
the boundary resizes both (Windows 11 "snap groups", GNOME tiling assistant).
The pair is broken when either is moved.

**Test:** snap A left and B right (`key:meta_l+left`, focus B,
`key:meta_l+right`), `drag:640,400,800,400 up:left shot:` — A is 800 - gap wide,
B fills the rest.

### P1-11. Window rules, extended

`rule` gains: `opacity 0.9`, `ontop`, `sticky`, `placement center|pointer`,
`noanim`, `fullscreen`, `nofocus` (never takes focus on map), `output NAME`,
and matching on `class~regex` alongside `app_id=` / `title~`. Rules re-match
when the title changes if `rerule` is set on the line.

**Test:** guest config `rule = app_id=palmy-counter, float, ontop, size 400x300`;
`--exec counter` — counter floats at 400x300 above everything.

---

## 5. P2 — polish and power users

- **P2-1. Scratchpad.** Super+grave toggles a drop-down terminal (or any app
  by rule `scratchpad`) that slides from under the bar, 60% height, sticky,
  always on top; hiding keeps its process. *Test:* `key:meta_l+grave shot:` —
  terminal in the top 60% across all workspaces; again — gone.
- **P2-2. Per-window opacity.** Super+scroll on a window changes its opacity
  in 5% steps (min 20%), shown in a 1 s badge; persisted for the session; rule
  `opacity`. Unfocused-opacity setting (`inactive_opacity = 0.92`).
- **P2-3. Workspace names and dynamic workspaces.** Rename from the indicator
  menu; `workspaces = dynamic` keeps one empty workspace at the end (GNOME).
- **P2-4. Window shake to minimize others**, and **double-click empty bar
  space to show the desktop** (minimize all; again to restore). Super+D keeps
  launcher; Super+Ctrl+D is show desktop.
- **P2-5. Touchpad gestures** (bare metal evdev already parses multitouch):
  three-finger swipe left/right switches workspace with a 1:1 tracked slide,
  three-finger up opens the overview, pinch out shows the desktop.
- **P2-6. Tab groups / stacking** (i3 style): drop a window onto another's
  title bar to group them as tabs in one frame.
- **P2-7. Multi-output niceties:** Super+Shift+Left/Right on a maximized
  window moves it to the neighbouring output, restoring its relative position;
  snap previews never straddle outputs; the taskbar per output shows that
  output's windows.
- **P2-8. Accessibility:** a high-contrast frame theme, `cursor_size`, a
  "locate pointer" pulse on Ctrl tap, sticky keys for the chords above, and
  every overlay readable at 200% scale.
- **P2-9. Title bar app menus:** when a client exports a menu through
  `xdg_toplevel_icon` + a future palmy menu protocol, show it in the title bar.
- **P2-10. Session restore:** remember workspace, float rect and layout seq
  per app_id across restarts.

---

## 6. Rendering and performance budget

Everything above has to fit a CPU rasterizer at 60 Hz on 1280x800 to
1920x1080. The rules that make that possible:

- **Damage tracking first** (TODO.md W2 "A full CPU repaint every frame").
  Hover states, the clock and the cursor must not repaint the screen. Without
  it, animations will be the first thing auto-reduction turns off.
- Shadows stay ring-only (as `ring_shadow` does) and are cached per window
  size and focus state as a 9-slice, not recomputed per frame.
- Overlays (menus, switcher, cheat sheet) are rasterized once into their own
  buffer when opened or when their content changes, then composited.
- Thumbnails are box-filtered once per client commit, at most one per frame
  (the rest show their previous thumbnail), so opening the overview with 20
  windows does not stall.
- Cursor shapes are pre-rasterized at the output scale; the cursor's damage is
  its old and new 32 x 32 rects.

---

## 7. Order of work

1. P0-0 (harness), then P0-1, P0-11, P0-12, P0-13 — correctness of what
   already exists: no surprise re-tiling, bindings that fire, clients that
   get their releases, focus that stays put.
2. P0-2, P0-3, P0-4, P0-8 — the title bar as a real control.
3. P0-6, P0-7 — resize and cursors (one change: the hit test grows, and the
   shape follows from it).
4. P0-5 — snapping, built on 2 and 3.
5. P0-9, P0-10 — the look, and the taskbar that replaces the dock.
6. P1 in order; P1-6 (animations) after damage tracking.
