#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

# read_conversation.sh <conversation_id>
# Returns all messages in a conversation as JSON array.

CONV_ID="${1:?usage: read_conversation.sh <conversation_id>}"

psql --no-psqlrc -A -t 2>/dev/null <<SQL
SELECT json_agg(row_to_json(t) ORDER BY t.id)::text
FROM (
  SELECT id, message, from_user, to_user, original_theme_alignment, parent_id, created
  FROM tagg.message
  WHERE conversation_id = $CONV_ID AND is_active = true
) t;
SQL
