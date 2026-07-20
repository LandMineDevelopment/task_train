-- ============================================================================
-- Workflow System
-- ============================================================================
-- Extends task_status with ordered, pluggable workflows so that the task
-- lifecycle is defined by data (workflow_step.seq_num) rather than hardcoded
-- status IDs.  Each agent_task belongs to one workflow, and
-- tagg.advance_workflow() moves it to the next step automatically.
-- ============================================================================

SET search_path TO tagg, pg_catalog, pg_temp;

-- ------------------------------------------------------------------------
-- 1. workflow table
-- ------------------------------------------------------------------------
CREATE TABLE tagg.workflow (
    id          bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        varchar(50)  NOT NULL,
    descr       varchar(400) NOT NULL,
    created     timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated     timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active   boolean      NOT NULL DEFAULT true
);

COMMENT ON TABLE  tagg.workflow IS
    'Lookup table for workflow types. Each row defines a named task lifecycle (e.g. standard, quick). Referenced by agent_task.workflow_id and workflow_step.workflow_id.';
COMMENT ON COLUMN tagg.workflow.id IS
    'Primary key, auto-generated workflow identifier.';
COMMENT ON COLUMN tagg.workflow.name IS
    'Unique name for the workflow (e.g. standard, quick).';
COMMENT ON COLUMN tagg.workflow.descr IS
    'Description of when this workflow should be used.';
COMMENT ON COLUMN tagg.workflow.created IS
    'Timestamp when this workflow was created.';
COMMENT ON COLUMN tagg.workflow.updated IS
    'Timestamp when this workflow was last updated.';
COMMENT ON COLUMN tagg.workflow.is_active IS
    'Soft-delete flag; inactive workflows are excluded from queries by default.';

CREATE UNIQUE INDEX workflow_unique_name_idx
    ON tagg.workflow (name);

CREATE INDEX workflow_active_idx
    ON tagg.workflow (id)
    WHERE is_active = true;

CREATE TRIGGER set_timestamp
    BEFORE INSERT OR UPDATE
    ON tagg.workflow
    FOR EACH ROW
    EXECUTE FUNCTION tagg.trigger_update_timestamp();

COMMENT ON TRIGGER set_timestamp ON tagg.workflow IS
    'Automatically sets updated=NOW() on INSERT or UPDATE.';

-- ------------------------------------------------------------------------
-- 2. workflow_step table (ordered M:N between workflow and task_status)
-- ------------------------------------------------------------------------
CREATE TABLE tagg.workflow_step (
    id              bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workflow_id     bigint  NOT NULL,
    task_status_id  bigint  NOT NULL,
    seq_num         integer NOT NULL,
    created         timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active       boolean     NOT NULL DEFAULT true
);

COMMENT ON TABLE  tagg.workflow_step IS
    'Ordered steps within a workflow. Maps a workflow to its sequence of task_statuses via seq_num. Enforces unique ordering per workflow and prevents duplicate statuses.';
COMMENT ON COLUMN tagg.workflow_step.id IS
    'Primary key, auto-generated step identifier.';
COMMENT ON COLUMN tagg.workflow_step.workflow_id IS
    'FK to workflow. The workflow this step belongs to.';
COMMENT ON COLUMN tagg.workflow_step.task_status_id IS
    'FK to task_status. The task status that represents this step.';
COMMENT ON COLUMN tagg.workflow_step.seq_num IS
    'Order of this step within the workflow (1-based). Lower numbers execute first.';
COMMENT ON COLUMN tagg.workflow_step.created IS
    'Timestamp when this step was created.';
COMMENT ON COLUMN tagg.workflow_step.is_active IS
    'Soft-delete flag; inactive steps are excluded from workflow traversal.';

ALTER TABLE tagg.workflow_step
    ADD CONSTRAINT workflow_step_workflow_fk
    FOREIGN KEY (workflow_id)
    REFERENCES tagg.workflow (id);

ALTER TABLE tagg.workflow_step
    ADD CONSTRAINT workflow_step_task_status_fk
    FOREIGN KEY (task_status_id)
    REFERENCES tagg.task_status (id);

ALTER TABLE tagg.workflow_step
    ADD CONSTRAINT workflow_step_unique_seq
    UNIQUE (workflow_id, seq_num);

ALTER TABLE tagg.workflow_step
    ADD CONSTRAINT workflow_step_unique_status
    UNIQUE (workflow_id, task_status_id);

CREATE INDEX workflow_step_workflow_id_idx
    ON tagg.workflow_step (workflow_id);

CREATE INDEX workflow_step_task_status_id_idx
    ON tagg.workflow_step (task_status_id);

CREATE INDEX workflow_step_active_idx
    ON tagg.workflow_step (id)
    WHERE is_active = true;

-- ------------------------------------------------------------------------
-- 3. Seed default workflows
-- ------------------------------------------------------------------------
INSERT INTO tagg.workflow (name, descr) VALUES
    ('standard', 'Full task lifecycle: pending → reserved → in_progress → completed → tested → validated.'),
    ('quick',    'Simplified lifecycle: pending → reserved → in_progress → completed.');

