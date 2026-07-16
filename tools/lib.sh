# Common library for tool scripts
# Source this in each tool:  source "$(dirname "$0")/lib.sh"

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

psql_json() {
    local agent_id="$1" # Compatibility argument; the run token determines identity.
    shift
    local sql="$1"
    shift
    : "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"
    local token_q="${AGENT_RUN_TOKEN//\'/\'\'}"
    psql --no-psqlrc -A -t \
         -c "SELECT tagg.set_agent_run_context('$token_q'); $sql" \
         2>&1
}

die() {
    echo "{\"success\": false, \"error\": \"$1\"}"
    exit 1
}

ok() {
    echo "{\"success\": true, \"data\": $1}"
    exit 0
}
