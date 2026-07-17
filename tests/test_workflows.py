import json
import os
import subprocess

from conftest import ROOT


def ids(db):
    return dict(db.execute("SELECT name, id FROM tagg.user WHERE name IN ('Coder', 'Conductor')"))


def create_task(db, project_id, assignee_id, text):
    workflow_id = db.execute("SELECT id FROM tagg.workflow WHERE name = 'standard'").fetchone()[0]
    return db.execute(
        """INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, workflow_id)
           VALUES (%s, %s, %s, %s, %s) RETURNING id""",
        (assignee_id, assignee_id, text, project_id, workflow_id),
    ).fetchone()[0]


def start_run(db, task_id, agent_id, token):
    return db.execute("SELECT tagg.start_agent_run(%s, %s, %s)", (task_id, agent_id, token)).fetchone()[0]


def test_reserve_claim_and_fail_are_owner_scoped(db, sandbox):
    coder = ids(db)["Coder"]
    task_id = create_task(db, sandbox["project_id"], coder, "workflow pytest task")
    assert db.execute("SELECT tagg.reserve_task(%s)", (task_id,)).fetchone()[0]
    assert not db.execute("SELECT tagg.reserve_task(%s)", (task_id,)).fetchone()[0]
    token = f"token-{sandbox['suffix']}-abcdefghijklmnopqrstuvwxyz"
    start_run(db, task_id, coder, token)
    db.execute("SELECT tagg.set_agent_run_context(%s)", (token,))
    claimed = db.execute("SELECT tagg.claim_task(%s)", (task_id,)).fetchone()[0]
    assert claimed["success"] is True
    assert claimed["task"]["task_status_id"] == 3
    assert db.execute("SELECT tagg.fail_task(%s)", (task_id,)).fetchone()[0] == 7
    assert db.execute("SELECT task_status_id FROM tagg.agent_task WHERE id = %s", (task_id,)).fetchone()[0] == 7


def test_claim_tool_emits_exactly_one_json_document(db, sandbox):
    coder = ids(db)["Coder"]
    task_id = create_task(db, sandbox["project_id"], coder, "claim wrapper pytest task")
    token = f"tool-{sandbox['suffix']}-abcdefghijklmnopqrstuvwxyz"
    start_run(db, task_id, coder, token)
    env = os.environ | {"AGENT_RUN_TOKEN": token}
    result = subprocess.run(
        ["bash", "tools/claim_task.sh", str(task_id), str(coder)],
        cwd=ROOT, env=env, text=True, capture_output=True, check=True,
    )
    payload = json.loads(result.stdout)
    assert payload["success"] is True
