#!/usr/bin/env python3
"""Supervisor: listens for pending tasks and spawns agent subprocesses.

Portable spawner — no hardcoded paths, no plpython3u dependency.
Resolves relative commands against project_root from config.
Can run as a systemd --user service.

Before spawning, writes task instructions to a pair conversation
and passes CONVERSATION_ID to the agent.

Usage:
    python3 db_supervisor.py [-c supervisor/agents.json]
"""

import json
import os
import secrets
import signal
import subprocess
import sys
import time
from argparse import ArgumentParser
from datetime import datetime, timezone
from pathlib import Path


def open_listener(db_conf: dict):
    """Open a dedicated LISTEN connection; task state remains in PostgreSQL."""
    try:
        import psycopg
    except ImportError as exc:
        raise RuntimeError(
            "psycopg is required for PostgreSQL notifications; install requirements.txt"
        ) from exc
    kwargs = {
        "host": db_conf["host"], "port": db_conf["port"],
        "user": db_conf["user"], "dbname": db_conf["dbname"],
    }
    if "password" in db_conf:
        kwargs["password"] = db_conf["password"]
    conn = psycopg.connect(**kwargs, autocommit=True)
    conn.execute("LISTEN tagg_task_ready")
    return conn


def load_config(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def psql_query(sql: str, db_conf: dict) -> list[tuple[str, ...]]:
    cmd = [
        "psql",
        "-h", db_conf["host"],
        "-p", str(db_conf["port"]),
        "-U", db_conf["user"],
        "-d", db_conf["dbname"],
        "--no-psqlrc", "-A", "-t", "-F", "\t",
        "-c", sql,
    ]
    env = os.environ.copy()
    if "password" in db_conf:
        env["PGPASSWORD"] = db_conf["password"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env)
    if result.returncode != 0:
        print(f"psql error: {result.stderr.strip()}", file=sys.stderr)
        return []
    out = result.stdout.strip()
    if not out:
        return []
    # Use tab separator to avoid pipe-in-data issues
    return [tuple(row.split("\t")) for row in out.split("\n")]


def ensure_agents_exist(db_conf: dict, agents: list[dict]):
    for a in agents:
        safe_name = a["name"].replace("'", "''")
        rows = psql_query(
            f"SELECT id FROM tagg.user WHERE name = '{safe_name}' AND is_active = true",
            db_conf,
        )
        if rows:
            a["user_id"] = int(rows[0][0])
        else:
            safe_descr = a.get("descr", "").replace("'", "''")
            rows = psql_query(
                f"SELECT tagg.agent_add('{safe_name}', '{safe_descr}')",
                db_conf,
            )
            if rows:
                a["user_id"] = int(rows[0][0])
                print(f"  Registered agent '{a['name']}' as user_id={a['user_id']}")


def build_agent_map(agents: list[dict], project_root: str) -> dict[int, dict]:
    m = {}
    for a in agents:
        uid = a.get("user_id")
        if uid is not None:
            cmd = a["command"]
            if not os.path.isabs(cmd):
                cmd = os.path.join(project_root, cmd)
            m[uid] = {
                "name": a["name"],
                "command": cmd,
                "max_concurrent": a.get("max_concurrent", 1),
            }
    return m


def mark_timed_out(db_conf: dict, timeout_secs: int):
    """Release stale reserved or in-progress tasks back to pending."""
    psql_query(
        f"UPDATE tagg.agent_task "
        f"SET task_status_id = 1 "
        f"WHERE task_status_id IN (2, 3) AND is_active = true "
        f"  AND updated < NOW() - INTERVAL '{timeout_secs} seconds'",
        db_conf,
    )


def reserve_task(task_id: int, db_conf: dict) -> bool:
    """Atomically reserve a pending task before a child process is spawned."""
    rows = psql_query(f"SELECT tagg.reserve_task({task_id})::text", db_conf)
    return bool(rows and rows[0][0].lower() == "true")


def start_agent_run(task_id: int, agent_id: int, conversation_id: str, db_conf: dict) -> tuple[int, str]:
    """Create a single-use run identity before exposing a task to an agent."""
    token = secrets.token_urlsafe(32)
    conversation_sql = conversation_id if conversation_id.isdigit() and int(conversation_id) > 0 else "NULL"
    rows = psql_query(
        f"SELECT tagg.start_agent_run({task_id}, {agent_id}, '{token}', {conversation_sql})::text",
        db_conf,
    )
    if not rows:
        raise RuntimeError(f"could not create run for task {task_id}")
    return int(rows[0][0]), token


def finish_agent_run(run_id: int, exit_code: int, stderr: bytes, db_conf: dict):
    error = stderr.decode(errors="replace").replace("'", "''")[-4000:]
    psql_query(
        f"SELECT tagg.finish_agent_run({run_id}, {exit_code}, '{error}')",
        db_conf,
    )


def get_task_details(task_id: int, db_conf: dict) -> dict | None:
    """Fetch from_user_id, to_user_id, task text, and project_id for a task."""
    rows = psql_query(
        f"SELECT row_to_json(t)::text FROM ("
        f"  SELECT from_user_id, to_user_id, task, project_id"
        f"  FROM tagg.agent_task WHERE id = {task_id} AND is_active = true"
        f") t",
        db_conf,
    )
    if not rows:
        return None
    import json
    data = json.loads(rows[0][0])
    return {
        "from_user_id": data["from_user_id"],
        "to_user_id": data["to_user_id"],
        "task_text": data["task"],
        "project_id": data["project_id"],
    }


def send_instruction(
    db_conf: dict,
    project_root: str,
    from_user_id: int,
    to_user_id: int,
    task_id: int,
    project_id: int,
    message: str,
) -> str | None:
    """Write an instruction message to the pair conversation, returns conversation_id."""
    script = os.path.join(project_root, "tools", "send_instruction.sh")
    # Escape single quotes for shell safety
    safe_msg = message.replace("'", "'\\''")
    cmd = [
        "bash",
        script,
        str(from_user_id),
        str(to_user_id),
        str(task_id),
        str(project_id),
        safe_msg,
    ]
    env = os.environ.copy()
    for k in ("PGHOST", "PGPORT", "PGUSER", "PGDATABASE"):
        if k in db_conf:
            env[k] = str(db_conf[k])
        elif k in os.environ:
            pass  # already set
    if "password" in db_conf:
        env["PGPASSWORD"] = db_conf["password"]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=env)
    if result.returncode != 0:
        print(f"  [send_instruction] error: {result.stderr.strip()}", file=sys.stderr)
        return None
    try:
        data = json.loads(result.stdout.strip())
        return str(data.get("conversation_id"))
    except (json.JSONDecodeError, TypeError):
        print(f"  [send_instruction] bad response: {result.stdout.strip()}")
        return None


