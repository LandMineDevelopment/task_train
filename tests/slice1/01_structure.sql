-- Slice 1: Structure Verification
-- Verifies all schemas, tables, functions exist with correct owners.

do $$ begin

-- Schemas
assert (select count(*) = 8 from pg_namespace where nspname in (
    'identity', 'project', 'taxonomy', 'platform',
    'internal_api', 'app_api_v1', 'operator_api_v1', 'worker_api_v1'
)), 'All 8 schemas must exist';

-- Identity tables
assert (select count(*) = 2
    from pg_tables
    where schemaname = 'identity' and tablename in ('users', 'auth_identities')
), 'identity.users and identity.auth_identities';

-- Project tables
assert (select count(*) = 2
    from pg_tables
    where schemaname = 'project' and tablename in ('projects', 'project_memberships')
), 'project.projects and project.project_memberships';

-- Taxonomy tables
assert (select count(*) = 6
    from pg_tables
    where schemaname = 'taxonomy' and tablename in (
        'object_types', 'object_registry', 'tags',
        'tag_assignments', 'relationship_types', 'object_relationships'
    )
), 'All 6 taxonomy tables';

-- Platform tables
assert (select count(*) = 1
    from pg_tables
    where schemaname = 'platform' and tablename = 'command_requests'
), 'platform.command_requests';

-- RLS enabled on user-facing tables
assert (select rowsecurity from pg_tables where schemaname = 'identity' and tablename = 'users'), 'RLS on identity.users';
assert (select rowsecurity from pg_tables where schemaname = 'project' and tablename = 'projects'), 'RLS on project.projects';
assert (select rowsecurity from pg_tables where schemaname = 'project' and tablename = 'project_memberships'), 'RLS on project.project_memberships';
assert (select rowsecurity from pg_tables where schemaname = 'taxonomy' and tablename = 'object_registry'), 'RLS on taxonomy.object_registry';
assert (select rowsecurity from pg_tables where schemaname = 'taxonomy' and tablename = 'tags'), 'RLS on taxonomy.tags';
assert (select rowsecurity from pg_tables where schemaname = 'taxonomy' and tablename = 'tag_assignments'), 'RLS on taxonomy.tag_assignments';
assert (select rowsecurity from pg_tables where schemaname = 'taxonomy' and tablename = 'object_relationships'), 'RLS on taxonomy.object_relationships';

-- Triggers
assert (select count(*) = 1 from pg_trigger where tgname = 'trg_membership_prevent_last_owner'), 'Project last-owner trigger';
assert (select count(*) = 1 from pg_trigger where tgname = 'trg_tag_assignment_check'), 'Tag assignment check trigger';
assert (select count(*) = 1 from pg_trigger where tgname = 'trg_object_relationship_check'), 'Relationship check trigger';

-- Internal API functions (17 expected)
assert (select count(*) = 17
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'internal_api'
), '17 internal_api helper functions';

-- Public API functions (14 expected)
assert (select count(*) = 14
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app_api_v1'
), '14 app_api_v1 public functions';

-- Function ownership
assert (select count(*) = 0
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app_api_v1' and p.proowner != (select oid from pg_roles where rolname = 'app_function_owner')
), 'All app_api_v1 functions owned by app_function_owner';

assert (select count(*) = 0
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'internal_api' and p.proowner != (select oid from pg_roles where rolname = 'migration_owner')
), 'All internal_api functions owned by migration_owner';

-- Seed data counts
assert (select count(*) = 18 from taxonomy.object_types), '18 object types seeded';
assert (select count(*) = 16 from taxonomy.relationship_types), '16 relationship types seeded';

raise notice 'All structure tests passed!';
end $$;
