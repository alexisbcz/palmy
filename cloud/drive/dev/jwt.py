#!/usr/bin/env python3
"""Mint an HS256 JWT for the local drive stack.

    jwt.py <secret> role=authenticated sub=<uuid> [palm_identity=<uuid>] [exp=<seconds>]

Local development only: real tokens come from Supabase Auth, and scoped
sessions (the palm_identity claim) from the accounts area's token exchange.
"""
import base64, hashlib, hmac, json, sys, time


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


secret = sys.argv[1].encode()
claims = {"iss": "palm-drive-dev", "iat": int(time.time())}
ttl = 3600 * 24 * 30
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    if k == "exp":
        ttl = int(v)
    else:
        claims[k] = v
claims["exp"] = int(time.time()) + ttl
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
body = b64(json.dumps(claims, separators=(",", ":")).encode())
sig = b64(hmac.new(secret, f"{head}.{body}".encode(), hashlib.sha256).digest())
print(f"{head}.{body}.{sig}")
