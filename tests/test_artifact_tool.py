import os
import subprocess

from conftest import ROOT


def test_artifact_runner_executes_in_and_cleans_temporary_workspace(db, sandbox, tmp_path):
    coder = db.execute("SELECT id FROM tagg.user WHERE name = 'Coder'").fetchone()[0]
    workflow = db.execute("SELECT id FROM tagg.workflow WHERE name = 'quick'").fetchone()[0]
    task_id = db.execute(
        """INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, workflow_id)
           VALUES (%s, %s, 'artifact runner test', %s, %s) RETURNING id""",
        (coder, coder, sandbox["project_id"], workflow),
    ).fetchone()[0]
    artifact_id = db.execute(
        """INSERT INTO tagg.artifact(agent_task_id, name, descr, artifact_type, body)
           VALUES (%s, 'hello.py', 'temporary execution test', 'code', %s) RETURNING id""",
        (task_id, "print('artifact hello')"),
    ).fetchone()[0]
    result = subprocess.run(
        ["bash", "tools/test_artifact.sh", str(artifact_id), "hello.py", "python3", "hello.py"],
        cwd=ROOT,
        env=os.environ | {"TMPDIR": str(tmp_path)},
        text=True,
        capture_output=True,
        check=True,
    )
    assert "artifact hello" in result.stdout
    assert f"artifact_id={artifact_id} exit_code=0" in result.stdout
    assert list(tmp_path.glob("task-train-artifact.*")) == []
