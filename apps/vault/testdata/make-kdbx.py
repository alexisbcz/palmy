"""Make the KeePass KDBX 4 fixtures in this directory with pykeepass (an
independent implementation, whose Argon2 is libargon2), in three cipher/KDF
combinations. Fake data only. Run: python3 -m venv kp && kp/bin/pip install
pykeepass && kp/bin/python -I make-kdbx.py <dir>"""
import sys, uuid, os
from pykeepass import create_database

out = sys.argv[1]
PW = "keepass-fixture-password"

CIPHERS = {"aes256": uuid.UUID("31c1f2e6-bf71-4350-be58-05216afc5aff").bytes,
           "chacha20": uuid.UUID("d6038a2b-8b6f-4cb5-a524-339a31dbb59a").bytes}
KDFS = {"argon2d": uuid.UUID("ef636ddf-8c29-444b-91f7-a9a403e30a0c").bytes,
        "argon2id": uuid.UUID("9e298b19-56db-4773-b23d-fc3ec6f0a1e6").bytes,
        "aeskdf": uuid.UUID("c9d9f39a-628a-4460-bf74-0d08c18a4fea").bytes}

def fill(kp):
    g = kp.add_group(kp.root_group, "Work")
    sub = kp.add_group(g, "Servers")
    e = kp.add_entry(kp.root_group, "Example Mail", "sample.user@example.com", "kp-mail-pass-Zx81!",
                     url="https://mail.example.com", notes="Line one\nLine <two> & three")
    e.otp = ("otpauth://totp/Example:sample?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=30&digits=6&algorithm=SHA1")
    e.set_custom_property("Recovery code", "RC-1234-5678", protect=True)
    e.tags = ["mail", "sample"]
    kp.add_entry(g, "Example Forge", "sample-dev", "kp-forge-pass-Qw77#", url="https://forge.example.net")
    kp.add_entry(sub, "Example Router", "admin", "kp-router-pass-Lm42$", url="http://192.0.2.1")
    kp.save()
    # A history: change the forge password and save again.
    f = kp.find_entries(title="Example Forge", first=True)
    f.save_history()
    f.password = "kp-forge-pass-NEW-99%"
    kp.save()
    trash = kp.add_entry(kp.root_group, "Deleted Thing", "x", "kp-deleted-pass")
    kp.trash_entry(trash)
    kp.save()

for name, (c, k) in {"argon2d-chacha20": ("chacha20", "argon2d"),
                     "argon2id-aes256": ("aes256", "argon2id"),
                     "aeskdf-aes256": ("aes256", "aeskdf")}.items():
    path = os.path.join(out, f"keepass-{name}.kdbx")
    kp = create_database(path, password=PW)
    h = kp.kdbx.header.value.dynamic_header
    h.cipher_id.data = c
    kd = h.kdf_parameters.data.dict
    kd["$UUID"].value = KDFS[k]
    if k == "aeskdf":
        import construct
        u = kd["$UUID"]; s = kd["S"]
        u.next_byte = 0x05
        r = construct.Container(type=0x05, key="R", value=1000, next_byte=0x42)
        s.value = os.urandom(32); s.next_byte = 0
        kd.clear(); kd["$UUID"] = u; kd["R"] = r; kd["S"] = s
    else:
        kd["M"].value = 1024 * 1024  # 1 MiB, so the test is fast
        kd["I"].value = 2
        kd["P"].value = 1
    kp.save()
    fill(kp)
    from pykeepass import PyKeePass
    chk = PyKeePass(path, password=PW)
    print(path, len(chk.entries), "entries; cipher", c, "kdf", k, "verified by reopening")
