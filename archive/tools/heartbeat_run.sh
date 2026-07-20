#!/usr/bin/env bash
set -euo pipefail

: "${AGENT_RUN_TOKEN:?AGENT_RUN_TOKEN required}"
psql --no-psqlrc -qAt -v ON_ERROR_STOP=1 -c "SELECT tagg.heartbeat_agent_run('$AGENT_RUN_TOKEN')" >/dev/null
