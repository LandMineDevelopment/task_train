#!/usr/bin/env bash
set -euo pipefail

PROJECT="task_train_fresh_${RANDOM}_${RANDOM}"
PORT="${TEST_DB_PORT:-15432}"
PASSWORD="test-password-abcdefghijklmnopqrstuvwxyz"

cleanup() {
    TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose down -v --remove-orphans
}
trap cleanup EXIT

bash tests/test_configure.sh
bash -n configure.sh setup.sh start.sh tools/*.sh agent-scripts/opencode_agent.sh
python3 -m py_compile supervisor/db_supervisor.py

TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" TASK_TRAIN_DB_PORT="$PORT" \
POSTGRES_DB="task_train_test" POSTGRES_USER="task_train_test" POSTGRES_PASSWORD="$PASSWORD" \
docker compose up -d --build

TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T app bash tools/smoke_test.sh
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T app bash tests/run.sh
