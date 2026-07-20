# Slice 1 — Implementation Checklist

## Phase 0: Environment & Setup

- [x] **0.1** — Start Supabase Docker stack (`docker compose up -d`)
- [x] **0.2** — Verify PostgREST is responding on port 3000
- [x] **0.3** — Verify Kong is routing on port 8000
- [x] **0.4** — Verify Auth (GoTrue) health check passes
- [x] **0.5** — Create `sql/slice1/` directory for migration files

---

## Phase 1: Schemas & Roles

### 1.1 Migration roles

- [x] **1.1.1** — Create NOLOGIN role `migration_owner` to own all schemas and tables
- [x] **1.1.2** — Create NOLOGIN role `app_function_owner` to own public API functions

### 1.2 Domain schemas (private — not exposed via PostgREST)

- [x] **1.2.1** — Create schema `identity`
- [x] **1.2.2** — Create schema `project`
- [x] **1.2.3** — Create schema `taxonomy`
- [x] **1.2.4** — Create schema `platform`

### 1.3 Internal/API schemas

- [x] **1.3.1** — Create schema `internal_api` (private helpers, no public grants)
- [x] **1.3.2** — Create schema `app_api_v1` (public PostgREST surface)
- [x] **1.3.3** — Create schema `operator_api_v1` (reserved, empty)
- [x] **1.3.4** — Create schema `worker_api_v1` (reserved, empty)

---

## Phase 2: Identity Model

### 2.1 Table: `identity.users`

- [x] **2.1.1** — Write `CREATE TABLE identity.users` with columns:
  - `id uuid PK DEFAULT gen_random_uuid()`
  - `display_name text NOT NULL CHECK (length(trim(display_name)) BETWEEN 1 AND 100)`
  - `email_display text`
  - `status text NOT NULL CHECK (status IN ('active','disabled','deleted'))`
  - `created_at timestamptz NOT NULL DEFAULT transaction_timestamp()`
  - `updated_at timestamptz NOT NULL DEFAULT transaction_timestamp()`
- [x] **2.1.2** — Set table owner to `migration_owner`
- [x] **2.1.3** — Enable RLS on `identity.users`
- [ ] **2.1.4** — Create RLS policy: current user may read own row *(deferred until Phase 8.1.3)*
- [x] **2.1.5** — Revoke all on table from `PUBLIC`

### 2.2 Table: `identity.auth_identities`

- [x] **2.2.1** — Write `CREATE TABLE identity.auth_identities` with columns:
  - `id uuid PK DEFAULT gen_random_uuid()`
  - `user_id uuid NOT NULL FK -> identity.users(id)`
  - `issuer text NOT NULL`
  - `subject text NOT NULL`
  - `provider text NOT NULL DEFAULT 'supabase'`
  - `email_at_last_login text`
  - `created_at timestamptz NOT NULL DEFAULT transaction_timestamp()`
  - `last_authenticated_at timestamptz`
- [x] **2.2.2** — Add `UNIQUE (issuer, subject)` constraint
- [x] **2.2.3** — Create index `ix_auth_identity_user` on `user_id`
- [x] **2.2.4** — Set table owner to `migration_owner`
- [x] **2.2.5** — Revoke all on table from PUBLIC; no direct access

---

## Phase 3: Project Model

### 3.1 Table: `project.projects`

- [x] **3.1.1** — Write `CREATE TABLE project.projects` with columns:
  - `id uuid PK DEFAULT gen_random_uuid()`
  - `project_kind text NOT NULL CHECK (project_kind IN ('personal','shared'))`
  - `name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120)`
  - `slug text NOT NULL`
  - `description text CHECK (description IS NULL OR length(description) <= 2000)`
  - `created_by_user_id uuid NOT NULL FK -> identity.users(id)`
  - `status text NOT NULL CHECK (status IN ('active','archived'))`
  - `revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1)`
  - `created_at timestamptz NOT NULL DEFAULT transaction_timestamp()`
  - `updated_at timestamptz NOT NULL DEFAULT transaction_timestamp()`
  - `archived_at timestamptz`
- [x] **3.1.2** — Add `UNIQUE (slug)` index `uq_project_slug`
- [x] **3.1.3** — Add partial unique index `uq_personal_project_owner` on `created_by_user_id WHERE project_kind = 'personal'`
- [x] **3.1.4** — Set table owner to `migration_owner`
- [x] **3.1.5** — Enable RLS; policy: active members may SELECT, owners may UPDATE
- [x] **3.1.6** — Revoke all on table from `PUBLIC`

