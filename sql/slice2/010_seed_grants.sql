-- Slice 2: Phase 8–10 — Seed Data, Operator APIs, Grants

-- 8.1 Add resource object types to registry
insert into taxonomy.object_types (object_type, native_schema, native_table, display_name, taggable, relatable, searchable)
values
    ('resource',         'resource', 'resources',          'Resource',         true, true, true),
    ('resource_version', 'resource', 'resource_versions',  'Resource Version', false, false, false)
on conflict (object_type) do nothing;

-- 8.2 Operator API reserved functions (call internal helpers, not yet granted)
create function operator_api_v1.search_resources(
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
language sql
set search_path = pg_catalog, operator_api_v1
security definer
as $$
    select * from app_api_v1.search_resources(
        p_project_id, p_query, p_resource_types,
        p_required_tag_ids, p_any_tag_ids, p_excluded_tag_ids,
        p_created_by_user_id, p_created_after, p_created_before,
        p_include_archived, p_limit, p_offset
    );
$$;

alter function operator_api_v1.search_resources(uuid, text, text[], uuid[], uuid[], uuid[], uuid, timestamptz, timestamptz, boolean, integer, integer) owner to app_function_owner;
revoke all on function operator_api_v1.search_resources(uuid, text, text[], uuid[], uuid[], uuid[], uuid, timestamptz, timestamptz, boolean, integer, integer) from public;

create function operator_api_v1.get_resource(
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
language sql
set search_path = pg_catalog, operator_api_v1
security definer
as $$
    select * from app_api_v1.get_resource(p_resource_id, p_version_number);
$$;

alter function operator_api_v1.get_resource(uuid, integer) owner to app_function_owner;
revoke all on function operator_api_v1.get_resource(uuid, integer) from public;

create function operator_api_v1.create_note(
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
language sql
set search_path = pg_catalog, operator_api_v1
security definer
as $$
    select * from app_api_v1.create_note(
        p_project_id, p_title, p_content, p_text_format,
        p_description, p_tag_ids, p_idempotency_key
    );
$$;

alter function operator_api_v1.create_note(uuid, text, text, text, text, uuid[], text) owner to app_function_owner;
revoke all on function operator_api_v1.create_note(uuid, text, text, text, text, uuid[], text) from public;

create function operator_api_v1.update_text_resource(
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
language sql
set search_path = pg_catalog, operator_api_v1
security definer
as $$
    select * from app_api_v1.update_text_resource(
        p_resource_id, p_expected_version_number, p_content, p_text_format,
        p_language_code, p_change_summary, p_idempotency_key
    );
$$;

alter function operator_api_v1.update_text_resource(uuid, integer, text, text, text, text, text) owner to app_function_owner;
revoke all on function operator_api_v1.update_text_resource(uuid, integer, text, text, text, text, text) from public;

-- 9. Grants and permissions

-- Grant USAGE on resource schema to function owner
grant usage on schema resource to app_function_owner;

-- Grant DML on resource tables to app_function_owner (for SECURITY DEFINER functions)
grant select, insert, update, delete on resource.resource_types to app_function_owner;
grant select, insert, update, delete on resource.resource_type_content_kinds to app_function_owner;
grant select, insert, update on resource.resources to app_function_owner;
grant select, insert, update on resource.resource_versions to app_function_owner;
grant select, insert, update on resource.resource_heads to app_function_owner;
grant select, insert, update, delete on resource.text_contents to app_function_owner;
grant select, insert, update on resource.storage_objects to app_function_owner;
grant select, insert, update, delete on resource.file_contents to app_function_owner;
grant select, insert, update, delete on resource.link_contents to app_function_owner;
grant select, insert, update on resource.upload_reservations to app_function_owner;
grant select, insert, update on resource.download_requests to app_function_owner;
grant select, insert, update on resource.resource_search_documents to app_function_owner;

-- Grant EXECUTE on new internal_api functions to app_function_owner
grant execute on function internal_api.sha256(text) to app_function_owner;
grant execute on function internal_api.normalize_url(text) to app_function_owner;
grant execute on function internal_api.extract_host(text) to app_function_owner;
grant execute on function internal_api.require_resource_member(uuid) to app_function_owner;
grant execute on function internal_api.validate_resource_tags(uuid, uuid[]) to app_function_owner;
grant execute on function internal_api.create_resource_identity(uuid, text, text, text, uuid) to app_function_owner;
grant execute on function internal_api.create_text_version(uuid, text, text, text, text, uuid) to app_function_owner;
grant execute on function internal_api.create_link_version(uuid, text, text, text, text, uuid) to app_function_owner;
grant execute on function internal_api.create_file_version(uuid, uuid, text, text, bigint, text, text, uuid) to app_function_owner;
grant execute on function internal_api.rebuild_resource_search_document(uuid) to app_function_owner;
grant execute on function internal_api.record_upload_observation(uuid, text, bigint, text, text) to app_function_owner;
grant execute on function internal_api.consume_download_request(uuid) to app_function_owner;
grant execute on function internal_api.expire_upload_reservations() to app_function_owner;
grant execute on function internal_api.expire_download_requests() to app_function_owner;
grant execute on function internal_api.verify_resource_registry_integrity(uuid) to app_function_owner;
grant execute on function internal_api.verify_resource_head_integrity(uuid) to app_function_owner;
grant execute on function internal_api.verify_resource_content_integrity(uuid) to app_function_owner;
grant execute on function internal_api.generate_upload_key(uuid, uuid, text) to app_function_owner;
grant execute on function internal_api.create_storage_object(uuid, text, text, text, text, bigint, text, uuid, text) to app_function_owner;

-- Storage gateway receives EXECUTE on specific functions
grant execute on function internal_api.record_upload_observation(uuid, text, bigint, text, text) to storage_gateway;
grant execute on function internal_api.consume_download_request(uuid) to storage_gateway;

-- Resource reconciler receives EXECUTE on integrity/reconciliation functions
grant execute on function internal_api.expire_upload_reservations() to resource_reconciler;
grant execute on function internal_api.expire_download_requests() to resource_reconciler;
grant execute on function internal_api.verify_resource_registry_integrity(uuid) to resource_reconciler;
grant execute on function internal_api.verify_resource_head_integrity(uuid) to resource_reconciler;
grant execute on function internal_api.verify_resource_content_integrity(uuid) to resource_reconciler;
grant usage on schema resource to resource_reconciler;
grant select on resource.storage_objects to resource_reconciler;

-- Grant EXECUTE on app_api_v1 functions to PostgREST roles
grant execute on function app_api_v1.create_note(uuid, text, text, text, text, uuid[], text) to authenticated, anon, service_role;
grant execute on function app_api_v1.update_text_resource(uuid, integer, text, text, text, text, text) to authenticated, anon, service_role;
grant execute on function app_api_v1.create_link_resource(uuid, text, text, text, text, text, uuid[], text) to authenticated, anon, service_role;
grant execute on function app_api_v1.update_link_resource(uuid, integer, text, text, text, text, text) to authenticated, anon, service_role;
grant execute on function app_api_v1.update_resource_metadata(uuid, bigint, boolean, text, boolean, text) to authenticated, anon, service_role;
grant execute on function app_api_v1.create_file_resource_upload_reservation(uuid, text, text, text, text, bigint, text) to authenticated, anon, service_role;
grant execute on function app_api_v1.create_file_version_upload_reservation(uuid, integer, text, text, bigint, text) to authenticated, anon, service_role;
grant execute on function app_api_v1.finalize_upload(uuid, text, uuid[], text, text) to authenticated, anon, service_role;
grant execute on function app_api_v1.cancel_upload_reservation(uuid) to authenticated, anon, service_role;
grant execute on function app_api_v1.get_resource(uuid, integer) to authenticated, anon, service_role;
grant execute on function app_api_v1.list_resource_versions(uuid, integer, integer) to authenticated, anon, service_role;
grant execute on function app_api_v1.search_resources(uuid, text, text[], uuid[], uuid[], uuid[], uuid, timestamptz, timestamptz, boolean, integer, integer) to authenticated, anon, service_role;
grant execute on function app_api_v1.archive_resource(uuid, bigint) to authenticated, anon, service_role;
grant execute on function app_api_v1.restore_resource(uuid, bigint) to authenticated, anon, service_role;
grant execute on function app_api_v1.create_resource_download_request(uuid, integer) to authenticated, anon, service_role;

-- app_function_owner needs schema-level USAGE on taxonomy and project for Slice 2 helpers
-- (already granted in Slice 1, but ensure taxonomy is accessible)
grant usage on schema taxonomy to app_function_owner;
