#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cp "$ROOT/configure.sh" "$TMPDIR/configure.sh"
chmod +x "$TMPDIR/configure.sh"

(cd "$TMPDIR" && ./configure.sh --non-interactive --port 15433 --web-port 13000 --database test_db --user test_user --password test-password-123)
test -f "$TMPDIR/.env"
test "$(stat -c '%a' "$TMPDIR/.env")" = "600"
grep -qx 'TASK_TRAIN_DB_PORT=15433' "$TMPDIR/.env"
grep -qx 'TASK_TRAIN_WEB_PORT=13000' "$TMPDIR/.env"
grep -qx 'POSTGRES_DB=test_db' "$TMPDIR/.env"
grep -qx 'POSTGRES_USER=test_user' "$TMPDIR/.env"

if (cd "$TMPDIR" && ./configure.sh --non-interactive --port invalid); then
    printf 'configure.sh accepted an invalid port\n' >&2
    exit 1
fi
