# Slice 2 — Resources, Notes, Files, and Full-Text Search — Checklist

## Phase 0: Schema, Roles, Extensions
- [ ] Create `resource` schema owned by `migration_owner`
- [ ] Create role `storage_gateway` (NOLOGIN)
- [ ] Create role `operator_gateway` (NOLOGIN)
- [ ] Create role `resource_reconciler` (NOLOGIN)
- [ ] Enable `pgcrypto` extension if not already enabled

## Phase 1: Resource-Type Registry
- [ ] Create `resource.resource_types` table
- [ ] Create `resource.resource_type_content_kinds` table
- [ ] Partial unique index for one default per resource type
- [ ] Enable RLS on both tables
- [ ] Add RLS policies (member select)
- [ ] Seed resource types: note, file, link, code_artifact, git_diff, agent_output
- [ ] Seed content kinds: (note,text), (file,file), (link,link), (code_artifact,file), (git_diff,text), (agent_output,text), (agent_output,file)
- [ ] Add `resource` to `taxonomy.object_types` registry seed

## Phase 2: Resources, Versions, Heads
- [ ] Create `resource.resources` table
- [ ] Create `resource.resource_versions` table
- [ ] Create `resource.resource_heads` table
- [ ] Unique/check constraints on all tables
- [ ] Foreign keys to `project.projects`, `taxonomy.object_registry`, `resource.resource_types`, `identity.users`
- [ ] Indexes: resources by project/status, resources by project/type, versions by resource/number
- [ ] Enable RLS + member-select policies
- [ ] NOT NULL + CHECK constraints per spec

## Phase 3: Typed Content Tables
- [ ] Create `resource.text_contents` table (PK=resource_version_id)
- [ ] Create `resource.storage_objects` table (provider-neutral)
- [ ] Create `resource.file_contents` table (PK=resource_version_id)
- [ ] Create `resource.link_contents` table (PK=resource_version_id)
- [ ] URL normalization: strip fragments, lowercase scheme/host, keep path/query
- [ ] Text format check constraint (plain_text, markdown, code, diff)
- [ ] Storage object verification_status check (unverified, verified, missing, deleted)
- [ ] Indexes: storage by project/status, by hash, upload/download expiration filters
- [ ] Deferred constraint trigger for exactly-one-content invariant
- [ ] Enable RLS + policies

## Phase 4: Upload/Download Lifecycle
- [ ] Create `resource.upload_reservations` table
- [ ] Create `resource.download_requests` table
- [ ] Reservation status check: reserved, uploaded, finalized, expired, cancelled, failed
- [ ] Download request status check: created, consumed, expired, cancelled
- [ ] Index: upload_reservations(expires_at) WHERE status IN ('reserved','uploaded')
- [ ] Index: download_requests(expires_at) WHERE status = 'created'
- [ ] Enable RLS + policies

## Phase 5: Full-Text Search
- [ ] Create `resource.resource_search_documents` table
- [ ] tsvector column with GIN index
- [ ] Weighted vector: A=title, B=description+body, C=filename+URL+link metadata
- [ ] Use `simple` text search configuration
- [ ] Index: project_id, updated_at desc

## Phase 6: Internal Helpers
- [ ] `internal_api.sha256(text)` — SHA-256 hash returning 64-char lowercase hex
- [ ] `internal_api.normalize_url(text)` — strip fragment, lowercase scheme/host, return canonical
- [ ] `internal_api.extract_host(text)` — extract normalized hostname from URL
- [ ] `internal_api.create_resource_identity(...)` — registry + resource atomically
- [ ] `internal_api.create_text_version(...)` — version + text + head atomically
- [ ] `internal_api.create_link_version(...)` — normalize + version + link + head
- [ ] `internal_api.create_file_version(...)` — storage object + file version + head
- [ ] `internal_api.set_resource_head(...)` — validate ownership/availability before head change
- [ ] `internal_api.rebuild_resource_search_document(...)` — rebuild tsvector for resource
- [ ] `internal_api.validate_resource_tags(...)` — validate project + effective tag definitions
- [ ] `internal_api.record_upload_observation(...)` — restricted gateway function
- [ ] `internal_api.consume_download_request(...)` — restricted gateway function
- [ ] `internal_api.expire_upload_reservations(...)` — cron helper
- [ ] `internal_api.expire_download_requests(...)` — cron helper
- [ ] `internal_api.verify_resource_registry_integrity(...)` — check registry vs resources
- [ ] `internal_api.verify_resource_head_integrity(...)` — check head validity
- [ ] `internal_api.verify_resource_content_integrity(...)` — exactly-one-content check
- [ ] `internal_api.verify_storage_object_integrity(...)` — check storage vs provider
- [ ] `internal_api.require_resource_member(...)` — verify membership on resource's project

