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
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose stop supervisor
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T web python3 -c "from urllib.request import Request, urlopen; import json; headers = {'Content-Type': 'application/json'}; assert json.load(urlopen('http://127.0.0.1:8000/api/health'))['status'] == 'ok'; conversations = json.load(urlopen('http://127.0.0.1:8000/api/conversations'))['conversations']; assert conversations; assert json.load(urlopen(f\"http://127.0.0.1:8000/api/conversations/{conversations[0]['id']}\"))['conversation']['id'] == conversations[0]['id']; request = Request('http://127.0.0.1:8000/api/conversations', data=b'{\"title\": \"Browser test\"}', headers=headers, method='POST'); created = json.load(urlopen(request)); request = Request(f\"http://127.0.0.1:8000/api/conversations/{created['conversation_id']}\", data=b'{\"title\": \"Renamed browser test\"}', headers=headers, method='PATCH'); assert json.load(urlopen(request))['conversation']['title'] == 'Renamed browser test'; request = Request(f\"http://127.0.0.1:8000/api/conversations/{created['conversation_id']}/messages\", data=b'{\"message\": \"Verify workflow dispatch.\"}', headers=headers, method='POST'); queued = json.load(urlopen(request)); assert queued['status'] == 'queued'; detail = json.load(urlopen(f\"http://127.0.0.1:8000/api/conversations/{created['conversation_id']}\")); assert detail['conversation']['title'] == 'Renamed browser test'; assert any(task['id'] == queued['task_id'] and task['artifacts'] == [] for task in detail['tasks']); assert 'Task Train' in urlopen('http://127.0.0.1:8000/').read().decode(); print(queued['task_id'])" > /tmp/browser-task-id
TASK_ID="$(tr -d '[:space:]' < /tmp/browser-task-id)"
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T app psql --no-psqlrc -v ON_ERROR_STOP=1 -c "SELECT 1 FROM tagg.agent_task WHERE id = $TASK_ID AND task_status_id = 1 AND conversation_id IS NOT NULL AND workflow_id = (SELECT id FROM tagg.workflow WHERE name = 'quick');"
ARTIFACT_ID="$(TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T app psql --no-psqlrc -qAt -v ON_ERROR_STOP=1 -c "INSERT INTO tagg.artifact(agent_task_id, name, descr, artifact_type, body) VALUES ($TASK_ID, 'browser-test.py', 'browser artifact endpoint test', 'code', 'print(1)') RETURNING id;")"
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T web python3 -c "from urllib.request import urlopen; import json; task = json.load(urlopen('http://127.0.0.1:8000/api/tasks/$TASK_ID')); assert task['id'] == $TASK_ID and task['artifacts'][0]['id'] == $ARTIFACT_ID; artifact = json.load(urlopen('http://127.0.0.1:8000/api/artifacts/$ARTIFACT_ID')); assert artifact['task_id'] == $TASK_ID and artifact['body'] == 'print(1)'; assert any(item['id'] == $TASK_ID for item in json.load(urlopen('http://127.0.0.1:8000/api/tasks'))['tasks']); assert any(item['id'] == $ARTIFACT_ID for item in json.load(urlopen('http://127.0.0.1:8000/api/artifacts'))['artifacts'])"
TASK_TRAIN_COMPOSE_PROJECT="$PROJECT" docker compose exec -T app bash tests/run.sh
