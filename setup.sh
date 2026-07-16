#!/usr/bin/env bash
# =============================================================================
# setup.sh — Bootstrap the postgres + opencode agent system on a new machine
# =============================================================================
# Usage:
#   bash setup.sh                    # interactive (prompts for DB details)
#   bash setup.sh --db-local         # quick: assumes local trust auth
#   bash setup.sh --db-local --db task_train --user "$USER"
#
# What it does:
#   1. Detects project root (portable)
#   2. Checks/creates the database
#   3. Runs SQL migrations in order
#   4. Verifies key functions exist
#   5. Creates supervisor config if missing
#   6. Prints ready-to-use instructions
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# Detect project root (portable: wherever this script lives)
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

echo "==================================="
echo " Agent Task System — Setup"
echo " Project root: $PROJECT_ROOT"
echo "==================================="

# ------------------------------------------------------------------
# DB config
# ------------------------------------------------------------------
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-task_train}"
DB_USER="${DB_USER:-$USER}"

if [[ "${1:-}" == "--db-local" ]]; then
    :  # use defaults
else
    read -rp "PostgreSQL host [$DB_HOST]: " input; DB_HOST="${input:-$DB_HOST}"
    read -rp "PostgreSQL port [$DB_PORT]: " input; DB_PORT="${input:-$DB_PORT}"
    read -rp "Database name [$DB_NAME]: " input; DB_NAME="${input:-$DB_NAME}"
    read -rp "Database user [$DB_USER]: " input; DB_USER="${input:-$DB_USER}"
fi

export PGHOST="$DB_HOST"
export PGPORT="$DB_PORT"
export PGUSER="$DB_USER"
export PGDATABASE="$DB_NAME"

# ------------------------------------------------------------------
# 1. Check psql
# ------------------------------------------------------------------
echo ""
echo "--- Step 1: Checking psql ---"
command -v psql >/dev/null 2>&1 || fail "psql not found. Install PostgreSQL client."
python3 -c "import psycopg" >/dev/null 2>&1 || fail "psycopg missing. Install the Python package listed in requirements.txt."

# ------------------------------------------------------------------
# 2. Check / create database
# ------------------------------------------------------------------
echo "--- Step 2: Database ---"
if psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    pass "Database '$DB_NAME' exists"
else
    warn "Database '$DB_NAME' not found. Attempting to create..."
    createdb "$DB_NAME" 2>/dev/null && pass "Created database '$DB_NAME'" \
        || fail "Cannot create database. Run: createdb $DB_NAME"
fi

# ------------------------------------------------------------------
# 3. Run SQL migrations
# ------------------------------------------------------------------
echo "--- Step 3: SQL migrations ---"
SQL_FILES=(
    "sql/000_core.sql"
    "sql/agent_config.sql"
    "sql/permissions.sql"
    "sql/workflow.sql"
    "sql/regress_workflow.sql"
    "sql/role_agents.sql"
    "sql/agent_config_db.sql"
    "sql/conversation_gateway.sql"
    "sql/hardening.sql"
    "sql/workflow_hardening.sql"
)

for f in "${SQL_FILES[@]}"; do
    if [ -f "$f" ]; then
        echo "  Running $f ..."
        psql -v ON_ERROR_STOP=1 -f "$f"
        pass "Applied $f"
    else
        warn "SQL file not found: $f (skipping)"
    fi
done

# ------------------------------------------------------------------
# 4. Verify functions
# ------------------------------------------------------------------
echo "--- Step 4: Verification ---"
for fn in claim_task get_agent_context get_pending_tasks \
           agent_task_add artifact_add advance_workflow message_add \
           set_agent_id require_permission check_permission; do
    count=$(psql -A -t -c "SELECT count(*) FROM pg_proc WHERE proname='$fn' AND pronamespace='tagg'::regnamespace" 2>/dev/null | tail -1)
    if [ "$count" -gt 0 ]; then
        pass "Function tagg.$fn exists"
    else
        warn "Function tagg.$fn not found (may be created in a later migration)"
    fi
done

# ------------------------------------------------------------------
# 5. Check for existing agents
# ------------------------------------------------------------------
echo "--- Step 5: Agents ---"
agent_count=$(psql -A -t -c "SELECT count(*) FROM tagg.user WHERE is_agent=true AND is_active=true" 2>/dev/null | tail -1)
if [ "$agent_count" -gt 0 ]; then
    pass "$agent_count active agents found in DB"
    psql -A -t -c "SELECT id, name FROM tagg.user WHERE is_agent=true AND is_active=true ORDER BY id" 2>/dev/null
else
    warn "No active agents found. Run sql/role_agents.sql to create them."
fi

# ------------------------------------------------------------------
# 6. Create supervisor config (if missing)
# ------------------------------------------------------------------
echo "--- Step 6: Supervisor config ---"
if [ -f "supervisor/agents.json" ]; then
    pass "supervisor/agents.json exists"
else
    warn "Creating default supervisor/agents.json"
    cat > supervisor/agents.json <<JSON
{
  "project_root": "..",
  "agents": [
    { "name": "Conductor", "descr": "Technical lead", "command": "agent-scripts/opencode_agent.sh", "max_concurrent": 3 },
    { "name": "Coder",     "descr": "Implements code", "command": "agent-scripts/opencode_agent.sh", "max_concurrent": 2 },
    { "name": "Tester",    "descr": "Writes tests",    "command": "agent-scripts/opencode_agent.sh", "max_concurrent": 2 },
    { "name": "Explorer",  "descr": "Researches",      "command": "agent-scripts/opencode_agent.sh", "max_concurrent": 3 },
    { "name": "Reviewer",  "descr": "Reviews code",    "command": "agent-scripts/opencode_agent.sh", "max_concurrent": 2 }
  ],
  "db": {
    "host": "$DB_HOST", "port": $DB_PORT, "dbname": "$DB_NAME", "user": "$DB_USER"
  },
  "supervisor": {
    "max_total_processes": 10, "reconcile_interval": 60.0, "task_timeout": 300
  }
}
JSON
    pass "Created supervisor/agents.json"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "==================================="
echo " Setup complete!"
echo "==================================="
echo ""
echo "Start the supervisor:"
echo "  python3 supervisor/db_supervisor.py -c supervisor/agents.json"
echo ""
echo "Or run it in the background:"
echo "  nohup python3 supervisor/db_supervisor.py -c supervisor/agents.json &"
echo ""
echo "Create a task to test:"
echo "  psql -d $DB_NAME -c \"SELECT tagg.set_agent_id(1);"
echo "    SELECT tagg.agent_task_add(1, 9, 'Hello from setup', 1);\""
echo ""
echo "Sync agent configs from DB to filesystem:"
echo "  bash sync_agents.sh"
echo ""
echo "Agent configs are at:"
echo "  agents/*.md          (used by opencode run --agent <name>)"
echo "  .opencode/agents/*.md"
echo ""
