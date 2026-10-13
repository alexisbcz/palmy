# A greeter that authenticates, asks for a session, and then refuses to exit.
import json, os, socket, struct, time
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["GREETD_SOCK"])
def ask(o):
    b = json.dumps(o).encode(); s.sendall(struct.pack("=I", len(b)) + b)
    n = struct.unpack("=I", s.recv(4))[0]; return json.loads(s.recv(n))
if not os.path.exists("/run/test/stuck-done"):
    ask({"type": "create_session", "username": "palm"})
    ask({"type": "post_auth_message_response", "response": "palm"})
    ask({"type": "start_session", "cmd": ["/bin/sh", "-c", "touch /run/test/stuck-done"], "env": []})
time.sleep(60)
