# term — a terminal emulator

A terminal for palmy with tabs, splits, Sixel and the Kitty graphics protocol. The VT engine is written from scratch in Odin
and lives in `vt/`, which knows nothing about windows; everything above it is
a front end.

```sh
odin build apps/term \
  -collection:palmy=$PWD/palmy \
  -collection:kit=$PWD/apps/kit \
  -collection:shadcn=$PWD/shadcn \
  -o:speed -out:apps/term/term.bin
```

```
linux-vdso.so.1
libm.so.6
libc.so.6
```

## What is in it

| | |
| --- | --- |
| `vt/parser.odin` | the DEC state machine: CSI, OSC, DCS, SS2/SS3, C0 and C1 |
| `vt/unicode.odin` | UTF-8 with a streaming decoder, widths, combining marks |
| `vt/sgr.odin` | the attribute parser, including colon subparameters |
| `vt/osc.odin` | title, cwd, hyperlinks, palette, clipboard, ConEmu progress |
| `vt/screen.odin` | cells, rows, scrollback trimmed to the length it uses |
| `vt/terminal.odin` | what the sequences mean: modes, regions, both screens |
| `vt/reflow.odin` | re-wrapping the scrollback when the window changes width |
| `vt/key.odin` | key encoding, legacy and the Kitty keyboard protocol |
| `vt/mouse.odin` | X10, 1005, 1006 and 1015 reporting, and paste bracketing |
| `vt/graphics.odin` | images on the grid: the store, placements, the 32 MiB budget |
| `vt/sixel.odin` | the Sixel decoder, fed a byte at a time as the DCS arrives |
| `vt/kitty.odin` | the Kitty graphics protocol: transmit, place, delete, query |
| `pty.odin` | `/dev/ptmx` by hand — no libutil, so no fourth line in `ldd` |
| `pump.odin` | the reader thread, which is why a `cat` is not frame-rate bound |
| `render.odin` | the grid, drawn into a pixel cache that outlives the frame |
| `tabs.odin` | panes, the split tree in each tab, layout, focus and resize |
| `images.odin` | what a Kitty file transfer may read |
| `ui.odin` | the tab strip, the panes and input |
| `oracle/` | the differential test against libghostty-vt, built separately |
| `oracle/images/` | Sixel against foot and Kitty graphics against kitty |
| `testdata/` | the escape streams those terminals were given, and where each came from |

## Commands

```
term                           open a window
term -e CMD [ARG...]           open a window running CMD
term run -- CMD [ARG...]       run CMD headlessly and print the screen it drew
term run --json -- CMD         the same, as JSON
term run --png F -- CMD        and draw it, images included, into a PNG
term bench FILE                feed FILE to the engine and report throughput
term shots DIR                 render the screenshots
term --selftest                443 assertions
```

`run` is the useful one for anything that is not a person: it runs a
full-screen program on a real pty with no window at all and prints the grid it
ended up drawing, which is how you look at a TUI from a script.

## Keys

| | | | |
| --- | --- | --- | --- |
| `ctrl+shift+t` | new tab | `ctrl+shift+w` | close tab |
| `ctrl+tab` | next tab | `ctrl+shift+tab` | previous tab |
| `ctrl+shift+←/→` | move the tab | `alt+1`…`alt+9` | jump to a tab |
| `ctrl+shift+c` | copy | `ctrl+shift+v` | paste |
| `shift+pgup/pgdn` | scroll the history | `shift+home/end` | top and bottom |
| `ctrl+±`, `ctrl+0` | font size | | |
| `ctrl+shift+r` | split: new pane beside | `ctrl+shift+d` | split: new pane below |
| `alt+←↑→↓` | focus the next pane that way | `alt+shift+←↑→↓` | move the divider that way |
| `ctrl+shift+z` | zoom the pane, and back | `ctrl+shift+w` | close the pane (the tab with its last) |

## Decisions worth knowing about

**libghostty-vt is a test oracle, not a dependency.** Ghostty 1.3.1 installs
`libghostty-vt.so.0`, and it is tempting to build on it. It exports 43
functions: key encoding, SGR attributes, OSC parsing, a few SIMD helpers and a
paste check. There is no terminal in it, no screen, no grid, no CSI parser and
no scrollback — you cannot hand it bytes and get a screen. So the engine here
is written from scratch, and the library is used in `oracle/` as something to
disagree with. The shipped binary neither links nor opens it.

```sh
apps/term/oracle/run.sh        # 250 of 1,352,484 cases differ
apps/term/oracle/run.sh -v     # and say which
```

