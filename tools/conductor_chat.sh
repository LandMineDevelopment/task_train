#!/usr/bin/env bash
set -euo pipefail

# Interactive, DB-backed chat with the Conductor agent. Each user turn and
# final agent response is recorded before the next prompt is accepted.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

PROJECT_ID="${PROJECT_ID:-3}"
USER_NAME="${CHAT_USER:-kasey}"
CONDUCTOR_NAME="${CONDUCTOR_NAME:-Conductor}"
CONTEXT_LIMIT="${CONTEXT_LIMIT:-20}"

sql_scalar() {
    psql --no-psqlrc -A -t -v ON_ERROR_STOP=1 -c "$1" | tr -d '[:space:]'
}

quote_sql() {
    printf "%s" "$1" | sed "s/'/''/g"
}

USER_ID="$(sql_scalar "SELECT id FROM tagg.user WHERE name = '$(quote_sql "$USER_NAME")' AND is_active = true AND is_agent = false")"
CONDUCTOR_ID="$(sql_scalar "SELECT id FROM tagg.user WHERE name = '$(quote_sql "$CONDUCTOR_NAME")' AND is_active = true AND is_agent = true")"

if [[ -z "$USER_ID" || -z "$CONDUCTOR_ID" ]]; then
    echo "Active user '$USER_NAME' or agent '$CONDUCTOR_NAME' was not found." >&2
    exit 1
fi

CONVERSATION_ID="$(sql_scalar "SELECT tagg.get_or_create_user_conductor_conversation($PROJECT_ID, $USER_ID, $CONDUCTOR_ID)")"
echo "DB-backed Conductor chat. Conversation $CONVERSATION_ID. Type /exit to quit."

while true; do
    read -r -p "you> " USER_MESSAGE || break
    [[ "$USER_MESSAGE" == "/exit" || "$USER_MESSAGE" == "/quit" ]] && break
    [[ -z "$USER_MESSAGE" ]] && continue

    USER_MESSAGE_SQL="$(quote_sql "$USER_MESSAGE")"
    psql --no-psqlrc -v ON_ERROR_STOP=1 -q -c \
        "SELECT tagg.append_conversation_message($CONVERSATION_ID, $USER_ID, $CONDUCTOR_ID, '$USER_MESSAGE_SQL', 'user');" >/dev/null

    CONTEXT="$(psql --no-psqlrc -A -t -v ON_ERROR_STOP=1 -c "SELECT tagg.get_conversation_context($CONVERSATION_ID, $CONTEXT_LIMIT)")"
    PROMPT="You are responding in database conversation $CONVERSATION_ID. The gateway already recorded the user turn and will record your final answer. Do not call send_message.sh. Use this recent conversation context:\n\n$CONTEXT\n\nRespond to the latest user message."

    RESPONSE="$(opencode run --agent "$CONDUCTOR_NAME" --dir "$PROJECT_ROOT" "$PROMPT")"
    RESPONSE="${RESPONSE#${RESPONSE%%[![:space:]]*}}"
    RESPONSE="${RESPONSE%${RESPONSE##*[![:space:]]}}"
    if [[ -z "$RESPONSE" ]]; then
        RESPONSE="The Conductor did not return a response."
        STATUS="failed"
    else
        STATUS="complete"
    fi

    RESPONSE_SQL="$(quote_sql "$RESPONSE")"
    psql --no-psqlrc -v ON_ERROR_STOP=1 -q -c \
        "SELECT tagg.append_conversation_message($CONVERSATION_ID, $CONDUCTOR_ID, $USER_ID, '$RESPONSE_SQL', 'assistant', '$STATUS');" >/dev/null
    printf '\nconductor> %s\n\n' "$RESPONSE"
done
