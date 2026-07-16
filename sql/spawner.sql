-- ============================================================================
-- Legacy Unsupported Agent Spawner (plpython3u)
-- ============================================================================
-- AFTER INSERT trigger on agent_task.  Reads the assigned agent's command
-- from tagg.user, checks max_concurrent, and spawns the agent process via
-- subprocess.Popen. This is retained for historical reference only. It is not
-- bootstrapped and is removed by conversation_gateway.sql; use db_supervisor.py.
-- ============================================================================

SET search_path TO tagg, pg_catalog, pg_temp;

CREATE OR REPLACE FUNCTION tagg.spawn_agent_on_insert()
 RETURNS trigger
 LANGUAGE plpython3u
 SECURITY DEFINER
 SET search_path TO 'tagg', 'pg_catalog', 'pg_temp'
AS $function$
    # Only spawn when a task is created as 'pending'
    if TD['new']['task_status_id'] != 1:
        return None

    to_user_id = TD['new']['to_user_id']

    # Read the agent's command and concurrency limit
    rv = plpy.execute(
        "SELECT command, max_concurrent FROM tagg.user "
        "WHERE id = $1 AND is_active = true AND command IS NOT NULL",
        [to_user_id]
    )
    if not rv:
        return None  # agent has no command configured; nothing to spawn

    command = rv[0]['command']
    max_concurrent = rv[0]['max_concurrent']

    # Count how many tasks this agent already has in-flight (claimed or in_progress)
    count = plpy.execute(
        "SELECT count(*)::int AS cnt FROM tagg.agent_task "
        "WHERE to_user_id = $1 AND task_status_id IN (2, 3)",
        [to_user_id]
    )[0]['cnt']

    if count >= max_concurrent:
        return None  # at capacity; task stays pending

    # Spawn the agent process
    import subprocess, os
    env = os.environ.copy()
    env['TASK_ID'] = str(TD['new']['id'])
    env['AGENT_USER_ID'] = str(to_user_id)

    try:
        subprocess.Popen(
            command,
            shell=True,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        plpy.info(f"spawned agent {to_user_id} for task {TD['new']['id']}: {command}")
    except Exception as e:
        plpy.warning(f"failed to spawn agent {to_user_id} for task {TD['new']['id']}: {e}")

    return None
$function$;

COMMENT ON FUNCTION tagg.spawn_agent_on_insert IS
    'Legacy unsupported plpython3u spawner. The supported launcher is supervisor/db_supervisor.py.';

DROP TRIGGER IF EXISTS spawn_agent_on_insert ON tagg.agent_task;

CREATE TRIGGER spawn_agent_on_insert
    AFTER INSERT ON tagg.agent_task
    FOR EACH ROW
    WHEN (NEW.task_status_id = 1)
    EXECUTE FUNCTION tagg.spawn_agent_on_insert();

COMMENT ON TRIGGER spawn_agent_on_insert ON tagg.agent_task IS
    'Legacy unsupported trigger; do not install in the supported deployment.';

RESET search_path;
