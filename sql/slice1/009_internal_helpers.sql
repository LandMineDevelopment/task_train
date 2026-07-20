-- Slice 1: Phase 8 — Internal API Helpers

-- 8.1 Authentication helpers

create function internal_api.current_auth_issuer()
returns text
language sql
stable
set search_path = pg_catalog
as $$
    select current_setting('request.jwt.claims', true)::json ->> 'iss';
$$;

alter function internal_api.current_auth_issuer() owner to migration_owner;
revoke all on function internal_api.current_auth_issuer() from public;

create function internal_api.current_auth_subject()
returns text
language sql
stable
set search_path = pg_catalog
as $$
    select current_setting('request.jwt.claims', true)::json ->> 'sub';
$$;

alter function internal_api.current_auth_subject() owner to migration_owner;
revoke all on function internal_api.current_auth_subject() from public;

create function internal_api.current_user_id()
returns uuid
language plpgsql
stable
set search_path = pg_catalog, identity
as $$
declare
    v_user_id uuid;
begin
    -- Check if already resolved in this transaction
    begin
        v_user_id := current_setting('app.current_user_id')::uuid;
        if v_user_id is not null then
            return v_user_id;
        end if;
    exception when others then
        null;
    end;

    -- Resolve from JWT claims
    select u.id into v_user_id
    from identity.users u
    inner join identity.auth_identities ai on ai.user_id = u.id
    where ai.issuer = internal_api.current_auth_issuer()
      and ai.subject = internal_api.current_auth_subject()
      and u.status = 'active';

    if v_user_id is not null then
        perform set_config('app.current_user_id', v_user_id::text, true);
    end if;

    return v_user_id;
end;
$$;

alter function internal_api.current_user_id() owner to migration_owner;
revoke all on function internal_api.current_user_id() from public;

create function internal_api.require_authenticated_user()
returns uuid
language plpgsql
set search_path = pg_catalog, internal_api
as $$
declare
    v_user_id uuid;
begin
    v_user_id := internal_api.current_user_id();
    if v_user_id is null then
        raise exception 'AUTHENTICATION_REQUIRED: No valid provider identity was present.'
            using detail = 'AUTHENTICATION_REQUIRED';
    end if;
    return v_user_id;
end;
$$;

alter function internal_api.require_authenticated_user() owner to migration_owner;
revoke all on function internal_api.require_authenticated_user() from public;

-- 8.2 Project authorization helpers

create function internal_api.require_project_member(p_project_id uuid)
returns uuid
language plpgsql
set search_path = pg_catalog, internal_api, project
as $$
declare
    v_user_id uuid;
begin
    v_user_id := internal_api.require_authenticated_user();
    if not exists (
        select 1 from project.project_memberships
        where project_id = p_project_id
          and user_id = v_user_id
          and status = 'active'
    ) then
        raise exception 'PROJECT_ACCESS_DENIED: Caller lacks active project membership.'
            using detail = 'PROJECT_ACCESS_DENIED';
    end if;
    return v_user_id;
end;
$$;

alter function internal_api.require_project_member(p_project_id uuid) owner to migration_owner;
revoke all on function internal_api.require_project_member(uuid) from public;

create function internal_api.require_project_owner(p_project_id uuid)
returns uuid
language plpgsql
set search_path = pg_catalog, internal_api, project
as $$
declare
    v_user_id uuid;
begin
    v_user_id := internal_api.require_authenticated_user();
    if not exists (
        select 1 from project.project_memberships
        where project_id = p_project_id
          and user_id = v_user_id
          and role = 'owner'
          and status = 'active'
    ) then
        raise exception 'PROJECT_OWNER_REQUIRED: Action requires active owner role.'
            using detail = 'PROJECT_OWNER_REQUIRED';
    end if;
    return v_user_id;
end;
$$;

alter function internal_api.require_project_owner(p_project_id uuid) owner to migration_owner;
revoke all on function internal_api.require_project_owner(uuid) from public;

-- 8.3 Normalization helpers

create function internal_api.normalize_namespace(p_namespace text)
returns text
language plpgsql
set search_path = pg_catalog
as $$
declare
    v_normalized text;
begin
    v_normalized := lower(trim(p_namespace));
    if v_normalized = '' then
        raise exception 'INVALID_ARGUMENT: Namespace cannot be empty.'
            using detail = 'INVALID_ARGUMENT';
    end if;
    return v_normalized;
end;
$$;

alter function internal_api.normalize_namespace(text) owner to migration_owner;
revoke all on function internal_api.normalize_namespace(text) from public;

create function internal_api.normalize_slug(p_input text)
returns text
language plpgsql
set search_path = pg_catalog
as $$
declare
    v_slug text;
