# wm on bare metal — notes from the window-manager side

Owner of this file: the agent that did TODO.md "W1 — boot it" (apps/wm).

## What palm-login gets

```
wm --drm                          user session
wm --drm --kiosk --exec greeter   greeter session
```

- `--drm` is also chosen automatically when neither `WAYLAND_DISPLAY` nor
  `DISPLAY` is set and `/dev/dri/card0` exists, so plain `wm` works too.
  `--nested` forces the old behaviour.
- `--drm` refuses to start when `WAYLAND_DISPLAY` or `DISPLAY` is set (that is
  somebody's live desktop), unless `PALMY_WM_DRM_LIVE=1`. **palm-login must
  not pass either variable into the session environment.**
- `--exec <cmd>` (repeatable) is word-split like a config `exec =` line and
  run once the socket listens, with `WAYLAND_DISPLAY=wayland-palmy` set and
  `XDG_RUNTIME_DIR` inherited. Children are reaped.
- `--kiosk`: no bar, no frames, no gaps, monocle layout (the first client
  fills the output), no key bindings, no config autostart. wm exits when the
  first `--exec` client exits, with that client's exit status (128+signal if
  it was killed). Ctrl+Alt+Q still quits (hardcoded escape hatch).
- SIGTERM / SIGINT: wm leaves its loop, restores the CRTCs it found and exits
  0. That is how palm-login should end a session.
- **SIGHUP no longer ends wm --drm**: it means "re-read /etc/palm/keyboard"
  (installer work, below). palm-login's `session_ended` sends SIGHUP and then
  SIGTERM to the session's process group, so sessions still end as before.
  The nested mode keeps the default SIGHUP behaviour.
- In a normal session `SUPER+SHIFT+E` (bind `exit`) quits wm on bare metal, so
  the user can get back to the greeter. reboot/poweroff binds stay
  intent-only (logged); power belongs to the greeter.

Requirements on the environment (all as in CONTRACT.md):

- `XDG_RUNTIME_DIR` set and writable (0700, owned by the user).
- The user in `video` and `input`; `/dev/dri/*` root:video 0660 and
  `/dev/input/event*` root:input 0660 **before wm starts** (palm-init's
  coldplug). Input devices are scanned once at startup — see gaps.
- No logind and no D-Bus needed. If a system bus with logind is reachable, wm
  uses TakeControl/TakeDevice instead (that path is unchanged and still
  untested on real logind).
- `HOME` for the config file (`$XDG_CONFIG_HOME/palmy/wm.conf`, falling back
  to `~/.config/palmy/wm.conf`; built-in defaults when absent).

## Verified, inside QEMU only (apps/wm/qemu-test.sh)

virtio-vga + virtio-keyboard-pci + virtio-tablet-pci, distro/out/bzImage,
throwaway busybox initramfs, wm running as uid 1000 in video+input:

- KMS: direct open of /dev/dri/card0, master by first-opener, SETCRTC
  1280x800@75, page flip with real completion events, software cursor.
- Keyboard: virtio-keyboard through the wm's own XKB compiler, both with
  /usr/share/X11/xkb present (evdev rules, us) and absent (built-in US
  keymap); `echo hello` typed into term shows `hello`; SUPER+Return,
  SUPER+D (launcher), Ctrl+Shift+W reach the right place.
- Pointer: virtio-tablet absolute motion scaled to the output, clicks focus
  windows and reach clients.
- `--kiosk --exec term`: fullscreen, undecorated; exits with the client.
- SIGTERM as root: clean stop, status 0.
- `wm --drm-probe` inside the guest: 173 checks, 0 failed.

Screenshot: distro/build/wm/desktop.png.

## Keyboard layouts and local time (installer work)

Per INSTALLER.md "System configuration files". Files: `apps/wm/keyboard.odin`
(new), `apps/wm/clock.odin` (new); edits in `xkbcomp.odin`, `xkbmap.odin`,
`bare.odin`, `main.odin`, `proto.odin`, `qemu-test.sh`.

**/etc/palm/keyboard** — `layout = fr`, `variant =`, `options =` (also
`model =`); `#` comments, optional quotes, case-insensitive keys; unknown keys
and malformed lines are logged, not fatal. Several layouts work:
`layout = us,ru`, `variant = ,phonetic`, `options = grp:alt_shift_toggle`.

- Precedence: `XKB_DEFAULT_LAYOUT` (+ `XKB_DEFAULT_VARIANT`) >
  `XKB_DEFAULT_OPTIONS` / `_MODEL` / `_RULES` > the file >
  /etc/vconsole.conf / xorg.conf.d > `us`. `XKB_DEFAULT_VARIANT` alone applies
  to the file's layout. With `XKB_DEFAULT_LAYOUT` set, the file's variant is
  dropped because it was chosen for a different layout.
