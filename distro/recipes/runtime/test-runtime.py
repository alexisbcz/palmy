"""Boot the image and check the runtime packages and the applications they unlock.

    python3 -I distro/recipes/runtime/test-runtime.py [--port 8093] [--keep]

Uses the Machine class of distro/image/test-boot.py (QEMU through
distro/run-qemu.sh: OVMF, limine, the image's kernel), with an Intel HDA
sound card whose output QEMU writes to a WAV file, so "sound came out" is
checked on the host. The repository is served on --port (not 8080, which
other checkouts may be serving) and the guest is pointed at it.

    services   dbus-daemon (as dbus), iwd, bluetoothd run; iwd and BlueZ are
               on the system bus; /var/log/messages is root's alone
    tools      ffmpeg encodes H.264/AAC/Opus and probes; bsdtar round-trips;
               openssl verifies a real TLS server with the shipped CA bundle
    wifi       mac80211_hwsim's two radios: iwd runs an access point on one
               and joins it from the other
    session    palm logs in; palm-login starts PipeWire from
               /etc/palm/session.d; wpctl and pactl see the HDA sink;
               pw-play writes audio the host captures; logging out ends it
    apps       palm add every runtime application over http; each one's
               --selftest where it has one; screenshots of the GUI ones
               in distro/out/shots/runtime-*.png
"""

import argparse
import importlib.util
import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("testboot", os.path.join(DISTRO, "image", "test-boot.py"))
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)

APPS = "audio video videoedit mixer bluetooth archive call mail mailcore ocr clipboard vault ai".split()


