import os
import uuid
from pathlib import Path

import psycopg
import pytest


ROOT = Path(__file__).resolve().parents[1]


def connect():
    return psycopg.connect(
        host=os.environ["PGHOST"],
        port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
        autocommit=True,
    )


@pytest.fixture
def db():
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


@pytest.fixture
def sandbox(db):
    suffix = uuid.uuid4().hex[:10]
    user_id = db.execute(
        "INSERT INTO tagg.user(name, descr, is_agent) VALUES (%s, %s, false) RETURNING id",
        (f"test-user-{suffix}", "pytest sandbox user"),
    ).fetchone()[0]
    project_id = db.execute(
        "INSERT INTO tagg.project(name, descr, created_by_id) VALUES (%s, %s, %s) RETURNING id",
        (f"test-project-{suffix}", "pytest sandbox project", user_id),
    ).fetchone()[0]
    data = {"suffix": suffix, "user_id": user_id, "project_id": project_id}
    try:
        yield data
    finally:
        db.execute(
            "DELETE FROM tagg.agent_run WHERE task_id IN (SELECT id FROM tagg.agent_task WHERE project_id = %s)",
            (project_id,),
        )
        db.execute("DELETE FROM tagg.message_agent_task_crosswalk WHERE agent_task_id IN (SELECT id FROM tagg.agent_task WHERE project_id = %s)", (project_id,))
        db.execute("DELETE FROM tagg.message WHERE conversation_id IN (SELECT id FROM tagg.conversation WHERE project_id = %s)", (project_id,))
        db.execute("DELETE FROM tagg.agent_task WHERE project_id = %s", (project_id,))
        db.execute("DELETE FROM tagg.conversation WHERE project_id = %s", (project_id,))
        db.execute("DELETE FROM tagg.user WHERE name = %s", (f"test-agent-{suffix}",))
        db.execute("DELETE FROM tagg.project WHERE id = %s", (project_id,))
        db.execute("DELETE FROM tagg.user WHERE id = %s", (user_id,))
