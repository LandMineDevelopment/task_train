#!/usr/bin/env bash
set -euo pipefail

mkdir -p /home/app/.local/share/opencode /home/app/.config/opencode
chown -R app:app /home/app/.local /home/app/.config
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
exec runuser -u app -- "$@"