### 3.2 Table: `project.project_memberships`

- [x] **3.2.1** — Write `CREATE TABLE project.project_memberships` with columns:
- [x] **3.2.2** — Add `UNIQUE (project_id, user_id)` index `uq_project_membership`
- [x] **3.2.3** — Create index `ix_project_membership_user_status` on `(user_id, status, project_id)`
- [x] **3.2.4** — Set table owner to `migration_owner`
- [x] **3.2.5** — Enable RLS; policy: active members may read, owners may mutate
- [x] **3.2.6** — Revoke all on table from `PUBLIC`

### 3.3 Project integrity triggers

- [x] **3.3.1** — Write trigger function: prevent removal of final active owner
- [x] **3.3.2** — Write trigger function: prevent disabling final active owner
- [x] **3.3.3** — Write trigger function: prevent demoting final active owner
- [x] **3.3.4** — Attach triggers to `project.project_memberships`

---

## Phase 4: Object Registry

### 4.1 Table: `taxonomy.object_types`

- [x] **4.1.1** — Write `CREATE TABLE taxonomy.object_types` with columns:
- [x] **4.1.2** — Set table owner to `migration_owner`
- [x] **4.1.3** — Revoke all on table from `PUBLIC`

### 4.2 Table: `taxonomy.object_registry`

- [x] **4.2.1** — Write `CREATE TABLE taxonomy.object_registry` with columns:
- [x] **4.2.2** — Create index `ix_object_registry_project_type` on `(project_id, object_type, archived_at)`
- [x] **4.2.3** — Create index `ix_object_registry_label` on `(project_id, lower(display_label))`
- [x] **4.2.4** — Set table owner to `migration_owner`
- [x] **4.2.5** — Enable RLS; policy: active project members may SELECT project rows
- [x] **4.2.6** — Revoke all on table from `PUBLIC`

---

## Phase 5: Tags

### 5.1 Table: `taxonomy.tags`

- [x] **5.1.1** — Write `CREATE TABLE taxonomy.tags` with columns:
- [x] **5.1.2** — Add `UNIQUE (project_id, namespace, slug)` index `uq_tag_project_namespace_slug`
- [x] **5.1.3** — Create index `ix_tags_project_namespace_status` on `(project_id, namespace, status)`
- [x] **5.1.4** — Create index `ix_tags_project_name` on `(project_id, lower(name))`
- [x] **5.1.5** — Set table owner to `migration_owner`
- [x] **5.1.6** — Enable RLS; policy: active project members may SELECT
- [x] **5.1.7** — Revoke all on table from `PUBLIC`

### 5.2 Table: `taxonomy.tag_assignments`

- [x] **5.2.1** — Write `CREATE TABLE taxonomy.tag_assignments` with columns:
- [x] **5.2.2** — Add partial unique index `uq_tag_assignment_current` on `(object_id, tag_id) WHERE status IN ('proposed','active','confirmed')`
- [x] **5.2.3** — Create index `ix_tag_assignments_object_status` on `(object_id, status, created_at DESC)`
- [x] **5.2.4** — Create index `ix_tag_assignments_tag_status` on `(tag_id, status, created_at DESC)`
- [x] **5.2.5** — Create index `ix_tag_assignments_project` on `(project_id, status, created_at DESC)`
- [x] **5.2.6** — Set table owner to `migration_owner`
- [x] **5.2.7** — Enable RLS; policy: active project members may SELECT
- [x] **5.2.8** — Revoke all on table from `PUBLIC`

### 5.3 Tag assignment triggers

- [x] **5.3.1** — Write trigger: validate project_id matches both object and tag
- [x] **5.3.2** — Write trigger: enforce exactly-one-value rule by value_type
- [x] **5.3.3** — Write trigger: prevent assignment to archived tag
- [x] **5.3.4** — Write trigger: prevent assignment to non-taggable object type
- [x] **5.3.5** — Attach triggers to `taxonomy.tag_assignments`

---

## Phase 6: Relationships

### 6.1 Table: `taxonomy.relationship_types`

