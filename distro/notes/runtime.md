# Runtime dependencies: bus, Wi-Fi, audio, Bluetooth, media, TLS

Owner: `distro/recipes/runtime/` (the manifest, the source builds, the
hand-written files, the test), the recipe directories it generates (they say
`from the runtime manifest` in their header), the `runtime` block in
`distro/recipes/generate.sh`, `distro/apps/apps.tsv`, and this file.

Before this work, 16 of the 48 programs in `apps/apps.tsv` did not work and 9
worked partly, because they shell out to ffmpeg, PipeWire, NetworkManager,
BlueZ, bsdtar, wl-copy or ollama, or link OpenSSL or libopus. Now it is 5 that
do not work and 14 partly (`apps.tsv` has the evidence for each row).

## Use it

```
make -C distro                         # unchanged: builds the source packages
                                       # when missing, then everything else
distro/recipes/runtime/src/build.sh    # just the source builds (default set)
distro/recipes/runtime/src/build.sh glibc   # the glibc prototype (not packaged)
python3 -I distro/recipes/runtime/test-runtime.py [--kernel K] [--ollama]
```

The first `make` on a fresh checkout spends ~8 minutes (at `JOBS=8`) building
nasm, x264, opus, ffmpeg, dbus, iwd and libarchive; afterwards the stamps make
it a no-op. `PALMFRAME_SKIP_SRC=1` skips the source step. When a recipe for a
new application appears, `distro/Makefile` only learns of its binary on the
*next* make (it lists `APP_BINS` when it parses, before `recipes` runs): run
`make -C distro recipes` once, then `make -C distro`.

## What was decided, dependency by dependency

