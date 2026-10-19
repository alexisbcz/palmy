# Translations

One directory per language, one catalogue per program:

```
distro/locale/<lang>/<domain>.msg   ->   /usr/share/palm/locale/<lang>/<domain>.msg
```

`<domain>` is the program's name as it calls `kit.i18n_init` (`greeter`,
`installer`). `<lang>` is a language (`fr`), or a language and territory
(`fr_CA`, `pt_BR`) for the strings that differ by country. The `palm-locale`
package ships every `.msg` here; nothing has to be listed by hand.

The library that reads them is `apps/kit/i18n.odin`; `apps/kit/i18n_test`
tests it and lints every catalogue in this directory.

## Languages today

| dir | language | plural rule | notes |
| --- | --- | --- | --- |
| `fr` | Français | `n > 1` | 0 is singular |
| `de` | Deutsch | `n != 1` | |
| `es` | Español | `n != 1` | |
| `ar` | العربية | gettext's six-form rule | right to left (`direction = rtl`) |
| `ja` | 日本語 | `0` | needs a CJK font installed to render |

English is the msgids themselves and has no directory.

## The format

UTF-8 text, gettext's `.po` with the parts that need tools taken out:

```
# A comment. Anything after # at the start of a line.
language  = fr
name      = Français
english   = French
plural    = n > 1

msgid "Install Palmy"
msgstr "Installer Palmy"

msgid "%d package"
msgid_plural "%d packages"
msgstr[0] "%d paquet"
msgstr[1] "%d paquets"

msgid ""
"A long string can be split "
"over several lines; they are joined."
msgstr ""
"Une longue chaîne peut être coupée "
"sur plusieurs lignes."
```

- **The msgid is the English text** exactly as the program has it, `%` verbs
  and punctuation included. If the program changes the English, the old entry
  stops matching and the English shows until the catalogue catches up.
- **Strings** are in double quotes with C escapes: `\"`, `\\`, `\n`, `\t`.
  A `=` inside a string is just text.
- **An empty `msgstr ""`** means "not translated yet": the program shows the
  English (or what a less specific catalogue has — see below).
- **Header lines** are `key = value`, unquoted, lower-case keys, normally at
  the top:

  | key | meaning |
  | --- | --- |
  | `plural` | the plural rule (below); required |
  | `language` | the directory's language code |
  | `name` | the language's name in itself (`Deutsch`), for language lists |
  | `english` | its name in English |
  | `direction` | `rtl` or `ltr`; without it, ar, he, fa and ur are right to left |

### Plurals

`plural =` is gettext's C expression in `n`; its value is the `msgstr[]` to
use, and a comparison counts as 0 or 1:

```
plural = n != 1        # English, German, Spanish: msgstr[0] for 1, [1] otherwise
plural = n > 1         # French: 0 and 1 are singular
plural = 0             # Japanese, Chinese, Korean: one form, msgstr[0]
plural = n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5
                       # Arabic: zero, one, two, few, many, other
```

`n`, integers, `== != < > <= >= && || ! + - * / %`, `?:` and parentheses
work, so any rule from gettext's table can be pasted in. A plural entry needs
as many `msgstr[]` as its rule can pick; the lint checks that.

### Formats

`%s`, `%d` and the rest are Odin's `core:fmt` verbs. A translation must keep
the same verbs as its msgid — every one, in every plural form — or the screen
shows `%!(EXTRA ...)` / `%!(MISSING ...)`. To change the order, use explicit
argument indices, which in Odin **start at 0**:

```
# Arguments: weekday, day of the month, month, year.
msgid "%[0]s, %[1]d %[2]s %[3]d"
msgstr "%[3]d年%[2]s%[1]d日（%[0]s）"
```

Some programs use `{name}` placeholders instead of `%` (the installer does);
those must survive translation too, and the program's own selftest checks
them.

## Which language is shown

The language named to `i18n_init` / `i18n_set_language`, or else the
environment: `LANGUAGE` (a `:`-separated list), then the first of `LC_ALL`,
`LC_MESSAGES`, `LANG`. On Palmy `LANG` comes from `/etc/locale.conf`, which
the installer writes; palm-init passes it to services and palm-login to the
login screen and to every session.

Each name is tried from most to least specific — `fr_CA.UTF-8@euro`,
`fr_CA.UTF-8`, `fr_CA@euro`, `fr_CA`, `fr` — and every catalogue found is
kept, so `fr_CA/greeter.msg` need only hold the strings Canadian French says
differently; the rest come from `fr`. `C` and `POSIX` mean English.

## Trying a catalogue from the checkout

`PALM_LOCALE_DIR` replaces `/usr/share/palm/locale`:

```sh
odin build apps/greeter -collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn -out:/tmp/greeter
PALM_LOCALE_DIR=$PWD/distro/locale /tmp/greeter --lang fr --shots /tmp/fr   # offscreen PNGs
odin test apps/kit/i18n_test -collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn
```

## Fonts

The base fonts (Geist, with DejaVu Sans as the fallback) cover Latin, Greek,
Cyrillic and Arabic. Japanese needs a CJK face under `/usr/share/fonts`
(the `fonts-cjk` package); without one, a program should list the language as
unavailable rather than draw boxes.
