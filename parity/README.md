# shadcn/ui parity

Render every shadcn/ui component twice — once by Chromium from the real React
source, once by [palmy](../README.md) (Odin, software rasterizer, Wayland) —
and measure the difference with numbers rather than adjectives.

```
┌─ web/ ─────────────┐   ┌─ harness/ ──────────┐   ┌─ odin/ ─────────────┐
│ react-router 8     │   │ playwright          │   │ render  (palmy)     │
│ shadcn + Base UI   │──▶│ 169 isolation routes│──▶│ pixdiff (stb_image) │
│ 61 components      │   │ PNG + geometry JSON │   │ shadcn widget layer │
└────────────────────┘   └─────────────────────┘   └─────────────────────┘
                                   │                        │
                                   └────── out/diff ────────┘
                                        report.html
```

## Running it

```sh
cd web && npm run dev -- --port 5190     # the shadcn app
node harness/capture.mjs                 # browser → out/web/*.png + *.json
node harness/interact.mjs                # hover / focus / typed states
bash tools/diff-all.sh                   # palmy → out/odin, then diff + report
open out/report.html
```

**169 routes, 182 cases.** The diagram counts browser *routes*; the report
counts *cases*. They differ because `interact.mjs` captures extra states of a
component that already has a route — `-open`, `-disabled`, `-checked`,
`-invalid`, plus the hover/focus/typed pass — and each state is its own
diffed case. So `out/report.md` listing 182 rows against 169 routes is correct,
not a truncated table.

`tools/record-demo.sh` records the live palmy window with wf-recorder while
driving it with real keyboard input. `tools/make-comparison-video.sh` turns
every diff into a narrated walkthrough.

## What makes the comparison fair

Both sides are pinned to the same four static Geist TTFs, and the isolation
route turns off kerning, ligatures and contextual alternates — stb_truetype
reads only the legacy `kern` table, and Geist carries GPOS pairs beyond it, so
leaving kerning on shifted every string by a constant 0.098em. With it off the
two sides agree on advance widths to 0.006px at 14px.

The browser lays elements out at subpixel sizes (a button is 67.828px wide, not
68) and Playwright crops screenshots on whole pixels, so an element sits at a
fractional offset inside its own image. The capture records that offset and the
renderer reproduces it; without that, every glyph lands up to a pixel off.

## What the numbers mean

- **Geometry** — width, height, padding, radius, colour. These match exactly,
  and `tools/geomdiff.mjs` prints them side by side. A non-zero delta here is a
  bug, not a limitation.
- **Pixels** — mean absolute error per channel over the whole image, and the
  share of pixels within 2/255.

Mean absolute error does not reach zero and cannot. Chromium rasterizes glyphs
through FreeType with hinting and its own gamma; palmy uses stb_truetype with
unhinted grayscale coverage. The shapes, positions and advances match; the
antialiasing on glyph edges does not. On a large, text-light component the error
lands around 1-4/255; on a small, text-dense one with white text on a dark fill
it lands around 25-35, because glyph edges are then a quarter of all the pixels.

Two calibrations were tried and measured rather than assumed:

- **Linear-light coverage blending** for glyphs and icons — kept. Compositing
  antialiased coverage in sRGB darkens light-on-dark text.
- **A Skia-style text contrast gamma** — implemented, measured, and left
  switched off. Swept from 1.0 to 1.4 it pulls in opposite directions: dark text
  on a light fill improves (badge-secondary 20.24 → 19.87, input-default 2.23 →
  1.70) while light text on a dark fill degrades (badge-default 25.74 → 26.64,
  button-sm 34.55 → 35.05). The mean is flat, so no single constant is
  justified and `set_text_gamma` defaults to 1.0. What is left is hinting:
  FreeType snaps stems to the pixel grid and stb_truetype does not, and that is
  not a curve you can fit.

## What measuring found in palmy

Holding a software renderer against a browser turns vague "looks about right"
into a number, and the number found real bugs. Each of these was discovered by a
diff, fixed in palmy, and re-measured across the whole corpus:

| fix | what was wrong | effect |
| --- | --- | --- |
| text metrics | kerning applied on one side only, a constant 0.098em drift on every string | advances now agree to 0.006px at 14px |
| glyph raster size | the cache rounded to whole pixels, so 12.8px text was drawn at 13px | `text-[0.8rem]` is no longer 1.5% too large |
| subpixel positioning | pen positions snapped to whole pixels | glyphs sit where the browser puts them |
| linear-light blending | coverage composited in sRGB | correct weight for light-on-dark text |
| flex cross axis | a line grew to its tallest child, so an oversized item was pinned to the top instead of overhanging | mean error 4.57 → 3.98 |
| absolute positioning | insets resolved against the content box; CSS uses the padding box | mean error 3.98 → 3.94 |
| `background-clip` | not implemented, so a transparent border was painted over | mean error 3.94 → 3.13 |
| `stroke_round_rect` | the "skip the hollow middle" fast path assumed straight sides and erased the corner arcs of any large radius — a circular ring drew only two columns | circular rings render; regression test added |

Features the work added to palmy because the components needed them: four real
font weights, SVG path parsing and stroking for line icons, design tokens so
class names can follow a design system, `ring-*`, `pointer-events-none`, and
`concat`/`apply`/`focusable`/`activated` for composing widgets.

## Rules the Odin side plays by

The renderer never reads a browser pixel. `out/web/*.json` is a specification —
numbers and colours — and the component is implemented against it from the
shadcn source. Icons are the one piece of borrowed geometry: lucide's path data
is converted to plain `M/L/C/Z` by `tools/gen-icons.mjs` and rasterized by
palmy's own stroker.
