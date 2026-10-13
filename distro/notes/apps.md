# Applications on Palmframe — notes from the apps side

Owner of this file: the agent that owns palmy/ and distro/apps/ (making palmy
clients run on the minimal system, and building the application set).

## What the integrator takes from distro/apps/

| file | what |
| --- | --- |
| `distro/apps/build.sh` | builds every application into `distro/out/bin/<name>` (47 binaries, 0 failures at the time of writing). `distro/apps/build.sh term files` builds a subset. Logs in `distro/build/apps/logs/`, summary in `distro/build/apps/results.tsv`. |
| `distro/apps/default.list` | the default install: wm greeter term launcher files editor notes calc sysmon image docs sheets slides calendar reader photoshop maps money torrent |
| `distro/apps/desktop/*.desktop` | freedesktop entries for the default set → `/usr/share/applications/`. **The launcher lists nothing without them**: it indexes `.desktop` files and nothing else. |
| `distro/apps/fonts.list` | `<source> <destination> <set>` per line; install every `base` line, `emoji` lines optionally (10 MB). Includes the license texts. |
| `distro/apps/apps.tsv` | every application: builds, runtime deps, works on the minimal system (yes/partial/no), notes |
| `distro/apps/test/minimal.sh` | runs applications in a chroot shaped like the target, against `stubwl.py`, a Wayland compositor offering only the mandatory globals; screenshots to `distro/build/apps/shots/` |

### Libraries and files the applications need at runtime

- glibc: `libc.so.6`, `libm.so.6`, `/lib64/ld-linux-x86-64.so.2`. That is the
  whole link list of every default-set binary (`ldd` checked).
- `libxkbcommon.so.0` (depends only on libc): **recommended**. Clients
  `dlopen` it to compile the keymap the wm sends; when it is absent they fall
  back to a built-in US layout (verified: typing works both ways, including
  shifted characters). Ship it so non-US layouts work in clients.
- `/usr/share/X11/xkb` (→ xkeyboard-config, 3.9 MB): only the wm's own keymap
  compiler reads it, and it has a built-in US fallback (see wm.md).
- Fonts per `fonts.list`. No fontconfig, no cache: palmy walks
  `/usr/share/fonts`, `/usr/local/share/fonts` and `~/.local/share/fonts`.
- **`/proc` must be mounted before any Odin binary runs** — core:os resolves
  paths through it and every `open` fails without it (found the hard way in
  the chroot; palm-init mounts it first, so this is a note, not a request).
- `/dev/ptmx` and `/dev/pts` for `term`.
- Not linked by any default-set binary but needed if shipped: `call` links
  `libopus.so.0`; `mailcore` and `ocr` link `libssl.so.3`, `libcrypto.so.3`,
  `libz`, `libbrotli*`, `libzstd`. All three fail at load time without them.

### The home directory

