#!/usr/bin/env bash
set -euo pipefail

# Run OpenCode login as the persisted container user, never root.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

docker compose exec -it --user app -e HOME=/home/app app opencode auth login
docker compose exec -T --user app -e HOME=/home/app app opencode auth list
