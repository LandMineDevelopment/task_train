-- ============================================================================
-- Agent Configuration: prompts, skills, and runtime config
-- ============================================================================
-- Stores agent initialization prompts and reusable skill definitions in the
-- database as the source of truth. sync_agents.sh renders prompts and
-- frontmatter into the OpenCode Markdown agent files used at runtime.
-- ============================================================================

SET search_path TO tagg, pg_catalog, pg_temp;

-- ------------------------------------------------------------------------
-- 1. Add runtime columns to tagg.user
-- ------------------------------------------------------------------------
ALTER TABLE tagg.user
    ADD COLUMN prompt         text,
    ADD COLUMN command        text,
    ADD COLUMN max_concurrent integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN tagg.user.prompt IS
    'Database source of truth for an agent prompt. sync_agents.sh renders it into the OpenCode Markdown agent file.';
COMMENT ON COLUMN tagg.user.command IS
    'Legacy per-agent command metadata. The supported external supervisor uses commands from supervisor/agents.json.';
COMMENT ON COLUMN tagg.user.max_concurrent IS
    'Per-agent concurrency metadata. The supported external supervisor enforces configured concurrency limits.';

-- ------------------------------------------------------------------------
-- 2. skill table
-- ------------------------------------------------------------------------
CREATE TABLE tagg.skill (
    id          bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        varchar(50)  NOT NULL,
    descr       varchar(400) NOT NULL,
    content     text         NOT NULL,
    created     timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated     timestamptz  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active   boolean      NOT NULL DEFAULT true
);

COMMENT ON TABLE  tagg.skill IS
    'Lookup table for reusable agent capabilities. Each row defines a named skill (e.g. code-python, review-sql) with full prompt content. Skills are assigned to agents via skill_user_crosswalk.';
COMMENT ON COLUMN tagg.skill.id IS
    'Primary key, auto-generated skill identifier.';
COMMENT ON COLUMN tagg.skill.name IS
    'Unique name for the skill (e.g. code-python, review-sql, filesystem).';
COMMENT ON COLUMN tagg.skill.descr IS
    'Description of what capability this skill provides.';
COMMENT ON COLUMN tagg.skill.content IS
    'Full skill prompt content. Instructions, capabilities, constraints, and examples injected into the agent context at startup.';
COMMENT ON COLUMN tagg.skill.created IS
    'Timestamp when this skill was created.';
COMMENT ON COLUMN tagg.skill.updated IS
    'Timestamp when this skill was last updated.';
COMMENT ON COLUMN tagg.skill.is_active IS
    'Soft-delete flag; inactive skills are excluded from agent configuration by default.';

CREATE UNIQUE INDEX skill_unique_name_idx
    ON tagg.skill (name);

CREATE INDEX skill_active_idx
    ON tagg.skill (id)
    WHERE is_active = true;

CREATE TRIGGER set_timestamp
    BEFORE INSERT OR UPDATE
    ON tagg.skill
    FOR EACH ROW
    EXECUTE FUNCTION tagg.trigger_update_timestamp();

COMMENT ON TRIGGER set_timestamp ON tagg.skill IS
    'Automatically sets updated=NOW() on INSERT or UPDATE.';

-- ------------------------------------------------------------------------
-- 3. skill_user_crosswalk table
-- ------------------------------------------------------------------------
CREATE TABLE tagg.skill_user_crosswalk (
    id        bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    skill_id  bigint  NOT NULL,
    user_id   bigint  NOT NULL,
    created   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated   timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_active boolean     NOT NULL DEFAULT true
);

COMMENT ON TABLE  tagg.skill_user_crosswalk IS
    'M:N crosswalk linking skills to agents. Determines which skills each agent has access to at startup.';
COMMENT ON COLUMN tagg.skill_user_crosswalk.id IS
    'Primary key, auto-generated crosswalk identifier.';
COMMENT ON COLUMN tagg.skill_user_crosswalk.skill_id IS
    'FK to skill. The skill assigned to the agent.';
COMMENT ON COLUMN tagg.skill_user_crosswalk.user_id IS
    'FK to user. The agent receiving the skill.';
COMMENT ON COLUMN tagg.skill_user_crosswalk.created IS
    'Timestamp when this crosswalk was created.';
COMMENT ON COLUMN tagg.skill_user_crosswalk.updated IS
    'Timestamp when this crosswalk was last updated.';
COMMENT ON COLUMN tagg.skill_user_crosswalk.is_active IS
    'Soft-delete flag; inactive crosswalks are excluded from agent configuration by default.';

ALTER TABLE tagg.skill_user_crosswalk
    ADD CONSTRAINT skill_user_crosswalk_skill_fk
    FOREIGN KEY (skill_id)
    REFERENCES tagg.skill (id);

