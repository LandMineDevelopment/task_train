-- Slice 2: Phase 3 — Typed Content Tables

create table resource.text_contents (
    resource_version_id uuid primary key references resource.resource_versions(id),
    body_text text not null,
    text_format text not null check (text_format in ('plain_text', 'markdown', 'code', 'diff')),
    language_code text
);

alter table resource.text_contents owner to migration_owner;
revoke all on resource.text_contents from public;

create table resource.storage_objects (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    provider text not null,
    bucket text not null,
    object_key text not null,
    provider_version text,
    content_hash text not null check (length(content_hash) = 64),
    byte_size bigint not null check (byte_size >= 0),
    media_type text not null,
    verification_status text not null check (verification_status in ('unverified', 'verified', 'missing', 'deleted')) default 'unverified',
    created_by_user_id uuid references identity.users(id),
    created_at timestamptz not null default transaction_timestamp(),
    verified_at timestamptz,
    missing_at timestamptz,
    deleted_at timestamptz,
    unique (provider, bucket, object_key)
);

create index ix_storage_objects_project on resource.storage_objects(project_id, verification_status);
create index ix_storage_objects_hash on resource.storage_objects(content_hash);

alter table resource.storage_objects owner to migration_owner;
alter table resource.storage_objects enable row level security;

create policy storage_objects_member_select on resource.storage_objects
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = storage_objects.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on resource.storage_objects from public;

create table resource.file_contents (
    resource_version_id uuid primary key references resource.resource_versions(id),
    storage_object_id uuid not null unique references resource.storage_objects(id),
    original_filename text not null check (length(trim(original_filename)) > 0),
    media_type text not null,
    byte_size bigint not null check (byte_size >= 0)
);

alter table resource.file_contents owner to migration_owner;
revoke all on resource.file_contents from public;

create table resource.link_contents (
    resource_version_id uuid primary key references resource.resource_versions(id),
    url text not null,
    normalized_url text not null,
    host_name text not null,
    link_title text,
    link_description text
);

alter table resource.link_contents owner to migration_owner;
revoke all on resource.link_contents from public;

-- Exactly-one-content invariant (deferred constraint trigger)
create or replace function resource.check_single_content()
returns trigger
language plpgsql
as $$
declare
    v_resource_id uuid;
    v_content_kind text;
    v_text_count int;
    v_file_count int;
    v_link_count int;
begin
    select rv.resource_id, rv.content_kind
    into v_resource_id, v_content_kind
    from resource.resource_versions rv
    where rv.id = coalesce(new.resource_version_id, old.resource_version_id);

    select
        (select count(*) from resource.text_contents tc where tc.resource_version_id = coalesce(new.resource_version_id, old.resource_version_id)),
        (select count(*) from resource.file_contents fc where fc.resource_version_id = coalesce(new.resource_version_id, old.resource_version_id)),
        (select count(*) from resource.link_contents lc where lc.resource_version_id = coalesce(new.resource_version_id, old.resource_version_id))
    into v_text_count, v_file_count, v_link_count;

    if v_text_count + v_file_count + v_link_count > 1 then
        raise exception 'RESOURCE_CONTENT_INVARIANT: Version may have at most one typed content row.'
            using detail = 'RESOURCE_CONTENT_INVARIANT';
    end if;

    return coalesce(new, old);
end;
$$;

alter function resource.check_single_content() owner to migration_owner;

create constraint trigger trg_text_content_single
    after insert or update or delete on resource.text_contents
    deferrable initially deferred
    for each row
    execute function resource.check_single_content();

create constraint trigger trg_file_content_single
    after insert or update or delete on resource.file_contents
    deferrable initially deferred
    for each row
    execute function resource.check_single_content();

create constraint trigger trg_link_content_single
    after insert or update or delete on resource.link_contents
    deferrable initially deferred
    for each row
    execute function resource.check_single_content();
