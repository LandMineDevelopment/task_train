#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# read_task.sh <task_id>
# Returns task details as JSON. Read-only, no permission needed.

TASK_ID="${1:?usage: read_task.sh <task_id>}"

psql --no-psqlrc -A -t <<SQL 2>/dev/null
SELECT row_to_json(t)::text
FROM (SELECT id, from_user_id, to_user_id, task, project_id, parent_id,
             task_status_id, workflow_id, created, updated, is_active
      FROM tagg.agent_task WHERE id = $TASK_ID) t;
SQL
