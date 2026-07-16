-- ============================================================================
-- Permissions System
-- ============================================================================
-- Associates permissions with skills (M:N via crosswalk).  Agents inherit
-- permissions from their assigned skills.  Every SECURITY DEFINER function
-- calls tagg.require_permission() at the top, which reads the caller's
-- identity from a session-level custom variable (set by tagg.set_agent_id()).
--
-- If the caller lacks the required permission, the call is logged to
-- tagg.error_log (via log_error / dblink) and an exception is raised.
-- ============================================================================

SET search_path TO tagg, pg_catalog, pg_temp;

-- ========================================================================
-- 1. permission table
-- ========================================================================
CREATE TABLE tagg.permission (
    id          bigint  GENERATED ALWAYS AS IDENTITY,
    name        varchar(50)  NOT NULL,
    descr       varchar(400) NOT NULL,
    created     timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated     timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active   boolean      NOT NULL DEFAULT true
);

COMMENT ON TABLE  tagg.permission IS
    'Lookup table for discrete permissions.  Namespaced as category:action (e.g. task:create, fs:write).  Linked to skills via skill_permission_crosswalk.';
COMMENT ON COLUMN tagg.permission.id IS
    'Primary key, auto-generated permission identifier.';
COMMENT ON COLUMN tagg.permission.name IS
    'Unique permission name (e.g. task:create, fs:write, admin:agent).';
COMMENT ON COLUMN tagg.permission.descr IS
    'Description of what this permission grants access to.';
COMMENT ON COLUMN tagg.permission.created IS
    'Timestamp when this permission was created.';
COMMENT ON COLUMN tagg.permission.updated IS
    'Timestamp when this permission was last updated.';
COMMENT ON COLUMN tagg.permission.is_active IS
    'Soft-delete flag; inactive permissions are excluded from checks.';

CREATE UNIQUE INDEX permission_unique_name_idx
    ON tagg.permission (name);

CREATE INDEX permission_active_idx
    ON tagg.permission (id)
    WHERE is_active = true;

CREATE TRIGGER set_timestamp
    BEFORE INSERT OR UPDATE
    ON tagg.permission
    FOR EACH ROW
    EXECUTE FUNCTION tagg.trigger_update_timestamp();

COMMENT ON TRIGGER set_timestamp ON tagg.permission IS
    'Automatically sets updated=NOW() on INSERT or UPDATE.';

-- ========================================================================
-- 2. Seed permissions
-- ========================================================================
INSERT INTO tagg.permission (name, descr) VALUES
    -- Task lifecycle
    ('task:create',      'Create new agent tasks.'),
    ('task:assign:self', 'Assign tasks to yourself.'),
    ('task:assign:any',  'Assign tasks to any agent.'),
    ('task:claim',       'Claim a pending task.'),
    ('task:advance',     'Advance a task to its next workflow step.'),
    ('task:link',        'Link messages to tasks.'),
    -- Artifact / file / message
    ('artifact:create',  'Create artifacts.'),
    ('fs:write',         'Write files.'),
    ('message:send',     'Send messages.'),
    -- Tagging
    ('tag:apply',        'Apply tags to entities.'),
    ('tag:manage',       'Create and manage tags.'),
    -- Admin
    ('admin:agent',      'Create and manage agents.'),
    ('admin:project',    'Create and manage projects.'),
    ('admin:artifact_type', 'Create and manage artifact types.'),
    ('admin:obj_type',    'Create and manage object types.'),
    ('admin:note',       'Create and manage notes.'),
    ('admin:object',     'Create and manage objects.'),
    ('admin:conversation', 'Create and manage conversations.'),
    ('admin:soft_delete',  'Inactivate and reactivate entities.');

-- ========================================================================
-- 3. skill_permission_crosswalk table
-- ========================================================================
CREATE TABLE tagg.skill_permission_crosswalk (
    id              bigint  GENERATED ALWAYS AS IDENTITY,
    skill_id        bigint  NOT NULL,
    permission_id   bigint  NOT NULL,
    created         timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated         timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active       boolean     NOT NULL DEFAULT true
);

COMMENT ON TABLE  tagg.skill_permission_crosswalk IS
    'M:N crosswalk linking skills to permissions.  Defines what each skill is allowed to do.';
