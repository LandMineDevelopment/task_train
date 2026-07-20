#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-task_train}"
export PGDATABASE="${PGDATABASE:-task_train}"

psql --no-psqlrc -v ON_ERROR_STOP=1 <<'SQL'
SELECT 1 FROM tagg.user WHERE name = 'Conductor' AND is_agent;
SELECT 1 FROM tagg.project WHERE name = 'default';
SELECT tagg.get_or_create_user_conductor_conversation(
  (SELECT id FROM tagg.project WHERE name = 'default'),
  (SELECT id FROM tagg.user WHERE name = 'local-user'),
  (SELECT id FROM tagg.user WHERE name = 'Conductor')
);
SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'task_ready_notification');
SQL
