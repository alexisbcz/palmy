# palmy desktop apps

Four real applications built on palmy (Odin, software rasterizer, Wayland) and
the shadcn widget layer in `../shadcn`.

| app | what it is |
| --- | --- |
| `launcher/` | a dmenu/rofi replacement with rich, macOS-grade context menus |
| `files/` | a file browser, held to Finder's standard |
| `bluetooth/` | a Bluetooth applet over `bluetoothctl` |
| `network/` | a network applet over `nmcli` |

## Building

```sh
odin build apps/<name> \
  -collection:palmy=/home/alex/Work/palmy/palmy \
  -collection:shadcn=/home/alex/Work/palmy/shadcn \
  -collection:kit=/home/alex/Work/palmy/apps/kit \
  -o:speed -out:apps/<name>/<name>.bin
```

## The kit

`import kit "kit:."` gives you the shared setup — do not re-implement it.

```odin
app, err := kit.start({title = "Files", width = 1100, height = 720})
// fonts, shadcn theme and the text calibration are already applied

out, ok  := kit.run({"nmcli", "-t", "-f", "SSID,SIGNAL", "device", "wifi"})
lines, _ := kit.run_lines({"bluetoothctl", "devices"})
kit.launch({"foot"})   // detached, does not block the UI
```

## What you have to build with

- **palmy** — read `/home/alex/Work/palmy/README.md` for the full class
  vocabulary and element API. Layout is flexbox, styling is Tailwind class
  strings, and the design tokens are registered so `bg-primary`,
  `text-muted-foreground`, `rounded-lg` and `ring-3` all work.
- **shadcn** — 58 files of components: `button`, `input`, `badge`, `card`,
  `dialog`, `menu` (dropdown + context menu), `select`, `tabs`, `table`,
  `switch`, `checkbox`, `slider`, `separator`, `avatar`, `skeleton`, `tooltip`,
  `popover`, `sidebar`, `scroll_area`, `command`, `spinner`, `progress`,
  `breadcrumb` and more. Read the `.odin` file before using a widget; they take
  an explicit `State{hover, focus, disabled}`.
- Icons: `p.icon(ui, sc.ICON_FOLDER, "size-4")`. Add more with
  `cd /home/alex/Work/palmy/parity && node tools/gen-icons.mjs <PascalName>` —
  the generator is additive and safe.

## Interaction

palmy gives you hit testing, hover, focus, keyboard and scrolling. The patterns:

```odin
idx := p.div(ui, "px-3 py-2 rounded-md hover:bg-accent transition")
p.focusable(ui)              // joins the Tab order
if p.activated(ui, idx) { }  // click, or Enter/Space while focused
hovered := p.is_hovered(ui, idx)
if p.key_pressed(ui, p.KEY_DOWN) { }
p.text_field(ui, &buf, "Search")
```

There is no `xdg_popup`, so **menus are drawn inside the window** as absolutely
positioned overlays with a `z-` class. That is a real constraint, not a bug to
work around with a second window.

## Images

palmy decodes images through stb_image — PNG, JPEG, BMP, GIF, TGA, PSD, PNM,
HDR. Pixels are straight 0xAARRGGBB and composite like anything else.

```odin
img, ok := p.load_image("/path/photo.jpg")   // decode
defer p.image_destroy(&img)

p.image(ui, img, "w-full h-full", .Contain)  // .Contain .Cover .Fill .None
p.image(ui, img, "w-full h-full", .None, zoom)   // zoom magnifies around centre

w, h, ch, ok := p.image_size(path)   // dimensions without decoding pixels
p.is_image_path(path)                // cheap extension check
p.write_png_rgba(path, rgba, w, h)   // save
```

Sampling is bilinear, switching to nearest past 2x magnification so a zoomed
photo shows real pixels rather than mush. `draw_image` is available directly
inside `p.pixels` if you need to composite frames yourself — which is how a
video player should blit decoded frames.

## Text editing

Beyond `p.text_field`, which is a single-line widget, palmy gives you the two
measurements a real text editor needs:

```odin
// Where does a click land in this string?
i := p.text_index_at(&app.fonts, line, size, click_x)

// Where does the caret at index i sit?
x := p.text_width_upto(&app.fonts, line, i, size)
```

Both are rune-safe and round-trip against each other. `p.text_field` also takes
a mask rune for password entry. If you need styled runs, selection across
lines, or undo, own that model in your app — palmy deliberately does not.

## Recording a demo

Write a plain-text script and hand it to the recorder:

```
# demo.txt
wait 0.6
type doc
wait 0.8
key Down
key Return
```

```sh
bash /home/alex/Work/palmy/apps/tools/record-app.sh \
  apps/<name>/<name>.bin apps/<name>/demo.mp4 apps/<name>/demo.txt
```

Steps: `key <X11name>`, `type <text>`, `move <x> <y>` (window-relative pointer),
`wait <seconds>`.

**Recordings serialise on a lock** (`/tmp/palmy-record.lock`). Every `wtype`
attaches its own virtual keyboard to the seat, so two recordings running at
once type into each other's windows and ruin both takes. The script waits its
turn automatically — call it normally and never bypass it. Note this compositor build has **no click dispatcher**, so
pointer clicks cannot be synthesized — drive activation from the keyboard, and
use `move` to show hover states. Verify the result by extracting frames with
`ffmpeg -ss <t> -i out.mp4 -frames:v 1 frame.png` and looking at them.

## Rules

- Own only your `apps/<name>/` directory. Do not edit `palmy/`, `shadcn/`,
  `apps/kit/`, `parity/` or another app.
- If palmy or shadcn is missing something you need, work around it in your app
  and **report the gap** — do not patch the toolkit.
- Build to your own `-out` path.
- The package is not shared between apps, so you cannot break another agent's
  build. Take your time and get it right.

## Safety when the app touches the system

`network/` and `bluetooth/` drive the real machine. Build the full
functionality, but **when recording a demo do not disrupt the user's live
connection**: do not disconnect the active wifi, do not forget a saved network,
do not unpair an existing device. Demonstrate scanning, listing, inspecting
details, and at most toggling something you immediately restore. Say in your
report exactly which operations your demo performed.
