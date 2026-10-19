"""Boot distro/out/palmframe-live.iso headless and check the live system.

    python3 -I distro/live/test-boot.py [--bios] [--serial-only] [--expect installer|term]

QEMU is started through distro/run-qemu.sh --iso, so the machine is the one a
person gets: OVMF (or SeaBIOS with --bios), limine from the ISO's El Torito
image, the kernel and the zstd initramfs, palm-init as /init. The target disk
is a blank 8G qcow2 in distro/build/live/ (never distro/out/target.qcow2, which
may hold someone's install), attached on virtio as run-qemu.sh does.

    limine's menu with both entries                    -> shots/<run>-limine.png
    the root shell autologs in on the serial console
    / is the initramfs (tmpfs), not a disk
    palm-login and getty-ttyS0 are masked; palm verify finds only the left-out kernel
    the repository is at /usr/share/palm/repo and palm reads it offline
    mkfs.ext4, mkfs.fat, tzdata, catalogues, the CJK font are present
    the target disk is /dev/vda, the CD /dev/sr0
    wm --drm --kiosk runs the expected client          -> shots/<run>-session.png
    poweroff ends the machine

--serial-only picks limine's second entry (palm.live.serial): no graphical
session, the serial shell only. Shots go to distro/build/live/shots/.

Nothing here touches the host's display, input or disks: QEMU runs with
-display none and the only disks are the ISO and a scratch image file.
"""

import argparse
import importlib.util
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(HERE)
WORK = os.path.join(DISTRO, "build", "live")
SHOTS = os.path.join(WORK, "shots")

# The serial/QMP machinery is distro/image/test-boot.py's; only the QEMU
# command line differs.
_spec = importlib.util.spec_from_file_location("image_test_boot", os.path.join(DISTRO, "image", "test-boot.py"))
itb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(itb)


