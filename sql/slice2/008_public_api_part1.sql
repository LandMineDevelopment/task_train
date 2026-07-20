-- Slice 2: Phase 7 — Public API Functions (Part 1: Mutations)

-- 7.1 create_note
create function app_api_v1.create_note(
    p_project_id uuid,
    p_title text,
    p_content text,
    p_text_format text default 'markdown',
    p_description text default null,
    p_tag_ids uuid[] default null,
    p_idempotency_key text default null
)
returns table (
    resource_id uuid,
    resource_object_id uuid,
    resource_version_id uuid,
    version_object_id uuid,
    version_number integer,
    resource_revision bigint,
    created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_cmd_id uuid;
    v_already_done boolean;
    v_resource_id uuid;
    v_resource_object_id uuid;
    v_resource_revision bigint;
    v_version_id uuid;
    v_version_object_id uuid;
    v_version_number integer;
    v_content_hash text;
    v_now timestamptz;
begin
    v_user_id := internal_api.require_project_member(p_project_id);

    if p_title is null or length(trim(p_title)) = 0 then
        raise exception 'RESOURCE_TITLE_REQUIRED: Title is required.'
            using detail = 'RESOURCE_TITLE_REQUIRED';
    end if;

    if p_content is null then
        raise exception 'RESOURCE_CONTENT_REQUIRED: Content is required.'
            using detail = 'RESOURCE_CONTENT_REQUIRED';
    end if;

    if p_text_format not in ('plain_text', 'markdown', 'code', 'diff') then
        raise exception 'RESOURCE_FORMAT_INVALID: Text format must be plain_text, markdown, code, or diff.'
            using detail = 'RESOURCE_FORMAT_INVALID';
    end if;

    -- Idempotency
    if p_idempotency_key is not null then
        select command_id, already_completed into v_cmd_id, v_already_done
        from internal_api.begin_command(v_user_id, p_project_id, 'create_note', p_idempotency_key);

        if v_already_done then
            return query
            select r.id, r.object_id, v.id, v.object_id, v.version_number, r.revision, v.created_at
            from platform.command_requests cr
            join resource.resources r on r.id = cr.result_entity_id
            join resource.resource_heads h on h.resource_id = r.id
            join resource.resource_versions v on v.id = h.current_version_id
            where cr.id = v_cmd_id;
            return;
        end if;
    end if;

    -- Validate tags
    if p_tag_ids is not null then
        perform internal_api.validate_resource_tags(p_project_id, p_tag_ids);
    end if;

    -- Create resource identity
    select ri.resource_id, ri.object_id, ri.revision
    into v_resource_id, v_resource_object_id, v_resource_revision
    from internal_api.create_resource_identity(
        p_project_id, 'note', p_title, p_description, v_user_id
    ) ri;

    -- Create version 1
    select tv.resource_version_id, tv.version_object_id, tv.version_number, tv.content_hash, tv.created_at
    into v_version_id, v_version_object_id, v_version_number, v_content_hash, v_now
    from internal_api.create_text_version(
        v_resource_id, p_content, p_text_format, null, null, v_user_id
    ) tv;

    -- Assign tags
    if p_tag_ids is not null then
        for i in 1..array_length(p_tag_ids, 1) loop
            insert into taxonomy.tag_assignments (project_id, object_id, tag_id, assignment_source, status, assigned_by_user_id)
            values (p_project_id, v_resource_object_id, p_tag_ids[i], 'human', 'active', v_user_id)
            on conflict (object_id, tag_id) where status in ('proposed', 'active', 'confirmed') do nothing;
        end loop;
    end if;

    -- Rebuild search
    perform internal_api.rebuild_resource_search_document(v_resource_id);

    -- Complete command
    if p_idempotency_key is not null then
        perform internal_api.complete_command(v_cmd_id, 'resource', v_resource_id);
    end if;

    return query
    select v_resource_id, v_resource_object_id, v_version_id, v_version_object_id, v_version_number, v_resource_revision, v_now;
end;
$$;

alter function app_api_v1.create_note(uuid, text, text, text, text, uuid[], text) owner to app_function_owner;
revoke all on function app_api_v1.create_note(uuid, text, text, text, text, uuid[], text) from public;

-- 7.2 update_text_resource
create function app_api_v1.update_text_resource(
    p_resource_id uuid,
    p_expected_version_number integer,
    p_content text,
    p_text_format text default 'markdown',
    p_language_code text default null,
    p_change_summary text default null,
    p_idempotency_key text default null
)
returns table (
    resource_id uuid,
    resource_version_id uuid,
    version_object_id uuid,
    version_number integer,
    content_hash text,
    created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
    v_cmd_id uuid;
    v_already_done boolean;
    v_head_number integer;
    v_version_id uuid;
    v_version_object_id uuid;
    v_version_number integer;
    v_content_hash text;
    v_now timestamptz;
begin
    v_user_id := internal_api.require_resource_member(p_resource_id);

    select r.project_id into v_project_id
    from resource.resources r where r.id = p_resource_id;

    if p_content is null then
        raise exception 'RESOURCE_CONTENT_REQUIRED: Content is required.'
            using detail = 'RESOURCE_CONTENT_REQUIRED';
    end if;

    if p_text_format not in ('plain_text', 'markdown', 'code', 'diff') then
        raise exception 'RESOURCE_FORMAT_INVALID: Text format must be plain_text, markdown, code, or diff.'
            using detail = 'RESOURCE_FORMAT_INVALID';
    end if;

    -- Check resource is active
    if exists (select 1 from resource.resources r2 where r2.id = p_resource_id and r2.status = 'archived') then
        raise exception 'RESOURCE_ARCHIVED: Archived resources cannot be modified.'
            using detail = 'RESOURCE_ARCHIVED';
    end if;

    -- Idempotency
    if p_idempotency_key is not null then
        select command_id, already_completed into v_cmd_id, v_already_done
        from internal_api.begin_command(v_user_id, v_project_id, 'update_text_resource', p_idempotency_key);

        if v_already_done then
            return query
            select r.id, v.id, v.object_id, v.version_number, v.content_hash, v.created_at
            from platform.command_requests cr
            join resource.resources r on r.id = cr.result_entity_id
            join resource.resource_heads h on h.resource_id = r.id
            join resource.resource_versions v on v.id = h.current_version_id
            where cr.id = v_cmd_id;
            return;
        end if;
    end if;

    -- Lock head and check expected version
    select h.current_version_number into v_head_number
    from resource.resource_heads h
    where h.resource_id = p_resource_id
    for update;

    if v_head_number is null then
        raise exception 'RESOURCE_HEAD_INVALID: Resource has no current version head.'
            using detail = 'RESOURCE_HEAD_INVALID';
    end if;

    if v_head_number != p_expected_version_number then
        raise exception 'RESOURCE_VERSION_CONFLICT: Expected version % does not match current head version %.', p_expected_version_number, v_head_number
            using detail = 'RESOURCE_VERSION_CONFLICT';
    end if;

    -- Create next version
    select tv.resource_version_id, tv.version_object_id, tv.version_number, tv.content_hash, tv.created_at
    into v_version_id, v_version_object_id, v_version_number, v_content_hash, v_now
    from internal_api.create_text_version(
        p_resource_id, p_content, p_text_format, p_language_code, p_change_summary, v_user_id
    ) tv;

    -- Rebuild search
    perform internal_api.rebuild_resource_search_document(p_resource_id);

    -- Complete command
    if p_idempotency_key is not null then
        perform internal_api.complete_command(v_cmd_id, 'resource', p_resource_id);
    end if;

    return query
    select p_resource_id, v_version_id, v_version_object_id, v_version_number, v_content_hash, v_now;
end;
$$;

alter function app_api_v1.update_text_resource(uuid, integer, text, text, text, text, text) owner to app_function_owner;
revoke all on function app_api_v1.update_text_resource(uuid, integer, text, text, text, text, text) from public;

-- 7.3 create_link_resource
create function app_api_v1.create_link_resource(
    p_project_id uuid,
    p_title text,
    p_url text,
    p_description text default null,
    p_link_title text default null,
    p_link_description text default null,
    p_tag_ids uuid[] default null,
    p_idempotency_key text default null
)
returns table (
    resource_id uuid,
    resource_object_id uuid,
    resource_version_id uuid,
    version_object_id uuid,
    version_number integer,
    created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_cmd_id uuid;
    v_already_done boolean;
    v_resource_id uuid;
    v_resource_object_id uuid;
    v_resource_revision bigint;
    v_version_id uuid;
    v_version_object_id uuid;
    v_version_number integer;
    v_normalized_url text;
    v_content_hash text;
    v_now timestamptz;
begin
    v_user_id := internal_api.require_project_member(p_project_id);

    if p_title is null or length(trim(p_title)) = 0 then
        raise exception 'RESOURCE_TITLE_REQUIRED: Title is required.'
            using detail = 'RESOURCE_TITLE_REQUIRED';
    end if;

    if p_url is null or length(trim(p_url)) = 0 then
        raise exception 'RESOURCE_CONTENT_REQUIRED: URL is required.'
            using detail = 'RESOURCE_CONTENT_REQUIRED';
    end if;

    -- Idempotency
    if p_idempotency_key is not null then
        select command_id, already_completed into v_cmd_id, v_already_done
        from internal_api.begin_command(v_user_id, p_project_id, 'create_link_resource', p_idempotency_key);

        if v_already_done then
            return query
            select r.id, r.object_id, v.id, v.object_id, v.version_number, v.created_at
            from platform.command_requests cr
            join resource.resources r on r.id = cr.result_entity_id
            join resource.resource_heads h on h.resource_id = r.id
            join resource.resource_versions v on v.id = h.current_version_id
            where cr.id = v_cmd_id;
            return;
        end if;
    end if;

    -- Validate tags
    if p_tag_ids is not null then
        perform internal_api.validate_resource_tags(p_project_id, p_tag_ids);
    end if;

    -- Create resource identity
    select ri.resource_id, ri.object_id, ri.revision
    into v_resource_id, v_resource_object_id, v_resource_revision
    from internal_api.create_resource_identity(
        p_project_id, 'link', p_title, p_description, v_user_id
    ) ri;

    -- Create link version 1
    select lv.resource_version_id, lv.version_object_id, lv.version_number, lv.normalized_url, lv.content_hash, lv.created_at
    into v_version_id, v_version_object_id, v_version_number, v_normalized_url, v_content_hash, v_now
    from internal_api.create_link_version(
        v_resource_id, p_url, p_link_title, p_link_description, null, v_user_id
    ) lv;

    -- Assign tags
    if p_tag_ids is not null then
        for i in 1..array_length(p_tag_ids, 1) loop
            insert into taxonomy.tag_assignments (project_id, object_id, tag_id, assignment_source, status, assigned_by_user_id)
            values (p_project_id, v_resource_object_id, p_tag_ids[i], 'human', 'active', v_user_id)
            on conflict (object_id, tag_id) where status in ('proposed', 'active', 'confirmed') do nothing;
        end loop;
    end if;

    -- Rebuild search
    perform internal_api.rebuild_resource_search_document(v_resource_id);

    -- Complete command
    if p_idempotency_key is not null then
        perform internal_api.complete_command(v_cmd_id, 'resource', v_resource_id);
    end if;

    return query
    select v_resource_id, v_resource_object_id, v_version_id, v_version_object_id, v_version_number, v_now;
end;
$$;

alter function app_api_v1.create_link_resource(uuid, text, text, text, text, text, uuid[], text) owner to app_function_owner;
revoke all on function app_api_v1.create_link_resource(uuid, text, text, text, text, text, uuid[], text) from public;

-- 7.4 update_link_resource
create function app_api_v1.update_link_resource(
    p_resource_id uuid,
    p_expected_version_number integer,
    p_url text,
    p_link_title text default null,
    p_link_description text default null,
    p_change_summary text default null,
    p_idempotency_key text default null
)
returns table (
    resource_id uuid,
    resource_version_id uuid,
    version_object_id uuid,
    version_number integer,
    normalized_url text,
    content_hash text,
    created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
    v_cmd_id uuid;
    v_already_done boolean;
    v_head_number integer;
    v_version_id uuid;
    v_version_object_id uuid;
    v_version_number integer;
    v_normalized_url text;
    v_content_hash text;
    v_now timestamptz;
begin
    v_user_id := internal_api.require_resource_member(p_resource_id);

    select r.project_id into v_project_id
    from resource.resources r where r.id = p_resource_id;

    if p_url is null or length(trim(p_url)) = 0 then
        raise exception 'RESOURCE_CONTENT_REQUIRED: URL is required.'
            using detail = 'RESOURCE_CONTENT_REQUIRED';
    end if;

    -- Check resource is active
    if exists (select 1 from resource.resources r2 where r2.id = p_resource_id and r2.status = 'archived') then
        raise exception 'RESOURCE_ARCHIVED: Archived resources cannot be modified.'
            using detail = 'RESOURCE_ARCHIVED';
    end if;

    -- Idempotency
    if p_idempotency_key is not null then
        select command_id, already_completed into v_cmd_id, v_already_done
        from internal_api.begin_command(v_user_id, v_project_id, 'update_link_resource', p_idempotency_key);

        if v_already_done then
            return query
            select r.id, v.id, v.object_id, v.version_number, lc.normalized_url, v.content_hash, v.created_at
            from platform.command_requests cr
            join resource.resources r on r.id = cr.result_entity_id
            join resource.resource_heads h on h.resource_id = r.id
            join resource.resource_versions v on v.id = h.current_version_id
            join resource.link_contents lc on lc.resource_version_id = v.id
            where cr.id = v_cmd_id;
            return;
        end if;
    end if;

    -- Lock head and check expected version
    select h.current_version_number into v_head_number
    from resource.resource_heads h
    where h.resource_id = p_resource_id
    for update;

    if v_head_number is null then
        raise exception 'RESOURCE_HEAD_INVALID: Resource has no current version head.'
            using detail = 'RESOURCE_HEAD_INVALID';
    end if;

    if v_head_number != p_expected_version_number then
        raise exception 'RESOURCE_VERSION_CONFLICT: Expected version % does not match current head version %.', p_expected_version_number, v_head_number
            using detail = 'RESOURCE_VERSION_CONFLICT';
    end if;

    -- Create next link version
    select lv.resource_version_id, lv.version_object_id, lv.version_number, lv.normalized_url, lv.content_hash, lv.created_at
    into v_version_id, v_version_object_id, v_version_number, v_normalized_url, v_content_hash, v_now
    from internal_api.create_link_version(
        p_resource_id, p_url, p_link_title, p_link_description, p_change_summary, v_user_id
    ) lv;

    -- Rebuild search
    perform internal_api.rebuild_resource_search_document(p_resource_id);

    -- Complete command
    if p_idempotency_key is not null then
        perform internal_api.complete_command(v_cmd_id, 'resource', p_resource_id);
    end if;

    return query
    select p_resource_id, v_version_id, v_version_object_id, v_version_number, v_normalized_url, v_content_hash, v_now;
end;
$$;

alter function app_api_v1.update_link_resource(uuid, integer, text, text, text, text, text) owner to app_function_owner;
revoke all on function app_api_v1.update_link_resource(uuid, integer, text, text, text, text, text) from public;

-- 7.5 update_resource_metadata
create function app_api_v1.update_resource_metadata(
    p_resource_id uuid,
    p_expected_revision bigint,
    p_set_title boolean default false,
    p_title text default null,
    p_set_description boolean default false,
    p_description text default null
)
returns table (
    resource_id uuid,
    revision bigint,
    title text,
    description text,
    updated_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
begin
    v_user_id := internal_api.require_resource_member(p_resource_id);

    select r.project_id into v_project_id
    from resource.resources r where r.id = p_resource_id;

    if exists (select 1 from resource.resources r2 where r2.id = p_resource_id and r2.status = 'archived') then
        raise exception 'RESOURCE_ARCHIVED: Archived resources cannot be modified.'
            using detail = 'RESOURCE_ARCHIVED';
    end if;

    if p_set_title and (p_title is null or length(trim(p_title)) = 0) then
        raise exception 'RESOURCE_TITLE_REQUIRED: Title is required when set_title is true.'
            using detail = 'RESOURCE_TITLE_REQUIRED';
    end if;

    update resource.resources r
    set title = case when p_set_title then trim(p_title) else r.title end,
        description = case when p_set_description then p_description else r.description end,
        revision = r.revision + 1,
        updated_at = transaction_timestamp()
    where r.id = p_resource_id
      and r.revision = p_expected_revision;

    if not found then
        if not exists (select 1 from resource.resources where id = p_resource_id) then
            raise exception 'RESOURCE_NOT_FOUND: Resource does not exist.'
                using detail = 'RESOURCE_NOT_FOUND';
        else
            raise exception 'RESOURCE_REVISION_CONFLICT: Expected revision did not match current revision.'
                using detail = 'RESOURCE_REVISION_CONFLICT';
        end if;
    end if;

    -- Rebuild search after metadata change
    perform internal_api.rebuild_resource_search_document(p_resource_id);

    return query
    select r.id, r.revision, r.title, r.description, r.updated_at
    from resource.resources r
    where r.id = p_resource_id;
end;
$$;

alter function app_api_v1.update_resource_metadata(uuid, bigint, boolean, text, boolean, text) owner to app_function_owner;
revoke all on function app_api_v1.update_resource_metadata(uuid, bigint, boolean, text, boolean, text) from public;

-- 7.6 create_file_resource_upload_reservation
create function app_api_v1.create_file_resource_upload_reservation(
    p_project_id uuid,
    p_resource_type text,
    p_title text,
    p_original_filename text,
    p_declared_media_type text,
    p_declared_byte_size bigint,
    p_idempotency_key text default null
)
returns table (
    reservation_id uuid,
    provider text,
    bucket text,
    object_key text,
    expires_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_cmd_id uuid;
    v_already_done boolean;
    v_reservation_id uuid;
    v_provider text := 'supabase_storage';
    v_bucket text := 'platform-resources';
    v_object_key text;
    v_expires_at timestamptz;
    v_type_enabled boolean;
    v_kind_allowed boolean;
begin
    v_user_id := internal_api.require_project_member(p_project_id);

    if p_title is null or length(trim(p_title)) = 0 then
        raise exception 'RESOURCE_TITLE_REQUIRED: Title is required.'
            using detail = 'RESOURCE_TITLE_REQUIRED';
    end if;

    -- Validate resource type supports file content kind
    select rt.enabled into v_type_enabled
    from resource.resource_types rt where rt.resource_type = p_resource_type;
    if not found or not v_type_enabled then
        raise exception 'RESOURCE_TYPE_INVALID: Resource type is disabled or unknown.'
            using detail = 'RESOURCE_TYPE_INVALID';
    end if;

    select 1 into v_kind_allowed
    from resource.resource_type_content_kinds rtc
    where rtc.resource_type = p_resource_type and rtc.content_kind = 'file';
    if not found then
        raise exception 'RESOURCE_CONTENT_KIND_INVALID: File content is not allowed for this resource type.'
            using detail = 'RESOURCE_CONTENT_KIND_INVALID';
    end if;

    -- Idempotency
    if p_idempotency_key is not null then
        select command_id, already_completed into v_cmd_id, v_already_done
        from internal_api.begin_command(v_user_id, p_project_id, 'create_file_resource_upload_reservation', p_idempotency_key);

        if v_already_done then
            return query
            select ur.id, ur.provider, ur.bucket, ur.object_key, ur.expires_at
            from platform.command_requests cr
            join resource.upload_reservations ur on ur.id = cr.result_entity_id
            where cr.id = v_cmd_id;
            return;
        end if;
    end if;

    -- Create reservation
    v_reservation_id := gen_random_uuid();
    v_object_key := internal_api.generate_upload_key(p_project_id, v_reservation_id, p_original_filename);
    v_expires_at := transaction_timestamp() + interval '15 minutes';

    insert into resource.upload_reservations (id, project_id, operation_type, resource_type, requested_title, original_filename, declared_media_type, declared_byte_size, provider, bucket, object_key, requested_by_user_id, expires_at)
    values (v_reservation_id, p_project_id, 'create_resource', p_resource_type, p_title, p_original_filename, p_declared_media_type, p_declared_byte_size, v_provider, v_bucket, v_object_key, v_user_id, v_expires_at);

    if p_idempotency_key is not null then
        perform internal_api.complete_command(v_cmd_id, 'reservation', v_reservation_id);
    end if;

    return query
    select v_reservation_id, v_provider, v_bucket, v_object_key, v_expires_at;
end;
$$;

alter function app_api_v1.create_file_resource_upload_reservation(uuid, text, text, text, text, bigint, text) owner to app_function_owner;
revoke all on function app_api_v1.create_file_resource_upload_reservation(uuid, text, text, text, text, bigint, text) from public;

-- 7.7 create_file_version_upload_reservation
create function app_api_v1.create_file_version_upload_reservation(
    p_resource_id uuid,
    p_expected_version_number integer,
    p_original_filename text,
    p_declared_media_type text,
    p_declared_byte_size bigint,
    p_idempotency_key text default null
)
returns table (
    reservation_id uuid,
    provider text,
    bucket text,
    object_key text,
    expires_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
    v_cmd_id uuid;
    v_already_done boolean;
    v_head_number integer;
    v_reservation_id uuid;
    v_provider text := 'supabase_storage';
    v_bucket text := 'platform-resources';
    v_object_key text;
    v_expires_at timestamptz;
begin
    v_user_id := internal_api.require_resource_member(p_resource_id);

    select r.project_id into v_project_id
    from resource.resources r where r.id = p_resource_id;

    -- Check resource is active
    if exists (select 1 from resource.resources r2 where r2.id = p_resource_id and r2.status = 'archived') then
        raise exception 'RESOURCE_ARCHIVED: Archived resources cannot be modified.'
            using detail = 'RESOURCE_ARCHIVED';
    end if;

    -- Verify content kind
    if not exists (
        select 1 from resource.resources r
        join resource.resource_type_content_kinds rtc on rtc.resource_type = r.resource_type
        where r.id = p_resource_id and rtc.content_kind = 'file'
    ) then
        raise exception 'RESOURCE_CONTENT_KIND_INVALID: File content is not allowed for this resource type.'
            using detail = 'RESOURCE_CONTENT_KIND_INVALID';
    end if;

    -- Lock head and check expected version
    select h.current_version_number into v_head_number
    from resource.resource_heads h
    where h.resource_id = p_resource_id
    for update;

    if v_head_number is null then
        raise exception 'RESOURCE_HEAD_INVALID: Resource has no current version head.'
            using detail = 'RESOURCE_HEAD_INVALID';
    end if;

    if v_head_number != p_expected_version_number then
        raise exception 'RESOURCE_VERSION_CONFLICT: Expected version % does not match current head version %.', p_expected_version_number, v_head_number
            using detail = 'RESOURCE_VERSION_CONFLICT';
    end if;

    -- Idempotency
    if p_idempotency_key is not null then
        select command_id, already_completed into v_cmd_id, v_already_done
        from internal_api.begin_command(v_user_id, v_project_id, 'create_file_version_upload_reservation', p_idempotency_key);

        if v_already_done then
            return query
            select ur.id, ur.provider, ur.bucket, ur.object_key, ur.expires_at
            from platform.command_requests cr
            join resource.upload_reservations ur on ur.id = cr.result_entity_id
            where cr.id = v_cmd_id;
            return;
        end if;
    end if;

    -- Create reservation
    v_reservation_id := gen_random_uuid();
    v_object_key := internal_api.generate_upload_key(v_project_id, v_reservation_id, p_original_filename);
    v_expires_at := transaction_timestamp() + interval '15 minutes';

    insert into resource.upload_reservations (id, project_id, operation_type, target_resource_id, expected_version_number, resource_type, original_filename, declared_media_type, declared_byte_size, provider, bucket, object_key, requested_by_user_id, expires_at)
    select v_reservation_id, v_project_id, 'create_version', p_resource_id, p_expected_version_number, r.resource_type, p_original_filename, p_declared_media_type, p_declared_byte_size, v_provider, v_bucket, v_object_key, v_user_id, v_expires_at
    from resource.resources r where r.id = p_resource_id;

    if p_idempotency_key is not null then
        perform internal_api.complete_command(v_cmd_id, 'reservation', v_reservation_id);
    end if;

    return query
    select v_reservation_id, v_provider, v_bucket, v_object_key, v_expires_at;
end;
$$;

alter function app_api_v1.create_file_version_upload_reservation(uuid, integer, text, text, bigint, text) owner to app_function_owner;
revoke all on function app_api_v1.create_file_version_upload_reservation(uuid, integer, text, text, bigint, text) from public;

-- 7.8 finalize_upload
create function app_api_v1.finalize_upload(
    p_reservation_id uuid,
    p_description text default null,
    p_tag_ids uuid[] default null,
    p_change_summary text default null,
    p_idempotency_key text default null
)
returns table (
    resource_id uuid,
    resource_object_id uuid,
    resource_version_id uuid,
    version_object_id uuid,
    storage_object_id uuid,
    version_number integer,
    verification_status text,
    created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
    v_cmd_id uuid;
    v_already_done boolean;
    v_res record;
    v_rid uuid;
    v_robject_id uuid;
    v_vid uuid;
    v_vobject_id uuid;
    v_vnum integer;
    v_soid uuid;
    v_now timestamptz;
begin
    -- Get reservation
    select ur.* into v_res
    from resource.upload_reservations ur
    where ur.id = p_reservation_id;

    if not found then
        raise exception 'UPLOAD_RESERVATION_NOT_FOUND: Reservation does not exist.'
            using detail = 'UPLOAD_RESERVATION_NOT_FOUND';
    end if;

    v_user_id := internal_api.require_project_member(v_res.project_id);
    v_project_id := v_res.project_id;

    -- Must be in 'uploaded' state
    if v_res.status = 'expired' then
        raise exception 'UPLOAD_RESERVATION_EXPIRED: Reservation has expired.'
            using detail = 'UPLOAD_RESERVATION_EXPIRED';
    end if;

    if v_res.status = 'finalized' then
        raise exception 'UPLOAD_RESERVATION_FINALIZED: Reservation has already been finalized.'
            using detail = 'UPLOAD_RESERVATION_FINALIZED';
    end if;

    if v_res.status = 'cancelled' then
        raise exception 'UPLOAD_RESERVATION_CANCELLED: Reservation was cancelled.'
            using detail = 'UPLOAD_RESERVATION_CANCELLED';
    end if;

    if v_res.status != 'uploaded' then
        raise exception 'UPLOAD_RESERVATION_NOT_UPLOADED: No trusted upload observation exists for this reservation.'
            using detail = 'UPLOAD_RESERVATION_NOT_UPLOADED';
    end if;

    if v_res.expires_at <= transaction_timestamp() then
        raise exception 'UPLOAD_RESERVATION_EXPIRED: Reservation has expired.'
            using detail = 'UPLOAD_RESERVATION_EXPIRED';
    end if;

    -- Validate tags
    if p_tag_ids is not null then
        perform internal_api.validate_resource_tags(v_project_id, p_tag_ids);
    end if;

    -- Idempotency
    if p_idempotency_key is not null then
        select command_id, already_completed into v_cmd_id, v_already_done
        from internal_api.begin_command(v_user_id, v_project_id, 'finalize_upload', p_idempotency_key);

        if v_already_done then
            return query
            select cr.result_entity_id as resource_id, r.object_id, v.id, v.object_id, fc.storage_object_id, v.version_number, so.verification_status, v.created_at
            from platform.command_requests cr
            join resource.resources r on r.id = cr.result_entity_id
            join resource.resource_heads h on h.resource_id = r.id
            join resource.resource_versions v on v.id = h.current_version_id
            join resource.file_contents fc on fc.resource_version_id = v.id
            join resource.storage_objects so on so.id = fc.storage_object_id
            where cr.id = v_cmd_id;
            return;
        end if;
    end if;

    -- Create storage object
    select so_id into v_soid
    from internal_api.create_storage_object(
        p_project_id := v_project_id,
        p_provider := v_res.provider,
        p_bucket := v_res.bucket,
        p_object_key := v_res.object_key,
        p_content_hash := v_res.observed_content_hash,
        p_byte_size := v_res.observed_byte_size,
        p_media_type := v_res.observed_media_type,
        p_created_by_user_id := v_user_id,
        p_provider_version := v_res.provider_version
    ) as so_id;

    if v_res.operation_type = 'create_resource' then
        -- Create new resource
        select ri.resource_id, ri.object_id
        into v_rid, v_robject_id
        from internal_api.create_resource_identity(
            v_project_id, v_res.resource_type, v_res.requested_title, p_description, v_user_id
        ) ri;

        -- Create file version 1
        select fv.resource_version_id, fv.version_object_id, fv.version_number, fv.created_at
        into v_vid, v_vobject_id, v_vnum, v_now
        from internal_api.create_file_version(
            v_rid, v_soid, v_res.original_filename, v_res.observed_media_type,
            v_res.observed_byte_size, v_res.observed_content_hash, p_change_summary, v_user_id
        ) fv;

        -- Assign tags
        if p_tag_ids is not null then
            for i in 1..array_length(p_tag_ids, 1) loop
                insert into taxonomy.tag_assignments (project_id, object_id, tag_id, assignment_source, status, assigned_by_user_id)
                values (v_project_id, v_robject_id, p_tag_ids[i], 'human', 'active', v_user_id)
                on conflict (object_id, tag_id) where status in ('proposed', 'active', 'confirmed') do nothing;
            end loop;
        end if;
    else
        -- Create new version for existing resource
        v_rid := v_res.target_resource_id;

        select r.object_id into v_robject_id
        from resource.resources r where r.id = v_rid;

        -- Create file version
        select fv.resource_version_id, fv.version_object_id, fv.version_number, fv.created_at
        into v_vid, v_vobject_id, v_vnum, v_now
        from internal_api.create_file_version(
            v_rid, v_soid, v_res.original_filename, v_res.observed_media_type,
            v_res.observed_byte_size, v_res.observed_content_hash, p_change_summary, v_user_id
        ) fv;
    end if;

    -- Rebuild search
    perform internal_api.rebuild_resource_search_document(v_rid);

    -- Mark reservation finalized
    update resource.upload_reservations
    set status = 'finalized',
        finalized_at = transaction_timestamp()
    where id = p_reservation_id;

    -- Complete command
    if p_idempotency_key is not null then
        perform internal_api.complete_command(v_cmd_id, 'resource', v_rid);
    end if;

    return query
    select v_rid, v_robject_id, v_vid, v_vobject_id, v_soid, v_vnum, 'verified'::text, v_now;
end;
$$;

alter function app_api_v1.finalize_upload(uuid, text, uuid[], text, text) owner to app_function_owner;
revoke all on function app_api_v1.finalize_upload(uuid, text, uuid[], text, text) from public;

-- 7.9 cancel_upload_reservation
create function app_api_v1.cancel_upload_reservation(
    p_reservation_id uuid
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
    select ur.project_id into v_project_id
    from resource.upload_reservations ur
    where ur.id = p_reservation_id;

    if not found then
        raise exception 'UPLOAD_RESERVATION_NOT_FOUND: Reservation does not exist.'
            using detail = 'UPLOAD_RESERVATION_NOT_FOUND';
    end if;

    v_user_id := internal_api.require_project_member(v_project_id);

    update resource.upload_reservations
    set status = 'cancelled',
        cancelled_at = transaction_timestamp()
    where id = p_reservation_id
      and status in ('reserved', 'uploaded');
end;
$$;

alter function app_api_v1.cancel_upload_reservation(uuid) owner to app_function_owner;
revoke all on function app_api_v1.cancel_upload_reservation(uuid) from public;
