# Quick start

From a checkout to the Palmy desktop in QEMU, and from there to an install on a disk of its own. Nothing here needs root, and nothing touches a disk on the host: the installer only ever sees QEMU's virtual disks.

:::callout{type=warning title="QEMU only"}
Palmy has never booted on real hardware. The kernel configuration is written for QEMU's virtual devices, and the build has been run on an Arch Linux host, from which it copies glibc and a few libraries. [What is missing](/distro/missing) has the details.
:::

## What the build host needs

- The **Odin** compiler. The toolkit is built and tested with Odin `dev-2026-09`.
- For the kernel (Linux {{kernel}}) and busybox ({{busybox}}), which are downloaded and built the first time: `curl` and what a kernel build needs.
- For the disk image, the tools `distro/image/build.sh` checks for: {{imageTools}}.
- For the live ISO, the tools `distro/live/build.sh` checks for: {{isoTools}}.
- **QEMU** and **OVMF**, edk2's UEFI firmware, to boot either one. `distro/run-qemu.sh` looks for OVMF in `/usr/share/edk2/x64`.

## From source to a desktop

:::steps

### Build and test the toolkit

```sh
make            # every example into ./bin
make test       # the headless test suite
make run-todo   # or run-counter, run-gallery, run-pixels
```

The examples open a window on any Wayland compositor with `xdg-shell`, or on an X server with a TrueColor screen. The toolkit is documented under [palmy](/docs/introduction).

### Build the distribution

```sh
make distro     # the same as make -C distro
```

The first run downloads and builds the kernel and busybox, which takes minutes. Later runs rebuild only what changed: the Odin binaries, the packages, the signed repository and `distro/out/palmy.img`.

### Boot it

```sh
distro/run-qemu.sh
```

A QEMU window opens on UEFI firmware, limine shows its menu, and the system boots to the greeter. Log in as `palm` with the password `palm`. The serial console is logged to `distro/out/serial.log`; with `--serial` it is on your terminal too, where `root` with the password `palm` logs in.

### Use the session

**Super+Enter** opens a terminal, **Super+D** the launcher, **Super+S** Software, and **Super+/** lists every shortcut. **Super+Shift+E** ends the session and returns to the greeter. The full table is on [The window manager](/distro/window-manager).

### Install a package from the build host

```sh
make -C distro serve      # on the host: the repository on :8080
```

Inside the guest the repository is `http://10.0.2.2:8080`, the host as QEMU's user network shows it. Open Software and install `track`, or on the serial console as root run `palm update` and then `palm add track`.

:::

The image is used in place: what you install stays installed. `make -C distro image` starts again from a clean image.

## Install onto a disk of its own

The disk image above is a demonstration system with a shared `palm` account. The live ISO carries the installer and a copy of the whole signed repository, so an install needs no network.

:::steps

### Build the live ISO

```sh
make -C distro iso        # distro/out/palmy-live.iso
```

### Boot it with a blank disk

```sh
distro/run-qemu.sh --iso
```

This attaches a blank 8 GiB `distro/out/target.qcow2` as the virtio disk, and creates it if it is missing.

### Run the installer

Eight steps: language, keyboard, time zone, disk, account, summary, install, done. The keyboard is enough for all of it: Tab and Shift+Tab move focus, Enter is Next and Esc is Back. The erase dialog names the disk and has Cancel focused, so Enter alone never erases.

### Boot what was installed

```sh
distro/run-qemu.sh --disk distro/out/target.qcow2
```

The installed disk boots alone, through the UEFI boot entry the installer wrote, to a greeter in the chosen language.

:::

`palm-install` does the same from the serial console without the graphical front end. [Installing](/distro/installing) describes both, and every file an install writes.

## Run the tests

| Command | What it does |
| --- | --- |
| `make test` | the toolkit's headless test suite |
| `make -C distro test` | boots the image headless and drives it over QMP: greeter, login, desktop, term, launcher, palm, poweroff |
| `make -C distro test-installer` | the installer's self-tests; no disk is touched |
| `make -C distro test-install` | builds the ISO, then a graphical and a command-line install in QEMU, each booted afterwards |
| `make -C distro check-libs` | fails if a shipped binary needs anything but libc, libm and the loader |

Screenshots from the QEMU runs land in `distro/out/shots/`. [Building and running](/distro/build-and-run) lists every target and every `run-qemu.sh` option.
