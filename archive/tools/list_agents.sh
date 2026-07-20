#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

FILTER="${1:-all}"

psql --no-psqlrc -A -t <<SQL 2>/dev/null
SELECT json_agg(row_to_json(t) ORDER BY t.id)::text
FROM (
  SELECT id, name, descr, prompt, max_concurrent,
    (SELECT json_agg(s.name ORDER BY s.name)
     FROM tagg.skill_user_crosswalk x
     JOIN tagg.skill s ON s.id = x.skill_id
     WHERE x.user_id = u.id AND x.is_active = true
    ) as skills
  FROM tagg.user u
  WHERE u.is_active = true
    AND (CASE WHEN '$FILTER' = 'agents' THEN u.is_agent = true
              WHEN '$FILTER' = 'users' THEN u.is_agent = false
              ELSE true END)
  ORDER BY u.id
) t;
SQL
