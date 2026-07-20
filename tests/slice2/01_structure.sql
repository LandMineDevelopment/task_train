-- Slice 2: Structural Tests

begin;
select plan(94);

-- Phase 0: Roles and schema
select has_role('storage_gateway');
select has_role('operator_gateway');
select has_role('resource_reconciler');
select has_schema('resource');

-- Phase 1: Resource type registry
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''resource_types''',
    array[1],
    'resource.resource_types should exist'
);
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''resource_type_content_kinds''',
    array[1],
    'resource.resource_type_content_kinds should exist'
);
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''uq_resource_type_default_kind''',
    array[1],
    'uq_resource_type_default_kind should exist'
);

-- Seed data checks
select results_eq(
    'select count(*)::int from resource.resource_types',
    array[6],
    'Should have 6 seeded resource types'
);
select results_eq(
    'select count(*)::int from resource.resource_type_content_kinds',
    array[7],
    'Should have 7 resource-type content-kind rows'
);
select is_empty(
    'select rt.resource_type from resource.resource_types rt
     left join resource.resource_type_content_kinds rtc on rtc.resource_type = rt.resource_type and rtc.is_default = true
     where rtc.resource_type is null',
    'Every resource type should have exactly one default content kind'
);

-- Phase 2: Resource tables
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''resources''',
    array[1],
    'resource.resources should exist'
);
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''resource_versions''',
    array[1],
    'resource.resource_versions should exist'
);
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''resource_heads''',
    array[1],
    'resource.resource_heads should exist'
);

-- Primary keys via information_schema
select is(
    (select column_name::text from information_schema.table_constraints tc join information_schema.key_column_usage kcu using (constraint_name, table_schema, table_name) where tc.table_schema = 'resource' and tc.table_name = 'resources' and tc.constraint_type = 'PRIMARY KEY' order by ordinal_position limit 1),
    'id',
    'resources PK is id'
);
select is(
    (select column_name::text from information_schema.table_constraints tc join information_schema.key_column_usage kcu using (constraint_name, table_schema, table_name) where tc.table_schema = 'resource' and tc.table_name = 'resource_versions' and tc.constraint_type = 'PRIMARY KEY' order by ordinal_position limit 1),
    'id',
    'resource_versions PK is id'
);
select is(
    (select column_name::text from information_schema.table_constraints tc join information_schema.key_column_usage kcu using (constraint_name, table_schema, table_name) where tc.table_schema = 'resource' and tc.table_name = 'resource_heads' and tc.constraint_type = 'PRIMARY KEY' order by ordinal_position limit 1),
    'resource_id',
    'resource_heads PK is resource_id'
);

