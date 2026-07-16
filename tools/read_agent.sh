#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# read_agent.sh <agent_name_or_id>
# Looks up an agent by name or ID. Returns JSON with id, name, descr, skills.

QUERY="${1:?usage: read_agent.sh <name_or_id>}"

if [[ "$QUERY" =~ ^[0-9]+$ ]]; then
  SQL_FILTER="id = $QUERY"
else
  SQL_FILTER="name = '$QUERY'"
fi

psql --no-psqlrc -A -t 2>/dev/null <<SQL
WITH
  agent AS (
    SELECT id, name, descr, prompt
    FROM tagg.user
    WHERE is_agent = true AND is_active = true
      AND $SQL_FILTER
    LIMIT 1
  ),
  skills AS (
    SELECT json_agg(s.name ORDER BY s.name) AS items
    FROM tagg.skill_user_crosswalk x
    JOIN tagg.skill s ON s.id = x.skill_id
    WHERE x.user_id = (SELECT id FROM agent) AND x.is_active = true
  )
SELECT json_build_object(
  'id', (SELECT id FROM agent),
  'name', (SELECT name FROM agent),
  'descr', (SELECT descr FROM agent),
  'prompt', (SELECT prompt FROM agent),
  'skills', COALESCE((SELECT items FROM skills), '[]'::json)
)::text;
SQL
