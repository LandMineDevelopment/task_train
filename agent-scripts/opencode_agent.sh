#!/usr/bin/env bash
set -euo pipefail

# opencode_agent.sh
# Entry point for agent spawner. Reads instructions from conversation table,
# invokes opencode to let the LLM process the task, then auto-advances.
#
# Called by the supervisor with env:
#   TASK_ID, AGENT_USER_ID, CONVERSATION_ID, PGHOST, PGPORT, PGUSER, PGDATABASE

TASK_ID="${TASK_ID:?TASK_ID required}"
AGENT_USER_ID="${AGENT_USER_ID:?AGENT_USER_ID required}"
CONVERSATION_ID="${CONVERSATION_ID:?CONVERSATION_ID required}"
AGENT_RUN_TOKEN="${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"
export AGENT_RUN_TOKEN

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$PROJECT_ROOT"

# 1. Get agent name from DB
AGENT_NAME=$(psql --no-psqlrc -A -t \
  -c "SELECT name FROM tagg.user WHERE id = $AGENT_USER_ID" 2>/dev/null | tail -1)

echo "[agent] $AGENT_NAME (id=$AGENT_USER_ID) starting for task $TASK_ID, conversation $CONVERSATION_ID"

# 2. Sync agent config from DB to filesystem
bash sync_agents.sh --dir "$PROJECT_ROOT/agents" --dir "$PROJECT_ROOT/.opencode/agents" 2>&1 | sed 's/^/[sync] /'

# 3. Claim the task
CLAIM_RESULT=$(bash tools/claim_task.sh "$TASK_ID" "$AGENT_USER_ID")
echo "[agent] claim: $CLAIM_RESULT"

SUCCESS=$(echo "$CLAIM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
if [ "$SUCCESS" != "True" ]; then
  echo "[agent] task already claimed or not pending, exiting"
  exit 0
fi

CONVERSATION_KIND=$(psql --no-psqlrc -A -t -c "SELECT kind FROM tagg.conversation WHERE id = $CONVERSATION_ID" 2>/dev/null | tr -d '[:space:]')
if [ "$AGENT_NAME" = "Conductor" ] && [ "$CONVERSATION_KIND" = "user_conductor" ]; then
  RESPONSE=$(opencode run \
    --agent "$AGENT_NAME" \
    --dir "$PROJECT_ROOT" \
    "Read assigned task $TASK_ID and conversation $CONVERSATION_ID. Follow your database-backed system prompt and assigned skills. Return the final user-facing response on stdout.")
  RESPONSE="${RESPONSE#${RESPONSE%%[![:space:]]*}}"
  RESPONSE="${RESPONSE%${RESPONSE##*[![:space:]]}}"
  if [ -z "$RESPONSE" ]; then
    RESPONSE="The Conductor did not return a response."
    STATUS="failed"
  else
    STATUS="complete"
  fi
  RESPONSE_SQL=$(printf "%s" "$RESPONSE" | sed "s/'/''/g")
  RECIPIENT_ID=$(psql --no-psqlrc -A -t -c "SELECT owner_user_id FROM tagg.conversation WHERE id = $CONVERSATION_ID" 2>/dev/null | tr -d '[:space:]')
  psql --no-psqlrc -v ON_ERROR_STOP=1 -q -c \
    "SELECT tagg.append_conversation_message($CONVERSATION_ID, $AGENT_USER_ID, $RECIPIENT_ID, '$RESPONSE_SQL', 'assistant', '$STATUS');" >/dev/null
  if [ "$STATUS" = "complete" ]; then
    bash tools/advance_task.sh "$TASK_ID" "$AGENT_USER_ID" >/dev/null
  else
    bash tools/fail_task.sh "$TASK_ID" "$AGENT_USER_ID" "Conductor did not return a response" >/dev/null
  fi
  exit 0
fi

# 4. Invoke opencode — the agent reads instructions from the conversation
opencode run \
  --agent "$AGENT_NAME" \
  --dir "$PROJECT_ROOT" \
  --print-logs \
  "You are $AGENT_NAME (id=$AGENT_USER_ID) working on task $TASK_ID.
Conversation: $CONVERSATION_ID

EXECUTE THESE STEPS, CALLING THE TOOLS:

1. bash tools/read_conversation.sh $CONVERSATION_ID
2. bash tools/read_task.sh $TASK_ID
3. Process the task using the available tools
4. Save code/output as artifacts: bash tools/create_artifact.sh $TASK_ID $AGENT_USER_ID <name> <descr> <type> <body>
5. bash tools/advance_task.sh $TASK_ID $AGENT_USER_ID
   OR bash tools/fail_task.sh $TASK_ID $AGENT_USER_ID

IMPORTANT: You must actually CALL these tools. Do not just describe what you would do." > /tmp/opencode-agent-${TASK_ID}.log 2>&1

echo "[agent] opencode finished for task $TASK_ID" 2>/dev/null || true

# Agents must explicitly advance or fail tasks; a clean process exit is not proof of completion.
