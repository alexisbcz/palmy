# reader

EPUB, MOBI, PDF and DjVu in one application, on palmy.

```sh
odin build apps/reader \
  -collection:palmy=/home/alex/Work/palmy/palmy \
  -collection:shadcn=/home/alex/Work/palmy/shadcn \
  -collection:kit=/home/alex/Work/palmy/apps/kit \
  -o:speed -out:apps/reader/reader.bin

apps/reader/reader.bin              # the library
apps/reader/reader.bin book.epub    # straight into a book
apps/reader/reader.bin --selftest   # 455 headless assertions
```

## Two kinds of book, and the interface says so

EPUB and MOBI are **reflowable**. The text has no page of its own, so the
window width and the reader's type size decide where the lines fall. The
controls are type size, line height, margins, indented or spaced paragraphs,
ragged or justified, paged or continuous, and a theme.

PDF and DjVu are **fixed-page**. Every page is a picture the author laid out.
There is no type size to change and no text to re-wrap, so the controls are
fit-width, fit-page and zoom — and the settings panel says why rather than
offering a font size that would do nothing.

What they share: the library, the table of contents, search, bookmarks,
highlights, the three themes, and the reading position.

## The formats

### EPUB — hand-rolled, and the one that matters

A ZIP of XHTML, read from the container up. `core:compress/zlib` has a raw
inflate, which is exactly the bitstream a ZIP member holds, so nothing below
`zip.odin` is hand-rolled below that.

| step | file | what is tolerated |
| --- | --- | --- |
| the archive | `zip.odin` | stored and deflated entries in one file, a trailing comment, ZIP64, a local header whose sizes were deferred to a data descriptor, a member that inflates only partway |
| `META-INF/container.xml` | `epub.odin` | missing or unparseable — the archive is then searched for a single `.opf` |
| the OPF | `epub.odin` | a spine `itemref` with no manifest `item`, a manifest `href` not in the archive, a spine item that is not markup — each noted and skipped |
| the TOC | `epub.odin` | an EPUB 3 nav document, an EPUB 2 NCX, or neither, in which case one is built from the spine and the chapters' own `<title>` elements |

Everything that goes wrong is collected and shown in a panel rather than
hidden, so a book missing three chapters from its contents says so.

### The XHTML and CSS subset

`html.odin` is an element stack, a character style carried down it, and a block
flushed at every block-level boundary. No boxes, no floats, no tables as grids.

**Handled.** `p div h1`–`h6` `blockquote pre li ul ol dl dt dd hr section
article header footer nav aside figure figcaption center address main td th tr
caption` as blocks; `b strong i em cite dfn var u ins s strike del code kbd samp
tt small big sup sub span a abbr q mark time font label` inline; `br hr img
image meta link col wbr mbp:pagebreak` void. `id` and `<a name>` become link
targets, `<a href>` resolves inside the book, and `<pre>` keeps its line breaks.
`script`, `head`, `iframe`, `object`, `audio`, `video`, `form`, `math` and
friends are dropped; `<style>` is collected as CSS.

**Error recovery** is one rule: a new block-level element implicitly closes a
`p`, `li`, `td`, `th`, `dt`, `dd` or heading that is still open, and a close tag
for something never opened is ignored. That is what makes a chapter of unclosed
`<p>` read correctly, and it is tested against a deliberately malformed chapter.

**CSS — where the line is drawn** (`css.odin`):

- *Selectors.* A comma list, each entry one or two compounds: a tag, a class, an
  id, or any combination, optionally preceded by **one ancestor compound**. So
  `p`, `.verse`, `p.verse`, `#note`, `blockquote p` and `.chapter > h2` all work
  and mean what they say. A chain of three or more keeps only its nearest
  ancestor and its subject. `>` is read as a descendant combinator rather than a
  child one. Pseudo-classes and attribute selectors are dropped from the
  compound rather than breaking the rule they are in.