begin
    v_slug := lower(trim(p_input));
    v_slug := regexp_replace(v_slug, '[^a-z0-9_-]', '-', 'g');
    v_slug := regexp_replace(v_slug, '-+', '-', 'g');
    v_slug := trim(both '-' from v_slug);
    if v_slug = '' then
        v_slug := 'item';
    end if;
    return v_slug;
end;
$$;

alter function internal_api.normalize_slug(text) owner to migration_owner;
revoke all on function internal_api.normalize_slug(text) from public;

-- 8.4 Registry helpers

create function internal_api.register_object(
    p_project_id uuid,
    p_object_type text,
    p_display_label text default null,
    p_created_by_user_id uuid default null,
    p_created_by_object_id uuid default null
)
returns uuid
language plpgsql
set search_path = pg_catalog, taxonomy
as $$
declare
    v_id uuid;
begin
    v_id := gen_random_uuid();
    insert into taxonomy.object_registry (id, project_id, object_type, display_label, created_by_user_id, created_by_object_id)
    values (v_id, p_project_id, p_object_type, p_display_label, p_created_by_user_id, p_created_by_object_id);
    return v_id;
end;
$$;

alter function internal_api.register_object(uuid, text, text, uuid, uuid) owner to migration_owner;
revoke all on function internal_api.register_object(uuid, text, text, uuid, uuid) from public;

create function internal_api.update_object_label(
    p_object_id uuid,
    p_expected_revision bigint,
    p_display_label text
)
returns table (object_id uuid, revision bigint, updated_at timestamptz)
language plpgsql
set search_path = pg_catalog, taxonomy
as $$
begin
    update taxonomy.object_registry o
    set display_label = p_display_label,
        revision = o.revision + 1,
        updated_at = transaction_timestamp()
    where o.id = p_object_id
      and o.revision = p_expected_revision
      and o.archived_at is null;

    if not found then
        if not exists (select 1 from taxonomy.object_registry where id = p_object_id) then
            raise exception 'OBJECT_NOT_FOUND: Registered object does not exist or is hidden.'
                using detail = 'OBJECT_NOT_FOUND';
        else
            raise exception 'REVISION_CONFLICT: Expected revision did not match current revision.'
                using detail = 'REVISION_CONFLICT';
        end if;
    end if;

    return query
    select o.id, o.revision, o.updated_at
    from taxonomy.object_registry o
    where o.id = p_object_id;
end;
$$;

alter function internal_api.update_object_label(uuid, bigint, text) owner to migration_owner;
revoke all on function internal_api.update_object_label(uuid, bigint, text) from public;

create function internal_api.archive_object(
    p_object_id uuid,
    p_expected_revision bigint
)
returns table (object_id uuid, revision bigint, archived_at timestamptz)
language plpgsql
set search_path = pg_catalog, taxonomy
as $$
begin
    update taxonomy.object_registry o
    set archived_at = transaction_timestamp(),
        revision = o.revision + 1,
        updated_at = transaction_timestamp()
    where o.id = p_object_id
      and o.revision = p_expected_revision
      and o.archived_at is null;

    if not found then
        if not exists (select 1 from taxonomy.object_registry where id = p_object_id) then
            raise exception 'OBJECT_NOT_FOUND: Registered object does not exist or is hidden.'
                using detail = 'OBJECT_NOT_FOUND';
        else
            raise exception 'REVISION_CONFLICT: Expected revision did not match current revision.'
                using detail = 'REVISION_CONFLICT';
        end if;
    end if;

    return query
    select o.id, o.revision, o.archived_at
    from taxonomy.object_registry o
    where o.id = p_object_id;
end;
$$;

alter function internal_api.archive_object(uuid, bigint) owner to migration_owner;
revoke all on function internal_api.archive_object(uuid, bigint) from public;

-- 8.5 Tag/relationship helpers

create function internal_api.validate_tag_value(
    p_tag_id uuid,
    p_text_value text default null,
    p_number_value numeric default null,
    p_boolean_value boolean default null,
    p_date_value date default null
)
returns void
language plpgsql
set search_path = pg_catalog, taxonomy
as $$
declare
    v_value_type text;
begin
    select t.value_type into v_value_type
    from taxonomy.tags t
    where t.id = p_tag_id;

    if not found then
        raise exception 'TAG_NOT_FOUND: Tag does not exist or is hidden.'
            using detail = 'TAG_NOT_FOUND';
    end if;

    if v_value_type = 'none' then
        if p_text_value is not null or p_number_value is not null
           or p_boolean_value is not null or p_date_value is not null
        then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag value_type is none but value arguments were provided.'
                using detail = 'TAG_VALUE_TYPE_MISMATCH';
        end if;
    elsif v_value_type = 'text' and p_text_value is null then
        raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a text value.'
            using detail = 'TAG_VALUE_TYPE_MISMATCH';
    elsif v_value_type = 'number' and p_number_value is null then
        raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a number value.'
            using detail = 'TAG_VALUE_TYPE_MISMATCH';
    elsif v_value_type = 'boolean' and p_boolean_value is null then
        raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a boolean value.'
            using detail = 'TAG_VALUE_TYPE_MISMATCH';
    elsif v_value_type = 'date' and p_date_value is null then
        raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a date value.'
            using detail = 'TAG_VALUE_TYPE_MISMATCH';
    end if;
