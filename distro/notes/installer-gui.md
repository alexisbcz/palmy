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
installer --selftest       flow, validation, demo install on its thread, RTL, catalogue coverage (141 checks)
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
- **Keyboard** — searchable layout list (descriptions in the UI language,
  sorted in it), variant list, test field. A change settles for 250 ms,
  then `/etc/palm/keyboard` is written (`core.keyboard_settings`, the text
  the new disk gets) and the wm gets SIGHUP. A layout with no Latin letters
  (ara, ru, gr, ...) comes with US English first and Alt+Shift, and the
  page says so: a user name is a-z.
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
  withdraws the confirmation. Under the disks, "Create a swap file of
  N GiB" (on by default; half the memory in whole GiB, 1 to 4 GiB).
- **Account** — full name (optional; `:`/`,` refused for GECOS), user name
  (follows the full name — "Élodie Martin" → `elodie` — until typed into),
  computer name (default `palmframe`), password twice with a weak/fair/strong
  meter, "use the same password for root" (on by default; off shows two more
  fields). Problems appear under a field once it has been typed into, all of
  them when Next is pressed (and the keyboard goes to the first one).
- **Summary** — the disk to be erased in a red box, then every choice with a
  Change button back to its page, and the swap file; Install. If the core's
  `validate_messages` objects, its problems are shown here, translated, and
  nothing starts.
- **Install** — current step name, whole-install percentage and bar, the
  seven steps ticked off, the core's progress detail translated
  (`Progress.detail`, `text_tr`), and "Show details" for the log
  (the core's own lines through `Options.on_log`, follows the end). On
  failure: the error, the log unfolded, "Back to summary" and "Restart".
- **Done** — "Palmframe is installed", Restart now (`/sbin/reboot`). Laid
  out from the top, so the pointer the compositor parks at the screen's
  centre does not cover the heading.

Keyboard: Tab / Shift+Tab move focus (palmy), Up/Down/PageUp/PageDown move the
page's list selection, Enter is Next (or the focused button), Esc is Back
(or closes the dialog). Rail entries already visited are clickable until the
install starts; no way back after that.

Plan details: `efi_boot_entry` = `/sys/firmware/efi` exists; `packages` is
left empty (the core's default) except for Japanese, which adds `fonts-cjk`
(`{"palmframe", "fonts-cjk"}`), as distro/notes/live.md suggested.

### Right to left

The root gets palmy's `dir-rtl` when `kit.i18n_is_rtl()`: every row below
it runs right to left, and Tab follows the tree's order, which is then the
reading order. Every text node is `dir-auto` (`text`, `textf`, `txt` in
`ui.odin`), so a paragraph keeps its own first strong character's
direction: without it "/dev/vda" and "20.0 GiB" come out "dev/vda/" and
"GiB 20.0". Text in columns is aligned to the UI direction (`txt`);
chevrons swap; the log is `dir-ltr`. Two bidi details, both in `i18n.odin`:

- a translation written in an RTL script gets a RIGHT-TO-LEFT MARK in front,
  so "GPT: قسم نظام EFI…" or "%s، %s…" is an RTL paragraph even though it
  starts with Latin;
- in RTL, every string argument of `trf` is wrapped in FSI…PDI, so
  "/dev/vda" inside an Arabic sentence is not drawn "dev/vda/".

## Translations

`distro/locale/{fr,de,es,ar,ja}/installer.msg`, 196 entries each, kit's
format with the same header keys as the greeter's catalogues (`language`,
`name`, `english`, `direction = rtl` for Arabic, Arabic's six-form plural
rule, `plural = 0` for Japanese). German and Spanish use the formal address.
The selftest scans the source for `tr("`, `trf("` and `N("` literals and
checks, per catalogue: it parses cleanly with `kit.i18n_parse`, names its
language, has every msgid translated, keeps `%` verbs and `{placeholders}`,
and has no stale entries. The msgids also include install_core's
`MESSAGE_FORMAT` (validate problems, progress details, 53 of them), which
`text_tr` translates with the message's arguments.

Japanese is available on the live image (a subset of Noto Sans CJK JP is
installed there, distro/notes/live.md; `core.list_languages` finds it),
so 日本語 is offered; on a system without a CJK font the row says it is
unavailable.

Country names and keyboard layout descriptions come from two generated
catalogues per language, `countries.msg` (keyed by the ISO 3166-1 code,
from iso-codes, LGPL-2.1) and `keyboards.msg` (keyed by base.lst's English
description, from xkeyboard-config's own translations), made by
`distro/locale/import-data.py` and loaded beside `installer.msg`
(`country_name`, `keyboard_name`). Coverage: fr 182 countries / 556 of 597
layouts, de 153 / 537, es 166 / 534, ar 248 / 597, ja 249 / 265; the rest
stays English (a country whose name is the same in both is not listed).
Search matches the translation and the English. Region names
(`Europe`, `America`) and city names stay as tzdata spells them, and disk
models and the log are machine text.

## Where install_core differs from INSTALLER.md (followed, not changed)

- `Progress.fraction` is the whole installation's progress, not the step's;
  the bar uses it as is (the demo computes the same thing with its own step
  weights).
- `install_with(plan, Options, …)` and `Options.on_log` exist; the GUI uses
  them for the log view instead of logging progress messages.
- `Zone.country` is the country *name* ("France"), `Zone.country_code` its
  code, the translation's key; the rows show "France · Europe".
- Arabic's code is `ar` (not `ar_EG`).
- `list_zones` includes `UTC`.

## Requests for others

The three earlier requests are done: palmy re-measures a text whose string
grows (so the tree is no longer keyed by language), palmy has `dir-rtl`
(so `hrow`/`hend` are gone), and install_core's problems carry codes. The
greeter (`apps/greeter`) still mirrors its rows with `if rtl` branches and
could take the same `dir-rtl` + `dir-auto` treatment.

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
