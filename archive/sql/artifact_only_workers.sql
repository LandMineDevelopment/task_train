-- Coder records implementation output as database artifacts, not project files.
SET search_path TO tagg, pg_catalog, pg_temp;
SELECT pg_advisory_lock(742019);

UPDATE tagg.user
SET opencode_config = jsonb_set(opencode_config, '{permissions,edit}', '"deny"'::jsonb)
WHERE name IN ('Coder', 'Tester') AND is_active = true;

UPDATE tagg.skill
SET descr = 'Produce implementation artifacts without editing the workspace.',
    content = 'You implement assigned work as an artifact using bash tools/create_artifact.sh. Do not create, edit, delete, or otherwise modify files in the project workspace. Include the complete implementation and any usage notes in the artifact body, then advance or fail your assigned task.'
WHERE name = 'code-python';

UPDATE tagg.skill
SET descr = 'Execute code artifacts in disposable temporary workspaces.',
    content = 'Validate code artifacts with bash tools/test_artifact.sh. The tool materializes an artifact only in a unique temporary directory and removes it automatically. Do not create, edit, delete, or otherwise modify files in the project workspace. Save the command, stdout/stderr, and pass/fail result as a test artifact. When validation fails, record actionable feedback for Coder in the test artifact.'
WHERE name = 'testing';

UPDATE tagg.user
SET prompt = 'You validate implementation artifacts in disposable temporary workspaces. Save test evidence as an artifact, report actionable feedback for Coder on failure, and explicitly mark the assigned task completed or failed.'
WHERE name = 'Tester' AND is_active = true;

UPDATE tagg.skill_permission_crosswalk x
SET is_active = false
FROM tagg.skill s
JOIN tagg.permission p ON p.name = 'fs:write'
WHERE x.skill_id = s.id AND x.permission_id = p.id AND s.name = 'code-python';

UPDATE tagg.skill_permission_crosswalk x
SET is_active = false
FROM tagg.skill s
JOIN tagg.permission p ON p.name = 'fs:write'
WHERE x.skill_id = s.id AND x.permission_id = p.id AND s.name = 'testing';

SELECT pg_advisory_unlock(742019);
RESET search_path;
