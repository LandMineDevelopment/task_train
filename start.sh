#!/usr/bin/env bash
# =============================================================================
# start.sh — Start the agent task system and open an opencode chat
# =============================================================================
# Starts the supervisor daemon in the background and opens an interactive
# opencode session with the Conductor agent. When you exit opencode, the
# supervisor is shut down cleanly.
#
# Usage:
#   bash start.sh                    # start + opencode chat with Conductor
#   bash start.sh --supervisor-only  # just start the background supervisor
#   bash start.sh --chat-only        # just open the chat (supervisor must be running)
# =============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
SUPERVISOR_LOG="/tmp/opencode-supervisor.log"
SUPERVISOR_PIDFILE="/tmp/opencode-supervisor.pid"

cd "$PROJECT_ROOT"

start_supervisor() {
    if [ -f "$SUPERVISOR_PIDFILE" ] && kill -0 "$(cat "$SUPERVISOR_PIDFILE")" 2>/dev/null; then
        echo "[start] Supervisor already running (PID $(cat "$SUPERVISOR_PIDFILE"))"
        return 0
    fi

    echo "[start] Syncing agent configs from DB..."
    bash sync_agents.sh 2>&1 | sed 's/^/  /'

    echo "[start] Starting supervisor..."
    nohup python3 -u supervisor/db_supervisor.py > "$SUPERVISOR_LOG" 2>&1 &
    SUPERVISOR_PID=$!
    echo "$SUPERVISOR_PID" > "$SUPERVISOR_PIDFILE"

    # Wait for supervisor to initialize
    sleep 2
    if kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
        echo "[start] Supervisor started (PID $SUPERVISOR_PID)"
        echo "[start] Log: $SUPERVISOR_LOG"
    else
        echo "[start] ERROR: Supervisor failed to start. Log:"
        cat "$SUPERVISOR_LOG"
        exit 1
    fi
}

stop_supervisor() {
    if [ -f "$SUPERVISOR_PIDFILE" ]; then
        PID=$(cat "$SUPERVISOR_PIDFILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo "[start] Stopping supervisor (PID $PID)..."
            kill "$PID" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$SUPERVISOR_PIDFILE"
    fi
}

# Parse args
MODE="both"
for arg in "$@"; do
    case "$arg" in
        --supervisor-only) MODE="supervisor-only" ;;
        --chat-only) MODE="chat-only" ;;
    esac
done

case "$MODE" in
    supervisor-only)
        start_supervisor
        echo "[start] Supervisor running in background. Stop it with: kill \$(cat $SUPERVISOR_PIDFILE)"
        ;;
    chat-only)
        if [ ! -f "$SUPERVISOR_PIDFILE" ] || ! kill -0 "$(cat "$SUPERVISOR_PIDFILE")" 2>/dev/null; then
            echo "[start] Supervisor not running. Start it first: bash start.sh --supervisor-only"
            exit 1
        fi
        bash tools/conductor_chat.sh
        ;;
    both)
        # Trap to clean up supervisor on exit
        cleanup() { stop_supervisor; }
        trap cleanup EXIT INT TERM

        start_supervisor
        echo ""
        echo "==============================================================="
        echo "  Agent Task System — Chat with Conductor"
        echo "==============================================================="
        echo "  Tell Conductor what you want to accomplish."
        echo "  It will create tasks for specialized agents as needed."
        echo ""
        echo "  Type '/exit' or press Ctrl-D when done."
        echo "==============================================================="
        echo ""
        bash tools/conductor_chat.sh
        ;;
esac
