#!/usr/bin/env bash
# Sync an identity's calendars and address books with vdirsyncer, then use
# khard and khal (third-party, file-based clients) on the local copies and
# sync back.
#
#   vdir.sh WORKDIR URL HANDLE APP_PASSWORD BIN
#
# BIN is a directory holding vdirsyncer, khard and khal (a venv's bin).
set -euo pipefail
work=$1 url=$2 user=$3 pass=$4 bin=$5
mkdir -p "$work/status" "$work/contacts" "$work/calendars"
cat > "$work/config" <<EOF
[general]
status_path = "$work/status/"

[pair contacts]
a = "contacts_local"
b = "contacts_remote"
collections = ["from b"]
conflict_resolution = "b wins"

[storage contacts_local]
type = "filesystem"
path = "$work/contacts/"
fileext = ".vcf"

[storage contacts_remote]
type = "carddav"
url = "$url"
username = "$user"
password = "$pass"

[pair calendars]
a = "calendars_local"
b = "calendars_remote"
collections = ["from b"]
metadata = ["color", "displayname"]
conflict_resolution = "b wins"

[storage calendars_local]
type = "filesystem"
path = "$work/calendars/"
fileext = ".ics"

[storage calendars_remote]
type = "caldav"
url = "$url"
username = "$user"
password = "$pass"
EOF
export VDIRSYNCER_CONFIG="$work/config"
(yes || true) | "$bin/vdirsyncer" discover >/dev/null || true
"$bin/vdirsyncer" sync
"$bin/vdirsyncer" metasync >/dev/null || true
