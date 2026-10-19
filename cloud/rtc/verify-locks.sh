#!/usr/bin/env bash
# The gateway's locking discipline, checked from the source by the same
# script that checks apps/chat/server (apps/chat/verify-locks.sh): one mutex,
# taken at exactly five sites, once each; no locked_* procedure can reach a
# lock; locked_send is the only thing that writes a frame.
#
# The five: `boot`, `serve` (the accept loop), `handle` (one frame),
# `drop_conn` (a connection going away) and `notify_batch` (a batch of
# Postgres notifications, which is where every stored change is broadcast).
#
# The state-free list is what the lock-takers may call outside the locked_*
# tier: work done before the lock is taken (verifying a token, uploading an
# attachment) and things that own nothing shared.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXPECTED="boot drop_conn handle notify_batch serve" \
EXTRA_NEUTRAL="jwt_verify jwks_load db_open new_uuid redact storage_client stage_attach listen_thread conn_thread" \
	exec bash "$here/../../apps/chat/verify-locks.sh" "$here/main.odin" "$here/gateway.odin" "$here/pg.odin" "$here/jwt.odin"
