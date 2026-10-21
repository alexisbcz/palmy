# palmy on the web

palmy applications run in a browser tab, unchanged. They are compiled to
WebAssembly (`wasi_wasm32`), draw with the same software rasterizer into a
`<canvas>`, and take keyboard, pointer, wheel, focus and resize events from
the page. Layout, text, widgets and the application's own code are the same
source as the native build, and the frames are the same bytes: every capture
in the end-to-end check is byte-identical to a native offscreen render of the
same frame, except a text caret whose blink phase differs by design (below).

    apps/tools/web-build.sh <app-dir> <out-dir> [--ship <font>]... [--ship-list <file>]
    node palmy/web/serve.mjs <out-dir> 8790
    # open http://127.0.0.1:8790/ in Chromium 137 or later

`index.html` takes `?fill=1` (the canvas fills the page and follows its size
instead of keeping the program's requested size), `?scale=N` (override the
device pixel ratio), `?env=K=V` (repeatable; the program's environment) and
`?args=a b c`.

## What is here

| | |
|---|---|
| `odin/window_wasi.odin` | the window: buffers, present, wait, wake, input dispatch, toplevel controls, the frame log |
| `odin/clipboard_wasi.odin` | the clipboard API over `navigator.clipboard` |
| `odin/keymap_wasi.odin` | the keymap: there is none to compile; the page sends keysyms |
| `odin-root/` | four files overlaid on the Odin toolchain for wasm (below) |
| `js/palmy-web.js` | the page half: WASI over an in-memory filesystem, the canvas, the input queue, JSPI |
| `js/index.html` | the page |
| `serve.mjs` | a static server that sends `.wasm` as `application/wasm` |
| `demo/` | the end-to-end check: drive, native replay, byte compare, frame times |
| `../../apps/tools/web-build.sh` | the build |

None of it is compiled by a native build. `palmy/web/odin/` is a subdirectory
of the `palmy` package's directory, which Odin does not descend into, and its
files are `#+build wasi` besides.

## How the build works

`palmy/` is one Odin package, and seven of its files speak Wayland, X11 or
Linux syscalls: `window.odin`, `wayland.odin`, `x11.odin`, `xauth.odin`,
`wire.odin`, `xkb.odin`, `clipboard.odin`. `web-build.sh` stages the package
into the output directory without them and with `odin/` in their place. The
backend-neutral parts of two of them -- `window.odin`'s input types
(`Input`, `Key_Event`, `Layer`, `Anchor`, `Shm_Buffer`, ...) and toplevel
wrappers (`set_title`, `set_fullscreen`, `window_size`, ...), and `xkb.odin`'s
`KEY_*` constants and keysym helpers -- are lifted out of the originals
verbatim by marker, so they have one source; if an edit moves a marker the
build stops and says which. `apps/kit` is staged the same way minus
`notify.odin` (a Unix socket to the notification daemon).

Nothing under `palmy/` or `apps/` is edited and `window.odin` has no web
dispatch lines: the web backend replaces `window.odin` rather than being one
of its cases, because `window.odin`'s own body is Linux (an `eventfd` to wake
the loop, `ppoll` to wait). The change that would let the staging go away is
in the report that introduced this directory: tag the seven files
`#+build linux`, split `window.odin` into its neutral half and its Linux half,
and move `odin/*.odin` into `palmy/`.

### The Odin toolchain overlay

Four gaps in Odin dev-2026-09's WebAssembly support are bridged by building
against an overlay of the Odin root -- symlinks to the real install, except
for these files. The install is not touched.

- `core:os` reads a WASI directory with an inverted assert
  (`dir_wasi.odin`: `assert(len(buf) < int(entry.d_namlen))`), so the first
  directory listing -- palmy's font scan -- traps. The overlay turns it round.
- `vendor:stb/image` has no stdio on wasm, so `stbi.write_png`, which
  `offscreen_write_png` and `image.odin` call, does not exist. The overlay adds
  it over `write_png_to_func` and `core:os`.
- `core:mem/virtual` has no wasm implementation: its reservation is a nil
  block, and palmy's per-frame node arenas are `virtual.Arena`. The overlay
  reserves zeroed, page-aligned memory from the wasm heap.