## Phase 7: Public API Functions (app_api_v1)
- [ ] `app_api_v1.create_note(...)` — create note resource + version 1 + text + head + tags + search
- [ ] `app_api_v1.update_text_resource(...)` — next text version + head + search
- [ ] `app_api_v1.create_link_resource(...)` — link + version 1
- [ ] `app_api_v1.update_link_resource(...)` — next link version
- [ ] `app_api_v1.update_resource_metadata(...)` — title/description revision-gated
- [ ] `app_api_v1.create_file_resource_upload_reservation(...)` — reserve key for new file resource
- [ ] `app_api_v1.create_file_version_upload_reservation(...)` — reserve key for new file version
- [ ] `app_api_v1.finalize_upload(...)` — consume reservation and create resource/version
- [ ] `app_api_v1.cancel_upload_reservation(...)` — cancel active reservation
- [ ] `app_api_v1.get_resource(...)` — read current or exact version
- [ ] `app_api_v1.list_resource_versions(...)` — immutable history
- [ ] `app_api_v1.search_resources(...)` — full-text + tag search
- [ ] `app_api_v1.archive_resource(...)` — archive logical resource
- [ ] `app_api_v1.restore_resource(...)` — restore logical resource
- [ ] `app_api_v1.create_resource_download_request(...)` — authorize file download

## Phase 8: Operator API Reservations
- [ ] Create `operator_api_v1.search_resources(...)` — reserved, calls internal helper
- [ ] Create `operator_api_v1.get_resource(...)` — reserved
- [ ] Create `operator_api_v1.create_note(...)` — reserved
- [ ] Create `operator_api_v1.update_text_resource(...)` — reserved

## Phase 9: Storage Gateway Functions
- [ ] Create `internal_api.record_upload_observation(...)` — restricted
- [ ] Create `internal_api.consume_download_request(...)` — restricted
- [ ] `resource_reconciler` owns/granted reconciliation functions

## Phase 10: RLS, Grants, Permissions
- [ ] Enable RLS on all resource schema tables
- [ ] Member-select policies on all resource tables
- [ ] Revoke all direct mutation on resource tables from public
- [ ] Grant USAGE on `resource` schema to `app_function_owner`
- [ ] Grant SELECT/INSERT/UPDATE on resource tables to `app_function_owner`
- [ ] Grant EXECUTE on `app_api_v1` functions to `authenticated`, `anon`, `service_role`
- [ ] Grant EXECUTE on `operator_api_v1` functions to `authenticated`, `anon`, `service_role`
- [ ] Grant storage/reconciler roles appropriate permissions
- [ ] `app_function_owner` BYPASSRLS already granted from Slice 1

## Phase 11: Idempotency Wiring
- [ ] Wire `p_idempotency_key` through all mutation functions via `internal_api.begin_command` / `complete_command` / `fail_command`
- [ ] Return cached result for replayed idempotent commands
- [ ] Handle `COMMAND_IN_PROGRESS` rejection

## Phase 12: Tests
- [ ] Test note creation: resource + version 1 + text + head + registry + tags + search
- [ ] Test text update creates version 2, leaves version 1 intact
- [ ] Test RESOURCE_VERSION_CONFLICT with wrong expected version
- [ ] Test metadata update: title/description revision-gated
- [ ] Test nullable description cleared via set_flags
- [ ] Test SHA-256 content hash stability
- [ ] Test exact historical version retrieval
- [ ] Test link creation and versioning
- [ ] Test non-HTTP/HTTPS URL rejection
- [ ] Test file upload reservation + finalization flow
- [ ] Test reservation expiration rejection
- [ ] Test finalization before upload observation fails
- [ ] Test cross-project tag rejection
- [ ] Test search by title and body
- [ ] Test required/any/excluded tag filters
- [ ] Test archive excludes from search
- [ ] Test restore returns to search
- [ ] Test download request + consumption
- [ ] Test expired download request rejection
- [ ] Test nonmember access denied
- [ ] Test head/content/registry integrity checks
- [ ] Test exactly-one-content invariant
- [ ] Test idempotency key replay
- [ ] Test concurrent version creation
