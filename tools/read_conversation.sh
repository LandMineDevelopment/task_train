#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# read_conversation.sh <conversation_id>
# Returns all messages in a conversation as JSON array.

CONV_ID="${1:?usage: read_conversation.sh <conversation_id>}"
: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"
[[ "$CONV_ID" =~ ^[0-9]+$ ]] || { printf 'Conversation ID must be numeric.\n' >&2; exit 2; }

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT tagg.get_conversation_for_run('$AGENT_RUN_TOKEN', $CONV_ID)::text;
SQL
