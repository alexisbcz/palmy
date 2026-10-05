# term — a terminal emulator

A multi-tab terminal for palmy. The VT engine is written from scratch in Odin
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
| `pty.odin` | `/dev/ptmx` by hand — no libutil, so no fourth line in `ldd` |
| `pump.odin` | the reader thread, which is why a `cat` is not frame-rate bound |
| `render.odin` | the grid, drawn into a pixel cache that outlives the frame |
| `ui.odin` | the tab strip and input |
| `oracle/` | the differential test against libghostty-vt, built separately |

## Commands

```
term                           open a window
term -e CMD [ARG...]           open a window running CMD
term --render -e CMD [ARG...]  run CMD headlessly and print the screen it drew
term --render --json -e CMD    the same, as JSON
term --bench FILE              feed FILE to the engine and report throughput
term --shots DIR               render the screenshots
term --selftest                212 assertions
```

`--render` is the useful one for anything that is not a person: it runs a
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

## What it does not do

Sixel, the Kitty graphics protocol and splits are all deliberately absent.
There is no bidi or Arabic shaping: the grid stores one codepoint per cell and
draws them left to right, which is what a terminal grid is, and what every
terminal without an explicit bidi mode does.
