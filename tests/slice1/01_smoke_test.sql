-- Slice 1 End-to-End Smoke Test
-- Run as supabase_admin: psql -U supabase_admin -d task_train -f tests/slice1/01_smoke_test.sql

begin;
select plan(20);  -- Number of tests

-- 1. Schema existence
select has_schema('identity');
select has_schema('project');
select has_schema('taxonomy');
select has_schema('platform');
select has_schema('internal_api');
select has_schema('app_api_v1');

-- 2. Table existence
select has_table('identity', 'users');
select has_table('identity', 'auth_identities');
select has_table('project', 'projects');
select has_table('project', 'project_memberships');
select has_table('taxonomy', 'object_types');
select has_table('taxonomy', 'object_registry');
select has_table('taxonomy', 'tags');
select has_table('taxonomy', 'tag_assignments');
select has_table('taxonomy', 'relationship_types');
select has_table('taxonomy', 'object_relationships');
select has_table('platform', 'command_requests');

-- 3. Seed data
select results_eq(
    'select count(*)::int from taxonomy.object_types',
    'select 18::int'
);
select results_eq(
    'select count(*)::int from taxonomy.relationship_types',
    'select 16::int'
);

-- 4. Helper function sanity
select is(internal_api.normalize_namespace('  Foo  '), 'foo');
select is(internal_api.normalize_slug('Hello World!!'), 'hello-world');

-- 5. Test with a mock JWT context
set app.current_user_id = '00000000-0000-0000-0000-000000000001';
-- These should fail because user isn't real
select throws_ok(
    'select * from internal_api.require_authenticated_user()',
    'AUTHENTICATION_REQUIRED',
    'require_authenticated_user should fail without JWT context'
);

rollback;
