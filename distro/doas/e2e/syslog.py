# A syslog that only writes down what it hears: binds the datagram socket
# glibc's syslog(3) sends to (argv[1]) and appends every message to argv[2].
import os, socket, sys

path, out = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.bind(path)
os.chmod(path, 0o666)
open(out, "a").close()
while True:
    msg = s.recv(8192)
    with open(out, "ab") as f:
        f.write(msg.rstrip(b"\0\n") + b"\n")
