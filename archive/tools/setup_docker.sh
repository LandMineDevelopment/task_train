#!/usr/bin/env bash
set -euo pipefail

# Docker-first setup: writes .env, builds images, and starts local services.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash ./configure.sh --non-interactive "$@"
docker compose up -d --build

set -a
source ./.env
set +a
printf '\nTask Train is running at http://localhost:%s\n' "$TASK_TRAIN_WEB_PORT"
printf 'Authenticate a model provider before sending chat messages:\n'
printf '  bash tools/opencode_auth.sh\n'
