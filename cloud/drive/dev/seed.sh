#!/usr/bin/env bash
# Seed two people and three identities into the dev stack, and write a drive
# config with one scoped token per identity.
#
#   alice   owns  alice (personal)   and  alice-work (work)
#   bob     owns  bob (personal)
#
# Real tokens come from Supabase Auth and the accounts area's token exchange;
# these are minted with the stack's JWT secret and are for development only.
#
#   seed.sh [config dir]     default ~/.config/palm-drive
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eval "$("$HERE/stack.sh" env)"
CONF=${1:-$HOME/.config/palm-drive}
mkdir -p "$CONF"

ALICE=00000000-0000-0000-0000-0000000a11ce
BOB=00000000-0000-0000-0000-000000000b0b
I_ALICE=11111111-1111-4111-8111-111111111111
I_WORK=22222222-2222-4222-8222-222222222222
I_BOB=33333333-3333-4333-8333-333333333333

"$HERE/stack.sh" psql <<-SQL
insert into auth.users (id, email) values
	('$ALICE', 'alice@palm.test'), ('$BOB', 'bob@palm.test')
on conflict (id) do nothing;
insert into public.identities (id, owner, handle, display_name, kind, color) values
	('$I_ALICE', '$ALICE', 'alice', 'Alice Martin', 'personal', 'indigo'),
	('$I_WORK', '$ALICE', 'alice-work', 'Alice Martin — Northwind', 'work', 'emerald'),
	('$I_BOB', '$BOB', 'bob', 'Bob Chen', 'personal', 'amber')
on conflict (id) do nothing;
SQL

tok() { python3 "$HERE/jwt.py" "$PALM_DRIVE_JWT_SECRET" role=authenticated sub="$1" ${2:+palm_identity=$2}; }

# One file per identity: the device token for it (scoped), plus where it is.
cat >"$CONF/drive.conf" <<-EOF
# palm-drive configuration. One [identity] block per drive to mirror.
# token is a JWT scoped to that identity (claim palm_identity); see
# cloud/CONTRACT.md. The account token is unscoped and only used by the app
# to list the person's identities.
url = $PALM_SUPABASE_URL
storage = $PALM_STORAGE_URL
anon = $PALM_SUPABASE_ANON_KEY
account = $(tok $ALICE)

[identity]
handle = alice
id = $I_ALICE
name = Alice Martin
kind = personal
color = indigo
token = $(tok $ALICE $I_ALICE)

[identity]
handle = alice-work
id = $I_WORK
name = Alice Martin — Northwind
kind = work
color = emerald
token = $(tok $ALICE $I_WORK)
EOF

cat >"$CONF/bob.conf" <<-EOF
url = $PALM_SUPABASE_URL
storage = $PALM_STORAGE_URL
anon = $PALM_SUPABASE_ANON_KEY
account = $(tok $BOB)

[identity]
handle = bob
id = $I_BOB
name = Bob Chen
kind = personal
color = amber
token = $(tok $BOB $I_BOB)
EOF
echo "wrote $CONF/drive.conf (alice) and $CONF/bob.conf" >&2
