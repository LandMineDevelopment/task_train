#!/usr/bin/env bash
set -euo pipefail

# Native installation for users who already run PostgreSQL locally.
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

command -v psql >/dev/null || { echo "psql is required" >&2; exit 1; }
command -v opencode >/dev/null || { echo "opencode is required" >&2; exit 1; }
python3 -c 'import psycopg' >/dev/null || { echo "Install requirements.txt first" >&2; exit 1; }

bash setup.sh --db-local
test -f supervisor/agents.json || cp supervisor/agents.example.json supervisor/agents.json
echo "Installation complete. Update supervisor/agents.json, then run bash start.sh."
