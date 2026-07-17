def test_supported_schema_is_present(db):
    expected = {
        "user", "project", "agent_task", "workflow", "workflow_step", "conversation",
        "message", "agent_run", "tag", "note", "file", "obj_type", "object",
        "artifact_type", "tag_project_crosswalk", "tag_artifact_crosswalk",
    }
    tables = {
        row[0]
        for row in db.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'tagg'"
        )
    }
    assert expected <= tables


def test_statuses_roles_and_notification(db):
    statuses = dict(db.execute("SELECT id, name FROM tagg.task_status"))
    assert statuses == {
        1: "pending", 2: "reserved", 3: "in_progress", 4: "completed",
        5: "tested", 6: "validated", 7: "failed", 8: "cancelled",
    }
    roles = {row[0] for row in db.execute("SELECT name FROM tagg.user WHERE is_agent AND is_active")}
    assert {"Conductor", "Coder", "Tester", "Explorer", "Reviewer", "Manager", "Admin-Agent"} <= roles
    assert db.execute("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'task_ready_notification')").fetchone()[0]


def test_conductor_workflow_policy_is_database_backed(db):
    conductor_id = db.execute("SELECT id FROM tagg.user WHERE name = 'Conductor'").fetchone()[0]
    skills = {
        row[0]
        for row in db.execute(
            """SELECT s.name FROM tagg.skill_user_crosswalk x
               JOIN tagg.skill s ON s.id = x.skill_id
               WHERE x.user_id = %s AND x.is_active AND s.is_active""",
            (conductor_id,),
        )
    }
    rendered = db.execute("SELECT tagg.render_agent_config(%s)", (conductor_id,)).fetchone()[0]
    assert "conductor-workflow" in skills
    assert "## Skill: conductor-workflow" in rendered
    assert "create_task.sh" in rendered


def test_coder_is_restricted_to_artifact_output(db):
    coder_id = db.execute("SELECT id FROM tagg.user WHERE name = 'Coder'").fetchone()[0]
    rendered = db.execute("SELECT tagg.render_agent_config(%s)", (coder_id,)).fetchone()[0]
    permissions = {
        row[0]
        for row in db.execute(
            """SELECT p.name FROM tagg.skill_user_crosswalk x
               JOIN tagg.skill_permission_crosswalk sp ON sp.skill_id = x.skill_id
               JOIN tagg.permission p ON p.id = sp.permission_id
               WHERE x.user_id = %s AND x.is_active AND sp.is_active""",
            (coder_id,),
        )
    }
    assert "edit: deny" in rendered
    assert "create_artifact.sh" in rendered
    assert "fs:write" not in permissions


def test_tester_uses_disposable_artifact_workspaces(db):
    tester_id = db.execute("SELECT id FROM tagg.user WHERE name = 'Tester'").fetchone()[0]
    rendered = db.execute("SELECT tagg.render_agent_config(%s)", (tester_id,)).fetchone()[0]
    permissions = {
        row[0]
        for row in db.execute(
            """SELECT p.name FROM tagg.skill_user_crosswalk x
               JOIN tagg.skill_permission_crosswalk sp ON sp.skill_id = x.skill_id
               JOIN tagg.permission p ON p.id = sp.permission_id
               WHERE x.user_id = %s AND x.is_active AND sp.is_active""",
            (tester_id,),
        )
    }
    assert "edit: deny" in rendered
    assert "test_artifact.sh" in rendered
    assert "fs:write" not in permissions
