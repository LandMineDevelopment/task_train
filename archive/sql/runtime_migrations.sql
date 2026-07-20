\set ON_ERROR_STOP on
SELECT pg_advisory_lock(742019);
\i /workspace/sql/browser_chat_workflow.sql
\i /workspace/sql/conductor_workflow.sql
\i /workspace/sql/conversation_progress.sql
\i /workspace/sql/artifact_only_workers.sql
\i /workspace/sql/audit_gateway.sql
\i /workspace/sql/run_scoped_gateway.sql
\i /workspace/sql/worker_role.sql
SELECT pg_advisory_unlock(742019);
