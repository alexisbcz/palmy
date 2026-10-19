"""The whole installer, end to end, inside QEMU: live ISO -> installed disks -> boot.

    python3 -I distro/live/test-install.py [--only gui|cli] [--keep]
    (make -C distro test-install builds the ISO first, then runs this)

What a person does, driven over QMP the way a person at the keyboard would,
with a screendump at every step into distro/out/shots/install-NN-<step>.png:

GUI, on distro/out/palmy-live.iso under OVMF with a blank 8 GiB virtio disk
    language   العربية first (the right-to-left rendering), then Français:
               the UI turns French
    keyboard   French is followed: /etc/palm/keyboard says fr, and the physical
               keys q w e r t y type "azerty" in the test field
    time zone  Europe/Paris (French's default)
    disk       the lone 8 GiB disk, erase confirmed in the dialog
    account    Ada Lovelace / ada / analytical / palmy, typed on AZERTY (the
               physical keys a French layout needs, so the layout is proven
               again by what the summary shows)
    install    progress to the Done page; Restart ends the machine
then the installed disk alone, same OVMF variable store
    OVMF loads the "Palmy" Boot#### entry (its serial line, and BootCurrent
    read back through efivarfs from the serial console), limine boots,
    the greeter is French with Paris time, Ada is listed, ada/palmy logs
    in to the desktop, term types AZERTY, date is CET/CEST, the host name is
    analytical, palm verify is clean, palm list shows the installed set, df
    shows the root filling the disk

CLI, a second live boot with two blank disks, from the serial console
    echo <pw> | palm-install --disk /dev/vdb --language de_DE --keyboard de
        --timezone America/New_York --hostname cli-test --user grace
        --password-file - --yes
    (busybox sh has no <(...), so the password comes on stdin), then vdb booted
    alone: the greeter is German, grace logs in, term types QWERTZ

Nothing touches the host's display, input or disks: -display none, and the
only disks are the ISO and scratch qcow2 files in distro/build/integrate/qemu.
"""

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(HERE)
OUT = os.path.join(DISTRO, "out")
WORK = os.path.join(DISTRO, "build", "integrate", "qemu")
SHOTS = os.path.join(OUT, "shots")
EFI_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
# A unix socket path must fit in 108 bytes, which a checkout in a deep
# directory (a git worktree) does not leave room for under WORK.
SOCKETS = tempfile.mkdtemp(prefix="palm-ti-")

_spec = importlib.util.spec_from_file_location("image_test_boot", os.path.join(DISTRO, "image", "test-boot.py"))
itb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(itb)

FAILURES = []

# The physical key (QMP qcode) that types a character on a French AZERTY or a
# German QWERTZ layout. QMP sends key positions, not characters, so once the
# compositor runs fr or de, typing "ada" means pressing q d q.
FR = {"a": "q", "q": "a", "z": "w", "w": "z", "m": "semicolon"}
DE = {"y": "z", "z": "y"}


class Machine(itb.Machine):
    """run-qemu.sh with the given options; the serial console on a socket."""

    def __init__(self, name, opts, extra=()):
        self.work = WORK
        self.serial_path = os.path.join(SOCKETS, f"{name}-serial.sock")
        self.qmp_path = os.path.join(SOCKETS, f"{name}-qmp.sock")
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = [os.path.join(DISTRO, "run-qemu.sh"), *opts,
               "--serial-socket", self.serial_path, "--qmp-socket", self.qmp_path,
               "--", "-no-reboot", *extra]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(WORK, f"{name}-qemu.log"), "w"))
        self.serial = self._connect(self.serial_path)
        self.serial.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.transcript = open(os.path.join(WORK, f"{name}-serial.txt"), "w")
        self.failures = FAILURES

    def type_on(self, layout, text):
        """Type text as it should come out on the given layout (fr, de, us)."""
        table = {"fr": FR, "de": DE}.get(layout, {})
        names = {" ": "spc", "-": "minus", ".": "dot"}
        for ch in text:
            low = ch.lower()
            q = table.get(low, names.get(low, low))
            if ch.isupper():
                self.key("shift", q)
            else:
                self.key(q)

    def shot(self, n, step):
        path = os.path.join(SHOTS, f"install-{n:02d}-{step}.png")
        for _ in range(10):
            try:
                w, h, rgb = self.screen(path)
                print(f"        shot {os.path.relpath(path, os.path.dirname(DISTRO))} ({itb.colours(w, h, rgb)} colours)", flush=True)
                return path
            except Exception:
                time.sleep(0.3)
        self.check(f"screendump {path}", False)
        return path

    def login(self, user, password, host):
        """Log in on the serial getty of an installed system."""
        if self.expect(rf"{re.escape(host)} login: ", 120) is None:
            return False
        time.sleep(0.5)
        self.send(user)
        if self.expect(r"Password: ", 15) is None:
            return False
        self.send(password)
        if self.expect(r"# ", 15) is None:
            return False
        self.run("stty -echo 2>/dev/null; export PS1='# '")
        return True

    def wait_exit(self, timeout):
        try:
            self.proc.wait(timeout=timeout)
            return True
        except subprocess.TimeoutExpired:
            return False