Create `~/.config`, `~/.local/share`, `~/.local/state` and `~/.cache` in each
user's home (an `/etc/skel` copied by whoever creates `/home/palm`). Several
applications create their data directory with a non-recursive `mkdir` of
`~/.local/share/<app>`: `notes` fails its first-run welcome note on a home
without `~/.local` (verified: "could not write
/home/palm/.local/share/palmy-notes/welcome-to-notes.md"), and the app then
runs empty.

## Requests to other owners

- **apps/palm vs distro/palm — name clash.** `apps/palm` is the application
  command dispatcher (`palm schema`, `palm notes ...`) and builds to a binary
  called `palm`; the package manager is `/usr/bin/palm` per CONTRACT.md.
  build.sh therefore installs the dispatcher as `palm-apps`. Whoever owns
  apps/palm should pick its permanent name.
- **apps/kit (`FONT_DIR`)**: kit.start pins Geist from
  `/home/alex/Work/palmy/parity/web/public/fonts`. That works on the target
  only because palmy's `load_font` now looks the file name up again under the
  font directories when the path does not exist (see below). Cleaner: try
  `/usr/share/fonts/geist` first in kit itself. The same path is copied into
  every app's `shot.odin` and into `videoedit` (`TITLE_FONT`, `MEDIA_DIR`).
- **apps/files**: "Open terminal here" launches `foot`
  (`apps/files/main.odin:615`); on Palmframe it should be `term`.
- **apps/launcher**: the terminal list it uses for `Terminal=true` entries and
  Ctrl+Enter (`main.odin:751`) knows foot/alacritty/kitty, not `term`.
- **apps/notes**: `store_dir` should use `make_directory_all` (see above).
- **wm**: the launcher and the greeter are layer-shell clients — they exit
  with "the compositor does not implement wlr-layer-shell" otherwise
  (verified against the stub). The kiosk session must still offer
  `zwlr_layer_shell_v1`.
- **Clipboard**: palmy has no native `wl_data_device` support, so every copy
  action in the apps goes through `wl-copy`/`wl-paste`, which Palmframe does
  not ship. In-app text fields work; copying out of an app does not. This is
  the biggest functional gap in the default set and belongs to palmy (future
  work, not attempted here).
- **Frame pacing**: editor, calc, image, docs and sysmon commit thousands of
  frames in 4 s when the compositor answers frame callbacks immediately (the
  stub does). Against the real wm they are paced by the page flip, but under
  QEMU's software rendering it is CPU worth knowing about.

## What changed in palmy

All in `palmy/font.odin`; `odin test tests` passes (122 tests, one added).

1. **Crash on any system missing a font weight** (existed at HEAD, verified by
   building HEAD's palmy into the chroot: `Index 97 is out of range 0..<4`).
   `weight_order()` returned slice literals from its own stack frame;
   `fill_weight_gaps`/`fill_slant_gaps` indexed freed stack. On a desktop
   every weight has a file and the table is never read; with DejaVuSans alone
   every application died in `fonts_init`. Now a package-level table.
2. **Built-in fallback font panicked on non-ASCII.** With no font file at all,
   text goes through stb_easy_font, which indexes a 96-entry table by byte;
   the first em dash was an out-of-range panic. Non-ASCII now draws and
   measures as `?`. Test: `test_no_fonts_non_ascii`.
3. **`load_font` relocation.** A path that does not exist is looked up again
   by file name under the font directories. Every application pins fonts by
   their absolute dev-tree path through kit; this makes the same binaries
   find `/usr/share/fonts/geist/Geist-400.ttf` on the target. The scan runs
   only on a miss.
4. **Last-resort sans.** When no candidate family is installed, palmy now
   takes any regular-looking upright text face it finds (skipping mono, emoji,
   symbol, script-specific, bold/italic files) instead of dropping the whole
   interface to the segment font. Verified with only Adwaita Sans installed.

Audited and found already sound (no change): the libxkbcommon `dlopen`
failure path (US fallback, modifiers from the raw mask), cursor-shape-v1
absence (no cursor is set; the compositor's default shows), no
xdg-decoration, wl_shm with XRGB8888 only, no `$HOME/.config`, no locale
(palmy reads no `LANG`/`LC_*`), no `HOME` at all (font scan skips the user
directories).

## How it was verified

`distro/apps/test/minimal.sh` builds a root with glibc, busybox, the
`fonts.list` base set, the binaries and their `.desktop` files, an empty
`/home/palm`, no LANG, and runs each app with `unshare -rm` + `chroot`
(host `/proc`, `/sys`, `/dev` bound in) against `stubwl.py`, which offers
wl_compositor, wl_shm, xdg_wm_base and wl_seat only (plus layer-shell for the
launcher/greeter), sends `no_keymap` (or a real XKB keymap with `XKB=1`), types
text, and saves the last frame.

Observed: 44 application binaries were run (all but wm; prose and
chat-server, added later, are not windowed and were not); 36 drew frames, and
the launcher a 37th once layer-shell was offered; the screenshots of
the default set show correct Geist/JetBrains Mono text. `calc` evaluated typed
input, `term` ran busybox sh and echoed typed input, `editor` took
"Hello World" through libxkbcommon and "12+30=" through the fallback, the
launcher listed and filtered the shipped `.desktop` entries. Failing to start:
`call`, `mailcore`, `ocr` (missing shared libraries), `greeter` (no
layer-shell in the plain stub; needs the wm), `chatbot` (headless bot),
`pkg`/`palm-apps` (CLIs that print usage).

Not verified here: anything inside QEMU (the image is assembled by another
agent), the wm itself, the greeter against palm-login, the emoji font path on
the target (it is covered on the host by the palmy test suite).