- *Properties.* `font-weight`, `font-style`, `font-family` (only "is it
  monospace"), `font-size`, `text-align`, `text-decoration`, `margin-top`,
  `margin-bottom`, the `margin` shorthand, `text-indent`, `display: none`,
  `page-break-before`.
- *Units.* `em`, `rem`, `%`, `pt`, `px` and the absolute keywords. All of them
  become a **multiplier on the reader's chosen type size**, never a pixel count,
  because a book's pixels are the author's guess and the reader's font size is
  the reader's decision.
- *Not here.* The box model, floats, positioning, colour, backgrounds, borders,
  `@media` (skipped entirely rather than applied unconditionally), `@font-face`,
  counters, and `!important` priority — it parses, it does not win.

Why one ancestor and not zero: `blockquote p { font-style: italic }` is in a
great many books, and flattening it to `p` sets the whole book in italic. That
was the first thing the rendered pages showed.

### MOBI — hand-rolled, including HUFF/CDIC

A PalmDB container with Mobipocket headers (`mobi.odin`).

| compression | support |
| --- | --- |
| 1, none | yes |
| 2, PalmDOC LZ77 | yes, and round-tripped against this program's own compressor — the space-folding byte, overlapping back-references, escaped literal runs and all |
| 17480, HUFF/CDIC | **yes** (`huff.odin`) — both dispatch tables, the lazily-resolved CDIC phrase dictionary, and the recursive case where a phrase is itself a bitstream |

HUFF/CDIC has no round trip, because writing the compressor is a far bigger job
than reading it. Instead the tables are validated field by field and a file
whose tables are inconsistent is **refused with a message rather than decoded
into nonsense**, and the decoder is driven through all three of its paths
(terminal dispatch, non-terminal fallback, nested phrase) by hand-built tables
in the selftest.

Trailing record data is stripped before decompression, from the extra-data flags
at byte `0xF2` of record 0 — getting this wrong puts index garbage at the end of
every chapter. EXTH gives author, publisher, ISBN and the updated title.
CP1252 text is widened to UTF-8. **DRM-protected files are refused**, by name,
and will not be supported.

MOBI has no spine and no named anchors. Chapters are therefore cut at the
shallowest heading level present, the TOC is built from the headings, and a
`filepos` link is resolved by binary search over a table of source byte offsets
recorded while parsing.

### PDF and DjVu — through the real renderers

Writing a PDF *renderer* is a far larger job than writing a PDF *writer*, which
this repository already has in `apps/docs/pdf.odin`. The media apps here shell
out to ffmpeg for the same reason, so `fixed.odin` shells out to:

| | PDF | DjVu |
| --- | --- | --- |
| raster | `pdftoppm -singlefile -png -r <dpi>` | `ddjvu -format=ppm -scale=<dpi>` (stb_image reads PNM, so no extra decoder) |
| text | `pdftotext -layout` | `djvutxt` |
| structure | `pdfinfo` | `djvused -e n` / `size` |
| outline | `pdftohtml -xml` (the only poppler tool that emits bookmarks) | `djvused -e print-outline` |

None of it runs on the UI thread. One worker owns the subprocesses, the pages
either side of the current one are rendered ahead, and ten rendered pages are
kept keyed on page *and* zoom. While the right zoom renders, any cached zoom of
the right page is shown, so changing the zoom never flashes a skeleton.

## Reflow

`apps/docs/layout.odin` solves the same problem for a word processor, and this
follows its shape: greedy word wrap measured through `p.text_width`, lines cut
into fragments at style boundaries, a pagination pass that is pure arithmetic,
and a per-paragraph cache keyed on a hash of its bytes and styles. Its author
measured a naive full re-wrap at 33 ms per keystroke over 400 paragraphs.

A book is not 400 paragraphs. Two things follow from that:

**Nothing ever lays out the whole book.** The unit of layout is the chapter —
the spine item, which is what an EPUB already divides itself into and what a
MOBI's headings are used to divide it into. Opening a book wraps chapter one.
Turning a page wraps nothing. Changing the type size re-wraps the chapter you
are in. Five chapter layouts are kept.

**Progress is not a page number.** A page number is meaningless when the font
size can change under it, so a position is *(chapter, byte offset into the
chapter)* and the fraction through the book comes from chapter byte sizes. That
is what makes reopening a book return you to the same words after a change of
type size, of window width, or of theme — all three are asserted.

Underneath both, the block cache is keyed on the block's content **and** on the
measure and type size it was wrapped to, so changing the size and changing it
back is a cache hit that returns pagination identical to before rather than
merely similar. The cache is bounded on cached *lines* (60 000, about 7 MB) and
evicts least-recently-seen down to a target rather than clearing itself.

Pagination keeps two typographic rules, both asserted on every chapter of the
fixture book: a heading is never left alone at the foot of a page, and a
paragraph never leaves exactly one line behind.

## Measured

A generated novel: 36 chapters, 1.67 MB of text, 2652 blocks, 2.0 MB on disk.
A bigger one: 60 chapters, 4.38 MB of text, 6915 blocks.

| | 1.67 MB EPUB | 4.38 MB EPUB | 1.67 MB MOBI |
| --- | --- | --- | --- |
| open (parse, no layout) | 42 ms | 94 ms | 39 ms |
| first page on screen | **55 ms** | 114 ms | 52 ms |
| page turn, same chapter | **0.00001 ms** | 0.00001 ms | — |
| page turn, averaged over the whole book | 0.004 ms | 0.34 ms | — |
| type size change | 14 ms | 20 ms | 13 ms |
| type size changed *back* | **0.13 ms** | 0.20 ms | 0.12 ms |
| whole book laid out | 487 ms / 1201 pages | 1226 ms / 3312 pages | — |
| search | 1.7 ms, 500 hits | 1.3 ms | — |
| memory held | 4.9 MB + 3.1 MB cache | 12.6 MB + 5.1 MB | 5.8 MB |

PDF: a 2-page A4 document opens in 26 ms; one page rasterises to 910 × 1287 in
186 ms, which is exactly why it happens on a worker thread; the text layer costs
14 ms once.

`reader.bin --bench <file>` prints all of it for any book.

## Keys

| | |
| --- | --- |
| `→` `space` `PgDn` `j` | next page |
| `←` `PgUp` `k` | previous page |
| `↑` `↓` | page, or scroll in continuous and fixed modes |
| `[` `]` | previous / next chapter (or outline entry) |
| `Home` `End` | start / end of the book |
| `+` `-` | type size (reflowable) or zoom (fixed) |
| `<` `>` | line height |
| `t` or `c` | contents |
| `/` or `Ctrl-F` | search; `↑` `↓` and `Enter` step the results |
| `b` | bookmark this page |
| `h` | highlight the selection (drag across words first) |
| `l` | bookmarks and highlights |
| `s` | settings |
| `i` | indented or spaced paragraphs |
| `u` | justified or ragged |
| `m` | paged or continuous |
| `w` `f` | fit width / fit page (fixed) |
| `1` `2` `3` | light / sepia / dark |
| `g` or `Esc` | back to the library |
| `Ctrl-O` | open a book |
| `Ctrl-Q` | quit |

In the library: arrows move, `Enter` opens, `Delete` removes the book from the
library (the file itself is never touched).

Everything is also clickable: in paged mode the outer thirds of the page turn
it, a drag across words selects them, and a link in the text is followed.

## Where things are kept

```
~/.local/share/palmy-reader/
  settings.tsv      type size, line height, margins, theme, mode
  library.tsv       one line per book: where it is, and where you were
  covers/<id>.png   the cover, extracted once
  marks/<id>.tsv    bookmarks and highlights
  cache/            scratch for the page rasterisers
```

Tab-separated, 0600, so a corrupt line costs one book rather than the library.
`PALMY_READER_HOME` overrides the directory, which is what the tests use.

**Nothing outside that directory is written, and nothing outside it is read
except the files you pick in the dialog** — whose paths are recorded there
precisely so that the home directory never has to be searched. There is no
scan, no watcher, no index of your disk, and **no network access of any kind**:
no metadata lookups, no cover downloads. An `http://` link inside a book is
reported, not opened.

The position is written a second or two after it changes rather than only on
exit, so a crash or a kill costs at most the page you were on.

## Verification

`--selftest` runs 455 assertions headlessly and reports the count.

Most of them need no real book, because the books are generated: `gen.odin`
holds a ZIP writer (stored *and* fixed-Huffman deflated entries, so the real
inflate path is what reads them back), an EPUB writer and a PalmDOC compressor.
The reader then has to give back exactly what was written — spine order, chapter
text byte for byte, TOC titles and targets, metadata, list kinds and depths,
character styles, entity decoding.

The hostile cases have their own group: a ZIP with no central directory, a valid
ZIP that is not an EPUB, an EPUB with an empty spine, a spine `itemref` with no
manifest item, XHTML with unclosed tags and a stray close tag and an unquoted
attribute, 2000 unclosed `<div>`s, an XML declaration that lies about its
encoding, a MOBI with a truncated final record, a MOBI whose record list runs
backwards, a DRM-ed MOBI, a zero-byte file of each extension, a `.pdf` that is
really an HTML error page, and a PDF that does not exist. None crashes; each
degrades with something to say.

For PDF there is a perfect oracle in this repository: `apps/docs` exports a PDF
from Markdown, so the test writes a document with known text, has `docs.bin`
turn it into a PDF, and asserts the reader's page count matches `pdfinfo`'s and
its text layer holds the markers. DjVu gets the same treatment through
djvulibre's own encoder, including an outline set with `djvused`.

Reflow is asserted structurally on every chapter: every wrapped line fits the
measure, the lines of a block partition its bytes exactly with nothing lost or
duplicated, every line is on exactly one page, no page overflows, no heading is
stranded, no paragraph is orphaned, and changing the type size and changing it
back gives back the identical first byte of every page.

`--shots <dir>` renders eighteen PNGs of the real views through the real
painter, because a page can satisfy every assertion and still have its lines
overlapping. The fixtures are generated into the same directory, so nothing of
yours is ever rendered into one.

The whole suite, the shots and the benchmarks all run clean under
`-sanitize:address`.

## What does not work

- **Tables are not grids.** A `<td>` becomes its own paragraph, in reading
  order. The text is all there and in the right sequence; the columns are not.
- **No text selection across paragraphs.** A selection is within one block,
  which is enough to highlight a sentence and not enough to copy a page. There
  is also no copy: palmy has no clipboard, and `kit.clipboard_set` was left out
  rather than shelling out to `wl-copy` from a reading app.
- **No `data:` URI images.** The alt text stands in. Books use them for
  decoration.
- **No bidirectional text, no complex shaping, no vertical writing.** That is a
  palmy limitation, not this app's, and Arabic or Hebrew books will render as
  disconnected left-to-right letters.
- **Font choice is the reader's, not the book's.** `font-family` is read only
  for "is it monospace". A book that ships its own faces gets the reader's.
- **No DRM**, ever.
- **Continuous mode does not cross chapters by scrolling.** It scrolls within a
  chapter and steps to the next at the end; a single unbroken scroll across a
  whole book would mean laying the whole book out, which is the thing this
  design exists to avoid.
- **PDF and DjVu have no reflow and no highlight.** Bookmarks work; highlights
  need a text model the page images do not have.
- **DjVu page size assumes 300 dpi** when converting to points, because DjVu
  records pixels rather than a physical size.
