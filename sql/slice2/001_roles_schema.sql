-- Slice 2: Phase 0 — Roles, Schema, Extensions

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'storage_gateway') then
    create role storage_gateway nologin;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'operator_gateway') then
    create role operator_gateway nologin;
  end if;

  if not exists (select 1 from pg_roles where rolname = 'resource_reconciler') then
    create role resource_reconciler nologin;
  end if;
end;
$$;

create schema if not exists resource;

alter schema resource owner to migration_owner;

create extension if not exists pgcrypto with schema pg_catalog;
