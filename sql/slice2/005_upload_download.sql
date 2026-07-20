-- Slice 2: Phase 4 — Upload Reservations and Download Requests

create table resource.upload_reservations (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    operation_type text not null check (operation_type in ('create_resource', 'create_version')),
    target_resource_id uuid references resource.resources(id),
    expected_version_number integer check (expected_version_number is null or expected_version_number >= 1),
    resource_type text not null references resource.resource_types(resource_type),
    requested_title text,
    original_filename text not null,
    declared_media_type text not null,
    declared_byte_size bigint not null check (declared_byte_size >= 0),
    provider text not null,
    bucket text not null,
    object_key text not null,
    status text not null check (status in ('reserved', 'uploaded', 'finalized', 'expired', 'cancelled', 'failed')) default 'reserved',
    requested_by_user_id uuid not null references identity.users(id),
    observed_content_hash text check (observed_content_hash is null or length(observed_content_hash) = 64),
    observed_byte_size bigint check (observed_byte_size is null or observed_byte_size >= 0),
    observed_media_type text,
    provider_version text,
    created_at timestamptz not null default transaction_timestamp(),
    expires_at timestamptz not null,
    uploaded_at timestamptz,
    finalized_at timestamptz,
    cancelled_at timestamptz,
    unique (provider, bucket, object_key)
);

create index ix_upload_reservations_expiration
    on resource.upload_reservations(expires_at)
    where status in ('reserved', 'uploaded');

alter table resource.upload_reservations owner to migration_owner;
alter table resource.upload_reservations enable row level security;

create policy upload_reservations_member_select on resource.upload_reservations
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = upload_reservations.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on resource.upload_reservations from public;

create table resource.download_requests (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    resource_version_id uuid not null references resource.resource_versions(id),
    storage_object_id uuid not null references resource.storage_objects(id),
    requested_by_user_id uuid not null references identity.users(id),
    status text not null check (status in ('created', 'consumed', 'expired', 'cancelled')) default 'created',
    created_at timestamptz not null default transaction_timestamp(),
    expires_at timestamptz not null,
    consumed_at timestamptz
);

create index ix_download_requests_expiration
    on resource.download_requests(expires_at)
    where status = 'created';

alter table resource.download_requests owner to migration_owner;
alter table resource.download_requests enable row level security;

create policy download_requests_member_select on resource.download_requests
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = download_requests.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on resource.download_requests from public;