end;
$$;

alter function internal_api.validate_tag_value(uuid, text, numeric, boolean, date) owner to migration_owner;
revoke all on function internal_api.validate_tag_value(uuid, text, numeric, boolean, date) from public;

create function internal_api.canonicalize_relationship(
    p_source_id uuid,
    p_target_id uuid,
    p_is_symmetric boolean
)
returns table (source_id uuid, target_id uuid)
language sql
stable
set search_path = pg_catalog
as $$
    select
        case when p_is_symmetric then least(p_source_id, p_target_id) else p_source_id end,
        case when p_is_symmetric then greatest(p_source_id, p_target_id) else p_target_id end;
$$;

alter function internal_api.canonicalize_relationship(uuid, uuid, boolean) owner to migration_owner;
revoke all on function internal_api.canonicalize_relationship(uuid, uuid, boolean) from public;

-- 8.6 Command deduplication helpers

create function internal_api.begin_command(
    p_user_id uuid,
    p_project_id uuid,
    p_function_key text,
    p_idempotency_key text,
    out command_id uuid,
    out already_completed boolean
)
language plpgsql
set search_path = pg_catalog, platform
as $$
declare
    v_existing record;
begin
    already_completed := false;

    select cr.id, cr.status, cr.result_entity_id
    into v_existing
    from platform.command_requests cr
    where cr.initiating_user_id = p_user_id
      and cr.function_key = p_function_key
      and cr.idempotency_key = p_idempotency_key;

    if found then
        if v_existing.status = 'completed' then
            command_id := v_existing.id;
            already_completed := true;
            return;
        elsif v_existing.status = 'started' then
            raise exception 'COMMAND_IN_PROGRESS: An idempotent command with the same key is still running.'
                using detail = 'COMMAND_IN_PROGRESS';
        else
            -- failed — allow retry
            update platform.command_requests
            set status = 'started',
                completed_at = null,
                error_code = null
            where id = v_existing.id;
            command_id := v_existing.id;
            return;
        end if;
    end if;

    insert into platform.command_requests (initiating_user_id, project_id, function_key, idempotency_key, status)
    values (p_user_id, p_project_id, p_function_key, p_idempotency_key, 'started')
    returning id into command_id;
end;
$$;

alter function internal_api.begin_command(uuid, uuid, text, text) owner to migration_owner;
revoke all on function internal_api.begin_command(uuid, uuid, text, text) from public;

create function internal_api.complete_command(
    p_command_id uuid,
    p_result_kind text,
    p_result_id uuid
)
returns void
language plpgsql
set search_path = pg_catalog, platform
as $$
begin
    update platform.command_requests
    set status = 'completed',
        result_entity_kind = p_result_kind,
        result_entity_id = p_result_id,
        completed_at = transaction_timestamp()
    where id = p_command_id;
end;
$$;

alter function internal_api.complete_command(uuid, text, uuid) owner to migration_owner;
revoke all on function internal_api.complete_command(uuid, text, uuid) from public;

create function internal_api.fail_command(
    p_command_id uuid,
    p_error_code text
)
returns void
language plpgsql
set search_path = pg_catalog, platform
as $$
begin
    update platform.command_requests
    set status = 'failed',
        error_code = p_error_code,
        completed_at = transaction_timestamp()
    where id = p_command_id;
end;
$$;

alter function internal_api.fail_command(uuid, text) owner to migration_owner;
revoke all on function internal_api.fail_command(uuid, text) from public;

-- 8.7 Integrity helper

create function internal_api.check_object_registry_integrity(
    p_project_id uuid default null
)
returns table (issue_type text, object_id uuid, object_type text, details text)
language plpgsql
set search_path = pg_catalog, taxonomy
as $$
begin
    -- Registry rows without matching object types
    return query
    select 'unknown_type'::text, r.id, r.object_type, 'Object type is not defined in taxonomy.object_types'
    from taxonomy.object_registry r
    left join taxonomy.object_types ot on ot.object_type = r.object_type
    where ot.object_type is null
      and (p_project_id is null or r.project_id = p_project_id);

    return next;
end;
$$;

alter function internal_api.check_object_registry_integrity(uuid) owner to migration_owner;
revoke all on function internal_api.check_object_registry_integrity(uuid) from public;

-- Deferred RLS policy for identity.users (requires current_user_id)
create policy users_self_read on identity.users
    for select
    using (id = internal_api.current_user_id());