-- Indexes
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_resources_project_status''',
    array[1],
    'ix_resources_project_status should exist'
);
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_resources_project_type''',
    array[1],
    'ix_resources_project_type should exist'
);
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_resource_versions_resource''',
    array[1],
    'ix_resource_versions_resource should exist'
);

-- NOT NULL checks
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resources' and column_name='title' and is_nullable='NO'$$,
    array[1],
    'resources.title is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resources' and column_name='project_id' and is_nullable='NO'$$,
    array[1],
    'resources.project_id is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resources' and column_name='resource_type' and is_nullable='NO'$$,
    array[1],
    'resources.resource_type is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resources' and column_name='status' and is_nullable='NO'$$,
    array[1],
    'resources.status is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resources' and column_name='revision' and is_nullable='NO'$$,
    array[1],
    'resources.revision is NOT NULL'
);

select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_versions' and column_name='version_number' and is_nullable='NO'$$,
    array[1],
    'resource_versions.version_number is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_versions' and column_name='content_kind' and is_nullable='NO'$$,
    array[1],
    'resource_versions.content_kind is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_versions' and column_name='status' and is_nullable='NO'$$,
    array[1],
    'resource_versions.status is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_versions' and column_name='content_hash' and is_nullable='NO'$$,
    array[1],
    'resource_versions.content_hash is NOT NULL'
);

select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_heads' and column_name='current_version_id' and is_nullable='NO'$$,
    array[1],
    'resource_heads.current_version_id is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_heads' and column_name='current_version_number' and is_nullable='NO'$$,
    array[1],
    'resource_heads.current_version_number is NOT NULL'
);

-- Phase 3: Content tables
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''text_contents''',
    array[1],
    'resource.text_contents should exist'
);
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''storage_objects''',
    array[1],
    'resource.storage_objects should exist'
);
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''file_contents''',
    array[1],
    'resource.file_contents should exist'
);
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''link_contents''',
    array[1],
    'resource.link_contents should exist'
);

-- Content table PKs
select is(
    (select column_name::text from information_schema.table_constraints tc join information_schema.key_column_usage kcu using (constraint_name, table_schema, table_name) where tc.table_schema = 'resource' and tc.table_name = 'text_contents' and tc.constraint_type = 'PRIMARY KEY' limit 1),
    'resource_version_id',
    'text_contents PK is resource_version_id'
);
select is(
    (select column_name::text from information_schema.table_constraints tc join information_schema.key_column_usage kcu using (constraint_name, table_schema, table_name) where tc.table_schema = 'resource' and tc.table_name = 'file_contents' and tc.constraint_type = 'PRIMARY KEY' limit 1),
    'resource_version_id',
    'file_contents PK is resource_version_id'
);
select is(
    (select column_name::text from information_schema.table_constraints tc join information_schema.key_column_usage kcu using (constraint_name, table_schema, table_name) where tc.table_schema = 'resource' and tc.table_name = 'link_contents' and tc.constraint_type = 'PRIMARY KEY' limit 1),
    'resource_version_id',
    'link_contents PK is resource_version_id'
);
select is(
    (select column_name::text from information_schema.table_constraints tc join information_schema.key_column_usage kcu using (constraint_name, table_schema, table_name) where tc.table_schema = 'resource' and tc.table_name = 'storage_objects' and tc.constraint_type = 'PRIMARY KEY' limit 1),
    'id',
    'storage_objects PK is id'
);

-- Storage object NOT NULL
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='storage_objects' and column_name='content_hash' and is_nullable='NO'$$,
    array[1],
    'storage_objects.content_hash is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='storage_objects' and column_name='byte_size' and is_nullable='NO'$$,
    array[1],
    'storage_objects.byte_size is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='storage_objects' and column_name='media_type' and is_nullable='NO'$$,
    array[1],
    'storage_objects.media_type is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='storage_objects' and column_name='verification_status' and is_nullable='NO'$$,
    array[1],
    'storage_objects.verification_status is NOT NULL'
);

-- Storage indexes
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_storage_objects_project''',
    array[1],
    'ix_storage_objects_project should exist'
);
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_storage_objects_hash''',
    array[1],
    'ix_storage_objects_hash should exist'
);

-- Content triggers
select ok(
    exists (select 1 from information_schema.triggers where trigger_schema='resource' and trigger_name='trg_text_content_single'),
    'trg_text_content_single should exist'
);
select ok(
    exists (select 1 from information_schema.triggers where trigger_schema='resource' and trigger_name='trg_file_content_single'),
    'trg_file_content_single should exist'
);
select ok(
    exists (select 1 from information_schema.triggers where trigger_schema='resource' and trigger_name='trg_link_content_single'),
    'trg_link_content_single should exist'
);

-- Phase 4: Upload/download tables
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''upload_reservations''',
    array[1],
    'resource.upload_reservations should exist'
);
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''download_requests''',
    array[1],
    'resource.download_requests should exist'
);

select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='upload_reservations' and column_name='original_filename' and is_nullable='NO'$$,
    array[1],
    'upload_reservations.original_filename is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='upload_reservations' and column_name='declared_media_type' and is_nullable='NO'$$,
    array[1],
    'upload_reservations.declared_media_type is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='upload_reservations' and column_name='declared_byte_size' and is_nullable='NO'$$,
    array[1],
    'upload_reservations.declared_byte_size is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='upload_reservations' and column_name='expires_at' and is_nullable='NO'$$,
    array[1],
    'upload_reservations.expires_at is NOT NULL'
);

-- Upload/download indexes
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_upload_reservations_expiration''',
    array[1],
    'ix_upload_reservations_expiration should exist'
);
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_download_requests_expiration''',
    array[1],
    'ix_download_requests_expiration should exist'
);

-- Phase 5: Search table
select results_eq(
    'select count(*)::int from information_schema.tables where table_schema = ''resource'' and table_name = ''resource_search_documents''',
    array[1],
    'resource.resource_search_documents should exist'
);
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_resource_search_documents_vector''',
    array[1],
    'ix_resource_search_documents_vector should exist'
);
select results_eq(
    'select count(*)::int from pg_indexes where schemaname = ''resource'' and indexname = ''ix_resource_search_documents_project''',
    array[1],
    'ix_resource_search_documents_project should exist'
);