- `vendor:libc-shim` implements `powf`, `cosf`, `sinf`, `pow`, `cos`, `sin`
  and `exp` with `core:math`, whose versions lower to calls to those same
  symbols on wasm: infinite recursion on palmy's first `math.pow`. The
  overlay points them at the browser's `Math` (double precision, rounded once
  to float for the `f` variants) and adds `expf`.

The build also links with an 8 MiB stack (`-z stack-size`): the default is
too small for palmy's paint recursion, and a wasm stack overflow is a memory
access out of bounds, not a crash with a name.

## The page

**Blocking.** An application's loop is `for ui in palmy.frames(app)`, which
blocks between frames. On the web it still does: `palmy_web_wait` is a
`WebAssembly.Suspending` import and `_start` is wrapped in
`WebAssembly.promising` (JavaScript Promise Integration), so the wasm stack
parks on a promise that settles on the next input event, the frame callback
or a timeout, while the browser runs. JSPI ships in Chromium 137; elsewhere
the page says so instead of starting. The clipboard calls and WASI
`poll_oneoff` (`time.sleep`) suspend the same way.

**Pacing.** A present is followed by `requestAnimationFrame`, which is the
frame callback: palmy will not paint again until it fires. This is Wayland's
model, so app.odin's frame-loop policy applies unchanged -- a hidden tab gets
no animation frames, the window then runs *logic* frames for due wakes and
input, and paints again when it is shown.

**Pixels.** One buffer, not two: `putImageData` copies synchronously, so the
buffer is free again when present returns. Only the rows damage.odin finds
changed are converted (0xAARRGGBB words to RGBA bytes, alpha forced opaque)
and put; a frame identical to the last is not put at all.

**Scale.** `devicePixelRatio`, rounded to an integer, is the window's scale;
the canvas's backing store is that many device pixels per CSS pixel. A
fractional ratio (1.25, 1.5) is drawn at the nearest integer and scaled by the
browser.

