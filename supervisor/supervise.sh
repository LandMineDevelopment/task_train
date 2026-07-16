#!/usr/bin/env bash
set -euo pipefail

# Supervisor: polls DB for pending tasks, spawns agent processes as the
# current user. Replaces the plpython3u trigger approach.
#
# Usage:
#   bash supervise.sh          # run in foreground
#   nohup bash supervise.sh &  # background
#
# Recommended: run as a systemd --user service.

POLL_INTERVAL="${POLL_INTERVAL:-2}"
PID_DIR="/tmp/opencode-supervisor"
mkdir -p "$PID_DIR"

log() { echo "[supervisor] $(date '+%H:%M:%S') $*"; }

cleanup() {
    log "shutting down, killing children..."
    for f in "$PID_DIR"/task_*.pid; do
        [ -f "$f" ] || continue
        kill "$(cat "$f")" 2>/dev/null || true
        rm -f "$f"
    done
    exit 0
}
trap cleanup SIGINT SIGTERM

log "started (pid=$$), polling every ${POLL_INTERVAL}s"

while true; do
    IFS='|' read -r task_id to_user_id command max_concurrent <<< "$(
        psql -h localhost -U kasey -d task_train --no-psqlrc -A -t 2>/dev/null \
        <<<'SELECT at.id, at.to_user_id, u.command, u.max_concurrent
            FROM tagg.agent_task at
            JOIN tagg.user u ON u.id = at.to_user_id
            WHERE at.task_status_id = 1 AND u.is_active = true AND u.command IS NOT NULL
            ORDER BY at.id LIMIT 1'
    )"

    if [ -n "$task_id" ]; then
        pidfile="$PID_DIR/task_${task_id}.pid"

        if [ ! -f "$pidfile" ]; then
            running="$(
                psql -h localhost -U kasey -d task_train --no-psqlrc -A -t 2>/dev/null \
                <<< "SELECT count(*)::int FROM tagg.agent_task WHERE to_user_id = $to_user_id AND task_status_id = 3"
            )"
            running="${running:-0}"

            if [ "$running" -lt "$max_concurrent" ]; then
                log "spawning task $task_id for agent $to_user_id (max_concurrent=$max_concurrent)"
                TASK_ID="$task_id" AGENT_USER_ID="$to_user_id" \
                PGHOST=localhost PGPORT=5432 PGDATABASE=task_train PGUSER=kasey \
                nohup bash -c "$command" > "$PID_DIR/agent_${task_id}.log" 2>&1 &
                echo $! > "$pidfile"
            fi
        fi
    fi

    # Reap finished children (always runs, not inside the task block)
    for f in "$PID_DIR"/task_*.pid; do
        [ -f "$f" ] || continue
        pid="$(cat "$f")"
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            tid="$(basename "$f" .pid)"
            tid="${tid#task_}"
            log "task $tid finished (pid=$pid)"
            rm -f "$f"
        fi
    done

    sleep "$POLL_INTERVAL"
done
