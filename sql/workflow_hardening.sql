-- Explicit role permissions and terminal task outcomes.
SET search_path TO tagg, pg_catalog, pg_temp;

UPDATE tagg.task_status SET name = 'reserved' WHERE id = 2 AND name = 'claimed';

INSERT INTO tagg.permission (name, descr) VALUES
  ('task:fail', 'Mark an assigned task as failed.'),
  ('task:cancel', 'Cancel a task.')
ON CONFLICT (name) DO NOTHING;

INSERT INTO tagg.skill (name, descr, content) VALUES
  ('testing', 'Validate work and record test results.', 'You validate assigned work, record test evidence, and report a pass or failure.'),
  ('review', 'Review work and record review findings.', 'You review assigned work, record findings, and validate or fail the task.'),
  ('research', 'Research an assigned topic and record findings.', 'You perform read-only research and save a research artifact.'),
  ('manager-runtime', 'Run orchestration tasks assigned to Manager.', 'You coordinate assigned work and report its outcome.')
ON CONFLICT (name) DO UPDATE SET descr = EXCLUDED.descr, content = EXCLUDED.content, is_active = true;

INSERT INTO tagg.user (name, descr, is_agent, prompt, command, max_concurrent)
VALUES ('Manager', 'Internal orchestration worker.', true,
  'You coordinate assigned orchestration work and explicitly complete or fail your own tasks.',
  'agent-scripts/opencode_agent.sh', 3)
ON CONFLICT (name) DO UPDATE SET is_active = true;

UPDATE tagg.user
SET opencode_config = '{"mode":"subagent","permissions":{"bash":"allow","read":"allow","edit":"deny","glob":"allow","grep":"allow","webfetch":"allow","websearch":"allow","task":"deny","todowrite":"deny","lsp":"deny","skill":"deny"}}'::jsonb
WHERE name = 'Manager' AND opencode_config IS NULL;

UPDATE tagg.skill_permission_crosswalk x SET is_active = false
FROM tagg.skill s WHERE x.skill_id = s.id
  AND s.name IN ('code-python', 'review-sql', 'filesystem', 'agent-communication', 'orchestration');

WITH grants(skill_name, permission_name) AS (VALUES
  ('code-python', 'task:claim'), ('code-python', 'artifact:create'), ('code-python', 'fs:write'), ('code-python', 'task:advance'), ('code-python', 'task:fail'),
  ('orchestration', 'task:create'), ('orchestration', 'task:assign:any'), ('orchestration', 'task:link'), ('orchestration', 'message:send'),
  ('testing', 'task:claim'), ('testing', 'artifact:create'), ('testing', 'fs:write'), ('testing', 'task:advance'), ('testing', 'task:fail'),
  ('review', 'task:claim'), ('review', 'artifact:create'), ('review', 'task:advance'), ('review', 'task:fail'),
  ('research', 'task:claim'), ('research', 'artifact:create'), ('research', 'task:advance'),
  ('manager-runtime', 'task:claim'), ('manager-runtime', 'task:advance'), ('manager-runtime', 'task:fail')
)
INSERT INTO tagg.skill_permission_crosswalk (skill_id, permission_id)
SELECT s.id, p.id FROM grants g JOIN tagg.skill s ON s.name = g.skill_name JOIN tagg.permission p ON p.name = g.permission_name
ON CONFLICT (skill_id, permission_id) DO UPDATE SET is_active = true;

UPDATE tagg.skill_user_crosswalk x SET is_active = false
FROM tagg.user u WHERE x.user_id = u.id AND u.name IN ('Conductor', 'Coder', 'Tester', 'Explorer', 'Reviewer', 'Manager');
WITH assignments(user_name, skill_name) AS (VALUES
  ('Conductor', 'orchestration'), ('Coder', 'code-python'), ('Tester', 'testing'),
  ('Explorer', 'research'), ('Reviewer', 'review'), ('Manager', 'orchestration'), ('Manager', 'manager-runtime')
)
INSERT INTO tagg.skill_user_crosswalk (user_id, skill_id)
SELECT u.id, s.id FROM assignments a JOIN tagg.user u ON u.name = a.user_name JOIN tagg.skill s ON s.name = a.skill_name
ON CONFLICT (skill_id, user_id) DO UPDATE SET is_active = true;

CREATE OR REPLACE FUNCTION tagg.fail_task(p_task_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
DECLARE v_agent bigint; BEGIN
  PERFORM tagg.require_permission('task:fail'); v_agent := current_setting('tagg.agent_id')::bigint;
  UPDATE tagg.agent_task SET task_status_id = 7 WHERE id = p_task_id AND to_user_id = v_agent AND task_status_id IN (2,3) AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Task % cannot be failed by this agent', p_task_id; END IF;
  RETURN 7;
END $$;

CREATE OR REPLACE FUNCTION tagg.cancel_task(p_task_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'tagg','pg_catalog','pg_temp' AS $$
BEGIN
  PERFORM tagg.require_permission('task:cancel');
  UPDATE tagg.agent_task SET task_status_id = 8 WHERE id = p_task_id AND task_status_id IN (1,2,3) AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Task % cannot be cancelled', p_task_id; END IF;
  RETURN 8;
END $$;

UPDATE tagg.user SET prompt = CASE name
  WHEN 'Conductor' THEN 'You are the Conductor. Decompose user goals into tasks, assign work to specialists, and report progress. Do not implement, test, research, or advance specialist tasks yourself.'
  WHEN 'Coder' THEN 'You implement assigned work. Save implementation artifacts and explicitly mark the assigned task completed or failed.'
  WHEN 'Tester' THEN 'You validate assigned work. Save test evidence and explicitly mark the assigned task completed or failed.'
  WHEN 'Explorer' THEN 'You research assigned topics without modifying project files. Save a research artifact and explicitly complete the assigned task.'
  WHEN 'Reviewer' THEN 'You review assigned work. Save review findings and explicitly validate or fail the assigned task.'
  WHEN 'Manager' THEN 'You coordinate assigned orchestration work and explicitly complete or fail your own tasks.'
  ELSE prompt END
WHERE name IN ('Conductor', 'Coder', 'Tester', 'Explorer', 'Reviewer', 'Manager');

RESET search_path;
