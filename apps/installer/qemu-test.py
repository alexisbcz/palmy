"""Drive the graphical installer inside QEMU, from the live ISO to an installed disk.

    python3 -I apps/installer/qemu-test.py [--lang-only] [--keep]

It boots distro/out/palmframe-live.iso through distro/run-qemu.sh --iso, the
way distro/live/test-boot.py does (whose machinery it reuses), with a blank
8G scratch qcow2 in distro/build/installer-gui/qemu/ as the target. Then it
works the installer with QMP key events only, as a person at the keyboard
would, taking a screendump at each page:

    language   English, then Français, then العربية (right to left), back to English
    keyboard   picking French makes the wm switch: /etc/palm/keyboard says fr, and
               the physical Q key types "a" in the test field (AZERTY)
    time zone  the default for English, the live clock
    disk       Down picks the first usable disk (vda); Enter asks; Tab, Enter erases
    account    full name typed, the user name follows, password twice
    summary    then Install
    install    progress screendumps until the done page
    done       the log on the serial console says the installation finished;
               Restart ends this machine (-no-reboot)
    target     boots the installed disk alone and waits for the greeter

--lang-only stops after the language and keyboard checks (nothing installed).
Nothing touches the host's display, input or disks: -display none, and the
only disks are the ISO and the scratch image.
"""

import argparse
import importlib.util
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DISTRO = os.path.join(ROOT, "distro")
WORK = os.path.join(DISTRO, "build", "installer-gui", "qemu")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


live = load("live_test_boot", os.path.join(DISTRO, "live", "test-boot.py"))
itb = live.itb


def shot(m, name):
    path = os.path.join(WORK, name + ".png")
    for _ in range(10):
        try:
            m.screen(path)
            return path
        except Exception:
            time.sleep(0.3)
    return path


