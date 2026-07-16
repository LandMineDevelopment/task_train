-- ============================================================================
-- Agent Roles: deactivate old agents, create role-based agents
-- ============================================================================

SET search_path TO tagg, pg_catalog, pg_temp;

-- ------------------------------------------------------------------------
-- 1. Deactivate old generic agents
-- ------------------------------------------------------------------------
UPDATE tagg.user
SET is_active = false
WHERE name IN ('Agent-Alpha', 'Agent-Beta', 'Agent-Gamma', 'Child-Agent');

-- ------------------------------------------------------------------------
-- 2. Create orchestration skill
-- ------------------------------------------------------------------------
INSERT INTO tagg.skill (name, descr, content)
VALUES (
    'orchestration',
    'Ability to decompose goals into tasks, delegate work to any agent, and monitor progress.',
    'You are an orchestrator. You break high-level goals into concrete, sequential tasks. You delegate tasks to the right agent by creating agent_task records with appropriate to_user_id. You do not write code or perform tests yourself — you coordinate. Track each subtask and only advance the parent task when all subtasks complete.'
);

-- Grant orchestration skill its permissions
INSERT INTO tagg.skill_permission_crosswalk (skill_id, permission_id)
SELECT s.id, p.id
FROM tagg.skill s, tagg.permission p
WHERE s.name = 'orchestration'
  AND p.name IN ('task:create', 'task:assign:any', 'task:advance', 'task:link', 'message:send', 'artifact:create');

-- ------------------------------------------------------------------------
-- 3. Create role agents
-- ------------------------------------------------------------------------

-- Conductor
INSERT INTO tagg.user (name, descr, is_agent, prompt, command, max_concurrent)
VALUES (
    'Conductor',
    'Technical lead / orchestrator. Receives goals, decomposes into tasks, delegates to the right agent, tracks progress.',
    true,
    'You are a technical lead and orchestrator. You receive high-level goals from users or other agents. Your job is to:
1. Analyze the goal and break it into concrete, actionable tasks
2. Assign each task to the right agent (Coder, Tester, Explorer, Reviewer) via agent_task_add
3. Monitor task completion through the workflow status
4. Report progress and results back

You do NOT write code, run tests, or do research yourself. You coordinate and delegate.',
    '/home/kasey/projects/postgres/agent-scripts/opencode_agent.sh',
    3
);

-- Coder
INSERT INTO tagg.user (name, descr, is_agent, prompt, command, max_concurrent)
VALUES (
    'Coder',
    'Implements features and fixes bugs. Writes production-quality code.',
    true,
    'You are a software engineer. You implement features and fix bugs. You:
1. Read task details to understand what needs to be built
2. Explore the codebase to find relevant files using filesystem tools
3. Write clean, well-structured code following project conventions
4. Save your work output as artifacts
5. Advance the workflow when complete

You can create subtasks for yourself if the work needs to be broken into steps.',
    '/home/kasey/projects/postgres/agent-scripts/opencode_agent.sh',
    2
);

-- Tester
INSERT INTO tagg.user (name, descr, is_agent, prompt, command, max_concurrent)
VALUES (
    'Tester',
    'Writes and runs tests. Validates behavior. Provides QA sign-off.',
    true,
    'You are a QA engineer. You validate that implementations work correctly. You:
1. Read the task to understand what needs testing
2. Write tests (unit, integration, etc.) using project conventions
3. Run existing tests to check for regressions
4. Save test results as artifacts
5. If tests pass, advance the workflow. If they fail, create a detailed artifact with failure info.',
    '/home/kasey/projects/postgres/agent-scripts/opencode_agent.sh',
    2
);

-- Explorer
INSERT INTO tagg.user (name, descr, is_agent, prompt, command, max_concurrent)
VALUES (
    'Explorer',
    'Navigates the codebase, researches architecture, answers questions about the project.',
    true,
    'You are a codebase researcher. You navigate the project to answer questions. You:
1. Search for relevant files, patterns, and definitions
2. Read and analyze code structure
3. Summarize findings clearly
4. Save research results as artifacts

You do not modify code or create tasks.',
    '/home/kasey/projects/postgres/agent-scripts/opencode_agent.sh',
    3
);

-- Reviewer
INSERT INTO tagg.user (name, descr, is_agent, prompt, command, max_concurrent)
VALUES (
    'Reviewer',
    'Reviews code quality, security, and correctness before merge.',
    true,
    'You are a code reviewer. You ensure quality before changes are accepted. You:
1. Read the task and associated artifacts to see what was changed
2. Review for: correctness, security vulnerabilities, performance, code style, test coverage
3. Save review findings as an artifact
4. If the review passes, advance the workflow. If it fails, note what needs to change.',
    '/home/kasey/projects/postgres/agent-scripts/opencode_agent.sh',
    2
);

-- ------------------------------------------------------------------------
-- 4. Assign skills to role agents
-- ------------------------------------------------------------------------
DO $$
DECLARE
    v_agents text[][] := ARRAY[
        ['Conductor', 'orchestration,agent-communication'],
        ['Coder',     'code-python,filesystem,agent-communication'],
        ['Tester',    'review-sql,filesystem,code-python'],
        ['Explorer',  'filesystem,review-sql'],
        ['Reviewer',  'review-sql,code-python']
    ];
    v_name text;
    v_skills text;
    v_skill text;
BEGIN
    FOREACH v_name, v_skills IN SLICE 1 ARRAY v_agents
    LOOP
        FOREACH v_skill IN ARRAY string_to_array(v_skills, ',')
        LOOP
            INSERT INTO tagg.skill_user_crosswalk (skill_id, user_id)
            SELECT s.id, u.id
            FROM tagg.skill s, tagg.user u
            WHERE s.name = trim(v_skill) AND u.name = v_name;
        END LOOP;
    END LOOP;
END $$;

-- ------------------------------------------------------------------------
-- 5. List resulting agents
-- ------------------------------------------------------------------------
SELECT u.name, u.prompt, string_agg(s.name, ', ' ORDER BY s.name) AS skills
FROM tagg.user u
JOIN tagg.skill_user_crosswalk x ON x.user_id = u.id
JOIN tagg.skill s ON s.id = x.skill_id
WHERE u.is_agent = true AND u.is_active = true
GROUP BY u.name, u.prompt
ORDER BY u.name;

RESET search_path;
