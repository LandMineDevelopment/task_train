-- Slice 1: Phase 1.1 — Migration roles
-- Create NOLOGIN owner roles for schemas and API functions.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'migration_owner') then
    create role migration_owner nologin;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'app_function_owner') then
    create role app_function_owner nologin;
  end if;
end;
$$;
