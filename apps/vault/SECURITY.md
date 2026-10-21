# What this protects against, and what it does not

This is a password manager with two vaults behind one window. On a machine
that is not enrolled in a Palmy account it opens **the local vault**: one
encrypted file, no network code reachable from the window. On an enrolled
machine it opens **the account vault**: each identity's vaults, encrypted on
the device and synced through the Palmy cloud, which stores ciphertext it
cannot open (`cloud/docs/vault.md` has the whole design).

The cryptography is real, built out of `core:crypto` primitives and checked
against the published test vectors for every algorithm it uses. The threat
model below is the honest one. Read it before trusting it with anything you
would miss.

## The local vault file

```
master password
   │  Argon2id, m = 256 MiB, t = 3 passes, p = 4 lanes, 128-bit random salt
   ▼
256-bit key ──► ChaCha20-Poly1305, fresh 96-bit random nonce per save
                AAD = the 64-byte file header (version, cipher and KDF ids,
                      the KDF parameters, the salt, the nonce, the length)
   ▼
vault.pvz = header ‖ 128-bit tag ‖ ciphertext
```

The salt is per vault and does not change while the master password does not;
the key is derived once, at unlock. The nonce is drawn fresh from the OS CSPRNG
on **every** save, which is what makes a fixed key safe — reusing a nonce under
one key with this construction does not degrade it, it breaks it, leaking the
XOR of two plaintexts and the Poly1305 key.

AES-256-GCM is the alternative cipher the format allows (`aead_id = 2`) and is
selectable per vault; ChaCha20-Poly1305 is the default because it has no
timing-variable table lookups to worry about on a machine without AES-NI.

The plaintext inside the AEAD is padded to a 4 KiB boundary. The ciphertext
length is visible to anyone holding the file, and without padding it would say
to within a few bytes how many accounts you have.

### Why these KDF parameters (both vaults)

Measured on the machine this was written on, best of three per run across a
dozen runs: **433–561 ms per derivation**, and a full unlock (read the file,
derive, decrypt, parse) in essentially the same time — about half a second,
nearly all of it Argon2id.

The number that matters is not the time, it is the memory. An offline attacker
guessing the master password pays 256 MiB of fast random-access memory *per
concurrent guess*. A 24 GB GPU therefore runs about 90 guesses at a time rather
than the tens of thousands it would manage against a hash with no memory cost,
and the pass count on top of that fixes the time per guess. Trading memory for
time is possible but Argon2id is designed so it costs you more than it saves.

Half a second is a cost a person pays a few times a day and an attacker pays on
every guess. That is the whole trade, and it is why the default is not faster.

Two things to know about it:

- The parameters live in **every vault's header**, not only in this source. The
  default can be raised later and old vaults still open; changing the master
  password re-derives at whatever the current default is, so a vault is
  upgraded by rotating its password.
- A header arriving from disk is an attacker's choice, so the parameters are
  bounds-checked (`m ≤ 4 GiB`, `t ≤ 64`, `p ≤ 64`, `m ≥ 8p`) before Argon2id is
  called. A hostile file gets an error, not a 64 GiB allocation.
- Odin's `argon2id` is single-threaded, so `p = 4` defines the lane structure
  (and therefore the digest) without making the derivation faster here. It is
  the RFC 9106 memory-constrained lane count.

### Authenticated, so tampering is refused

The header is the AEAD's additional authenticated data. Every byte of a vault
file is therefore covered by the tag, including the recorded KDF parameters and
the nonce. `vault --selftest` flips **every single byte of a real vault, one at
a time**, and asserts all 4,176 of them are refused.

There is no partial decryption anywhere in the code. `vault_unseal` either
returns a plaintext whose tag verified or returns an error and nothing else.
There is no recovery mode and no "best effort" path, because a password manager
that hands back a plaintext it could not authenticate is handing back whatever
an attacker wrote into it.

A wrong master password and a tampered file produce the **same** error message,
because the AEAD genuinely cannot tell them apart.

### Changing the master password cannot brick the vault

