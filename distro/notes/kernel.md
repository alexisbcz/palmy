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

## When modules are loaded

- **At boot**, through palm-init's early hooks (`distro/notes/init.md`): the
  linux package installs `/usr/lib/palm-init/early.d/10-modules`, a two-line
  script that runs `palm-modules coldplug`. palm-init runs it after `/` is
  writable and before the device-permission walk, the rest of fstab, swap,
  the network and every service, so `eth0` exists when the DHCP one-shot
  looks for it and a native GPU driver has replaced simpledrm before the
  greeter opens `/dev/dri/card0`. It is silent unless a module fails
  (`--verbose` prints `N device(s) with a modalias, M module(s) loaded`). In
  the QEMU runs it took the e1000e card from nothing to a DHCP lease before
  services started.
- **When a device appears later**, two things react today. palm-init runs
  `modprobe -b -q <MODALIAS>` for every `add` uevent, and the linux
  package's service `/etc/palm/services/modules` (`palm-modules watch`)
  does the same itself. The service is what works: the `modprobe` palm-init
  finds in PATH is busybox's, which fails (next section). A PCIe card
  hot-added in QEMU (igb) got its driver from the service within a second.
- **When the kernel asks** (`request_module`: a filesystem type at mount, a
  network protocol, a crypto algorithm), it runs `/usr/bin/palm-modules -q
  -- <alias>` (`CONFIG_MODPROBE_PATH`). Verified with `mount -t exfat`.

## busybox's modprobe (request to the busybox recipe)

busybox is built with `MODPROBE_SMALL`, whose `modprobe`, `insmod`,
`depmod` and `modinfo` read module files themselves and cannot read
`.ko.zst`. In the QEMU run, `modprobe -b -q fs-udf` (what palm-init runs on
hotplug) exited 1 with `module 'fs_udf' not found`, after scanning every
module and writing `/usr/lib/modules/<release>/modules.dep.bb` into the
linux package's directory. On a real machine palm-init runs it for every
device a hotplug adds, each time rescanning 35 MB.

Fixed after the merge, as proposed here:

- `distro/recipes/generate.sh`: `BB_SKIP=" init linuxrc chat modprobe insmod
  depmod modinfo "` (busybox's `lsmod` and `rmmod` are fine and stay);
- `distro/recipes/linux/PALMBUILD`: `symlink = /usr/bin/modprobe ->
  palm-modules` (palm-modules accepts `-a -b -q --` and behaves as modprobe).
  The `modules` service is dropped, since palm-init's hotplug covers it.

The symlink cannot be added before the first change: palm refuses two
packages owning `/usr/bin/modprobe`, and the image would not build.

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
temp file beside the destination and renames it, which vfat allows). The
canonical ESP layout is therefore **`vmlinuz` at the root of the ESP, and
limine.conf's `path: boot():/vmlinuz`**, which is what the installer
already writes.

What the other areas must match:

