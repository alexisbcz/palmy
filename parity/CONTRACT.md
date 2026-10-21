# Parity pipeline contract

Goal: render every shadcn/ui component twice — once by Chromium from the real
shadcn React source, once by palmy (Odin, software rasterizer, Wayland) — and
measure the difference objectively.

Nothing in the Odin side may read an image produced by the browser. The browser
output is ground truth to *measure against*, never an asset to copy.

## Pieces

| path | what |
| --- | --- |
| `web/` | react-router + shadcn (Base UI, `base-nova`, neutral) |
| `web/app/parity/cases.tsx` | THE case registry — single source of truth |
| `web/app/routes/iso.tsx` | `/iso/:id` renders exactly one case |
| `harness/capture.mjs` | Playwright: every case → PNG + geometry JSON |
| `harness/interact.mjs` | Playwright: typing/clicking → per-state PNGs |
| `odin/render/` | Odin: `render <case> <out.png>` via palmy offscreen |
| `odin/pixdiff/` | Odin: compare two PNGs → metrics + heat map |
| `out/web/<case>.png` `.json` | browser truth |
| `out/odin/<case>.png` `.geom.json` | palmy output |
| `out/diff/<case>.png` | side by side + heat map |

## Fixed conditions

Both sides must agree on all of these or the comparison is meaningless.

- Viewport 1280x800, **device pixel ratio 1**, light theme.
- Font: the four static Geist TTFs in `web/public/fonts/`, installed to
  `~/.local/share/fonts/geist-parity/`. The Odin side loads the same files.
- Kerning, ligatures and contextual alternates are disabled in CSS, because
  stb_truetype only reads the legacy `kern` table.
- Transitions and animations are disabled on the isolation route.
- No dates, randomness or network images in a case. Calendars take a pinned
  date.

## The case registry

```ts
export type Case = {
  id: string          // kebab, unique, e.g. "button-default"
  component: string   // "button"
  title: string
  render: () => ReactNode
}
```

Each case renders ONE component. The outermost element of the thing being
measured carries `data-parity-root`. For overlay components (dialog, popover,
dropdown, tooltip, select, sheet, drawer, context menu, hover card, menubar,
command) the case opens the overlay with `defaultOpen` and puts
`data-parity-root` on the *popup content*, since that is the interesting pixels.

The route sets `data-parity-ready` on `<body>` once fonts have loaded.

## Geometry JSON

For each case the harness walks the subtree under `[data-parity-root]` and
writes, for every element:

```json
{
  "tag": "button",
  "cls": "inline-flex items-center ...",
  "text": "Button",
  "rect": { "x": 0, "y": 0, "w": 86, "h": 36 },
  "style": {
    "backgroundColor": "rgb(23, 23, 23)",
    "color": "rgb(250, 250, 250)",
    "borderWidth": [1, 1, 1, 1],
    "borderColor": "rgb(229, 229, 229)",
    "borderRadius": [8, 8, 8, 8],
    "padding": [8, 16, 8, 16],
    "fontSize": 14,
    "fontWeight": 500,
    "lineHeight": 20,
    "letterSpacing": 0,
    "opacity": 1,
    "boxShadow": "...",
    "textAlign": "center"
  },
  "children": []
}
```

`rect` is relative to the root element's top-left, in CSS pixels. This file is
the implementation spec: an Odin component is "right" when its own node rects
match these numbers exactly, before any pixel is compared.

## The Odin side

`odin/render/case_<component>.odin` registers cases:

```odin
@(init)
register_button :: proc() {
    add_case("button-default", proc(ui: ^p.Ctx) {
        shadcn_button(ui, "Button", .Default, .Default)
    })
}
```

`render <case-id>` looks up the case, renders it offscreen at the size recorded
in `out/web/<case>.json`, writes `out/odin/<case>.png`, and dumps its own node
rects to `out/odin/<case>.geom.json` in the same shape as above.

Shared widgets live in `odin/render/shadcn/` and are built only from palmy
primitives.

## Metrics

Two numbers per case, both reported, neither fudged.

1. **Geometry delta** — for each matched box, |Δx|+|Δy|+|Δw|+|Δh| in CSS px.
   Reported as max and mean. This can and should reach 0.
