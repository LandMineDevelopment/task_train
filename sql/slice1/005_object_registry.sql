-- Slice 1: Phase 4 — Object Registry

-- 4.1 taxonomy.object_types
create table taxonomy.object_types (
    object_type text primary key,
    native_schema text not null,
    native_table text not null,
    display_name text not null,
    taggable boolean not null,
    relatable boolean not null,
    searchable boolean not null,
    enabled boolean not null default true,
    created_at timestamptz not null default transaction_timestamp()
);

alter table taxonomy.object_types owner to migration_owner;
revoke all on taxonomy.object_types from public;

-- 4.2 taxonomy.object_registry
create table taxonomy.object_registry (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    object_type text not null references taxonomy.object_types(object_type),
    display_label text check (display_label is null or length(display_label) <= 240),
    created_by_user_id uuid references identity.users(id),
    created_by_object_id uuid references taxonomy.object_registry(id),
    revision bigint not null default 1 check (revision >= 1),
    created_at timestamptz not null default transaction_timestamp(),
    updated_at timestamptz not null default transaction_timestamp(),
    archived_at timestamptz
);

create index ix_object_registry_project_type on taxonomy.object_registry (project_id, object_type, archived_at);
create index ix_object_registry_label on taxonomy.object_registry (project_id, lower(display_label));

alter table taxonomy.object_registry owner to migration_owner;
alter table taxonomy.object_registry enable row level security;

create policy registry_member_select on taxonomy.object_registry
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = object_registry.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on taxonomy.object_registry from public;
