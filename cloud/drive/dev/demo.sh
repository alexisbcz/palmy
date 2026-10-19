#!/usr/bin/env bash
# Fill the dev stack with a believable drive, through the drive CLI, and sync
# it to a demo folder with palm-drive. The screenshots in apps/drive were
# taken against exactly this.
#
#   cloud/drive/dev/demo.sh [dir]      default /tmp/palm-drive-demo
#
# It resets the database. Office files are made by the repo's own apps
# (sheets export, slides --pptx/--pdf) when they are built, so opening them
# from the drive opens real documents.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIR=${1:-/tmp/palm-drive-demo}
DRIVE="$ROOT/apps/drive/drive.bin"
SYNC="$ROOT/cloud/drive/bin/palm-drive"

rm -rf "$DIR"
mkdir -p "$DIR/stage"
"$HERE/stack.sh" reset >/dev/null 2>&1
"$HERE/seed.sh" "$DIR/conf" 2>/dev/null
export PALM_DRIVE_CONFIG="$DIR/conf/drive.conf" PALM_DRIVE_DIR="$DIR/Drive" PALM_DRIVE_STATE="$DIR/state" PALM_DRIVE_DEVICE=laptop
S="$DIR/stage"

# --- the files ---------------------------------------------------------------
if [ -x "$ROOT/apps/slides/slides.bin" ]; then
	"$ROOT/apps/slides/slides.bin" --pptx "$S/Board deck.pptx" >/dev/null 2>&1 || true
	"$ROOT/apps/slides/slides.bin" --pdf "$S/Q3 results.pdf" >/dev/null 2>&1 || true
fi
if [ -x "$ROOT/apps/sheets/sheets.bin" ]; then
	"$ROOT/apps/sheets/sheets.bin" export "$S/Budget 2026.xlsx" >/dev/null 2>&1 || true
fi
[ -s "$S/Board deck.pptx" ] || head -c 912345 /dev/urandom >"$S/Board deck.pptx"
[ -s "$S/Q3 results.pdf" ] || head -c 284113 /dev/urandom >"$S/Q3 results.pdf"
[ -s "$S/Budget 2026.xlsx" ] || head -c 48211 /dev/urandom >"$S/Budget 2026.xlsx"

cat >"$S/Board memo.md" <<-'EOF'
	# Q3 board memo

	Revenue grew 12% quarter on quarter, led by the Northwind renewal.
	Hiring is on plan; two roles move to Q4.
EOF
cat >"$S/Northwind MSA.md" <<-'EOF'
	# Master services agreement — Northwind Traders

	Term: 24 months from signature. Renewal: automatic, 90 days' notice.
EOF
printf 'vendor,owner,renewal\nAcme Hosting,ops,2027-01\nGlyph Fonts,design,2026-12\nPaperTrail,finance,2027-03\n' >"$S/Vendor list.csv"
printf 'team,q3,q4\ndesign,42000,45000\nplatform,88000,91000\nsupport,31000,31000\n' >"$S/Team budget.csv"
printf '# Onboarding\n\n1. Laptop and accounts\n2. Read the handbook\n3. Meet your buddy\n' >"$S/Onboarding.md"
printf '# Draft memo v1\n\nSuperseded.\n' >"$S/Draft memo v1.md"
printf 'year,item,amount\n2025,income,58200\n2025,deductions,6120\n' >"$S/Taxes 2025.csv"
printf '# Recipes\n\n## Pastéis de nata\n\nPuff pastry, milk, sugar, eggs, lemon, cinnamon.\n' >"$S/Recipes.md"
printf '# Lisbon, May\n\n- Alfama walk\n- Tram 28 early\n- Belém on Sunday\n' >"$S/Trip to Lisbon.md"
printf '# Garden plan\n\nTomatoes along the south fence.\n' >"$S/Garden plan.md"
for f in app-files app-slides app-sheets app-maps; do
	cp "$ROOT/site/public/shots/$f.png" "$S/${f#app-} mockup.png"
done
cp "$ROOT/site/public/film/palmframe-poster.jpg" "$S/palmframe-poster.jpg"
cp "$ROOT/site/public/shots/app-photoshop.png" "$S/Old logo.png"

# --- alice.northwind (work) ----------------------------------------------------------------
W() { PALM_IDENTITY=alice.northwind "$DRIVE" "$@" >/dev/null; }
for f in "Board deck.pptx" "Budget 2026.xlsx" "Board memo.md" "Q3 results.pdf" "Draft memo v1.md"; do W upload "$S/$f" "Q3 Board pack"; done
for f in "Northwind MSA.md" "Vendor list.csv"; do W upload "$S/$f" "Contracts"; done
for f in "files mockup.png" "slides mockup.png" "sheets mockup.png" "maps mockup.png" "palmframe-poster.jpg" "Old logo.png"; do W upload "$S/$f" "Design"; done
W upload "$S/Onboarding.md" /
W upload "$S/Team budget.csv" /
W mkdir "Archive/2025"
# A second version of the memo.
printf '\nAction: approve the Q4 hiring plan.\n' >>"$S/Board memo.md"
W upload "$S/Board memo.md" "Q3 Board pack"
W star "Q3 Board pack"
W star "Q3 Board pack/Budget 2026.xlsx"
W share "Q3 Board pack" bob.chen --role viewer
W share "Contracts" bob.chen --role editor
W share "Onboarding.md" alice.martin --role viewer # work to personal: a deliberate crossing
W link "Q3 Board pack" --expires "7 days"
W trash "Design/Old logo.png"
W trash "Q3 Board pack/Draft memo v1.md"

# --- alice.martin (personal) ------------------------------------------------------------
P() { PALM_IDENTITY=alice.martin "$DRIVE" "$@" >/dev/null; }
cp "$ROOT/site/public/shots/app-maps.png" "$S/Lisbon map.png"
cp "$ROOT/site/public/shots/app-video.png" "$S/Holiday video still.png"
for f in "palmframe-poster.jpg" "Lisbon map.png" "Holiday video still.png"; do P upload "$S/$f" "Photos"; done
for f in "Taxes 2025.csv" "Recipes.md" "Trip to Lisbon.md"; do P upload "$S/$f" /; done
P star "Trip to Lisbon.md"

# --- bob.chen ---------------------------------------------------------------------------
PALM_DRIVE_CONFIG="$DIR/conf/bob.conf" PALM_IDENTITY=bob.chen "$DRIVE" upload "$S/Garden plan.md" / >/dev/null

# Recent: what alice opened at work, most recent last.
for f in "Budget 2026.xlsx" "Board memo.md" "Board deck.pptx"; do
	"$HERE/stack.sh" psql -c "update drive_items set accessed_at = now() where name = '$f'" >/dev/null
	sleep 0.05
done

# Mirror both of alice's drives on this "laptop".
"$SYNC" sync >/dev/null 2>&1 || true
echo "demo drive ready in $DIR" >&2
echo "  PALM_DRIVE_CONFIG=$DIR/conf/drive.conf PALM_DRIVE_DIR=$DIR/Drive PALM_DRIVE_STATE=$DIR/state" >&2
