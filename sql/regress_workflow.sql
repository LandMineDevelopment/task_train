-- regress_workflow(p_task_id) — move task back one workflow step (fail back)
-- Returns the new task_status_id, or NULL if already at step 1.

SET search_path TO tagg, pg_catalog, pg_temp;

-- Ensure operation type exists
INSERT INTO tagg.operation_type (name, descr)
VALUES ('regress_workflow', 'Task was moved back one workflow step via regress_workflow().')
ON CONFLICT (name) DO NOTHING;

CREATE OR REPLACE FUNCTION tagg.regress_workflow(p_task_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_workflow_id     bigint;
    v_current_seq     integer;
    v_prev_seq        integer;
    v_prev_status_id  bigint;
    v_current_status  bigint;
BEGIN
    SELECT workflow_id, task_status_id
        INTO v_workflow_id, v_current_status
        FROM tagg.agent_task
        WHERE id = p_task_id AND is_active = true
        FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT seq_num INTO v_current_seq
        FROM tagg.workflow_step
        WHERE workflow_id = v_workflow_id
          AND task_status_id = v_current_status
          AND is_active = true;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Find the previous step (seq_num < current, ordered desc)
    SELECT ws.task_status_id, ws.seq_num
        INTO v_prev_status_id, v_prev_seq
        FROM tagg.workflow_step ws
        WHERE ws.workflow_id = v_workflow_id
          AND ws.seq_num < v_current_seq
          AND ws.is_active = true
        ORDER BY ws.seq_num DESC
        LIMIT 1;

    -- Already at the first step — nothing to do.
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    UPDATE tagg.agent_task
        SET task_status_id = v_prev_status_id
        WHERE id = p_task_id;

    BEGIN
        PERFORM tagg.log_operation('agent_task', p_task_id, 'regress_workflow');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    RETURN v_prev_status_id;
END;
$function$;

COMMENT ON FUNCTION tagg.regress_workflow IS
    'Moves a task back one step in its workflow. Returns the new task_status_id, or NULL if already at step 1.';

RESET search_path;