def main():
    ap = ArgumentParser(description="DB Agent Supervisor (stdlib + psql)")
    ap.add_argument("-c", "--config", default="agents.json")
    ap.add_argument("--cwd", default=None)
    args = ap.parse_args()

    script_dir = Path(__file__).resolve().parent
    raw = args.config
    if not os.path.isabs(raw):
        candidate = os.path.join(script_dir, raw)
        if os.path.exists(candidate):
            config_path = candidate
        else:
            config_path = os.path.abspath(raw)
    else:
        config_path = raw

    cwd = args.cwd or Path(config_path).resolve().parent
    config = load_config(config_path)

    pr = config.get("project_root", ".")
    project_root = os.path.join(cwd, pr) if not os.path.isabs(pr) else pr
    project_root = os.path.abspath(project_root)

    agents = config["agents"]
    db_conf = config["db"]
    s_conf = config.get("supervisor", {})

    reconcile_interval = s_conf.get("reconcile_interval", 60.0)
    max_total = s_conf.get("max_total_processes", 10)
    task_timeout = s_conf.get("task_timeout", 300)

    print(f"[supervisor] project_root={project_root}")
    print(f"[supervisor] connecting to {db_conf['dbname']}@{db_conf['host']}:{db_conf['port']} ...")

    if not psql_query("SELECT 1", db_conf):
        print("[supervisor] ERROR: cannot reach DB", file=sys.stderr)
        sys.exit(1)
    try:
        listener = open_listener(db_conf)
    except RuntimeError as exc:
        print(f"[supervisor] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    print("[supervisor] ensuring agents exist in DB...")
    ensure_agents_exist(db_conf, agents)
    agent_map = build_agent_map(agents, project_root)
    sync_script = os.path.join(project_root, "sync_agents.sh")
    if os.path.exists(sync_script):
        subprocess.run(["bash", sync_script], cwd=project_root, capture_output=True, timeout=30)
        print(f"[supervisor] synced agent configs from DB")

    print(f"[supervisor] watching {len(agent_map)} agents: {', '.join(a['name'] for a in agents)}")

    for uid, info in agent_map.items():
        print(f"  {info['name']}: uid={uid} cmd={info['command']} max_concurrent={info['max_concurrent']}")

    processes: dict[int, dict] = {}
    agent_counts: dict[int, int] = {uid: 0 for uid in agent_map}
    running = True

    def handle_signal(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    last_recovery = 0.0
    last_reconcile = 0.0
    scan_pending = True

    while running:
        now = time.monotonic()

        # Reap finished children
        dead_pids = []
        for pid, info in list(processes.items()):
            proc = info["proc"]
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                finish_agent_run(info["run_id"], proc.returncode, stderr, db_conf)
                status = "OK" if proc.returncode == 0 else f"FAIL (rc={proc.returncode})"
                print(f"  [done] pid={pid} task={info['task_id']} {status}")
                if stderr and stderr.strip():
                    for line in stderr.decode().strip().split("\n"):
                        print(f"    stderr: {line}")
                agent_counts[info["agent_uid"]] = max(
                    agent_counts.get(info["agent_uid"], 1) - 1, 0
                )
                dead_pids.append(pid)
        for pid in dead_pids:
            del processes[pid]

        # Periodically recover stalled tasks
        if now - last_recovery >= 60:
            last_recovery = now
            mark_timed_out(db_conf, task_timeout)
            print(f"  [recovery] checked for tasks stalled >{task_timeout}s")

        # Notifications provide low-latency wakeups. Reconciliation handles
        # notifications missed while the supervisor was offline.
        if now - last_reconcile >= reconcile_interval:
            last_reconcile = now
            scan_pending = True
        if scan_pending:
            scan_pending = False
            rows = psql_query(
                "SELECT id::text, to_user_id::text "
                "FROM tagg.agent_task "
                "WHERE task_status_id = 1 AND is_active = true "
                "ORDER BY id LIMIT 20",
                db_conf,
            )
            for task_id_str, uid_str in rows:
                task_id = int(task_id_str)
                uid = int(uid_str)
                if uid not in agent_map:
                    print(f"  [scan] task={task_id} skipped: unknown agent={uid}")
                    continue
                if len(processes) >= max_total:
                    break
                if agent_counts.get(uid, 0) >= agent_map[uid]["max_concurrent"]:
                    continue

                if not reserve_task(task_id, db_conf):
                    print(f"  [scan] task={task_id} skipped: reservation lost")
                    continue
                agent = agent_map[uid]

                # Get task details and write instruction to conversation
                details = get_task_details(task_id, db_conf)
                if details is None:
                    print(f"  [spawn] task={task_id} skipped: details unavailable")
                    continue

                instruction = (
                    f"Task #{task_id} assigned to you ({agent['name']}).\n\n"
                    f"From: user #{details['from_user_id']}\n"
                    f"To: {agent['name']} (id={uid})\n\n"
                    f"Instructions:\n{details['task_text']}"
                )

                conv_id = send_instruction(
                    db_conf,
                    project_root,
                    details["from_user_id"],
                    uid,
                    task_id,
                    details["project_id"],
                    instruction,
                )

                if conv_id is None:
                    print(f"  [spawn] WARNING: no conversation for task {task_id}, spawning without it")
                    conv_id = "0"

                try:
                    run_id, run_token = start_agent_run(task_id, uid, conv_id, db_conf)
                except RuntimeError as exc:
                    print(f"  [spawn] {exc}", file=sys.stderr)
                    continue

                env = os.environ.copy()
                env["TASK_ID"] = str(task_id)
                env["AGENT_USER_ID"] = str(uid)
                env["CONVERSATION_ID"] = conv_id
                env["AGENT_RUN_TOKEN"] = run_token
                env["PGHOST"] = db_conf["host"]
                env["PGPORT"] = str(db_conf["port"])
                env["PGDATABASE"] = db_conf["dbname"]
                env["PGUSER"] = db_conf["user"]
                env["PROJECT_ROOT"] = project_root
                if "password" in db_conf:
                    env["PGPASSWORD"] = db_conf["password"]

                proc = subprocess.Popen(
                    [agent["command"]],
                    cwd=project_root,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                processes[proc.pid] = {
                    "proc": proc,
                    "task_id": task_id,
                    "agent_uid": uid,
                    "run_id": run_id,
                }
                agent_counts[uid] = agent_counts.get(uid, 0) + 1
                print(
                    f"  [spawn] {agent['name']} pid={proc.pid} task={task_id} conv={conv_id} "
                    f"(running={len(processes)}, {agent['name']} count={agent_counts[uid]})"
                )

        try:
            notification = next(listener.notifies(timeout=0.5), None)
            if notification is not None:
                print(f"  [notify] task={notification.payload}")
                scan_pending = True
        except Exception as exc:
            print(f"[supervisor] LISTEN connection failed: {exc}; reconnecting", file=sys.stderr)
            try:
                listener.close()
                listener = open_listener(db_conf)
                scan_pending = True
            except Exception as reconnect_error:
                print(f"[supervisor] LISTEN reconnect failed: {reconnect_error}", file=sys.stderr)
                time.sleep(5)

    # Shutdown
    print("\n[supervisor] terminating agent processes...")
    listener.close()
    for pid, info in processes.items():
        proc = info["proc"]
        if proc.poll() is None:
            proc.terminate()
    for pid, info in list(processes.items()):
        proc = info["proc"]
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    print("[supervisor] all agents terminated. Goodbye.")


if __name__ == "__main__":
    main()