ALTER TABLE tagg.skill_user_crosswalk
    ADD CONSTRAINT skill_user_crosswalk_user_fk
    FOREIGN KEY (user_id)
    REFERENCES tagg.user (id);

ALTER TABLE tagg.skill_user_crosswalk
    ADD CONSTRAINT skill_user_crosswalk_unique
    UNIQUE (skill_id, user_id);

CREATE INDEX skill_user_crosswalk_skill_id_idx
    ON tagg.skill_user_crosswalk (skill_id);

CREATE INDEX skill_user_crosswalk_user_id_idx
    ON tagg.skill_user_crosswalk (user_id);

CREATE INDEX skill_user_crosswalk_active_idx
    ON tagg.skill_user_crosswalk (id)
    WHERE is_active = true;

CREATE TRIGGER set_timestamp
    BEFORE INSERT OR UPDATE
    ON tagg.skill_user_crosswalk
    FOR EACH ROW
    EXECUTE FUNCTION tagg.trigger_update_timestamp();

COMMENT ON TRIGGER set_timestamp ON tagg.skill_user_crosswalk IS
    'Automatically sets updated=NOW() on INSERT or UPDATE.';

-- ------------------------------------------------------------------------
-- 4. Seed example skills
-- ------------------------------------------------------------------------
INSERT INTO tagg.skill (name, descr, content) VALUES
    ('code-python',
     'Python implementation artifacts including PEP8, type hints, and tests.',
     'You are a Python developer. Produce complete implementation output as an artifact. Follow PEP8 style guidelines, write type hints for all function signatures, include Google-style docstrings, and prefer the standard library unless the task specifies otherwise. Do not modify files in the project workspace.'),
    ('review-sql',
     'SQL query review for performance, security, and correctness.',
     'When reviewing SQL: check for missing WHERE clauses that could cause full table scans. Verify JOIN columns are indexed. Watch for SQL injection vectors in dynamic queries. Confirm EXPLAIN ANALYZE output is acceptable. Flag any N+1 query patterns.'),
    ('filesystem',
     'Ability to read and write files referenced in task context.',
     'You can read and write files on the local filesystem. File paths are provided in the task context. Always confirm the working directory before reading or writing. Use atomic writes (write to temp file, then rename). Never follow symlinks outside the project directory.'),
    ('agent-communication',
     'How to delegate tasks to other agents or create child tasks.',
     'You can create tasks for other agents by calling agent_task_add(). When you need work that is outside your capabilities, create a child task assigned to the appropriate agent. Set the parent_id to your current task so the dependency chain is preserved. Monitor child tasks by querying agent_task with the parent_id filter.');

-- ------------------------------------------------------------------------
-- 5. Assign skills to existing agents
-- ------------------------------------------------------------------------
-- Agent-Alpha (user_id=3) gets all skills
INSERT INTO tagg.skill_user_crosswalk (skill_id, user_id)
SELECT s.id, u.id
FROM tagg.skill s, tagg.user u
WHERE u.name = 'Agent-Alpha';

-- Agent-Beta (user_id=4) gets review-sql and filesystem
INSERT INTO tagg.skill_user_crosswalk (skill_id, user_id)
SELECT s.id, u.id
FROM tagg.skill s, tagg.user u
WHERE u.name = 'Agent-Beta'
  AND s.name IN ('review-sql', 'filesystem');

-- ------------------------------------------------------------------------
-- 6. Update existing agents with prompts and commands (no-op examples)
-- ------------------------------------------------------------------------
UPDATE tagg.user
SET prompt = 'You are Agent-Alpha, a senior software engineer. You write production-quality code, review changes, and can delegate work to other agents when needed. Your primary role is to implement new features and fix bugs across the codebase.',
    command = 'python3 /opt/agents/coding_agent.py'
WHERE name = 'Agent-Alpha';

UPDATE tagg.user
SET prompt = 'You are Agent-Beta, a code reviewer and QA specialist. You review SQL queries, test changes, and validate that implementations meet requirements before they are marked complete.',
    command = 'python3 /opt/agents/coding_agent.py'
WHERE name = 'Agent-Beta';

-- ------------------------------------------------------------------------
-- 7. Update agent_add to accept prompt, command, and skills
-- ------------------------------------------------------------------------
-- Drop the old two-param overload so the new one is the only version.
DROP FUNCTION IF EXISTS tagg.agent_add(character varying, character varying);

CREATE OR REPLACE FUNCTION tagg.agent_add(
    p_name          varchar(50),
    p_descr         varchar(400),
    p_prompt        text        DEFAULT NULL,
    p_command       text        DEFAULT NULL,
    p_max_concurrent integer    DEFAULT 1,
    p_skill_names   text[]      DEFAULT NULL
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
    'Creates a new agent user with optional prompt, command, max_concurrent limit, and skill assignments via p_skill_names text array.';

RESET search_path;