def fresh_disk(path):
    for p in (path, path.rsplit(".", 1)[0] + ".OVMF_VARS.fd"):
        if os.path.exists(p):
            os.unlink(p)
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", path, "8G"], check=True)


def live_shell(m):
    ok = m.expect(r"root@\S*?:.*?# ", 120) is not None
    m.check("the live system's root shell on ttyS0", ok, m.buf[-1500:])
    if ok:
        time.sleep(1)
        m.send("")
        m.run("stty -echo 2>/dev/null")
    return ok


def efi_entries(m):
    """BootCurrent, BootOrder and every Boot#### description, read through efivarfs."""
    out, _ = m.run(
        "mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null; cd /sys/firmware/efi/efivars && "
        f"for v in BootCurrent BootOrder; do printf '%s: ' $v; od -An -tx1 $v-{EFI_GUID}; done; "
        f"for f in Boot0*-{EFI_GUID}; do printf '%s ' ${{f%%-*}}; od -An -c $f | tr -d ' \\n' | sed 's/\\\\0//g' | cut -c1-48; echo; done; cd /")
    print("        " + out.strip().replace("\n", "\n        "), flush=True)
    cur = re.search(r"BootCurrent:\s+\S+ \S+ \S+ \S+ (\S\S) (\S\S)", out)
    order = re.search(r"BootOrder:\s+\S+ \S+ \S+ \S+ (\S\S) (\S\S)", out)
    if not (cur and order):
        m.check("BootCurrent and BootOrder are readable", False, out)
        return
    num = f"Boot{cur.group(2).upper()}{cur.group(1).upper()}"
    m.check(f"the firmware booted {num}, first in BootOrder", cur.groups() == order.groups(), out)
    m.check(f"{num} is the \"Palmy\" entry", re.search(rf"^{num} .*Palmy", out, re.M) is not None, out)


def wait_session(m, user):
    for _ in range(40):
        o, _ = m.run("ps -o user,args | grep '[w]m --drm' | grep -v kiosk")
        if user in o:
            return True
        time.sleep(1)
    return False


# ---------------------------------------------------------------------------
# GUI install
# ---------------------------------------------------------------------------