- Compiled by wm's own XKB compiler from /usr/share/X11/xkb. Before compiling,
  wm checks that `symbols/<layout>` exists and defines the variant. Names are
  restricted to `[A-Za-z0-9_-]`. A layout or variant that is missing, or a
  keymap whose letter rows type nothing, is logged as
  `wm: keyboard: xx (from /etc/palm/keyboard): no layout "xx" ...; falling back to ... (us)`
  and replaced by `us`. If there is no XKB data at all, the built-in US
  keymap is used, as before.
- Reload: SIGHUP always recompiles. inotify on the file's *directory*
  (`CLOSE_WRITE`, `MOVED_TO`, `DELETE`, `MOVED_FROM`) is immediate and
  catches both write-in-place and write-then-rename. A once-a-second stat
  check covers a directory that did not exist when wm started. A file change
  whose resolved layout is unchanged is ignored.
- On reload, every `wl_keyboard` of every client gets a new memfd keymap,
  followed by `wl_keyboard.modifiers` to the focused client. palmy clients
  already rebuild their xkb state when a second keymap arrives
  (`palmy/xkb.odin keymap_load`), so typing in an open window switches at once.
  The bar shows a note (`keyboard: de`) and a layout badge left of the clock
  whenever the layout is not plain `us`.
- **Installer**: writing /etc/palm/keyboard is enough; wm notices within
  milliseconds. If it wants certainty, `kill(getppid(), SIGHUP)` from a
  `--exec` child reaches the wm that started it.

Fixed along the way (these affected every bare-metal session, not only the
installer):

- **AltGr did nothing.** wm's xkb state took a key's modifiers only from
  `modifier_map`. <RALT> gets Mod5 from its interpret's
  `SetMods(modifiers=LevelThree)`, not from a modmap. Explicit SetMods/LatchMods
  in interprets are now recorded (`compat_setmods_of`) and used for keys with no
  modmap. de AltGr+Q gives `@`.