The re-keyed vault is built in memory under a new salt and a new key, written to
a sibling temporary file, `fsync`ed, and then `rename(2)`d over the original.
`rename` within a directory is atomic, so at every instant the vault path names
either the complete old file or the complete new one. The old key is dropped
only after the new file is in place. The self-test performs an interrupted
change — the new file written and fsynced, the process "dying" before the
rename — and asserts the original vault is byte-for-byte unchanged and still
opens with the original password.

Every ordinary save takes the same path. There is no code anywhere in this app
that writes into an existing vault file.

### The generator

Characters are drawn from the alphabet by **rejection sampling** over
`crypto.rand_bytes`, not by taking a byte modulo the alphabet size. With the
90-character default alphabet, `byte % 90` would make the first 76 characters
come up three times per 256 draws and the last 14 only twice — a 50% excess
across most of the alphabet. The self-test draws 600,000 characters and asserts
the worst bin is within 10% of the mean and that chi-square over 89 degrees of
freedom stays under 160.

The entropy figure beside a generated password is exact: a uniform draw of *n*
characters from an alphabet of *a* is *n*·log2(*a*) bits, and the draw really is
uniform. The figure beside a password **you** typed is only an upper bound on a
random string of that shape — "Summer2024!" scores 72 bits by that measure and
is cracked instantly. The UI says so rather than implying the number means more
than it does.

## The account vault

```
master password ──Argon2id (the parameters above)──┐
Secret Key (128 bits, on the device) ──HKDF────────┴─HKDF─► account unlock key
   account unlock key ─wraps─► account key ─wraps─► each identity's keys
   identity keys (X25519 + ML-KEM-768, Ed25519) ─seal─► vault keys
   vault key ─wraps─► item keys ─encrypt─► items (every field, padded to 512 bytes)
```

Every symmetric layer is XChaCha20-Poly1305 with a random 192-bit nonce and a
context string naming the row it belongs to as associated data; every key
sealed to an identity uses X25519 and ML-KEM-768 together. Shares are signed
with the sharing identity's Ed25519 key over every field of the share row.

**The Secret Key** is generated on the first device, kept in
`account/device.json` (0600) on each enrolled device, printed once for an
emergency kit, and never sent to the server. It is what makes a copy of the
database worthless to someone who also guesses the master password: they need
128 more bits they do not have. It does **not** protect this disk from a
thief: the Secret Key sits next to the cache, so a stolen, powered-off laptop
is protected by the master password and Argon2id alone, exactly like the
local vault file. (1Password makes the same trade.)

**What the server sees** is listed in `cloud/docs/vault.md` ("What the server
sees"): ids, which identity owns how many items, revisions and timestamps,
padded sizes, public keys, KDF parameters, and who shares with whom. Titles,
URLs, usernames, passwords, notes, tags, item types and vault names are all
inside the encryption. A `pg_dump` of the vault tables after the end-to-end
demo is searched for 20 known strings; none appear.

---

## What it protects against

**An attacker who has the vault file and not the master password** (local
vault), **or the whole server database** (account vault). The account vault
adds the Secret Key: the server's copy cannot be attacked by guessing the
password at all. For the local file, this is the case the design is for: a stolen laptop, a backup on someone else's disk, a
synced folder, a file recovered from a wiped drive. They get a 64-byte header,
a tag, and padded ciphertext. Breaking it means guessing the master password at
256 MiB and half a second per attempt, or breaking ChaCha20-Poly1305.

**An attacker who modifies the vault file.** Detected and refused, every byte of
it, including the KDF parameters — they cannot downgrade your vault to a cheap
KDF and hand it back to you.

**Another account on the same machine reading the file.** The vault directory is
created `0700` and the file `0600`.

**Someone who walks up to an unlocked session.** The vault locks itself after
an idle timeout (default 300 s, `--idle=`) and on demand with Ctrl L, dropping
the key and freeing every decrypted string. It locks on exit.

**A secret left on the clipboard.** Copies go through palmy's own clipboard
client, served from this process's memory, so the secret never passes through
another program. A copy arms a timer (default 20 s, `--clip=`) and the UI
shows it counting down. When it expires the selection is
cleared — but only if it is still *ours*, compared in constant time against what
was put there, so a clear never destroys something you copied in the meantime.
The clipboard is also cleared when the vault locks, idles, or exits.

**How those two timers fire.** Both are deadlines on a
monotonic clock: the window sleeps until the next one and palmy's `wake_after`
runs one frame at that instant. On headless sway with the window idle and
unfocused, they were measured firing 1–3 ms after their deadline. They also fire
while the window is on a workspace that is not shown: the compositor then
withholds frame callbacks, and palmy runs a logic-only frame (app code, no
paint) when a wake falls due. Measured with the workspace hidden right after a
copy: the clipboard clear 7.0 ms and the idle lock 7.9 ms after their
deadlines, and `wl-paste` empty afterwards. Before palmy did that, the same run
left the secret pasteable 18 s past its deadline. Not yet measured on a
compositor that throttles covered windows rather than withholding callbacks
entirely, or on X11.

**The server reading or changing your vault.** It holds ciphertext under keys
it never sees. It cannot add an item to a vault (it has no vault key), cannot
swap a share's key for one of its own (the share is signed and the signature
checked before anything opens), cannot move an item's ciphertext to another
row or rewrite its revision (the associated data binds both), and cannot hand
a device an older revision of an item it has already seen (refused, and
reported). Its write path refuses an item key wrapped under a vault key that
was rotated after a revocation.

