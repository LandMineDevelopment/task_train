-- Durable conversation APIs for user/agent and agent/agent interactions.
SET search_path TO tagg, pg_catalog, pg_temp;

ALTER TABLE tagg.conversation
    ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'agent_agent',
    ADD COLUMN IF NOT EXISTS owner_user_id bigint,
    ADD COLUMN IF NOT EXISTS conductor_user_id bigint,
    ADD COLUMN IF NOT EXISTS opencode_session_id text,
    ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE tagg.message
    ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'assistant',
    ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'complete',
    ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

UPDATE tagg.message m
SET role = CASE WHEN u.is_agent THEN 'assistant' ELSE 'user' END
FROM tagg.user u
WHERE u.id = m.from_user
  AND m.role = 'assistant';

ALTER TABLE tagg.conversation
    DROP CONSTRAINT IF EXISTS conversation_kind_check;
ALTER TABLE tagg.conversation
    ADD CONSTRAINT conversation_kind_check
    CHECK (kind IN ('user_conductor', 'agent_agent', 'task'));

ALTER TABLE tagg.message
    DROP CONSTRAINT IF EXISTS message_role_check;
ALTER TABLE tagg.message
    ADD CONSTRAINT message_role_check
    CHECK (role IN ('user', 'assistant', 'system', 'tool'));

ALTER TABLE tagg.message
    DROP CONSTRAINT IF EXISTS message_status_check;
ALTER TABLE tagg.message
    ADD CONSTRAINT message_status_check
    CHECK (status IN ('pending', 'processing', 'complete', 'failed'));

CREATE INDEX IF NOT EXISTS conversation_user_conductor_idx
    ON tagg.conversation (project_id, owner_user_id, conductor_user_id, updated DESC)
    WHERE is_active = true AND kind = 'user_conductor';

CREATE INDEX IF NOT EXISTS message_conversation_created_idx
    ON tagg.message (conversation_id, created, id)
    WHERE is_active = true;

CREATE OR REPLACE FUNCTION tagg.get_or_create_user_conductor_conversation(
    p_project_id bigint,
    p_user_id bigint,
    p_conductor_id bigint,
    p_title varchar(200) DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_conversation_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tagg.user WHERE id = p_user_id AND is_active = true AND NOT is_agent) THEN
        RAISE EXCEPTION 'User % is not active', p_user_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM tagg.user WHERE id = p_conductor_id AND is_active = true AND is_agent) THEN
        RAISE EXCEPTION 'Conductor % is not an active agent', p_conductor_id;
    END IF;

    SELECT id INTO v_conversation_id
    FROM tagg.conversation
    WHERE project_id = p_project_id
      AND owner_user_id = p_user_id
      AND conductor_user_id = p_conductor_id
      AND kind = 'user_conductor'
      AND is_active = true
    ORDER BY updated DESC, id DESC
    LIMIT 1;

    IF v_conversation_id IS NULL THEN
        INSERT INTO tagg.conversation (
            title, original_theme, project_id, kind, owner_user_id, conductor_user_id
        ) VALUES (
            COALESCE(p_title, 'Chat with Conductor'),
            'user_conductor', p_project_id, 'user_conductor', p_user_id, p_conductor_id
        ) RETURNING id INTO v_conversation_id;
    END IF;

    RETURN v_conversation_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.append_conversation_message(
    p_conversation_id bigint,
    p_from_user_id bigint,
    p_to_user_id bigint,
    p_message text,
    p_role text,
    p_status text DEFAULT 'complete',
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_message_id bigint;
    v_parent_id bigint;
BEGIN
    IF p_message = '' THEN
        RAISE EXCEPTION 'Message cannot be empty';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM tagg.conversation WHERE id = p_conversation_id AND is_active = true) THEN
        RAISE EXCEPTION 'Conversation % is not active', p_conversation_id;
    END IF;

    SELECT id INTO v_parent_id
    FROM tagg.message
    WHERE conversation_id = p_conversation_id AND is_active = true
    ORDER BY id DESC
    LIMIT 1;

    INSERT INTO tagg.message (
        conversation_id, message, from_user, to_user, original_theme_alignment,
        parent_id, role, status, metadata
    ) VALUES (
        p_conversation_id, p_message, p_from_user_id, p_to_user_id, 0,
        v_parent_id, p_role, p_status, COALESCE(p_metadata, '{}'::jsonb)
    ) RETURNING id INTO v_message_id;

    UPDATE tagg.conversation SET updated = CURRENT_TIMESTAMP WHERE id = p_conversation_id;
    RETURN v_message_id;
END;
$function$;

CREATE OR REPLACE FUNCTION tagg.get_conversation_context(
    p_conversation_id bigint,
    p_limit integer DEFAULT 20
)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
    SELECT COALESCE(string_agg(
        format('%s (%s): %s', u.name, m.role, m.message),
        E'\n\n' ORDER BY m.id
    ), '')
    FROM (
        SELECT *
        FROM tagg.message
        WHERE conversation_id = p_conversation_id
          AND is_active = true
        ORDER BY id DESC
        LIMIT GREATEST(p_limit, 1)
    ) m
    JOIN tagg.user u ON u.id = m.from_user
$function$;

-- The external Python supervisor is the only supported process launcher.
DROP TRIGGER IF EXISTS spawn_agent_on_insert ON tagg.agent_task;

-- A supervisor reserves a task before it starts an agent process.  The agent
-- then claims the reserved task by moving it from reserved (2) to in_progress (3).
CREATE OR REPLACE FUNCTION tagg.reserve_task(p_task_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
    UPDATE tagg.agent_task
    SET task_status_id = 2
    WHERE id = p_task_id
      AND task_status_id = 1
      AND is_active = true
      AND NOT EXISTS (
          SELECT 1 FROM tagg.agent_task active
          WHERE active.conversation_id = tagg.agent_task.conversation_id
            AND active.to_user_id = tagg.agent_task.to_user_id
            AND active.id <> tagg.agent_task.id
            AND active.task_status_id IN (2, 3)
      );
    RETURN FOUND;
END;
$function$;

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
        RETURN jsonb_build_object('success', false, 'error', format('task %s is unavailable', p_task_id));
    END IF;

    PERFORM tagg.log_operation('agent_task', p_task_id, 'claim');
    RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_row));
END;
$function$;

-- The chat gateway persists user turns itself; the agent must not duplicate them.
UPDATE tagg.user
SET prompt = 'You are the Conductor, the human interface to the agent task system. The chat gateway has already persisted the user message and will persist your final response. Read the supplied database conversation context, respond directly to the user, and use the task tools only when delegation is needed. Never use send_message.sh to re-log a user or assistant message. Keep the user informed of created tasks, progress, and results.'
WHERE name = 'Conductor' AND is_active = true;

RESET search_path;
