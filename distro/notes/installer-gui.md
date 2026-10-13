# The graphical installer (apps/installer) — notes

Owner: `apps/installer/`, `distro/locale/*/installer.msg`, this file.

## What exists

`installer`, a palmy app over install_core, following INSTALLER.md "What a
person does": a left rail of eight steps (Language, Keyboard, Time zone, Disk,
Account, Summary, Install, Done), a heading, the page, and a Back/Next bar.
It is the greeter's visual language: same dark tokens (copied from
`apps/greeter/main.odin`), Geist, lucide icons, shadcn buttons and inputs.

```
installer [--demo] [--demo-fail] [--dry-run] [--lang CODE]
installer --shots DIR      every page offscreen, en/fr/ar at 1280x800, en/ar at 1024x768 and 1920x1200
installer --selftest       flow, validation, demo install on its thread, RTL, catalogue coverage (132 checks)
python3 -I apps/installer/qemu-test.py [--lang-only]   the whole thing inside QEMU, ISO to installed disk
```

Build: `odin build apps/installer -o:speed -collection:palmy=palmy
-collection:kit=apps/kit -collection:shadcn=shadcn
-collection:install=distro/installer -out:distro/out/bin/installer` (also what
`distro/Makefile` does).

Files: `flow.odin` the state machine (can_leave / go_next / go_back / go_to,
the plan), `account.odin` the account rules, `backend.odin` the only code that
touches the system, `backend_core.odin` the only file importing install_core,
`demo.odin` the fabrications, `ui.odin` the frame, `pages.odin` the pages,
`tz.odin` the clock, `i18n.odin` the translation seam, `shot.odin`,
`selftest.odin`, `qemu-test.py`.

### Modes, and why the host is safe

- **real** only when *all* of: no `--demo`, euid 0, and `/etc/palm/keys`
  exists (a Palmframe system). Anywhere else it starts in **demo** and says so
  on stderr and with a red "Demo" badge in the rail. Demo disks are invented
  (`/dev/nvme0n1`, `/dev/vda`, a live USB stick, a 2 GB card), the install is
  `demo_install`, which only sleeps and reports, and every log line starts
  with `demo:`. The selftest checks that.
- The keyboard page's live switch (`apply_keyboard`) is a no-op in demo, and
  in real mode signals only a process whose `/proc/<pid>/comm` is `wm` (the
  parent when it is, else the first `wm`), never blindly the parent, which on
  a desktop would be a shell.
- `--dry-run` (real mode) passes `Options.dry_run` to the core: real disks,
  real layout switching, the install only described.
- `--shots` and `--selftest` use the demo backend only.

### The pages

- **Language** — six rows (native name, plus the name in the current UI
  language); choosing one calls `kit.i18n_set_language` and the next frame is
  translated. Unavailable languages (no catalogue or no font, from
  `core.list_languages`) are listed with "Not available: no font for this
  script is installed" and Next refuses them. Picking a language also
  preselects keyboard and zone (fr → fr + Europe/Paris, ar → ara +
  Africa/Cairo, ja → jp + Asia/Tokyo, …) until the user picks those by hand,
  and the followed layout is sent to the compositor too.
- **Keyboard** — searchable layout list, variant list, test field. A change
  settles for 250 ms, then `/etc/palm/keyboard` is written and the wm gets
  SIGHUP.
- **Time zone** — search over city / zone name / country, a card with the
  city, the date in the UI language (a `{weekday}, {day} {month} {year}`
  template per language), `Zone · abbreviation · UTC±hh:mm`, and the local
  time, from the zone's TZif via `core:time/timezone` (so DST is right).
- **Disk** — the erase-the-whole-disk statement first, then the disks with
  model, size (binary units), Removable / Has partitions badges; the live
  medium, read-only and < 4 GiB disks are shown greyed with the reason. When
  exactly one disk is usable it is preselected. Next opens a dialog naming the
  path, model and size ("Erase /dev/vda?", "VirtIO disk, 8.0 GiB"); **Cancel
  holds the focus, so Enter alone never erases**; choosing another disk
  withdraws the confirmation.
