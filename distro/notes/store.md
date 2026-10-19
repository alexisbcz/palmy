# Software and palmd — notes

Owner of this file: the agent that built `apps/store/` and `distro/palmd/`.

## What was built

- **palmd** (`distro/palmd/`, Odin, no collections): the root daemon. Service
  file `distro/palmd/palmd.service`, installed by the palmd package as
  `/etc/palm/services/palmd`, so removing the package removes the service.
  `palmd --selftest`, `palmd --test --sock ...` (unprivileged, any palm),
  `palmd --request '<json>'` (a one-shot client).
- **Software** (`apps/store/`, palmy + shadcn + kit): the window, `--demo`,
  `--shots <dir>`, the kit CLI (`store search|info|list|plan|install|remove|
  upgrade|update`) and `store --selftest`.
- **palm**: optional `category`, `icon`, `details` fields; sizes, `url`,
  `csize`, `installed_size`, `explicit` and (for `info`) `required_by` in the
  JSON; `download_size` and `size_change` in a plan; JSON progress lines on
  stderr under `--json`. 520 selftest assertions.
- **Packaging**: recipes `palmd` (hand-written) and `store` (generated); both
  in `palmy`; every recipe has a category, icon and details.
- **wm**: `SUPER+S` spawns `store` in the built-in config.

## Decisions

- **The protocol is greetd's framing**, as palm-login uses: a native u32
  length and a JSON object. One way of talking to a root daemon, not two.
- **Three requests, no queries.** Read-only questions are `palm --json` run by
  the user; a daemon that answers fewer questions has fewer ways to be wrong.
- **Unknown request fields are refused**, not ignored, so a client trying
  `"repo"` or `"root"` learns it cannot.
- **palm's argv is constant words plus validated names.** `--` is not used:
  palm's parser rejects it, and the name rule already forbids a leading `-`.
- **A plan has an id** (sha256 over the action, the names and palm's plan
  text). Apply plans again and refuses on a different id, with the new plan in
  the refusal, so the confirmed plan is the one that runs.
- **Authorization reads the files on every connection** (as palm-init and
  palm-login do — no NSS here), so editing `/etc/group` takes effect at the
  next connection. Wheel membership is the member list or the primary group
  in `/etc/passwd`; the peer's own gid is not consulted.
- **Busy, not queued.** A request while palm runs is answered `busy`; queued
  clicks that run minutes later are worse than a clear "try again".
- **A client that disconnects does not stop palm.** Half a transaction is
  worse than one nobody watches.
- **The log** is palmd's stderr, which palm-init writes to
  `/var/log/palmd.log` (`--log` overrides).
- **Software never removes the system.** `palmy`, `palmy-base`, palm,
  palmd, glibc, busybox, linux, palm-init and palm-login have no Remove; a
  dependency something still needs shows who needs it instead.
- **Unprivileged palm and the index cache.** palm as a user reads
  `/var/cache/palm` but cannot write it, so before the first `palm update`
  (Software's *Check for updates*, through palmd) each `palm list` fetches the
  index over http. It works; it is slower than it needs to be.

## For other areas

- **CONTRACT.md**: one new service (`palmd`) and one new socket
  (`/run/palmd.sock`, root 0666, peer-credential checked). Nothing existing
  changed.
- **palm**: `list`/`search`/`info --json` objects gained fields; none were
  removed or renamed. Progress on stderr appears only under `--json` outside
  the selftest.

## Verified

Host: `palm --selftest` 520/0, `palmd --selftest` 114/0 (a fake palm driven
through the real daemon: plan, stale and changed plan ids refused, progress
streamed, palm's error verbatim, busy, `--root=/` and `x;rm` refused, a user
removed from wheel refused at the next connection), `store --selftest` 72/0,
`wm --selftest` 116/0. Offscreen renders of every view and dialog stage on
demo data: `distro/build/store/01..17-*.png`.

QEMU (`distro/palmd/qemu-store.py`, OVMF, headless, image built by
`make -C distro` in this worktree, `make -C distro serve PORT=8091` with the
guest's `/etc/palm/repositories` pointed at it over the serial console):

- palmd ran as root from palm-init; `/run/palmd.sock` was `srw-rw-rw-`.
- Logged in as palm through the greeter; SUPER+S opened Software, which
  showed 38 packages and 33 installed from the image's palm database
  (`qemu-01-discover.png`, `qemu-02/03-installed*.png`).
- Install track from Discover: palmd's plan (track 0.1.0, download 561 kB,
  disk +1.4 MB) → Install → `track is installed`; `/usr/bin/track` existed and
  `/etc/palm/world` held `palmy track` (`qemu-04..07`). Its page listed
  `/usr/bin/track` from `palm info -L` (`qemu-08`). Remove → plan → confirm →
  removed; `/usr/bin/track` gone, world back to `palmy` (`qemu-09/10`).
- Live search "emoji" → install fonts-emoji, with palm's progress in the
  dialog, "Installing fonts-emoji 0.1.0, 2 of 2" (`qemu-12..15`).
- A calc 0.1.1 published on the host: *Check for updates* (palmd update) found
  it, *Update all* planned calc 0.1.0 → 0.1.1 and upgraded it (`qemu-16..19`).
- As root on the serial console, `palmd --request` with `--root=/`, `x;rm`,
  an extra `"repo"` field, and a made-up plan id: all refused, the first three
  as invalid (exit 2), the last with the current plan (exit 4); all logged.
- A user `guest` (uid 1001, not in wheel) added to `/etc/passwd` and
  `/etc/group`: `palmd --request '{"op":"update"}'` as guest was refused
  ("only root and members of group wheel may change the system"); added to
  wheel, the same request succeeded; removed again, refused again.
- `store search`, `store plan add emoji --json`, `store remove fonts-emoji`
  (refused without `--yes`, exit 4) and `--yes` (removed) as palm.
- The launcher lists Software (`qemu-20-launcher.png`).

## Not done

- No per-package icons beyond lucide names; no screenshots of applications on
  their pages; no ratings, no featured curation beyond a fixed list.
- palmd has no cancel: a running transaction finishes.
- Software polls palmd every 50 ms while a change runs rather than waking on
  the socket; palmy's frame loop has no fd watch to wake on.
