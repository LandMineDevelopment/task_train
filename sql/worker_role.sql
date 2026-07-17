-- Restricted login used only by OpenCode worker subprocesses.
SELECT format('CREATE ROLE task_train_worker LOGIN PASSWORD %L', :'worker_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'task_train_worker') \gexec
ALTER ROLE task_train_worker LOGIN PASSWORD :'worker_password';
GRANT USAGE ON SCHEMA tagg TO task_train_worker;
GRANT SELECT ON tagg.user, tagg.project, tagg.conversation, tagg.message, tagg.agent_task TO task_train_worker;
REVOKE ALL ON ALL TABLES IN SCHEMA tagg FROM task_train_worker;
GRANT SELECT ON tagg.user, tagg.project, tagg.conversation, tagg.message, tagg.agent_task TO task_train_worker;
REVOKE EXECUTE ON FUNCTION tagg.set_agent_run_context(text), tagg.claim_task(bigint),
    tagg.artifact_add(bigint, varchar, varchar, varchar, text),
    tagg.agent_task_add(bigint, bigint, text, bigint, bigint, bigint),
    tagg.advance_workflow(bigint), tagg.fail_task(bigint),
    tagg.append_conversation_message(bigint, bigint, bigint, text, text, text, jsonb)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tagg.set_agent_run_context(text), tagg.claim_task(bigint),
    tagg.artifact_add(bigint, varchar, varchar, varchar, text),
    tagg.agent_task_add(bigint, bigint, text, bigint, bigint, bigint),
    tagg.advance_workflow(bigint), tagg.fail_task(bigint),
    tagg.append_conversation_message(bigint, bigint, bigint, text, text, text, jsonb),
    tagg.get_pending_tasks(integer)
TO task_train_worker;
