"""Probe palm-maild's two SMTP ports on 127.0.0.1 and print each reply.

    python3 -I smtp_probe.py mx-relay        RCPT to a non-local domain on the MX port
    python3 -I smtp_probe.py mx-unknown      RCPT to an unknown local mailbox
    python3 -I smtp_probe.py mx-deliver      a message from "outside" to bob and alice.work
    python3 -I smtp_probe.py submit TOKENFILE FROM RCPT...   submission with AUTH PLAIN

Only ever connects to 127.0.0.1. Exit status 0 when the server answered the
way the scenario expects.
"""
import os
import smtplib
import sys

MX = int(os.environ.get("PALM_SMTP_PORT", "55525"))
SUBMIT = int(os.environ.get("PALM_SUBMIT_PORT", "55587"))


def conn(port):
    s = smtplib.SMTP("127.0.0.1", port, timeout=10)
    code, msg = s.ehlo("probe.example")
    print(f"EHLO -> {code} {msg.decode().splitlines()[0]}")
    return s


def main():
    what = sys.argv[1]
    if what == "mx-relay":
        s = conn(MX)
        print("MAIL ->", *s.mail("someone@elsewhere.example"))
        code, msg = s.rcpt("victim@gmail.com")
        print("RCPT victim@gmail.com ->", code, msg.decode())
        s.quit()
        return 0 if code == 550 else 1
    if what == "mx-unknown":
        s = conn(MX)
        s.mail("someone@elsewhere.example")
        code, msg = s.rcpt("nobody@palm.test")
        print("RCPT nobody@palm.test ->", code, msg.decode())
        s.quit()
        return 0 if code == 550 else 1
    if what == "mx-deliver":
        s = conn(MX)
        body = (
            "From: Newsletter <news@elsewhere.example>\r\n"
            "To: bob@palm.test, alice.work@palm.test\r\n"
            "Subject: Inbound over the MX port\r\n"
            "Date: Mon, 19 Oct 2026 08:00:00 +0000\r\n"
            "Message-ID: <mx-1@elsewhere.example>\r\n"
            "\r\n"
            "This came in through palm-maild's MX listener, the way a peer\r\n"
            "server (or, later, the Resend inbound webhook) hands mail over.\r\n"
        )
        s.mail("news@elsewhere.example")
        for r in ("bob@palm.test", "alice.work@palm.test"):
            print(f"RCPT {r} ->", *s.rcpt(r))
        code, msg = s.data(body)
        print("DATA ->", code, msg.decode())
        s.quit()
        return 0 if code == 250 else 1
    if what == "submit":
        token = open(sys.argv[2]).read().strip()
        sender, rcpts = sys.argv[3], sys.argv[4:]
        s = conn(SUBMIT)
        s.login(sender, token)
        print("AUTH -> ok")
        s.mail(sender)
        for r in rcpts:
            print(f"RCPT {r} ->", *s.rcpt(r))
        code, msg = s.data(
            f"From: {sender}\r\nTo: {', '.join(rcpts)}\r\nSubject: Probe\r\n\r\nprobe\r\n"
        )
        print("DATA ->", code, msg.decode())
        s.quit()
        return 0 if code == 250 else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
