#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# send_message.sh <conversation_id> <from_user_id> <to_user_id> <message_text>
# Posts a message to a conversation, threading it as a reply to the last message.

CONV_ID="${1:?usage: send_message.sh <conv_id> <from> <to> <message>}"
FROM="${2:?}"
TO="${3:?}"
MSG="${4:?}"

msg_q="${MSG//\'/\'\'}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT json_build_object(
  'success', true,
  'message_id', tagg.append_conversation_message(
    $CONV_ID,
    $FROM,
    $TO,
    '$msg_q',
    CASE WHEN (SELECT is_agent FROM tagg.user WHERE id = $FROM) THEN 'assistant' ELSE 'user' END
  )
)::text;
SQL
