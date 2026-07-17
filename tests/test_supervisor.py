import json
import os
import select
import stat
import subprocess
import time

from conftest import ROOT


def test_supervisor_reserves_notified_task_and_passes_run_context(db, sandbox, tmp_path):
    workflow_id = db.execute("SELECT id FROM tagg.workflow WHERE name = 'standard'").fetchone()[0]
    marker = tmp_path / "worker-env.txt"
    worker = tmp_path / "fake-worker.sh"
    worker.write_text(f"#!/usr/bin/env bash\nenv | sort > {marker}\n")
    worker.chmod(worker.stat().st_mode | stat.S_IXUSR)
    agent_name = f"test-agent-{sandbox['suffix']}"
    agent_id = db.execute(
        """INSERT INTO tagg.user(name, descr, is_agent, prompt, command, max_concurrent)
           VALUES (%s, 'pytest supervisor agent', true, 'test agent', %s, 1) RETURNING id""",
        (agent_name, str(worker)),
    ).fetchone()[0]
    task_id = db.execute(
        """INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, workflow_id)
           VALUES (%s, %s, 'supervisor pytest task', %s, %s) RETURNING id""",
        (agent_id, agent_id, sandbox["project_id"], workflow_id),
    ).fetchone()[0]
    assert db.execute("SELECT task_status_id FROM tagg.agent_task WHERE id = %s", (task_id,)).fetchone()[0] == 1
    config = tmp_path / "supervisor.json"
    config.write_text(json.dumps({
        "project_root": str(ROOT),
        "agents": [{"name": agent_name, "command": str(worker), "max_concurrent": 1}],
        "db": {
            "host": os.environ["PGHOST"], "port": int(os.environ["PGPORT"]),
            "dbname": os.environ["PGDATABASE"], "user": os.environ["PGUSER"],
            "password": os.environ["PGPASSWORD"],
        },
        "supervisor": {"max_total_processes": 1, "reconcile_interval": 60, "task_timeout": 300},
    }))
    process = subprocess.Popen(
        ["python3", "-u", "supervisor/db_supervisor.py", "-c", str(config)],
        cwd=ROOT, env=os.environ.copy(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        output = []
        deadline = time.monotonic() + 15
        ready = False
        while time.monotonic() < deadline:
            readable, _, _ = select.select([process.stdout], [], [], 0.2)
            if readable:
                line = process.stdout.readline()
                output.append(line)
                if "watching" in line:
                    ready = True
                    break
        assert ready, f"supervisor did not initialize\n{''.join(output)}"
        deadline = time.monotonic() + 12
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not marker.exists():
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            raise AssertionError(f"supervisor did not spawn the fake worker\nstdout:\n{''.join(output)}{stdout}\nstderr:\n{stderr}")
        values = dict(line.split("=", 1) for line in marker.read_text().splitlines() if "=" in line)
        assert values["TASK_ID"] == str(task_id)
        assert values["AGENT_USER_ID"] == str(agent_id)
        assert values["AGENT_RUN_TOKEN"]
        deadline = time.monotonic() + 5
        run = None
        while time.monotonic() < deadline:
            run = db.execute("SELECT status, exit_code FROM tagg.agent_run WHERE task_id = %s", (task_id,)).fetchone()
            if run and run[0] == "completed":
                break
            time.sleep(0.2)
        assert run == ("completed", 0)
        assert db.execute("SELECT task_status_id FROM tagg.agent_task WHERE id = %s", (task_id,)).fetchone()[0] == 2
    finally:
        process.terminate()
        process.wait(timeout=5)