**Another identity, another person, or an assistant reading what is not
theirs.** Row-level security on every vault table (pgTAP:
`cloud/supabase/tests/vault_*.sql`), and for anyone outside the account the
cryptography as well. An assistant's delegated session receives nothing at
all from the vault tables, not even ciphertext, and the CLI refuses to run
under one.

**Your secrets leaving the machine, beyond sync.** The local vault has no
network code reachable from it: no socket, no DNS, no breach check, no
telemetry, no update check. The account vault talks to the Palmy cloud
and nothing else, and sends only ciphertext. The breach check is off by
default and, when the person runs it, sends five hex digits of each
password's SHA-1 to Have I Been Pwned and nothing more.

**A web vault serving you hostile code.** There is no web vault. The client is
this binary; the server delivers data, never code, so a compromised server
cannot ship a version of the app that leaks the master password -- the
attack that makes a browser-based vault only as trustworthy as its server on
the day you load it.

---

## What it does not protect against

**An attacker who can read this process's memory.** While the vault is
unlocked, the key and every password are in the heap in plaintext. Another
process running as your user can read them with `ptrace` or `/proc/<pid>/mem`.
Nothing in userspace fixes this.

**The swap file, or a hibernation image.** **Memory is not locked.** This
program does not call `mlock`, because the default `RLIMIT_MEMLOCK` on this
machine is far smaller than the 256 MiB Argon2id needs and raising it requires
privilege the app does not have and should not ask for. The kernel is therefore
free to write the key, the plaintext vault, and the master password you typed
out to swap at any moment, and `zero_explicit` cannot reach a page that has
already been paged out. Encrypted swap, or no swap, is the mitigation, and it is
outside this program.

What zeroizing *does* do, and its limits: locking overwrites the key with
`crypto.zero_explicit` (which the compiler may not elide) and zeroes every
secret string — passwords, notes, TOTP seeds, password history — before freeing
it. The sealed plaintext is wiped as soon as it is sealed. What cannot be
guaranteed is that no copy survives: the text field you typed the master
password into is wiped, but anything the allocator, the kernel, or a reallocated
`[dynamic]u8`'s old backing store copied along the way is out of reach. Treat
zeroizing as closing a window, not as proof the room is empty.

**A keylogger, or a compromised compositor.** Wayland does not let an ordinary
client read another's input, but anything with access to your seat, your
`XDG_RUNTIME_DIR`, or an input device sees the master password as you type it.

**Any kind of malware running as you.** It can read the vault file, read this
process's memory, log your keys, or simply replace the binary. There is no
defence here against code already running as your user.