- **Image (`distro/image/build.sh`)**: its limine.conf still says
  `path: boot():/boot/vmlinuz` and copies `$ROOTFS/boot/vmlinuz` to
  `::/boot/vmlinuz`. It must say `path: boot():/vmlinuz` (three entries) and
  copy `$ROOTFS/boot/efi/vmlinuz` to `::/vmlinuz`; the exact four-line
  change is `distro/notes/kernel-image.patch`. Until then the image
  boots the copy made at build time, an upgrade writes a file limine does
  not read, and `palm verify` reports `/boot/efi/vmlinuz` missing (the
  mounted ESP hides the root's copy). It should also leave `$ROOTFS/boot/efi/`
  empty before `mkfs.ext4 -d`, so the root does not carry a hidden copy.
- **Installer (`distro/installer/core`)**: mount the ESP at
  `<target>/boot/efi` before `palm add`, so palm writes and records the file
  limine boots. The copy in `boot.odin` then copies a file onto itself and
  can stay as a fallback. Keep `path: boot():/vmlinuz`.
- **Live (`distro/live/build.sh`)**: prune `./boot/efi` as well as
  `./boot/vmlinuz` from the initramfs, and keep `/usr/lib/modules`, which the
  live system needs on real hardware. `test-boot.py` filters
  `/boot/vmlinuz: missing` from `palm verify`; it needs the same for
  `/boot/efi/vmlinuz`.


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

Sizes: `bzImage` 13.5 MB (it was 14.6 MB with i915 built in), 996 modules
in 35 MB (zstd) under `/usr/lib/modules/6.18.56-palmframe`, the linux
package 59 MB. A full kernel and modules build took about 35 minutes at
`JOBS=8` on a shared 16-core host; a config change rebuilds incrementally.

`python3 -I distro/kernel/test-hardware.py` (both scenarios, all passed):

- **nvme**: the image's root on an emulated NVMe disk, booted with
  `root=/dev/nvme0n1p2` and no initramfs, on PC devices instead of virtio:
  e1000e, Intel HD Audio with an `hda-duplex` codec, xHCI with a USB
  keyboard and tablet, an AHCI disk. The early hook loaded e1000e,
  snd_hda_intel, its codec and i2c_i801 before services, so the DHCP
  one-shot found `eth0` and got 10.0.2.15. Each driver was bound to its PCI
  device (`/sys/bus/pci/drivers/<driver>/`), `/proc/asound/cards` listed the
  HDA card and `/dev/snd/pcmC0D0p` was `root:audio 0660`, the USB devices
  were input devices, the AHCI disk was `sda`. `mount -t exfat` loaded exfat
  through `CONFIG_MODPROBE_PATH`, `palm-modules load dm-crypt` loaded dm_mod
  first, zram (now built in) was palm-init's swap, and an igb card added over
  QMP `device_add` (PCIe hotplug, `CONFIG_HOTPLUG_PCI_PCIE`) got its driver
  from the modules service. 18 modules were loaded in the end.
- **esp**: OVMF, limine, the root on virtio, the ESP mounted at `/boot/efi`
  by the image's fstab. With limine.conf pointed at `boot():/vmlinuz`,
  `palm upgrade linux` from a signed repository on a second disk installed a
  package carrying a different kernel (the main checkout's older one, which
  has no modules); `/boot/efi/vmlinuz` then had its sha256, `palm verify
  linux` was clean, and after `reboot` limine booted it
  (`/proc/config.gz`: `CONFIG_MODULES is not set`), and `palm verify linux`
  was still clean with the ESP remounted. Also the firmware loader: with no
  `regulatory.db`, loading cfg80211 logs `failed to load regulatory.db`;
  with only `regulatory.db.zst` and its `.p7s.zst` in `/usr/lib/firmware`
  it does not, so compressed firmware is read.
- `distro/image/test-boot.py` (greeter, login, desktop, term, launcher,
  palm update/add, poweroff) passes on the new kernel once the image's
  limine.conf and ESP copy use `/vmlinuz` (`kernel-image.patch`, applied locally
  and reverted). Without that patch its only failures are `palm verify`'s
  `linux: /boot/efi/vmlinuz: missing`.
- `palm-modules --selftest` (glob, names, aliases, modprobe.d, softdep), and
  the dry-run coldplug on the build host described above.

The ESP file is declared mode 0700: vfat stores no modes, so with the
`fmask=0077` both fstabs use every file reads back as 0700 after a remount,
and a recipe saying 0644 made `palm verify` fail. An ESP mounted with
another fmask makes verify report the mode, nothing worse. FAT cannot store
the 1970 timestamp palm gives files (`SOURCE_DATE_EPOCH=0`); `ls` shows
2098, which is cosmetic.

Not verified: any real hardware; a native GPU driver taking over from
simpledrm (QEMU has no amdgpu/i915 device); Wi-Fi; SOF audio; firmware for
any device other than cfg80211's database; the live ISO with modules.

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
- **One kernel on the ESP.** An upgrade replaces `/vmlinuz` in place; there
  is no fallback entry with the previous kernel if the new one does not boot.