class LiveMachine(itb.Machine):
    def __init__(self, work, disk, bios):
        self.work = work
        self.serial_path = os.path.join(work, "serial.sock")
        self.qmp_path = os.path.join(work, "qmp.sock")
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = [os.path.join(DISTRO, "run-qemu.sh"), "--iso", "--disk", disk,
               "--serial-socket", self.serial_path, "--qmp-socket", self.qmp_path]
        if bios:
            cmd.append("--bios")
        cmd += ["--", "-no-reboot"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(work, "qemu.log"), "w"))
        self.serial = self._connect(self.serial_path)
        self.serial.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.transcript = open(os.path.join(work, "serial.txt"), "w")
        self.failures = []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bios", action="store_true", help="SeaBIOS instead of OVMF")
    ap.add_argument("--serial-only", action="store_true", help="limine's second entry")
    ap.add_argument("--expect", default="installer", help="the kiosk client to expect (installer, or term)")
    ap.add_argument("--keep", action="store_true", help="leave the machine running at the end (for poking)")
    args = ap.parse_args()

    run = ("bios" if args.bios else "uefi") + ("-serial" if args.serial_only else "")
    os.makedirs(SHOTS, exist_ok=True)
    disk = os.path.join(WORK, "target-test.qcow2")
    if os.path.exists(disk):
        os.unlink(disk)
    for v in (disk.rsplit(".", 1)[0] + ".OVMF_VARS.fd",):
        if os.path.exists(v):
            os.unlink(v)
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", disk, "8G"], check=True)

    print(f"live boot test ({run}), expecting {'no session' if args.serial_only else args.expect}", flush=True)
    m = LiveMachine(WORK, disk, args.bios)
    t0 = time.time()
    try:
        # limine draws its menu on the framebuffer and prints nothing on the
        # serial port. OVMF says on serial when it starts the CD's loader;
        # SeaBIOS does not, so there the wait is by time. The menu waits
        # 5 s, long enough to take the shot and, for --serial-only, choose
        # the second entry.
        if args.bios:
            time.sleep(3.0)
        else:
            m.expect(r"BdsDxe: starting", 30)
            time.sleep(1.5)
        menu = False
        for _ in range(20):
            try:
                w, h, rgb = m.screen(os.path.join(SHOTS, f"{run}-limine.png"))
            except Exception:
                time.sleep(0.25)
                continue
            if itb.colours(w, h, rgb) > 3:
                menu = True
                break
            time.sleep(0.25)
        m.check("limine's menu is on screen", menu)
        if args.serial_only:
            m.key("down")
            m.key("ret")

        ok = m.expect(r"palm-init: Palmframe is starting", 90) is not None
        m.check("the kernel starts palm-init from the initramfs", ok)
        ok = m.expect(r"root@\S*?:.*?# ", 90) is not None
        m.check(f"root shell on ttyS0 without a password ({time.time() - t0:.1f} s)", ok, m.buf[-2000:])
        if not ok:
            return 1
        time.sleep(1)
        m.send("")

        out, _ = m.run("id -u; cat /proc/cmdline; awk '$2==\"/\"{print $3}' /proc/mounts")
        m.check("uid 0, / is the initramfs (rootfs/tmpfs)", out.split("\n")[0] == "0" and re.search(r"^(rootfs|tmpfs)$", out, re.M) is not None, out)
        if args.serial_only:
            m.check("palm.live.serial on the command line", "palm.live.serial" in out, out)

        # /boot/vmlinuz is left out of the initramfs on purpose (build.sh: the
        # kernel is on the ISO beside it), so verify reports exactly that.
        out, _ = m.run("ls /etc/palm/services.off; ps -o args | grep -c '[p]alm-login'; "
                       "palm verify | grep -v -e 'modified (config)' -e 'problem(s) found' -e '^linux: /boot/vmlinuz: missing$' -e '^linux: /boot/efi/vmlinuz: missing$' -e '^linux: /boot/efi: missing$'; echo verify-other=$?")
        m.check("palm-login and getty-ttyS0 masked (palm-login not running); palm verify finds only the left-out kernel",
                "palm-login" in out and "getty-ttyS0" in out and re.search(r"^0$", out, re.M) is not None
                and "verify-other=1" in out, out)

        out, rc = m.run("ls /usr/share/palm/repo | wc -l; palm --repo /usr/share/palm/repo --no-cache search tzdata")
        m.check("the repository is on the medium and palm verifies it offline", rc == 0 and "tzdata" in out, out)

        out, rc = m.run("mkfs.ext4 -V 2>&1 | head -1; mkfs.fat --help 2>&1 | head -1; ls /usr/share/limine")
        m.check("mkfs.ext4, mkfs.fat and limine's files are installed", "mke2fs" in out and "mkfs.fat" in out and "BOOTX64.EFI" in out, out)

        out, rc = m.run("head -3 /usr/share/zoneinfo/zone1970.tab | tail -1; ls /usr/share/zoneinfo/Europe/Paris; "
                        "ls /usr/share/zoneinfo/right /usr/share/zoneinfo/posix 2>&1 | head -2")
        m.check("tzdata (without right/ and posix/)", "Europe/Paris" in out and "No such file" in out, out)

        # The live root has a Japanese subset of the CJK font (build.sh); the
        # whole font is a package in the medium's repository, for installs.
        out, rc = m.run("ls /usr/share/palm/locale; ls /usr/share/fonts/palm-live; ls /usr/share/palm/repo | grep fonts-cjk")
        m.check("catalogues, the CJK subset, and fonts-cjk in the repository",
                "ja" in out and "NotoSansCJKjp-Regular.otf" in out and "fonts-cjk-" in out, out)
        # Firmware: the parts build.sh's LIVE_FIRMWARE names are installed, so
        # the live kernel finds them, and carried for an offline install.
        out, rc = m.run("ls /usr/lib/firmware | head -400 | wc -l; ls /usr/lib/firmware/regulatory.db*; "
                        "palm list --installed | grep -c -E '^(linux-firmware|wireless-regdb)'; "
                        "ls /usr/share/palm/repo | grep -c -E '^(linux-firmware|wireless-regdb)'")
        print("  ....  firmware: " + out.strip().replace("\n", " | "))
        m.check("firmware installed in the live root and carried in its repository",
                "regulatory.db" in out and re.search(r"\|\s*([1-9]\d*)\s*\|\s*([1-9]\d*)\s*$", out.strip().replace("\n", " | ")) is not None, out)

        out, rc = m.run("cd /sys/block && echo *; cat /sys/block/vda/size; cd")
        m.check("the blank target is /dev/vda (8 GiB), the CD /dev/sr0",
                re.search(r"\bvda\b", out) is not None and "sr0" in out and "16777216" in out, out)

        out, rc = m.run("free -m | head -2")
        print("        " + out.strip().replace("\n", "\n        "), flush=True)

        if not args.serial_only:
            want = args.expect
            got = ""
            for _ in range(40):
                got, _ = m.run("ps -o user,args | grep -v grep | grep -E 'wm --drm|installer|term'")
                if "wm --drm --kiosk --exec" in got and re.search(r"(^|\s|/)" + re.escape(want) + r"(\s|$)", got.split("wm --drm")[-1] + "\n" + got, re.M):
                    break
                time.sleep(0.5)
            m.check(f"wm --drm --kiosk runs {want} as root", "wm --drm --kiosk --exec" in got and want in got, got)
            time.sleep(4)
            w, h, rgb = m.screen(os.path.join(SHOTS, f"{run}-session.png"))
            m.check(f"the session draws ({w}x{h}, {itb.colours(w, h, rgb)} colours)", itb.colours(w, h, rgb) > 8)
            out, _ = m.run("tail -n 15 /var/log/installer.log")
            print("        installer.log:\n        " + out.strip().replace("\n", "\n        "), flush=True)
        else:
            out, _ = m.run("ps -o args | grep -c '[w]m --drm'")
            m.check("no graphical session", out.strip() == "0", out)

        if args.keep:
            print(f"machine left running: serial {m.serial_path}, qmp {m.qmp_path}")
            m.proc.wait()
            return 0
        m.send("poweroff")
        try:
            m.proc.wait(timeout=30)
            m.check("poweroff ends the machine", True)
        except subprocess.TimeoutExpired:
            m.check("poweroff ends the machine", False)
    finally:
        m.close()

    print(f"{'all passed' if not m.failures else str(len(m.failures)) + ' failed'} ({run}); shots in {SHOTS}")
    return 1 if m.failures else 0


if __name__ == "__main__":
    sys.exit(main())
