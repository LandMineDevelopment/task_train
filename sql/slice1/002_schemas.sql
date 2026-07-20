-- Slice 1: Phase 1.2–1.3 — Schemas
-- Domain schemas (private, not exposed via PostgREST)
-- API schemas (exposed via PostgREST)

create schema if not exists identity;
create schema if not exists project;
create schema if not exists taxonomy;
create schema if not exists platform;
create schema if not exists internal_api;
create schema if not exists app_api_v1;
create schema if not exists operator_api_v1;
create schema if not exists worker_api_v1;

alter schema identity owner to migration_owner;
alter schema project owner to migration_owner;
alter schema taxonomy owner to migration_owner;
alter schema platform owner to migration_owner;
alter schema internal_api owner to migration_owner;
alter schema app_api_v1 owner to migration_owner;
alter schema operator_api_v1 owner to migration_owner;
alter schema worker_api_v1 owner to migration_owner;
