# The kernel, its modules and firmware — notes for the other pieces

Owner of `distro/kernel/`, `distro/recipes/linux/`, the firmware recipes
(`distro/recipes/linux-firmware*/`, `sof-firmware/`, `wireless-regdb/`) and
this file.

## What the kernel is now

Linux 6.18.56, built by `distro/kernel/build.sh` in three layers:

1. `x86_64_defconfig` + `kvm_guest.config`, as before.
2. `distro/kernel/modular.list`: driver families (Ethernet, Wi-Fi,
   Bluetooth, HID, sound, laptop platform drivers, Thunderbolt, USB-C) of
   which every tristate option becomes `=m`. Naming directories rather than
   drivers is what keeps a new laptop's Wi-Fi chip from being forgotten.
3. `distro/kernel/palmframe.config`, which wins over both. build.sh fails if
   any of its lines does not survive `olddefconfig`, so a dropped dependency
   is a build error, not a machine without a disk.

The rule for `=y` and `=m`: everything needed to reach the root filesystem
and a picture is built in, so there is still no initramfs. That is NVMe
(and Intel VMD, which hides NVMe on many Intel laptops), AHCI, USB storage
and UAS, SD/MMC, virtio, ext4, vfat, simpledrm on the firmware's
framebuffer, and a USB or PS/2 keyboard. Everything that needs firmware from
`/usr/lib/firmware`, or exists only on some machines, is a module: amdgpu,
radeon, i915, xe, nouveau, iwlwifi, ath9k–12k, mt76, rtw88/89, brcmfmac,
e1000e, igc, r8169, HDA and Sound Open Firmware, i2c-hid and multitouch,
thinkpad_acpi and the other vendor drivers, dm-crypt, zram, exfat, ntfs3.
Namespaces, cgroups v2, seccomp, BPF and Landlock are built in for
sandboxing later.

The built-in command line is `rootwait=30` (`CONFIG_CMDLINE`), prepended to
whatever limine passes, because an NVMe or USB root can appear after the
kernel first looks for it. `root=PARTUUID=...` works without an initramfs.

Modules are installed stripped and zstd-compressed (`CONFIG_MODULE_COMPRESS_
ZSTD`), and the kernel decompresses them itself (`CONFIG_MODULE_DECOMPRESS`).
Firmware is read by the kernel straight from `/usr/lib/firmware`, `.zst`
files included (`CONFIG_FW_LOADER_COMPRESS_ZSTD`); no user helper.

## palm-modules

`distro/kernel/palm-modules/` (Odin, static, shipped in the linux package as
`/usr/bin/palm-modules`) is the module loader: kmod and the module half of
udev in one small program. It reads depmod's text indexes
(`modules.dep`, `modules.alias`, `modules.softdep`, `modules.builtin`) and
`/etc/modprobe.d/*.conf` (`blacklist`, `options`), and loads with
`finit_module(2)`.

```
palm-modules coldplug        a module for every device in /sys with a modalias,
                             walking again until nothing new appears
palm-modules watch           the same, then for every device added later
palm-modules load NAME...    modprobe: by name or alias, dependencies first
palm-modules -q -- NAME      the kernel's own request_module (CONFIG_MODPROBE_PATH)
palm-modules lookup NAME...  what a name or modalias resolves to
palm-modules --selftest
```

`--dir DIR` and `--dry-run` let it be tried on any machine:
`palm-modules coldplug --dry-run --dir /usr/lib/modules/$(uname -r)` on the
Arch build host walked 100 modaliases in 0.2 s and named exactly the 4
modules the host's udev had found nothing to do with (they refuse the
hardware), so its matching agrees with kmod's.

busybox's `modprobe`, `insmod` and `depmod` applets cannot load `.ko.zst`
(busybox is built with `MODPROBE_SMALL`, which reads modules into memory
itself). `lsmod` and `rmmod` work.

## For palm-init: one call before services (request)

Drivers must be loaded before anything uses a device: `add_builtin_network`
looks for `eth0` once, and the window manager opens `/dev/dri/card0`, which
is simpledrm until a native driver such as i915 takes the card over and
removes it. So palm-init should run the coldplug itself, synchronously,
before its own device-permission coldplug and before services. In
`distro/init/main.odin`, `boot()`:

```odin
	devices_init(sup.groups)
	hotplug_open()
	run_and_wait({"/usr/bin/palm-modules", "coldplug"}, 30_000)   // new
	coldplug()
```

where `run_and_wait` forks, `execve`s the argv with the service
environment's PATH, and `wait4`s for at most the timeout (WNOHANG polling,
then SIGKILL), doing nothing if the binary is missing. A driver that hangs
in probe must not hang boot. It prints one line
(`palm-modules: N device(s) with a modalias, M module(s) loaded`).

Until that lands, the linux package's service `/etc/palm/services/modules`
(`palm-modules watch`) loads the same modules, but concurrently with the
other services: in QEMU nothing notices (virtio is built in), on a real
machine the network one-shot misses a modular NIC and the greeter can start
on simpledrm just before i915 removes it. The service stays useful after
the hook: it catches devices added later.

## The kernel limine boots, and upgrades

The linux package installs the kernel twice:

| path | what |
| --- | --- |
| `/boot/vmlinuz` | the root's copy; the live ISO build and the installer read it |
| `/boot/efi/vmlinuz` | the one limine boots: on the ESP, mounted at `/boot/efi`, it is `/vmlinuz` |
| `/usr/lib/modules/<release>/` | modules and depmod's indexes |
| `/boot/config` | the .config |

palm has no hooks, so the second file is the whole mechanism: with the ESP
mounted, `palm upgrade linux` writes the new kernel onto it (palm writes a
temp file beside the destination and renames it, which vfat does). The
canonical ESP layout is therefore **`vmlinuz` at the root of the ESP, and
limine.conf's `path: boot():/vmlinuz`** — what the installer already writes.

What the other areas must match:

- **Image (`distro/image/build.sh`)**: limine.conf `path: boot():/vmlinuz`
  (today `boot():/boot/vmlinuz`), copy `$ROOTFS/boot/efi/vmlinuz` (or
  everything under `$ROOTFS/boot/efi/`) to the ESP root instead of
  `$ROOTFS/boot/vmlinuz` to `::/boot/vmlinuz`, and remove `$ROOTFS/boot/efi/*`
  before `mkfs.ext4 -d` so the root does not carry a shadowed third copy.
  Add the fstab line the installer writes
  (`PARTUUID=<esp> /boot/efi vfat rw,relatime,fmask=0077,dmask=0077 0 2`, or
  `LABEL=PALMESP`).
- **Installer (`distro/installer/core`)**: mount the ESP at
  `<target>/boot/efi` before `palm add`, so palm records and writes the file
  that limine boots; the copy step in `boot.odin` then becomes a no-op (keep
  it as a fallback). Keep `path: boot():/vmlinuz`.
- **Init**: `mount -a` (the ESP), done by its agent. Without the mount, an
  upgrade writes `/boot/efi/vmlinuz` onto the root, where limine never looks.
- **Live (`distro/live/build.sh`)**: prune `./boot/efi` as well as
  `./boot/vmlinuz` from the initramfs, and keep `/usr/lib/modules`: the live
  system needs its modules on real hardware. `test-boot.py` already filters
  `/boot/vmlinuz: missing` from `palm verify`; it needs the same for
  `/boot/efi/vmlinuz`.

On a vfat ESP mounted `fmask=0077` palm's chmod to 0644 is refused silently
and the file stays 0700... (see *What was verified*).

## Firmware

`distro/recipes/linux-firmware/generate.sh` writes one recipe per Arch
firmware package on the build host, keeping Arch's split, because all of it
is 440 MB packed and a machine needs a fraction:

| package | .palm |
| --- | --- |
| linux-firmware-intel | 139 MB |
| linux-firmware-nvidia | 109 MB |
| linux-firmware-atheros | 54 MB |
| linux-firmware-mediatek | 39 MB |
| linux-firmware-other | 31 MB |
| linux-firmware-amdgpu | 28 MB |
| linux-firmware-broadcom | 14 MB |
| sof-firmware | 13 MB |
| linux-firmware-realtek | 8 MB |
| linux-firmware-cirrus | 3 MB |
| linux-firmware-radeon | 2.4 MB |
| linux-firmware-whence | 54 KB (WHENCE; every part depends on it) |
| wireless-regdb | 5 KB (`regulatory.db`, read by cfg80211) |
| linux-firmware | the meta-package: all of the above |

The files are Arch's `.zst` ones; the kernel decompresses them. Building all
of them takes about 20 s. `generate.sh` (shared) should call this script
next to the other host-copied packages, one line near the tzdata section:

```bash
"$HERE/linux-firmware/generate.sh"
```

Its outputs are committed, so until then they are simply as current as the
host was when they were written.

**Nothing depends on the firmware yet.** `palmframe` does not, so the QEMU
image is unchanged. For a real machine it should be installed, and that is
a decision for the image, installer and live areas, written down here:
the live ISO embeds the whole repository in an initramfs held in RAM, so
adding 440 MB of firmware there (twice: installed and as packages) is not
reasonable. The suggestion: the installer installs `linux-firmware` onto the
target when the repository has it; the live medium installs (and carries in
its repository) only `linux-firmware-intel`, `-amdgpu`, `-realtek` and
`-mediatek` and `wireless-regdb` (the common laptop GPUs, Wi-Fi and
Ethernet), about 215 MB; the full set comes from the network repository.

## What was verified

(filled in below)

## Gaps

- **Early microcode** needs either an initramfs or limine `module_path`
  with an early-cpio of `amd-ucode`/`intel-ucode`; neither is done. The
  kernel has `CONFIG_MICROCODE=y`, so microcode from the firmware is used.
- **An encrypted root** needs an initramfs to unlock it. dm-crypt is a
  module and the kernel has the AF_ALG interfaces cryptsetup uses; there is
  no cryptsetup and no initramfs.
- **Old modules are removed on upgrade.** `palm upgrade linux` to a new
  release deletes the running kernel's `/usr/lib/modules/<old>`; until the
  restart nothing more can be loaded (the same as on Arch).
- **No signature on modules.** `CONFIG_MODULE_SIG` is off.
- **Never booted on real hardware**; everything below was QEMU.
