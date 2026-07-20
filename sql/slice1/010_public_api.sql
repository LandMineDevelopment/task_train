-- Slice 1: Phase 9 — Public API Functions (app_api_v1)

-- 9.1 bootstrap_personal_project
create function app_api_v1.bootstrap_personal_project(
    p_display_name text,
    p_email_display text default null,
    p_project_name text default null
)
returns table (user_id uuid, project_id uuid)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_issuer text;
    v_subject text;
    v_user_id uuid;
    v_project_id uuid;
    v_project_slug text;
begin
    -- Resolve or create user
    v_issuer := internal_api.current_auth_issuer();
    v_subject := internal_api.current_auth_subject();

    if v_issuer is null or v_subject is null then
        raise exception 'AUTHENTICATION_REQUIRED: JWT claims iss and sub must be present.'
            using detail = 'AUTHENTICATION_REQUIRED';
    end if;

    select u.id into v_user_id
    from identity.users u
    inner join identity.auth_identities ai on ai.user_id = u.id
    where ai.issuer = v_issuer and ai.subject = v_subject;

    if not found then
        insert into identity.users (display_name, email_display)
        values (p_display_name, p_email_display)
        returning id into v_user_id;

        insert into identity.auth_identities (user_id, issuer, subject)
        values (v_user_id, v_issuer, v_subject);

        perform set_config('app.current_user_id', v_user_id::text, true);
    else
        perform set_config('app.current_user_id', v_user_id::text, true);
    end if;

    -- Create personal project if not exists
    select p.id into v_project_id
    from project.projects p
    where p.created_by_user_id = v_user_id and p.project_kind = 'personal';

    if not found then
        v_project_slug := internal_api.normalize_slug(coalesce(p_project_name, p_display_name));
        insert into project.projects (project_kind, name, slug, created_by_user_id, status)
        values ('personal', coalesce(p_project_name, p_display_name || '''s Project'), v_project_slug || '-' || v_user_id::text, v_user_id, 'active')
        returning id into v_project_id;

        insert into project.project_memberships (project_id, user_id, role, status, added_by_user_id)
        values (v_project_id, v_user_id, 'owner', 'active', v_user_id);
    end if;

    return query select v_user_id, v_project_id;
end;
$$;

alter function app_api_v1.bootstrap_personal_project(text, text, text) owner to app_function_owner;
revoke all on function app_api_v1.bootstrap_personal_project(text, text, text) from public;

-- 9.2 create_project
create function app_api_v1.create_project(
    p_name text,
    p_slug text default null,
    p_description text default null,
    p_project_kind text default 'personal'
)
returns table (project_id uuid, project_slug text, revision bigint)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_slug text;
    v_project_id uuid;
begin
    v_user_id := internal_api.require_authenticated_user();
    v_slug := coalesce(p_slug, internal_api.normalize_slug(p_name));

    insert into project.projects (project_kind, name, slug, description, created_by_user_id, status)
    values (p_project_kind, p_name, v_slug, p_description, v_user_id, 'active')
    returning id into v_project_id;

    insert into project.project_memberships (project_id, user_id, role, status, added_by_user_id)
    values (v_project_id, v_user_id, 'owner', 'active', v_user_id);

    return query select v_project_id, v_slug, 1::bigint;
end;
$$;

alter function app_api_v1.create_project(text, text, text, text) owner to app_function_owner;
revoke all on function app_api_v1.create_project(text, text, text, text) from public;

-- 9.3 update_project
create function app_api_v1.update_project(
    p_project_id uuid,
    p_expected_revision bigint,
    p_name text default null,
    p_description text default null
)
returns table (project_id uuid, revision bigint, updated_at timestamptz)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
begin
    v_user_id := internal_api.require_project_owner(p_project_id);

    update project.projects p
    set name = coalesce(p_name, p.name),
        description = coalesce(p_description, p.description),
        revision = p.revision + 1,
        updated_at = transaction_timestamp()
    where p.id = p_project_id
      and p.revision = p_expected_revision;

    if not found then
        if not exists (select 1 from project.projects where id = p_project_id) then
            raise exception 'PROJECT_NOT_FOUND: Project does not exist.'
                using detail = 'PROJECT_NOT_FOUND';
        else
            raise exception 'REVISION_CONFLICT: Expected revision did not match current revision.'
                using detail = 'REVISION_CONFLICT';
        end if;
    end if;

    return query select p.id, p.revision, p.updated_at
    from project.projects p where p.id = p_project_id;
end;
$$;

alter function app_api_v1.update_project(uuid, bigint, text, text) owner to app_function_owner;
revoke all on function app_api_v1.update_project(uuid, bigint, text, text) from public;

-- 9.4 get_project
create function app_api_v1.get_project(p_project_id uuid)
returns table (
    id uuid, project_kind text, name text, slug text, description text,
    created_by_user_id uuid, status text, revision bigint,
    created_at timestamptz, updated_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
begin
    perform internal_api.require_project_member(p_project_id);

    return query select p.id, p.project_kind, p.name, p.slug, p.description,
                        p.created_by_user_id, p.status, p.revision,
                        p.created_at, p.updated_at
    from project.projects p
    where p.id = p_project_id;
end;
$$;

alter function app_api_v1.get_project(uuid) owner to app_function_owner;
revoke all on function app_api_v1.get_project(uuid) from public;

-- 9.5 list_projects
create function app_api_v1.list_projects()
returns table (
    id uuid, project_kind text, name text, slug text, status text, role text,
    created_at timestamptz
)
language sql
set search_path = pg_catalog, app_api_v1
security definer
as $$
    select p.id, p.project_kind, p.name, p.slug, p.status, pm.role, p.created_at
    from project.projects p
    inner join project.project_memberships pm on pm.project_id = p.id
    where pm.user_id = internal_api.current_user_id()
      and pm.status = 'active'
    order by p.created_at desc;
$$;

alter function app_api_v1.list_projects() owner to app_function_owner;
revoke all on function app_api_v1.list_projects() from public;

-- 9.6 add_project_member
create function app_api_v1.add_project_member(
    p_project_id uuid,
    p_user_id uuid,
    p_role text default 'member'
)
returns table (membership_id uuid, role text)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_caller_id uuid;
    v_membership_id uuid;
begin
    v_caller_id := internal_api.require_project_owner(p_project_id);

    insert into project.project_memberships (project_id, user_id, role, status, added_by_user_id)
    values (p_project_id, p_user_id, p_role, 'active', v_caller_id)
    on conflict (project_id, user_id) do update
        set role = excluded.role,
            status = 'active',
            updated_at = transaction_timestamp()
    returning id into v_membership_id;

    return query select v_membership_id, p_role;
end;
$$;

alter function app_api_v1.add_project_member(uuid, uuid, text) owner to app_function_owner;
revoke all on function app_api_v1.add_project_member(uuid, uuid, text) from public;

-- 9.7 remove_project_member
create function app_api_v1.remove_project_member(
    p_project_id uuid,
    p_user_id uuid
)
returns void
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
begin
    perform internal_api.require_project_owner(p_project_id);

    update project.project_memberships
    set status = 'disabled',
        disabled_at = transaction_timestamp(),
        updated_at = transaction_timestamp()
    where project_id = p_project_id
      and user_id = p_user_id;
end;
$$;

alter function app_api_v1.remove_project_member(uuid, uuid) owner to app_function_owner;
revoke all on function app_api_v1.remove_project_member(uuid, uuid) from public;

-- 9.8 create_tag
create function app_api_v1.create_tag(
    p_project_id uuid,
    p_namespace text,
    p_name text,
    p_value_type text default 'none',
    p_description text default null
)
returns table (tag_id uuid, namespace text, slug text, revision bigint)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_slug text;
    v_tag_id uuid;
begin
    v_user_id := internal_api.require_project_member(p_project_id);

    v_slug := internal_api.normalize_slug(p_name);

    insert into taxonomy.tags (project_id, namespace, name, slug, description, value_type, status, created_by_user_id)
    values (p_project_id, p_namespace, p_name, v_slug, p_description, p_value_type, 'active', v_user_id)
    returning id into v_tag_id;

    return query select v_tag_id, p_namespace, v_slug, 1::bigint;
end;
$$;

alter function app_api_v1.create_tag(uuid, text, text, text, text) owner to app_function_owner;
revoke all on function app_api_v1.create_tag(uuid, text, text, text, text) from public;

-- 9.9 update_tag
create function app_api_v1.update_tag(
    p_tag_id uuid,
    p_expected_revision bigint,
    p_name text default null,
    p_description text default null
)
returns table (tag_id uuid, revision bigint, updated_at timestamptz)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_project_id uuid;
    v_user_id uuid;
begin
    select t.project_id into v_project_id from taxonomy.tags t where t.id = p_tag_id;
    if not found then
        raise exception 'TAG_NOT_FOUND: Tag does not exist.'
            using detail = 'TAG_NOT_FOUND';
    end if;

    v_user_id := internal_api.require_project_member(v_project_id);

    update taxonomy.tags t
    set name = coalesce(p_name, t.name),
        description = coalesce(p_description, t.description),
        revision = t.revision + 1,
        updated_at = transaction_timestamp()
    where t.id = p_tag_id
      and t.revision = p_expected_revision;

    if not found then
        raise exception 'REVISION_CONFLICT: Expected revision did not match current revision.'
            using detail = 'REVISION_CONFLICT';
    end if;

    return query select t.id, t.revision, t.updated_at
    from taxonomy.tags t where t.id = p_tag_id;
end;
$$;

alter function app_api_v1.update_tag(uuid, bigint, text, text) owner to app_function_owner;
revoke all on function app_api_v1.update_tag(uuid, bigint, text, text) from public;

-- 9.10 assign_tag_to_object
create function app_api_v1.assign_tag_to_object(
    p_project_id uuid,
    p_object_id uuid,
    p_tag_id uuid,
    p_text_value text default null,
    p_number_value numeric default null,
    p_boolean_value boolean default null,
    p_date_value date default null,
    p_assignment_source text default 'human',
    p_confidence numeric default null,
    p_evidence_text text default null
)
returns table (assignment_id uuid, status text)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_assignment_id uuid;
begin
    v_user_id := internal_api.require_project_member(p_project_id);

    insert into taxonomy.tag_assignments (
        project_id, object_id, tag_id, assignment_source, status,
        text_value, number_value, boolean_value, date_value,
        assigned_by_user_id, confidence, evidence_text
    ) values (
        p_project_id, p_object_id, p_tag_id, p_assignment_source, 'active',
        p_text_value, p_number_value, p_boolean_value, p_date_value,
        v_user_id, p_confidence, p_evidence_text
    )
    returning id into v_assignment_id;

    return query select v_assignment_id, 'active';
end;
$$;

alter function app_api_v1.assign_tag_to_object(uuid, uuid, uuid, text, numeric, boolean, date, text, numeric, text) owner to app_function_owner;
revoke all on function app_api_v1.assign_tag_to_object(uuid, uuid, uuid, text, numeric, boolean, date, text, numeric, text) from public;

-- 9.11 remove_tag_assignment
create function app_api_v1.remove_tag_assignment(
    p_assignment_id uuid,
    p_removal_reason text default null
)
returns void
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_project_id uuid;
    v_user_id uuid;
begin
    select ta.project_id into v_project_id
    from taxonomy.tag_assignments ta where ta.id = p_assignment_id;
    if not found then
        raise exception 'TAG_ASSIGNMENT_NOT_FOUND: Tag assignment does not exist.'
            using detail = 'TAG_ASSIGNMENT_NOT_FOUND';
    end if;

    v_user_id := internal_api.require_project_member(v_project_id);

    update taxonomy.tag_assignments
    set status = 'removed',
        removed_by_user_id = v_user_id,
        removed_at = transaction_timestamp(),
        removal_reason = p_removal_reason
    where id = p_assignment_id;
end;
$$;

alter function app_api_v1.remove_tag_assignment(uuid, text) owner to app_function_owner;
revoke all on function app_api_v1.remove_tag_assignment(uuid, text) from public;

-- 9.12 create_relationship
create function app_api_v1.create_relationship(
    p_project_id uuid,
    p_source_object_id uuid,
    p_relationship_type text,
    p_target_object_id uuid,
    p_confidence numeric default null,
    p_evidence_text text default null
)
returns table (relationship_id uuid, status text)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_relationship_id uuid;
begin
    v_user_id := internal_api.require_project_member(p_project_id);

    insert into taxonomy.object_relationships (
        project_id, source_object_id, relationship_type, target_object_id, status,
        created_by_user_id, confidence, evidence_text
    ) values (
        p_project_id, p_source_object_id, p_relationship_type, p_target_object_id, 'active',
        v_user_id, p_confidence, p_evidence_text
    )
    returning id into v_relationship_id;

    return query select v_relationship_id, 'active';
end;
$$;

alter function app_api_v1.create_relationship(uuid, uuid, text, uuid, numeric, text) owner to app_function_owner;
revoke all on function app_api_v1.create_relationship(uuid, uuid, text, uuid, numeric, text) from public;

-- 9.13 update_relationship
create function app_api_v1.update_relationship(
    p_relationship_id uuid,
    p_status text
)
returns table (relationship_id uuid, status text)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_project_id uuid;
    v_user_id uuid;
begin
    select or_.project_id into v_project_id
    from taxonomy.object_relationships or_ where or_.id = p_relationship_id;
    if not found then
        raise exception 'RELATIONSHIP_NOT_FOUND: Relationship does not exist.'
            using detail = 'RELATIONSHIP_NOT_FOUND';
    end if;

    v_user_id := internal_api.require_project_member(v_project_id);

    update taxonomy.object_relationships
    set status = p_status,
        reviewed_by_user_id = v_user_id,
        reviewed_at = transaction_timestamp()
    where id = p_relationship_id;

    return query select p_relationship_id, p_status;
end;
$$;

alter function app_api_v1.update_relationship(uuid, text) owner to app_function_owner;
revoke all on function app_api_v1.update_relationship(uuid, text) from public;

-- 9.14 remove_relationship
create function app_api_v1.remove_relationship(
    p_relationship_id uuid,
    p_removal_reason text default null
)
returns void
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_project_id uuid;
    v_user_id uuid;
begin
    select or_.project_id into v_project_id
    from taxonomy.object_relationships or_ where or_.id = p_relationship_id;
    if not found then
        raise exception 'RELATIONSHIP_NOT_FOUND: Relationship does not exist.'
            using detail = 'RELATIONSHIP_NOT_FOUND';
    end if;

    v_user_id := internal_api.require_project_member(v_project_id);

    update taxonomy.object_relationships
    set status = 'removed',
        removed_by_user_id = v_user_id,
        removed_at = transaction_timestamp(),
        removal_reason = p_removal_reason
    where id = p_relationship_id;
end;
$$;

alter function app_api_v1.remove_relationship(uuid, text) owner to app_function_owner;
revoke all on function app_api_v1.remove_relationship(uuid, text) from public;
