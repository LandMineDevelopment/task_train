#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# send_instruction.sh <from_user> <to_user> <task_id> <project_id> <message>
# Creates/finds a conversation for the agent pair and writes a message linked to the task.
# Returns JSON: {"conversation_id": ..., "message_id": ...}

FROM="${1:?usage: send_instruction.sh <from> <to> <task_id> <project_id> <message>}"
TO="${2:?}"
TASK_ID="${3:?}"
PROJECT_ID="${4:?}"
MESSAGE="${5:?}"

msg_q="${MESSAGE//\'/\'\'}"

if [ "$FROM" -lt "$TO" ]; then
  PAIR_KEY="pair:${FROM}-${TO}"
else
  PAIR_KEY="pair:${TO}-${FROM}"
fi
TITLE="Agent-${FROM} ↔ Agent-${TO}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
WITH
  conv AS (
    SELECT id FROM tagg.conversation
    WHERE original_theme = '$PAIR_KEY' AND project_id = $PROJECT_ID AND is_active = true
    LIMIT 1
  ),
  new_conv AS (
    INSERT INTO tagg.conversation (title, original_theme, project_id)
    SELECT '$TITLE', '$PAIR_KEY', $PROJECT_ID
    WHERE NOT EXISTS (SELECT 1 FROM conv)
    RETURNING id
  ),
  use_conv AS (
    SELECT COALESCE((SELECT id FROM conv), (SELECT id FROM new_conv)) AS id
  ),
  last_msg AS (
    SELECT id FROM tagg.message
    WHERE conversation_id = (SELECT id FROM use_conv) AND is_active = true
    ORDER BY id DESC LIMIT 1
  ),
  ins_msg AS (
    INSERT INTO tagg.message (conversation_id, message, from_user, to_user, original_theme_alignment, parent_id)
    SELECT (SELECT id FROM use_conv), '$msg_q', $FROM, $TO, 0, (SELECT id FROM last_msg)
    RETURNING id AS message_id
  ),
  link AS (
    INSERT INTO tagg.message_agent_task_crosswalk (message_id, agent_task_id)
    SELECT (SELECT message_id FROM ins_msg), $TASK_ID
    WHERE NOT EXISTS (
      SELECT 1 FROM tagg.message_agent_task_crosswalk
      WHERE message_id = (SELECT message_id FROM ins_msg) AND agent_task_id = $TASK_ID
    )
  )
SELECT json_build_object(
  'conversation_id', (SELECT id FROM use_conv),
  'message_id', (SELECT message_id FROM ins_msg)
)::text;
SQL