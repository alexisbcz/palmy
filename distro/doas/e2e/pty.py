# Runs a command on a fresh pseudo-terminal, in its own session, and types
# answers at its password prompts: what a person at a terminal does, for
# doas and passwd, which read passwords from /dev/tty and never from stdin.
#
#   python3 pty.py [-a ANSWER]... [-t SECONDS] -- command [args...]
#
# Every prompt that ends in "password: " (any case) gets the next ANSWER and
# a newline; a prompt with no answer left gets end-of-input (ctrl-D). The
# transcript is printed, then a last line "pty: prompts=N exit=M".
import os, pty, select, sys, time

answers, timeout, i = [], 20.0, 1
while i < len(sys.argv) and sys.argv[i] != "--":
    if sys.argv[i] == "-a":
        answers.append(sys.argv[i + 1]); i += 2
    elif sys.argv[i] == "-t":
        timeout = float(sys.argv[i + 1]); i += 2
    else:
        sys.exit("usage: pty.py [-a ANSWER]... [-t SECONDS] -- command [args...]")
cmd = sys.argv[i + 1:]

pid, fd = pty.fork()  # the child is a session leader with the pty as its terminal
if pid == 0:
    os.execvp(cmd[0], cmd)

out, pending, prompts = b"", b"", 0
deadline = time.time() + timeout
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        pending += chunk
        if pending.lower().rstrip(b" ").endswith(b"password:"):
            prompts += 1
            pending = b""
            if answers:
                os.write(fd, answers.pop(0).encode() + b"\n")
            else:
                os.write(fd, b"\x04")
    else:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
else:
    os.kill(pid, 9)

_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
print("\npty: prompts=%d exit=%d" % (prompts, os.waitstatus_to_exitcode(status)))
