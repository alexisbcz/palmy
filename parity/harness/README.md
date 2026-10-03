# parity harness — browser capture

Playwright half of the browser-vs-Odin parity pipeline. It renders every case
the web app publishes and writes the browser ground truth that the Odin side is
measured against: a tight PNG of the case root plus a geometry JSON tree.

See `../CONTRACT.md` for the pipeline and the geometry schema.

## Install

```sh
cd parity/harness
npm install                      # playwright
npx playwright install chromium  # bundled browser
```

Do **not** run `npx playwright install-deps` on Arch — it is Ubuntu-only and
will fail. The bundled Chrome Headless Shell runs fine as downloaded. If it ever
refuses to launch, `capture.mjs` falls back to `/usr/bin/chromium` on its own
and says which browser it used on the `browser` line of its output.

## Run

The web app must be serving `/parity/cases.json` and `/iso/:id`:

```sh
cd parity/web && npm run dev     # http://localhost:5173
```

Then:

```sh
cd parity/harness

node capture.mjs                       # every case
node capture.mjs button-default        # one case
node capture.mjs 'button-*' 'badge-*'  # exact ids and '*' globs

BASE_URL=http://localhost:3000 node capture.mjs
```

Output goes to `../out/web/`:

| file | what |
| --- | --- |
| `<id>.png` | tight screenshot of `[data-parity-root]`, 1 px = 1 CSS px |
| `<id>.json` | geometry tree of the root and its subtree |

Re-running overwrites both files and nothing else, so the run is idempotent —
two runs against the same app produce byte-identical output.

Exit code is 0 when every case captured, 1 when any case failed, 2 on a fatal
error (app unreachable, no browser). The last line is always
`N captured, M failed[: ids]`.

### Environment

| var | default | meaning |
| --- | --- | --- |
| `BASE_URL` | `http://localhost:5173` | where the web app is |
| `OUT_DIR` | `../out/web` | where PNG + JSON land |
| `CHROME_PATH` | — | explicit browser binary, tried before the bundled one |
| `CASE_TIMEOUT` | `20000` | ms budget per case |
| `HEADLESS` | `1` | `0` opens a real window |

## Fixed conditions it enforces

Per `CONTRACT.md`:

- viewport 1280x800, `deviceScaleFactor: 1` (so PNG pixels == CSS pixels),
- `colorScheme: 'light'`, `reducedMotion: 'reduce'`, `forcedColors: 'none'`,
- locale `en-US`, timezone `UTC`,
- animations, transitions, smooth scrolling and the text caret are disabled by
  an init script, and screenshots are taken with `animations: 'disabled'` and
  `caret: 'hide'` — the harness does not rely on the iso route to do this,
- Chromium flags `--font-render-hinting=none --disable-lcd-text
  --force-color-profile=srgb` for stable, grayscale-antialiased sRGB text.

## Per case

1. `goto ${BASE_URL}/iso/<id>`
2. wait for `body[data-parity-ready]`
3. wait for `document.fonts.ready`
4. two animation frames to let layout settle
5. locate `[data-parity-root]` (first match if a case has several — it warns)
6. walk the subtree, write the JSON
7. element screenshot, write the PNG

A case that throws anywhere in there is logged as `FAIL <id>: <reason>` and the
run moves on. A failing case never leaves a half-written file: the PNG and JSON
are only written once the walk has succeeded.

## Geometry JSON

The file is the root node object from `CONTRACT.md`, with `children` nested
inside it:

```json
{
  "tag": "div",
  "cls": "card",
  "text": "Hello parity",
  "rect": { "x": 0, "y": 0, "w": 300, "h": 120 },
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
    "boxShadow": "rgba(0, 0, 0, 0.05) 0px 1px 2px 0px",
    "textAlign": "center"
  },
  "children": []
}
```

Conventions, so the Odin side can match them exactly:

- `rect` is `getBoundingClientRect()` minus the root's own top-left, in CSS px,
  rounded to 3 decimals. The root is therefore always at `0, 0` and its `w`/`h`
  is the size the Odin side must render at.
- `text` is the element's **own** direct text nodes only, whitespace collapsed
  and trimmed. Text inside a child belongs to that child.
- `cls` is the raw class attribute.
- `borderWidth` and `padding` are `[top, right, bottom, left]`;
  `borderRadius` is `[topLeft, topRight, bottomRight, bottomLeft]`. All in px,
  as numbers.
- Colours are always `rgb(r, g, b)` or `rgba(r, g, b, a)`. Chromium serializes
  Tailwind v4's `oklch()` values verbatim from `getComputedStyle`, so the walker
  converts any non-legacy colour to 8-bit sRGB by painting it on a 1x1 canvas —
  the same conversion the compositor does. Alpha is taken from the source string
  rather than from the pixel, so it stays exact.
- `borderColor` is one string when the four sides agree, otherwise the four
  values space separated in CSS shorthand order.
- Elements with zero width or height are omitted, but their children are kept,
  hoisted into the nearest surviving ancestor — a zero-size wrapper should not
  swallow what it paints.
- The walk stops at depth 12 (root = depth 0). A node at the cap keeps its own
  rect and style and an empty `children`; the run prints `depth-clipped N`.
- `<script>`, `<style>`, `<link>` and `<template>` are skipped; they paint
  nothing.
- `lineHeight` is a number in px, except for `line-height: normal`, which has no
  px form in `getComputedStyle` and is emitted as the string `"normal"` rather
  than a fabricated number. `letter-spacing: normal` is emitted as `0`, which it
  is by definition.

## Self-test

`selftest/` is a standalone stand-in for the web app: a stub server plus two
static pages with known geometry. It needs nothing else running.

```sh
npm run selftest       # or: node selftest/run.mjs
```

It boots `selftest/server.mjs` on port 5174, runs `capture.mjs` against it into
`selftest/out/`, and asserts the output: root rect, PNG dimensions equal to the
root's CSS size, own-text extraction, the 4-number border/radius/padding arrays,
child rects measured from the root, `oklch()` resolved to `rgb()`/`rgba()`,
children of a zero-area element surviving, the depth cap, and that a deliberately
broken case is skipped rather than aborting the run.

`selftest/out/` is scratch output; the real run writes to `../out/web/`.
