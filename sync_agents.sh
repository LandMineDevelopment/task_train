#!/usr/bin/env bash
# =============================================================================
# sync_agents.sh — Render agent configs from DB to filesystem .md files
# =============================================================================
# Reads tagg.user for every active agent, calls tagg.render_agent_config(id),
# and writes the result to agents/<name>.md and .opencode/agents/<name>.md.
#
# This is the bridge between DB-stored config and opencode's file-based
# agent loading.  Run after any change to agent prompts or permissions.
#
# Usage:
#   bash sync_agents.sh                    # write to agents/ + .opencode/agents/
#   bash sync_agents.sh --dir agents       # write only to agents/
#   bash sync_agents.sh --dry-run          # preview without writing
# =============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=false

TARGET_DIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) TARGET_DIRS+=("$2"); shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ ${#TARGET_DIRS[@]} -eq 0 ]; then
    TARGET_DIRS=("$PROJECT_ROOT/agents" "$PROJECT_ROOT/.opencode/agents")
fi

for d in "${TARGET_DIRS[@]}"; do
    mkdir -p "$d"
done

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

echo "[sync] Rendering agent configs from DB..."
echo "[sync] Targets: ${TARGET_DIRS[*]}"
echo ""

AGENTS=$(psql --no-psqlrc -A -t -F'|' \
    -c "SELECT id, name FROM tagg.user WHERE is_agent=true AND is_active=true AND opencode_config IS NOT NULL AND prompt IS NOT NULL ORDER BY id" 2>/dev/null)

if [ -z "$AGENTS" ]; then
    echo "[sync] No agents found with both opencode_config and prompt."
    exit 0
fi

echo "$AGENTS" | while IFS='|' read -r id name; do
    echo "[sync] $name (id=$id)..."

    CONTENT=$(psql --no-psqlrc -A -t \
        -c "SELECT tagg.render_agent_config($id)" 2>/dev/null)

    if [ -z "$CONTENT" ]; then
        echo "  WARNING: render_agent_config returned empty for $name"
        continue
    fi

    for dir in "${TARGET_DIRS[@]}"; do
        FILE="$dir/${name}.md"
        if [ "$DRY_RUN" = true ]; then
            echo "  -> $FILE (${#CONTENT} chars)"
        else
            # Ensure the file ends with exactly one newline
            printf '%s\n' "$CONTENT" > "$FILE"
            echo "  wrote $FILE (${#CONTENT} chars)"
        fi
    done
done

echo ""
echo "[sync] Done."
