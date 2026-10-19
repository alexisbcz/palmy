# A real browser, GPU clients and X11 on Palmframe — design note

Status: research and one afternoon of experiments, nothing built. Written
against `main` at 3323cb0 (the window-manager rework merge). Nothing in the
repository was changed; every experiment ran from a copy of the committed
source under a scratch directory.

The question, from TODO.md W2 and *The long work → A browser*: what is the
path to letting a user run a real web browser, GPU (EGL/Vulkan) applications
and X11 applications on Palmframe, and what should be done first.

## The short answer

1. **Firefox 158 and Chromium 152 already start, render and take keyboard
   focus on `apps/wm` today, with wl_shm only.** No flag beyond Chromium's
   `--ozone-platform=wayland` was needed. Both were run against the committed
   wm, nested in a headless sway, and screenshotted (below).
2. **The first `<select>`, menu or tooltip kills them.** `xdg_surface.get_popup`
   is answered with a protocol error (`apps/wm/proto.odin:1168`, and the same
   for layer-shell popups at `apps/wm/layer.odin:483`). Chromium's browser
   process died the moment a `<select>` was opened. A browser that cannot open
   a menu is not usable, so **xdg_popup is the single blocker**, and it is a
   compositor task, not a design question.
3. **linux-dmabuf is not needed for a browser.** Without it Chromium reports
   `gpu_compositing: disabled_software` and still has WebGL (`enabled_readback`);
   Firefox draws through software WebRender. The cost is CPU time, which on
   Palmframe's current target (QEMU virtio-gpu without virgl) is the only
   option anyway.
4. **X11 needs no new code to *start*:** rootful `Xwayland -shm` runs as an
   ordinary xdg_toplevel client of the wm today, and Chromium in X11 mode drew
   inside it. Proper per-window (rootless) X11 needs an X window manager:
   either xwayland-satellite (blocked on the same xdg_popup) or a small XWM in
   the wm written on top of the existing X11 wire code in `palmy/x11.odin`.
5. **Vulkan clients on real hardware fail outright** without linux-dmabuf
   (radv/anv WSI binds only linux-dmabuf; mpv got `VK_ERROR_SURFACE_LOST_KHR`).
   EGL clients silently fall back to llvmpipe over wl_shm, even on a machine
   with a real GPU. That is the case for linux-dmabuf, and it is a later case.

## How this was tested

Everything below that says "observed" came from this setup, repeatable in a
few minutes on the build host (Arch, Mesa 26.2.2, AMD 680M):

```sh
git archive HEAD apps palmy shadcn | tar -x -C $SCRATCH/src
odin build apps/wm -o:minimal -collection:palmy=palmy -collection:kit=apps/kit \
    -collection:shadcn=shadcn -out:$SCRATCH/wm
# host: a headless sway with the pixman renderer, private XDG_RUNTIME_DIR
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c sway.conf
WAYLAND_DISPLAY=wayland-1 $SCRATCH/wm --nested -v          # -> wayland-palmy
WAYLAND_DISPLAY=wayland-palmy WAYLAND_DEBUG=1 chromium --ozone-platform=wayland ...
WAYLAND_DISPLAY=wayland-palmy WAYLAND_DEBUG=1 firefox/firefox --profile ... # mozilla.org tarball
WAYLAND_DISPLAY=wayland-palmy Xwayland :47 -geometry 1024x700 -shm -noreset
grim (against sway) for screenshots; Chrome DevTools Protocol / WebDriver BiDi
from node to click a <select> and read chrome://gpu's feature status.
```

The sway socket path has to be short: a runtime dir under the scratch
directory overflows `sun_path` (108 bytes) and sway segfaults.

Not tested: real pointer input to a client (the headless seat problem in
TODO.md *Known-unfixed* reproduced — `wlrctl` motion never reached the nested
clients), QEMU, real hardware.

### What was observed

| Client | Result on wm (wl_shm only) |
| --- | --- |
| Chromium 152, `--ozone-platform=wayland` | Maps, renders, page and UI correct. `SystemInfo.getInfo`: `gpu_compositing: disabled_software`, `webgl: enabled_readback`, `webgpu: enabled_readback`, renderer ANGLE on the host GPU through surfaceless EGL. Opening a `<select>` → `xdg_surface.get_popup` → `wl_display.error "this compositor does not implement xdg_popup"` → browser process exits (crashpad dump). |
| Firefox 158 (official tarball) | Maps and renders; WebGL true. Uses two `wl_subsurface`s with `set_desync`. A `<select>` opened by WebDriver BiDi was drawn as a **subsurface**, not a popup — Firefox does that when it has no input serial for the event; a real click carries a serial and goes to `get_popup` (see *Firefox*, below). Firefox draws its own title bar *and* the wm draws one: GTK3 does not speak xdg-decoration. |
| Ghostty (GTK4, OpenGL) | Maps and works; `GL_RENDERER` would be llvmpipe (Mesa EGL found no dmabuf/wl_drm). Double title bar again; its CSD shadow margin is drawn as part of the window. |
| mpv `--vo=gpu --gpu-context=waylandvk` | Vulkan (radv) fails: `GetPhysicalDeviceSurfacePresentModesKHR: VK_ERROR_SURFACE_LOST_KHR`. Falls back to EGL: `GL_RENDERER='llvmpipe (LLVM 22.1.8, 256 bits)'`, buffers are `wl_shm` from Mesa's "swrast display queue". The window stayed black and ~half the frames were dropped; not investigated further. |
| Xwayland 24.1.13 rootful, `-shm` | Maps as one xdg_toplevel ("Xwayland on :47"). Bound only core globals plus xdg_wm_base v1. Chromium `--ozone-platform=x11` inside it rendered (WebGL false: `-shm` has no GLX acceleration). The root window did not follow the tile size the wm configured. |

