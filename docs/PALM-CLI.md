# `palm` — one command surface, designed for agents

A single CLI through which a coding agent can operate every part of Palmy:
the window manager, the applications, the system state, and eventually the
identity and cloud layer. Humans use it too, but they are the second audience.

This is the design, and part of it has shipped. The convention is
`apps/kit/cli.odin` (`kit.cli`, documented for application authors in
`apps/APPS.md`); the dispatcher is `apps/palm`; and 17 of the 37 nouns in its
`NOUNS` table are converted — see *Where it stands* below for which. The rest of
this document is the design those follow and the remaining applications are
being brought up to; where the code and this text disagree, the code is what
runs.

## The principle

**Every application is a library with two front ends.** The GUI is one. The
CLI is the other, and it is not a reduced version — anything a person can do
in the window, an agent can do from a command, with the same code underneath.

That is the opposite of wrapping. A wrapper re-implements a subset in shell
and drifts from the real behaviour; two front ends over one core cannot drift,
because there is only one implementation of what the application actually does.

Several apps here are already shaped this way without it being a policy.
`apps/mailcore` is headless by construction — it is an engine, and the mail
GUI is a separate program reading the Maildir it writes. `apps/sheets` keeps
its formula engine in `eval.odin` with the grid drawn on top. `apps/docs`
separates `model.odin` and `layout.odin` from `ui.odin`, which is why
`--convert` can produce a PDF with no window open.

Others are not, and the inventory shows it plainly. Taking the flags each app
invented for itself:

| | |
| --- | --- |
| rich already | `mailcore` (33 flags), `torrent` (24), `call` (22), `chat`, `docs`, `money` |
| nearly nothing | `maps`, `reader`, `shop`, `launcher`, `files`, `notes`, `calendar` |

and the conventions have diverged: `--selftest` against `--self-test` (`call`
accepts both), `--shot` against `--export-png`, `--help` present in about a
dozen of forty. Each was a reasonable local choice; together they are not a
surface anything can be built on.

So the work is two things, and the second is the larger: a shared convention,
and then every application brought up to it.

## Why not just scripts

Omarchy, which this machine runs, has arrived at a good shape over 446
commands: `omarchy-<noun>-<verb>` scripts, each carrying metadata in comments
near the top —

```bash
# omarchy:summary=Adjust output volume and show the Omarchy OSD
# omarchy:args=<raise|lower|mute-toggle|+N|-N>
# omarchy:examples=omarchy audio output volume raise | ...
```

— and a single `omarchy` dispatcher that discovers them, routes
`omarchy audio output volume raise` to the right script, and can print the
whole surface with `omarchy commands --json`.

Adopt that wholesale. It is simple, each command stays independently runnable
and testable, and adding one is adding a file.

The thing it does not solve is that its *output* is for people. `omarchy
commands --json` describes the commands; the commands themselves print prose.
An agent then parses English, which is where agent tooling usually starts
failing — quietly, on the day a message changes.

## What an agent needs that a person does not

**Structured results, not just a structured index.** Every command takes
`--json` and emits a documented object. `palm audio status --json` returns
sinks and volumes; it does not return `Volume is now 40%`.

**A machine-readable surface.** `palm schema` emits the entire command tree as
JSON — nouns, verbs, argument types, enumerated values, the output schema, and
the side-effect class. An agent can plan from it instead of discovering
commands by trial.

**A declared side-effect class per command**, because the useful question
before running something is *can I retry this, and what does it touch*:

| class | meaning |
| --- | --- |
| `read` | no state changes; always safe |
| `idempotent` | converges on a state; safe to repeat |
| `mutate` | changes state; repeating is not the same as running once |
| `destructive` | loses data or is hard to undo; refuses without `--yes` |
| `intent` | deliberately does nothing but log what it would have done |

That last class is not a joke. Power and session actions in this project
already behave that way: `apps/power` logs `systemctl reboot` and executes
nothing, so a demo script driving the UI cannot reboot the machine. `palm`
keeps that property rather than quietly becoming the way around it.

