-- Slice 1: Phase 6 — Relationships

-- 6.1 taxonomy.relationship_types
create table taxonomy.relationship_types (
    relationship_type text primary key,
    display_name text not null,
    inverse_type text references taxonomy.relationship_types(relationship_type),
    is_symmetric boolean not null default false,
    enabled boolean not null default true,
    created_at timestamptz not null default transaction_timestamp()
);

alter table taxonomy.relationship_types owner to migration_owner;
revoke all on taxonomy.relationship_types from public;

-- 6.2 taxonomy.object_relationships
create table taxonomy.object_relationships (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    source_object_id uuid not null references taxonomy.object_registry(id),
    relationship_type text not null references taxonomy.relationship_types(relationship_type),
    target_object_id uuid not null references taxonomy.object_registry(id),
    status text not null check (status in ('proposed', 'active', 'rejected', 'removed')),
    created_by_user_id uuid references identity.users(id),
    created_by_object_id uuid references taxonomy.object_registry(id),
    confidence numeric check (confidence is null or confidence between 0 and 1),
    evidence_text text check (evidence_text is null or length(evidence_text) <= 4000),
    created_at timestamptz not null default transaction_timestamp(),
    reviewed_by_user_id uuid references identity.users(id),
    reviewed_at timestamptz,
    removed_by_user_id uuid references identity.users(id),
    removed_at timestamptz,
    removal_reason text check (removal_reason is null or length(removal_reason) <= 1000),
    constraint no_self_relationship check (source_object_id <> target_object_id)
);

create unique index uq_object_relationship_current
    on taxonomy.object_relationships (source_object_id, relationship_type, target_object_id)
    where status in ('proposed', 'active');

create index ix_relationship_source_status on taxonomy.object_relationships (source_object_id, status, created_at desc);
create index ix_relationship_target_status on taxonomy.object_relationships (target_object_id, status, created_at desc);

alter table taxonomy.object_relationships owner to migration_owner;
alter table taxonomy.object_relationships enable row level security;

create policy object_relationships_member_select on taxonomy.object_relationships
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = object_relationships.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on taxonomy.object_relationships from public;

-- 6.3 Relationship integrity triggers
create or replace function taxonomy.check_object_relationship()
returns trigger
language plpgsql
as $$
declare
    v_rel_type_enabled boolean;
    v_rel_symmetric boolean;
    v_source_project uuid;
    v_target_project uuid;
    v_source_relatable boolean;
    v_target_relatable boolean;
    v_canon_source uuid;
    v_canon_target uuid;
begin
    -- Get relationship type info
    select rt.enabled, rt.is_symmetric
    into v_rel_type_enabled, v_rel_symmetric
    from taxonomy.relationship_types rt
    where rt.relationship_type = new.relationship_type;

    -- 6.3.1: Relationship type must be enabled
    if not v_rel_type_enabled then
        raise exception 'RELATIONSHIP_TYPE_INVALID: Relationship type is disabled or unknown.';
    end if;

    -- Get source and target project + relatability
    select o.project_id, ot.relatable
    into v_source_project, v_source_relatable
    from taxonomy.object_registry o
    join taxonomy.object_types ot on ot.object_type = o.object_type
    where o.id = new.source_object_id;

    select o.project_id, ot.relatable
    into v_target_project, v_target_relatable
    from taxonomy.object_registry o
    join taxonomy.object_types ot on ot.object_type = o.object_type
    where o.id = new.target_object_id;

    -- 6.3.1: Validate project equality
    if v_source_project != v_target_project then
        raise exception 'OBJECT_PROJECT_MISMATCH: Source and target belong to different projects.';
    end if;
    if new.project_id != v_source_project then
        raise exception 'OBJECT_PROJECT_MISMATCH: Relationship project must match source and target project.';
    end if;

    -- 6.3.2: Prevent relationship to non-relatable object types
    if not v_source_relatable then
        raise exception 'OBJECT_TYPE_NOT_RELATABLE: Source object type does not permit relationships.';
    end if;
    if not v_target_relatable then
        raise exception 'OBJECT_TYPE_NOT_RELATABLE: Target object type does not permit relationships.';
    end if;

    -- 6.3.3: Canonicalize symmetric edge ordering
    if v_rel_symmetric is true then
        v_canon_source := least(new.source_object_id, new.target_object_id);
        v_canon_target := greatest(new.source_object_id, new.target_object_id);
        new.source_object_id := v_canon_source;
        new.target_object_id := v_canon_target;
    end if;

    return new;
end;
$$;

alter function taxonomy.check_object_relationship() owner to migration_owner;

create trigger trg_object_relationship_check
    before insert on taxonomy.object_relationships
    for each row
    execute function taxonomy.check_object_relationship();
