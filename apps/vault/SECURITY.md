# What this protects against, and what it does not

This is a password manager written for a UI toolkit demo. The cryptography is
real, built out of `core:crypto` primitives and checked against the published
test vectors for every algorithm it uses. The threat model below is the honest
one. Read it before trusting it with anything you would miss.

## The construction

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

### Why these KDF parameters

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

---

## What it protects against

**An attacker who has the vault file and not the master password.** This is the
case the design is for: a stolen laptop, a backup on someone else's disk, a
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

**A secret left on the clipboard.** A copy arms a timer (default 20 s,
`--clip=`) and the UI shows it counting down. When it expires the selection is
cleared — but only if it is still *ours*, compared in constant time against what
was put there, so a clear never destroys something you copied in the meantime.
The clipboard is also cleared when the vault locks, idles, or exits.

**Your secrets leaving the machine.** There is no network code in this program.
No socket, no DNS, no breach check, no sync, no telemetry, no update check.

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
password-manager hint; most clipboard managers do not. The secret is handed to
`wl-copy` over a **pipe**, not as a command-line argument — `wl-copy -- <secret>`
would put the password in `/proc/<pid>/cmdline` for every process on the machine
to read for as long as wl-copy held the selection — but once the selection
exists it is readable by any Wayland client with data-device access.

**A forgotten master password.** There is no recovery, no reset, no escrow and
no second copy of the key. Forgetting it means the entries are gone. That is a
property of the design, not an oversight.

**Rollback.** Nothing here authenticates *which version* of your vault you are
being handed. An attacker who kept a copy of yesterday's file can put it back,
and it will open: the tag is still valid, because it was valid yesterday. There
is no counter, no chaining and no external anchor to notice with.

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

Round-tripping proves nothing: a vault sealed and opened by the same wrong
implementation opens perfectly. The published ciphertexts are the reason to
believe this is the algorithm it claims to be.

583 assertions in total, backed by 600,000 generated characters, 120,000
`rand_index` draws, 256 consecutive saves checked for a repeated nonce, and
every one of a real vault's 4,176 bytes flipped in turn. The run redirects
`XDG_DATA_HOME` to a scratch directory and stubs the clipboard, so it never
reads, writes or clears anything of yours.

There is also `vault --shot <dir>`, which renders every screen through palmy's
offscreen renderer against the same throwaway fixture — useful for checking a
layout without recording anything.