**Traffic analysis of the file.** The padding hides the vault's size to 4 KiB.
The file's modification time still says when you last changed something, and its
size still bounds how much is in it.

**Clipboard history managers.** When this app puts a password on the Wayland
selection, anything watching the clipboard can capture it. This app's sibling
`apps/clipboard` deliberately skips selections that advertise a
password-manager hint; palmy's clipboard client does not yet offer that hint
(`x-kde-passwordManagerHint`), which is a gap in palmy, not something this app
can add from outside. Once the selection exists it is readable by any Wayland
client with data-device access. When there is no window to serve from, the
fallback is `wl-copy`, given the secret over a **pipe**, never as an argument
(`wl-copy -- <secret>` would put it in `/proc/<pid>/cmdline`).

**A forgotten master password.** There is no recovery, no reset, no escrow and
no second copy of the key. Forgetting it means the entries are gone. In the
account vault, losing every device *and* the emergency kit's Secret Key is
the same. Recovery codes and a recovery contact are designed
(`cloud/docs/vault.md`, "Recovery") and not built; each would be one more way
in, which is why they are the person's choice.

**What a revoked grantee already read.** Revoking a share stops the rows
reaching them and the client rotates the keys, so nothing written afterwards
opens under the keys they had. What they decrypted before, they may have
kept. The vault flags those items "exposed" and password health tells you to
change them at the site; that is the only real remedy.

**A device you lost while it was unlocked, or that was compromised.** It holds
the Secret Key and, while unlocked, every key. Revoking its session stops it
syncing; it cannot take back what it holds. Change the master password, and
treat its items as exposed.

**What the server can still see or do.** It sees the metadata in the table in
`cloud/docs/vault.md`: how many items each identity has, when they change, and
who shares with whom. It can withhold or delete your ciphertext (other
devices and an export are the backup). It can refuse to deliver a revocation
to a grantee's device, which only matters for what that device already had.

**Separation between your own identities against your own devices.** One
account key wraps every identity's keys, so a device that knows the master
password and the Secret Key could derive all of them if it had their rows.
Between your identities, the separation is the database's (a device scoped to
"work" never receives "personal"'s rows); against everyone else, it is
cryptographic.

**Autofill against programs running as you.** The socket checks the peer's
user, pairs only with the person's approval and asks before every fill, but a
program running as you can read the browser's profile (and its pairing key),
ptrace the browser or this process, or replace the browser binary. Pairing
and confirmation make that visible; they are not a sandbox.