def keyboard_conf(m):
    out, _ = m.run("cat /etc/palm/keyboard")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang-only", action="store_true", help="stop after the language and keyboard pages")
    ap.add_argument("--keep", action="store_true", help="leave the machine running at the end")
    args = ap.parse_args()

    os.makedirs(WORK, exist_ok=True)
    disk = os.path.join(WORK, "target.qcow2")
    for p in (disk, disk.rsplit(".", 1)[0] + ".OVMF_VARS.fd"):
        if os.path.exists(p):
            os.unlink(p)
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", disk, "8G"], check=True)

    print("installer in QEMU: live ISO, blank 8G target", flush=True)
    m = live.LiveMachine(WORK, disk, False)
    try:
        ok = m.expect(r"root@\S*?:.*?# ", 120) is not None
        m.check("the live system's root shell on ttyS0", ok)
        if not ok:
            return 1
        time.sleep(1)
        m.send("")
        for _ in range(40):
            out, _ = m.run("pidof installer; pidof wm")
            if len(out.split("\n")) >= 2 and all(out.split("\n")[:2]):
                break
            time.sleep(0.5)
        m.check("wm and installer are running", len(out.split()) >= 2, out)
        time.sleep(3)  # first frame, fonts

        # --- language -----------------------------------------------------
        shot(m, "01-language-en")
        m.key("down")
        time.sleep(1)
        shot(m, "02-language-fr")
        for _ in range(3):
            m.key("down")
        time.sleep(1)
        shot(m, "03-language-ar")
        for _ in range(4):
            m.key("up")
        time.sleep(0.5)

        # --- keyboard: French, live ----------------------------------------
        m.key("down")  # Français
        time.sleep(0.8)
        m.key("ret")
        time.sleep(1.5)
        conf = keyboard_conf(m)
        m.check("choosing French wrote layout = fr to /etc/palm/keyboard", "layout = fr" in conf, conf)
        out, _ = m.run("tail -n 5 /var/log/installer.log")
        print("        installer.log: " + out.replace("\n", " | ")[:400])
        # Focus starts in the search field; one Tab reaches the test field
        # (the lists are driven by the arrows, not in the Tab order).
        m.key("tab")
        time.sleep(0.3)
        m.type("q")
        time.sleep(0.8)
        shot(m, "04-keyboard-fr")
        print("        look at 04-keyboard-fr.png: the test field should hold 'a' (AZERTY q)")

        # Back to English: the layout follows back to us.
        m.key("esc")
        time.sleep(0.6)
        m.key("up")
        time.sleep(1.2)
        conf = keyboard_conf(m)
        m.check("going back to English switched the layout back to us", "layout = us" in conf, conf)
        if args.lang_only:
            return 0 if not m.failures else 1

        m.key("ret")  # keyboard
        time.sleep(1)
        shot(m, "05-keyboard-us")
        m.key("ret")  # time zone
        time.sleep(1)
        shot(m, "06-timezone")
        m.key("ret")  # disk
        time.sleep(1)
        m.key("down")
        time.sleep(0.5)
        shot(m, "07-disk")
        m.key("ret")
        time.sleep(0.8)
        shot(m, "08-disk-confirm")
        m.key("ret")  # Enter lands on Cancel, which holds the focus
        time.sleep(0.6)
        shot(m, "08b-disk-cancelled")
        m.key("ret")
        time.sleep(0.6)
        m.key("tab")  # Cancel -> Erase
        time.sleep(0.3)
        m.key("ret")
        time.sleep(1)

        # --- account -------------------------------------------------------
        m.type("Ada Lovelace")
        time.sleep(0.3)
        for _ in range(3):
            m.key("tab")
            time.sleep(0.2)
        m.type("analytical engine")
        m.key("tab")
        time.sleep(0.2)
        m.type("analytical engine")
        time.sleep(0.5)
        shot(m, "09-account")
        m.key("ret")
        time.sleep(1)
        shot(m, "10-summary")

        # --- install -------------------------------------------------------
        m.key("ret")
        t0 = time.time()
        n = 0
        finished = False
        while time.time() - t0 < 600:
            time.sleep(4)
            n += 1
            shot(m, f"11-install-{n:02d}")
            out, _ = m.run("tail -n 2 /var/log/palm-install.log 2>/dev/null")
            print(f"        {time.time() - t0:5.0f} s  {out.strip().splitlines()[-1] if out.strip() else ''}"[:160], flush=True)
            if "installation finished" in out:
                finished = True
                break
            if "error" in out.lower() or "failed" in out.lower():
                break
        time.sleep(2)
        shot(m, "12-done")
        m.check(f"the installation finished ({time.time() - t0:.0f} s)", finished, out)
        out, _ = m.run("tail -n 40 /var/log/palm-install.log")
        with open(os.path.join(WORK, "palm-install.log"), "w") as f:
            f.write(out)
        if not finished:
            return 1

        m.key("ret")  # Restart now (focused)
        for _ in range(60):
            if m.proc.poll() is not None:
                break
            time.sleep(0.5)
        m.check("Restart ended the live machine", m.proc.poll() is not None)
    finally:
        if not args.keep:
            m.close()

    # --- the installed disk ---------------------------------------------------
    print("booting the installed disk", flush=True)
    t = TargetMachine(WORK, disk)
    try:
        ok = t.expect(r"palm-init: Palmframe is starting", 120) is not None
        t.check("the installed system starts palm-init", ok, t.buf[-1500:])
        ok = t.expect(r"palm-login", 60) is not None
        time.sleep(8)
        shot(t, "13-installed-greeter")
        t.check("palm-login started on the installed system (see 13-installed-greeter.png)", ok, t.buf[-1500:])
    finally:
        t.close()
    return 0 if not (m.failures or t.failures) else 1


class TargetMachine(itb.Machine):
    """The target disk alone, through run-qemu.sh --disk (its own OVMF vars)."""

    def __init__(self, work, disk):
        self.work = work
        self.serial_path = os.path.join(work, "serial2.sock")
        self.qmp_path = os.path.join(work, "qmp2.sock")
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = [os.path.join(DISTRO, "run-qemu.sh"), "--disk", disk,
               "--serial-socket", self.serial_path, "--qmp-socket", self.qmp_path, "--", "-no-reboot"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(work, "qemu2.log"), "w"))
        self.serial = self._connect(self.serial_path)
        self.serial.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.transcript = open(os.path.join(work, "serial2.txt"), "w")
        self.failures = []


if __name__ == "__main__":
    sys.exit(main())