WITH w AS (SELECT id FROM tagg.workflow WHERE name = 'standard')
INSERT INTO tagg.workflow_step (workflow_id, task_status_id, seq_num)
SELECT w.id, s.id, s.seq
FROM w,
  (VALUES
    (1, 1),   -- pending
    (2, 2),   -- reserved
    (3, 3),   -- in_progress
    (4, 4),   -- completed
    (5, 5),   -- tested
    (6, 6)    -- validated
  ) AS s(seq, id);

WITH w AS (SELECT id FROM tagg.workflow WHERE name = 'quick')
INSERT INTO tagg.workflow_step (workflow_id, task_status_id, seq_num)
SELECT w.id, s.id, s.seq
FROM w,
  (VALUES
    (1, 1),   -- pending
    (2, 2),   -- reserved
    (3, 3),   -- in_progress
    (4, 4)    -- completed
  ) AS s(seq, id);

-- ------------------------------------------------------------------------
-- 4. Add workflow_id to agent_task
-- ------------------------------------------------------------------------
ALTER TABLE tagg.agent_task
    ADD COLUMN workflow_id bigint;

COMMENT ON COLUMN tagg.agent_task.workflow_id IS
    'FK to workflow. Which workflow lifecycle this task follows. Determines the valid status progression and next steps when advance_workflow() is called.';

ALTER TABLE tagg.agent_task
    ADD CONSTRAINT agent_task_workflow_fk
    FOREIGN KEY (workflow_id)
    REFERENCES tagg.workflow (id);

CREATE INDEX agent_task_workflow_id_idx
    ON tagg.agent_task (workflow_id);

-- Migrate existing tasks to the 'standard' workflow (the default).
UPDATE tagg.agent_task
    SET workflow_id = (SELECT id FROM tagg.workflow WHERE name = 'standard')
    WHERE workflow_id IS NULL;

-- Now make it NOT NULL.
ALTER TABLE tagg.agent_task
    ALTER COLUMN workflow_id SET NOT NULL;

-- ------------------------------------------------------------------------
-- 5. advance_workflow function
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tagg.advance_workflow(p_task_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_workflow_id     bigint;
    v_current_seq     integer;
    v_next_seq        integer;
    v_next_status_id  bigint;
    v_current_status  bigint;
BEGIN
    -- Grab the task's current workflow and status.
    SELECT workflow_id, task_status_id
        INTO v_workflow_id, v_current_status
        FROM tagg.agent_task
        WHERE id = p_task_id AND is_active = true
        FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Find the current step's seq_num.
    SELECT seq_num INTO v_current_seq
        FROM tagg.workflow_step
        WHERE workflow_id = v_workflow_id
          AND task_status_id = v_current_status
          AND is_active = true;

    -- Don't advance if this status isn't in the workflow.
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Find the next step.
    SELECT ws.task_status_id, ws.seq_num
        INTO v_next_status_id, v_next_seq
        FROM tagg.workflow_step ws
        WHERE ws.workflow_id = v_workflow_id
          AND ws.seq_num > v_current_seq
          AND ws.is_active = true
        ORDER BY ws.seq_num
        LIMIT 1;

    -- Already at the last step — nothing to do.
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Advance.
    UPDATE tagg.agent_task
        SET task_status_id = v_next_status_id
        WHERE id = p_task_id;

    PERFORM tagg.log_operation('agent_task', p_task_id, 'advance_workflow');

    RETURN v_next_status_id;
END;
$function$;

COMMENT ON FUNCTION tagg.advance_workflow IS
    'Moves a task to the next status in its workflow. Looks up the task''s workflow_id, finds the current task_status_id in workflow_step, then updates to the next seq_num''s status. Returns the new task_status_id, or NULL if already at the terminal step.';

-- ------------------------------------------------------------------------
-- 6. Update agent_task_add to accept workflow_id
-- ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tagg.agent_task_add(
    p_from_user_id  bigint,
    p_to_user_id    bigint,
    p_task          text,
    p_project_id    bigint,
    p_parent_id     bigint DEFAULT NULL,
    p_workflow_id   bigint DEFAULT NULL
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
    v_workflow_id bigint;
BEGIN
    v_workflow_id := COALESCE(p_workflow_id,
        (SELECT id FROM tagg.workflow WHERE name = 'standard'));

    INSERT INTO tagg.agent_task (from_user_id, to_user_id, task, project_id, parent_id, workflow_id)
    VALUES (p_from_user_id, p_to_user_id, p_task, p_project_id, p_parent_id, v_workflow_id)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('agent_task', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('agent_task_add', SQLERRM, SQLSTATE,
        jsonb_build_object('from_user_id', p_from_user_id, 'to_user_id', p_to_user_id,
                           'project_id', p_project_id, 'parent_id', p_parent_id,
                           'workflow_id', v_workflow_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.agent_task_add IS
    'Creates a new agent task with the given from/to agents, task text, project, optional parent, and optional workflow. Defaults to the "standard" workflow if no workflow_id is provided.';

-- ------------------------------------------------------------------------
-- 7. Everything is wired
-- ------------------------------------------------------------------------
-- task_ready_notification wakes the external Python supervisor when a task
-- becomes pending. The supervisor reserves the task before starting a
-- tokenized worker. advance_workflow() handles only normal linear progression;
-- failed and cancelled are terminal exception states.

RESET search_path;