COMMENT ON COLUMN tagg.skill_permission_crosswalk.id IS
    'Primary key, auto-generated crosswalk identifier.';
COMMENT ON COLUMN tagg.skill_permission_crosswalk.skill_id IS
    'FK to skill. The skill receiving the permission.';
COMMENT ON COLUMN tagg.skill_permission_crosswalk.permission_id IS
    'FK to permission. The permission granted to the skill.';
COMMENT ON COLUMN tagg.skill_permission_crosswalk.created IS
    'Timestamp when this crosswalk was created.';
COMMENT ON COLUMN tagg.skill_permission_crosswalk.updated IS
    'Timestamp when this crosswalk was last updated.';
COMMENT ON COLUMN tagg.skill_permission_crosswalk.is_active IS
    'Soft-delete flag; inactive links are excluded from permission checks.';

ALTER TABLE tagg.skill_permission_crosswalk
    ADD CONSTRAINT skill_permission_crosswalk_pkey
    PRIMARY KEY (id);

ALTER TABLE tagg.skill_permission_crosswalk
    ADD CONSTRAINT skill_permission_crosswalk_skill_fk
    FOREIGN KEY (skill_id)
    REFERENCES tagg.skill (id);

ALTER TABLE tagg.skill_permission_crosswalk
    ADD CONSTRAINT skill_permission_crosswalk_permission_fk
    FOREIGN KEY (permission_id)
    REFERENCES tagg.permission (id);

ALTER TABLE tagg.skill_permission_crosswalk
    ADD CONSTRAINT skill_permission_crosswalk_unique
    UNIQUE (skill_id, permission_id);

CREATE INDEX skill_permission_crosswalk_skill_id_idx
    ON tagg.skill_permission_crosswalk (skill_id);

CREATE INDEX skill_permission_crosswalk_permission_id_idx
    ON tagg.skill_permission_crosswalk (permission_id);

CREATE INDEX skill_permission_crosswalk_active_idx
    ON tagg.skill_permission_crosswalk (id)
    WHERE is_active = true;

CREATE TRIGGER set_timestamp
    BEFORE INSERT OR UPDATE
    ON tagg.skill_permission_crosswalk
    FOR EACH ROW
    EXECUTE FUNCTION tagg.trigger_update_timestamp();

COMMENT ON TRIGGER set_timestamp ON tagg.skill_permission_crosswalk IS
    'Automatically sets updated=NOW() on INSERT or UPDATE.';

-- ========================================================================
-- 4. Assign permissions to existing skills
-- ========================================================================
-- code-python: write code, create tasks/artifacts/files, send messages
INSERT INTO tagg.skill_permission_crosswalk (skill_id, permission_id)
SELECT s.id, p.id
FROM tagg.skill s, tagg.permission p
WHERE s.name = 'code-python'
  AND p.name IN ('task:create', 'task:assign:self', 'task:advance',
                 'artifact:create', 'fs:write', 'message:send', 'task:link');

-- review-sql: advance tasks, create artifacts, send messages
INSERT INTO tagg.skill_permission_crosswalk (skill_id, permission_id)
SELECT s.id, p.id
FROM tagg.skill s, tagg.permission p
WHERE s.name = 'review-sql'
  AND p.name IN ('task:advance', 'artifact:create', 'message:send');

-- filesystem: write files, create artifacts
INSERT INTO tagg.skill_permission_crosswalk (skill_id, permission_id)
SELECT s.id, p.id
FROM tagg.skill s, tagg.permission p
WHERE s.name = 'filesystem'
  AND p.name IN ('fs:write', 'artifact:create');

-- agent-communication: create/link tasks, send messages
INSERT INTO tagg.skill_permission_crosswalk (skill_id, permission_id)
SELECT s.id, p.id
FROM tagg.skill s, tagg.permission p
WHERE s.name = 'agent-communication'
  AND p.name IN ('task:create', 'task:assign:self', 'message:send', 'task:link');

