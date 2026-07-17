EXPECTED = {
    "Conductor": {"message:send", "task:advance", "task:assign:any", "task:claim", "task:create", "task:fail", "task:link"},
    "Coder": {"artifact:create", "fs:write", "task:advance", "task:claim", "task:fail"},
    "Tester": {"artifact:create", "fs:write", "task:advance", "task:claim", "task:fail"},
    "Explorer": {"artifact:create", "task:advance", "task:claim"},
    "Reviewer": {"artifact:create", "task:advance", "task:claim", "task:fail"},
    "Manager": {"message:send", "task:advance", "task:assign:any", "task:claim", "task:create", "task:fail", "task:link"},
}


def test_effective_role_permissions(db):
    rows = db.execute(
        """
        SELECT u.name, p.name
        FROM tagg.user u
        JOIN tagg.skill_user_crosswalk x ON x.user_id = u.id AND x.is_active
        JOIN tagg.skill_permission_crosswalk sp ON sp.skill_id = x.skill_id AND sp.is_active
        JOIN tagg.permission p ON p.id = sp.permission_id AND p.is_active
        WHERE u.name = ANY(%s)
        """,
        (list(EXPECTED),),
    )
    actual = {role: set() for role in EXPECTED}
    for role, permission in rows:
        actual[role].add(permission)
    assert actual == EXPECTED