**Autofill against web pages** (the browser's side, cloud/docs/vault.md).
The browser names the top-level origin its engine host reports — never a
frame's, never one the page states — and the host checks it again before a
fill reaches the page; a page that navigated meanwhile gets nothing. Fields
in iframes are never reported or filled. A form that posts to another origin
is not filled. A page reads empty fields until the person picks a login, and
the password reaches the page only as the field's value. What this cannot
stop: once a field holds the password, script on that origin can read it —
the origin the login was saved for is trusted with it, as in every browser;
a site with an XSS hole hands it to the attacker after a fill. Pages see
`input` events with no data and `change`; nothing names the vault. A save or
update offered after a submit carries what the page submitted; the person
decides, and an update never tells the browser whether the stored password
was the same (that would let a paired program test guesses unasked).

**Post-quantum, partly.** Keys sealed to identities use ML-KEM-768 alongside
X25519, so recorded ciphertext is not opened by a future quantum computer
breaking X25519 alone. Signatures (Ed25519) and the one-time device enrolment
box (X25519 only) are not post-quantum; a forged signature needs a quantum
computer *at the time of the attack*, and the enrolment box carries the Secret
Key, which is useless without the master password.

**Rollback.** For the local file, nothing authenticates *which version* you
are being handed: yesterday's copy, put back, opens. For the account vault, a
device refuses an older revision of any item it has already seen, but a
**new** device has no history to compare with, and a server could still hold
back a newer revision (withholding, not rollback, and indistinguishable from
the network being slow).

**Side channels beyond the ones named.** Secrets are compared with
`crypto.compare_constant_time`, never `==` on bytes. The search, the sort and
the UI are ordinary code and make no timing promises; they run on data already
decrypted in this process, so there is nothing there an attacker who cannot
already read the memory could learn.

---

## Where things are

| | |
| --- | --- |
| Vault | `~/.local/share/palmy-vault/default.pvz`, mode 0600 |
| Directory | `~/.local/share/palmy-vault/`, mode 0700 |
| Honours | `$XDG_DATA_HOME` |
| Another vault | `--vault=<path>`, or Ctrl O and pick one |
| Account vault cache | `~/.local/share/palmy-vault/account/cache.json` (ciphertext only), 0600 |
| Secret Key, device key | `~/.local/share/palmy-vault/account/device.json`, 0600 |
| Autofill socket | `$XDG_RUNTIME_DIR/palm-vault/autofill.sock`, directory 0700, socket 0600 |
| Autofill pairings | `~/.local/share/palmy-vault/autofill-pairs.json`, 0600 |
| Which directory, and why | `vault where`: `$XDG_DATA_HOME`, else `$HOME` only if this user owns it, else `/etc/passwd`'s home for this uid |

This app opens exactly two kinds of file: a vault it created, and a file you
explicitly chose in the dialog (whose magic it checks first). It does not read
`~/.password-store`, `~/.gnupg`, `~/.ssh`, browser profiles or
`~/.local/share/keyrings`, and it does not scan your home directory looking for
them.

## Checking it yourself

```sh
odin build apps/vault -collection:palmy=../palmy -collection:shadcn=../shadcn \
  -collection:kit=../apps/kit -o:speed -out:apps/vault/vault.bin
apps/vault/vault.bin --selftest
```

The vectors asserted, all transcribed into `vectors.odin` from the documents
rather than generated by this code:

| Algorithm | Source |
| --- | --- |
| Argon2id | RFC 9106 §5.3 |
| ChaCha20-Poly1305 | RFC 8439 §2.8.2, both directions |
| AES-256-GCM | NIST GCM specification, test case 16 |
| HMAC-SHA-1 | RFC 2202 cases 1–4, 6, 7 |
| HMAC-SHA-256 | RFC 4231 cases 1–4, 6, 7 |
| HMAC-SHA-512 | RFC 4231 case 2 |
| HOTP | RFC 4226 appendix D, counters 0–9 |
| TOTP | RFC 6238 appendix B, SHA-1/256/512 at six timestamps |
| base32 | RFC 4648 §10 |
| X25519 | RFC 7748 §6.1 |
| HKDF-SHA-256 | RFC 5869 A.1 |
| Ed25519 | RFC 8032 §7.1, test 1 |
| XChaCha20-Poly1305 | draft-irtf-cfrg-xchacha-03 A.3.1 |
| Argon2d (KeePass imports) | RFC 9106 §5.1 |

Round-tripping proves nothing: a vault sealed and opened by the same wrong
implementation opens perfectly. The published ciphertexts are the reason to
believe this is the algorithm it claims to be.

4,865 assertions in total, backed by 600,000 generated characters, 120,000
`rand_index` draws, 256 consecutive saves checked for a repeated nonce, every
one of a real vault's bytes flipped in turn, every byte of a wrap and every
seventh byte of a sealed key flipped in turn, an offline two-device account
with swapped, rewritten and substituted rows, KeePass files written by an
independent implementation, and the autofill protocol over a real socket. The
run redirects `XDG_DATA_HOME` to a scratch directory and stubs the clipboard,
so it never reads, writes or clears anything of yours, and makes no network
call. The KDF's cost is asserted on this thread's CPU time, not wall time, so
a loaded machine no longer fails it.

Against a live stack, `apps/vault/e2e.sh` runs the account vault end to end
(two devices, a conflict, sharing across identities and accounts,
revocation and rotation, an assistant's token, import, autofill, and a
`pg_dump` searched for plaintext): 87 checks.

There is also `vault --shot <dir>`, which renders every screen through palmy's
offscreen renderer against the same throwaway fixture — useful for checking a
layout without recording anything.
