"""More of the installer, end to end, inside QEMU: what test-install.py does not cover.

    python3 -I distro/live/test-install-more.py [--only ja|ar|two] [--keep]

ja   Japanese, on an emulated NVMe disk, with the pointer. The live ISO under
     OVMF with an NVMe disk (and a 2 GiB virtio disk, too small, which the
     installer greys out). 日本語 is chosen, Next is clicked with the pointer
     (QMP absolute events through virtio-tablet) on the language and keyboard
     pages, the account is typed, the install runs, and "Restart now" is
     clicked. Then the NVMe disk boots alone under OVMF through its own entry,
     "Palmy (kyoto)", to a Japanese greeter; and again under SeaBIOS,
     through limine's BIOS stages.
ar   Arabic, under SeaBIOS: the live ISO boots through the BIOS, the
     installer runs right to left, the keyboard gets `us,ara`, the account is
     typed in Latin letters, and the installed disk then boots under SeaBIOS
     to an Arabic greeter, and under OVMF (a fresh variable store) through
     the fallback path.
two  Two disks in one machine: palm-install onto /dev/vdb with options, then
     palm-install's questions onto /dev/vda over the serial console. Each
     disk gets its own Boot#### ("Palmy (cli-b)", "Palmy (cli-a)"),
     and each boots alone through its own.

Screenshots go to distro/out/shots/more-<scenario>-NN-<step>.png.
"""

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(HERE)
OUT = os.path.join(DISTRO, "out")
SHOTS = os.path.join(OUT, "shots")

_spec = importlib.util.spec_from_file_location("test_install", os.path.join(HERE, "test-install.py"))
ti = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ti)
itb = ti.itb
WORK = ti.WORK
FAILURES = ti.FAILURES


