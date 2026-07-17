#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# read_task.sh <task_id>
# Returns the current run's task details as JSON.

TASK_ID="${1:?usage: read_task.sh <task_id>}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"
[[ "$TASK_ID" =~ ^[0-9]+$ ]] || { printf 'Task ID must be numeric.\n' >&2; exit 2; }

psql --no-psqlrc -A -t <<SQL 2>/dev/null
SELECT tagg.get_task_for_run('$AGENT_RUN_TOKEN', $TASK_ID)::text;
SQL
