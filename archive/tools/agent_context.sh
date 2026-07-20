#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

AGENT_ID="${1:?usage: agent_context.sh <agent_id>}"

psql --no-psqlrc -A -t <<SQL 2>/dev/null
SELECT tagg.get_agent_context($AGENT_ID)::text;
SQL
