#!/usr/bin/env bash
set -euo pipefail

psql -h localhost -U kasey -d task_train --no-psqlrc -A -t \
  -c "SELECT c.id || ': ' || c.title || ' (' || COALESCE(m.cnt::text, '0') || ' msgs)'
      FROM tagg.conversation c
      LEFT JOIN LATERAL (
        SELECT count(*) as cnt FROM tagg.message
        WHERE conversation_id = c.id AND is_active = true
      ) m ON true
      WHERE c.is_active = true
      ORDER BY c.updated DESC
      LIMIT 20;" 2>/dev/null