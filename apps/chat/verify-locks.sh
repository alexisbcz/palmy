#!/usr/bin/env bash
# Statically verify the chat server's locking discipline.
#
#   bash apps/chat/verify-locks.sh
#
# The server has exactly one mutex, `srv.mu`, over all shared state, and its
# procedures come in two tiers that the names declare:
#
#   * `locked_*` runs with the lock already held. It never locks, never
#     unlocks, and never calls anything that does — not directly and not
#     through any chain of calls.
#   * everything else runs with the lock NOT held, and there are exactly four
#     places that take it.
#
# That discipline is what makes the ordering guarantee hold: broadcast happens
# inside the critical section, so the order every client observes is the order
# the server committed. It is also the thing a careless edit silently breaks —
# a `locked_*` procedure that reaches a `sync.lock` deadlocks on the first
# message, and reviewing for it by eye does not scale. So it is checked here,
# from the source, and this script is part of the test suite.
#
# What it does NOT prove, stated plainly so nobody reads more into a green
# run than is there:
#
#   * It follows direct, named calls only. A procedure passed as a value --
#     `thread.create_and_start_with_poly_data(c, conn_thread, ...)` -- is not
#     an edge in the graph, so the chain main -> conn_thread -> handle is
#     invisible to it. That is also why check 4 passes: `conn_thread` is never
#     seen as a callee of `main`. The server holds to the convention that
#     every call is direct; this script assumes it rather than checking it.
#   * Check 4 looks at the direct callees of the four lock-takers, not at
#     their transitive closure, and `NEUTRAL` is a hand-maintained list.
#   * It cannot see work done under the lock -- a long disk write inside a
#     `locked_*` procedure is a latency bug it will call clean.
#
# Exit status is 0 when the discipline holds and 1 when it does not.
set -uo pipefail

