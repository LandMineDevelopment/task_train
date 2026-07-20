-- Slice 1: API Integration Test
-- Tests full create/read/update/archive lifecycle for all domain objects.
-- Simulates JWT context via app.current_user_id.

begin;
do $$
declare
    v_user_id uuid := gen_random_uuid();
    v_project_id uuid;
    v_project2_id uuid;
    v_tag_id uuid;
    v_assignment_id uuid;
    v_rel_id uuid;
    v_object_id uuid;
    v_user_obj_id uuid;
    v_member_id uuid;
    v_revision bigint;
    v_rec record;
begin
    -- Bootstrap: create a user manually
    insert into identity.users (id, display_name, email_display, status)
    values (v_user_id, 'Test User', 'test@example.com', 'active');
    insert into identity.auth_identities (user_id, issuer, subject)
    values (v_user_id, 'test-issuer', v_user_id::text);
    perform set_config('app.current_user_id', v_user_id::text, true);

    -- create_project
    select project_id into strict v_project_id
    from app_api_v1.create_project('Test Project', 'test-project-' || v_user_id::text, 'A test project', 'personal') t;
    assert v_project_id is not null, 'create_project should return a project_id';

    -- Verify project + ownership
    assert (select count(*) = 1 from project.projects where id = v_project_id), 'Project should exist';
    assert exists (select 1 from project.project_memberships where project_id = v_project_id and user_id = v_user_id and role = 'owner'),
        'Owner membership should exist';

    -- get_project
    assert exists (select 1 from app_api_v1.get_project(v_project_id) where name = 'Test Project'),
        'get_project should return project details';

    -- update_project
    select revision into v_revision from project.projects where id = v_project_id;
    perform app_api_v1.update_project(v_project_id, v_revision, 'Updated Project');
    assert (select name from project.projects where id = v_project_id) = 'Updated Project', 'Project name should be updated';

    -- create_tag
    select tag_id into v_tag_id
    from app_api_v1.create_tag(v_project_id, 'test-ns', 'test-tag', 'none') t;
    assert v_tag_id is not null, 'create_tag should return a tag_id';
    assert exists (select 1 from taxonomy.tags where id = v_tag_id and slug = 'test-tag'), 'Tag should exist';

    -- update_tag
    select revision into v_revision from taxonomy.tags where id = v_tag_id;
    perform app_api_v1.update_tag(v_tag_id, v_revision, 'updated-tag');
    assert (select name from taxonomy.tags where id = v_tag_id) = 'updated-tag', 'Tag name should be updated';

    -- register_object via internal helper
    v_object_id := internal_api.register_object(v_project_id, 'task', 'My Task', v_user_id);
    assert v_object_id is not null, 'register_object should return a UUID';

    -- assign_tag_to_object
    select assignment_id into v_assignment_id
    from app_api_v1.assign_tag_to_object(v_project_id, v_object_id, v_tag_id, null, null, null, null, 'human') t;
    assert v_assignment_id is not null, 'assign_tag_to_object should return an assignment_id';
    assert exists (select 1 from taxonomy.tag_assignments where id = v_assignment_id and status = 'active'),
        'Tag assignment should exist with status active';

    -- create_relationship (needs both objects registered)
    v_user_obj_id := internal_api.register_object(v_project_id, 'user', 'Target User', v_user_id);
    select relationship_id into v_rel_id
    from app_api_v1.create_relationship(v_project_id, v_object_id, 'assigned_to', v_user_obj_id) t;
    assert v_rel_id is not null, 'create_relationship should return a relationship_id';
    assert exists (select 1 from taxonomy.object_relationships where id = v_rel_id and status = 'active'),
        'Relationship should exist with status active';

    -- remove_tag_assignment
    perform app_api_v1.remove_tag_assignment(v_assignment_id, 'Test removal');
    assert (select status from taxonomy.tag_assignments where id = v_assignment_id) = 'removed',
        'Tag assignment should be removed';

    -- remove_relationship
    perform app_api_v1.remove_relationship(v_rel_id, 'Test removal');
    assert (select status from taxonomy.object_relationships where id = v_rel_id) = 'removed',
        'Relationship should be removed';

    -- list_projects
    assert exists (select 1 from app_api_v1.list_projects() where id = v_project_id),
        'list_projects should include the project';

    -- add_project_member
    select project_id into v_project2_id
    from app_api_v1.create_project('Project 2', 'project-2-' || v_user_id::text, 'A second project', 'shared') t;

    v_member_id := gen_random_uuid();
    insert into identity.users (id, display_name, status) values (v_member_id, 'Member User', 'active');

    perform app_api_v1.add_project_member(v_project2_id, v_member_id, 'member');
    assert exists (select 1 from project.project_memberships where project_id = v_project2_id and user_id = v_member_id and role = 'member'),
        'Membership should exist';

    -- remove_project_member
    perform app_api_v1.remove_project_member(v_project2_id, v_member_id);
    assert exists (select 1 from project.project_memberships where project_id = v_project2_id and user_id = v_member_id and status = 'disabled'),
        'Member should be disabled';

    -- last-owner protection
    begin
        perform app_api_v1.remove_project_member(v_project_id, v_user_id);
        assert false, 'Should not be able to remove last owner';
    exception when others then
        -- expected
    end;

    raise notice 'All API integration tests passed!';
end $$;
rollback;
