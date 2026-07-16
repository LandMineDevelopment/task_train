-- ============================================================================
-- Store agent opencode config in DB (portable, single source of truth)
-- ============================================================================
-- Adds opencode_config JSONB column to tagg.user, seeds configs for existing
-- agents, and provides render_agent_config() to generate .md file content.
-- ============================================================================

SET search_path TO tagg, pg_catalog, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. Add opencode_config column
-- ---------------------------------------------------------------------------
ALTER TABLE tagg.user
    ADD COLUMN opencode_config jsonb;

COMMENT ON COLUMN tagg.user.opencode_config IS
    'JSONB object storing opencode agent file frontmatter.  Keys: mode (string), permissions (map of tool -> allow|deny).  Example: {"mode": "subagent", "permissions": {"bash": "allow", "edit": "deny", ...}}.  Rendered to .md files by sync_agents.sh.';

-- ---------------------------------------------------------------------------
-- 2. Seed configs for existing agents
-- ---------------------------------------------------------------------------
-- Each config matches the current agents/*.md frontmatter

UPDATE tagg.user SET opencode_config = '{
    "mode": "subagent",
    "permissions": {
        "bash": "allow", "read": "allow", "edit": "deny",
        "glob": "allow", "grep": "allow",
        "webfetch": "allow", "websearch": "allow",
        "task": "deny", "todowrite": "deny",
        "lsp": "deny", "skill": "deny"
    }
}'::jsonb WHERE name = 'Conductor';

UPDATE tagg.user SET opencode_config = '{
    "mode": "subagent",
    "permissions": {
        "bash": "allow", "read": "allow", "edit": "allow",
        "glob": "allow", "grep": "allow",
        "webfetch": "allow", "websearch": "allow",
        "task": "deny", "todowrite": "deny",
        "lsp": "allow", "skill": "deny"
    }
}'::jsonb WHERE name = 'Coder';

UPDATE tagg.user SET opencode_config = '{
    "mode": "subagent",
    "permissions": {
        "bash": "allow", "read": "allow", "edit": "allow",
        "glob": "allow", "grep": "allow",
        "webfetch": "allow", "websearch": "allow",
        "task": "deny", "todowrite": "deny",
        "lsp": "allow", "skill": "deny"
    }
}'::jsonb WHERE name = 'Tester';

UPDATE tagg.user SET opencode_config = '{
    "mode": "subagent",
    "permissions": {
        "bash": "allow", "read": "allow", "edit": "deny",
        "glob": "allow", "grep": "allow",
        "webfetch": "allow", "websearch": "allow",
        "task": "deny", "todowrite": "deny",
        "lsp": "allow", "skill": "deny"
    }
}'::jsonb WHERE name = 'Explorer';

UPDATE tagg.user SET opencode_config = '{
    "mode": "subagent",
    "permissions": {
        "bash": "allow", "read": "allow", "edit": "deny",
        "glob": "allow", "grep": "allow",
        "webfetch": "allow", "websearch": "allow",
        "task": "deny", "todowrite": "deny",
        "lsp": "allow", "skill": "deny"
    }
}'::jsonb WHERE name = 'Reviewer';

UPDATE tagg.user SET opencode_config = '{
    "mode": "subagent",
    "permissions": {
        "bash": "allow", "read": "allow", "edit": "allow",
        "glob": "allow", "grep": "allow",
        "webfetch": "allow", "websearch": "allow",
        "task": "deny", "todowrite": "deny",
        "lsp": "allow", "skill": "deny"
    }
}'::jsonb WHERE name = 'Admin-Agent';

-- Manager (internal orchestrator)
UPDATE tagg.user SET opencode_config = '{
    "mode": "subagent",
    "permissions": {
        "bash": "allow", "read": "allow", "edit": "deny",
        "glob": "allow", "grep": "allow",
        "webfetch": "allow", "websearch": "allow",
        "task": "deny", "todowrite": "deny",
        "lsp": "deny", "skill": "deny"
    }
}'::jsonb WHERE name = 'Manager';

-- ---------------------------------------------------------------------------
-- 3. render_agent_config(agent_id) — produce opencode .md file content
-- ---------------------------------------------------------------------------
-- Returns the complete markdown for an agent config file, with YAML
-- frontmatter built from opencode_config + descr, and the body from prompt.
-- Agents without both opencode_config and prompt return NULL.

CREATE OR REPLACE FUNCTION tagg.render_agent_config(p_agent_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_name      text;
    v_descr     text;
    v_prompt    text;
    v_config    jsonb;
    v_mode      text;
    v_perms     jsonb;
    v_yaml_perms text := '';
    v_key       text;
    v_val       text;
    v_result    text;
BEGIN
    SELECT u.name, u.descr, u.prompt, u.opencode_config
    INTO v_name, v_descr, v_prompt, v_config
    FROM tagg.user u
    WHERE u.id = p_agent_id AND u.is_active = true;

    IF NOT FOUND OR v_config IS NULL OR v_prompt IS NULL THEN
        RETURN NULL;
    END IF;

    v_mode := v_config->>'mode';
    v_perms := v_config->'permissions';

    -- Build YAML permissions block
    IF v_perms IS NOT NULL THEN
        v_yaml_perms := 'permission:';
        FOR v_key, v_val IN SELECT * FROM jsonb_each_text(v_perms) LOOP
            v_yaml_perms := v_yaml_perms || E'\n  ' || v_key || ': ' || v_val;
        END LOOP;
    END IF;

    -- Assemble full .md content
    v_result := '---' || E'\n'
             || 'description: "' || v_descr || '"' || E'\n'
             || 'mode: ' || COALESCE(v_mode, 'subagent') || E'\n'
             || v_yaml_perms || E'\n'
             || '---' || E'\n'
             || E'\n'
             || v_prompt;

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION tagg.render_agent_config IS
    'Generates the complete opencode agent .md file content for a given agent. Combines descr, opencode_config (YAML frontmatter), and prompt (body). Returns NULL if the agent has no config or prompt.';

-- ---------------------------------------------------------------------------
-- 4. list_agent_configs() — render all agent configs as a table
-- ---------------------------------------------------------------------------
-- Useful for debugging: shows agent name and the first 80 chars of config.

CREATE OR REPLACE FUNCTION tagg.list_agent_configs()
 RETURNS TABLE(name text, config_preview text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
    RETURN QUERY
    SELECT u.name, left(tagg.render_agent_config(u.id), 80)
    FROM tagg.user u
    WHERE u.is_agent = true AND u.is_active = true
      AND u.opencode_config IS NOT NULL
      AND u.prompt IS NOT NULL
    ORDER BY u.name;
END;
$function$;

RESET search_path;
