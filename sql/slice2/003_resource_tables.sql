-- Slice 2: Phase 2 — Resources, Versions, Current Heads

create table resource.resources (
    id uuid primary key default gen_random_uuid(),
    object_id uuid not null unique references taxonomy.object_registry(id),
    project_id uuid not null references project.projects(id),
    resource_type text not null references resource.resource_types(resource_type),
    title text not null check (length(trim(title)) > 0),
    description text,
    status text not null check (status in ('active', 'archived')) default 'active',
    revision bigint not null default 1 check (revision >= 1),
    created_by_user_id uuid references identity.users(id),
    created_at timestamptz not null default transaction_timestamp(),
    updated_at timestamptz not null default transaction_timestamp(),
    archived_at timestamptz
);

create index ix_resources_project_status on resource.resources(project_id, status, updated_at desc);
create index ix_resources_project_type on resource.resources(project_id, resource_type, status);

alter table resource.resources owner to migration_owner;
alter table resource.resources enable row level security;

create policy resources_member_select on resource.resources
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = resources.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on resource.resources from public;

create table resource.resource_versions (
    id uuid primary key default gen_random_uuid(),
    object_id uuid not null unique references taxonomy.object_registry(id),
    resource_id uuid not null references resource.resources(id),
    version_number integer not null check (version_number >= 1),
    content_kind text not null check (content_kind in ('text', 'file', 'link')),
    status text not null check (status in ('pending', 'available', 'failed')),
    content_hash text not null check (length(content_hash) = 64),
    change_summary text,
    created_by_user_id uuid references identity.users(id),
    created_at timestamptz not null default transaction_timestamp(),
    unique (resource_id, version_number)
);

create index ix_resource_versions_resource on resource.resource_versions(resource_id, version_number desc);

alter table resource.resource_versions owner to migration_owner;
alter table resource.resource_versions enable row level security;

create policy resource_versions_member_select on resource.resource_versions
    for select
    using (exists (
        select 1 from project.project_memberships pm
        join resource.resources r on r.id = resource_versions.resource_id
        where r.project_id = pm.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on resource.resource_versions from public;

create table resource.resource_heads (
    resource_id uuid primary key references resource.resources(id),
    current_version_id uuid not null unique references resource.resource_versions(id),
    current_version_number integer not null check (current_version_number >= 1),
    updated_at timestamptz not null default transaction_timestamp()
);

alter table resource.resource_heads owner to migration_owner;
alter table resource.resource_heads enable row level security;

create policy resource_heads_member_select on resource.resource_heads
    for select
    using (exists (
        select 1 from project.project_memberships pm
        join resource.resources r on r.id = resource_heads.resource_id
        where r.project_id = pm.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on resource.resource_heads from public;