class Machine(ti.Machine):
    scenario = "x"

    def shot(self, n, step):
        path = os.path.join(SHOTS, f"more-{self.scenario}-{n:02d}-{step}.png")
        for _ in range(10):
            try:
                self.last = self.screen(path)
                print(f"        shot {os.path.relpath(path, os.path.dirname(DISTRO))}", flush=True)
                return self.last
            except Exception:
                time.sleep(0.3)
        self.check(f"screendump {path}", False)
        return None

    def pointer(self, x, y, w, h, click=True):
        """Move the absolute pointer to (x, y) of a w x h screen and click."""
        ax = {"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / max(1, w - 1))}}
        ay = {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / max(1, h - 1))}}
        self.qmp({"execute": "input-send-event", "arguments": {"events": [ax, ay]}})
        time.sleep(0.3)
        if click:
            for down in (True, False):
                self.qmp({"execute": "input-send-event", "arguments": {"events": [
                    {"type": "btn", "data": {"down": down, "button": "left"}}]}})
                time.sleep(0.12)

    def click_bright(self, n, step, box):
        """Find the light (primary) button inside box = (x0, y0, x1, y1) as
        fractions of the screen, click its centre, and return whether one was
        found. Primary buttons are the only near-white areas of the dark UI."""
        got = self.shot(n, step)
        if not got:
            return False
        w, h, rgb = got
        x0, y0, x1, y1 = int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)
        # A button's fill is light and solid: rows with a run of at least
        # 48 light pixels. White text (a heading) has no runs that long.
        xs, ys = [], []
        for y in range(y0, y1):
            row = y * w * 3
            run = 0
            for x in range(x0, x1):
                i = row + x * 3
                if rgb[i] > 215 and rgb[i + 1] > 215 and rgb[i + 2] > 215:
                    run += 1
                    if run >= 48:
                        xs.extend((x - run + 1, x))
                        ys.append(y)
                else:
                    run = 0
        if len(ys) < 50:
            self.check(f"{step}: a primary button on screen", False, f"{len(ys)} light runs in {box}")
            return False
        cx, cy = (min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2
        print(f"        pointer: click ({cx}, {cy}) on a {max(xs) - min(xs)}x{max(ys) - min(ys)} button", flush=True)
        self.pointer(cx, cy, w, h)
        return True


def disk(path, size="8G"):
    for p in (path, path.rsplit(".", 1)[0] + ".OVMF_VARS.fd"):
        if os.path.exists(p):
            os.unlink(p)
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", path, size], check=True)


def wait_installer(m):
    out = ""
    for _ in range(60):
        out, _ = m.run("pidof installer; pidof wm")
        if len(out.split()) >= 2:
            break
        time.sleep(0.5)
    m.check("wm and the installer are running", len(out.split()) >= 2, out)
    time.sleep(4)


def wait_install(m, tag):
    t0 = time.time()
    finished = False
    last = ""
    while time.time() - t0 < 600:
        time.sleep(2)
        out, _ = m.run("tail -n 2 /var/log/palm-install.log 2>/dev/null")
        last = out.strip().splitlines()[-1] if out.strip() else ""
        if "installation finished" in out:
            finished = True
            break
        if re.search(r"\bFAILED\b", out):
            break
    m.check(f"{tag}: the installation finished ({time.time() - t0:.0f} s)", finished, last)
    log, _ = m.run("cat /var/log/palm-install.log", 30)
    with open(os.path.join(WORK, f"more-{tag}-palm-install.log"), "w") as f:
        f.write(log)
    return finished, log


def type_account(m, full, host, pw):
    m.type_on("us", full)
    time.sleep(0.4)
    m.key("tab")  # user name, follows the full name
    time.sleep(0.2)
    m.key("tab")  # computer name, prefilled
    time.sleep(0.2)
    for _ in range(16):
        m.key("backspace")
    m.type_on("us", host)
    m.key("tab")
    time.sleep(0.2)
    m.type_on("us", pw)
    m.key("tab")
    time.sleep(0.2)
    m.type_on("us", pw)
    time.sleep(0.8)


def boot_target(name, scenario, opts, extra, host, pw, want_entry=None, shot_n=None, shot_step=None, checks=None):
    """Boot an installed disk; log in on the serial console; run checks."""
    t = Machine(name, opts, extra)
    t.scenario = scenario
    try:
        if want_entry:
            mm = t.expect(r'BdsDxe: (?:loading|starting) (Boot[0-9A-F]{4}) "([^"]*)"', 60)
            t.check(f"{name}: OVMF starts \"{want_entry}\"", mm is not None and mm.group(2) == want_entry,
                    mm.group(0) if mm else t.buf[-800:])
        ok = t.expect(r"palm-init: Palmy is starting", 120) is not None
        t.check(f"{name}: limine boots the kernel, palm-init starts", ok, t.buf[-1500:])
        if not t.check(f"{name}: serial getty on host {host}", t.login("root", pw, host), t.buf[-1500:]):
            return False
        if checks:
            checks(t)
        if shot_n is not None:
            for _ in range(40):
                o, _ = t.run("ps | grep -c '[g]reeter'")
                if o.strip().isdigit() and int(o.strip()) > 0:
                    break
                time.sleep(1)
            time.sleep(5)
            t.shot(shot_n, shot_step)
        t.send("poweroff")
        t.check(f"{name}: powers off", t.wait_exit(60))
        return True
    finally:
        t.close()


# ---------------------------------------------------------------------------

def scenario_ja():
    spare = os.path.join(WORK, "ja-spare.qcow2")
    nvme = os.path.join(WORK, "ja-nvme.qcow2")
    disk(spare, "2G")
    disk(nvme, "8G")
    nv = ["-drive", f"file={nvme},if=none,id=nv0,format=qcow2", "-device", "nvme,drive=nv0,serial=PALMNVME01"]
    print("ja: live ISO under OVMF, an 8 GiB NVMe disk, the pointer", flush=True)
    m = Machine("ja-live", ["--iso", "--disk", spare], nv)
    m.scenario = "ja"
    try:
        if not ti.live_shell(m):
            return
        out, _ = m.run("ls /sys/block; palm-install --list-disks")
        print("        " + out.strip().replace("\n", "\n        "))
        m.check("the NVMe disk is listed", "/dev/nvme0n1" in out, out)
        wait_installer(m)
        for _ in range(5):
            m.key("down")
        time.sleep(1.5)
        m.shot(1, "language-ja")
        # Next, with the pointer: the light button at the bottom right.
        m.click_bright(2, "language-next", (0.6, 0.85, 1.0, 1.0))
        time.sleep(1.5)
        out, _ = m.run("cat /etc/palm/keyboard")
        m.check("clicking Next left the language page (keyboard page; layout = jp)", re.search(r"^layout = jp$", out, re.M) is not None, out)
        m.click_bright(3, "keyboard", (0.6, 0.85, 1.0, 1.0))
        time.sleep(1.5)
        m.shot(4, "timezone")
        m.key("ret")
        time.sleep(1.5)
        m.shot(5, "disk")
        m.key("ret")
        time.sleep(1)
        m.shot(6, "disk-confirm")
        m.key("tab")
        time.sleep(0.3)
        m.key("ret")
        time.sleep(1.5)
        type_account(m, "Hanako Yamada", "kyoto", "sakurasakura")
        m.shot(7, "account")
        m.key("ret")
        time.sleep(1.5)
        m.shot(8, "summary")
        m.key("ret")
        for i in range(3):
            m.shot(9 + i, f"progress-{i + 1}")
            time.sleep(0.4)
        finished, log = wait_install(m, "ja")
        print("        " + "\n        ".join(l for l in log.splitlines() if re.search(r"GPT written|nvme0n1p|bios-install|UEFI|swap|fonts-cjk", l))[:2000])
        m.check("partitions are nvme0n1p1..p3", "/dev/nvme0n1p1" in log and "/dev/nvme0n1p2" in log, log[-1500:])
        m.check("limine's BIOS stages went onto the NVMe disk", "bios-install /dev/nvme0n1 3" in log and "installed successfully" in log, log[-1500:])
        m.check("the UEFI entry is \"Palmy (kyoto)\"", re.search(r'UEFI: Boot[0-9A-F]{4} "Palmy \(kyoto\)"', log) is not None)
        m.check("fonts-cjk is installed for Japanese", "fonts-cjk" in log, "")
        if not finished:
            return
        time.sleep(1.5)
        # Restart now, with the pointer: the Done page's one light button,
        # right of the rail.
        m.click_bright(12, "done", (0.25, 0.1, 1.0, 0.9))
        m.check("clicking Restart now ends the live machine", m.wait_exit(60))
    finally:
        m.close()

    def checks(t):
        out, _ = t.run("cat /etc/locale.conf /etc/palm/keyboard; ls /usr/share/fonts/noto-cjk; cat /proc/partitions; "
                       "ls -l /swapfile; grep swap /etc/fstab; cat /proc/swaps; date +%Z")
        print("        " + out.strip().replace("\n", "\n        "))
        t.check("LANG=ja_JP.UTF-8, layout = jp, the full CJK font, Tokyo time",
                "LANG=ja_JP.UTF-8" in out and "layout = jp" in out and "NotoSansCJK-Regular.ttc" in out and re.search(r"^JST$", out, re.M), out)
        t.check("/swapfile exists and is in fstab", "/swapfile" in out and "swap" in out, out)
        ti.efi_entries(t)

    print("ja: the NVMe disk alone under OVMF", flush=True)
    boot_target("ja-uefi", "ja", ["--disk", spare], nv, "kyoto", "sakurasakura", "Palmy (kyoto)", 13, "installed-greeter-ja", checks)
    print("ja: the NVMe disk alone under SeaBIOS", flush=True)
    # SeaBIOS tries an NVMe disk only when it has a boot index (what choosing
    # it in the BIOS boot menu does); without one it never looks at it.
    nv_first = nv[:-1] + [nv[-1] + ",bootindex=0"]
    boot_target("ja-bios", "ja", ["--bios", "--disk", spare], nv_first, "kyoto", "sakurasakura",
                checks=lambda t: t.check("booted without UEFI", t.run("test -d /sys/firmware/efi || echo nouefi")[0].strip() == "nouefi"))


def scenario_ar():
    d = os.path.join(WORK, "ar.qcow2")
    disk(d)
    print("ar: live ISO under SeaBIOS, a blank 8 GiB virtio disk", flush=True)
    m = Machine("ar-live", ["--iso", "--bios", "--disk", d])
    m.scenario = "ar"
    try:
        if not ti.live_shell(m):
            return
        m.check("the live system booted through the BIOS", m.run("test -d /sys/firmware/efi || echo nouefi")[0].strip() == "nouefi")
        wait_installer(m)
        for _ in range(4):
            m.key("down")
        time.sleep(1.5)
        m.shot(1, "language-ar")
        m.key("ret")
        time.sleep(1.5)
        out, _ = m.run("cat /etc/palm/keyboard")
        m.check("Arabic's layout comes with US English: layout = us,ara", "layout = us,ara" in out and "grp:alt_shift_toggle" in out, out)
        m.shot(2, "keyboard")
        m.key("ret")
        time.sleep(1.5)
        m.shot(3, "timezone")
        m.key("ret")
        time.sleep(1.5)
        m.shot(4, "disk")
        m.key("ret")
        time.sleep(1)
        m.key("tab")
        time.sleep(0.3)
        m.key("ret")
        time.sleep(1.5)
        type_account(m, "Layla Hassan", "cairo", "nilenile")
        m.shot(5, "account")
        m.key("ret")
        time.sleep(1.5)
        m.shot(6, "summary")
        m.key("ret")
        for i in range(3):
            m.shot(7 + i, f"progress-{i + 1}")
            time.sleep(0.4)
        finished, log = wait_install(m, "ar")
        print("        " + "\n        ".join(l for l in log.splitlines() if re.search(r"bios-install|UEFI|installed successfully", l)))
        m.check("limine's BIOS stages installed", "installed successfully" in log, log[-1500:])
        m.check("no UEFI entry under a BIOS", "no UEFI boot entry requested" in log, log[-800:])
        if not finished:
            return
        time.sleep(1.5)
        m.shot(10, "done")
        m.key("ret")
        m.check("Restart now ends the live machine", m.wait_exit(60))
    finally:
        m.close()

    def checks(t):
        out, _ = t.run("cat /etc/locale.conf /etc/palm/keyboard; id layla; date +%Z")
        print("        " + out.strip().replace("\n", "\n        "))
        t.check("LANG=ar, layout = us,ara, layla, Cairo time",
                "LANG=ar" in out and "layout = us,ara" in out and "uid=1000(layla)" in out and re.search(r"^EES?T$", out, re.M), out)

    print("ar: the installed disk alone under SeaBIOS", flush=True)
    boot_target("ar-bios", "ar", ["--bios", "--disk", d], [], "cairo", "nilenile", None, 11, "installed-greeter-ar", checks)
    print("ar: the same disk under OVMF, a fresh variable store (fallback path)", flush=True)
    v = d.rsplit(".", 1)[0] + ".OVMF_VARS.fd"
    if os.path.exists(v):
        os.unlink(v)
    boot_target("ar-uefi", "ar", ["--disk", d], [], "cairo", "nilenile")


def scenario_two():
    a = os.path.join(WORK, "two-a.qcow2")
    b = os.path.join(WORK, "two-b.qcow2")
    disk(a)
    disk(b)
    print("two: live ISO under OVMF, two blank disks", flush=True)
    m = Machine("two-live", ["--iso", "--disk", a], ["-drive", f"file={b},if=virtio,format=qcow2"])
    m.scenario = "two"
    try:
        if not ti.live_shell(m):
            return
        out, rc = m.run("echo gracehopper | palm-install --disk /dev/vdb --hostname cli-b --user grace "
                        "--password-file - --swap 1G --yes", 600)
        print("        " + "\n        ".join(out.strip().splitlines()[-6:]))
        m.check("palm-install onto /dev/vdb exits 0", rc == 0, out[-1500:])

        # palm-install's questions, over the serial console.
        m.send("palm-install; echo interactive-exit=$?")
        steps = [
            (r"Disk to erase \(number or path\) \[\d\]: ", "/dev/vda"),
            (r"Language \([^)]*\) \[en_US\]: ", "fr_FR"),
            (r"Keyboard layout.*\[fr\]: ", ""),
            (r"Time zone.*\[Europe/Paris\]: ", "?Paris"),
            (r"Time zone.*\[Europe/Paris\]: ", ""),
            (r"Computer name \[palmy\]: ", "cli-a"),
            (r"Your full name \(optional\): ", "Ada Lovelace"),
            (r"User name \[ada\]: ", ""),
            (r"Password: ", "analytical"),
            (r"Password again: ", "analytical"),
            (r"Use the same password for root.*\[yes\]: ", ""),
            (r"Swap file size.*\[none\]: ", "512M"),
            (r"Type vda to erase it.*: ", "vda"),
        ]
        ok = True
        for rx, answer in steps:
            if m.expect(rx, 30) is None:
                m.check(f"palm-install asks {rx!r}", False, m.buf[-1200:])
                ok = False
                break
            time.sleep(0.2)
            m.send(answer)
        if ok:
            r = m.expect(r"interactive-exit=(\d+)", 600)
            print("        " + "\n        ".join(m.buf[-1600:].splitlines()[-16:]))
            m.check("the questions installed onto /dev/vda", r is not None and r.group(1) == "0", m.buf[-1500:])
        out, _ = m.run("mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null; cd /sys/firmware/efi/efivars && "
                       f"for f in Boot0*-{ti.EFI_GUID}; do printf '%s ' ${{f%%-*}}; od -An -c $f | tr -d ' \\n' | sed 's/\\\\0//g' | cut -c1-40; echo; done; cd /")
        print("        " + out.strip().replace("\n", "\n        "))
        m.check("two Palmy entries, one per disk", "Palmy(cli-b)" in out and "Palmy(cli-a)" in out, out)
        m.send("poweroff")
        m.check("the live machine powers off", m.wait_exit(60))
    finally:
        m.close()
    shutil.copy(a.rsplit(".", 1)[0] + ".OVMF_VARS.fd", b.rsplit(".", 1)[0] + ".OVMF_VARS.fd")

    def swap(t):
        out, _ = t.run("grep swap /etc/fstab; ls -l /swapfile")
        print("        " + out.strip().replace("\n", "\n        "))
        t.check("/swapfile and its fstab line", "/swapfile" in out, out)

    print("two: /dev/vdb alone", flush=True)
    boot_target("two-b", "two", ["--disk", b], [], "cli-b", "gracehopper", "Palmy (cli-b)", checks=swap)
    print("two: /dev/vda alone", flush=True)
    boot_target("two-a", "two", ["--disk", a], [], "cli-a", "analytical", "Palmy (cli-a)", checks=swap)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=("ja", "ar", "two"))
    args = ap.parse_args()
    if not os.path.exists(os.path.join(OUT, "palmy-live.iso")):
        sys.exit("test-install-more: distro/out/palmy-live.iso is missing (make -C distro iso)")
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(SHOTS, exist_ok=True)
    for name, f in (("ja", scenario_ja), ("ar", scenario_ar), ("two", scenario_two)):
        if args.only in (None, name):
            f()
    print(f"test-install-more: {'all passed' if not FAILURES else f'{len(FAILURES)} failed: ' + '; '.join(FAILURES)}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