# Every .odin file in the server package, not just main.odin: a `locked_*`
# procedure added in a second file would otherwise go unanalysed.
if [ $# -gt 0 ]; then
  SRCS="$*"
else
  SRCS="$(cd "$(dirname "$0")" && pwd)/server"/*.odin
fi
for f in $SRCS; do
  [ -f "$f" ] || { echo "no such file: $f"; exit 1; }
done

# The four, by name. `main` holds the accept loop.
EXPECTED="${EXPECTED:-boot drop_conn handle main}"

# shellcheck disable=SC2086
python3 - "$EXPECTED" $SRCS <<'PY'
import re, sys

expected, src_paths = sys.argv[1].split(), sys.argv[2:]

# --- normalise away comments and string literals, once, up front ----------
#
# Doing this before anything else — rather than per line, after the fact —
# is what makes the rest exact. A `//` inside a string literal, a `}` inside a
# block comment and a backtick raw string spanning lines each used to truncate
# a procedure's body silently, and everything after the truncation went
# unexamined: a miss, not a false positive.
def strip(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append('"')
            i += 1
            while i < n and text[i] != '"':
                if text[i] == '\\':
                    i += 1
                i += 1
            out.append('"')
            i += 1
        elif c == '`':
            out.append('`')
            i += 1
            while i < n and text[i] != '`':
                out.append('\n' if text[i] == '\n' else ' ')
                i += 1
            out.append('`')
            i += 1
        elif c == "'":
            out.append("'")
            i += 1
            while i < n and text[i] != "'":
                if text[i] == '\\':
                    i += 1
                i += 1
            out.append("'")
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != '\n':
                i += 1
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if text[i] == '\n':
                        out.append('\n')
                    i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)

lines = []
for pth in src_paths:
    lines.extend(strip(open(pth).read()).split("\n"))

# --- carve the file into top-level procedures ------------------------------
#
# Odin has no overloading to worry about here and every procedure in this file
# starts at column 0 as `name :: proc`, so a flat scan is exact rather than
# approximate. A procedure's body runs to the next column-0 `}`.
decl = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*) :: proc\b')
procs, order = {}, []
cur = None
for ln in lines:
    m = decl.match(ln)
    if m:
        cur = m.group(1)
        procs[cur] = []
        order.append(cur)
        continue
    if cur is not None:
        if ln == "}":
            procs[cur].append(ln)
            cur = None
            continue
        procs[cur].append(ln)

if not procs:
    print("verify-locks: parsed no procedures out of", ", ".join(src_paths))
    sys.exit(1)

def code(name):
    # Already stripped of comments and literals above.
    return "\n".join(procs.get(name, []))

names = set(procs)
call = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\(')

def callees(name):
    return {c for c in call.findall(code(name)) if c in names and c != name}

# --- 1. who takes the lock -------------------------------------------------
# Every way core:sync can take this mutex, not just `sync.lock`. `mutex_lock`
# and `guard` are the same lock by another name, and a `locked_*` procedure
# calling either is exactly the deadlock this script exists to rule out.
SYNC = r'\bsync\.(lock|unlock|try_lock|mutex_lock|mutex_unlock|try_mutex_lock|guard)\b'
MU = re.compile(SYNC + r'[^\n]*srv\.mu')
ANY_SYNC = re.compile(SYNC)

takers = sorted(n for n in procs if MU.search(code(n)))
fails = []

if takers != sorted(expected):
    fails.append("the set of lock-taking procedures changed:\n"
                 "    expected: %s\n    found:    %s" % (", ".join(sorted(expected)), ", ".join(takers)))
else:
    print("ok   exactly %d procedures take srv.mu: %s" % (len(takers), ", ".join(takers)))

# --- 2. each takes it once, in one place -----------------------------------
for t in takers:
    n = len(re.findall(r'\bsync\.(lock|mutex_lock|guard)\b[^\n]*srv\.mu', code(t)))
    if n != 1:
        fails.append("%s calls sync.lock %d times; each lock-taker takes it exactly once" % (t, n))
if not fails:
    print("ok   each of them locks exactly once")

# --- 3. no locked_* procedure can reach a lock -----------------------------
#
# Transitively: a locked_* procedure that calls something that calls `handle`
# is just as deadlocked as one that calls sync.lock itself.
def reaches(start, targets):
    seen, stack = set(), [start]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        for c in callees(n):
            if c in targets:
                return c, n
            stack.append(c)
    return None, None

locked = [n for n in order if n.startswith("locked_")]
bad = 0
for n in locked:
    if ANY_SYNC.search(code(n)):
        fails.append("%s touches sync directly; locked_* runs with the lock already held" % n)
        bad += 1
        continue
    hit, via = reaches(n, set(takers))
    if hit:
        fails.append("%s can reach %s (which takes the lock) via %s" % (n, hit, via))
        bad += 1
if bad == 0:
    print("ok   none of the %d locked_* procedures can reach a lock" % len(locked))

# --- 4. the lock-takers call only locked_* across the boundary -------------
#
# This is the other half: a lock-taker that calls an ordinary procedure which
# then reads shared state without the lock is a race rather than a deadlock.
# These own nothing shared, and are listed so adding a new one is a deliberate
# act. Two notes on the list:
#
#   * `stage_attach` is the one entry that is NOT state-free in the trivial
#     sense: it writes a file. It is here because it is called from `handle`
#     *before* the lock is taken, deliberately, so a 512 KiB decode and disk
#     write do not happen inside the critical section. It reads `srv.files`,
#     which `boot` writes once before any connection thread exists, and it
#     writes a path named by the connection's own id and counter. This script
#     cannot tell "called before the lock" from "called inside it", so that
#     distinction is carried here rather than checked.
#   * `safe_component`, `clean_mime` and `trim_text` are pure.
NEUTRAL = {"note", "log_line", "log_chan", "log_msg", "log_edit", "log_delete",
           "log_react", "log_read", "clean_nick", "default_dir", "read_key",
           "safe_component", "clean_mime", "trim_text", "stage_attach"}
import os
NEUTRAL |= set(os.environ.get("EXTRA_NEUTRAL", "").split())
for t in takers:
    for c in sorted(callees(t)):
        if c.startswith("locked_") or c in NEUTRAL or c in takers:
            continue
        fails.append("%s calls %s, which is neither locked_* nor declared state-free" % (t, c))
if not any("declared state-free" in f for f in fails):
    print("ok   the lock-takers call only locked_* across the boundary")

# --- 5. a locked_* procedure never writes to a socket outside locked_send --
#
# Every write goes through locked_send, which is what makes a dead peer get
# reaped instead of retried.
for n in order:
    if n == "locked_send":
        continue
    if re.search(r'\bw\.send_frame\s*\(', code(n)):
        fails.append("%s writes to a socket directly; every send goes through locked_send" % n)
if not any("writes to a socket" in f for f in fails):
    print("ok   locked_send is the only thing that writes a frame")

if fails:
    print()
    for f in fails:
        print("FAIL " + f)
    print("\nthe locking discipline does not hold")
    sys.exit(1)

print("\nthe locking discipline holds")
PY
