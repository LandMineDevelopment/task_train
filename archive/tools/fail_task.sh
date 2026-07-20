#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# fail_task.sh <task_id> <agent_id>
# Marks the caller's assigned task as failed. Requires task:fail.

TASK_ID="${1:?usage: fail_task.sh <task_id> <agent_id>}"
AGENT_ID="${2:?}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"
[[ "$TASK_ID" =~ ^[0-9]+$ && "$AGENT_ID" =~ ^[0-9]+$ ]] || { printf 'Task and agent IDs must be numeric.\n' >&2; exit 2; }

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT json_build_object(
  'success', true,
  'new_status_id', tagg.fail_task_for_run('$AGENT_RUN_TOKEN', $TASK_ID)
)::text;
SQL
