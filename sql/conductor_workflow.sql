-- Database-backed Conductor workflow policy and rendered agent skills.
SET search_path TO tagg, pg_catalog, pg_temp;
SELECT pg_advisory_lock(742017);

INSERT INTO tagg.skill (name, descr, content) VALUES
  ('conductor-workflow',
   'Delegate user goals through the Task Train workflow.',
   'For every user request, work through the assigned task and its linked conversation. Decompose the goal into concrete specialist tasks and create those tasks with bash tools/create_task.sh. Assign implementation to Coder, testing to Tester, research to Explorer, and review to Reviewer as appropriate. Do not implement, test, research, or review work yourself. Report the tasks you created and their workflow status. For user-Conductor chat tasks, do not call send_message.sh or advance_task.sh: the runtime persists your final stdout reply and completes the chat dispatch task.')
ON CONFLICT (name) DO UPDATE
SET descr = EXCLUDED.descr, content = EXCLUDED.content, is_active = true;

INSERT INTO tagg.skill_user_crosswalk (user_id, skill_id)
SELECT u.id, s.id
FROM tagg.user u
JOIN tagg.skill s ON s.name = 'conductor-workflow'
WHERE u.name = 'Conductor'
ON CONFLICT (skill_id, user_id) DO UPDATE SET is_active = true;

UPDATE tagg.user
SET prompt = 'You are the Conductor, the orchestrator for Task Train. Follow your assigned skills as the operating policy. You coordinate work through the task workflow and do not perform specialist work yourself. Read the assigned task and conversation, then give the user a concise progress report grounded in the tasks you delegated.'
WHERE name = 'Conductor' AND is_active = true;

CREATE OR REPLACE FUNCTION tagg.render_agent_config(p_agent_id bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
    v_name text;
    v_descr text;
    v_prompt text;
    v_config jsonb;
    v_mode text;
    v_perms jsonb;
    v_yaml_perms text := '';
    v_skills text := '';
    v_key text;
    v_val text;
    v_result text;
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
    IF v_perms IS NOT NULL THEN
        v_yaml_perms := 'permission:';
        FOR v_key, v_val IN SELECT * FROM jsonb_each_text(v_perms) LOOP
            v_yaml_perms := v_yaml_perms || E'\n  ' || v_key || ': ' || v_val;
        END LOOP;
    END IF;

    SELECT COALESCE(string_agg(
        format('## Skill: %s\n%s', s.name, s.content), E'\n\n' ORDER BY s.name
    ), '') INTO v_skills
    FROM tagg.skill_user_crosswalk x
    JOIN tagg.skill s ON s.id = x.skill_id
    WHERE x.user_id = p_agent_id AND x.is_active AND s.is_active;

    v_result := '---' || E'\n'
             || 'description: "' || v_descr || '"' || E'\n'
             || 'mode: ' || COALESCE(v_mode, 'subagent') || E'\n'
             || v_yaml_perms || E'\n'
             || '---' || E'\n\n'
             || v_prompt
             || CASE WHEN v_skills = '' THEN '' ELSE E'\n\n' || v_skills END;
    RETURN v_result;
END;
$function$;

SELECT pg_advisory_unlock(742017);
RESET search_path;