2. **Pixel delta** — over the whole image: mean absolute error per channel, and
   the share of pixels within a tolerance of 2/255 and 8/255.

Text antialiasing differs between FreeType and stb_truetype and cannot reach
zero. Report the number; do not pretend otherwise.

---

# How to implement a component (the proven recipe)

This loop produced `button`, `badge` and `input`. Follow it exactly.

## 1. Read the truth, do not guess

```sh
cat web/app/components/ui/<name>.tsx          # the real class strings
python3 -c "import json;d=json.load(open('out/web/<case>.json'));print(json.dumps(d,indent=1)[:3000])"
```

The JSON is the spec: `rect` (size), `style.padding`, `style.borderWidth`,
`style.borderRadius`, `style.fontSize`, `style.lineHeight`, `style.color`,
`style.backgroundColor` — all resolved to numbers and `rgb()`. Match those
numbers, not your memory of what shadcn looks like.

## 2. Write the widget

`odin/shadcn/<name>.odin`, `package shadcn`. Translate the TSX class strings
into palmy class strings — they are nearly identical, because the theme tokens
are registered (`bg-primary`, `text-muted-foreground`, `rounded-lg`, `ring-3`)
and `p.apply` composes variants the way `cva` does.

Known translations:
- `size-8` → `size-8`, `h-9 px-2.5` → same, `gap-1.5` → same.
- `text-[0.8rem]` → `text-[12.8]` **and set the line height explicitly** from
  the JSON, e.g. `leading-[19.2]`; palmy does not infer it.
- `inline-flex` is a no-op; add `flex-row items-center` if that is the intent.
- Pseudo-classes are not simulated: take a `State{hover, focus, disabled}` and
  branch, as `button.odin` does.
- Icons: `p.icon(ui, sc.ICON_CHECK, "size-4")`. Run
  `node tools/gen-icons.mjs <PascalIconName>...` to add more. The generator is
  additive — it keeps every icon already in `odin/shadcn/icons.odin` and adds
  yours — so pass only the new names. Never hand-edit that file.

## 3. Register cases

`odin/render/case_<name>.odin`, `package main`. **`@(init)` procedures must be
declared `proc "contextless" ()`** or the build fails.

```odin
@(init)
register_x_cases :: proc "contextless" () {
    add_case("switch-on", proc(ui: ^p.Ctx) { sc.switch_(ui, true) })
}
```

Case ids must match `specs/case-ids.txt` exactly.

## 4. Measure, then fix

```sh
odin build odin/render -collection:palmy=$PWD/../palmy -collection:shadcn=$PWD/../shadcn -out:odin/render-<you>.bin
./odin/render-<you>.bin <case-id>
./odin/pixdiff.bin out/web/<case-id>.png out/odin/<case-id>.png --out out/diff/<case-id>.png --json
```

Run these from the `parity/` directory of the checkout or worktree you are
changing. The collections point at that tree, and the renderer writes into the
tree it was built from (`#directory`), so nothing here reaches another
checkout. Browser captures are gitignored: a fresh worktree has none until you
capture or borrow them, as `tools/diff-all.sh` does.

Then compare geometry numerically — this is where "pixel perfect" is actually
winnable:

```sh
node tools/geomdiff.mjs <case-id>
```

Drive `size_match` to true and the box deltas to 0. After that, residual error
is glyph antialiasing, which does not go to zero: Chromium hints stems, stb
does not. **mae under ~8 on a text-light component and under ~25 on a small,
text-dense one is the practical floor.** Do not chase past it, and never report
a number you did not measure.

Inspect visually when stuck:

```sh
magick out/diff/<case>.png -filter point -resize 600% /tmp/look.png
```

## 5. Rules

- Only touch `odin/shadcn/<your components>.odin` and
  `odin/render/case_<your components>.odin`. Never edit another agent's files,
  `main.odin`, `theme.odin`, `icons.odin` (regenerate it instead), or anything
  under `web/` or `harness/`.
- Build to your **own** `-out` path so parallel builds do not clobber.
- The package is shared: if a compile error names a file you do not own,
  another agent is mid-edit. Wait a few seconds and rebuild; do not "fix" it.
- Never read or copy pixels from `out/web/`. Implement the component.