Screenshots of the runs are in `browser/` next to this note
(`chr1.png`, `ff1.png`, `ff2.png`, `xw1.png`, `gl1.png`).

## 1. Firefox and Chromium on a wl_shm-only compositor

### Chromium

- Ozone/Wayland is the default platform on Linux with
  `--ozone-platform-hint=auto` when `WAYLAND_DISPLAY` is set; Palmframe has no
  `DISPLAY`, so `--ozone-platform=wayland` (or the hint) is all it needs.
- With no `zwp_linux_dmabuf_v1` and no `wl_drm`, the GPU process cannot share
  buffers with the compositor, so the display compositor runs in software
  (Skia) and presents `wl_shm` buffers; WebGL/WebGPU still run on whatever GL
  the GPU process finds (ANGLE on the real GPU, SwiftShader otherwise) and are
  read back. Observed: `gpu_compositing: disabled_software`. No `--disable-gpu`
  is needed; on a machine with no usable GPU at all Chromium uses SwiftShader
  for WebGL by itself.
- Bound on the wm: wl_compositor, wl_shm, wl_seat, xdg_wm_base v3,
  wl_subcompositor, xdg-decoration (asks for `client_side`, the wm answers
  `server_side`), data device, primary selection, xdg-output, viewporter,
  fractional-scale, xdg-activation, relative pointer, pointer constraints,
  idle inhibit, cursor-shape, wl_output.