**OSC 52 writes, but does not read.** A program can put text on the clipboard
and cannot take text off it. Reading is an exfiltration channel: whatever was
last copied — a password, a token, a recovery phrase — would be readable by
anything running in the terminal, including something on the far end of an
ssh connection. The usual mitigation is to ask, and a program that asks a
hundred times defeats it. The query is parsed, recognised and dropped.

**Closing a tab hangs up the terminal.** The child's process group gets
SIGHUP, which is what every shell is written to handle, and SIGKILL if it is
still there a second and a half later. Anything started under `nohup` or
`disown` survives, which is exactly what those are for. Silently orphaning the
process was the other option and was rejected: a build left running with
nowhere to write is a thing that bites hours later.

**The pty is read on its own thread.** Reading from the frame body caps
throughput at the frame rate times the kernel's pty buffer — measured at
1.9 MB/s, against foot's 30. With the reader on its own thread it is 20 MB/s,
and the child never waits for the compositor.

**Rows are repainted, not frames.** palmy repaints its whole tree every frame,
so the grid is drawn into a pixel cache that outlives the frame and only the
rows the terminal marked dirty are re-rendered. A full-screen repaint is
0.38 ms at 80×24; a shell prompt redrawing one line is 0.014 ms.

**A split is a tab holding a tree.** Each leaf is a pane: its own pty, its
own VT state, its own pixel cache. The reader thread and the housekeeping see
one flat list of panes and never ask which tab one is in, which is why splits
needed no change below the tab strip. The panes that will not get the
keystrokes are drawn a third of the way towards the background and their
cursors are hollow. `alt+arrows` are the pane keys only in a tab that has
more than one pane; in an ordinary tab they still reach the program. A new
pane starts in the directory of the one it split from -- from OSC 7 when the
shell sends it, and from `/proc/PID/cwd` of the foreground process when it
does not, which is most shells as installed.

**Images live on the rows.** A placement is cut into one fragment per text
row it covers and each fragment is attached to that row, so an image scrolls,
moves with a scroll region, goes into the scrollback and comes back exactly
as the text beside it does -- and when its rows fall off the end of the
scrollback it is evicted, because the last reference went with them. Each
terminal (each pane) holds at most **32 MiB of decoded pixels**, four 1920x1080
frames; past that the oldest image nothing shows goes first, then the oldest.
An image larger than the whole budget is refused, a chunked transfer cannot
park more than the budget, and zlib and PNG are decoded under an allocator
that refuses anything bigger, so a 65 KB zlib stream of 64 MiB of zeros is an
error rather than an allocation.

**Sixel follows foot; Kitty graphics follows kitty.** Both were run on a
headless sway with the same probe (`oracle/images/run.sh`): after a Sixel
image the cursor is on the image's last row in its first column, as in foot;
after a Kitty placement it is one column past the image on its last row, or
untouched with `C=1`, as in kitty. Every reply and every cursor position in the
Kitty probe is identical to kitty's, and a 64x48 block of the image `kitten
icat` sent is identical to kitty's pixels; the Sixel image differs from foot's
by at most one level in any channel (percent to 0..255 rounding). The
differences that remain are written down rather than hidden: text printed over
a Sixel image cuts that part of it, as foot does, while text never cuts a Kitty
image; and a translucent pixel is blended in sRGB, where kitty blends so that a
50% red over this background is `#cc1924` and here is `#85080f`.

**File transfers read only what kitty would.** `t=f` and `t=t` make the
terminal open a path the program names, which over ssh is a remote program
naming a local file. `images.odin` is the whole policy: a regular file (opened
non-blocking, so a FIFO cannot hang anything), never under `/proc`, `/sys` or
`/dev` after every symlink is resolved, at most the budget in size, and a
temporary file deleted only when it is in a temporary directory and has
`tty-graphics-protocol` in its name. The contents never go back to the program.

**OSC 52 reads stay refused**, images or not; see above.

## What it does not do

The Kitty protocol's animation (`a=f`, `a=a`, `a=c`), Unicode placeholders
(`U=1`) and relative placements (`P=`) answer `ENOTSUP`. Sixel ignores the
pixel aspect ratio, as foot and xterm do once a raster is declared. Images are
not re-wrapped on resize; they stay with the row they started on. There is no
bidi or Arabic shaping: the grid stores one codepoint per cell and draws them
left to right, which is what a terminal grid is, and what every terminal
without an explicit bidi mode does.
