# The window manager

`wm` is palmy's Wayland compositor, written on the same toolkit as the applications it manages. It runs in two ways:

- **Nested**, as a window inside another Wayland session. This is how it is developed and how its demos are recorded.
- **On bare metal**, with `wm --drm`, which is how Palmframe runs it. It drives KMS dumb buffers with page flip, reads `/dev/input/event*` itself, and compiles its own keymap without libxkbcommon. `wm --drm --kiosk --exec greeter` is the login screen; `wm --drm` is the session.

It tiles by default, with a master column and a stack, and also has monocle, grid and floating layouts. On top of that it has title bars with buttons, snapping to edges and corners, a taskbar in the bar, an Alt+Tab switcher, an overview, a window menu, and a cheat sheet on Super+/ that lists the bindings below from the live configuration.

:::callout{type=info title="Read from the source"}
The tables on this page are generated from `apps/wm/config.odin`, `apps/wm/keys.odin` and `apps/wm/cheatsheet.odin`, with the grouping and wording the cheat sheet uses. They show what the built-in configuration binds today: {{bindingCount}} bindings. Super is the default `$mod`.
:::

## Keyboard shortcuts

A lone tap of Super opens the overview, and so does pushing the pointer into the top-left corner (`super_tap` and `hot_corner` in the configuration).

::keybindings

## Mouse

::wm-mouse

## Configuration

The configuration is a text file, `$XDG_CONFIG_HOME/palmy/wm.conf` (or `~/.config/palmy/wm.conf`). There is no file by default, and that is a supported state: the built-in default below is compiled in and parsed by the same parser, so the two cannot drift apart. The file is re-read within a second of being saved, and Super+Shift+R reloads it.

There is one directive per line, `name = value`, with `#` or `//` comments. `bind`, `rule`, `output` and `exec` accumulate; every other directive takes the last value. A `bind` on a chord the default already uses replaces it, `unbind = $mod, Q` removes one, and `default_binds = replace` starts from an empty table.

::wm-config

## On Palmframe

The keyboard layout comes from `/etc/palm/keyboard` (`layout = fr`, for example), which the installer writes and wm reloads when it changes. The bar's clock follows `/etc/localtime`.

On bare metal it has no VT switching, it ignores keyboards and mice plugged in after it starts, it has only ever run one monitor, and it repaints the whole screen on the CPU every frame. Clients see keys as press and release pairs, so none can see a key held down. There is no `linux-dmabuf`, so no GPU client, and no XWayland. The full list is in [What is missing](/distro/missing) and in the [roadmap](/distro/roadmap#the-window-manager); the bare-metal backend's own notes are [wm on bare metal](/distro/notes-wm).