- [x] **6.1.1** — Write `CREATE TABLE taxonomy.relationship_types` with columns:
- [x] **6.1.2** — Set table owner to `migration_owner`
- [x] **6.1.3** — Revoke all on table from `PUBLIC`

### 6.2 Table: `taxonomy.object_relationships`

- [x] **6.2.1** — Write `CREATE TABLE taxonomy.object_relationships` with columns:
- [x] **6.2.2** — Add partial unique index `uq_object_relationship_current` on `(source_object_id, relationship_type, target_object_id) WHERE status IN ('proposed','active')`
- [x] **6.2.3** — Create index `ix_relationship_source_status` on `(source_object_id, status, created_at DESC)`
- [x] **6.2.4** -- Create index `ix_relationship_target_status` on `(target_object_id, status, created_at DESC)`
- [x] **6.2.5** — Set table owner to `migration_owner`
- [x] **6.2.6** — Enable RLS; policy: active project members may SELECT
- [x] **6.2.7** — Revoke all on table from `PUBLIC`

### 6.3 Relationship triggers

- [x] **6.3.1** — Write trigger: validate project equality for source/target/relationship
- [x] **6.3.2** — Write trigger: prevent relationship to non-relatable object types
- [x] **6.3.3** — Write trigger: canonicalize symmetric edge ordering
- [x] **6.3.4** — Attach triggers to `taxonomy.object_relationships`

---

## Phase 7: Command Deduplication

### 7.1 Table: `platform.command_requests`

- [ ] **7.1.1** — Write `CREATE TABLE platform.command_requests` with columns:
  - `id uuid PK DEFAULT gen_random_uuid()`
  - `initiating_user_id uuid NOT NULL FK -> identity.users(id)`
  - `project_id uuid FK -> project.projects(id)`
  - `function_key text NOT NULL`
  - `idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 200)`
  - `status text NOT NULL CHECK (status IN ('started','completed','failed'))`
  - `result_entity_kind text`
  - `result_entity_id uuid`
  - `error_code text`
  - `created_at timestamptz NOT NULL DEFAULT transaction_timestamp()`
  - `completed_at timestamptz`
- [ ] **7.1.2** — Add `UNIQUE (initiating_user_id, function_key, idempotency_key)` index `uq_command_request_idempotency`
- [ ] **7.1.3** — Set table owner to `migration_owner`
- [ ] **7.1.4** — Revoke all on table from `PUBLIC`; no direct access

---

## Phase 8: Internal API Helpers

Write each function in schema `internal_api`:

### 8.1 Authentication helpers

- [ ] **8.1.1** — `current_auth_issuer()` — read and normalize JWT issuer from `current_setting`
- [ ] **8.1.2** — `current_auth_subject()` — read and normalize JWT subject from `current_setting`
- [ ] **8.1.3** — `current_user_id()` — resolve issuer+subject to `identity.users.id`; return NULL if unknown
- [ ] **8.1.4** — `require_authenticated_user()` — raise `AUTHENTICATION_REQUIRED` if no active user

### 8.2 Project authorization helpers

- [ ] **8.2.1** — `require_project_member(p_project_id)` — return `user_id` or raise `PROJECT_ACCESS_DENIED`
- [ ] **8.2.2** — `require_project_owner(p_project_id)` — return `user_id` or raise `PROJECT_OWNER_REQUIRED`

### 8.3 Normalization helpers

- [ ] **8.3.1** — `normalize_namespace(text)` — trim, lowercase, validate
- [ ] **8.3.2** — `normalize_slug(text)` — generate stable lowercase slug from text

### 8.4 Registry helpers

- [ ] **8.4.1** — `register_object(project_id, object_type, label, created_by_user_id, created_by_object_id)` — insert and return UUID
- [ ] **8.4.2** — `update_object_label(object_id, expected_revision, label)` — revision-check update
- [ ] **8.4.3** — `archive_object(object_id, expected_revision)` — archive registry row

### 8.5 Tag/relationship helpers

- [ ] **8.5.1** — `validate_tag_value(tag_id, typed values...)` — enforce value_type rules
- [ ] **8.5.2** — `canonicalize_relationship(type, source_id, target_id)` — return normalized edge order for symmetric types

### 8.6 Command deduplication helpers

- [ ] **8.6.1** — `begin_command(user_id, project_id, function_key, idempotency_key)` — create or resolve command record
- [ ] **8.6.2** — `complete_command(command_id, result_kind, result_id)` — mark completed
- [ ] **8.6.3** — `fail_command(command_id, error_code)` — mark failed

