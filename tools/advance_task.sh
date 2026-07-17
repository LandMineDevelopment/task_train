#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# advance_task.sh <task_id> <agent_id>
# Moves a task to its next workflow step. Requires task:advance.

TASK_ID="${1:?usage: advance_task.sh <task_id> <agent_id>}"
AGENT_ID="${2:?}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT json_build_object(
  'success', true,
  'new_status_id', tagg.advance_task_for_run('$AGENT_RUN_TOKEN', $TASK_ID)
)::text;
SQL
