# Packages

Palmy does not need a new package manager. It needs a declarative layer
over the one that already works.

This is a design. None of it is built.

## Why not write one

A package manager is dependency solving, signature verification, mirror
selection, atomic transactions, and a decade of packaging. Arch already has
pacman, this machine already runs it — 1,115 packages installed, 189 of them
explicitly — and `yay` reaches the AUR. A new one would start with **zero
packages**, which is not a smaller problem than the one it was meant to solve.

Rollback, the part people assume is missing, is already here too: `snapper` is
configured on `/` and `limine-snapper-sync.service` is running, keeping boot
entries in step with the snapshot list. The machine can already be returned to
how it was before a change.

So the gap is not the mechanism. It is that **pacman's interface is for a
person at a terminal**, and Palmy's premise is a machine an agent can
operate.

## What is actually missing

**Declarative state.** `pacman -Qqe` lists 189 explicitly installed packages,
which is the closest thing to a description of what this machine *is* — but it
is the residue of a history of commands, not a statement of intent. There is no
file that says "this machine should have these things", so a machine cannot be
reproduced, diffed against its intent, or carried to a second device. That last
one is the whole point of the account and sub-identities in the README: your
machine should follow you.

**An interface an agent can use safely.** pacman prints prose for a human and
asks interactive questions. An agent parsing that is fragile in exactly the way
`docs/PALM-CLI.md` describes — it fails quietly on the day a message changes.
What is needed is the same contract as the rest of `palm`: `--json` output with
a stable schema, `--dry-run`, declared side-effect classes, refusal rather than
prompting, and documented exit codes.

**Per-identity profiles.** If a person has a work identity and a personal one,
they do not want the same tools in both. Packages are the coarsest version of
that and the easiest to get right first.

**Rollback bound to the operation.** Snapshots exist, but nothing ties one to
"the change `palm` just made". A snapshot taken before a mutation and named
after it turns undo from a manual rescue into an ordinary operation.

## The shape

```
palm pkg list                 what is installed, and which of it was explicit
palm pkg search <q>           repos and AUR
palm pkg info <name>
palm pkg install <names...>   mutate; snapshots first
palm pkg remove <names...>    destructive; refuses without --yes
palm pkg upgrade              mutate; never partial (see below)
palm pkg sync                 make the machine match the declaration
palm pkg diff                 how the machine differs from the declaration
palm pkg declare <names...>   add to the declaration without installing now
palm pkg rollback [snapshot]  back to before a named operation
```

The declaration is a plain file, per identity, listing wanted packages and the
profile they belong to. `sync` is the only verb that is interesting: it computes
the difference between the declaration and the machine, shows it under
`--dry-run`, and converges. That makes a machine's state reviewable in a diff
and reproducible on another device.

## The rules that keep it from breaking the machine

These are not style preferences. Each one is a way a package layer destroys a
working system.

- **Never a partial upgrade.** On Arch, `pacman -Sy <pkg>` — refreshing the
  database and installing one package against it — is the documented way to
  break a system, because it links new packages against old libraries. Only
  ever a full `-Syu`, or nothing. `palm pkg install` must refuse to refresh
  without upgrading.
- **Snapshot before every mutation**, named for the operation, so `rollback`
  has something to return to and the user can see what each snapshot was for.
- **Never remove a package something else depends on** without naming every
  dependant and requiring `--yes`.
- **Never touch the bootloader, the kernel, the display manager or the
  init system** without an explicit, separate confirmation. This repository
  already holds that line elsewhere: `apps/power` logs what it would run and
  executes nothing, and `apps/network` does the same for anything that would
  take the machine off the network.
- **sudo is asked for, never assumed.** It needs a password on this machine,
  and a tool that caches or embeds one is a worse problem than the one it
  solves.
- **An agent may not upgrade unattended.** A full upgrade can require manual
  intervention — a `.pacnew`, a keyring change, a kernel module mismatch — and
  an agent that hits one mid-upgrade leaves a half-configured machine. Upgrades
  are a thing a person starts.

## Verification

The hard part of testing this is that the honest test modifies a real system.
So:

- **Everything down to the final exec is testable headlessly**: the
  declaration parser, the diff between declaration and installed set, the
  dependency reasoning, the refusal rules, and the exact argv that *would* be
  run. Assert the argv — that a `-Sy` without `-u` is never emitted, that a
  removal with dependants refuses without `--yes`, that a protected package is
  refused — rather than running it.
- The `intent` class from `docs/PALM-CLI.md` applies: a command that would
  modify the system can log precisely what it would do and execute nothing.
  `apps/power`'s self-test is the pattern — fake `pacman` and `sudo` binaries
  on `PATH` that write to a sentinel file, with the sentinel asserted empty
  after driving every verb.
- Only then, a real install of something small and removable, done
  deliberately and once.
