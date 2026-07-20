-- Slice 2: API Integration Test
-- Tests full resource lifecycle, typed content, upload/download, search, archive.
-- Simulates JWT context via app.current_user_id, uses PL/pgSQL asserts.

begin;
do $$
declare
    v_user_id uuid := gen_random_uuid();
    v_project_id uuid;

    -- Note
    v_note_resource_id uuid;
    v_note_resource_object_id uuid;
    v_note_version_id uuid;
    v_note_version_object_id uuid;
    v_note_version_number int;
    v_note_revision bigint;

    -- Link
    v_link_resource_id uuid;
    v_link_version_id uuid;
    v_link_version_number int;

    -- File (new resource)
    v_file_reservation_id uuid;
    v_file_resource_id uuid;
    v_file_storage_id uuid;
    v_file_version_number int;

    -- File (new version)
    v_vers_reservation_id uuid;

    -- Cancel
    v_cancel_reservation_id uuid;

    -- No-upload
    v_no_upload_reservation_id uuid;

    -- Download
    v_download_request_id uuid;

    -- Tags
    v_tag_id uuid;
    v_tag2_id uuid;

    -- second project
    v_project2_id uuid;

    -- idempotency
    v_idem_key text;
    v_first_id uuid;
    v_second_id uuid;
    v_expired_id uuid;
    v_desc_null_test_id uuid;

    -- Reusable records
    v_count int;
    v_status text;
