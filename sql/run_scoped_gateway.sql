-- Token-validated worker mutations. Never trust caller-set session settings.
SET search_path TO tagg, pg_catalog, pg_temp;

ALTER TABLE tagg.agent_run ADD COLUMN IF NOT EXISTS heartbeat_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP;

CREATE OR REPLACE FUNCTION tagg.heartbeat_agent_run(p_token text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
BEGIN
    UPDATE tagg.agent_run SET heartbeat_at = CURRENT_TIMESTAMP
    WHERE token_hash = md5(p_token) AND status = 'running' AND expires_at > CURRENT_TIMESTAMP;
    RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.get_task_for_run(p_token text, p_task_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_task tagg.agent_task%ROWTYPE;
BEGIN
    PERFORM tagg.authorize_run(p_token, p_task_id, 'task:claim');
    SELECT * INTO v_task FROM tagg.agent_task WHERE id = p_task_id;
    RETURN to_jsonb(v_task);
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.get_conversation_for_run(p_token text, p_conversation_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_task_id bigint;
BEGIN
    SELECT task_id INTO v_task_id FROM tagg.agent_run WHERE token_hash = md5(p_token) AND status = 'running' AND expires_at > CURRENT_TIMESTAMP AND conversation_id = p_conversation_id;
    IF v_task_id IS NULL THEN RAISE EXCEPTION 'Conversation is not assigned to this run'; END IF;
    RETURN COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM tagg.message m WHERE m.conversation_id = p_conversation_id AND m.is_active), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.get_current_task_for_run(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_task_id bigint;
BEGIN
    SELECT task_id INTO v_task_id FROM tagg.agent_run
    WHERE token_hash = md5(p_token) AND status = 'running' AND expires_at > CURRENT_TIMESTAMP;
    IF v_task_id IS NULL THEN RAISE EXCEPTION 'Invalid agent run'; END IF;
    RETURN tagg.get_task_for_run(p_token, v_task_id);
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.append_message_for_run(p_token text, p_message text, p_status text DEFAULT 'complete')
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_run tagg.agent_run%ROWTYPE; v_owner bigint; v_message_id bigint; v_source_message_id bigint;
BEGIN
    SELECT * INTO v_run FROM tagg.agent_run WHERE token_hash = md5(p_token) AND status = 'running' AND expires_at > CURRENT_TIMESTAMP;
    IF NOT FOUND OR v_run.conversation_id IS NULL THEN RAISE EXCEPTION 'Run has no active conversation'; END IF;
    SELECT owner_user_id INTO v_owner FROM tagg.conversation WHERE id = v_run.conversation_id AND is_active;
    IF v_owner IS NULL THEN RAISE EXCEPTION 'Conversation is unavailable'; END IF;
    v_message_id := tagg.append_conversation_message(v_run.conversation_id, v_run.agent_user_id, v_owner, p_message, 'assistant', p_status);
    SELECT source_message_id INTO v_source_message_id FROM tagg.agent_task WHERE id = v_run.task_id;
    IF v_source_message_id IS NOT NULL THEN
        UPDATE tagg.message SET parent_id = v_source_message_id WHERE id = v_message_id;
    END IF;
    PERFORM tagg.set_run_audit_context(p_token);
    PERFORM tagg.log_operation('message', v_message_id, 'run_append');
    RETURN v_message_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.release_reserved_task(p_task_id bigint, p_reason text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
BEGIN
    UPDATE tagg.agent_task SET task_status_id = 1, last_error = p_reason, updated = CURRENT_TIMESTAMP
    WHERE id = p_task_id AND task_status_id = 2 AND is_active;
    IF FOUND THEN PERFORM tagg.log_operation('agent_task', p_task_id, 'release_reservation'); END IF;
    RETURN FOUND;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.recover_expired_runs(p_timeout_seconds integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_run record; v_count integer := 0;
BEGIN
    FOR v_run IN
        UPDATE tagg.agent_run SET status = 'abandoned', finished_at = CURRENT_TIMESTAMP,
            error_text = 'worker heartbeat expired'
        WHERE status = 'running' AND heartbeat_at < CURRENT_TIMESTAMP - make_interval(secs => p_timeout_seconds)
        RETURNING id, task_id
    LOOP
        UPDATE tagg.agent_task task SET attempt_count = attempt_count + 1,
            last_error = 'worker heartbeat expired', failed_at = CASE WHEN attempt_count + 1 >= max_attempts THEN CURRENT_TIMESTAMP ELSE NULL END,
            task_status_id = CASE WHEN attempt_count + 1 >= max_attempts THEN 7 ELSE 1 END,
            updated = CURRENT_TIMESTAMP
        WHERE task.id = v_run.task_id AND task.task_status_id IN (2, 3)
          AND NOT EXISTS (SELECT 1 FROM tagg.agent_run active WHERE active.task_id = task.id AND active.status = 'running');
        PERFORM tagg.log_operation('agent_run', v_run.id, 'abandon');
        PERFORM tagg.log_operation('agent_task', v_run.task_id, 'recover_expired_run');
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.finish_agent_run(p_run bigint, p_exit integer, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_run tagg.agent_run%ROWTYPE; v_error text;
BEGIN
    SELECT * INTO v_run FROM tagg.agent_run WHERE id = p_run FOR UPDATE;
    IF NOT FOUND OR v_run.status <> 'running' THEN RETURN; END IF;
    UPDATE tagg.agent_run SET finished_at = CURRENT_TIMESTAMP, exit_code = p_exit,
        error_text = p_error, status = CASE WHEN p_exit = 0 THEN 'completed' ELSE 'failed' END WHERE id = p_run;
    IF p_exit <> 0 OR EXISTS (SELECT 1 FROM tagg.agent_task WHERE id = v_run.task_id AND task_status_id IN (2, 3)) THEN
        v_error := COALESCE(NULLIF(p_error, ''), 'worker exited without completing its task');
        UPDATE tagg.agent_task SET attempt_count = attempt_count + 1, last_error = v_error,
            failed_at = CASE WHEN attempt_count + 1 >= max_attempts THEN CURRENT_TIMESTAMP ELSE NULL END,
            task_status_id = CASE WHEN attempt_count + 1 >= max_attempts THEN 7 ELSE 1 END,
            updated = CURRENT_TIMESTAMP
        WHERE id = v_run.task_id AND task_status_id IN (2, 3);
    END IF;
    PERFORM tagg.log_operation('agent_run', p_run, 'finish');
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.authorize_run(p_token text, p_task_id bigint, p_permission text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_agent_id bigint;
BEGIN
    SELECT run.agent_user_id INTO v_agent_id
    FROM tagg.agent_run run
    JOIN tagg.agent_task task ON task.id = run.task_id
    WHERE run.token_hash = md5(p_token) AND run.status = 'running' AND run.expires_at > CURRENT_TIMESTAMP
      AND run.task_id = p_task_id AND task.to_user_id = run.agent_user_id AND task.is_active;
    IF v_agent_id IS NULL THEN RAISE EXCEPTION 'Invalid or unauthorized agent run'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM tagg.skill_user_crosswalk su
        JOIN tagg.skill_permission_crosswalk sp ON sp.skill_id = su.skill_id AND sp.is_active
        JOIN tagg.permission permission ON permission.id = sp.permission_id AND permission.is_active
        WHERE su.user_id = v_agent_id AND su.is_active AND permission.name = p_permission
    ) THEN RAISE EXCEPTION 'Permission denied: %', p_permission; END IF;
    RETURN v_agent_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.set_run_audit_context(p_token text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_run tagg.agent_run%ROWTYPE;
BEGIN
    SELECT * INTO v_run FROM tagg.agent_run WHERE token_hash = md5(p_token) AND status = 'running' AND expires_at > CURRENT_TIMESTAMP;
    IF NOT FOUND THEN RAISE EXCEPTION 'Invalid agent run'; END IF;
    PERFORM set_config('tagg.agent_id', v_run.agent_user_id::text, true);
    PERFORM set_config('tagg.agent_run_id', v_run.id::text, true);
    UPDATE tagg.agent_run SET heartbeat_at = CURRENT_TIMESTAMP WHERE id = v_run.id;
    RETURN v_run.agent_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.claim_task_for_run(p_token text, p_task_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_agent bigint; v_row tagg.agent_task%ROWTYPE;
BEGIN
    v_agent := tagg.authorize_run(p_token, p_task_id, 'task:claim');
    PERFORM tagg.set_run_audit_context(p_token);
    UPDATE tagg.agent_task SET task_status_id = 3, updated = CURRENT_TIMESTAMP
    WHERE id = p_task_id AND to_user_id = v_agent AND task_status_id IN (1, 2) AND is_active
    RETURNING * INTO v_row;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'task is unavailable'); END IF;
    PERFORM tagg.log_operation('agent_task', p_task_id, 'claim');
    RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_row));
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.artifact_add_for_run(p_token text, p_task_id bigint, p_name varchar, p_descr varchar, p_type varchar, p_body text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_id bigint;
BEGIN
    PERFORM tagg.authorize_run(p_token, p_task_id, 'artifact:create');
    PERFORM tagg.set_run_audit_context(p_token);
    INSERT INTO tagg.artifact(agent_task_id, name, descr, artifact_type, body) VALUES (p_task_id, p_name, p_descr, p_type, p_body) RETURNING id INTO v_id;
    PERFORM tagg.log_operation('artifact', v_id, 'add');
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.advance_task_for_run(p_token text, p_task_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_workflow bigint; v_current bigint; v_next bigint;
BEGIN
    PERFORM tagg.authorize_run(p_token, p_task_id, 'task:advance');
    PERFORM tagg.set_run_audit_context(p_token);
    SELECT workflow_id, task_status_id INTO v_workflow, v_current FROM tagg.agent_task WHERE id = p_task_id FOR UPDATE;
    SELECT ws.task_status_id INTO v_next FROM tagg.workflow_step ws JOIN tagg.workflow_step cur ON cur.workflow_id = ws.workflow_id AND cur.task_status_id = v_current WHERE ws.workflow_id = v_workflow AND ws.seq_num > cur.seq_num AND ws.is_active AND cur.is_active ORDER BY ws.seq_num LIMIT 1;
    IF v_next IS NULL THEN RETURN NULL; END IF;
    UPDATE tagg.agent_task SET task_status_id = v_next, updated = CURRENT_TIMESTAMP WHERE id = p_task_id;
    PERFORM tagg.log_operation('agent_task', p_task_id, 'advance_workflow');
    RETURN v_next;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.fail_task_for_run(p_token text, p_task_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
BEGIN
    PERFORM tagg.authorize_run(p_token, p_task_id, 'task:fail');
    PERFORM tagg.set_run_audit_context(p_token);
    UPDATE tagg.agent_task SET task_status_id = 7, updated = CURRENT_TIMESTAMP WHERE id = p_task_id AND task_status_id IN (2, 3);
    IF NOT FOUND THEN RAISE EXCEPTION 'Task cannot be failed'; END IF;
    PERFORM tagg.log_operation('agent_task', p_task_id, 'fail');
    RETURN 7;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.create_task_for_run(p_token text, p_task_id bigint, p_to_user_id bigint, p_task text, p_workflow_name text DEFAULT 'standard')
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_agent bigint; v_project_id bigint; v_conversation_id bigint; v_id bigint;
BEGIN
    v_agent := tagg.authorize_run(p_token, p_task_id, 'task:create');
    IF v_agent = p_to_user_id THEN PERFORM tagg.authorize_run(p_token, p_task_id, 'task:assign:self'); ELSE PERFORM tagg.authorize_run(p_token, p_task_id, 'task:assign:any'); END IF;
    PERFORM tagg.set_run_audit_context(p_token);
    SELECT project_id, conversation_id INTO v_project_id, v_conversation_id FROM tagg.agent_task WHERE id = p_task_id;
    INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, parent_id, workflow_id, conversation_id)
    VALUES (v_agent, p_to_user_id, p_task, v_project_id, p_task_id, (SELECT id FROM tagg.workflow WHERE name = p_workflow_name), v_conversation_id)
    RETURNING id INTO v_id;
    PERFORM tagg.log_operation('agent_task', v_id, 'add');
    RETURN v_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION tagg.authorize_run(text,bigint,text), tagg.set_agent_run_context(text), tagg.claim_task(bigint), tagg.artifact_add(bigint,varchar,varchar,varchar,text), tagg.agent_task_add(bigint,bigint,text,bigint,bigint,bigint), tagg.advance_workflow(bigint), tagg.fail_task(bigint), tagg.append_conversation_message(bigint,bigint,bigint,text,text,text,jsonb), tagg.get_pending_tasks(integer), tagg.claim_task_for_run(text,bigint), tagg.artifact_add_for_run(text,bigint,varchar,varchar,varchar,text), tagg.advance_task_for_run(text,bigint), tagg.fail_task_for_run(text,bigint), tagg.create_task_for_run(text,bigint,bigint,text,text), tagg.get_task_for_run(text,bigint), tagg.get_conversation_for_run(text,bigint), tagg.get_current_task_for_run(text), tagg.append_message_for_run(text,text,text) FROM PUBLIC;
RESET search_path;
