#!/usr/bin/env bash
set -euo pipefail

PROJECT="task_train_fresh_${RANDOM}_${RANDOM}"
PORT="${TEST_DB_PORT:-15432}"
WEB_PORT="${TEST_WEB_PORT:-13000}"
PASSWORD="test-password-abcdefghijklmnopqrstuvwxyz"

cleanup() {
    TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose down -v --remove-orphans
}
trap cleanup EXIT

bash tests/test_configure.sh
bash -n configure.sh setup.sh start.sh tools/*.sh agent-scripts/opencode_agent.sh
python3 -m py_compile supervisor/db_supervisor.py

TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" TASK_TRAIN_DB_PORT="$PORT" TASK_TRAIN_WEB_PORT="$WEB_PORT" \
POSTGRES_DB="task_train_test" POSTGRES_USER="task_train_test" POSTGRES_PASSWORD="$PASSWORD" \
docker compose up -d --build --wait

TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T app bash tools/smoke_test.sh
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T web python -c "from urllib.request import urlopen; import json; assert json.load(urlopen('http://127.0.0.1:8000/api/health'))['status'] == 'ok'; conversations = json.load(urlopen('http://127.0.0.1:8000/api/conversations'))['conversations']; assert conversations; assert json.load(urlopen(f\"http://127.0.0.1:8000/api/conversations/{conversations[0]['id']}\"))['conversation']['id'] == conversations[0]['id']; assert 'Task Train' in urlopen('http://127.0.0.1:8000/').read().decode()"
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T app bash tests/run.sh
