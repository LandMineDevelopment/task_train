#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

TASK_ID="${1:?usage: claim_task.sh <task_id> <agent_id>}"
AGENT_ID="${2:?usage: claim_task.sh <task_id> <agent_id>}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT tagg.set_agent_run_context('$AGENT_RUN_TOKEN');
SELECT tagg.claim_task($TASK_ID)::text;
SQL