### 8.7 Integrity helpers

- [ ] **8.7.1** — `check_object_registry_integrity(project_id DEFAULT NULL)` — report orphan rows and type mismatches

---

## Phase 9: Public API Functions (app_api_v1)

### 9.1 Identity and project functions

- [ ] **9.1.1** — `bootstrap_current_user(p_display_name text)` — upsert user + auth_identity + personal project
- [ ] **9.1.2** — `get_current_user()` — return current internal user details
- [ ] **9.1.3** — `list_projects()` — list active memberships for current user
- [ ] **9.1.4** — `get_project(p_project_id)` — read project summary
- [ ] **9.1.5** — `create_project(p_name, p_slug, p_description, p_idempotency_key)` — create shared project + owner membership
- [ ] **9.1.6** — `update_project(p_project_id, p_expected_revision, p_set_name, p_name, p_set_description, p_description)` — revision-checked update
- [ ] **9.1.7** — `archive_project(p_project_id, p_expected_revision)` — archive with final-owner guard
- [ ] **9.1.8** — `list_project_members(p_project_id, p_include_disabled)` — list members
- [ ] **9.1.9** — `add_project_member(p_project_id, p_user_id, p_role, p_idempotency_key)` — add member
- [ ] **9.1.10** — `update_project_member(p_membership_id, p_expected_revision, ...)` — change role/status with final-owner guard

### 9.2 Tag functions

- [ ] **9.2.1** — `list_object_types(p_project_id)` — return enabled object types
- [ ] **9.2.2** — `create_tag(p_project_id, p_namespace, p_name, p_description, p_value_type, p_idempotency_key)` — create tag
- [ ] **9.2.3** — `get_tag(p_tag_id)` — read one tag with current assignment count
- [ ] **9.2.4** — `list_tags(p_project_id, p_query, p_namespace, p_include_archived, p_limit, p_offset)` — search and page
- [ ] **9.2.5** — `update_tag(p_tag_id, p_expected_revision, ...)` — revision-checked update
- [ ] **9.2.6** — `archive_tag(p_tag_id, p_expected_revision)` — archive tag
- [ ] **9.2.7** — `restore_tag(p_tag_id, p_expected_revision)` — restore archived tag

### 9.3 Tag assignment functions

- [ ] **9.3.1** — `assign_tag(p_object_id, p_tag_id, p_text_value, p_number_value, p_boolean_value, p_date_value, p_idempotency_key)` — human assignment (active)
- [ ] **9.3.2** — `review_tag_assignment(p_assignment_id, p_decision, p_reason)` — confirm or reject a proposal
- [ ] **9.3.3** — `remove_tag_assignment(p_assignment_id, p_reason)` — remove current assignment
- [ ] **9.3.4** — `get_object_tags(p_object_id, p_include_proposed, p_include_history)` — return current or historical tags

### 9.4 Relationship functions

- [ ] **9.4.1** — `relate_objects(p_source_object_id, p_relationship_type, p_target_object_id, p_idempotency_key)` — create human relationship
- [ ] **9.4.2** — `review_object_relationship(p_relationship_id, p_decision, p_reason)` — accept or reject proposal
- [ ] **9.4.3** — `remove_object_relationship(p_relationship_id, p_reason)` — remove relationship
- [ ] **9.4.4** — `get_related_objects(p_object_id, p_relationship_type, p_include_proposed, p_include_history, p_limit, p_offset)` — list related objects both directions

### 9.5 Grant management

- [ ] **9.5.1** — Revoke `EXECUTE` on all app_api_v1 functions from `PUBLIC`
- [ ] **9.5.2** — Grant `EXECUTE` on all app_api_v1 functions to `authenticated`

---

## Phase 10: Seed Data

### 10.1 Object types

- [ ] **10.1.1** — `resource`
- [ ] **10.1.2** — `resource_version`
- [ ] **10.1.3** — `agent`
- [ ] **10.1.4** — `agent_version`
- [ ] **10.1.5** — `workflow`
- [ ] **10.1.6** — `workflow_run`
- [ ] **10.1.7** — `conversation`
- [ ] **10.1.8** — `message`
- [ ] **10.1.9** — `human_task`
- [ ] **10.1.10** — `agent_execution`

