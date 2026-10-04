#!/usr/bin/env bash
# Check an exported workbook against LibreOffice, which is the only oracle
# that matters: a file is correct when the program that did not write it
# agrees about what is in it.
#
#   bash apps/sheets/oracle.sh
#
# Four passes, each of which has caught something real:
#
#   1. xmllint every part and list the container. A part that is not
#      well-formed XML is a file no reader will open.
#   2. convert to CSV. LibreOffice recalculates on load (fullCalcOnLoad), so
#      the values it prints are *its* arithmetic over *our* formulas.
#   3. re-save as .xlsx and read the parts back. This is where cross-sheet
#      formulas, the frozen pane, the merges and the defined names are
#      checked in Excel's own spelling rather than LibreOffice's.
#   4. import the file LibreOffice wrote. That exercises deflate, shared
#      strings and shared formulas at once, over several sheets.
#
# The profile path carries a 2 so it cannot collide with another agent's
# headless LibreOffice. The GUI is never launched.
set -uo pipefail
cd "$(dirname "$0")/../.."
BIN=apps/sheets/sheets.bin
PROFILE=file:///tmp/palmy-lo-sheets2
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
say() { printf '%-62s %s\n' "$1" "$2"; }
want() { if printf '%s' "$2" | grep -qF -- "$3"; then say "$1" "ok"; else say "$1" "FAILED"; fail=1; fi; }

"$BIN" --export "$WORK/book.xlsx" >/dev/null || { echo "export failed"; exit 1; }

echo "--- 1. the container ---"
unzip -l "$WORK/book.xlsx" | tail -n +4 | head -n -2 | awk '{print "   ", $4}'
for f in $(unzip -Z1 "$WORK/book.xlsx"); do
  # unzip globs its member pattern, so the brackets of [Content_Types].xml
  # have to be escaped or it matches nothing at all.
  pat="$(printf '%s' "$f" | sed 's/\[/[[]/g')"
  unzip -p "$WORK/book.xlsx" "$pat" > "$WORK/part.xml" 2>/dev/null
  if [ -s "$WORK/part.xml" ] && xmllint --noout "$WORK/part.xml"; then
    say "well-formed: $f" "ok"
  else
    say "well-formed: $f" "FAILED"; fail=1
  fi
done

echo "--- 2. values, recalculated by LibreOffice ---"
soffice --headless -env:UserInstallation=$PROFILE \
  --convert-to 'csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,true,false,false,-1' \
  --outdir "$WORK/csv" "$WORK/book.xlsx" >/dev/null 2>&1
ls "$WORK/csv" | sed 's/^/    /'
SALES="$(cat "$WORK/csv/book-Sales.csv" 2>/dev/null)"
SUM="$(cat "$WORK/csv/book-Summary.csv" 2>/dev/null)"
want "both sheets come back"                "$(ls "$WORK/csv")"  "book-Summary.csv"
want "a same-sheet formula recalculates"    "$SALES" '$801.85'
want "a cross-sheet SUM recalculates"       "$SUM"   '$2,781.05'
want "a cross-sheet INDEX/MATCH recalculates" "$SUM" 'Best region,East'

echo "--- 3. re-saved by LibreOffice ---"
soffice --headless -env:UserInstallation=$PROFILE --convert-to xlsx \
  --outdir "$WORK/rs" "$WORK/book.xlsx" >/dev/null 2>&1
S2="$(unzip -p "$WORK/rs/book.xlsx" xl/worksheets/sheet2.xml)"
S1="$(unzip -p "$WORK/rs/book.xlsx" xl/worksheets/sheet1.xml)"
WB="$(unzip -p "$WORK/rs/book.xlsx" xl/workbook.xml)"
CH="$(unzip -p "$WORK/rs/book.xlsx" xl/charts/chart1.xml 2>/dev/null)"
want "the sheet names survive"              "$WB" '<sheet name="Summary"'
want "a cross-sheet reference survives"     "$S2" '>Sales!D3<'
want "a cross-sheet range survives"         "$S2" '>SUM(Sales!D3:D7)<'
want "a nested cross-sheet formula survives" "$S2" '>INDEX(Sales!A3:A7,MATCH(MAX(Sales!D3:D7),Sales!D3:D7,0))<'
want "the frozen pane survives"             "$S1" 'state="frozen"'
want "the split is where we put it"         "$S1" 'xSplit="1" ySplit="2" topLeftCell="B3"'
want "the merge survives"                   "$S1" '<mergeCell ref="A1:D1"/>'
want "the defined name survives"            "$WB" 'Sales!$D$3:$D$7'
want "the chart survives as a chart"        "$CH" '<c:barChart>'
want "the chart keeps its series formula"   "$CH" '<c:f>Summary!$B$2:$B$6</c:f>'

echo "--- 4. importing what LibreOffice wrote ---"
"$BIN" --export "$WORK/back.sheet.json" "$WORK/rs/book.xlsx" | sed 's/^/    /'
J="$(cat "$WORK/back.sheet.json")"
want "both sheets import"                   "$J" '"name": "Summary"'
want "the cross-sheet formula imports"      "$J" '=SUM(Sales!D3:D7)'
want "the frozen pane imports"              "$J" '"frz_row": 2'
want "the merge imports"                    "$J" '"A1:D1"'
want "the defined name imports"             "$J" '"REVENUE"'
want "the chart imports"                    "$J" '"Revenue by region"'

echo
if [ "$fail" = 0 ]; then echo "oracle: every check passed"; else echo "oracle: FAILURES above"; fi
exit $fail
