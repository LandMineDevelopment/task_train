#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

AGENT_ID="${1:?usage: list_pending_tasks.sh <agent_id> <limit>}"
LIMIT="${2:-10}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT jsonb_build_array(tagg.get_current_task_for_run('$AGENT_RUN_TOKEN'))::text;
SQL
