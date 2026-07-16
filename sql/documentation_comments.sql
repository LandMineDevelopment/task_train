-- Correct catalog comments after the supported external-supervisor migrations.
SET search_path TO tagg, pg_catalog, pg_temp;

COMMENT ON COLUMN tagg.user.prompt IS 'Database source of truth for an agent prompt. sync_agents.sh renders it into the OpenCode Markdown agent file.';
COMMENT ON COLUMN tagg.user.command IS 'Legacy per-agent command metadata. The supported external supervisor uses commands from supervisor/agents.json.';
COMMENT ON COLUMN tagg.user.max_concurrent IS 'Per-agent concurrency metadata. The supported external supervisor enforces configured concurrency limits.';
COMMENT ON FUNCTION tagg.set_agent_id(bigint) IS 'Legacy session identity helper. Tokenized workers use set_agent_run_context(token) instead.';
COMMENT ON TABLE tagg.error_log IS 'Error audit table for function failures and permission denials.';
COMMENT ON FUNCTION tagg.check_permission(text) IS 'Returns whether the current run-context agent has a named permission through active skills.';
COMMENT ON FUNCTION tagg.require_permission(text) IS 'Checks the current run-context agent permission, logs denial, and raises. Used by permission-gated mutating functions.';
COMMENT ON FUNCTION tagg.claim_task(bigint) IS 'Claims a pending or reserved task (status 1 or 2 -> 3) for the current run-context agent. Requires task:claim and matching assignee.';
COMMENT ON FUNCTION tagg.reserve_task(bigint) IS 'Atomically reserves a pending task (status 1 -> reserved status 2) before the external supervisor starts a worker.';
COMMENT ON FUNCTION tagg.fail_task(bigint) IS 'Marks the current run-context agent''s assigned reserved or in-progress task as failed (status 7). Requires task:fail.';
COMMENT ON FUNCTION tagg.cancel_task(bigint) IS 'Cancels an active pending, reserved, or in-progress task (status 8). Requires task:cancel.';
COMMENT ON FUNCTION tagg.get_pending_tasks(integer) IS 'Returns pending tasks assigned to the current run-context agent. Read-only.';

RESET search_path;
