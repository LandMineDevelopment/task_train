#!/usr/bin/env bash
set -euo pipefail

export CONVERSATION_ID="${CONVERSATION_ID:-1}"
export FROM_USER="${FROM_USER:-18}"
export TO_USER="${TO_USER:-8}"
export SNAPSHOT_FILE="${1:-/tmp/opencode-sessions-before}"

if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "  no snapshot file at $SNAPSHOT_FILE, skipping import"
  exit 0
fi

python3 << 'PYEOF'
import json, os, subprocess, sys

conv_id = int(os.environ['CONVERSATION_ID'])
from_user = int(os.environ['FROM_USER'])
to_user = int(os.environ['TO_USER'])
snapshot = os.environ['SNAPSHOT_FILE']

with open(snapshot) as f:
    before = set(line.strip() for line in f if line.strip())

out = subprocess.run(['opencode', 'session', 'list'], capture_output=True, text=True, timeout=15)
lines = out.stdout.strip().split('\n')[2:] if out.stdout.strip() else []

new = []
for line in lines:
    sid = line.split()[0] if line.strip() else ''
    if sid and sid not in before:
        new.append(sid)

if not new:
    sys.exit(0)

for sid in reversed(new):
    r = subprocess.run(['opencode', 'export', sid], capture_output=True, text=True, timeout=30)
    raw = r.stdout.strip()
    start = raw.find('{')
    if start < 0:
        continue
    data = json.loads(raw[start:])
    msgs = data.get('messages', [])

    oc_to_db = {}
    count = 0
    for msg in msgs:
        info = msg.get('info', {})
        role = info.get('role', '')
        parent = info.get('parentID', info.get('parentId', ''))
        parts = msg.get('parts', [])
        text_parts = [p.get('text', '') for p in parts if p.get('type') == 'text']
        body = '\n'.join(text_parts).strip()
        if not body:
            continue

        if role == 'user':
            from_id, to_id = from_user, to_user
        elif role == 'assistant':
            from_id, to_id = to_user, from_user
        else:
            continue

        mid = info.get('id', '')
        pid = oc_to_db.get(parent, 'NULL')

        quoted = body.replace("'", "''")
        q = (
            f"INSERT INTO tagg.message (conversation_id, message, from_user, to_user, "
            f"original_theme_alignment, parent_id) "
            f"VALUES ({conv_id}, '{quoted}', {from_id}, {to_id}, 0, {pid}) "
            f"ON CONFLICT DO NOTHING RETURNING id;"
        )
        res = subprocess.run(
            ['psql', '-h', 'localhost', '-U', 'kasey', '-d', 'task_train',
             '--no-psqlrc', '-A', '-t'],
            input=q, capture_output=True, text=True, timeout=10
        )
        inserted = res.stdout.strip()
        if inserted:
            oc_to_db[mid] = inserted
            count += 1

    info_data = data.get('info', {})
    agent = info_data.get('agent', info_data.get('title', sid))
    print(f'  imported {count} messages from session {sid} ({agent})')

PYEOF
