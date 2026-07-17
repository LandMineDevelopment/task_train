-- Restricted login used only by OpenCode worker subprocesses.
SELECT format('CREATE ROLE task_train_worker LOGIN PASSWORD %L', :'worker_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'task_train_worker') \gexec
ALTER ROLE task_train_worker LOGIN PASSWORD :'worker_password';
GRANT USAGE ON SCHEMA tagg TO task_train_worker;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA tagg FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA tagg FROM task_train_worker;
REVOKE EXECUTE ON FUNCTION tagg.set_agent_run_context(text), tagg.claim_task(bigint),
    tagg.artifact_add(bigint, varchar, varchar, varchar, text), tagg.advance_workflow(bigint), tagg.fail_task(bigint),
    tagg.append_conversation_message(bigint, bigint, bigint, text, text, text, jsonb)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tagg.claim_task_for_run(text, bigint),
    tagg.artifact_add_for_run(text, bigint, varchar, varchar, varchar, text),
    tagg.advance_task_for_run(text, bigint), tagg.fail_task_for_run(text, bigint), tagg.create_task_for_run(text, bigint, bigint, text, text),
    tagg.get_current_task_for_run(text)
TO task_train_worker;
GRANT EXECUTE ON FUNCTION tagg.heartbeat_agent_run(text) TO task_train_worker;
GRANT EXECUTE ON FUNCTION tagg.get_task_for_run(text, bigint), tagg.get_conversation_for_run(text, bigint), tagg.append_message_for_run(text, text, text) TO task_train_worker;