select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_search_documents' and column_name='search_vector' and is_nullable='NO'$$,
    array[1],
    'resource_search_documents.search_vector is NOT NULL'
);
select results_eq(
    $$select count(*)::int from information_schema.columns where table_schema='resource' and table_name='resource_search_documents' and column_name='title_text' and is_nullable='NO'$$,
    array[1],
    'resource_search_documents.title_text is NOT NULL'
);

-- Phase 6: Internal helper functions
select has_function('internal_api', 'sha256', array['text']);
select has_function('internal_api', 'normalize_url', array['text']);
select has_function('internal_api', 'extract_host', array['text']);
select has_function('internal_api', 'require_resource_member', array['uuid']);
select has_function('internal_api', 'validate_resource_tags', array['uuid', 'uuid[]']);
select has_function('internal_api', 'create_resource_identity', array['uuid', 'text', 'text', 'text', 'uuid']);
select has_function('internal_api', 'create_text_version', array['uuid', 'text', 'text', 'text', 'text', 'uuid']);
select has_function('internal_api', 'create_link_version', array['uuid', 'text', 'text', 'text', 'text', 'uuid']);
select has_function('internal_api', 'create_file_version', array['uuid', 'uuid', 'text', 'text', 'bigint', 'text', 'text', 'uuid']);
select has_function('internal_api', 'rebuild_resource_search_document', array['uuid']);
select has_function('internal_api', 'record_upload_observation', array['uuid', 'text', 'bigint', 'text', 'text']);
select has_function('internal_api', 'consume_download_request', array['uuid']);
select has_function('internal_api', 'expire_upload_reservations', array[]::text[]);
select has_function('internal_api', 'expire_download_requests', array[]::text[]);

-- Phase 7: Public API functions
select has_function('app_api_v1', 'create_note', array['uuid', 'text', 'text', 'text', 'text', 'uuid[]', 'text']);
select has_function('app_api_v1', 'update_text_resource', array['uuid', 'integer', 'text', 'text', 'text', 'text', 'text']);
select has_function('app_api_v1', 'create_link_resource', array['uuid', 'text', 'text', 'text', 'text', 'text', 'uuid[]', 'text']);
select has_function('app_api_v1', 'update_link_resource', array['uuid', 'integer', 'text', 'text', 'text', 'text', 'text']);
select has_function('app_api_v1', 'update_resource_metadata', array['uuid', 'bigint', 'boolean', 'text', 'boolean', 'text']);
select has_function('app_api_v1', 'create_file_resource_upload_reservation', array['uuid', 'text', 'text', 'text', 'text', 'bigint', 'text']);
select has_function('app_api_v1', 'create_file_version_upload_reservation', array['uuid', 'integer', 'text', 'text', 'bigint', 'text']);
select has_function('app_api_v1', 'finalize_upload', array['uuid', 'text', 'uuid[]', 'text', 'text']);
select has_function('app_api_v1', 'cancel_upload_reservation', array['uuid']);
select has_function('app_api_v1', 'get_resource', array['uuid', 'integer']);
select has_function('app_api_v1', 'list_resource_versions', array['uuid', 'integer', 'integer']);
select has_function('app_api_v1', 'search_resources', array['uuid', 'text', 'text[]', 'uuid[]', 'uuid[]', 'uuid[]', 'uuid', 'timestamptz', 'timestamptz', 'boolean', 'integer', 'integer']);
select has_function('app_api_v1', 'archive_resource', array['uuid', 'bigint']);
select has_function('app_api_v1', 'restore_resource', array['uuid', 'bigint']);
select has_function('app_api_v1', 'create_resource_download_request', array['uuid', 'integer']);

-- Phase 8: Operator API reserved functions
select has_function('operator_api_v1', 'search_resources', array['uuid', 'text', 'text[]', 'uuid[]', 'uuid[]', 'uuid[]', 'uuid', 'timestamptz', 'timestamptz', 'boolean', 'integer', 'integer']);
select has_function('operator_api_v1', 'get_resource', array['uuid', 'integer']);
select has_function('operator_api_v1', 'create_note', array['uuid', 'text', 'text', 'text', 'text', 'uuid[]', 'text']);
select has_function('operator_api_v1', 'update_text_resource', array['uuid', 'integer', 'text', 'text', 'text', 'text', 'text']);

-- Object types seeded
select results_eq(
    $$select count(*)::int from taxonomy.object_types where object_type in ('resource', 'resource_version')$$,
    array[2],
    'resource and resource_version object types should be seeded'
);

rollback;