- **Account** — full name (optional; `:`/`,` refused for GECOS), user name
  (follows the full name — "Élodie Martin" → `elodie` — until typed into),
  computer name (default `palmframe`), password twice with a weak/fair/strong
  meter, "use the same password for root" (on by default; off shows two more
  fields). Problems appear under a field once it has been typed into, all of
  them when Next is pressed (and the keyboard goes to the first one).
- **Summary** — the disk to be erased in a red box, then every choice with a
  Change button back to its page; Install. If `core.validate` objects, its
  sentences are shown here verbatim and nothing starts.
- **Install** — current step name, whole-install percentage and bar, the
  seven steps ticked off, the latest message, and "Show details" for the log
  (the core's own lines through `Options.on_log`, follows the end). On
  failure: the error, the log unfolded, "Back to summary" and "Restart".
- **Done** — "Palmframe is installed", Restart now (`/sbin/reboot`).

Keyboard: Tab / Shift+Tab move focus (palmy), Up/Down/PageUp/PageDown move the
page's list selection, Enter is Next (or the focused button), Esc is Back
(or closes the dialog). Rail entries already visited are clickable until the
install starts; no way back after that.

Plan details: `efi_boot_entry` = `/sys/firmware/efi` exists; `packages` is
left empty (the core's default) except for Japanese, which adds `fonts-cjk`
(`{"palmframe", "fonts-cjk"}`), as distro/notes/live.md suggested.

### Right to left

palmy shapes Arabic and orders bidi text, and aligns a paragraph to its own
script's side, but its flex layout has no direction. The installer mirrors
itself: rows are opened with `hrow` and closed with `hend`, which reverses the
row's children (and swaps justify start/end) when `kit.i18n_is_rtl()`; text in
columns is aligned to the UI direction (`txt`); chevrons swap. Tab order
follows the mirrored order. Two bidi details, both in `i18n.odin`:

- a translation written in an RTL script gets a RIGHT-TO-LEFT MARK in front,
  so "GPT: قسم نظام EFI…" or "%s، %s…" is an RTL paragraph even though it
  starts with Latin;
- in RTL, every string argument of `trf` is wrapped in FSI…PDI, so
  "/dev/vda" inside an Arabic sentence is not drawn "dev/vda/".

## Translations

`distro/locale/{fr,de,es,ar,ja}/installer.msg`, 141 entries each, kit's
format with the same header keys as the greeter's catalogues (`language`,
`name`, `english`, `direction = rtl` for Arabic, Arabic's six-form plural
rule, `plural = 0` for Japanese). German and Spanish use the formal address.
The selftest scans the source for `tr("`, `trf("` and `N("` literals and
checks, per catalogue: it parses cleanly with `kit.i18n_parse`, names its
language, has every msgid translated, keeps `%` verbs and `{placeholders}`,
and has no stale entries.

Japanese is available on the live image (`fonts-cjk` is installed there;
`core.list_languages` finds it), so 日本語 is offered; on a system without a
CJK font the row says it is unavailable.

Not translated, because they are data: keyboard layout descriptions
(xkeyboard-config's English), region and country names (tzdata's
iso3166.tab), disk models, the core's log lines and `validate` problems.

## Where install_core differs from INSTALLER.md (followed, not changed)

- `Progress.fraction` is the whole installation's progress, not the step's;
  the bar uses it as is (the demo computes the same thing with its own step
  weights).
- `install_with(plan, Options, …)` and `Options.on_log` exist; the GUI uses
  them for the log view instead of logging progress messages.
- `Zone.country` is the country *name* ("France"); the rows show
  "France · Europe" and the search matches names.
- Arabic's code is `ar` (not `ar_EG`).
- `list_zones` includes `UTC`.

## Requests for others

- **palmy** (`palmy/layout.odin`, `measure`, ~line 235): a Text node's wrap
  width is capped at the width that node id had *last frame*
  (`wrap_w = min(wrap_w, hint)`). When the string at an id gets longer — a
  language switch, one validation message replacing another, a status line —
  a shrink-wrapped text in a row stays at the old width and breaks onto
  several lines, and never recovers. Reproduced before the workaround below
  with three runs in one process (`en_US`, then `fr_FR`, then `ar`): the
  Arabic "passwords do not match" line laid out at 72 px over two lines
  instead of 125 px on one; any two of the three alone were fine. The
  installer works around it (the whole tree is keyed by language, and row
  texts whose content changes are `flex-1` or `whitespace-nowrap`); other apps
  with changing labels will hit it. Suggest: drop the hint when the node's
  text differs from last frame's, or only use it when it is larger than the
  intrinsic width.
- **palmy**: a layout direction (or `flex-row-reverse`) would let the
  installer's `hrow`/`hend` mirroring go away; the greeter does the same by
  hand.
- **install_core**: `validate` problems are English sentences with the values
  baked in, so the GUI can only show them untranslated. A stable code per
  problem (plus its arguments) would let them be translated. The GUI checks
  the same rules itself first, in the user's language, so in practice the
  core's sentences are only seen if the two disagree.

## Verified

On the host (demo backend only, nothing touched):

- `installer --selftest`: 132 checks, 0 failed — flow (Next/Back/rail, the
  erase dialog, Enter not confirming, the plan), account rules (9 bad and 4
  good user names, 6 bad and 3 good host names, passwords, GECOS),
  strength, name suggestion, language defaults, search, Paris = UTC+2 CEST on
  2026-10-13, the demo install run on its worker thread to the Done page
  and failing with `demo_fail`, RTL mirroring measured offscreen, the five
  catalogues.
- `installer --shots distro/build/installer-gui`: 77 PNGs (11 pages × en, fr,
  ar at 1280x800; en and ar at 1024x768 and 1920x1200), all looked at.
- `make -C distro check-libs`: every binary links only glibc.

Inside QEMU only (`apps/installer/qemu-test.py`, live ISO rebuilt with
`make -C distro iso`, blank 8G qcow2 in distro/build/installer-gui/qemu/,
OVMF, headless, QMP keys and screendumps):

- The live session runs the installer in real mode (no Demo badge, the real
  base.lst and zone1970.tab, the disk list is `/dev/vda` "VirtIO disk 8.0 GiB"
  alone, preselected).
- English → Français → العربية: the screen re-renders translated and Arabic
  mirrored (`03-language-ar.png`).
- French: `/etc/palm/keyboard` became `layout = fr`, the wm logged
  "reloading (SIGHUP) … now fr", and the physical Q key typed `a` in the test
  field (`04-keyboard-fr.png`). Back to English switched it back to `us`.
- Disk: Enter on the dialog cancelled (Cancel has the focus); Tab, Enter
  erased.
- Account typed through QMP ("Ada Lovelace" → user `ada`), Summary, Install:
  the core partitioned, formatted, installed 33 packages, configured, wrote
  limine and `Boot0009 "Palmframe"`, unmounted — "installation finished" in
  about 6 s (local repository, all in guest RAM). Done page, Restart now
  ended the live machine (`-no-reboot`).
- The installed disk booted alone (`run-qemu.sh --disk`) to palm-login and
  the greeter showing "Ada Lovelace · ada · uid 1000" on host `palmframe`,
  its clock at New York time (`13-installed-greeter.png`).

Not done / not verified: logging in to the installed system, an install in a
language other than English end to end (the French and Arabic screens were
checked, and the keyboard switch, but the account was typed with `us`),
BIOS boot of the live ISO with the GUI, real hardware, the pointer (only
keys were used in QEMU; clicking is exercised offscreen by nothing either —
the click paths are the same `p.clickable` the greeter uses).
