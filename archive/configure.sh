#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT/.env"
PORT="${TASK_TRAIN_DB_PORT:-5433}"
WEB_PORT="${TASK_TRAIN_WEB_PORT:-3000}"
DATABASE="${POSTGRES_DB:-task_train}"
USERNAME="${POSTGRES_USER:-task_train}"
PASSWORD="${POSTGRES_PASSWORD:-}"
WORKER_PASSWORD="${POSTGRES_WORKER_PASSWORD:-}"
PROJECT="${TASK_TRAIN_COMPOSE_PROJECT:-task_train}"
INTERACTIVE=true
OLD_DATABASE=""
OLD_USERNAME=""
OLD_PASSWORD=""
OLD_PROJECT=""

usage() {
    printf 'Usage: %s [--port PORT] [--web-port PORT] [--database NAME] [--user NAME] [--password PASSWORD] [--project NAME] [--non-interactive]\n' "$0"
}

generate_password() {
    local value=""
    while (( ${#value} < 32 )); do
        value+="$(LC_ALL=C tr -dc 'A-Za-z0-9_@%+=.,/-' </dev/urandom | head -c 64 || true)"
    done
    printf '%s' "${value:0:32}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="${2:?missing port}"; shift 2 ;;
        --web-port) WEB_PORT="${2:?missing web port}"; shift 2 ;;
        --database) DATABASE="${2:?missing database}"; shift 2 ;;
        --user) USERNAME="${2:?missing user}"; shift 2 ;;
        --password) PASSWORD="${2:?missing password}"; shift 2 ;;
        --project) PROJECT="${2:?missing project}"; shift 2 ;;
        --non-interactive) INTERACTIVE=false; shift ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key value; do
        case "$key" in
            TASK_TRAIN_DB_PORT) [[ "$PORT" == "5433" ]] && PORT="$value" ;;
            TASK_TRAIN_WEB_PORT) [[ "$WEB_PORT" == "3000" ]] && WEB_PORT="$value" ;;
            POSTGRES_DB) OLD_DATABASE="$value"; [[ "$DATABASE" == "task_train" ]] && DATABASE="$value" ;;
            POSTGRES_USER) OLD_USERNAME="$value"; [[ "$USERNAME" == "task_train" ]] && USERNAME="$value" ;;
            POSTGRES_PASSWORD) OLD_PASSWORD="$value"; [[ -z "$PASSWORD" ]] && PASSWORD="$value" ;;
            POSTGRES_WORKER_PASSWORD) [[ -z "$WORKER_PASSWORD" ]] && WORKER_PASSWORD="$value" ;;
            TASK_TRAIN_COMPOSE_PROJECT) OLD_PROJECT="$value"; [[ "$PROJECT" == "task_train" ]] && PROJECT="$value" ;;
        esac
    done < "$ENV_FILE"
fi

if [[ "$INTERACTIVE" == true ]]; then
    read -r -p "Host database port [$PORT]: " value; PORT="${value:-$PORT}"
    read -r -p "Browser web port [$WEB_PORT]: " value; WEB_PORT="${value:-$WEB_PORT}"
    read -r -p "Database name [$DATABASE]: " value; DATABASE="${value:-$DATABASE}"
    read -r -p "Database user [$USERNAME]: " value; USERNAME="${value:-$USERNAME}"
    read -r -p "Compose project name [$PROJECT]: " value; PROJECT="${value:-$PROJECT}"
fi

if [[ -z "$PASSWORD" ]]; then
    PASSWORD="$(generate_password)"
    printf 'Generated a database password. It is stored only in %s.\n' "$ENV_FILE"
fi
if [[ -z "$WORKER_PASSWORD" ]]; then
    WORKER_PASSWORD="$(generate_password)"
fi

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { printf 'Port must be between 1 and 65535.\n' >&2; exit 1; }
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] && (( WEB_PORT >= 1 && WEB_PORT <= 65535 )) || { printf 'Web port must be between 1 and 65535.\n' >&2; exit 1; }
[[ "$DATABASE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'Database name must be alphanumeric or underscore.\n' >&2; exit 1; }
[[ "$USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'User name must be alphanumeric or underscore.\n' >&2; exit 1; }
[[ "$PROJECT" =~ ^[A-Za-z0-9_-]+$ ]] || { printf 'Project name contains unsupported characters.\n' >&2; exit 1; }
[[ "$PASSWORD" =~ ^[A-Za-z0-9_@%+=.,/-]+$ ]] || { printf 'Password may contain letters, numbers, and _@%%+=.,/-.\n' >&2; exit 1; }

if [[ -n "$OLD_PROJECT" && "$PROJECT" == "$OLD_PROJECT" ]] \
    && [[ "$DATABASE" != "$OLD_DATABASE" || "$USERNAME" != "$OLD_USERNAME" || "$PASSWORD" != "$OLD_PASSWORD" ]] \
    && docker volume inspect "${OLD_PROJECT}_task_train_data" >/dev/null 2>&1; then
    printf 'Database name, user, or password cannot change while the %s database volume exists.\n' "$OLD_PROJECT" >&2
    printf 'To discard its data and apply new credentials: docker compose down -v\n' >&2
    exit 1
fi

umask 077
{
    printf 'TASK_TRAIN_COMPOSE_PROJECT=%s\n' "$PROJECT"
    printf 'TASK_TRAIN_DB_PORT=%s\n' "$PORT"
    printf 'TASK_TRAIN_WEB_PORT=%s\n' "$WEB_PORT"
    printf 'POSTGRES_DB=%s\n' "$DATABASE"
    printf 'POSTGRES_USER=%s\n' "$USERNAME"
    printf 'POSTGRES_PASSWORD=%s\n' "$PASSWORD"
    printf 'POSTGRES_WORKER_PASSWORD=%s\n' "$WORKER_PASSWORD"
} > "$ENV_FILE"

printf 'Wrote %s. Start with: docker compose up -d --build\n' "$ENV_FILE"
