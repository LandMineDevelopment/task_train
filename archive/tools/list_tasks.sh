#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# list_tasks.sh [status_name|status_id|agent_name|agent_id] [limit]
# Examples:
#   list_tasks.sh                  -- all active tasks
#   list_tasks.sh pending          -- pending tasks only
#   list_tasks.sh 1                -- status_id = 1 (pending)
#   list_tasks.sh Coder            -- tasks for Coder
#   list_tasks.sh 9                -- tasks for agent_id 9
#   list_tasks.sh pending Coder    -- pending tasks for Coder
#   list_tasks.sh "" 5             -- all tasks, limit 5

STATUS_FILTER="${1:-}"
AGENT_FILTER="${2:-}"
LIMIT="${3:-50}"

WHERE_CLAUSE="at.is_active = true"
JOIN_CLAUSE=""

if [ -n "$STATUS_FILTER" ]; then
  if [[ "$STATUS_FILTER" =~ ^[0-9]+$ ]]; then
    WHERE_CLAUSE="$WHERE_CLAUSE AND at.task_status_id = $STATUS_FILTER"
  else
    WHERE_CLAUSE="$WHERE_CLAUSE AND ts.name = '$STATUS_FILTER'"
  fi
  JOIN_CLAUSE="JOIN tagg.task_status ts ON ts.id = at.task_status_id"
fi

if [ -n "$AGENT_FILTER" ]; then
  if [[ "$AGENT_FILTER" =~ ^[0-9]+$ ]]; then
    WHERE_CLAUSE="$WHERE_CLAUSE AND (at.to_user_id = $AGENT_FILTER OR at.from_user_id = $AGENT_FILTER)"
  else
    WHERE_CLAUSE="$WHERE_CLAUSE AND (u_to.name = '$AGENT_FILTER' OR u_from.name = '$AGENT_FILTER')"
  fi
fi

SQL="
SELECT json_agg(row_to_json(t) ORDER BY t.id DESC)::text
FROM (
  SELECT at.id, at.from_user_id, u_from.name as from_name,
         at.to_user_id, u_to.name as to_name,
         at.task_status_id, ts.name as status_name,
         at.project_id, p.name as project_name,
         at.parent_id, at.workflow_id,
         left(at.task, 200) as task,
         at.created, at.updated
  FROM tagg.agent_task at
  JOIN tagg.user u_from ON u_from.id = at.from_user_id
  JOIN tagg.user u_to ON u_to.id = at.to_user_id
  JOIN tagg.task_status ts ON ts.id = at.task_status_id
  LEFT JOIN tagg.project p ON p.id = at.project_id
  WHERE $WHERE_CLAUSE
  ORDER BY at.id DESC
  LIMIT $LIMIT
) t;"

psql --no-psqlrc -A -t <<SQL 2>/dev/null
$SQL
SQL
