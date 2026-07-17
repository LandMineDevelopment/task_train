-- Propagate user conversation context to delegated work and report lifecycle updates.
SET search_path TO tagg, pg_catalog, pg_temp;
SELECT pg_advisory_lock(742018);

CREATE OR REPLACE FUNCTION tagg.agent_task_add(
    p_from_user_id bigint,
    p_to_user_id bigint,
    p_task text,
    p_project_id bigint,
    p_parent_id bigint DEFAULT NULL,
    p_workflow_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_id bigint;
    v_agent bigint;
    v_conversation_id bigint;
BEGIN
    v_agent := current_setting('tagg.agent_id')::bigint;
    IF p_from_user_id <> v_agent THEN
        RAISE EXCEPTION 'Agents may only create tasks as themselves';
    END IF;
    PERFORM tagg.require_permission('task:create');
    IF p_from_user_id = p_to_user_id THEN
        PERFORM tagg.require_permission('task:assign:self');
    ELSE
        PERFORM tagg.require_permission('task:assign:any');
    END IF;

    SELECT conversation_id INTO v_conversation_id
    FROM tagg.agent_run
    WHERE id = NULLIF(current_setting('tagg.agent_run_id', true), '')::bigint
      AND status = 'running';

    INSERT INTO tagg.agent_task (
        from_user_id, to_user_id, task, project_id, parent_id, workflow_id, conversation_id
    ) VALUES (
        p_from_user_id, p_to_user_id, p_task, p_project_id, p_parent_id,
        COALESCE(p_workflow_id, (SELECT id FROM tagg.workflow WHERE name = 'standard')),
        v_conversation_id
    ) RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.report_user_conversation_task_progress()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_conductor_id bigint;
    v_owner_id bigint;
    v_agent_name text;
    v_message text;
    v_artifact_body text;
BEGIN
    IF NEW.conversation_id IS NULL
       OR NEW.task_status_id IS NOT DISTINCT FROM OLD.task_status_id THEN
        RETURN NEW;
    END IF;

    SELECT conductor_user_id, owner_user_id INTO v_conductor_id, v_owner_id
    FROM tagg.conversation
    WHERE id = NEW.conversation_id AND kind = 'user_conductor' AND is_active;
    IF v_conductor_id IS NULL OR v_owner_id IS NULL OR NEW.from_user_id <> v_conductor_id THEN
        RETURN NEW;
    END IF;

    SELECT name INTO v_agent_name FROM tagg.user WHERE id = NEW.to_user_id;
    v_message := CASE NEW.task_status_id
        WHEN 3 THEN format('%s started task #%s: %s', v_agent_name, NEW.id, NEW.task)
        WHEN 4 THEN format('%s completed task #%s: %s', v_agent_name, NEW.id, NEW.task)
        WHEN 7 THEN format('%s failed task #%s: %s', v_agent_name, NEW.id, NEW.task)
        WHEN 8 THEN format('%s cancelled task #%s: %s', v_agent_name, NEW.id, NEW.task)
        ELSE NULL
    END;
    IF NEW.task_status_id = 4 THEN
        SELECT left(body, 12000) INTO v_artifact_body
        FROM tagg.artifact
        WHERE agent_task_id = NEW.id
          AND NULLIF(btrim(body), '') IS NOT NULL
        ORDER BY id DESC
        LIMIT 1;
        IF v_artifact_body IS NOT NULL THEN
            v_message := v_message || E'\n\nArtifact:\n' || v_artifact_body;
        END IF;
    END IF;
    IF v_message IS NOT NULL THEN
        PERFORM tagg.append_conversation_message(
            NEW.conversation_id, v_conductor_id, v_owner_id, v_message, 'assistant'
        );
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS user_conversation_task_progress ON tagg.agent_task;
CREATE TRIGGER user_conversation_task_progress
AFTER UPDATE OF task_status_id ON tagg.agent_task
FOR EACH ROW EXECUTE FUNCTION tagg.report_user_conversation_task_progress();

SELECT pg_advisory_unlock(742018);
RESET search_path;