### 10.2 Relationship types

- [ ] **10.2.1** — `references` (inverse: `referenced_by`)
- [ ] **10.2.2** — `related_to` (symmetric)
- [ ] **10.2.3** — `derived_from` (inverse: `source_of`)
- [ ] **10.2.4** — `source_of` (inverse: `derived_from`)
- [ ] **10.2.5** — `produced_by` (inverse: `produced`)
- [ ] **10.2.6** — `produced` (inverse: `produced_by`)
- [ ] **10.2.7** — `supersedes` (inverse: `superseded_by`)
- [ ] **10.2.8** — `superseded_by` (inverse: `supersedes`)
- [ ] **10.2.9** — `concerns` (inverse: `concerned_by`)
- [ ] **10.2.10** — `concerned_by` (inverse: `concerns`)

---

## Phase 11: Migration & Deployment

- [ ] **11.1** — Write single migration SQL file `slice1_initial.sql` that applies all phases in order
- [ ] **11.2** — Create migration rollback for development
- [ ] **11.3** — Configure `PGRST_DB_SCHEMAS` in `.env` to include `app_api_v1`
- [ ] **11.4** — Apply migration to Supabase PostgreSQL
- [ ] **11.5** — Verify PostgREST introspection shows all app_api_v1 functions
- [ ] **11.6** — Verify direct table access via PostgREST fails (e.g. `from("taxonomy.tags").insert(...)`)

---

## Phase 12: Tests

### 12.1 Identity tests

- [ ] **12.1.1** — **PF-001**: Bootstrap creates internal user + personal project
- [ ] **12.1.2** — **PF-002**: Repeated bootstrap returns same IDs, `created=false`
- [ ] **12.1.3** — **PF-003**: Disabled user cannot call project or taxonomy functions

### 12.2 Project tests

- [ ] **12.2.1** — **PF-004**: User creates shared project, becomes owner
- [ ] **12.2.2** — **PF-005**: Nonmember cannot read project details
- [ ] **12.2.3** — **PF-006**: Owner adds existing user as member
- [ ] **12.2.4** — **PF-007**: Member cannot add or elevate members
- [ ] **12.2.5** — **PF-008**: Final active owner cannot be disabled or demoted

### 12.3 Concurrency tests

- [ ] **12.3.1** — **PF-009**: Stale expected revision returns `REVISION_CONFLICT`

### 12.4 Tag tests

- [ ] **12.4.1** — **PF-010**: Create an unvalued tag
- [ ] **12.4.2** — **PF-011**: Duplicate namespace+slug in same project rejected
- [ ] **12.4.3** — **PF-012**: Same namespace+slug allowed in different project
- [ ] **12.4.4** — **PF-013**: Number tag rejects text_value, accepts number_value

### 12.5 Assignment tests

- [ ] **12.5.1** — **PF-014**: Human assignment becomes active
- [ ] **12.5.2** — **PF-015**: Agent-style proposal can be confirmed or rejected
- [ ] **12.5.3** — **PF-016**: Only one current assignment per object+tag
- [ ] **12.5.4** — **PF-017**: Removed/rejected assignments remain queryable with history flag

### 12.6 Relationship tests

- [ ] **12.6.1** — **PF-018**: Directed relationship created and returned in both directions
- [ ] **12.6.2** — **PF-019**: Symmetric reverse duplicate rejected
- [ ] **12.6.3** — **PF-020**: Cross-project edge rejected

### 12.7 Registry tests

- [ ] **12.7.1** — **PF-021**: Native fixture row and registry share UUID
- [ ] **12.7.2** — **PF-022**: Integrity check reports deliberately introduced orphan

### 12.8 Idempotency tests

- [ ] **12.8.1** — **PF-023**: Repeated `create_tag` with same key returns same tag ID
- [ ] **12.8.2** — **PF-024**: Same key with different function does not collide

### 12.9 Authorization tests

- [ ] **12.9.1** — **PF-025**: Direct INSERT/UPDATE/DELETE through PostgREST fails
- [ ] **12.9.2** — **PF-026**: API function cannot infer existence of inaccessible project objects

### 12.10 Portability & integration

- [ ] **12.10.1** — **PF-027**: Tests pass with Supabase Realtime disabled
- [ ] **12.10.2** — **PF-028**: Fresh database migration + seed succeeds from zero state