| needed by | dependency | decision |
| --- | --- | --- |
| iwd, bluetoothd | D-Bus system bus | **ship**, built from source without systemd/X11/audit (`dbus.build`). No session bus. |
| network | NetworkManager (`nmcli`) | **replace with iwd** — see below. The app has to change. |
| Wi-Fi | wpa_supplicant or iwd + DHCP client | **iwd**, from source. It needs no OpenSSL, libnl or wpa_supplicant (crypto is the kernel's), and does DHCP itself (`EnableNetworkConfiguration=true`), so no dhcpcd. DNS goes through a 20-line `resolvconf` shim it ships. Wired stays palm-init's udhcpc. |
| audio, video, mixer, call | PipeWire, WirePlumber, pw-cat, wpctl, pactl | **ship** (host-copied). PipeWire does not need a bus (RTKit and portal modules just warn). wpctl needs WirePlumber; pactl needs pipewire-pulse; all three are started per session by one `pipewire` (`pipewire.conf.d/50-palmframe.conf`). Plain ALSA would not do: the apps call pw-cat/wpctl/pactl by name. |
| PipeWire's ALSA monitor | udev | **no udevd**: a palm-init one-shot (`sound-cards`) writes `/run/udev/data/+sound:cardN` with `SOUND_INITIALIZED=1`, which is the one property PipeWire gates on. Hotplugged (USB) cards are not covered. libudev itself comes from systemd-libs (a library only; no systemd daemon runs). |
| bluetooth | BlueZ, bluetoothctl, rfkill | **ship** bluetoothd + bluetoothctl + btmgmt (host), rfkill from util-linux (busybox has none). Needs `CONFIG_BT`. |
| audio, video, videoedit, call, captions | ffmpeg | **ship, from source**, with its own codecs plus libx264 (static) and libopus, `--disable-autodetect`: links glibc, zlib, libopus only (Arch's links ~120 packages). No libass (videoedit's `subtitles` filter), no SDL (no ffplay). |
| mailcore, ocr | OpenSSL, CA bundle | **ship** (host): libssl/libcrypto, `openssl`, the Mozilla bundle as `/etc/ssl/certs/ca-certificates.crt` plus `/etc/ssl/cert.pem` (OpenSSL's default CAfile on this build). |
| call | libopus.so.0 | **ship, from source**. |
| archive | bsdtar | **ship, from source** without libxml2 (which pulls 40 MB of ICU), OpenSSL, nettle, ACLs. |
| clipboard, vault, emoji, sheets, files, colorpick | wl-copy, wl-paste | **ship** wl-clipboard (host). The wm implements `wl_data_device_manager`, and wl-copy works through it (verified). |
| ai, chatbot | ollama | **ship, optional** (host, 66 MB, CPU backends only; not in `palmframe-runtime`). Pull + answer verified with qwen3:0.6b. |
| captions | whisper-cli, ffplay | not shipped. |
| reader, ocr | poppler | not shipped: Arch's pdftoppm pulls curl, krb5, NSS, gpgme… A minimal source build needs cmake on the host. |
| call | v4l2-ctl | not shipped. |

`palmframe-runtime` is the meta-package for the services and libraries (not
the applications, not ollama); the `palmframe` meta-package depends on it, so
the image and every install have them.

### NetworkManager without systemd

It can run without systemd (Alpine, Void and Gentoo/OpenRC ship it), but here
it would cost more than it gives:

- it needs the system bus and, for non-root clients, polkit (or
  `auth-polkit=false`, i.e. every user may reconfigure the network);
- it expects udev to have initialised devices (it copes in containers, not as
  a design);
- its closure on the build host is libnm, glib, curl, krb5, NSS, libndp,
  libpsl, libteam, nghttp2/3, ngtcp2, audit, libbpf, libelf… (`ldd
  /usr/bin/NetworkManager /usr/bin/nmcli`), on top of wpa_supplicant or iwd
  for Wi-Fi anyway.

**Proposal for `apps/network`:** talk to iwd directly over the system bus. iwd's
D-Bus API (`net.connman.iwd`: `Station.Scan`, `Station.GetOrderedNetworks`,
`Network.Connect` with an `Agent` for the passphrase, `Device.Powered`,
`KnownNetwork`) covers every action the app has; `apps/wm/dbus.odin` is
already a hand-rolled D-Bus client that could move into kit. Wired status
comes from `/sys/class/net` and `/proc/net/route`. Until then `iwctl` works
from a terminal (members of `wheel` may use iwd: iwd's bus policy).

## How the packages are made

`distro/recipes/runtime/generate.sh`, sourced by the `runtime` block of
`generate.sh`, writes one recipe per package. Two kinds:

**From source** (`runtime/src/<name>.build` + `runtime/src/build.sh`). A
`.build` file pins `version`, `url`, `sha256`, `license`, `builddeps` and a
`build()` function. The driver downloads once into `distro/build/src/dl`,
refuses a tarball whose sha256 differs, unpacks into an empty work directory,
hard-links the staging trees of the build dependencies into a private sysroot
(rewriting their `.pc` files to point at it), runs `build()` under `env -i`
with a fixed PATH, `LC_ALL=C`, `TZ=UTC`, `SOURCE_DATE_EPOCH` and
`-ffile-prefix-map`, installs with `DESTDIR` into
`distro/build/src/stage/<name>`, and copies the runtime part (no headers,
static libraries, pkg-config, manuals), stripped, to `distro/out/src/<name>`,
which the recipe packs. Each tarball's sha256 was cross-checked once against
something independent, noted in the `.build` file: the upstream GPG signature
(ffmpeg, dbus, libarchive, glibc), kernel.org's signed `sha256sums.asc`
(iwd), xiph's `SHA256SUMS.txt` (opus), or Alpine's/Arch's pinned sha512
(x264, nasm). `package=no` builds without packaging (nasm and x264 are build
inputs only); `auto=no` keeps a prototype out of the default set.

To add one: write `runtime/src/foo.build` (copy `opus.build`), add
`src_pkg foo foo` to the manifest in `runtime/generate.sh`, run `make -C distro
recipes`. Its DT_NEEDED is resolved like every other package's (below).

**From the build host** (`host_pkg <name> "<arch packages>" <keep> <drop>`): the
file list is `pacman -Ql` minus development and systemd files, filtered by two
regexes; version, licence and URL come from `pacman -Qi`.

**The closure.** Every ELF file's DT_NEEDED (with its RUNPATH) is resolved
against what the packages install — these and every other recipe in
`distro/recipes`. A library nobody installs is taken from the host package
that owns it, as a package of that name holding only the libraries asked for
(`glib2`, `systemd-libs`, `readline`…; named `<x>-libs` if a hand-written
recipe already has the name). A library another recipe ships is depended on,
not copied: e2fsprogs ships libblkid, so `util-linux-libs` depends on
`e2fsprogs` (see requests). Packages the manifest stops producing have their
recipe removed. The output is committed, so the recipes show exactly what each
package holds.

Reproducibility: the source builds are as reproducible as the host compiler
(gcc/binutils from Arch) — the inputs are pinned, the toolchain is not. The
host-copied packages are as reproducible as the host's package set, as
glibc's already were.

### glibc from source (prototype)

`runtime/src/glibc.build` builds glibc 2.44 from the GNU tarball (signature
verified) into `distro/build/src/stage/glibc` in about 8 minutes at `-j8`. It
is not packaged: the glibc recipe is the integrator's. Checked:

- `ld-linux-x86-64.so.2 --list distro/out/bin/calc` resolves libc and libm to
  the built ones; the loader reports "stable release version 2.44".
- In an unprivileged chroot whose only C library is the built one
  (busybox, palm, palm-login), `palm-login --selftest`: 64 checks, 0 failed;
  `palm --selftest`: 493 assertions, 20 failures — **the same 20** with the
  host's libc.so.6/libm.so.6/loader in the same chroot (they need tools the
  chroot lacks), so no difference attributable to the build.

To switch: in the glibc block of `generate.sh`, take the three files from
`${PALMFRAME_OUT}/src/glibc/usr/lib/` instead of `/usr/lib`, drop
`package=no` from `glibc.build` and `auto=no` so `make` builds it, and boot the
image. Not done here: booting an image on it, and the version skew rule (the
Odin binaries link the host's glibc, so the shipped one must be at least as
new — pin it to the host's major.minor, or build the Odin binaries against
the built sysroot).

## Services and the session

palm-init service files shipped by the packages (in `/etc/palm/services`):

| file | package | what |
| --- | --- | --- |
| `dbus` | dbus | `/usr/lib/palmframe/dbus-system`: makes `/run/dbus` and `/etc/machine-id`, execs `dbus-daemon --nofork`. Built to run as user `dbus`; until `/etc/passwd` has one, the wrapper runs it as `nobody` from a copy of `system.conf`. |
| `iwd` | iwd | `/usr/lib/iwd/iwd`, `after = dbus`. Exits at once on a kernel without the crypto API (below). |
| `bluetooth` | bluez | `bluetoothd --nodetach`, `after = dbus`. Exits without `CONFIG_BT`; palm-init retries every 30 s. |
| `sound-cards` | pipewire | the one-shot above. |

`after = dbus` is satisfied when dbus-daemon is *running*, not when its socket
exists, so the first bluetoothd sometimes loses the race and is restarted a
second later. Harmless; a readiness notion in palm-init would fix it.

**The user session.** PipeWire must run as the user, with the session's
`XDG_RUNTIME_DIR`. palm-login execs `wm --drm` directly, and the wm's
autostart is the user's own config (empty by design), so there is no hook
today. The package ships `/etc/palm/session.d/50-pipewire` (exits if
`$XDG_RUNTIME_DIR/pipewire-0` exists, else execs `pipewire`). **Request to
palm-login:** before exec'ing the session command, run every executable in
`/etc/palm/session.d/` (sorted) in the background, as the user, with the
session environment, in the session's process group, and kill them when the
session ends. In the tests it was started by hand the same way.

## Verification

All in QEMU (OVMF, the image's limine) with `-device intel-hda -device
hda-duplex` and QEMU's `wav` audio backend, so sound is checked on the host.

```
make -C distro image
python3 -I distro/recipes/runtime/test-runtime.py                    # stock kernel
python3 -I distro/recipes/runtime/test-runtime.py \
    --kernel distro/build/kernel-runtime/bzImage --ollama           # + kernel.config
```

With the stock kernel: 4 failures, all iwd (missing crypto) and one openssl
check string fixed since. With the kernel built from `palmframe.config` +
`runtime/kernel.config` (`--kernel`): **all passed**:

- dbus-daemon (as nobody), iwd and bluetoothd run as palm-init services;
  `net.connman.iwd` and `org.bluez` are on the system bus; `bluetoothctl show`
  says "No default controller available" (no controller in QEMU).
- Wi-Fi end to end over `mac80211_hwsim`: iwd puts wlan1 in AP mode
  (`PalmframeTest`, WPA2), iwd on wlan0 scans, sees it, connects with
  `iwctl --passphrase`, and gets 192.168.5.34/28 from iwd's DHCP server.
- `rfkill list` shows both radios.
- ffmpeg encodes H.264 (libx264) + AAC and Opus; ffprobe reads them back.
- bsdtar creates and lists tar.zst and zip.
- `openssl s_client -verify_return_error` completes a TLS 1.3 handshake with
  example.com using the shipped bundle.
- `palm add` of 13 application packages over http from the build host.
- As palm in the session: pipewire starts wireplumber and pipewire-pulse;
  `wpctl status` lists "HDA Intel Analog Stereo" sink and source; `pactl info`
  says "PulseAudio (on PipeWire 1.6.8)"; `pw-play` produces samples QEMU
  writes to the host WAV (peak 2540), and so does pressing Space in the
  audio app (peak 1258).
- `echo … | wl-copy; wl-paste` round-trips through the wm.
- ollama: `ollama pull qwen3:0.6b` over the guest's network, `ollama run`
  answers.
- Per-application `--selftest` results and screenshots
  (`distro/out/shots/runtime-*.png`) are summarised in `apps.tsv`.

Not verified: real hardware of any kind; Bluetooth pairing (no controller);
iwd against a real access point or EAP; USB sound; PipeWire started by
palm-login (the hook does not exist yet); the live ISO with these packages
(it builds — see size — but was not booted); the vault GUI and the
mailcore/ocr selftests that ended up writing under `/root` in the harness
(the same shell reported `HOME=/home/palm`; not chased further).

## Size

| | before | after |
| --- | --- | --- |
| packages in the repository | 50 | 111 |
| installed by `palmframe` + `palmframe-demo` | 36 | 85 |
| root filesystem (apparent) | 62 MB | 136 MB |
| `palmframe.img` on disk (1.2 → 1.3 GB sparse) | 89 MB | 165 MB |
| + the 13 application packages | | 150 MB root |
| palmframe + palmframe-runtime + `ai` (ollama) | | 207 MB root |
| `palmframe-live.iso` (carries the whole repository, ollama included) | 108 MB | 200 MB |

`make -C distro test` (`image/test-boot.py`) still passes on the new image
(greeter, login, term, launcher, `palm verify` clean, `palm add shop`,
poweroff). The live ISO builds (90 packages in its root) but was not booted.

ffmpeg is 33 MB of the 74 MB added (libavcodec alone 21 MB); trimming it to
named decoders/encoders is the obvious next cut.

## Versions and licences

Source builds: dbus 1.16.2, iwd 3.12, opus 1.6.1, ffmpeg 9.0.2 (GPL, because
of libx264 0.164.3108), libarchive 3.8.10; build tools nasm 3.02. Everything
else is the Arch host's version on 2026-10-19; each recipe's `pkgver` and
`license` say which (`grep -h '^pkg\|^lic' distro/recipes/*/PALMBUILD`). The
licence strings are pacman's, joined with AND; the shipped licence texts are
those the Arch packages put under `/usr/share/licenses/<package>/`.

## Requests to other areas

- **kernel** (`distro/kernel/palmframe.config`): add `runtime/kernel.config`
  — the crypto API iwd needs (it exits without it), `CONFIG_BT` and its
  drivers, `CONFIG_MAC80211_HWSIM` (or only in a test config),
  `CONFIG_SND_USB_AUDIO`. Real Wi-Fi drivers need a firmware decision.
- **base** (`distro/base/root/etc/passwd`, `group`): add user and group
  `dbus` (uid/gid 81, home `/`, shell `/sbin/nologin`) so the bus does not run
  as nobody; add group `netdev` or accept iwd's policy warning.
- **palm-login**: the `/etc/palm/session.d/` hook above.
- **palm-init**: optionally write the udev database entry for sound cards on
  the uevent it already handles (then `sound-cards` can go), and a readiness
  notion for `after =`.
- **integrator** (`generate.sh` outside the runtime block): the `palmframe`
  meta-package now has `depend = palmframe-runtime` (one line, added here);
  e2fsprogs should depend on `util-linux-libs` instead of shipping
  libblkid/libuuid itself, so glib does not pull mkfs into every install;
  `emoji` should depend on `wl-clipboard`; switching glibc to the source
  build as described above.
- **apps**: `network` needs an iwd backend; `videoedit` has `/home/alex` media
  and output paths and wants libass (`subtitles`); the launcher and the
  application `.desktop` entries for the new packages live in
  `distro/recipes/runtime/desktop/` until `distro/apps/desktop/` takes them;
  `apps/store/icons.odin` does not draw the icons these recipes name
  (bluetooth, wifi, volume-2, mail, archive, phone, clipboard, key-round, bot,
  layers, audio-lines, sliders-horizontal, network, clapperboard, scan-text).
