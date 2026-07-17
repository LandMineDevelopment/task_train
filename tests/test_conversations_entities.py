import uuid

import psycopg


def test_conversation_context_is_ordered(db, sandbox):
    conductor = db.execute("SELECT id FROM tagg.user WHERE name = 'Conductor'").fetchone()[0]
    conversation = db.execute(
        "SELECT tagg.get_or_create_user_conductor_conversation(%s, %s, %s)",
        (sandbox["project_id"], sandbox["user_id"], conductor),
    ).fetchone()[0]
    first_id = db.execute("SELECT tagg.append_conversation_message(%s, %s, %s, 'first', 'user')", (conversation, sandbox["user_id"], conductor)).fetchone()[0]
    second_id = db.execute("SELECT tagg.append_conversation_message(%s, %s, %s, 'second', 'assistant')", (conversation, conductor, sandbox["user_id"])).fetchone()[0]
    messages = db.execute("SELECT id, parent_id, seq_num FROM tagg.message WHERE conversation_id = %s ORDER BY seq_num", (conversation,)).fetchall()
    assert messages == [(first_id, None, 1), (second_id, first_id, 2)]
    context = db.execute("SELECT tagg.get_conversation_context(%s, 2)", (conversation,)).fetchone()[0]
    assert context.index("first") < context.index("second")


def test_tag_crosswalk_prevents_duplicates(db):
    suffix = uuid.uuid4().hex[:10]
    tag_id = db.execute("INSERT INTO tagg.tag(name, descr) VALUES (%s, 'pytest tag') RETURNING id", (f"tag-{suffix}",)).fetchone()[0]
    note_id = db.execute("INSERT INTO tagg.note(name, descr, body) VALUES (%s, 'pytest note', 'body') RETURNING id", (f"note-{suffix}",)).fetchone()[0]
    try:
        db.execute("INSERT INTO tagg.tag_note_crosswalk(tag_id, note_id) VALUES (%s, %s)", (tag_id, note_id))
        try:
            db.execute("INSERT INTO tagg.tag_note_crosswalk(tag_id, note_id) VALUES (%s, %s)", (tag_id, note_id))
        except psycopg.errors.UniqueViolation:
            pass
        else:
            raise AssertionError("duplicate tag assignment succeeded")
    finally:
        db.execute("DELETE FROM tagg.tag_note_crosswalk WHERE tag_id = %s", (tag_id,))
        db.execute("DELETE FROM tagg.note WHERE id = %s", (note_id,))
        db.execute("DELETE FROM tagg.tag WHERE id = %s", (tag_id,))
