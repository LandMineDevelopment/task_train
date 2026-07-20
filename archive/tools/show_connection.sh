#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || { printf 'No .env found. Run ./configure.sh first.\n' >&2; exit 1; }

while IFS='=' read -r key value; do
    case "$key" in
        TASK_TRAIN_DB_PORT) PORT="$value" ;;
        POSTGRES_DB) DATABASE="$value" ;;
        POSTGRES_USER) USERNAME="$value" ;;
        POSTGRES_PASSWORD) PASSWORD="$value" ;;
    esac
done < "$ENV_FILE"

printf 'Host: localhost\nPort: %s\nDatabase: %s\nUsername: %s\nPassword: %s\n' "$PORT" "$DATABASE" "$USERNAME" "$PASSWORD"