def gui():
    disk = os.path.join(WORK, "gui.qcow2")
    fresh_disk(disk)
    print("GUI: live ISO under OVMF, a blank 8 GiB virtio disk", flush=True)
    m = Machine("gui-live", ["--iso", "--disk", disk])
    try:
        if not live_shell(m):
            return False
        for _ in range(40):
            out, _ = m.run("pidof installer; pidof wm")
            if len(out.split()) >= 2:
                break
            time.sleep(0.5)
        m.check("wm and the installer are running", len(out.split()) >= 2, out)
        time.sleep(4)  # first frame, fonts
        m.shot(1, "language-en")

        # Arabic first: right to left. English, Français, Deutsch, Español, العربية, 日本語.
        for _ in range(4):
            m.key("down")
        time.sleep(1.5)
        m.shot(2, "language-ar")
        out, _ = m.run("cat /etc/palm/keyboard")
        print("        keyboard after Arabic: " + out.strip().replace("\n", " | "))
        for _ in range(3):
            m.key("up")
        time.sleep(1.5)
        m.shot(3, "language-fr")

        m.key("ret")  # -> keyboard, French followed
        time.sleep(1.5)
        out, _ = m.run("cat /etc/palm/keyboard")
        m.check("choosing Français wrote layout = fr to /etc/palm/keyboard", re.search(r"^layout = fr$", out, re.M) is not None, out)
        out, _ = m.run("grep -i 'fr' /var/log/wm.log 2>/dev/null | tail -3; tail -n 3 /var/log/installer.log")
        print("        " + out.strip().replace("\n", "\n        ")[:600])
        m.key("tab")  # search -> test field
        time.sleep(0.3)
        for k in "qwerty":  # physical keys
            m.key(k)
        time.sleep(1)
        m.shot(4, "keyboard-fr")
        print("        look at install-04: the test field must read 'azerty'")

        m.key("ret")  # -> time zone
        time.sleep(1.5)
        m.shot(5, "timezone")
        m.key("ret")  # -> disk
        time.sleep(1.5)
        m.shot(6, "disk")
        m.key("ret")  # the erase dialog
        time.sleep(1)
        m.shot(7, "disk-confirm")
        m.key("tab")  # Cancel holds the focus; Tab moves to Erase
        time.sleep(0.3)
        m.key("ret")
        time.sleep(1.5)

        # Account, on AZERTY now.
        m.type_on("fr", "Ada Lovelace")
        time.sleep(0.4)
        m.key("tab")  # user name (follows the full name: ada)
        time.sleep(0.2)
        m.key("tab")  # computer name, prefilled "palmy"
        time.sleep(0.2)
        for _ in range(16):
            m.key("backspace")
        m.type_on("fr", "analytical")
        m.key("tab")
        time.sleep(0.2)
        m.type_on("fr", "palmy")
        m.key("tab")
        time.sleep(0.2)
        m.type_on("fr", "palmy")
        time.sleep(0.8)
        m.shot(8, "account")
        m.key("ret")
        time.sleep(1.5)
        m.shot(9, "summary")

        m.key("ret")  # Install
        t0 = time.time()
        # The whole install takes seconds from the medium's repository in
        # RAM, so the progress page is caught with back-to-back screendumps.
        for i in range(1, 4):
            m.shot(9 + i, f"install-progress-{i}")
        n = 3
        finished = False
        last = ""
        while time.time() - t0 < 600:
            time.sleep(2)
            n += 1
            out, _ = m.run("tail -n 2 /var/log/palm-install.log 2>/dev/null")
            last = out.strip().splitlines()[-1] if out.strip() else ""
            print(f"        {time.time() - t0:5.0f} s  {last}"[:160], flush=True)
            if "installation finished" in out:
                finished = True
                break
            if re.search(r"\b(error|failed)\b", out, re.I):
                break
        time.sleep(2)
        m.shot(14, "done")
        m.check(f"the installation finished ({time.time() - t0:.0f} s)", finished, last)
        log, _ = m.run("cat /var/log/palm-install.log", 30)
        with open(os.path.join(WORK, "gui-palm-install.log"), "w") as f:
            f.write(log)
        m.check("the install log names the UEFI entry", re.search(r"UEFI: Boot[0-9A-F]{4} \"Palmy \(analytical\)\"", log) is not None, log[-1500:])
        if not finished:
            return False
        m.key("ret")  # Restart now, focused
        m.check("Restart now ends the live machine", m.wait_exit(60))
    finally:
        m.close()

    print("GUI: the installed disk alone, same OVMF variables", flush=True)
    t = Machine("gui-target", ["--disk", disk])
    try:
        m = t.expect(r'BdsDxe: (?:loading|starting) (Boot[0-9A-F]{4}) "([^"]*)"', 60)
        t.check("OVMF starts the \"Palmy\" boot entry", m is not None and m.group(2) == "Palmy (analytical)",
                m.group(0) if m else t.buf[-800:])
        ok = t.expect(r"palm-init: Palmy is starting", 90) is not None
        t.check("limine boots the kernel, palm-init starts", ok, t.buf[-1500:])
        if not t.check("serial getty on host analytical; root's password is the user's",
                       t.login("root", "palmy", "analytical"), t.buf[-1500:]):
            return False
        efi_entries(t)
        out, _ = t.run("cat /etc/hostname; date; date +%Z; cat /etc/locale.conf /etc/palm/keyboard; readlink /etc/localtime; "
                       "id ada; grep ada /etc/passwd; cat /proc/cmdline")
        print("        " + out.strip().replace("\n", "\n        "))
        t.check("/etc/hostname is analytical", out.split("\n")[0].strip() == "analytical", out)
        t.check("date is in Paris time (CET/CEST)", re.search(r"^CES?T$", out, re.M) is not None, out)
        t.check("LANG=fr_FR.UTF-8, layout = fr, /etc/localtime -> Europe/Paris",
                "LANG=fr_FR.UTF-8" in out and "layout = fr" in out and out.count("zoneinfo/Europe/Paris") == 1, out)
        t.check("ada: uid 1000, wheel/video/input/audio, full name Ada Lovelace",
                all(s in out for s in ("uid=1000(ada)", "wheel", "video", "input", "audio", "Ada Lovelace")), out)
        out, rc = t.run("palm verify; echo verify-exit=$?", 60)
        print("        palm verify:\n        " + out.strip().replace("\n", "\n        "))
        t.check("palm verify is clean (exit 0)", "verify-exit=0" in out, out)
        out, _ = t.run("palm list --installed 2>/dev/null | wc -l; palm list --installed 2>/dev/null | tr '\\n' ' '", 30)
        print("        palm list --installed: " + out.strip()[:900])
        t.check("palm list shows the installed set (palmy and its dependencies)", "palmy" in out and "palmy-demo" not in out, out)
        # The medium carries the firmware parts live/build.sh's LIVE_FIRMWARE
        # names, and install_core adds what the repository has.
        t.check("the medium's firmware parts are installed (linux-firmware-intel, wireless-regdb)",
                "linux-firmware-intel" in out and "wireless-regdb" in out, out)
        out, _ = t.run("df -h / /boot/efi 2>&1; cat /sys/block/vda/size; cat /sys/block/vda/vda2/size; ls /home | cat")
        print("        " + out.strip().replace("\n", "\n        "))
        sizes = re.findall(r"^(\d+)$", out, re.M)
        t.check("the root partition fills the disk (more than 7 of 8 GiB)",
                len(sizes) >= 2 and int(sizes[1]) * 512 > 7 * 2**30, out)
        t.check("only ada's home under /home (the demo user's is gone)", out.strip().split("\n")[-1].strip() == "ada", out)

        greeter = False
        for _ in range(40):
            o, _ = t.run("ps | grep -c '[g]reeter'")
            if o.strip().isdigit() and int(o.strip()) > 0:
                greeter = True
                break
            time.sleep(1)
        time.sleep(5)
        t.shot(15, "installed-greeter")
        out, _ = t.run("date +%H:%M; date -u +%H:%M")
        print(f"        local / UTC time now: {out.strip()}  (the greeter's clock must show the first)")
        t.check("the greeter runs", greeter)
        t.type_on("fr", "palmy")
        t.key("ret")
        ok = wait_session(t, "ada")
        time.sleep(4)
        t.shot(16, "installed-desktop")
        t.check("ada/palmy logs in through the greeter: wm --drm runs as ada", ok,
                t.run("ps -o user,args | grep -v '\\['; tail -20 /var/log/palm-login.log")[0])
        if ok:
            t.key("meta_l", "ret")  # SUPER+Return: term
            time.sleep(3)
            for k in "qwerty":  # physical keys -> azerty
                t.key(k)
            t.key("ret")
            time.sleep(0.5)
            t.type_on("fr", "date")
            t.key("ret")
            t.type_on("fr", "hostname")
            t.key("ret")
            time.sleep(1.5)
            t.shot(17, "installed-term")
            out, _ = t.run("cat /home/ada/.ash_history 2>/dev/null | tail -3")
            print("        ada's shell history: " + out.strip().replace("\n", " | "))
            t.check("term typed AZERTY: physical q w e r t y gave 'azerty'", "azerty" in out, out)
        t.send("poweroff")
        t.check("the installed system powers off", t.wait_exit(60))
    finally:
        t.close()
    return True


