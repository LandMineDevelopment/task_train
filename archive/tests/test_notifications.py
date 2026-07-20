import os

import psycopg


def test_task_insert_emits_ready_notification(db, sandbox):
    kwargs = {
        "host": os.environ["PGHOST"], "port": os.environ["PGPORT"],
        "dbname": os.environ["PGDATABASE"], "user": os.environ["PGUSER"],
        "password": os.environ["PGPASSWORD"], "autocommit": True,
    }
    listener = psycopg.connect(**kwargs)
    try:
        listener.execute("LISTEN tagg_task_ready")
        coder_id = db.execute("SELECT id FROM tagg.user WHERE name = 'Coder'").fetchone()[0]
        workflow_id = db.execute("SELECT id FROM tagg.workflow WHERE name = 'standard'").fetchone()[0]
        task_id = db.execute(
            """INSERT INTO tagg.agent_task(from_user_id, to_user_id, task, project_id, workflow_id)
               VALUES (%s, %s, 'notification pytest task', %s, %s) RETURNING id""",
            (coder_id, coder_id, sandbox["project_id"], workflow_id),
        ).fetchone()[0]
        notification = next(listener.notifies(timeout=3), None)
        assert notification is not None
        assert notification.payload == str(task_id)
    finally:
        listener.close()
