-- Audit records and database gateways for browser and supervisor mutations.
SET search_path TO tagg, pg_catalog, pg_temp;

ALTER TABLE tagg.operation_log ADD COLUMN IF NOT EXISTS actor_user_id bigint REFERENCES tagg.user(id);
ALTER TABLE tagg.operation_log ADD COLUMN IF NOT EXISTS agent_run_id bigint REFERENCES tagg.agent_run(id);
ALTER TABLE tagg.operation_log ADD COLUMN IF NOT EXISTS details jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE tagg.operation_log DROP CONSTRAINT IF EXISTS operation_log_actor_user_id_fkey;
ALTER TABLE tagg.operation_log ADD CONSTRAINT operation_log_actor_user_id_fkey
    FOREIGN KEY (actor_user_id) REFERENCES tagg.user(id) ON DELETE SET NULL;
ALTER TABLE tagg.operation_log DROP CONSTRAINT IF EXISTS operation_log_agent_run_id_fkey;
ALTER TABLE tagg.operation_log ADD CONSTRAINT operation_log_agent_run_id_fkey
    FOREIGN KEY (agent_run_id) REFERENCES tagg.agent_run(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION tagg.log_operation(p_object_type text, p_object_id bigint, p_operation text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE
    v_operation_type_id bigint;
    v_actor_user_id bigint;
    v_agent_run_id bigint;
BEGIN
    v_actor_user_id := NULLIF(current_setting('tagg.agent_id', true), '')::bigint;
    v_agent_run_id := NULLIF(current_setting('tagg.agent_run_id', true), '')::bigint;
    INSERT INTO tagg.operation_type(name, descr) VALUES (p_operation, p_operation)
    ON CONFLICT (name) DO UPDATE SET descr = EXCLUDED.descr
    RETURNING id INTO v_operation_type_id;
    INSERT INTO tagg.operation_log(operation_type_id, object_type, object_id, actor_user_id, agent_run_id, details)
    VALUES (v_operation_type_id, p_object_type, p_object_id, v_actor_user_id, v_agent_run_id,
            jsonb_strip_nulls(jsonb_build_object('operation', p_operation)));
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.log_error(p_operation text, p_message text, p_code text, p_details jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
BEGIN
    INSERT INTO tagg.error_log(operation, error_message, error_code, details)
    VALUES (
        p_operation, p_message, p_code,
        COALESCE(p_details, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
            'agent_id', NULLIF(current_setting('tagg.agent_id', true), ''),
            'agent_run_id', NULLIF(current_setting('tagg.agent_run_id', true), '')
        ))
    );
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.artifact_add(
    p_agent_task_id bigint, p_name varchar(50), p_descr varchar(400), p_artifact_type varchar(50), p_body text
)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_id bigint; v_agent bigint;
BEGIN
    PERFORM tagg.require_permission('artifact:create');
    v_agent := current_setting('tagg.agent_id')::bigint;
    IF NOT EXISTS (SELECT 1 FROM tagg.agent_task WHERE id = p_agent_task_id AND to_user_id = v_agent AND is_active) THEN
        RAISE EXCEPTION 'Task % is not assigned to this agent', p_agent_task_id;
    END IF;
    INSERT INTO tagg.artifact(agent_task_id, name, descr, artifact_type, body)
    VALUES (p_agent_task_id, p_name, p_descr, p_artifact_type, p_body)
    RETURNING id INTO v_id;
    PERFORM tagg.log_operation('artifact', v_id, 'add');
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.agent_task_add(
    p_from_user_id bigint, p_to_user_id bigint, p_task text, p_project_id bigint,
    p_parent_id bigint DEFAULT NULL, p_workflow_id bigint DEFAULT NULL
)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_id bigint; v_agent bigint; v_conversation_id bigint;
BEGIN
    v_agent := current_setting('tagg.agent_id')::bigint;
    IF p_from_user_id <> v_agent THEN RAISE EXCEPTION 'Agents may only create tasks as themselves'; END IF;
    PERFORM tagg.require_permission('task:create');
    IF p_from_user_id = p_to_user_id THEN PERFORM tagg.require_permission('task:assign:self'); ELSE PERFORM tagg.require_permission('task:assign:any'); END IF;
    SELECT conversation_id INTO v_conversation_id FROM tagg.agent_run
    WHERE id = NULLIF(current_setting('tagg.agent_run_id', true), '')::bigint AND status = 'running';
    INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, parent_id, workflow_id, conversation_id)
    VALUES (p_from_user_id, p_to_user_id, p_task, p_project_id, p_parent_id,
            COALESCE(p_workflow_id, (SELECT id FROM tagg.workflow WHERE name = 'standard')), v_conversation_id)
    RETURNING id INTO v_id;
    PERFORM tagg.log_operation('agent_task', v_id, 'add');
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.advance_workflow(p_task_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_agent bigint; v_workflow bigint; v_current bigint; v_next bigint;
BEGIN
    PERFORM tagg.require_permission('task:advance'); v_agent := current_setting('tagg.agent_id')::bigint;
    SELECT workflow_id, task_status_id INTO v_workflow, v_current FROM tagg.agent_task WHERE id = p_task_id AND to_user_id = v_agent AND is_active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Task % is not assigned to this agent', p_task_id; END IF;
    SELECT ws.task_status_id INTO v_next FROM tagg.workflow_step ws JOIN tagg.workflow_step cur ON cur.workflow_id = ws.workflow_id AND cur.task_status_id = v_current WHERE ws.workflow_id = v_workflow AND ws.seq_num > cur.seq_num AND ws.is_active AND cur.is_active ORDER BY ws.seq_num LIMIT 1;
    IF v_next IS NULL THEN RETURN NULL; END IF;
    UPDATE tagg.agent_task SET task_status_id = v_next WHERE id = p_task_id;
    PERFORM tagg.log_operation('agent_task', p_task_id, 'advance_workflow');
    RETURN v_next;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.create_browser_conversation(
    p_project_id bigint, p_user_id bigint, p_conductor_id bigint, p_title text
)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_id bigint;
BEGIN
    INSERT INTO tagg.conversation(title, original_theme, project_id, kind, owner_user_id, conductor_user_id)
    VALUES (p_title, 'user_conductor', p_project_id, 'user_conductor', p_user_id, p_conductor_id)
    RETURNING id INTO v_id;
    PERFORM tagg.log_operation('conversation', v_id, 'browser_create');
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.rename_browser_conversation(
    p_conversation_id bigint, p_user_id bigint, p_conductor_id bigint, p_title text
)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_title text;
BEGIN
    UPDATE tagg.conversation SET title = p_title, updated = CURRENT_TIMESTAMP
    WHERE id = p_conversation_id AND is_active AND kind = 'user_conductor'
      AND owner_user_id = p_user_id AND conductor_user_id = p_conductor_id
    RETURNING title INTO v_title;
    IF v_title IS NULL THEN RAISE EXCEPTION 'Conversation not found'; END IF;
    PERFORM tagg.log_operation('conversation', p_conversation_id, 'browser_rename');
    RETURN v_title;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.queue_browser_message(
    p_conversation_id bigint, p_project_id bigint, p_user_id bigint, p_conductor_id bigint, p_message text
)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_message_id bigint; v_task_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tagg.conversation WHERE id = p_conversation_id AND is_active
                   AND kind = 'user_conductor' AND owner_user_id = p_user_id AND conductor_user_id = p_conductor_id) THEN
        RAISE EXCEPTION 'Conversation not found';
    END IF;
    v_message_id := tagg.append_conversation_message(p_conversation_id, p_user_id, p_conductor_id, p_message, 'user');
    INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, workflow_id, conversation_id)
    VALUES (p_user_id, p_conductor_id, 'Respond to the latest user message through the Conductor workflow.', p_project_id,
            (SELECT id FROM tagg.workflow WHERE name = 'quick'), p_conversation_id)
    RETURNING id INTO v_task_id;
    INSERT INTO tagg.message_agent_task_crosswalk(message_id, agent_task_id) VALUES (v_message_id, v_task_id);
    PERFORM tagg.log_operation('message', v_message_id, 'browser_send');
    PERFORM tagg.log_operation('agent_task', v_task_id, 'browser_queue');
    RETURN v_task_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.recover_stalled_tasks(p_timeout_seconds integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg', 'pg_catalog', 'pg_temp' AS $function$
DECLARE v_task_id bigint; v_count integer := 0;
BEGIN
    FOR v_task_id IN
        UPDATE tagg.agent_task SET task_status_id = 1
        WHERE task_status_id IN (2, 3) AND is_active
          AND updated < CURRENT_TIMESTAMP - make_interval(secs => p_timeout_seconds)
        RETURNING id
    LOOP
        PERFORM tagg.log_operation('agent_task', v_task_id, 'recover_stalled');
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$function$;

RESET search_path;
