-- Grants for PostgREST / API access

-- Grant USAGE on public API schemas to all roles PostgREST may use
grant usage on schema app_api_v1 to authenticator;
grant usage on schema operator_api_v1 to authenticator;
grant usage on schema worker_api_v1 to authenticator;

-- JWT role claim roles need schema USAGE + function EXECUTE
grant usage on schema app_api_v1 to authenticated, anon, service_role;
grant usage on schema operator_api_v1 to authenticated, anon, service_role;
grant usage on schema worker_api_v1 to authenticated, anon, service_role;

grant execute on all functions in schema app_api_v1 to authenticated, anon, service_role;
grant execute on all functions in schema operator_api_v1 to authenticated, anon, service_role;
grant execute on all functions in schema worker_api_v1 to authenticated, anon, service_role;

-- app_function_owner needs USAGE on internal schemas for SECURITY DEFINER functions
grant usage on schema identity to app_function_owner;
grant usage on schema project to app_function_owner;
grant usage on schema taxonomy to app_function_owner;
grant usage on schema platform to app_function_owner;
grant usage on schema internal_api to app_function_owner;

-- app_function_owner needs DML permissions on tables accessed by SECURITY DEFINER functions
grant select, insert, update on identity.users to app_function_owner;
grant select, insert on identity.auth_identities to app_function_owner;
grant select, insert, update on project.projects to app_function_owner;
grant select, insert, update on project.project_memberships to app_function_owner;
grant select, insert, update on taxonomy.object_registry to app_function_owner;
grant select, insert, update on taxonomy.tags to app_function_owner;
grant select, insert, update on taxonomy.tag_assignments to app_function_owner;
grant select, insert, update on taxonomy.object_relationships to app_function_owner;
grant select on taxonomy.object_types to app_function_owner;
grant select on taxonomy.relationship_types to app_function_owner;
grant select, insert, update on platform.command_requests to app_function_owner;

-- app_function_owner needs EXECUTE on internal helpers (SECURITY DEFINER chaining)
grant execute on all functions in schema internal_api to app_function_owner;

-- Grant BYPASSRLS to function owners so SECURITY DEFINER functions bypass RLS
alter role app_function_owner bypassrls;
alter role migration_owner bypassrls;