# ---------------------------------------------------------------------------
# CLI install
# ---------------------------------------------------------------------------

def cli():
    spare = os.path.join(WORK, "cli-vda.qcow2")
    disk = os.path.join(WORK, "cli.qcow2")
    fresh_disk(spare)
    fresh_disk(disk)
    print("CLI: live ISO with two blank disks; palm-install onto /dev/vdb from the serial console", flush=True)
    m = Machine("cli-live", ["--iso", "--disk", spare], ["-drive", f"file={disk},if=virtio,format=qcow2"])
    try:
        if not live_shell(m):
            return False
        out, _ = m.run("palm-install --list-disks")
        print("        " + out.strip().replace("\n", "\n        "))
        t0 = time.time()
        out, rc = m.run("echo gracehopper | palm-install --disk /dev/vdb --language de_DE --keyboard de "
                        "--timezone America/New_York --hostname cli-test --user grace --full-name 'Grace Hopper' "
                        "--password-file - --yes", 600)
        print("        " + "\n        ".join(out.strip().splitlines()[-12:]))
        m.check(f"palm-install --disk /dev/vdb ... --yes exits 0 ({time.time() - t0:.0f} s)", rc == 0, out[-2000:])
        log, _ = m.run("cat /var/log/palm-install.log", 30)
        with open(os.path.join(WORK, "cli-palm-install.log"), "w") as f:
            f.write(log)
        m.send("poweroff")
        m.check("the live machine powers off", m.wait_exit(60))
        if rc != 0:
            return False
    finally:
        m.close()
    # The Boot#### entry was written into the live machine's variable store,
    # which run-qemu.sh keeps beside its first disk; it belongs to vdb.
    shutil.copy(spare.rsplit(".", 1)[0] + ".OVMF_VARS.fd", disk.rsplit(".", 1)[0] + ".OVMF_VARS.fd")

    print("CLI: the installed disk alone", flush=True)
    t = Machine("cli-target", ["--disk", disk])
    try:
        mm = t.expect(r'BdsDxe: (?:loading|starting) (Boot[0-9A-F]{4}) "([^"]*)"', 60)
        t.check("OVMF starts the \"Palmy\" boot entry", mm is not None and mm.group(2) == "Palmy (cli-test)",
                mm.group(0) if mm else t.buf[-800:])
        if not t.check("serial getty on host cli-test", t.login("root", "gracehopper", "cli-test"), t.buf[-1500:]):
            return False
        out, _ = t.run("cat /etc/hostname /etc/locale.conf /etc/palm/keyboard; date +%Z; id grace")
        print("        " + out.strip().replace("\n", "\n        "))
        t.check("cli-test, LANG=de_DE.UTF-8, layout = de, New York time",
                "cli-test" in out and "LANG=de_DE.UTF-8" in out and "layout = de" in out and re.search(r"^E[SD]T$", out, re.M), out)
        out, _ = t.run("palm verify; echo verify-exit=$?", 60)
        t.check("palm verify is clean", "verify-exit=0" in out, out)
        for _ in range(40):
            o, _ = t.run("ps | grep -c '[g]reeter'")
            if o.strip().isdigit() and int(o.strip()) > 0:
                break
            time.sleep(1)
        time.sleep(5)
        t.shot(20, "cli-greeter-de")
        t.type_on("de", "gracehopper")
        t.key("ret")
        ok = wait_session(t, "grace")
        time.sleep(4)
        t.check("grace logs in through the greeter", ok, t.run("tail -20 /var/log/palm-login.log")[0])
        if ok:
            t.key("meta_l", "ret")
            time.sleep(3)
            for k in "qwerty":  # physical keys -> qwertz
                t.key(k)
            t.key("ret")
            time.sleep(1.5)
            t.shot(21, "cli-term-de")
            out, _ = t.run("cat /home/grace/.ash_history 2>/dev/null | tail -2")
            t.check("term typed QWERTZ: physical q w e r t y gave 'qwertz'", "qwertz" in out, out)
        t.send("poweroff")
        t.check("the installed system powers off", t.wait_exit(60))
    finally:
        t.close()
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=("gui", "cli"))
    args = ap.parse_args()
    if not os.path.exists(os.path.join(OUT, "palmy-live.iso")):
        sys.exit("test-install: distro/out/palmy-live.iso is missing (make -C distro iso)")
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(SHOTS, exist_ok=True)
    if args.only in (None, "gui"):
        gui()
    if args.only in (None, "cli"):
        cli()
    print(f"test-install: {'all passed' if not FAILURES else f'{len(FAILURES)} failed: ' + '; '.join(FAILURES)}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
