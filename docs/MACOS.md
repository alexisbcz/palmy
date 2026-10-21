# palmy on macOS

palmy builds and runs natively on macOS (arm64, tested on macOS 27). It opens
a Cocoa window and blits the software rasterizer's buffer into it, with no GPU
code. Layout, text, widgets and the frame loop are the same code as on Linux.

## Build

The toolchain is the pinned Odin `dev-2026-09` (Homebrew's `odin` formula at
2026-09 is that commit: `odin version` prints `dev-2026-09:a2fb372b7`).

```sh
apps/tools/macos-build.sh tests                  # odin test tests: 153 of 153
apps/tools/macos-build.sh check                  # windowed self-check, ~5 s
apps/tools/macos-build.sh parity CAPTURES BASELINE   # 182 renders, byte-compared
apps/tools/macos-build.sh app notes sheets       # -o:speed builds into $OUT
```

The script writes binaries to `$OUT`, never into the tree. The tree is shared
with the Linux build VM, and that VM must not find Mach-O files where it
expects its own.

## How it works

| piece | file | what it does |
| --- | --- | --- |
| window | `palmy/window_darwin.odin` | an NSWindow. Its content view, `PalmyView`, hosts a CALayer, is the window's delegate, and is the NSTextInputClient |
| present | same | the buffer becomes a CGImage (sRGB, BGRX) and the layer's contents. The bytes are copied, so the next frame never races Core Animation. A frame identical to the last is not sent |
| wait | same | `nextEventMatchingMask:untilDate:`. The wake descriptor is a kqueue with one `EVFILT_USER` event. A CFFileDescriptor watches it and posts an application-defined event, which ends the wait |
| pacing | same | a present sets `frame_pending`. The wait clears it after one refresh of the screen (`maximumFramesPerSecond`). While the window is occluded or minimised it stays set: logic frames run and painting waits, as on a compositor that withholds frame callbacks |
| App Nap | same | while a `wake_after` deadline is armed, the process holds a latency-critical activity |
| keys | same | X keysyms: special keys by virtual key code, the rest from the layout's characters. Text comes from `interpretKeyEvents:`, so dead keys and input methods compose |
| clipboard | `palmy/clipboard_darwin.odin` | NSPasteboard. `clipboard_watch` polls `changeCount` every 250 ms while a window watches. `PALMY_MAC_PASTEBOARD=name` uses a private named pasteboard |
| `poll_fds` | `window.odin` + `window_darwin.odin` | `poll(2)`. `struct pollfd` and the IN/OUT/ERR/HUP bits are the same as on Linux. Errors come back as the Linux errno with the same meaning |
| fonts | `palmy/font.odin` | `/System/Library/Fonts`, `/Library/Fonts` and `~/Library/Fonts` are searched. SF, Menlo, SF Hebrew, Arial Unicode, Hiragino, Apple SD Gothic Neo, Apple Symbols and Apple Color Emoji end the candidate lists |

On Linux nothing changes. `wire`, `wayland`, `x11`, `xauth` and `clipboard`
are `#+build !darwin`. Every other change is inside `when ODIN_OS == .Darwin`.
`Backend` keeps its two values, so no switch on it has a case that is dead
on Linux. `palmy/linux_names_darwin.odin` declares the Linux names that those
switches still type-check against.

## Decisions

- **Command and Control both report as `.Ctrl`.** Every palmy application
  spells its shortcuts with Ctrl. This mapping makes them the shortcuts a Mac
  user expects (⌘C, ⌘S, ⌘Z), and a terminal's ^C still works. Set
  `PALMY_MAC_COMMAND=super` to report Command as `.Super` instead. Option is
  `.Alt` and still types characters, as AltGr does on Linux.
- **`decorate` is ignored, as on X11.** The window always has the system
  title bar, because palmy draws none of its own.
- **⌘Q and the Dock's Quit** ask every window to close. They do not end the
  process mid-frame.
- **No primary selection.** macOS has none. `primary_set` and `primary_get`
  keep a string in the window, and `clipboard_watch({.Primary})` reports
  `.Unsupported`.

## Environment

| variable | effect |
| --- | --- |
| `PALMY_MAC_COMMAND=super` | report Command as Super, not Ctrl |
| `PALMY_MAC_NO_ACTIVATE=1` | do not bring the application to the front when a window opens |
| `PALMY_MAC_PASTEBOARD=name` | use a named pasteboard, not the general one (tests, demos) |
| `PALMY_MAC_DEBUG=1` | print each window's number, for `screencapture -l` |

## Measured

- **Unit tests:** 153 of 153 pass. The 154th needs a Linux memfd.
- **Windowed self-check** (`palmy/darwin/check`): 34 assertions. It covers
  geometry and scale, a click, typed text and keysyms, a composed dead key,
  scroll, a wake from another thread (0.3 ms), `wake_after(300 ms)`
  (300–302 ms), the clipboard and its watch, resize and title. It also
  checks that a hidden, animating window paints 0 frames and runs 12 logic
  frames in 600 ms, and that frames are paced while visible.
- **Parity:** all 182 offscreen renders are byte-identical to the Linux VM's
  baseline, and the metrics are identical except for line order. The
  parity cases pin their fonts. Discovered fonts differ: SF and SF Mono on
  the Mac, Inter and Hack in the VM. A text panel rendered with discovered
  fonts differs between the two machines. The same panel with Geist pinned
  is byte-identical.
- **Idle CPU over 15 s:** 0.00 s for counter, notes and the parity
  showcase; 0.01 s for sheets and term. colorpick costs 4.7% of a core
  (`-o:speed`) because its focused field's caret blinks, which repaints
  the whole Retina window in software. The same cost exists on Linux.

## Not done

- **Live resize.** While a window edge is dragged, AppKit runs its own
  tracking loop inside `sendEvent:`. palmy's frame loop belongs to the
  application, so the old frame stays pinned top-left. The new size paints
  when the drag ends.
- **No pre-edit display** for input methods (palmy has none on any backend),
  no drag and drop, and no layer-shell surfaces.
- **Applications:** `apps/kit/notify.odin` uses `core:sys/linux` for its
  socket, so every kit application fails to build until it uses
  `core:sys/posix`. With that one-file change, notes, colorpick and sheets
  run. `apps/term` needs a PTY (`openpty`), the same posix calls, and a
  reader thread that calls `wake(app)` instead of polling the display
  descriptor, which macOS does not have. Every application that shells out
  to Linux tools (`wpctl`, `nmcli`, ...) needs more than that.
