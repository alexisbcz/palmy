import gzip, json, struct, sys
# convert editing-traces JSON to a flat binary: u32 count, then per patch: u32 pos, u32 del, u32 len, bytes
src, dst, endout = sys.argv[1], sys.argv[2], sys.argv[3]
t = json.load(gzip.open(src))
patches = [p for tx in t["txns"] for p in tx["patches"]]
with open(dst, "wb") as f:
    f.write(struct.pack("<I", len(patches)))
    for pos, d, ins in patches:
        b = ins.encode()
        f.write(struct.pack("<III", pos, d, len(b)))
        f.write(b)
open(endout, "w").write(t["endContent"])
print(len(patches), "patches", len(t["endContent"]), "chars")
