#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

psql --no-psqlrc -A -t <<SQL 2>/dev/null
SELECT json_agg(row_to_json(t))::text
FROM (SELECT id, name, descr, created_by_id, created
      FROM tagg.project WHERE is_active = true
      ORDER BY id) t;
SQL