begin
    -- Bootstrap: create a user manually
    insert into identity.users (id, display_name, email_display, status)
    values (v_user_id, 'Test User', 'test@example.com', 'active');
    insert into identity.auth_identities (user_id, issuer, subject)
    values (v_user_id, 'test-issuer-for-slice2', v_user_id::text);
    perform set_config('app.current_user_id', v_user_id::text, true);

    -- Create personal project
    select project_id into v_project_id
    from app_api_v1.create_project('Slice 2 Test Project', 'slice2-test-' || v_user_id::text, 'Slice 2 test project', 'personal') t;
    assert v_project_id is not null, 'create_project should return a project_id';

    -- Create a tag for testing
    select tag_id into v_tag_id
    from app_api_v1.create_tag(v_project_id, 'test-slice2', 'slice2-tag', 'none') t;
    assert v_tag_id is not null, 'create_tag should return a tag_id';

    -- ============================================================
    -- 1. CREATE NOTE
    -- ============================================================
    select resource_id, resource_object_id, resource_version_id, version_object_id, version_number, resource_revision
    into v_note_resource_id, v_note_resource_object_id, v_note_version_id, v_note_version_object_id, v_note_version_number, v_note_revision
    from app_api_v1.create_note(v_project_id, 'Test Note', 'Hello World', 'markdown', 'A test note', array[v_tag_id]) t;

    assert v_note_resource_id is not null, 'create_note should return resource_id';
    assert v_note_version_number = 1, 'create_note version should be 1';
    assert v_note_revision = 1, 'create_note revision should be 1';

    -- Verify registry
    assert exists (select 1 from taxonomy.object_registry o join resource.resources r on r.object_id = o.id where r.id = v_note_resource_id),
        'Resource should have object_registry entry';
    assert exists (select 1 from taxonomy.object_registry o join resource.resource_versions v on v.object_id = o.id where v.id = v_note_version_id),
        'Version should have object_registry entry';

    -- Verify head
    assert exists (select 1 from resource.resource_heads where resource_id = v_note_resource_id and current_version_number = 1),
        'Head should point to version 1';

    -- Verify text content
    assert (select body_text from resource.text_contents where resource_version_id = v_note_version_id) = 'Hello World',
        'Text content should match';

    -- Verify search document
    assert exists (select 1 from resource.resource_search_documents where resource_id = v_note_resource_id),
        'Search document should exist';

    -- Verify tag assignment
    assert exists (select 1 from taxonomy.tag_assignments where object_id = v_note_resource_object_id and tag_id = v_tag_id and status = 'active'),
        'Tag should be assigned to resource';

    -- ============================================================
    -- 2. UPDATE TEXT NOTE (version 2)
    -- ============================================================
    select resource_version_id, version_number
    into v_note_version_id, v_note_version_number
    from app_api_v1.update_text_resource(v_note_resource_id, 1, 'Updated Content', 'markdown', null, 'Updated via test') t;

    assert v_note_version_number = 2, 'update_text_resource should create version 2';

    -- Version 1 still exists
    assert exists (select 1 from resource.resource_versions where resource_id = v_note_resource_id and version_number = 1 and status = 'available'),
        'Version 1 should still exist after update';

    -- Head should be version 2 now
    assert (select current_version_number from resource.resource_heads where resource_id = v_note_resource_id) = 2,
        'Head should point to version 2';

    -- ============================================================
    -- 3. VERSION CONFLICT
    -- ============================================================
    begin
        perform app_api_v1.update_text_resource(v_note_resource_id, 1, 'Should fail', 'markdown');
        raise exception 'SHOULD_NOT_REACH';
    exception
        when others then
            assert sqlerrm like '%RESOURCE_VERSION_CONFLICT%', 'Wrong expected version should throw RESOURCE_VERSION_CONFLICT';
    end;

    -- ============================================================
    -- 4. CREATE LINK RESOURCE
    -- ============================================================
    select resource_id, resource_version_id, version_number
    into v_link_resource_id, v_link_version_id, v_link_version_number
    from app_api_v1.create_link_resource(v_project_id, 'Test Link', 'https://example.com', 'A test link') t;

    assert v_link_version_number = 1, 'create_link_resource should create version 1';

    -- Verify link content
    assert (select normalized_url from resource.link_contents where resource_version_id = v_link_version_id) like 'https://example.com%',
        'Link content should have normalized URL';

    -- ============================================================
    -- 5. REJECT NON-HTTP URL
    -- ============================================================
    begin
        perform app_api_v1.create_link_resource(v_project_id, 'Bad Link', 'ftp://bad.com');
        raise exception 'SHOULD_NOT_REACH';
    exception
        when others then
            assert sqlerrm like '%RESOURCE_FORMAT_INVALID%', 'Non-HTTP URL should be rejected';
    end;

    -- ============================================================
    -- 6. UPDATE LINK
    -- ============================================================
    select version_number
    into v_link_version_number
    from app_api_v1.update_link_resource(v_link_resource_id, 1, 'https://example.org') t;

    assert v_link_version_number = 2, 'update_link_resource should create version 2';

    -- ============================================================
    -- 7. UPDATE METADATA
    -- ============================================================
    select revision into v_note_revision
    from app_api_v1.update_resource_metadata(v_note_resource_id, 1, true, 'Updated Title', true, 'Updated Description') t;

    assert v_note_revision = 2, 'update_resource_metadata should increment revision (rev 1 -> 2)';

    -- ============================================================
    -- 8. GET RESOURCE (current version)
    -- ============================================================
    select count(*) into v_count from app_api_v1.get_resource(v_note_resource_id) t where t.title = 'Updated Title' and t.text_content = 'Updated Content';
    assert v_count = 1, 'get_resource should return updated title and content';

    -- ============================================================
    -- 9. GET RESOURCE (exact version 1)
    -- ============================================================
    select count(*) into v_count from app_api_v1.get_resource(v_note_resource_id, 1) t where t.text_content = 'Hello World' and t.version_number = 1;
    assert v_count = 1, 'get_resource with version 1 should return original content';

    -- ============================================================
    -- 10. LIST VERSIONS
    -- ============================================================
    select count(*) into v_count from app_api_v1.list_resource_versions(v_note_resource_id);
    assert v_count = 2, 'list_resource_versions should return 2 versions';

    -- ============================================================
    -- 11. FILE UPLOAD RESERVATION (new resource)
    -- ============================================================
    select reservation_id into v_file_reservation_id
    from app_api_v1.create_file_resource_upload_reservation(v_project_id, 'file', 'My File', 'test.txt', 'text/plain', 100) t;

    assert v_file_reservation_id is not null, 'create_file_resource_upload_reservation should return reservation_id';

    -- Verify reservation
    assert (select provider from resource.upload_reservations where id = v_file_reservation_id) = 'supabase_storage',
        'Reservation provider should be supabase_storage';
    assert (select object_key from resource.upload_reservations where id = v_file_reservation_id) like 'projects/%/uploads/%',
        'Object key should follow project/upload pattern';

    -- ============================================================
    -- 12. SIMULATE UPLOAD OBSERVATION
    -- ============================================================
    select status into v_status from internal_api.record_upload_observation(v_file_reservation_id, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 100, 'text/plain');
    assert v_status = 'uploaded', 'record_upload_observation should set status to uploaded';

    -- ============================================================
    -- 13. FINALIZE UPLOAD (new resource)
    -- ============================================================
    select resource_id, storage_object_id, version_number
    into v_file_resource_id, v_file_storage_id, v_file_version_number
    from app_api_v1.finalize_upload(v_file_reservation_id, 'A file resource') t;

    assert v_file_resource_id is not null, 'finalize_upload should create resource';
    assert v_file_version_number = 1, 'File resource should have version 1';
    assert v_file_storage_id is not null, 'Storage object should be created';

    -- Verify storage object
    assert (select content_hash from resource.storage_objects where id = v_file_storage_id) = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'Storage object should have observed hash';

    -- ============================================================
    -- 14. FILE VERSION UPLOAD RESERVATION
    -- ============================================================
    select reservation_id into v_vers_reservation_id
    from app_api_v1.create_file_version_upload_reservation(v_file_resource_id, 1, 'v2.txt', 'text/plain', 200) t;

    assert v_vers_reservation_id is not null, 'create_file_version_upload_reservation should succeed';

    -- Observe and finalize version
    perform internal_api.record_upload_observation(v_vers_reservation_id, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 200, 'text/plain');
    select version_number into v_file_version_number
    from app_api_v1.finalize_upload(v_vers_reservation_id);
    assert v_file_version_number = 2, 'File version finalize should create version 2';

    -- ============================================================
    -- 15. CANCEL RESERVATION
    -- ============================================================
    select reservation_id into v_cancel_reservation_id
    from app_api_v1.create_file_resource_upload_reservation(v_project_id, 'file', 'Cancel Test', 'cancel.txt', 'text/plain', 50) t;

    perform app_api_v1.cancel_upload_reservation(v_cancel_reservation_id);
    assert (select status from resource.upload_reservations where id = v_cancel_reservation_id) = 'cancelled',
        'Reservation should be cancelled';

    -- ============================================================
    -- 16. FINALIZE WITHOUT UPLOAD FAILS
    -- ============================================================
    select reservation_id into v_no_upload_reservation_id
    from app_api_v1.create_file_resource_upload_reservation(v_project_id, 'file', 'No Upload', 'no-upload.txt', 'text/plain', 50) t;

    begin
        perform app_api_v1.finalize_upload(v_no_upload_reservation_id);
        raise exception 'SHOULD_NOT_REACH';
    exception
        when others then
            assert sqlerrm like '%UPLOAD_RESERVATION_NOT_UPLOADED%', 'Finalizing without upload should fail';
    end;

    -- ============================================================
    -- 17. SEARCH
    -- ============================================================
    select count(*) into v_count from app_api_v1.search_resources(v_project_id, 'Updated Title');
    assert v_count > 0, 'Search by title should find resources';

    select count(*) into v_count from app_api_v1.search_resources(v_project_id, 'Updated Content');
    assert v_count > 0, 'Search by content should find resources';

    -- ============================================================
    -- 18. ARCHIVE AND RESTORE
    -- ============================================================
    select status into v_status from app_api_v1.archive_resource(v_note_resource_id, 2);
    assert v_status = 'archived', 'archive_resource should set status to archived';

    -- Archived should be excluded from default search
    select count(*) into v_count from app_api_v1.search_resources(v_project_id, 'Updated Title') t where t.resource_id = v_note_resource_id;
    assert v_count = 0, 'Archived resources should be excluded from default search';

    -- Restore
    select status into v_status from app_api_v1.restore_resource(v_note_resource_id, 3);
    assert v_status = 'active', 'restore_resource should set status to active';

    -- Should appear in search again
    select count(*) into v_count from app_api_v1.search_resources(v_project_id, 'Updated Title') t where t.resource_id = v_note_resource_id;
    assert v_count > 0, 'Restored resources should appear in search';

    -- ============================================================
    -- 19. DOWNLOAD REQUEST
    -- ============================================================
    select download_request_id into v_download_request_id
    from app_api_v1.create_resource_download_request(v_file_resource_id, 1) t;

    assert v_download_request_id is not null, 'Download request should be created';
    assert (select status from resource.download_requests where id = v_download_request_id) = 'created',
        'Download request should have status created';

    -- Consume download request
    select status into v_status from internal_api.consume_download_request(v_download_request_id);
    assert v_status = 'consumed', 'consume_download_request should set status to consumed';

    -- ============================================================
    -- 20. SHA-256 HELPER
    -- ============================================================
    assert internal_api.sha256('hello') = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        'SHA-256 of hello should match expected';

    -- ============================================================
    -- 21. URL NORMALIZATION
    -- ============================================================
    assert internal_api.normalize_url('HTTP://Example.COM/Path#frag') = 'http://Example.COM/Path',
        'normalize_url should lowercase scheme/host and strip fragment';
    assert internal_api.extract_host('https://www.example.com/path') = 'www.example.com',
        'extract_host should return hostname';

    -- ============================================================
    -- 22. IDEMPOTENCY KEY REPLAY
    -- ============================================================
    v_idem_key := 'idem-' || v_user_id::text;

    -- First call
    select resource_id into v_first_id
    from app_api_v1.create_note(v_project_id, 'Idempotent Note', 'Idempotent Content', 'markdown', null, null, v_idem_key) t;

    -- Second call with same key
    select resource_id into v_second_id
    from app_api_v1.create_note(v_project_id, 'Idempotent Note', 'Idempotent Content', 'markdown', null, null, v_idem_key) t;

    assert v_first_id = v_second_id, 'Idempotent replay should return same resource_id';
    assert (select count(*) = 1 from resource.resources where id = v_first_id),
        'Idempotent key should not create duplicate resource';

    -- ============================================================
    -- 23. EXPIRATION
    -- ============================================================
    v_expired_id := gen_random_uuid();
    insert into resource.upload_reservations (id, project_id, operation_type, resource_type, original_filename, declared_media_type, declared_byte_size, provider, bucket, object_key, requested_by_user_id, expires_at)
    values (v_expired_id, v_project_id, 'create_resource', 'file', 'expired.txt', 'text/plain', 100, 'supabase_storage', 'platform-resources', 'expired-key-' || v_user_id::text, v_user_id, now() - interval '1 minute');

    perform internal_api.expire_upload_reservations();
    assert (select status from resource.upload_reservations where id = v_expired_id) = 'expired',
        'Expired reservation should be marked expired';

    -- ============================================================
    -- 24. METADATA NULLABLE FIELD CLEARING
    -- ============================================================
    select resource_id into v_desc_null_test_id
    from app_api_v1.create_note(v_project_id, 'Null Description Test', 'Test content', 'markdown', 'Has description') t;

    perform app_api_v1.update_resource_metadata(v_desc_null_test_id, 1, false, null, true, null);
    assert (select description from resource.resources where id = v_desc_null_test_id) is null,
        'Description should be cleared via set_flag';

    -- ============================================================
    -- 25. CROSS-PROJECT TAG REJECTION
    -- ============================================================
    select project_id into v_project2_id
    from app_api_v1.create_project('Second Project', 'second-proj-' || v_user_id::text, null, 'shared') t;

    select tag_id into v_tag2_id
    from app_api_v1.create_tag(v_project2_id, 'other', 'other-tag', 'none') t;

    begin
        perform app_api_v1.create_note(v_project_id, 'Cross-project tag', 'Content', 'markdown', null, array[v_tag2_id]);
        raise exception 'SHOULD_NOT_REACH';
    exception
        when others then
            assert sqlerrm like '%RESOURCE_TAG_PROJECT_MISMATCH%', 'Cross-project tags should be rejected';
    end;

    raise notice 'All Slice 2 integration tests passed!';
end;
$$;

rollback;