-- ========================================================================
-- 5. Session-level caller identity
-- ========================================================================
CREATE OR REPLACE FUNCTION tagg.set_agent_id(p_agent_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tagg.user WHERE id = p_agent_id AND is_agent = true AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive agent ID: %', p_agent_id;
    END IF;
    PERFORM set_config('tagg.agent_id', p_agent_id::text, false);
END;
$function$;

COMMENT ON FUNCTION tagg.set_agent_id IS
    'Sets the current session''s agent identity.  Must be called at the start of a session so that subsequent SECURITY DEFINER functions can identify the caller.  Raises if the ID is not a valid, active agent.';

-- ========================================================================
-- 6. Permission-checking functions
-- ========================================================================
CREATE OR REPLACE FUNCTION tagg.check_permission(p_permission_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_agent_id bigint;
BEGIN
    BEGIN
        v_agent_id := current_setting('tagg.agent_id')::bigint;
    EXCEPTION WHEN OTHERS THEN
        RETURN false;
    END;

    RETURN EXISTS (
        SELECT 1
        FROM tagg.skill_user_crosswalk x
        JOIN tagg.skill_permission_crosswalk sp ON sp.skill_id = x.skill_id
        JOIN tagg.permission p ON p.id = sp.permission_id
        WHERE x.user_id = v_agent_id
          AND x.is_active = true
          AND sp.is_active = true
          AND p.is_active = true
          AND p.name = p_permission_name
    );
END;
$function$;

COMMENT ON FUNCTION tagg.check_permission IS
    'Returns true if the current session agent (set via set_agent_id) has the named permission through their assigned skills.  Returns false if no agent has been set.';

CREATE OR REPLACE FUNCTION tagg.require_permission(p_permission_name text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_agent_id bigint;
    v_has_perm boolean;
BEGIN
    BEGIN
        v_agent_id := current_setting('tagg.agent_id')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_agent_id := NULL;
    END;

    v_has_perm := tagg.check_permission(p_permission_name);

    IF NOT v_has_perm THEN
        PERFORM tagg.log_error(
            'require_permission',
            format('Agent %s denied permission: %s', v_agent_id, p_permission_name),
            'Caller lacks the required permission to invoke this function.',
            jsonb_build_object('agent_id', v_agent_id, 'permission', p_permission_name)
        );
        RAISE EXCEPTION 'Permission denied: % (agent %)', p_permission_name, v_agent_id
            USING HINT = 'Ensure the agent has a skill that grants this permission.';
    END IF;
END;
$function$;

COMMENT ON FUNCTION tagg.require_permission IS
    'Checks that the session agent has the named permission.  Logs to tagg.error_log and raises EXCEPTION if denied.  Designed to be called at the top of every SECURITY DEFINER function.';

-- ========================================================================
-- 7. Add require_permission to every callable SECURITY DEFINER function
-- ========================================================================

-- 7a. agent_task_add
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
    PERFORM tagg.require_permission('task:create');

    IF p_from_user_id = p_to_user_id THEN
        PERFORM tagg.require_permission('task:assign:self');
    ELSE
        PERFORM tagg.require_permission('task:assign:any');
    END IF;

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
    'Creates a new agent task.  Requires task:create and either task:assign:self or task:assign:any depending on whether the target differs from the caller.  Defaults to the "standard" workflow if no workflow_id is provided.';

-- 7b. artifact_add
CREATE OR REPLACE FUNCTION tagg.artifact_add(
    p_agent_task_id  bigint,
    p_name           varchar(50),
    p_descr          varchar(400),
    p_artifact_type  varchar(50),
    p_body           text
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('artifact:create');

    INSERT INTO tagg.artifact (agent_task_id, name, descr, artifact_type, body)
    VALUES (p_agent_task_id, p_name, p_descr, p_artifact_type, p_body)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('artifact', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('artifact_add', SQLERRM, SQLSTATE,
        jsonb_build_object('agent_task_id', p_agent_task_id, 'name', p_name,
                           'descr', p_descr, 'artifact_type', p_artifact_type));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.artifact_add IS
    'Creates a new artifact linked to a task.  Requires artifact:create.';

-- 7c. advance_workflow
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
    PERFORM tagg.require_permission('task:advance');

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

    SELECT ws.task_status_id, ws.seq_num
        INTO v_next_status_id, v_next_seq
        FROM tagg.workflow_step ws
        WHERE ws.workflow_id = v_workflow_id
          AND ws.seq_num > v_current_seq
          AND ws.is_active = true
        ORDER BY ws.seq_num
        LIMIT 1;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    UPDATE tagg.agent_task
        SET task_status_id = v_next_status_id
        WHERE id = p_task_id;

    PERFORM tagg.log_operation('agent_task', p_task_id, 'advance_workflow');

    RETURN v_next_status_id;
END;
$function$;

COMMENT ON FUNCTION tagg.advance_workflow IS
    'Moves a task to the next status in its workflow.  Requires task:advance.  Returns the new task_status_id, or NULL at the terminal step.';

-- 7d. message_add
CREATE OR REPLACE FUNCTION tagg.message_add(
    p_conversation_id           bigint,
    p_message                   text,
    p_from_user                 bigint,
    p_to_user                   bigint,
    p_original_theme_alignment  real,
    p_parent_id                 bigint DEFAULT NULL
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('message:send');

    INSERT INTO tagg.message (conversation_id, message, from_user, to_user, original_theme_alignment, parent_id)
    VALUES (p_conversation_id, p_message, p_from_user, p_to_user, p_original_theme_alignment, p_parent_id)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('message', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('message_add', SQLERRM, SQLSTATE,
        jsonb_build_object('conversation_id', p_conversation_id, 'from_user', p_from_user,
                           'to_user', p_to_user, 'original_theme_alignment', p_original_theme_alignment,
                           'parent_id', p_parent_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.message_add IS
    'Adds a message to a conversation.  Requires message:send.';

-- 7e. link_message_agent_task
CREATE OR REPLACE FUNCTION tagg.link_message_agent_task(p_message_id bigint, p_agent_task_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('task:link');

    INSERT INTO tagg.message_agent_task_crosswalk (message_id, agent_task_id)
    VALUES (p_message_id, p_agent_task_id)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('message', p_message_id, 'link_agent_task');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('link_message_agent_task', SQLERRM, SQLSTATE,
        jsonb_build_object('message_id', p_message_id, 'agent_task_id', p_agent_task_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.link_message_agent_task IS
    'Links a message to an agent task.  Requires task:link.';

-- 7f. file_add
CREATE OR REPLACE FUNCTION tagg.file_add(
    p_file_ext  varchar(10),
    p_name      varchar(50),
    p_descr     varchar(400),
    p_body      bytea DEFAULT NULL
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('fs:write');

    INSERT INTO tagg.file (file_ext, name, descr, body)
    VALUES (p_file_ext, p_name, p_descr, p_body)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('file', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('file_add', SQLERRM, SQLSTATE,
        jsonb_build_object('file_ext', p_file_ext, 'name', p_name, 'descr', p_descr));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.file_add IS
    'Adds a file record.  Requires fs:write.';

-- 7g. apply_tag
CREATE OR REPLACE FUNCTION tagg.apply_tag(p_table_name text, p_tag_id bigint, p_other_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    fk_col text;
BEGIN
    PERFORM tagg.require_permission('tag:apply');

    IF p_table_name NOT IN ('project','file','note','object','conversation','message','agent_task','artifact') THEN
        RAISE EXCEPTION 'Unsupported entity type: %. Must be one of: project, file, note, object, conversation, message, agent_task, artifact.', p_table_name;
    END IF;

    fk_col := p_table_name || '_id';

    EXECUTE format(
        'INSERT INTO tagg.%I (tag_id, %I) VALUES ($1, $2)',
        'tag_' || p_table_name || '_crosswalk',
        fk_col
    ) USING p_tag_id, p_other_id;

    PERFORM tagg.log_operation(p_table_name, p_other_id, 'tag_apply');
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('apply_tag', SQLERRM, SQLSTATE,
        jsonb_build_object('table_name', p_table_name, 'tag_id', p_tag_id, 'other_id', p_other_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.apply_tag IS
    'Applies a tag to a supported entity.  Requires tag:apply.';

-- 7h. agent_add
CREATE OR REPLACE FUNCTION tagg.agent_add(
    p_name           varchar(50),
    p_descr          varchar(400),
    p_prompt         text        DEFAULT NULL,
    p_command        text        DEFAULT NULL,
    p_max_concurrent integer     DEFAULT 1,
    p_skill_names    text[]      DEFAULT NULL
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
    skill_name text;
BEGIN
    PERFORM tagg.require_permission('admin:agent');

    INSERT INTO tagg.user (name, descr, is_agent, prompt, command, max_concurrent)
    VALUES (p_name, p_descr, true, p_prompt, p_command, p_max_concurrent)
    RETURNING id INTO new_id;

    IF p_skill_names IS NOT NULL THEN
        FOREACH skill_name IN ARRAY p_skill_names
        LOOP
            INSERT INTO tagg.skill_user_crosswalk (skill_id, user_id)
            SELECT id, new_id FROM tagg.skill WHERE name = skill_name;
        END LOOP;
    END IF;

    PERFORM tagg.log_operation('user', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('agent_add', SQLERRM, SQLSTATE,
        jsonb_build_object('name', p_name, 'descr', p_descr));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.agent_add IS
    'Creates a new agent user.  Requires admin:agent.';

-- 7i. project_add
CREATE OR REPLACE FUNCTION tagg.project_add(
    p_name          varchar(50),
    p_descr         varchar(400),
    p_created_by_id bigint
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('admin:project');

    INSERT INTO tagg.project (name, descr, created_by_id)
    VALUES (p_name, p_descr, p_created_by_id)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('project', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('project_add', SQLERRM, SQLSTATE,
        jsonb_build_object('name', p_name, 'descr', p_descr, 'created_by_id', p_created_by_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.project_add IS
    'Creates a new project.  Requires admin:project.';

-- 7j. tag_add
CREATE OR REPLACE FUNCTION tagg.tag_add(p_name varchar(50), p_descr varchar(400))
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('tag:manage');

    INSERT INTO tagg.tag (name, descr)
    VALUES (p_name, p_descr)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('tag', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('tag_add', SQLERRM, SQLSTATE,
        jsonb_build_object('name', p_name, 'descr', p_descr));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.tag_add IS
    'Creates a new tag.  Requires tag:manage.';

-- 7k. artifact_type_add
CREATE OR REPLACE FUNCTION tagg.artifact_type_add(p_name varchar(50), p_descr varchar(400))
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('admin:artifact_type');

    INSERT INTO tagg.artifact_type (name, descr)
    VALUES (p_name, p_descr)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('artifact_type', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('artifact_type_add', SQLERRM, SQLSTATE,
        jsonb_build_object('name', p_name, 'descr', p_descr));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.artifact_type_add IS
    'Creates a new artifact type.  Requires admin:artifact_type.';

-- 7l. obj_type_add
CREATE OR REPLACE FUNCTION tagg.obj_type_add(p_name varchar(50), p_descr varchar(400))
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('admin:obj_type');

    INSERT INTO tagg.obj_type (name, descr)
    VALUES (p_name, p_descr)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('obj_type', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('obj_type_add', SQLERRM, SQLSTATE,
        jsonb_build_object('name', p_name, 'descr', p_descr));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.obj_type_add IS
    'Creates a new object type.  Requires admin:obj_type.';

-- 7m. note_add
CREATE OR REPLACE FUNCTION tagg.note_add(p_name varchar(50), p_descr varchar(400), p_body text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('admin:note');

    INSERT INTO tagg.note (name, descr, body)
    VALUES (p_name, p_descr, p_body)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('note', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('note_add', SQLERRM, SQLSTATE,
        jsonb_build_object('name', p_name, 'descr', p_descr));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.note_add IS
    'Creates a new note.  Requires admin:note.';

-- 7n. object_add
CREATE OR REPLACE FUNCTION tagg.object_add(
    p_obj_type_id bigint,
    p_name        varchar(50),
    p_descr       varchar(400),
    p_body        jsonb DEFAULT NULL
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('admin:object');

    INSERT INTO tagg.object (obj_type_id, name, descr, body)
    VALUES (p_obj_type_id, p_name, p_descr, p_body)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('object', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('object_add', SQLERRM, SQLSTATE,
        jsonb_build_object('obj_type_id', p_obj_type_id, 'name', p_name, 'descr', p_descr, 'body', p_body));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.object_add IS
    'Creates a new object.  Requires admin:object.';

-- 7o. conversation_add
CREATE OR REPLACE FUNCTION tagg.conversation_add(
    p_title          varchar(200),
    p_original_theme text,
    p_project_id     bigint
)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    new_id bigint;
BEGIN
    PERFORM tagg.require_permission('admin:conversation');

    INSERT INTO tagg.conversation (title, original_theme, project_id)
    VALUES (p_title, p_original_theme, p_project_id)
    RETURNING id INTO new_id;

    PERFORM tagg.log_operation('conversation', new_id, 'add');
    RETURN new_id;
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('conversation_add', SQLERRM, SQLSTATE,
        jsonb_build_object('title', p_title, 'project_id', p_project_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.conversation_add IS
    'Creates a new conversation.  Requires admin:conversation.';

-- 7p. set_active / inactivate / reactivate
CREATE OR REPLACE FUNCTION tagg.set_active(p_table_name text, p_id bigint, p_active boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    updated_count int;
    op_type text;
BEGIN
    PERFORM tagg.require_permission('admin:soft_delete');
    PERFORM tagg.assert_valid_entity(p_table_name);

    op_type := CASE WHEN p_active THEN 'reactivate' ELSE 'inactivate' END;

    IF p_active THEN
        EXECUTE format('UPDATE tagg.%I SET is_active = true WHERE id = $1 AND NOT is_active', p_table_name)
        USING p_id;
    ELSE
        EXECUTE format('UPDATE tagg.%I SET is_active = false WHERE id = $1 AND is_active', p_table_name)
        USING p_id;
    END IF;

    GET DIAGNOSTICS updated_count = ROW_COUNT;

    IF updated_count = 0 THEN
        RAISE EXCEPTION 'No % row found in tagg.% with id=%',
            CASE WHEN p_active THEN 'inactive' ELSE 'active' END, p_table_name, p_id;
    END IF;

    PERFORM tagg.log_operation(p_table_name, p_id, op_type);
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('set_active', SQLERRM, SQLSTATE,
        jsonb_build_object('table_name', p_table_name, 'id', p_id, 'active', p_active));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.set_active IS
    'Sets is_active on any valid entity table.  Requires admin:soft_delete.';

CREATE OR REPLACE FUNCTION tagg.inactivate(p_table_name text, p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
    PERFORM tagg.set_active(p_table_name, p_id, false);
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('inactivate', SQLERRM, SQLSTATE,
        jsonb_build_object('table_name', p_table_name, 'id', p_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.inactivate IS
    'Inactivates a row (soft delete).  Delegates to set_active.  Requires admin:soft_delete.';

CREATE OR REPLACE FUNCTION tagg.reactivate(p_table_name text, p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
    PERFORM tagg.set_active(p_table_name, p_id, true);
EXCEPTION WHEN OTHERS THEN
    PERFORM tagg.log_error('reactivate', SQLERRM, SQLSTATE,
        jsonb_build_object('table_name', p_table_name, 'id', p_id));
    RAISE;
END;
$function$;

COMMENT ON FUNCTION tagg.reactivate IS
    'Reactivates a soft-deleted row.  Delegates to set_active.  Requires admin:soft_delete.';

-- ========================================================================
-- 8. Add an admin agent that has all admin permissions
-- ========================================================================
INSERT INTO tagg.permission (name, descr)
SELECT 'admin:skill', 'Create and manage skills.'
WHERE NOT EXISTS (SELECT 1 FROM tagg.permission WHERE name = 'admin:skill');

INSERT INTO tagg.skill (name, descr, content)
VALUES ('admin',
    'Administrator access.  Grants all admin-level permissions.',
    'You are an administrator.  You can manage agents, projects, tags, soft-delete entities, and system configuration.'
);

INSERT INTO tagg.skill_permission_crosswalk (skill_id, permission_id)
SELECT s.id, p.id
FROM tagg.skill s, tagg.permission p
WHERE s.name = 'admin'
  AND p.name LIKE 'admin:%';

-- ========================================================================
-- 9. Agent-task DB functions (portable, permission-aware)
-- ========================================================================

INSERT INTO tagg.operation_type (name, descr)
SELECT 'claim', 'Task claimed by an agent'
WHERE NOT EXISTS (SELECT 1 FROM tagg.operation_type WHERE name = 'claim');

-- 9a. claim_task — atomically claim a pending task
CREATE OR REPLACE FUNCTION tagg.claim_task(p_task_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_agent_id bigint;
    v_row record;
BEGIN
    PERFORM tagg.require_permission('task:claim');
    v_agent_id := current_setting('tagg.agent_id')::bigint;

    UPDATE tagg.agent_task
    SET task_status_id = 3
    WHERE id = p_task_id
      AND task_status_id IN (1, 2)
      AND to_user_id = v_agent_id
      AND is_active = true
    RETURNING id, from_user_id, to_user_id, task, project_id, parent_id,
              task_status_id, workflow_id, created, updated, is_active
    INTO v_row;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', COALESCE(
                (SELECT format('task %s not pending (status %s)', p_task_id, task_status_id)
                 FROM tagg.agent_task WHERE id = p_task_id),
                format('task %s not found', p_task_id)
            )
        );
    END IF;

    BEGIN
        PERFORM tagg.log_operation('agent_task', p_task_id, 'claim');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    RETURN jsonb_build_object(
        'success', true,
        'task', jsonb_build_object(
            'id', v_row.id,
            'from_user_id', v_row.from_user_id,
            'to_user_id', v_row.to_user_id,
            'task', v_row.task,
            'project_id', v_row.project_id,
            'parent_id', v_row.parent_id,
            'task_status_id', v_row.task_status_id,
            'workflow_id', v_row.workflow_id,
            'created', v_row.created,
            'updated', v_row.updated,
            'is_active', v_row.is_active
        )
    );
END;
$function$;

COMMENT ON FUNCTION tagg.claim_task IS
    'Atomically claims a pending task (status 1 -> 3) for the current session agent. Requires task:claim. Validates to_user_id matches the caller. Returns the claimed task row or an error.';

-- 9b. get_agent_context — return agent info, skills, permissions as jsonb
CREATE OR REPLACE FUNCTION tagg.get_agent_context(p_agent_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_agent_id bigint;
BEGIN
    v_agent_id := COALESCE(p_agent_id, current_setting('tagg.agent_id')::bigint);

    RETURN (
        SELECT jsonb_build_object(
            'agent_id', u.id,
            'name', u.name,
            'descr', u.descr,
            'prompt', u.prompt,
            'skills', COALESCE(
                (SELECT jsonb_agg(jsonb_build_object('name', s.name, 'content', s.content) ORDER BY s.name)
                 FROM tagg.skill_user_crosswalk x
                 JOIN tagg.skill s ON s.id = x.skill_id
                 WHERE x.user_id = u.id AND x.is_active = true AND s.is_active = true),
                '[]'::jsonb
            ),
            'permissions', COALESCE(
                (SELECT jsonb_agg(DISTINCT p.name ORDER BY p.name)
                 FROM tagg.skill_user_crosswalk x
                 JOIN tagg.skill_permission_crosswalk sp ON sp.skill_id = x.skill_id
                 JOIN tagg.permission p ON p.id = sp.permission_id
                 WHERE x.user_id = u.id AND x.is_active = true AND sp.is_active = true AND p.is_active = true),
                '[]'::jsonb
            )
        )
        FROM tagg.user u
        WHERE u.id = v_agent_id AND u.is_active = true
    );
END;
$function$;

COMMENT ON FUNCTION tagg.get_agent_context IS
    'Returns the agent''s name, description, prompt, skills, and permissions as jsonb. Read-only, no permission required. Accepts an optional agent_id (defaults to the current session agent).';

-- 9c. get_pending_tasks — list unclaimed tasks for the current agent
CREATE OR REPLACE FUNCTION tagg.get_pending_tasks(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_agent_id bigint;
BEGIN
    v_agent_id := current_setting('tagg.agent_id')::bigint;

    RETURN COALESCE(
        (SELECT jsonb_agg(
            jsonb_build_object(
                'id', id,
                'from_user_id', from_user_id,
                'task', task,
                'project_id', project_id,
                'parent_id', parent_id,
                'created', created
            )
            ORDER BY id
         )
         FROM tagg.agent_task
         WHERE to_user_id = v_agent_id
           AND task_status_id = 1
           AND is_active = true
         LIMIT p_limit),
        '[]'::jsonb
    );
END;
$function$;

COMMENT ON FUNCTION tagg.get_pending_tasks IS
    'Returns up to p_limit pending tasks assigned to the current session agent as a jsonb array. Read-only, no permission required.';

RESET search_path;