**Keyboard.** Keys go to a transparent `<textarea>` that holds focus while
the canvas is in use, because a canvas never receives composed text. A
`keydown` becomes a keysym (named keys by table, characters by codepoint,
keypad keys by `location`), its first-level keysym from `KeyboardEvent.code`
(read as a US board -- the DOM does not say what an unshifted key produces in
another layout), and the text it typed, unless Ctrl or Meta is held (the rule
palmy applies to xkb's output). Text without a key -- dead keys, IME
composition (taken whole at `compositionend`), the emoji picker, automation's
`insertText` -- arrives from the textarea's `input` event. Repeats are the
browser's (`KeyboardEvent.repeat`); palmy's own repeat stays off, as on X11.
F5, F11, F12 and the developer-tools chords are left to the browser.

**Pointer and wheel.** Pointer events in CSS pixels are palmy's logical
pixels. A press captures the pointer, so a drag that leaves the canvas still
ends in it. One wheel notch is palmy's `SCROLL_NOTCH` (10): Chromium's 100
pixels and Firefox's 3 lines both map to it.

**Focus and resize.** The textarea's focus and blur are the window's
activation. With `?fill=1`, a ResizeObserver on the canvas's container
reports its size, and palmy reallocates at the next frame, as for a Wayland
configure.

**Cursor, title, fullscreen.** `canvas.style.cursor`, `document.title`,
`requestFullscreen` (which the browser grants only during a user gesture). A
layer surface (panel, launcher) cannot exist in a page and `create` fails
with a message saying so.

**Fonts are shipped, not discovered.** The page's filesystem holds only what
the build shipped (`--ship`, `--ship-list`), each file at the absolute path
the program will ask for. palmy's font scan and `load_font` run unchanged
over it and find exactly those files. `demo/` ships what the native build of
the same app actually loaded (`PALMY_REPLAY_FONTS`), which is what makes the
two renders comparable; a real deployment would ship a small chosen set
(the four Geist weights plus two mono faces are 764 KB; the showcase's full native set,
with Noto CJK and colour emoji, is 66 MB).

**Files.** WASI over an in-memory tree. Writes (colorpick's saved palette,
`offscreen_write_png`) land in memory and last as long as the page. `HOME` is
`/home/web`; `/tmp` exists.

**Clipboard.** `navigator.clipboard.writeText` and `readText`, through
suspending imports, so `clipboard_set`/`clipboard_get` keep their
synchronous signatures. Writing needs a focused page; reading needs the
`clipboard-read` permission, which Chromium asks the person for. Refused,
`clipboard_get` returns false except for text this window copied itself,
answered from memory as the native backends do. There is no primary
selection on the web (`primary_set`/`primary_get` work within one canvas and
nowhere else), and a page cannot watch the clipboard (`clipboard_watch` is
`.Unsupported`). Applications that copy by running `wl-copy` through
`apps/kit` cannot copy on the web.

**No subprocess.** `os.process_*` fails on WASI; an app that shells out sees
the tool as missing (colorpick shows "grim missing"). That is the seam the
README's portability discipline asks for, and it holds.

**Threads: none.** A web build is single-threaded. Worker threads would need
a `SharedArrayBuffer` -- so the page served cross-origin isolated (COOP and
COEP; `serve.mjs` already sends both) -- an Odin runtime built with wasm
atomics and shared memory, and a thread-spawn shim in the page. Nothing in
the toolkit needs threads and the applications that use them (clipboard
pipes, term's pty reader) are the ones that cannot run here anyway, so it is
not done. `wake_window` from the loop's own code works: it is an atomic flag
the next wait sees.

**IME position, accessibility.** Not done: the textarea sits at the page's
corner, so an IME's candidate window does too, and the canvas has no
accessibility tree.

## The end-to-end check

    PLAYWRIGHT_DIR=<.../node_modules/playwright> palmy/web/demo/run.sh <scratch-dir> [demo...]

For each demo -- the parity showcase (`showcase`, and again at 2x, `hidpi`,
and in a resizing page, `resize`), `apps/colorpick` (`colorpick`), and a
small text-area program for both clipboard directions (`clip`) -- it:

1. builds the native app with `demo/replay/replay.odin` and a hook compiled
   into its own package (`demo/native-replay.sh`; the app's files are
   copied unchanged) and asks it which font files it loads;
2. builds the web version shipping exactly those;
3. drives the page in Playwright's Chromium (`demo/drive.mjs`): clicks,
   typing, wheel scrolling, key chords, clipboard round trips, resizes; after
   each step it waits until the program is parked with nothing queued, and a
   capture reads the canvas with `getImageData` in the same task as the
   frame number it belongs to;
4. replays the page's frame log natively (`PALMY_WEB_LOG=1` writes, for every
   painted frame, the viewport, the frame clock, pointer, buttons, wheel,
   keys, text and what clipboard reads returned; floats as bit patterns)
   through an offscreen renderer, writing the same frames as raw RGBA;
5. byte-compares them (`demo/compare.mjs`) and reports frame times
   (`demo/times.mjs`).

**The two differences, and why.**

- *The caret.* A focused text field's caret blinks on the wall clock in a
  window (time since the last keystroke) and on the renderer's synthetic
  clock offscreen (`widgets.odin`, `caret_on`), deliberately, so that
  offscreen captures are deterministic. In a frame where it is lit on one
  side and not the other, the frames differ by exactly the caret: a column a
  caret wide and a line tall. `compare.mjs` reports that as "caret only" and
  fails on anything else.
- *Fused multiply-add.* The `stb_truetype.a` Odin ships for arm64 is
  compiled with floating-point contraction, so its glyph rasterizer
  (`stbtt__rasterize_sorted_edges`, the curve tessellators) uses `fmadd`;
  WebAssembly has no fused multiply-add. At some glyph sizes that moves a stem
  edge's coverage by one level out of 255. In these demos it shows only at
  2x: 96 pixels, all of them delta 1, in one-pixel columns at glyph stems.
  `run.sh` then replays again against a native build whose stb_truetype is
  compiled with `-ffp-contract=off` (`NOFMA=1 native-replay.sh`), and that
  replay is byte-identical to the browser -- which is what proves the
  difference is the C compiler's and not palmy's. Anything still different
  fails the check.

**The frame log** records every frame the loop runs, painted or not: when the
page is not ready for pixels (the frame callback is late, as it is on a
loaded machine or in a hidden tab), palmy runs *logic* frames that see input
but paint nothing, and a replay that skipped them would lose the keys they
consumed.
