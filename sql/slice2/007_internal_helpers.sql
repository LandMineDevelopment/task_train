-- Slice 2: Phase 6 — Internal Helpers

-- 6.1 Hashing helper
create function internal_api.sha256(p_input text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
    select encode(extensions.digest(p_input::bytea, 'sha256'::text), 'hex');
$$;

alter function internal_api.sha256(text) owner to migration_owner;
revoke all on function internal_api.sha256(text) from public;

-- 6.2 URL normalization (strip fragment, lowercase scheme/host only, preserve path case)
create function internal_api.normalize_url(p_url text)
returns text
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
    v_url text;
    v_scheme text;
    v_rest text;
    v_host text;
    v_path text;
    v_fragment_pos int;
    v_query_pos int;
begin
    v_url := trim(p_url);

    if v_url !~* '^https?://' then
        raise exception 'RESOURCE_FORMAT_INVALID: URL must start with http:// or https://.'
            using detail = 'RESOURCE_FORMAT_INVALID';
    end if;

    -- Strip fragment
    v_fragment_pos := position('#' in v_url);
    if v_fragment_pos > 0 then
        v_url := substr(v_url, 1, v_fragment_pos - 1);
    end if;

    -- Extract and lowercase scheme
    v_scheme := lower(substr(v_url, 1, position('://' in v_url)));
    v_rest := substr(v_url, length(v_scheme) + 1);

    -- Split host from path (lowercase host, preserve path case)
    v_query_pos := position('/' in v_rest);
    if v_query_pos = 0 then
        v_host := lower(v_rest);
        v_path := '';
    else
        v_host := lower(substr(v_rest, 1, v_query_pos - 1));
        v_path := substr(v_rest, v_query_pos);
    end if;

    -- Strip port 80/443 for cleanliness
    v_host := regexp_replace(v_host, ':80$', '');
    v_host := regexp_replace(v_host, ':443$', '');

    return v_scheme || v_host || v_path;
end;
$$;

alter function internal_api.normalize_url(text) owner to migration_owner;
revoke all on function internal_api.normalize_url(text) from public;

create function internal_api.extract_host(p_url text)
returns text
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
    v_url text;
    v_after_scheme text;
    v_host text;
    v_slash_pos int;
begin
    v_url := trim(p_url);
    v_after_scheme := substr(v_url, position('://' in v_url) + 3);
    v_slash_pos := position('/' in v_after_scheme);
    if v_slash_pos = 0 then
        v_host := lower(v_after_scheme);
    else
        v_host := lower(substr(v_after_scheme, 1, v_slash_pos - 1));
    end if;
    v_host := regexp_replace(v_host, ':[0-9]+$', '');
    return v_host;
end;
$$;

alter function internal_api.extract_host(text) owner to migration_owner;
revoke all on function internal_api.extract_host(text) from public;

-- 6.3 Resource membership helper
create function internal_api.require_resource_member(p_resource_id uuid)
returns uuid
language plpgsql
set search_path = pg_catalog, internal_api, resource, project
as $$
declare
    v_user_id uuid;
    v_project_id uuid;
begin
    v_user_id := internal_api.require_authenticated_user();

    select r.project_id into v_project_id
    from resource.resources r
    where r.id = p_resource_id;

    if not found then
        raise exception 'RESOURCE_NOT_FOUND: Resource does not exist or is not visible.'
            using detail = 'RESOURCE_NOT_FOUND';
    end if;

    if not exists (
        select 1 from project.project_memberships
        where project_id = v_project_id
          and user_id = v_user_id
          and status = 'active'
    ) then
        raise exception 'PROJECT_ACCESS_DENIED: Caller lacks active project membership.'
            using detail = 'PROJECT_ACCESS_DENIED';
    end if;

    return v_user_id;
end;
$$;

alter function internal_api.require_resource_member(uuid) owner to migration_owner;
revoke all on function internal_api.require_resource_member(uuid) from public;

-- 6.4 Validate resource tags (project-scoped)
create function internal_api.validate_resource_tags(
    p_project_id uuid,
    p_tag_ids uuid[]
)
returns void
language plpgsql
set search_path = pg_catalog, taxonomy
as $$
declare
    v_tag record;
begin
    if p_tag_ids is null then
        return;
    end if;

    for i in 1..array_length(p_tag_ids, 1) loop
        select t.id, t.project_id, t.status into v_tag
        from taxonomy.tags t
        where t.id = p_tag_ids[i];

        if not found then
            raise exception 'TAG_NOT_FOUND: Tag with id % does not exist.', p_tag_ids[i]
                using detail = 'TAG_NOT_FOUND';
        end if;

        if v_tag.project_id != p_project_id then
            raise exception 'RESOURCE_TAG_PROJECT_MISMATCH: Tag % belongs to a different project.', p_tag_ids[i]
                using detail = 'RESOURCE_TAG_PROJECT_MISMATCH';
        end if;

        if v_tag.status = 'archived' then
            raise exception 'TAG_ARCHIVED: Tag % is archived and cannot be assigned.', p_tag_ids[i]
                using detail = 'TAG_ARCHIVED';
        end if;
    end loop;
end;
$$;

alter function internal_api.validate_resource_tags(uuid, uuid[]) owner to migration_owner;
revoke all on function internal_api.validate_resource_tags(uuid, uuid[]) from public;

-- 6.5 Create resource identity (registry + resource atomically)
create function internal_api.create_resource_identity(
    p_project_id uuid,
    p_resource_type text,
    p_title text,
    p_description text,
    p_created_by_user_id uuid,
    out resource_id uuid,
    out object_id uuid,
    out revision bigint
)
language plpgsql
set search_path = pg_catalog, internal_api, taxonomy, resource
as $$
declare
    v_type_enabled boolean;
    v_user_creatable boolean;
begin
    -- Validate type is enabled and user-creatable
    select rt.enabled, rt.user_creatable into v_type_enabled, v_user_creatable
    from resource.resource_types rt
    where rt.resource_type = p_resource_type;

    if not found then
        raise exception 'RESOURCE_TYPE_INVALID: Resource type % does not exist.', p_resource_type
            using detail = 'RESOURCE_TYPE_INVALID';
    end if;

    if not v_type_enabled then
        raise exception 'RESOURCE_TYPE_INVALID: Resource type % is disabled.', p_resource_type
            using detail = 'RESOURCE_TYPE_INVALID';
    end if;

    if not v_user_creatable then
        raise exception 'RESOURCE_TYPE_INVALID: Resource type % is not user-creatable.', p_resource_type
            using detail = 'RESOURCE_TYPE_INVALID';
    end if;

    -- Create registry object
    object_id := internal_api.register_object(
        p_project_id := p_project_id,
        p_object_type := 'resource',
        p_display_label := p_title,
        p_created_by_user_id := p_created_by_user_id
    );

    -- Create resource
    insert into resource.resources (object_id, project_id, resource_type, title, description, created_by_user_id)
    values (object_id, p_project_id, p_resource_type, trim(p_title), p_description, p_created_by_user_id)
    returning resources.id, resources.revision into resource_id, revision;
end;
$$;

alter function internal_api.create_resource_identity(uuid, text, text, text, uuid) owner to migration_owner;
revoke all on function internal_api.create_resource_identity(uuid, text, text, text, uuid) from public;

-- 6.6 Create text version
create function internal_api.create_text_version(
    p_resource_id uuid,
    p_content text,
    p_text_format text,
    p_language_code text,
    p_change_summary text,
    p_created_by_user_id uuid,
    out resource_version_id uuid,
    out version_object_id uuid,
    out version_number integer,
    out content_hash text,
    out created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, internal_api, taxonomy, resource
as $$
declare
    v_project_id uuid;
    v_content_kind text;
    v_new_number integer;
begin
    -- Validate resource exists and is active
    select r.project_id, r.status into v_project_id
    from resource.resources r
    where r.id = p_resource_id;

    if not found then
        raise exception 'RESOURCE_NOT_FOUND: Resource does not exist.'
            using detail = 'RESOURCE_NOT_FOUND';
    end if;

    if v_project_id is null then
        raise exception 'RESOURCE_NOT_FOUND: Resource does not exist.'
            using detail = 'RESOURCE_NOT_FOUND';
    end if;

    -- Determine content kind from resource type
    select rtc.content_kind into v_content_kind
    from resource.resource_type_content_kinds rtc
    join resource.resources r on r.resource_type = rtc.resource_type
    where r.id = p_resource_id and rtc.content_kind = 'text';

    if not found then
        raise exception 'RESOURCE_CONTENT_KIND_INVALID: Text content is not allowed for this resource type.'
            using detail = 'RESOURCE_CONTENT_KIND_INVALID';
    end if;

    -- Compute hash
    content_hash := internal_api.sha256(p_content);

    -- Lock head and get next version number
    select coalesce(h.current_version_number, 0) + 1 into v_new_number
    from resource.resources r
    left join resource.resource_heads h on h.resource_id = r.id
    where r.id = p_resource_id
    for update of r;

    -- Create registry object for version
    version_object_id := internal_api.register_object(
        p_project_id := v_project_id,
        p_object_type := 'resource_version',
        p_display_label := 'v' || v_new_number || ' of ' || p_resource_id::text,
        p_created_by_user_id := p_created_by_user_id
    );

    -- Create version
    insert into resource.resource_versions (object_id, resource_id, version_number, content_kind, status, content_hash, change_summary, created_by_user_id)
    values (version_object_id, p_resource_id, v_new_number, 'text', 'available', content_hash, p_change_summary, p_created_by_user_id)
    returning resource_versions.id, resource_versions.version_number, resource_versions.created_at into resource_version_id, version_number, created_at;

    -- Create text content
    insert into resource.text_contents (resource_version_id, body_text, text_format, language_code)
    values (resource_version_id, p_content, p_text_format, p_language_code);

    -- Update head
    insert into resource.resource_heads (resource_id, current_version_id, current_version_number)
    values (p_resource_id, resource_version_id, version_number)
    on conflict (resource_id) do update
    set current_version_id = resource_version_id,
        current_version_number = version_number,
        updated_at = transaction_timestamp();

    -- Update resource updated_at
    update resource.resources r
    set updated_at = transaction_timestamp()
    where r.id = p_resource_id;
end;
$$;

alter function internal_api.create_text_version(uuid, text, text, text, text, uuid) owner to migration_owner;
revoke all on function internal_api.create_text_version(uuid, text, text, text, text, uuid) from public;

-- 6.7 Create link version
create function internal_api.create_link_version(
    p_resource_id uuid,
    p_url text,
    p_link_title text,
    p_link_description text,
    p_change_summary text,
    p_created_by_user_id uuid,
    out resource_version_id uuid,
    out version_object_id uuid,
    out version_number integer,
    out normalized_url text,
    out content_hash text,
    out created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, internal_api, taxonomy, resource
as $$
declare
    v_project_id uuid;
    v_host_name text;
    v_canonical text;
    v_new_number integer;
begin
    -- Validate resource
    select r.project_id into v_project_id
    from resource.resources r
    where r.id = p_resource_id;

    if not found then
        raise exception 'RESOURCE_NOT_FOUND: Resource does not exist.'
            using detail = 'RESOURCE_NOT_FOUND';
    end if;

    -- Normalize URL
    normalized_url := internal_api.normalize_url(p_url);
    v_host_name := internal_api.extract_host(p_url);

    -- Build canonical hash input
    v_canonical := normalized_url || '|' || coalesce(p_link_title, '') || '|' || coalesce(p_link_description, '');
    content_hash := internal_api.sha256(v_canonical);

    -- Lock and get next version
    select coalesce(h.current_version_number, 0) + 1 into v_new_number
    from resource.resources r
    left join resource.resource_heads h on h.resource_id = r.id
    where r.id = p_resource_id
    for update of r;

    -- Registry for version
    version_object_id := internal_api.register_object(
        p_project_id := v_project_id,
        p_object_type := 'resource_version',
        p_display_label := 'v' || v_new_number || ' of ' || p_resource_id::text,
        p_created_by_user_id := p_created_by_user_id
    );

    -- Create version
    insert into resource.resource_versions (object_id, resource_id, version_number, content_kind, status, content_hash, change_summary, created_by_user_id)
    values (version_object_id, p_resource_id, v_new_number, 'link', 'available', content_hash, p_change_summary, p_created_by_user_id)
    returning resource_versions.id, resource_versions.version_number, resource_versions.created_at into resource_version_id, version_number, created_at;

    -- Create link content
    insert into resource.link_contents (resource_version_id, url, normalized_url, host_name, link_title, link_description)
    values (resource_version_id, p_url, normalized_url, v_host_name, p_link_title, p_link_description);

    -- Update head
    insert into resource.resource_heads (resource_id, current_version_id, current_version_number)
    values (p_resource_id, resource_version_id, version_number)
    on conflict (resource_id) do update
    set current_version_id = resource_version_id,
        current_version_number = version_number,
        updated_at = transaction_timestamp();

    -- Update resource updated_at
    update resource.resources r
    set updated_at = transaction_timestamp()
    where r.id = p_resource_id;
end;
$$;

alter function internal_api.create_link_version(uuid, text, text, text, text, uuid) owner to migration_owner;
revoke all on function internal_api.create_link_version(uuid, text, text, text, text, uuid) from public;

-- 6.8 Create file version (from finalized upload)
create function internal_api.create_file_version(
    p_resource_id uuid,
    p_storage_object_id uuid,
    p_original_filename text,
    p_media_type text,
    p_byte_size bigint,
    p_content_hash text,
    p_change_summary text,
    p_created_by_user_id uuid,
    out resource_version_id uuid,
    out version_object_id uuid,
    out version_number integer,
    out created_at timestamptz
)
language plpgsql
set search_path = pg_catalog, internal_api, taxonomy, resource
as $$
declare
    v_project_id uuid;
    v_new_number integer;
begin
    -- Validate resource
    select r.project_id into v_project_id
    from resource.resources r
    where r.id = p_resource_id;

    if not found then
        raise exception 'RESOURCE_NOT_FOUND: Resource does not exist.'
            using detail = 'RESOURCE_NOT_FOUND';
    end if;

    -- Lock and get next version
    select coalesce(h.current_version_number, 0) + 1 into v_new_number
    from resource.resources r
    left join resource.resource_heads h on h.resource_id = r.id
    where r.id = p_resource_id
    for update of r;

    -- Registry for version
    version_object_id := internal_api.register_object(
        p_project_id := v_project_id,
        p_object_type := 'resource_version',
        p_display_label := 'v' || v_new_number || ' of ' || p_resource_id::text,
        p_created_by_user_id := p_created_by_user_id
    );

    -- Create version
    insert into resource.resource_versions (object_id, resource_id, version_number, content_kind, status, content_hash, change_summary, created_by_user_id)
    values (version_object_id, p_resource_id, v_new_number, 'file', 'available', p_content_hash, p_change_summary, p_created_by_user_id)
    returning resource_versions.id, resource_versions.version_number, resource_versions.created_at into resource_version_id, version_number, created_at;

    -- Create file content
    insert into resource.file_contents (resource_version_id, storage_object_id, original_filename, media_type, byte_size)
    values (resource_version_id, p_storage_object_id, p_original_filename, p_media_type, p_byte_size);

    -- Update head
    insert into resource.resource_heads (resource_id, current_version_id, current_version_number)
    values (p_resource_id, resource_version_id, version_number)
    on conflict (resource_id) do update
    set current_version_id = resource_version_id,
        current_version_number = version_number,
        updated_at = transaction_timestamp();

    -- Update resource updated_at
    update resource.resources r
    set updated_at = transaction_timestamp()
    where r.id = p_resource_id;
end;
$$;

alter function internal_api.create_file_version(uuid, uuid, text, text, bigint, text, text, uuid) owner to migration_owner;
revoke all on function internal_api.create_file_version(uuid, uuid, text, text, bigint, text, text, uuid) from public;

-- 6.9 Rebuild resource search document
create function internal_api.rebuild_resource_search_document(
    p_resource_id uuid
)
returns void
language plpgsql
set search_path = pg_catalog, resource
as $$
declare
    v_head_id uuid;
    v_project_id uuid;
    v_resource_type text;
    v_title text;
    v_description text;
    v_content_text text;
    v_filename_text text;
    v_link_text text;
    v_vector tsvector;
begin
    -- Get current head
    select h.current_version_id, r.project_id, r.resource_type, r.title, r.description
    into v_head_id, v_project_id, v_resource_type, v_title, v_description
    from resource.resources r
    left join resource.resource_heads h on h.resource_id = r.id
    where r.id = p_resource_id;

    if v_head_id is null then
        return;
    end if;

    -- Get text content
    select tc.body_text into v_content_text
    from resource.text_contents tc
    where tc.resource_version_id = v_head_id;

    -- Get file name
    select fc.original_filename into v_filename_text
    from resource.file_contents fc
    where fc.resource_version_id = v_head_id;

    -- Get link text
    select lc.url || ' ' || coalesce(lc.link_title, '') || ' ' || coalesce(lc.link_description, '')
    into v_link_text
    from resource.link_contents lc
    where lc.resource_version_id = v_head_id;

    -- Build weighted vector
    v_vector :=
        setweight(to_tsvector('simple', coalesce(v_title, '')), 'A') ||
        setweight(to_tsvector('simple', coalesce(v_description, '') || ' ' || coalesce(v_content_text, '')), 'B') ||
        setweight(to_tsvector('simple', coalesce(v_filename_text, '') || ' ' || coalesce(v_link_text, '')), 'C');

    -- Upsert search document
    insert into resource.resource_search_documents (resource_id, resource_version_id, project_id, resource_type, title_text, description_text, content_text, filename_text, link_text, search_vector)
    values (p_resource_id, v_head_id, v_project_id, v_resource_type, v_title, v_description, v_content_text, v_filename_text, v_link_text, v_vector)
    on conflict (resource_id) do update
    set resource_version_id = v_head_id,
        project_id = v_project_id,
        resource_type = v_resource_type,
        title_text = v_title,
        description_text = v_description,
        content_text = v_content_text,
        filename_text = v_filename_text,
        link_text = v_link_text,
        search_vector = v_vector,
        updated_at = transaction_timestamp();
end;
$$;

alter function internal_api.rebuild_resource_search_document(uuid) owner to migration_owner;
revoke all on function internal_api.rebuild_resource_search_document(uuid) from public;

-- 6.10 Record upload observation (restricted gateway function)
create function internal_api.record_upload_observation(
    p_reservation_id uuid,
    p_observed_content_hash text,
    p_observed_byte_size bigint,
    p_observed_media_type text,
    p_provider_version text default null
)
returns table (
    reservation_id uuid,
    status text,
    object_key text,
    uploaded_at timestamptz
)
language plpgsql
set search_path = pg_catalog, resource
as $$
begin
    if p_observed_content_hash is null or length(p_observed_content_hash) != 64 then
        raise exception 'UPLOAD_HASH_INVALID: Observed SHA-256 must be exactly 64 lowercase hex characters.'
            using detail = 'UPLOAD_HASH_INVALID';
    end if;

    if p_observed_byte_size is null or p_observed_byte_size < 0 then
        raise exception 'UPLOAD_SIZE_MISMATCH: Observed byte size is invalid.'
            using detail = 'UPLOAD_SIZE_MISMATCH';
    end if;

    update resource.upload_reservations ur
    set status = 'uploaded',
        observed_content_hash = p_observed_content_hash,
        observed_byte_size = p_observed_byte_size,
        observed_media_type = p_observed_media_type,
        provider_version = p_provider_version,
        uploaded_at = transaction_timestamp()
    where ur.id = p_reservation_id
      and ur.status = 'reserved';

    if not found then
        if not exists (select 1 from resource.upload_reservations where id = p_reservation_id) then
            raise exception 'UPLOAD_RESERVATION_NOT_FOUND: Reservation does not exist.'
                using detail = 'UPLOAD_RESERVATION_NOT_FOUND';
        else
            raise exception 'UPLOAD_RESERVATION_FINALIZED: Reservation has already been processed.'
                using detail = 'UPLOAD_RESERVATION_FINALIZED';
        end if;
    end if;

    return query
    select ur.id, ur.status, ur.object_key, ur.uploaded_at
    from resource.upload_reservations ur
    where ur.id = p_reservation_id;
end;
$$;

alter function internal_api.record_upload_observation(uuid, text, bigint, text, text) owner to migration_owner;
revoke all on function internal_api.record_upload_observation(uuid, text, bigint, text, text) from public;

-- 6.11 Consume download request (restricted gateway function)
create function internal_api.consume_download_request(
    p_download_request_id uuid
)
returns table (
    download_request_id uuid,
    storage_object_id uuid,
    provider text,
    bucket text,
    object_key text,
    status text
)
language plpgsql
set search_path = pg_catalog, resource
as $$
begin
    update resource.download_requests dr
    set status = 'consumed',
        consumed_at = transaction_timestamp()
    where dr.id = p_download_request_id
      and dr.status = 'created'
      and dr.expires_at > transaction_timestamp();

    if not found then
        if not exists (select 1 from resource.download_requests where id = p_download_request_id) then
            raise exception 'DOWNLOAD_NOT_ALLOWED: Download request does not exist.'
                using detail = 'DOWNLOAD_NOT_ALLOWED';
        else
            raise exception 'DOWNLOAD_REQUEST_EXPIRED: Download request has expired or been consumed.'
                using detail = 'DOWNLOAD_REQUEST_EXPIRED';
        end if;
    end if;

    return query
    select dr.id, so.id, so.provider, so.bucket, so.object_key, dr.status
    from resource.download_requests dr
    join resource.storage_objects so on so.id = dr.storage_object_id
    where dr.id = p_download_request_id;
end;
$$;

alter function internal_api.consume_download_request(uuid) owner to migration_owner;
revoke all on function internal_api.consume_download_request(uuid) from public;

-- 6.12 Expire stale upload reservations
create function internal_api.expire_upload_reservations()
returns table (reservation_id uuid, expired_at timestamptz)
language plpgsql
set search_path = pg_catalog, resource
as $$
begin
    return query
    update resource.upload_reservations ur
    set status = 'expired'
    where ur.status in ('reserved', 'uploaded')
      and ur.expires_at <= transaction_timestamp()
    returning ur.id, transaction_timestamp();
end;
$$;

alter function internal_api.expire_upload_reservations() owner to migration_owner;
revoke all on function internal_api.expire_upload_reservations() from public;

-- 6.13 Expire stale download requests
create function internal_api.expire_download_requests()
returns table (request_id uuid, expired_at timestamptz)
language plpgsql
set search_path = pg_catalog, resource
as $$
begin
    return query
    update resource.download_requests dr
    set status = 'expired'
    where dr.status = 'created'
      and dr.expires_at <= transaction_timestamp()
    returning dr.id, transaction_timestamp();
end;
$$;

alter function internal_api.expire_download_requests() owner to migration_owner;
revoke all on function internal_api.expire_download_requests() from public;

-- 6.14 Integrity: verify resource registry alignment
create function internal_api.verify_resource_registry_integrity(
    p_project_id uuid default null
)
returns table (issue_type text, object_id uuid, resource_id uuid, details text)
language plpgsql
set search_path = pg_catalog, resource, taxonomy
as $$
begin
    -- Resources without matching registry rows
    return query
    select 'missing_registry'::text, null::uuid, r.id, 'Resource has no taxonomy.object_registry row'
    from resource.resources r
    left join taxonomy.object_registry o on o.id = r.object_id
    where o.id is null
      and (p_project_id is null or r.project_id = p_project_id);

    -- Registry rows with wrong type
    return query
    select 'wrong_registry_type'::text, o.id, r.id, 'Registry object_type should be resource but is ' || o.object_type
    from resource.resources r
    join taxonomy.object_registry o on o.id = r.object_id
    where o.object_type != 'resource'
      and (p_project_id is null or r.project_id = p_project_id);

    -- Registry-project mismatch
    return query
    select 'project_mismatch'::text, o.id, r.id, 'Registry project does not match resource project'
    from resource.resources r
    join taxonomy.object_registry o on o.id = r.object_id
    where o.project_id != r.project_id
      and (p_project_id is null or r.project_id = p_project_id);
end;
$$;

alter function internal_api.verify_resource_registry_integrity(uuid) owner to migration_owner;
revoke all on function internal_api.verify_resource_registry_integrity(uuid) from public;

-- 6.15 Integrity: verify resource head integrity
create function internal_api.verify_resource_head_integrity(
    p_project_id uuid default null
)
returns table (issue_type text, resource_id uuid, details text)
language plpgsql
set search_path = pg_catalog, resource
as $$
begin
    -- Heads whose version is not available
    return query
    select 'head_not_available'::text, h.resource_id, 'Head version status is not available'
    from resource.resource_heads h
    join resource.resource_versions v on v.id = h.current_version_id
    where v.status != 'available'
      and (p_project_id is null or exists (
        select 1 from resource.resources r where r.id = h.resource_id
        and (p_project_id is null or r.project_id = p_project_id)
      ));

    -- Heads with version number mismatch
    return query
    select 'head_number_mismatch'::text, h.resource_id, 'Head version_number does not match version row'
    from resource.resource_heads h
    join resource.resource_versions v on v.id = h.current_version_id
    where h.current_version_number != v.version_number
      and (p_project_id is null or exists (
        select 1 from resource.resources r where r.id = h.resource_id
        and (p_project_id is null or r.project_id = p_project_id)
      ));

    -- Resources without heads
    return query
    select 'missing_head'::text, r.id, 'Active resource has no head row'
    from resource.resources r
    left join resource.resource_heads h on h.resource_id = r.id
    where h.resource_id is null
      and r.status = 'active'
      and (p_project_id is null or r.project_id = p_project_id);
end;
$$;

alter function internal_api.verify_resource_head_integrity(uuid) owner to migration_owner;
revoke all on function internal_api.verify_resource_head_integrity(uuid) from public;

-- 6.16 Integrity: verify exactly-one-content per available version
create function internal_api.verify_resource_content_integrity(
    p_project_id uuid default null
)
returns table (issue_type text, resource_version_id uuid, details text)
language plpgsql
set search_path = pg_catalog, resource
as $$
begin
    -- Versions with no typed content
    return query
    select 'missing_content'::text, v.id, 'Available version has no typed content row'
    from resource.resource_versions v
    where v.status = 'available'
      and not exists (select 1 from resource.text_contents tc where tc.resource_version_id = v.id)
      and not exists (select 1 from resource.file_contents fc where fc.resource_version_id = v.id)
      and not exists (select 1 from resource.link_contents lc where lc.resource_version_id = v.id)
      and (p_project_id is null or exists (
          select 1 from resource.resources r where r.id = v.resource_id
          and (p_project_id is null or r.project_id = p_project_id)
      ));

    -- Versions with multiple typed content rows
    return query
    select 'multiple_content'::text, v.id, 'Available version has multiple typed content rows'
    from resource.resource_versions v
    where v.status = 'available'
      and (
          (select count(*) from resource.text_contents tc where tc.resource_version_id = v.id)
        + (select count(*) from resource.file_contents fc where fc.resource_version_id = v.id)
        + (select count(*) from resource.link_contents lc where lc.resource_version_id = v.id)
      ) > 1
      and (p_project_id is null or exists (
          select 1 from resource.resources r where r.id = v.resource_id
          and (p_project_id is null or r.project_id = p_project_id)
      ));
end;
$$;

alter function internal_api.verify_resource_content_integrity(uuid) owner to migration_owner;
revoke all on function internal_api.verify_resource_content_integrity(uuid) from public;

-- 6.17 Generate upload object key
create function internal_api.generate_upload_key(
    p_project_id uuid,
    p_reservation_id uuid,
    p_original_filename text
)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
    select 'projects/' || p_project_id::text || '/uploads/' || p_reservation_id::text || '/' || p_original_filename;
$$;

alter function internal_api.generate_upload_key(uuid, uuid, text) owner to migration_owner;
revoke all on function internal_api.generate_upload_key(uuid, uuid, text) from public;

-- 6.18 Create storage object record
create function internal_api.create_storage_object(
    p_project_id uuid,
    p_provider text,
    p_bucket text,
    p_object_key text,
    p_content_hash text,
    p_byte_size bigint,
    p_media_type text,
    p_created_by_user_id uuid,
    p_provider_version text default null,
    out storage_object_id uuid
)
language plpgsql
set search_path = pg_catalog, resource
as $$
begin
    insert into resource.storage_objects (project_id, provider, bucket, object_key, content_hash, byte_size, media_type, verification_status, created_by_user_id, provider_version)
    values (p_project_id, p_provider, p_bucket, p_object_key, p_content_hash, p_byte_size, p_media_type, 'verified', p_created_by_user_id, p_provider_version)
    returning id into storage_object_id;
end;
$$;

alter function internal_api.create_storage_object(uuid, text, text, text, text, bigint, text, uuid, text) owner to migration_owner;
revoke all on function internal_api.create_storage_object(uuid, text, text, text, text, bigint, text, uuid, text) from public;
