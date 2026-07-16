-- Add fail_task.sh to Manager and Conductor tool lists

SET search_path TO tagg;

UPDATE tagg.user
SET prompt = regexp_replace(
    prompt,
    E'\\`bash tools/advance_task\\.sh \\$TASK_ID \\$AGENT_USER_ID\\`',
    '`bash tools/advance_task.sh $TASK_ID $AGENT_USER_ID` — advance to next step\n  `bash tools/fail_task.sh $TASK_ID $AGENT_USER_ID` — move back one step'
)
WHERE name = 'Manager';

UPDATE tagg.user
SET prompt = regexp_replace(
    prompt,
    E'\\`bash tools/advance_task\\.sh <task_id> \\$AGENT_USER_ID\\`',
    '`bash tools/advance_task.sh <task_id> $AGENT_USER_ID` — advance to next step\n    `bash tools/fail_task.sh <task_id> $AGENT_USER_ID` — move back one step'
)
WHERE name = 'Conductor';

RESET search_path;
