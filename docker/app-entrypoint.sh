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
}
Path('/tmp/agents.container.json').write_text(json.dumps(config))
PY
chown app:app /tmp/agents.container.json
psql --no-psqlrc -v ON_ERROR_STOP=1 -f /workspace/sql/browser_chat_workflow.sql >/dev/null
psql --no-psqlrc -v ON_ERROR_STOP=1 -f /workspace/sql/conductor_workflow.sql >/dev/null
psql --no-psqlrc -v ON_ERROR_STOP=1 -f /workspace/sql/conversation_progress.sql >/dev/null
exec runuser -u app -- "$@"
