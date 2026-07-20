-- Slice 2: Phase 7 — Public API Functions (Part 2: Reads, Search, Archive, Download)

-- 7.10 get_resource
create function app_api_v1.get_resource(
    p_resource_id uuid,
    p_version_number integer default null
)
returns table (
    resource_id uuid,
    resource_object_id uuid,
    project_id uuid,
    resource_type text,
    title text,
    description text,
    status text,
    resource_revision bigint,
    resource_version_id uuid,
    version_object_id uuid,
    version_number integer,
    content_kind text,
    content_hash text,
    text_content text,
    text_format text,
    language_code text,
    original_filename text,
    media_type text,
    byte_size bigint,
    external_url text,
    storage_verification_status text,
    created_at timestamptz,
    updated_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
    v_version_id uuid;
begin
    v_user_id := internal_api.require_resource_member(p_resource_id);

    select r.project_id into v_project_id
    from resource.resources r where r.id = p_resource_id;

    -- Determine which version to read
    if p_version_number is null then
        select h.current_version_id into v_version_id
        from resource.resource_heads h
        where h.resource_id = p_resource_id;
    else
        select v.id into v_version_id
        from resource.resource_versions v
        where v.resource_id = p_resource_id and v.version_number = p_version_number;
    end if;

    if v_version_id is null then
        raise exception 'RESOURCE_VERSION_NOT_FOUND: Requested version does not exist.'
            using detail = 'RESOURCE_VERSION_NOT_FOUND';
    end if;

    return query
    select
        r.id,
        r.object_id,
        r.project_id,
        r.resource_type,
        r.title,
        r.description,
        r.status,
        r.revision,
        v.id,
        v.object_id,
        v.version_number,
        v.content_kind,
        v.content_hash,
        tc.body_text,
        tc.text_format,
        tc.language_code,
        fc.original_filename,
        fc.media_type,
        fc.byte_size,
        lc.url,
        so.verification_status,
        v.created_at,
        r.updated_at
    from resource.resources r
    join resource.resource_versions v on v.id = v_version_id
    left join resource.text_contents tc on tc.resource_version_id = v.id
    left join resource.file_contents fc on fc.resource_version_id = v.id
    left join resource.link_contents lc on lc.resource_version_id = v.id
    left join resource.storage_objects so on so.id = fc.storage_object_id
    where r.id = p_resource_id;
end;
$$;

alter function app_api_v1.get_resource(uuid, integer) owner to app_function_owner;
revoke all on function app_api_v1.get_resource(uuid, integer) from public;

-- 7.11 list_resource_versions
create function app_api_v1.list_resource_versions(
    p_resource_id uuid,
    p_limit integer default 100,
    p_offset integer default 0
)
returns table (
    resource_version_id uuid,
    version_object_id uuid,
    version_number integer,
    content_kind text,
    status text,
    content_hash text,
    change_summary text,
    created_by_user_id uuid,
    created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
begin
    perform internal_api.require_resource_member(p_resource_id);

    return query
    select v.id, v.object_id, v.version_number, v.content_kind, v.status,
           v.content_hash, v.change_summary, v.created_by_user_id, v.created_at
    from resource.resource_versions v
    where v.resource_id = p_resource_id
    order by v.version_number desc
    limit least(p_limit, 200)
    offset p_offset;
end;
$$;

alter function app_api_v1.list_resource_versions(uuid, integer, integer) owner to app_function_owner;
revoke all on function app_api_v1.list_resource_versions(uuid, integer, integer) from public;

-- 7.12 search_resources
create function app_api_v1.search_resources(
    p_project_id uuid,
    p_query text default null,
    p_resource_types text[] default null,
    p_required_tag_ids uuid[] default null,
    p_any_tag_ids uuid[] default null,
    p_excluded_tag_ids uuid[] default null,
    p_created_by_user_id uuid default null,
    p_created_after timestamptz default null,
    p_created_before timestamptz default null,
    p_include_archived boolean default false,
    p_limit integer default 50,
    p_offset integer default 0
)
returns table (
    resource_id uuid,
    resource_object_id uuid,
    resource_type text,
    title text,
    description text,
    status text,
    current_version_number integer,
    content_kind text,
    media_type text,
    original_filename text,
    search_rank real,
    created_at timestamptz,
    updated_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_max_limit integer := 200;
    v_limit integer;
begin
    v_user_id := internal_api.require_project_member(p_project_id);
    v_limit := least(p_limit, v_max_limit);

    return query
    select
        r.id,
        r.object_id,
        r.resource_type,
        r.title,
        r.description,
        r.status,
        h.current_version_number,
        v.content_kind,
        coalesce(fc.media_type, ''),
        coalesce(fc.original_filename, ''),
        case when p_query is not null and length(trim(p_query)) > 0
            then ts_rank(sd.search_vector, plainto_tsquery('simple', p_query))
            else 0::real
        end,
        r.created_at,
        r.updated_at
    from resource.resources r
    join resource.resource_heads h on h.resource_id = r.id
    join resource.resource_versions v on v.id = h.current_version_id
    left join resource.file_contents fc on fc.resource_version_id = h.current_version_id
    left join resource.resource_search_documents sd on sd.resource_id = r.id
    where r.project_id = p_project_id
      -- Status filter
      and (p_include_archived or r.status = 'active')
      -- Type filter
      and (p_resource_types is null or r.resource_type = any(p_resource_types))
      -- Creator filter
      and (p_created_by_user_id is null or r.created_by_user_id = p_created_by_user_id)
      -- Date range
      and (p_created_after is null or r.created_at >= p_created_after)
      and (p_created_before is null or r.created_at <= p_created_before)
      -- Text query
      and (p_query is null or length(trim(p_query)) = 0 or sd.search_vector @@ plainto_tsquery('simple', p_query))
      -- Required tags
      and (p_required_tag_ids is null or (
          select count(distinct ta.tag_id) = array_length(p_required_tag_ids, 1)
          from taxonomy.tag_assignments ta
          where ta.object_id = r.object_id
            and ta.status in ('active', 'confirmed')
            and ta.tag_id = any(p_required_tag_ids)
      ))
      -- Any tags
      and (p_any_tag_ids is null or exists (
          select 1 from taxonomy.tag_assignments ta
          where ta.object_id = r.object_id
            and ta.status in ('active', 'confirmed')
            and ta.tag_id = any(p_any_tag_ids)
      ))
      -- Excluded tags
      and (p_excluded_tag_ids is null or not exists (
          select 1 from taxonomy.tag_assignments ta
          where ta.object_id = r.object_id
            and ta.status in ('active', 'confirmed')
            and ta.tag_id = any(p_excluded_tag_ids)
      ))
    order by
        case when p_query is not null and length(trim(p_query)) > 0
            then ts_rank(sd.search_vector, plainto_tsquery('simple', p_query))
            else 0::real
        end desc,
        r.updated_at desc,
        r.id asc
    limit v_limit
    offset p_offset;
end;
$$;

alter function app_api_v1.search_resources(uuid, text, text[], uuid[], uuid[], uuid[], uuid, timestamptz, timestamptz, boolean, integer, integer) owner to app_function_owner;
revoke all on function app_api_v1.search_resources(uuid, text, text[], uuid[], uuid[], uuid[], uuid, timestamptz, timestamptz, boolean, integer, integer) from public;

-- 7.13 archive_resource
create function app_api_v1.archive_resource(
    p_resource_id uuid,
    p_expected_revision bigint
)
returns table (
    resource_id uuid,
    revision bigint,
    status text,
    archived_at timestamptz
)
language plpgsql
set search_path = pg_catalog, app_api_v1
security definer
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
    v_object_id uuid;
begin
    v_user_id := internal_api.require_resource_member(p_resource_id);

    select r.project_id, r.object_id into v_project_id, v_object_id
    from resource.resources r where r.id = p_resource_id;

    if exists (select 1 from resource.resources r2 where r2.id = p_resource_id and r2.status = 'archived') then
        raise exception 'RESOURCE_ARCHIVED: Resource is already archived.'
            using detail = 'RESOURCE_ARCHIVED';
    end if;

    update resource.resources r
    set status = 'archived',
        archived_at = transaction_timestamp(),
        revision = r.revision + 1,
        updated_at = transaction_timestamp()
    where r.id = p_resource_id
      and r.revision = p_expected_revision;

    if not found then
        raise exception 'RESOURCE_REVISION_CONFLICT: Expected revision did not match current revision.'
            using detail = 'RESOURCE_REVISION_CONFLICT';
    end if;

    -- Rebuild search (removes from search results)
    perform internal_api.rebuild_resource_search_document(p_resource_id);

    return query
    select r.id, r.revision, r.status, r.archived_at
    from resource.resources r
    where r.id = p_resource_id;
end;
$$;

alter function app_api_v1.archive_resource(uuid, bigint) owner to app_function_owner;
revoke all on function app_api_v1.archive_resource(uuid, bigint) from public;

-- 7.14 restore_resource
create function app_api_v1.restore_resource(
    p_resource_id uuid,
    p_expected_revision bigint
)
returns table (
    resource_id uuid,
    revision bigint,
    status text,
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

    if not exists (select 1 from resource.resources r2 where r2.id = p_resource_id and r2.status = 'archived') then
        raise exception 'RESOURCE_ARCHIVED: Resource is not archived.'
            using detail = 'RESOURCE_ARCHIVED';
    end if;

    update resource.resources r
    set status = 'active',
        archived_at = null,
        revision = r.revision + 1,
        updated_at = transaction_timestamp()
    where r.id = p_resource_id
      and r.revision = p_expected_revision
      and r.status = 'archived';

    if not found then
        raise exception 'RESOURCE_REVISION_CONFLICT: Expected revision did not match current revision.'
            using detail = 'RESOURCE_REVISION_CONFLICT';
    end if;

    -- Rebuild search (restores to search results)
    perform internal_api.rebuild_resource_search_document(p_resource_id);

    return query
    select r.id, r.revision, r.status, r.updated_at
    from resource.resources r
    where r.id = p_resource_id;
end;
$$;

alter function app_api_v1.restore_resource(uuid, bigint) owner to app_function_owner;
revoke all on function app_api_v1.restore_resource(uuid, bigint) from public;

-- 7.15 create_resource_download_request
create function app_api_v1.create_resource_download_request(
    p_resource_id uuid,
    p_version_number integer default null
)
returns table (
    download_request_id uuid,
    storage_object_id uuid,
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
    v_version_id uuid;
    v_storage_object_id uuid;
    v_request_id uuid;
    v_project_id uuid;
    v_expires_at timestamptz;
begin
    v_user_id := internal_api.require_resource_member(p_resource_id);

    select r.project_id into v_project_id
    from resource.resources r where r.id = p_resource_id;

    -- Determine version
    if p_version_number is null then
        select h.current_version_id into v_version_id
        from resource.resource_heads h
        where h.resource_id = p_resource_id;
    else
        select v.id into v_version_id
        from resource.resource_versions v
        where v.resource_id = p_resource_id and v.version_number = p_version_number;
    end if;

    if v_version_id is null then
        raise exception 'RESOURCE_VERSION_NOT_FOUND: Requested version does not exist.'
            using detail = 'RESOURCE_VERSION_NOT_FOUND';
    end if;

    -- Verify it's a file version with a storage object
    select fc.storage_object_id into v_storage_object_id
    from resource.file_contents fc
    where fc.resource_version_id = v_version_id;

    if not found then
        raise exception 'DOWNLOAD_NOT_ALLOWED: Requested version is not a file resource.'
            using detail = 'DOWNLOAD_NOT_ALLOWED';
    end if;

    -- Create download request
    v_request_id := gen_random_uuid();
    v_expires_at := transaction_timestamp() + interval '5 minutes';

    insert into resource.download_requests (id, project_id, resource_version_id, storage_object_id, requested_by_user_id, expires_at)
    values (v_request_id, v_project_id, v_version_id, v_storage_object_id, v_user_id, v_expires_at);

    return query
    select dr.id, so.id, so.provider, so.bucket, so.object_key, dr.expires_at
    from resource.download_requests dr
    join resource.storage_objects so on so.id = dr.storage_object_id
    where dr.id = v_request_id;
end;
$$;

alter function app_api_v1.create_resource_download_request(uuid, integer) owner to app_function_owner;
revoke all on function app_api_v1.create_resource_download_request(uuid, integer) from public;