**Refusal instead of prompting.** A destructive command without `--yes` exits
non-zero with a machine-readable reason. It never blocks on a TTY read, which
is how agent pipelines hang.

**Stable exit codes**, so failure can be handled without reading text:

```
0  ok
2  usage error
3  not found
4  refused: needs --yes
5  refused: out of scope for this identity
6  unavailable: the thing it talks to is not running
7  failed
```

**`--dry-run` on everything that mutates**, printing the same JSON the real run
would, plus what it would change.

## The surface

Nouns follow the system, not the source tree.

```
palm app        list | info | launch | kill
palm window     list | focus | move | resize | fullscreen | close
palm workspace  list | switch | move-window
palm theme      list | get | set | tokens
palm display    list | info | scale
palm audio      status | output | input | volume | mute
palm net        status | wifi list                 # read-only, see below
palm power      status | lock | suspend | reboot   # intent class
palm capture    screenshot | record                # headless by default
palm notify     send | list | dismiss

palm mail       folders | list | read | search | compose | send
palm files      list | stat | find | open
palm notes      list | read | write | search
palm calendar   list | add | next
palm vault      list | get | add                   # scoped, see below
palm money      accounts | import | budget
palm reader     library | open | position
palm torrent    list | add | pause | remove
palm ai         models | prompt | scope

palm pkg        list | search | install | remove | sync | diff | rollback
palm identity   list | current | switch | link | scope
palm dev        build | test | parity | record | lint
palm schema     the whole surface as JSON
palm commands   the command index, Omarchy-compatible
palm audit      what has been run, and by what
```

## Scope, which is the point

The README's identity model says an assistant scoped to one identity, asked
for another's data, should fail — and that there should be an assertion that
says so and runs. `palm` is where that is enforced, because it is the only
door.

```sh
PALM_IDENTITY=work palm mail list --json      # work mail
PALM_IDENTITY=work palm mail list --identity personal
# exit 5, {"error":"out of scope","identity":"work","requested":"personal"}
```

Scope is read from the environment and may only ever be *narrowed* by a flag,
never widened. A process started inside a scope cannot escape it by asking
nicely, which is the only version of this that means anything.

`palm vault` is the sharpest case. A secret is returned only to a caller
already inside the owning identity's scope, every access is written to the
audit log with the caller's identity, and there is no verb that lists secrets
across identities at all — not gated, absent.

The other half is that a secret *given* to a command is not repeated back. A
parameter declared `secret` (`--password`, `--token`) is shown as
`<redacted>` in the audit log, in the `--json` result and refusal, on stderr,
in `--help` and in the schema's examples; the command itself still gets the
value.

## Safety rules that live in the code, not the docs

This project has already made these decisions in several places, and `palm`
must not become the hole in them.

- **Networking is read-only.** `palm net status` reports; there is no verb that
  disables the radio or drops a connection. `apps/network` already routes
  `nmcli radio wifi off` and `nmcli device wifi connect` through a logged
  intent that executes nothing, after a live command could have taken the
  machine off the network — and with it the session doing the work.
- **No `systemctl enable/disable/start/stop`** of `sddm`, `greetd`,
  `display-manager` or `ollama`. ollama is deliberately a user process here.
- **Power and session actions are `intent` class** and log what they would run.
- **Camera and microphone are never captured** by `palm capture`. Synthetic
  sources only, which is what every demo in this repo already uses.
- **`palm capture` records on a private headless compositor** by default —
  `apps/tools/headless-record.sh` — so an agent filming a demo cannot put a
  window on the user's screen or type into their session. The flaw that
  motivated this is documented: a shared compositor meant one agent's
  keystrokes landed in another's window and added slides to its deck.

## Testability

The surface being machine-readable makes the CLI testable in a way prose is
not:

- `palm schema` is itself asserted — every command it advertises exists, every
  example it ships parses, and every documented exit code is produced by
  something.
- Every `read` command runs in CI and must emit JSON matching its declared
  schema.
- Every `destructive` command is asserted to refuse without `--yes`, and the
  `intent` commands are asserted to execute nothing — the same trap
  `apps/power` already uses, with fake `systemctl`/`reboot` binaries on `PATH`
  writing to a sentinel file that must stay empty.