- **The reverse table** (keysym back to keycode for forward_key) now covers
  levels 3/4 (AltGr), so `@ | { [ \` on fr/de reach clients. It also knows when
  Caps Lock alone produces an uppercase letter, so Caps+a no longer comes out
  as `a` (Shift+Lock). It is built for the active XKB group.
- **Group switches** (`grp:*` options): ISO_Next/Prev_Group is looked up at
  the level the current modifiers select, so Shift+Alt toggles work. The group
  is sent in `wl_keyboard.modifiers`, which used to always send 0.
- xkbcomp's rules resolution had no `layout[N]` support. Extra layouts are now
  spliced in as `+ru(phonetic):2`, which gives the same symbols line as
  libxkbcommon (`xkbcli compile-keymap --kccgst`) for us,ru / fr,de / variants
  / options.

**Local time** — the bar now has a clock (`Tue 13 Oct  21:39`), the right-most
thing on it; the key legend drops trailing entries to fit beside it. The zone
comes from `TZ` (`Area/City`, `:Area/City` or `/path`), else /etc/localtime,
parsed with `core:time/timezone`'s TZif reader (transitions plus the POSIX
footer rule). It is re-read when the link target, inode, size or mtime
changes, checked every 5 s. glibc does not re-read a repointed /etc/localtime
in a running process, and the live installer repoints it while wm runs. An
unreadable or unknown zone shows UTC and is logged once.

Verified on the host: `wm --kbd-selftest` passes 68 keyboard + 13 clock checks.
They cover parsing, precedence, validation, fallback, fr AZERTY and de y/z,
AltGr through the state machine, the Shift+Alt toggle, libxkbcommon reading our
`us,ru` text and resolving й in group 2, and a full reload over a real
socketpair (SIGHUP, the stat check, an inotify rename): 2 keymap fds plus
modifiers each time. Offsets were checked against tzdata for Paris, New York
in 2100 (footer rule), Kolkata, Lord Howe, Tokyo and UTC. Also unchanged:
`--input-selftest` (evdev 118/118, xkb 134/134, still 131/131 layouts
identical to libxkbcommon) and `--selftest` (116/116).

Verified in QEMU only (`apps/wm/qemu-test.sh --out distro/build/wm-kbd
--keyboard fr --localtime Asia/Kolkata --guest-script ...`, wm --drm as palm,
a root script in the guest playing the installer). Screenshots are in
distro/build/wm-kbd/:

- `02-fr-typed.png`: physical `q w a z` typed `a z q w`; bar badge FR.
- `03-de-typed.png`: after `printf 'layout = de' > /etc/palm/keyboard;
  killall -HUP wm`, physical `q w y z` typed `q w z y` in the same term.
- `04-us-typed.png`: write-then-rename to `us`, no signal; QWERTY again.
- `05-usru-toggle.png`: `us,ru` + `grp:alt_shift_toggle` (plain overwrite, no
  signal). In the launcher's search field, q, Shift+Alt, q w e, Shift+Alt, q
  typed `qйцуq`.
- `06-fallback-us.png`: `layout = xx` + SIGHUP, logged, falls back to us, wm
  keeps running.
- `12-de-altgr-caps.png`: de AltGr+Q gave `@`; Caps Lock + a y gave `A Z`.
- Clock: the bar showed 21:39/21:48 with /etc/localtime ->
  Asia/Kolkata while UTC was 16:09/16:18 (the guest's `date` agreed). With
  America/New_York it showed 12:11 at 16:11 UTC.

qemu-test.sh gained `--out DIR`, `--keyboard layout[:variant[:options]]`,
`--localtime Area/City` and `--guest-script FILE` (runs as root once wm
listens, output prefixed `guest:` in serial.log).

## What I need from others

- **apps/kit (`kit.FONT_DIR`)** is an absolute path into this checkout
  (`/home/alex/Work/palmy/parity/web/public/fonts`). Every kit app (term,
  launcher, greeter, ...) looks for Geist there. On the image that path does
  not exist, so they silently fall back to whatever fonts_init scans. Please
  make kit also look in `/usr/share/fonts/palmy/` (wm already does), and have
  the font package install Geist-{400,500,600,700}.ttf there. The test
  initramfs mirrors the checkout path as a stopgap.
- **Image contents** for a usable session: `libxkbcommon.so.0` (palmy clients
  dlopen it to read the keymap wm sends; wm itself does not need it), a mono
  font (DejaVuSansMono or Liberation Mono) under /usr/share/fonts, ideally
  /usr/share/X11/xkb (without it the keymap is the built-in US one), and
  `.desktop` files for the launcher to list (it shows "No applications match"
  with none).
- **apps/term**: when the shell exits, term keeps its window open
  ("process exited ... ctrl+shift+w to close"). Harmless for the greeter, but
  `--kiosk --exec term` only ends on Ctrl+Shift+W.
- **palmy clients requesting frames**: not a problem any more, just noted —
  wm paces frames by the refresh period because virtio-gpu completes page
  flips immediately.

- **apps/term**: text comes from the keysym through term's own
  `keysym_codepoint` (keymap.odin), which knows only Latin-1 and
  `0x01xxxxxx` Unicode keysyms. Legacy keysyms give no text at all: Cyrillic
  (й is 0x6ca), Greek, Arabic, Hebrew, and `EuroSign` (0x20ac, AltGr+E on fr
  and de). wm delivers them correctly; the launcher, which uses palmy's
  libxkbcommon utf8, shows `qйцуq` for the same keys where term shows `qq`.
  Fix: use `xkb_keysym_to_utf32`, or palmy's typed text for the key.
- **apps/greeter**: its clock shows UTC (README "No timezone"). wm's
  `clock.odin` shows the approach: `core:time/timezone.region_load_from_buffer`
  on /etc/localtime, re-read when the link changes.
- **Image contents**: /etc/localtime resolves only if tzdata
  (/usr/share/zoneinfo) is installed, at least the chosen zone. Without it the
  bar shows UTC.
- **apps/installer**: the keyboard step needs only to write
  /etc/palm/keyboard. Write it as one `write()` or as write-then-rename; a
  truncate followed by several writes can make wm compile a half-written file
  (it recompiles when the final `CLOSE_WRITE` arrives).

## Known gaps (not done, stated rather than faked)

- Keyboard: `options` are passed through the rules file; an option that
  matches nothing is silently ignored (as libxkbcommon does). Only the first
  keysym of a key decides its SetMods fallback.
- Keyboard: a group switch rebuilds the reverse table on the next loop
  iteration, so keys arriving in the same poll batch as the toggle may still
  be resolved in the old group.

- No VT switching. Without logind there is no PauseDevice; Ctrl+Alt+Fn is not
  handled and the kernel console's VT is not put into KD_GRAPHICS. evdev
  devices are grabbed, so the console does not also receive keys.
- Input hotplug: devices are enumerated once at startup. A keyboard plugged in
  later is not opened (DRM connector hotplug is handled via the uevent socket).
- Multi-head: composited into one layout-sized buffer and copied per head; the
  workspace layer still sees one output the size of the bounding box. Only one
  head has ever been run.
- Keys reach clients as press+release pairs re-derived from the keysym
  (the nested path's forward_key, now fed a reverse table built from the
  compiled keymap). Typing, modifiers and repeat work; a client cannot see a
  key held down.
- Rendering is a full CPU repaint per frame; no damage tracking.
