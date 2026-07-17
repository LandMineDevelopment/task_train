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


def test_gateway_operations_and_errors_are_audited(db, sandbox):
    coder = ids(db)["Coder"]
    task_id = create_task(db, sandbox["project_id"], coder, "audit pytest task")
    token = f"audit-{sandbox['suffix']}-abcdefghijklmnopqrstuvwxyz"
    assert db.execute("SELECT tagg.reserve_task(%s)", (task_id,)).fetchone()[0]
    start_run(db, task_id, coder, token)
    db.execute("SELECT tagg.set_agent_run_context(%s)", (token,))
    assert db.execute("SELECT tagg.claim_task(%s)", (task_id,)).fetchone()[0]["success"]
    artifact_id = db.execute(
        "SELECT tagg.artifact_add(%s, 'audit.py', 'audit output', 'code', 'print(1)')",
        (task_id,),
    ).fetchone()[0]
    operations = db.execute(
        """SELECT operation_type.name, operation_log.object_id
           FROM tagg.operation_log
           JOIN tagg.operation_type ON operation_type.id = operation_log.operation_type_id
           WHERE operation_log.object_id IN (%s, %s)""",
        (task_id, artifact_id),
    ).fetchall()
    assert ("claim", task_id) in operations
    assert ("add", artifact_id) in operations
    error_count = db.execute("SELECT count(*) FROM tagg.error_log WHERE operation = 'pytest_audit'").fetchone()[0]
    db.execute("SELECT tagg.log_error('pytest_audit', 'expected test error', 'TEST', '{}'::jsonb)")
    assert db.execute("SELECT count(*) FROM tagg.error_log WHERE operation = 'pytest_audit'").fetchone()[0] == error_count + 1


def test_worker_role_cannot_mutate_tables_but_can_use_gateway(db, sandbox):
    coder = ids(db)["Coder"]
    task_id = create_task(db, sandbox["project_id"], coder, "restricted worker pytest task")
    token = f"worker-{sandbox['suffix']}-abcdefghijklmnopqrstuvwxyz"
    start_run(db, task_id, coder, token)
    env = os.environ | {"PGUSER": "task_train_worker", "AGENT_RUN_TOKEN": token}
    denied = subprocess.run(
        ["psql", "--no-psqlrc", "-c", "UPDATE tagg.agent_task SET task_status_id = 4 WHERE id = 0"],
        env=env, text=True, capture_output=True,
    )
    assert denied.returncode != 0
    allowed = subprocess.run(
        ["psql", "--no-psqlrc", "-At", "-c", f"SELECT tagg.set_agent_run_context('{token}'); SELECT tagg.artifact_add({task_id}, 'worker.txt', 'gateway test', 'code', 'ok');"],
        env=env, text=True, capture_output=True, check=True,
    )
    assert allowed.stdout.strip().endswith(tuple("0123456789"))


def test_delegated_task_reports_progress_to_user_conversation(db, sandbox):
    identities = ids(db)
    conductor = identities["Conductor"]
    coder = identities["Coder"]
    quick_workflow = db.execute("SELECT id FROM tagg.workflow WHERE name = 'quick'").fetchone()[0]
    conversation = db.execute(
        "SELECT tagg.get_or_create_user_conductor_conversation(%s, %s, %s)",
        (sandbox["project_id"], sandbox["user_id"], conductor),
    ).fetchone()[0]
    chat_task = db.execute(
        """INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, workflow_id, conversation_id)
           VALUES (%s, %s, 'chat dispatch', %s, %s, %s) RETURNING id""",
        (sandbox["user_id"], conductor, sandbox["project_id"], quick_workflow, conversation),
    ).fetchone()[0]
    token = f"conversation-{sandbox['suffix']}-abcdefghijklmnopqrstuvwxyz"
    assert db.execute("SELECT tagg.reserve_task(%s)", (chat_task,)).fetchone()[0]
    db.execute("SELECT tagg.start_agent_run(%s, %s, %s, %s)", (chat_task, conductor, token, conversation))
    db.execute("SELECT tagg.set_agent_run_context(%s)", (token,))
    delegated_task = db.execute(
        "SELECT tagg.agent_task_add(%s, %s, 'implement feature', %s)",
        (conductor, coder, sandbox["project_id"]),
    ).fetchone()[0]
    assert db.execute("SELECT conversation_id FROM tagg.agent_task WHERE id = %s", (delegated_task,)).fetchone()[0] == conversation
    db.execute("UPDATE tagg.agent_task SET task_status_id = 3 WHERE id = %s", (delegated_task,))
    db.execute(
        """INSERT INTO tagg.artifact(agent_task_id, name, descr, artifact_type, body)
           VALUES (%s, 'implementation', 'completed work', 'code', %s)""",
        (delegated_task, "print('artifact output')"),
    )
    db.execute("UPDATE tagg.agent_task SET task_status_id = 4 WHERE id = %s", (delegated_task,))
    updates = [
        row[0] for row in db.execute(
            "SELECT message FROM tagg.message WHERE conversation_id = %s ORDER BY id", (conversation,)
        )
    ]
    assert any(f"Coder started task #{delegated_task}" in message for message in updates)
    assert any(f"Coder completed task #{delegated_task}" in message for message in updates)
    assert any("Artifact:\nprint('artifact output')" in message for message in updates)
