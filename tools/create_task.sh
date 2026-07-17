#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# create_task.sh <from_agent_id> <to_agent_id> <task_text> <project_id> [workflow_name]
# The run token determines the creator, project, parent, and conversation.

FROM="${1:?usage: create_task.sh <from> <to> <task> <project_id> [workflow]}"
TO="${2:?}"
TASK="${3:?}"
PROJECT_ID="${4:?}"
WORKFLOW="${5:-standard}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"
: "${TASK_ID:?TASK_ID required}"

task_q="${TASK//\'/\'\'}"
wf_q="${WORKFLOW//\'/\'\'}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT tagg.set_agent_run_context('$AGENT_RUN_TOKEN');
SELECT json_build_object(
  'success', true,
  'task_id', tagg.create_task_for_run('$AGENT_RUN_TOKEN', $TASK_ID, $TO, '$task_q', '$wf_q')
)::text;
SQL
