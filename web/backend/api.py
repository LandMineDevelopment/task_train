import os
from contextlib import contextmanager
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from psycopg.rows import dict_row


STATIC_DIR = Path(__file__).resolve().parent / "static"
app = FastAPI(title="Task Train API", docs_url="/api/docs", openapi_url="/api/openapi.json")
app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")


@contextmanager
def database():
    connection = psycopg.connect(
        host=os.environ["PGHOST"],
        port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
        row_factory=dict_row,
    )
    try:
        yield connection
    finally:
        connection.close()


@app.get("/api/health")
def health():
    with database() as connection:
        connection.execute("SELECT 1").fetchone()
    return {"status": "ok"}


@app.get("/api/conversations")
def list_conversations(kind: str = Query("user_conductor", pattern="^(user_conductor|agent_agent|task)$")):
    with database() as connection:
        rows = connection.execute(
            """
            SELECT c.id, c.title, c.kind, c.updated, p.name AS project_name,
                   owner.name AS owner_name, conductor.name AS conductor_name,
                   COALESCE(last_message.message, '') AS last_message,
                   last_message.created AS last_message_at,
                   COUNT(m.id) AS message_count
            FROM tagg.conversation c
            JOIN tagg.project p ON p.id = c.project_id
            LEFT JOIN tagg.user owner ON owner.id = c.owner_user_id
            LEFT JOIN tagg.user conductor ON conductor.id = c.conductor_user_id
            LEFT JOIN LATERAL (
                SELECT message, created FROM tagg.message
                WHERE conversation_id = c.id AND is_active
                ORDER BY id DESC LIMIT 1
            ) last_message ON true
            LEFT JOIN tagg.message m ON m.conversation_id = c.id AND m.is_active
            WHERE c.is_active AND c.kind = %s
            GROUP BY c.id, p.name, owner.name, conductor.name, last_message.message, last_message.created
            ORDER BY COALESCE(last_message.created, c.updated) DESC, c.id DESC
            """,
            (kind,),
        ).fetchall()
    return {"conversations": rows}


@app.get("/api/conversations/{conversation_id}")
def get_conversation(conversation_id: int):
    with database() as connection:
        conversation = connection.execute(
            """
            SELECT c.id, c.title, c.kind, c.created, c.updated, p.name AS project_name,
                   owner.name AS owner_name, conductor.name AS conductor_name
            FROM tagg.conversation c
            JOIN tagg.project p ON p.id = c.project_id
            LEFT JOIN tagg.user owner ON owner.id = c.owner_user_id
            LEFT JOIN tagg.user conductor ON conductor.id = c.conductor_user_id
            WHERE c.id = %s AND c.is_active
            """,
            (conversation_id,),
        ).fetchone()
        if conversation is None:
            raise HTTPException(status_code=404, detail="Conversation not found")
        messages = connection.execute(
            """
            SELECT m.id, m.message, m.role, m.status, m.created, m.metadata,
                   sender.name AS sender_name, sender.is_agent AS sender_is_agent,
                   recipient.name AS recipient_name,
                   COALESCE(
                       (SELECT jsonb_agg(x.agent_task_id ORDER BY x.agent_task_id)
                        FROM tagg.message_agent_task_crosswalk x WHERE x.message_id = m.id),
                       '[]'::jsonb
                   ) AS task_ids
            FROM tagg.message m
            JOIN tagg.user sender ON sender.id = m.from_user
            JOIN tagg.user recipient ON recipient.id = m.to_user
            WHERE m.conversation_id = %s AND m.is_active
            ORDER BY m.id
            """,
            (conversation_id,),
        ).fetchall()
    return {"conversation": conversation, "messages": messages}


@app.get("/")
def frontend():
    return FileResponse(STATIC_DIR / "index.html")
