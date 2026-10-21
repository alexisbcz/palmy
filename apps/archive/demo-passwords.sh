#!/bin/sh
# Builds an encrypted 7z with the command line, then opens it in the window.
A="$(cd "$(dirname "$0")" && pwd)/archive.bin"
W=/tmp/palmy-archive-demo
rm -rf $W && mkdir -p $W/notes/drafts && cd $W
printf '# Plans\n\nShip the archive passwords.\n' > notes/plans.md
printf 'first draft\n' > notes/drafts/one.txt
printf 'second draft\n' > notes/drafts/two.txt
printf 'demo-pass\n' > pw.txt
export PALM_AUDIT=$W/audit.jsonl HOME=$W
$A create notes $W/notes.7z --password-file pw.txt >/dev/null 2>&1
rm -rf notes
exec $A $W/notes.7z
