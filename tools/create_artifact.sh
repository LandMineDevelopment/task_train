#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# create_artifact.sh <task_id> <agent_id> <name> <description> <type> <body>
# Creates an artifact linked to a task. Requires artifact:create.

TASK_ID="${1:?usage: create_artifact.sh <task_id> <agent_id> <name> <descr> <type> <body>}"
AGENT_ID="${2:?}"
NAME="${3:?}"
DESCR="${4:?}"
TYPE="${5:?}"
BODY="${6:?}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"

name_q="${NAME//\'/\'\'}"
descr_q="${DESCR//\'/\'\'}"
type_q="${TYPE//\'/\'\'}"
body_q="${BODY//\'/\'\'}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT json_build_object(
  'success', true,
  'artifact_id', tagg.artifact_add_for_run('$AGENT_RUN_TOKEN', $TASK_ID, '$name_q', '$descr_q', '$type_q', '$body_q')
)::text;
SQL