def wav_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def wav_peak(path, since=0):
    """Largest absolute 16-bit sample in a WAV file QEMU wrote (0 if none),
    counting only bytes past offset `since` when it is given."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return 0
    i = data.find(b"data")
    if i < 0:
        return 0
    pcm = data[max(i + 8, since):]
    n = len(pcm) // 2
    if n == 0:
        return 0
    peak = 0
    for (s,) in struct.iter_unpack("<h", pcm[: n * 2]):
        if abs(s) > peak:
            peak = abs(s)
    return peak


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(DISTRO, "out", "palmy.img"))
    ap.add_argument("--shots", default=os.path.join(DISTRO, "out", "shots"))
    ap.add_argument("--work", default=os.path.join(DISTRO, "build", "runtime-test"))
    ap.add_argument("--port", type=int, default=8093)
    ap.add_argument("--apps", default=" ".join(APPS))
    ap.add_argument("--kernel", help="boot this bzImage instead of the image's (e.g. one with runtime/kernel.config)")
    ap.add_argument("--ollama", action="store_true", help="also pull qwen3:0.6b over the network and ask it something")
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    img = os.path.join(args.work, "test.img")
    subprocess.run(["cp", "--sparse=always", args.image, img], check=True)
    wav = os.path.join(args.work, "hda-out.wav")
    if os.path.exists(wav):
        os.unlink(wav)
    httpd = tb.serve(os.path.join(DISTRO, "out", "repo"), args.port)
    shot = lambda name: os.path.join(args.shots, "runtime-" + name)

    # The sound card: QEMU's HDA codec, its output captured to a WAV file.
    orig_init = tb.Machine.__init__

    def init(self, img, work):
        real_popen = subprocess.Popen

        def popen(cmd, *a, **kw):
            cmd = list(cmd)
            if args.kernel:
                cmd += ["-kernel", args.kernel, "-append",
                        "root=/dev/vda2 rw console=tty0 console=ttyS0,115200 quiet loglevel=3"]
            cmd += ["-audiodev", f"wav,id=snd0,path={wav}",
                               "-device", "intel-hda", "-device", "hda-duplex,audiodev=snd0"]
            return real_popen(cmd, *a, **kw)
        subprocess.Popen = popen
        try:
            orig_init(self, img, work)
        finally:
            subprocess.Popen = real_popen
    tb.Machine.__init__ = init

    m = tb.Machine(img, args.work)
    report = {}
    try:
        if not m.check("palm-init starts", m.expect(r"palm-init: Palmy is starting", 60) is not None):
            return m.failures
        if not m.check("getty on ttyS0", m.expect(r"login: ", 60) is not None):
            return m.failures
        m.send("root")
        m.expect(r"Password: ", 10)
        m.send("palm")
        if not m.check("root shell", m.expect(r"# ", 15) is not None):
            return m.failures
        m.run("stty -echo cols 250")

        # --- services -----------------------------------------------------------
        ok, out = tb.wait_for(m, "ps -o user,args | grep -E '[d]bus-daemon|[i]wd|[b]luetoothd' || true",
                              r"dbus-daemon[\s\S]*iwd", 30)
        m.check("dbus-daemon and iwd run (palm-init services)", ok, out)
        print("  ....  " + out.strip().replace("\n", "\n        "))
        m.check("dbus-daemon runs as dbus", re.search(r"^\s*dbus\s+dbus-daemon", out, re.M) is not None, out)
        out, _ = m.run("logger -p authpriv.info test-runtime; sleep 1; stat -c '%a %U' /var/log/messages")
        m.check("/var/log/messages is 0600 root", out.strip() == "600 root", out)
        out, _ = m.run("for s in dbus iwd bluetooth; do echo \"== $s\"; tail -25 /var/log/$s.log; done")
        print("  ....  service logs:\n        " + out.strip().replace("\n", "\n        "))
        out, st = m.run("dbus-send --system --print-reply --dest=org.freedesktop.DBus "
                        "/org/freedesktop/DBus org.freedesktop.DBus.ListNames")
        m.check("iwd owns net.connman.iwd on the system bus", "net.connman.iwd" in out, out)
        # bluetoothd starts once the kernel has loaded bluetooth for its
        # socket, and palm-init may have retried it after dbus came up.
        ok, out = tb.wait_for(m, "dbus-send --system --print-reply --dest=org.freedesktop.DBus "
                              "/org/freedesktop/DBus org.freedesktop.DBus.ListNames", r"org\.bluez", 40)
        m.check("bluetoothd owns org.bluez on the system bus", ok, out)
        report["bluez on bus"] = ok
        out, st = m.run("timeout 10 iwctl device list 2>&1 | sed 's/\\x1b\\[[0-9;]*m//g' | head -8", 20)
        m.check("iwctl talks to iwd", st == 0 and "Devices" in out, out)
        print("  ....  iwctl device list:\n        " + out.strip().replace("\n", "\n        "))
        out, st = m.run("timeout 10 bluetoothctl --timeout 3 show 2>&1 | head -5", 20)
        print(f"  ....  bluetoothctl show (exit {st}): " + out.strip().replace("\n", " | "))
        report["bluetoothctl"] = out.strip()
        out, st = m.run("rfkill list 2>&1; echo rc=$?")
        print("  ....  rfkill list: " + out.strip().replace("\n", " | "))

        # --- tools ----------------------------------------------------------------
        out, st = m.run("cd /tmp && ffmpeg -hide_banner -loglevel error -y "
                        "-f lavfi -i testsrc=duration=2:size=320x240:rate=15 "
                        "-f lavfi -i sine=frequency=440:duration=2 "
                        "-c:v libx264 -preset ultrafast -c:a aac -shortest t.mp4 && "
                        "ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=660:duration=3 t.wav && "
                        "ffmpeg -hide_banner -loglevel error -y -i t.wav -c:a libopus t.opus && "
                        "for f in t.mp4 t.opus; do ffprobe -v error -show_entries stream=codec_name -of csv=p=0 $f; done | tr '\\n' ' '", 120)
        m.check("ffmpeg encodes H.264+AAC and Opus, ffprobe reads them",
                st == 0 and "h264" in out and "aac" in out and "opus" in out, out)
        print("  ....  ffprobe: " + out.strip())
        out, st = m.run("cd /tmp && mkdir -p arc/d && echo hello > arc/d/f.txt && "
                        "bsdtar -a -c -f a.tar.zst -C arc d && bsdtar -tf a.tar.zst && "
                        "bsdtar -a -c -f a.zip -C arc d && bsdtar -tvf a.zip | wc -l")
        m.check("bsdtar creates and lists tar.zst and zip", st == 0 and "d/f.txt" in out, out)
        out, st = m.run("openssl version; echo | timeout 20 openssl s_client -connect example.com:443 "
                        "-servername example.com -verify_return_error -brief 2>&1 | head -6", 40)
        # -verify_return_error: the handshake only completes if the chain
        # verified against /etc/ssl/cert.pem.
        m.check("openssl verifies a real TLS server with the CA bundle",
                "CONNECTION ESTABLISHED" in out or "Verification: OK" in out, out)
        print("  ....  openssl: " + out.strip().replace("\n", " | "))

        # --- the session ----------------------------------------------------------
        m.run(f"echo http://10.0.2.2:{args.port}/x86_64 > /etc/palm/repositories")
        out, st = m.run("palm update", 60)
        m.check("palm update from the test repository", st == 0, out)
        out, st = m.run(f"palm add --yes {args.apps} 2>&1 | tail -3", 600)
        m.check(f"palm add {args.apps}", st == 0, out)
        print("  ....  " + out.strip().replace("\n", "\n        "))

        time.sleep(2)
        m.type("palm\n")
        ok, out = tb.wait_for(m, "ps -o user,args | grep '[w]m --drm' || true", r"^\s*palm\s+wm --drm\s*$")
        m.check("palm logs in (wm --drm as palm)", ok, out)
        time.sleep(3)
        out, _ = m.run("ls /run/user/1000")
        disp = (re.findall(r"(wayland-[\w-]+?)(?:\.lock)?\s", out + "\n") or ["wayland-palmy"])[0]
        env = f"HOME=/home/palm XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY={disp} PATH=/usr/bin"
        as_palm = lambda cmd: f"su -s /bin/sh -c 'export {env}; {cmd}' palm"

        out, _ = m.run(as_palm("id; echo HOME=$HOME"))
        print("  ....  as palm: " + out.strip().replace("\n", " | "))

        # Wi-Fi end to end over mac80211_hwsim (a module nothing loads by
        # itself; two radios): iwd runs an access point on one and joins it
        # from the other, including its own DHCP on both sides.
        m.run("modprobe mac80211_hwsim")
        ok, out = tb.wait_for(m, "ls /sys/class/net", r"wlan1", 20)
        m.check("mac80211_hwsim loads (two radios)", ok, out)
        if "wlan1" in out:
            iw = lambda c: m.run("timeout 20 iwctl " + c + " 2>&1 | sed 's/\\x1b\\[[0-9;]*m//g'", 30)[0]
            print("  ....  iwctl device list:\n        " + iw("device list").strip().replace("\n", "\n        "))
            iw("device wlan1 set-property Mode ap")
            time.sleep(2)
            out = iw("ap wlan1 start PalmyTest palmy123")
            print("  ....  ap start: " + out.strip())
            time.sleep(3)
            iw("station wlan0 scan")
            time.sleep(5)
            out = iw("station wlan0 get-networks")
            m.check("iwd (station) sees the iwd access point over mac80211_hwsim", "PalmyTest" in out, out)
            out = iw("--passphrase palmy123 station wlan0 connect PalmyTest")
            ok, out = tb.wait_for(m, "ip -4 addr show wlan0", r"inet \d", 20)
            st_out = iw("station wlan0 show")
            m.check("iwd joins it with WPA2 and gets an address by DHCP", ok, out + st_out)
            print("  ....  wlan0: " + out.strip().replace("\n", " | ") + "\n        " + st_out.strip().replace("\n", "\n        "))
            report["wifi"] = ok

        # palm-login ran /etc/palm/session.d/50-pipewire as palm when the
        # session started; nothing here starts it.
        ok, out = tb.wait_for(m, "ps -o user,args | grep -E '[p]ipewire|[w]ireplumber' || true",
                              r"wireplumber[\s\S]*pipewire-pulse|pipewire-pulse[\s\S]*wireplumber", 20)
        m.check("palm-login's session hook started pipewire, wireplumber, pipewire-pulse as palm",
                ok and re.search(r"^\s*palm\s+pipewire\s*$", out, re.M) is not None,
                out + m.run("grep -E 'hook|pipewire' /var/log/palm-login.log /var/log/session-palm.log | tail")[0])
        time.sleep(3)
        out, st = m.run(as_palm("wpctl status 2>&1 | head -40"), 20)
        m.check("wpctl sees an ALSA sink", st == 0 and re.search(r"Sinks:\s*\n[^\n]*\d+\. ", out) is not None, out)
        print("  ....  wpctl status:\n        " + out.strip().replace("\n", "\n        "))
        out, st = m.run(as_palm("pactl info 2>&1 | grep -E \"Server Name|Default Sink\"; pactl list sinks short 2>&1 | head -5"), 20)
        m.check("pactl reaches the PulseAudio server", st == 0 and "PulseAudio (on PipeWire" in out, out)
        print("  ....  pactl: " + out.strip().replace("\n", " | "))
        before = wav_peak(wav)
        start = wav_size(wav)
        out, st = m.run(as_palm("pw-play /tmp/t.wav"), 30)
        time.sleep(1)
        after = wav_peak(wav, start)
        m.check("pw-play: the host captures sound from the HDA card", st == 0 and after > 1000,
                f"exit {st}, peak before {before}, after {after}\n{out}")
        print(f"  ....  hda-out.wav peak after pw-play: {after}")

        out, st = m.run(as_palm("echo palmy-clip | timeout 10 wl-copy; sleep 1; timeout 10 wl-paste"), 20)
        report["wl-copy"] = (st, out.strip())
        m.check("wl-copy / wl-paste round-trip through the wm", "palmy-clip" in out, out)

        # --- the applications -------------------------------------------------------
        for app in args.apps.split():
            out, st = m.run(as_palm(f"cd /tmp && timeout 120 {app} --selftest {'--no-e2e' if app == 'mailcore' else ''} 2>&1 | grep -E \"FAIL|fail|PASS|checks|assertions\" | tail -8"), 150)
            report[app + " selftest"] = (st, out.strip()[-400:])
            print(f"  ....  {app} --selftest (exit {st}): " + out.strip().replace("\n", " | ")[-400:])

        gui = [("audio", "/tmp/t.wav"), ("video", "/tmp/t.mp4"), ("mixer", ""), ("bluetooth", ""),
               ("archive", "/tmp/a.zip"), ("videoedit", ""), ("call", ""), ("mail", ""),
               ("clipboard", ""), ("vault", ""), ("ai", "")]
        for app, arg in gui:
            if app not in args.apps.split():
                continue
            m.run(as_palm(f"cd /tmp && {app} {arg} >/tmp/{app}.log 2>&1 &"))
            if app == "ai" and args.ollama:
                m.run(as_palm("OLLAMA_HOST=127.0.0.1:11434 ollama serve >/tmp/ollama.log 2>&1 &"))
                out, st = m.run(as_palm("sleep 3; ollama pull qwen3:0.6b 2>&1 | tail -2; "
                                        "timeout 300 ollama run qwen3:0.6b --think=false Say hello in five words. 2>&1 | tail -3"), 900)
                print(f"  ....  ollama pull + run (exit {st}): " + out.strip().replace("\n", " | ")[-300:])
                m.check("ollama serves qwen3:0.6b and answers", st == 0 and len(out.strip()) > 0, out)
            time.sleep(6)
            w, h, rgb = m.screen(shot(f"{app}.png"))
            alive, _ = m.run(f"ps -o args | grep -c '^{app}' || true")
            log, _ = m.run(f"tail -5 /tmp/{app}.log")
            print(f"  ....  {app}: runtime-{app}.png, {tb.colours(w, h, rgb)} colours, running={alive.strip()}; log: "
                  + log.strip().replace("\n", " | ")[-300:])
            if app == "audio":
                start = wav_size(wav)
                m.key("spc")
                time.sleep(4)
                print(f"  ....  hda-out.wav peak after Space in audio: {wav_peak(wav, start)}")
            m.run(f"pkill -x {app}; true")
            time.sleep(1)

        # Logging out (SUPER+SHIFT+E) ends the session, and the session
        # hooks with it.
        m.key("meta_l", "shift", "e")
        ok, out = tb.wait_for(m, "ps -o user,args | grep -E '^ *palm ' || true", r"\A\s*\Z", 20)
        m.check("logging out ends the session's PipeWire too (no process of palm's left)", ok, out)

        m.send("poweroff")
        m.expect(r"palm-init: powering off", 20)
        try:
            m.proc.wait(30)
        except subprocess.TimeoutExpired:
            pass
    finally:
        m.close()
        httpd.shutdown()
    return m.failures


if __name__ == "__main__":
    failures = main()
    print(f"test-runtime: {'all passed' if not failures else f'{len(failures)} failed: ' + ', '.join(failures)}")
    sys.exit(1 if failures else 0)
