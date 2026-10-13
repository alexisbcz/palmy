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
- SIGTERM / SIGINT / SIGHUP: wm leaves its loop, restores the CRTCs it found
  and exits 0. That is how palm-login should end a session.
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

## Known gaps (not done, stated rather than faked)

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
