#!/usr/bin/env bash
set -euo pipefail

mkdir -p /home/app/.local/share/opencode /home/app/.config/opencode
chown -R app:app /home/app/.local /home/app/.config
rm -f /tmp/agents.container.json
python3 - <<'PY'
import json
import os
from pathlib import Path

config = json.loads(Path('/workspace/supervisor/agents.container.template.json').read_text())
config['db'] = {
    'host': os.environ['PGHOST'],
    'port': int(os.environ['PGPORT']),
    'dbname': os.environ['PGDATABASE'],
    'user': os.environ['PGUSER'],
    'password': os.environ['PGPASSWORD'],
    'worker_user': os.environ.get('PGWORKER_USER', 'task_train_worker'),
    'worker_password': os.environ.get('PGWORKER_PASSWORD', os.environ['PGPASSWORD']),
}
Path('/tmp/agents.container.json').write_text(json.dumps(config))
PY
chown root:root /tmp/agents.container.json
chmod 600 /tmp/agents.container.json
psql --no-psqlrc -v ON_ERROR_STOP=1 -v worker_password="$PGWORKER_PASSWORD" -f /workspace/sql/runtime_migrations.sql >/dev/null
if [[ "${1:-}" == "python3" && "${2:-}" == "-u" && "${3:-}" == "supervisor/db_supervisor.py" ]]; then
    exec "$@"
fi
exec runuser -u app -- "$@"