- The scope rule above gets the assertion the README asks for.
- `palm --selftest` runs every child with a private `$HOME` and XDG
  directories (a blind `clipboard list` must not read the real history) and
  under a timeout (`$PALM_SELFTEST_TIMEOUT`, 30 s): a read that never returns
  is reported as timed out and counted as unavailable, not left hanging.

## The shared convention

One implementation, in `apps/kit/cli.odin`, so forty applications cannot each invent
their own. An app declares its commands; the kit parses, validates, generates
`--help`, emits `--json`, honours `--dry-run`, and produces the exit codes
above. `palm schema` then introspects the same declarations, which is what
keeps the index and the behaviour from drifting apart.

Every binary accepts the same base flags, whatever else it takes:

```
--json          structured output on stdout, nothing else on stdout
--dry-run       for any mutating command
--yes           required by destructive commands
--help          generated from the declaration, never hand-written
--identity NAME narrow the scope, never widen it
```

Two rules that matter more than they look. **Machine output goes to stdout and
nothing else does** — progress, warnings and prose go to stderr, so a pipeline
never has to strip chatter out of a JSON document. And **`--selftest` is the
one existing convention to keep**, since every app already has it and the
counts are how this project has been judging its own work all along.

## Bringing forty applications up to it

The order is by what an agent would reach for first, not alphabetically:

1. **Already close** — `mailcore`, `torrent`, `docs`, `sheets`, `slides`,
   `money`, `chat`. Mostly renaming flags onto the convention and adding
   `--json`.
2. **Have an engine but no CLI over it** — `mail`, `calendar`, `notes`,
   `reader`, `vault`, `shop`, `maps`. The core is there; the commands are not.
3. **UI-shaped, needing a core to be lifted out** — `files`, `editor`,
   `image`, `clipboard`, `colorpick`, `emoji`. These are the real work, and
   lifting the core out is worth doing for its own sake: it is what makes them
   testable headlessly.
4. **System applets** — `audio`, `power`, `sysmon`, `network`, `bluetooth`,
   `screenshot`. Small surfaces, and the safety rules above bite hardest here.

Where it stands: 17 of the 37 nouns in `apps/palm` are on the convention —
notes, sheets, power, drive, calendar, contacts, chat, forge, ai, notify,
index, settings, accounts, welcome, vault, browser, and mail, which routes to
`palm-mail` (`cloud/mail/palm-mail`; `mailcore` stays listed, off the
convention). `palm --selftest` holds each to the whole convention and prints
the count. Two outcomes of a read say nothing about the convention and are
accepted with the documented error object: *not found* (3), and
*unavailable* (6) — no server, daemon or session on this machine, which is
how the self-test runs. "Not signed in" is unavailable everywhere (drive,
chat, accounts, forge, mail, ai). An example may set the scope in front of
the binary (`PALM_IDENTITY=work drive ls`); one that composes commands
(`git clone $(forge clone-url …)`) is documentation, not an invocation, and
is not checked as one.

A thing is done when the GUI uses the same entry points the CLI does. If
`palm notes write` goes through a different path than typing in the window,
the two will diverge, and the CLI will be the one that rots.

## Open questions

- **How a long-running command reports progress** to an agent. *(Answered by
  what was built: NDJSON on **stderr** — `kit.cli_progress` writes one
  `{"progress": {...}}` object per line under `--json` — so stdout stays the
  one result document; a command that outlives its caller keeps a job record
  with `kit.cli_job_*`, which `kit.cli_jobs` reads back.)*
- **Whether the audit log is append-only on disk or in the account**, once the
  account exists.
- **Whether `palm` should be a dispatcher of separate binaries, as Omarchy is,
  or one binary with subcommands.** Separate binaries keep each app
  independently runnable and testable, which is worth a lot here; the
  dispatcher then exists for discovery and scope enforcement rather than for
  routing alone. *(Answered by what was built: `apps/palm` is a dispatcher of
  separate binaries, each of which answers `--schema` itself.)*