- Hard requirements, from source: `WaylandConnection::Initialize()` fails
  without `wl_compositor`, `wl_shm` or `xdg_wm_base`, and before that it
  round-trips until at least one `wl_output` has sent `done` — a compositor
  whose outputs never send `done` hangs Chromium at startup
  ([wayland_connection.cc#L257-L287](https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_connection.cc#L257-L287),
  [wayland_output.cc#L244](https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_output.cc#L244-L250)).
  The wm passes (wl_output v4 sends `done`). Accepted versions: compositor ≤4,
  xdg_wm_base ≤6, shm 1, seat 1–10, output 2–4.
- The shm path in source: no dmabuf → no GBM device in the GPU process →
  viz falls back to software compositing into `WaylandCanvasSurface` shm
  buffers ([wayland_canvas_surface.cc](https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/gpu/wayland_canvas_surface.cc#L73-L94)).
  `--disable-gpu` skips the failed GPU-compositing attempt, at the price of
  WebGL; observed, it is not required.
- Popups ([wayland_window_factory.cc](https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_window_factory.cc#L23-L48)):
  menus (context menu, app menu, `<select>`) and **tooltips** are `xdg_popup`
  with a grab; bubbles are `wl_subsurface`s of their parent. No fallback, so
  the first hover tooltip is as fatal as the first menu.
- Text input v3 is on by default (`kWaylandTextInputV3`) but optional;
  `wp_presentation`, keyboard-shortcuts-inhibit and `wp_linux_drm_syncobj`
  are bound only if present. Electron is the same Ozone code.
- Chromium links `libgbm.so.1` and `libdrm.so.2` unconditionally (ldd), so the
  package needs Mesa's libgbm even when nothing is GPU accelerated.

### Firefox

- Wayland is the default since Firefox 121 when `WAYLAND_DISPLAY` is set; no
  `MOZ_ENABLE_WAYLAND` needed. Firefox 158 started without D-Bus (only an
  `org.a11y.Bus` warning) and without a portal.
- GTK3 is the Wayland client library underneath. It binds wl_compositor,
  wl_shm, wl_seat, xdg_wm_base, wl_subcompositor, wl_data_device_manager,
  primary selection, xdg-output, viewporter, fractional-scale, xdg-activation,
  relative pointer, pointer constraints, idle inhibit, cursor-shape (all
  observed).
- Hard requirements, from source: `MOZ_RELEASE_ASSERT` (a crash) without
  `wl_shm`, `wl_compositor` ≥4 (it needs `damage_buffer`) or
  **`wl_subcompositor`** ([nsWaylandDisplay.cpp#L1369](https://github.com/mozilla-firefox/firefox/blob/main/widget/gtk/nsWaylandDisplay.cpp#L1369-L1380)).
  GTK3 itself only insists on a shell (`xdg_wm_base` or `zxdg_shell_v6`,
  [gdkdisplay-wayland.c](https://gitlab.gnome.org/GNOME/gtk/-/blob/gtk-3-24/gdk/wayland/gdkdisplay-wayland.c)).
- **Page content is always a desync `wl_subsurface`** owned by Firefox on
  top of GTK's toplevel surface, in software mode too
  ([MozContainerWayland.cpp](https://github.com/mozilla-firefox/firefox/blob/main/widget/gtk/MozContainerWayland.cpp),
  [WaylandSurface.cpp#L449](https://github.com/mozilla-firefox/firefox/blob/main/widget/gtk/WaylandSurface.cpp#L449-L458)),
  so subsurface compositing is load-bearing, not a detail.
- Popups: GTK3 maps menus, combo boxes and any temp window with a grab or a
  `move_to_rect` to `xdg_popup`, unconditionally; a temp window with a parent
  but **no grab** becomes a subsurface — tooltips, and the `<select>` opened
  by automation in the experiment above
  ([gdkwindow-wayland.c `should_map_as_popup`](https://gitlab.gnome.org/GNOME/gtk/-/blob/gtk-3-24/gdk/wayland/gdkwindow-wayland.c)).
  A real click opens the hamburger menu, context menu and `<select>` as
  `xdg_popup`, which the wm kills.
- Without dmabuf it renders with software WebRender into `wl_shm` buffers
  (Mesa's software drivers are blocklisted from hardware WebRender,
  [GfxInfo.cpp](https://github.com/mozilla-firefox/firefox/blob/main/widget/gtk/GfxInfo.cpp#L1039-L1045));
  hardware video decode is off without DMABuf. `gfx.webrender.software=true`
  makes the choice deterministic. It
  still tries EGL (`MESA-EGL: warning: failed to get driver name for fd -1`)
  and gets llvmpipe for WebGL.
- **Decorations.** GTK3 does not implement xdg-decoration, so Firefox always
  draws client-side decorations and sets `xdg_surface.set_window_geometry`
  (`26, 23, 1280, 874` in the trace) to exclude its shadow. The wm stores the
  geometry (`proto.odin:1169`) but nothing reads it, so the shadow margin is
  laid out, tiled and clicked as if it were window. Firefox has
  `browser.tabs.inTitlebar = 0` to drop its own title bar; GTK3's server-side
  decoration support is the KDE `org_kde_kwin_server_decoration_manager`
  protocol. Either way the wm must honour window geometry.

### Everything else that will run, and why the same gap blocks it

- **GTK4** requires `wl_compositor`, `wl_shm`, `wl_data_device_manager` and a
  shell ([gdkdisplay-wayland.c](https://gitlab.gnome.org/GNOME/gtk/-/blob/main/gdk/wayland/gdkdisplay-wayland.c#L860-L902)),
  all present; popovers, menus and tooltips are `xdg_popup`.
  `GSK_RENDERER=cairo` presents through shm; otherwise it gets llvmpipe.
- **Qt6** requires only xdg-shell; `Qt::ToolTip` and `Qt::Popup` both become
  `get_popup` ([qwaylandxdgshell.cpp](https://github.com/qt/qtbase/blob/dev/src/plugins/platforms/wayland/plugins/shellintegration/xdg-shell/qwaylandxdgshell.cpp)).
- **Mesa EGL** on a compositor with neither linux-dmabuf nor `wl_drm`:
  hardware init fails, zink fails, then `dri2_initialize_wayland_swrast`
  binds `wl_shm` and renders with llvmpipe
  ([eglapi.c#L694](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/egl/main/eglapi.c#L694-L711),
  [platform_wayland.c#L3167](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/egl/drivers/dri2/platform_wayland.c#L3167)).
  Observed with mpv and Ghostty, on a machine with a real GPU.
- **Mesa Vulkan WSI**: only a software device (lavapipe) binds `wl_shm`;
  radv/anv look only for linux-dmabuf and return `VK_ERROR_SURFACE_LOST_KHR`
  ([wsi_common_wayland.c#L1491, L1648](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/vulkan/wsi/wsi_common_wayland.c#L1491)).
  Observed with mpv.

### The protocol gap list, against `apps/wm`

The globals the wm advertises (`apps/wm/proto.odin:241`):

```
wl_compositor 5   wl_shm 1 (ARGB8888, XRGB8888)   wl_seat 5   xdg_wm_base 3
wl_subcompositor 1   zxdg_decoration_manager_v1 1   wl_data_device_manager 3
zwp_primary_selection_device_manager_v1 1   zwlr_layer_shell_v1 4
ext_session_lock_manager_v1 1   zxdg_output_manager_v1 3   wp_viewporter 1
wp_fractional_scale_manager_v1 1   xdg_activation_v1 1
zwp_relative_pointer_manager_v1 1   zwp_pointer_constraints_v1 1
zwp_idle_inhibit_manager_v1 1   wp_cursor_shape_manager_v1 1   wl_output 4 (per head)
```

What a browser needs that is missing or incomplete, in order of how badly:

| Gap | Where | Effect today | Needed by |
| --- | --- | --- | --- |
| **`xdg_popup`** (+ a real `xdg_positioner`: anchor rect, anchor, gravity, constraint adjustment flip/slide/resize, offset, `reposition` in v3; `grab` and `popup_done` dismissal) | `proto.odin:1168` posts an error; positioner requests are dropped (`proto.odin:353`); `layer.odin:483` same for layer-shell popups | Client killed on first menu, `<select>`, tooltip, autocomplete | Every GTK/Qt/Chromium/Electron app, xwayland-satellite |
| **`set_window_geometry` honoured** | stored at `proto.odin:1169`, never read | CSD clients (GTK3/4, Firefox, Ghostty, Chromium's shadow) are laid out with their shadow margins, offset by ~16–26 px, overlap neighbours, and configure sizes are interpreted as buffer size | GTK3/4, Firefox, Chromium, libdecor |
| **Subsurface sync/desync** | `proto.odin:1460` ignores `set_sync`/`set_desync`; a child's commit applies immediately; `place_below` the parent is not possible (children always draw above, `main.odin:1471`) | Firefox's page and GTK3 tooltips are desync subsurfaces, which the immediate-apply model happens to match; Chromium's bubbles ask for `set_sync` and will tear or show a child's new position before the parent's new content. Synchronized commit caching is needed for correctness, not to start | Firefox (content), Chromium (bubbles), GTK3 (tooltips), video players |
| **`xdg_toplevel.set_parent`** | `proto.odin:1279` reads and drops it | Dialogs (file chooser, print, auth) tile as ordinary windows instead of floating over their parent | All toolkits |
| **Server-side decorations for GTK** (`org_kde_kwin_server_decoration_manager`) or none at all | absent | Double title bar on every GTK app | GTK3; optional |
| **Key state** | `main.odin:1026` `forward_key` sends a press and a release together | No held keys: games, `keydown` repeat semantics, holding Shift-click in web apps; the wm repeats instead of the client | Browsers' `keydown/keyup` model |
| `wl_pointer` axis detail | `main.odin:973` sends `axis_source` + `axis`, no `axis_value120`/`axis_discrete`/`axis_stop` | Smooth, unclustered scrolling; no kinetic scroll stop | Firefox/Chromium scrolling feel |
| `zwp_text_input_v3` (+ an IME) | absent | No CJK input methods; Latin typing unaffected | Firefox, Chromium (`--enable-wayland-ime`), GTK |
| `zwp_linux_dmabuf_v1` | absent | GPU compositing off in browsers, Vulkan fails, EGL is llvmpipe | Hardware acceleration |
| `wp_presentation` | absent | Video/animation timing estimated from frame callbacks | Chromium, Firefox, mpv; optional |
| `wp_single_pixel_buffer_v1`, `wp_content_type_v1`, `xdg_toplevel_icon_v1`, `xdg_dialog_v1`, `zxdg_exporter/importer_v2` (xdg-foreign), `zwp_keyboard_shortcuts_inhibit`, `zwp_tablet_v2`, `wp_linux_drm_syncobj_v1`, `ext_idle_notify` | absent | Nothing breaks; each is a nicety (portal dialogs need xdg-foreign) | Optional |
| `xwayland_shell_v1` | absent | Needed only for rootless Xwayland driven by the wm's own XWM | XWayland |

Already present and working for browsers: xdg-shell toplevels with
maximize/fullscreen/minimize/move/resize/show_window_menu, xdg-decoration,
data device (clipboard and DnD wiring, although DnD has never completed
under test), primary selection, cursor-shape, viewporter, fractional scale,
xdg-output, xdg-activation, relative pointer + pointer constraints (pointer
lock for web games), idle inhibit (video), wl_output v4.

Two non-protocol issues that will show up the moment a browser is used daily:

- **CPU cost.** The wm copies every committed buffer into its own image
  (`surface_commit`, `proto.odin:871`) and repaints the whole screen every
  frame (W2). A 1600×900 browser scrolling at 60 fps is ~5.7 MB copied in
  plus a full-screen composite per frame, on top of the browser's own
  software rasterizing. Damage tracking (W2) becomes a priority once a browser
  exists; the per-surface damage the wm already collects
  (`surface_damage_bounds`) is the input it needs.
- **Pointer input in tests.** No pointer reaches a client on the headless
  seat, so popups (which need a click with a serial) cannot be tested on the
  host the way keyboard demos are. Testing xdg_popup needs either that fixed or
  the QEMU path with virtio-tablet, which is known to deliver clicks.

## 2. linux-dmabuf in a CPU compositor

Feasible, small, and not first.

**Protocol.** Implement `zwp_linux_dmabuf_v1` **v4**, not v3: Mesa's EGL
hardware path learns its render node only from v4 `main_device` (or the legacy
`wl_drm`); with v3 alone and no `wl_drm` it falls back to zink and then to
llvmpipe over wl_shm
([platform_wayland.c](https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/src/egl/drivers/dri2/platform_wayland.c)).
Mesa's Vulkan WSI, Chromium and Firefox accept v3 or v4
([wsi_common_wayland.c](https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/src/vulkan/wsi/wsi_common_wayland.c),
[wayland_zwp_linux_dmabuf.cc](https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_zwp_linux_dmabuf.cc),
[nsWaylandDisplay.cpp](https://github.com/mozilla-firefox/firefox/blob/main/widget/gtk/nsWaylandDisplay.cpp)).
The protocol is at v6 now
([linux-dmabuf-v1.xml](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/raw/main/stable/linux-dmabuf/linux-dmabuf-v1.xml));
v6 replaces `main_device` with a sampling-device tranche, so advertise v4 or v5
until there is a reason not to.

What the server sends: a memfd format table of 16-byte entries
`{u32 format, u32 pad, u64 modifier}`; `main_device` = `fstat(card_fd).st_rdev`
of the card the wm already drives (a primary node is allowed; clients map it to
the render node themselves; virtio-gpu always registers a render node,
[virtgpu_drv.c](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/virtio/virtgpu_drv.c));
one tranche targeting that device with **ARGB8888 and XRGB8888 at
`DRM_FORMAT_MOD_LINEAR` only**. Never advertise `DRM_FORMAT_MOD_INVALID`: it
lets the driver pick an implicit, possibly tiled layout the CPU cannot read.
Validate `create`/`create_immed` params by trying `DRM_IOCTL_PRIME_FD_TO_HANDLE`
on the card fd and closing the handle, which is what wlroots does with no GPU
code ([wlr_linux_dmabuf_v1.c](https://gitlab.freedesktop.org/wlroots/wlroots/-/raw/master/types/wlr_linux_dmabuf_v1.c)).
All of this is ioctls and a memfd, which fits the wm's no-libdrm rule; the
render node can be found under `/sys/dev/char/MAJ:MIN/device/drm/renderD*`.

**Reading the pixels** ([dma-buf.rst, CPU access](https://github.com/torvalds/linux/blob/master/Documentation/driver-api/dma-buf.rst)):
`mmap` the plane once per buffer and cache it; per commit,
`DMA_BUF_IOCTL_SYNC(START|READ)`, copy the damaged rows into `surf.img`,
`DMA_BUF_IOCTL_SYNC(END|READ)`, then `wl_buffer.release` — the same
copy-and-release-at-commit shape the wm already has, which is what makes this
cheap to add.

The prior art is exactly one compositor: **Smithay's pixman renderer** mmaps
LINEAR single-plane dmabufs and brackets reads with sync
([pixman/mod.rs](https://github.com/Smithay/smithay/blob/master/src/backend/renderer/pixman/mod.rs)).
wlroots' pixman renderer and weston's pixman renderer both refuse dmabuf
entirely and do not advertise the global
([wlroots render/pixman/renderer.c](https://gitlab.freedesktop.org/wlroots/wlroots/-/raw/master/render/pixman/renderer.c),
[weston pixman-renderer.c](https://gitlab.freedesktop.org/wayland/weston/-/blob/main/libweston/pixman-renderer.c)).

Pitfalls, in the order they will bite:

1. **`SYNC_START` blocks without a timeout** until the client's GPU fence
   signals (`dma_resv_wait_timeout(..., MAX_SCHEDULE_TIMEOUT)`). Never call it
   with work outstanding from the event loop: on commit, `poll()` the dmabuf fd
   for `POLLIN` (implicit fence done) and hold the surface state until it is
   readable — Smithay's `DmabufBlocker` does this. Explicit sync
   (`wp_linux_drm_syncobj_v1`) can come later; implicit is the default.
2. **Reading GPU memory is slow.** Uncached/write-combined reads measure in the
   0.13–0.3 GB/s range on an AMD APU
   ([Lottes 2023](https://timothylottes.sourceforge.io/2023/2023.htm)); a 1080p
   frame (8.3 MB) is then 30–60 ms, impossible at 60 Hz. Streaming loads
   (`MOVNTDQA`, as in Mesa's
   [streaming-load-memcpy.c](https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/src/util/streaming-load-memcpy.c))
   get ~1 GB/s, ~7 ms. Copy only damage. Intel iGPUs map linear buffers
   cacheable, so they are close to memcpy; discrete AMD will migrate the buffer
   VRAM→GTT on every read (amdgpu's `begin_cpu_access`) and back on the next
   render (inferred, unmeasured).
3. **LINEAR only.** Clients that need tiling for performance pay for it; this
   is fine for a browser surface and bad for games.
4. **Exporters without `mmap`** return `EINVAL`; reject the buffer with
   `zwp_linux_buffer_params_v1.failed`. i915, xe, amdgpu, nouveau, panfrost
   and udmabuf all implement it; amdgpu refuses `NO_CPU_ACCESS` buffers.
5. **virtio-gpu with virgl** (QEMU `-device virtio-vga-gl`): the guest pages of
   a non-blob resource are a shadow copy and virtio-gpu has no
   `begin_cpu_access`, so mmap shows stale pixels unless something issues
   `VIRTGPU_TRANSFER_FROM_HOST` (read from
   [virtgpu_prime.c](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/virtio/virtgpu_prime.c),
   not run). **Without virgl** — the current Palmframe QEMU target — there is
   no GPU rendering at all, clients use llvmpipe over wl_shm, and dmabuf buys
   nothing except making Vulkan (lavapipe) and dmabuf-only clients not fail.

**Direct scanout** is the right second step for fullscreen video and
fullscreen browsing on real hardware: import the client's dmabuf on the card fd
(`PRIME_FD_TO_HANDLE`, `ADDFB2` with modifiers), put it on the primary plane if
its format/modifier is in the plane's `IN_FORMATS`, and never touch the pixels.
It needs something the wm does not have today: holding a `wl_buffer` until the
next flip completes instead of releasing it at commit.

**The GPU compositing alternative** (GBM + EGL + GLES2, importing dmabufs as
EGLImages) handles every modifier and sync correctly, but brings Mesa:
measured on the build host, mesa 54 MiB + llvm-libs 164 MiB + spirv-tools
8 MiB + libglvnd 3 MiB + libdrm 1 MiB ≈ **230 MiB** and a C ABI, against a
compositor whose README leads with `ldd` showing three libraries. In QEMU
without 3D it would be llvmpipe compositing anyway. Hybrid (GPU import, blit
to linear, read back) keeps the whole Mesa cost. Not recommended until there is
real hardware to run on and a measured reason.

## 3. XWayland

### What Xwayland needs from the wm

Measured against `Xwayland 24.1.13` and read in the xserver source
([xwayland-screen.c registry](https://gitlab.freedesktop.org/xorg/xserver/-/blob/master/hw/xwayland/xwayland-screen.c#L497)):
wl_compositor (v4 for `damage_buffer`), wl_shm, wl_seat ≥3, wl_output ≥2,
xdg-output, viewporter (RandR emulation) — **all already present**. Glamor
initialises only with `wl_drm` or linux-dmabuf v4; without them Xwayland logs
"falling back to sw" and every pixmap is a memfd `wl_shm` buffer
([xwayland-shm.c](https://gitlab.freedesktop.org/xorg/xserver/-/blob/master/hw/xwayland/xwayland-shm.c#L136)).
Pass `-shm` to skip the probe. Xwayland compiles the `wl_keyboard.keymap`
text with the external **`xkbcomp`** binary, so that and xkeyboard-config are
runtime requirements.

### Rootful: works today, stopgap only

`Xwayland :N -geometry WxH -shm` (or `-fullscreen`, `-decorate` with libdecor)
creates one xdg_toplevel holding a whole X screen. Observed working on the wm.
X windows inside it are unmanaged unless an X WM runs inside too, the root does
not follow the wm's configure, and copy/paste with Wayland apps does not cross.
Worth a launcher entry ("X11 session in a window") and nothing more.

### Rootless: a window manager is mandatory

In rootless mode Xwayland gives a window a `wl_surface` only after the WM has
issued Composite `RedirectSubwindows(root, Manual)`
([xwayland-window.c ensure_surface_for_window](https://gitlab.freedesktop.org/xorg/xserver/-/blob/master/hw/xwayland/xwayland-window.c#L1488)),
so without an XWM nothing appears. How compositors launch it
([wlroots xwayland/server.c](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/master/xwayland/server.c#L43),
[weston frontend/xwayland.c](https://gitlab.freedesktop.org/wayland/weston/-/blob/main/frontend/xwayland.c#L158),
[Smithay xserver.rs](https://github.com/Smithay/smithay/blob/master/src/xwayland/xserver.rs#L140)):

```
mkdir -m1777 /tmp/.X11-unix; create /tmp/.X<N>-lock (O_EXCL, pid "%10d\n")
listen on \0/tmp/.X11-unix/X<N> (abstract) and /tmp/.X11-unix/X<N>
socketpair A: compositor adopts one end as a Wayland client, child gets WAYLAND_SOCKET=<fd>
socketpair B: the XWM's X connection, child gets -wm <fd>
Xwayland :N -rootless -core -terminate -listenfd <abs> -listenfd <path> -displayfd <pipe> -wm <fd> -shm
export DISPLAY=:N to every child the wm spawns
```

Lazy start (wlroots, niri): poll the listening sockets and spawn Xwayland on
the first connection, re-arming when `-terminate` ends it. The wm today strips
`WAYLAND_SOCKET` from children (`main.odin:1446`) and has no way to adopt an
already-connected fd as a client; both are small changes.

**The XWM's minimum** (following wlroots `xwm.c`, 3,106 lines, of which much
is EWMH completeness):

- connect over the `-wm` fd (no auth); intern atoms; query Composite, XFIXES;
- root mask SubstructureRedirect | SubstructureNotify | PropertyChange;
  `RedirectSubwindows(Manual)`; a 1×1 check window with
  `_NET_SUPPORTING_WM_CHECK`; own `WM_S0` and `_NET_WM_CM_S0`; `_NET_SUPPORTED`;
- `MapRequest` → `WM_STATE` Normal + `MapWindow`; `ConfigureRequest` → apply or
  override and always answer; track `ConfigureNotify` of override-redirect
  windows (menus, tooltips) and place their surfaces at those absolute
  coordinates — **this is why the in-wm XWM does not need xdg_popup**;
- properties: `WM_NAME`/`_NET_WM_NAME`, `WM_CLASS` (app id), `WM_TRANSIENT_FOR`,
  `WM_HINTS` (input), `WM_NORMAL_HINTS` (min/max), `WM_PROTOCOLS`,
  `_NET_WM_WINDOW_TYPE`, `_MOTIF_WM_HINTS`, `_NET_WM_STATE`;
- client messages: `WL_SURFACE_SERIAL` (matched against
  `xwayland_surface_v1.set_serial`, either may arrive first),
  `_NET_WM_STATE` fullscreen/maximize, `_NET_ACTIVE_WINDOW`,
  `_NET_WM_MOVERESIZE`, `WM_CHANGE_STATE`;
- focus: `SetInputFocus` unless `input=false`, plus `WM_TAKE_FOCUS`; close
  with `WM_DELETE_WINDOW`, else `KillClient`;
- keep X window positions in sync (`ConfigureWindow`) with where the wm draws
  them, or clicks land in the wrong place;
- the Wayland side: `xwayland_shell_v1` (wlroots' is 241 lines), restricted to
  the Xwayland client, giving surfaces an "xwayland" role the workspace layer
  treats like a toplevel.

Clipboard bridging (CLIPBOARD and PRIMARY via XFIXES `SelectSelectionInput`,
with INCR for large transfers; ~1,300 lines in wlroots) is a second step:
without it copy/paste works X↔X and Wayland↔Wayland only.

### The two realistic options

| | xwayland-satellite | XWM inside `apps/wm` |
| --- | --- | --- |
| What it is | A separate Rust process: the X WM, a Wayland server to Xwayland and a client of the wm; it turns X windows into ordinary `xdg_toplevel`/`xdg_popup` ([ARCHITECTURE.md](https://github.com/Supreeeme/xwayland-satellite/blob/main/ARCHITECTURE.md)). niri ships it since 25.08. v0.8.3, MPL-2.0. | Odin, on top of `palmy/x11.odin`'s wire code (refactored out of its `Window` struct into a generic connection with extensions, `SendEvent`, selections). |
| Needs from the wm | xdg_wm_base **with popups** (it maps override-redirect windows to `get_popup`, [server/mod.rs](https://github.com/Supreeeme/xwayland-satellite/blob/main/src/server/mod.rs#L1622)), wl_compositor ≥4, subcompositor, wl_shm, viewporter — everything else is present. Plus ~150 lines: sockets, lock file, `DISPLAY`, lazy spawn with `-listenfd` (copy niri's [satellite.rs](https://github.com/YaLTeR/niri/blob/main/src/utils/xwayland/satellite.rs)). | `xwayland_shell_v1`, an xwayland surface role, adopting a pre-connected client fd. |
| Size | ~150 lines in the wm once xdg_popup exists | Estimated 200 (launch) + 150 (shell/role) + 1,200–1,800 (WM) + 800–1,200 (clipboard, later) lines of Odin |
| Dependencies | the satellite binary: libxcb, xcb-util-cursor | none beyond Xwayland |
| Limits | All X toplevels at the monitor origin; apps that need absolute placement (Steam notifications) break; mixed DPI uses the smallest scale; an extra buffer hop | Every EWMH quirk is ours to find |

Both need Xwayland itself.

## 4. What the distribution would have to ship

Palmframe copies glibc, libxkbcommon and xkeyboard-config from the Arch build
host (`distro/recipes/generate.sh`); the same mechanism can package any of
these, with the same caveat — nothing is built from source. Measured on the
host:

| Option | Packages | Size |
| --- | --- | --- |
| **Firefox** (mozilla.org tarball) | The tarball (bundles NSS, its own sqlite, codecs) + gtk3, glib2, pango, cairo, harfbuzz, freetype, fontconfig, gdk-pixbuf, atk/at-spi2, libX11/libxcb family (linked even on Wayland), dbus libs, libxkbcommon, libwayland-client/-cursor/-egl, ICU, libsystemd (linked, not run), libasound, libseccomp. `ldd libxul.so` resolves to 77 MB of system libraries. | 326 MB unpacked + ~77 MB libraries |
| **Chromium** (Arch build) | As above minus GTK at link time, plus **libgbm + libdrm (Mesa's)**, libcups, avahi, pulse, NSS, gnutls, dav1d, openh264, libwebp, flac/opus/vorbis. ~84 MB of libraries. | 397 MB + ~84 MB |
| Both browsers, always | **fontconfig + fonts** (a sans, a serif, a mono, emoji, CJK — `fonts`, `fonts-cjk`, `fonts-emoji` packages exist), **CA certificates** (`/etc/ssl/certs`, for NSS: Firefox bundles its own roots, Chromium on Linux uses NSS + system store), `/etc/machine-id` is expected by D-Bus libraries. A session bus is optional: both started without one, with warnings. ALSA or PulseAudio/PipeWire for sound (Palmframe has none). | small |
| GL for WebGL / GTK4 / mpv | Mesa (llvmpipe at minimum): mesa + llvm-libs ≈ 220 MB. Without it, Chromium uses its bundled SwiftShader; Firefox disables WebGL; GTK4 needs `GSK_RENDERER=cairo`. | ~220 MB, optional |
| Vulkan | lavapipe (`vulkan-swrast`) uses wl_shm; radv/anv need linux-dmabuf | optional |
| XWayland | `Xwayland` (2.4 MB) + pixman, libxfont2, libxcvt, libepoxy, libtirpc, nettle, libXau, libei, libdecor; **`xkbcomp`** + xkeyboard-config at runtime. Arch's build also pulls mesa/libdrm for glamor, unused with `-shm`; a `-Dglamor=false` build drops them ([meson_options.txt](https://gitlab.freedesktop.org/xorg/xserver/-/blob/master/meson_options.txt#L7)). xwayland-satellite adds libxcb + xcb-util-cursor. | ~10 MB without Mesa |

The arithmetic for the README's "palmy links only libc": a real browser is
roughly half a gigabyte of somebody else's code. That is the price, and the
place to pay it is a package (`palm add firefox`), not the base image.

### The CPU-only browser engines

| Engine | State, October 2026 | Fit |
| --- | --- | --- |
| [Ladybird](https://ladybird.org/) | Pre-alpha; alpha targeted for 2026 on Linux and macOS, not shipped. Linux UI is Qt (`UI/Qt`); pages paint with Skia on the CPU in a separate WebContent process into shared bitmaps. | Not a daily browser yet. Its process split (bitmaps out of a sandboxed content process) is the same shape as a palmy frontend would need; worth revisiting after its alpha. |
| [NetSurf](https://github.com/netsurf-browser/netsurf) | Mature, tiny, CSS 2-ish, little JavaScript. Frontends: gtk, qt, **framebuffer**; libnsfb surfaces include `ram`, `sdl`, `vnc`, `x`, `wld`. | A palmy frontend over the `ram` surface is a small, self-contained project and would give "some web" with zero GPU and few dependencies. It will not run modern web apps. |
| [Servo](https://github.com/servo/servo) | v0.7.0 (2026-10-05). Embeddable; renders through OpenGL (surfman), i.e. llvmpipe without a GPU. | Embedding pulls Mesa in; not CPU-native. |
| WebKitGTK / WPE | WebKitGTK 2.52 on the host. The web process allocates dmabufs through GBM itself and GTK's GL imports them; the compositor's linux-dmabuf is never involved. A shared-memory swap chain is used when acceleration is off ([AcceleratedSurface.cpp#L598](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.cpp#L598-L625)); `WEBKIT_DISABLE_DMABUF_RENDERER=1`, `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1`, `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`. WPEPlatform's Wayland view has a `wl_shm` path and treats dmabuf as optional ([WPEDisplayWayland.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WPEPlatform/wpe/wayland/WPEDisplayWayland.cpp#L274-L305)). | Not run here. Epiphany has the same popup/geometry needs as Firefox and no advantage over it. WPE is the interesting one for embedding a web view in a palmy app later. |

None of them changes the plan: the compositor work in section 1 is needed by
every one of them except a NetSurf-on-palmy frontend.

## 5. Is a browser the gap or the point?

TODO.md asks this before anyone starts. The finding above changes the cost of
the answer: running Firefox is not a port and not a GPU project, it is
**xdg_popup plus window geometry** — perhaps a week of compositor work — and
a package. The question then becomes only whether Palmframe ships a browser
in the base image (no: it is half a gigabyte) or makes one installable (yes:
an assistant that is "part of the system rather than a browser tab" still has
to coexist with the web people use). Sub-identities map naturally onto browser
profiles (`firefox --profile ~/.identities/<id>/firefox`), which is the first
place the identity design touches the browser.

## Recommended plan, in order

1. **xdg_popup and a real xdg_positioner** in `apps/wm` (and the layer-shell
   `get_popup` beside it). Positioner state (size, anchor_rect, anchor,
   gravity, constraint_adjustment, offset, reactive, parent size/configure),
   placement relative to the parent's window geometry, constraint against the
   output (flip, then slide, then resize), `configure`/`repositioned`,
   `grab` with dismissal on click-outside and Escape via `popup_done` (topmost
   first), nested popups, keyboard focus to the grabbing popup, drawn above
   everything. Test with a palmy-native unit client over a socketpair the way
   `--kbd-selftest` does, then Firefox and Chromium in QEMU with
   virtio-tablet clicks (the headless seat cannot click). Done when a
   `<select>`, a context menu, the omnibox dropdown and a tooltip work in both.
2. **Honour `xdg_surface.set_window_geometry`** everywhere the wm treats a
   window as a rectangle: placement, tiling, configure sizes (they are geometry
   sizes), hit testing, the frame, snapping, the overview. Then decide the
   decoration policy for clients that will not do xdg-decoration (GTK3): draw
   no wm frame for a client that set a geometry with margins, or implement
   `org_kde_kwin_server_decoration_manager`.
3. **`xdg_toplevel.set_parent`**: float dialogs over their parent.
4. **Package Firefox** from the mozilla.org tarball plus its library closure
   (generated recipes, as for libxkbcommon), with fontconfig and the existing
   font packages and CA certificates. Add it to the launcher. Measure frame
   time while scrolling in QEMU; that number decides how urgent step 6 is.
5. **Real key press/release** to clients (W2) and `axis_value120`/`axis_stop`
   for scrolling — the remaining input gaps a browser exposes.
6. **Damage tracking** in the compositor (W2): with a browser on screen, the
   full repaint per frame is the dominant cost the wm controls.
7. **XWayland via xwayland-satellite**, now that popups exist: sockets, lock
   file, lazy spawn with `-listenfd`, `DISPLAY` exported to children; ship
   Xwayland (`-shm`), xkbcomp and the satellite binary. Revisit an in-wm XWM
   only if satellite's placement limits matter in practice. Before that, a
   rootful `Xwayland -shm -decorate` launcher entry is a 20-line stopgap.
8. **linux-dmabuf v4, LINEAR only, CPU import** with `poll()` before
   `DMA_BUF_IOCTL_SYNC` and damage-only streaming copies — when Palmframe runs
   on real hardware, to stop Vulkan clients failing and give browsers GPU
   rasterization. Not useful in QEMU without virgl.
9. **Direct scanout** of opaque fullscreen dmabuf surfaces (needs buffer
   lifetime tracking past commit). Only then consider whether GBM/EGL is worth
   its ~230 MB.
10. Optional, in parallel to all of the above, and in the spirit of the
    project: a **NetSurf frontend on palmy** over libnsfb's `ram` surface, as a
    zero-dependency "read a page" component the assistant and the mail client
    can embed.
