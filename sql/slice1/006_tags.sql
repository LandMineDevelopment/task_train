-- Slice 1: Phase 5 — Tags

-- 5.1 taxonomy.tags
create table taxonomy.tags (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    namespace text not null,
    name text not null,
    slug text not null,
    description text check (description is null or length(description) <= 2000),
    value_type text not null check (value_type in ('none', 'text', 'number', 'boolean', 'date')),
    status text not null check (status in ('active', 'archived')),
    revision bigint not null default 1 check (revision >= 1),
    created_by_user_id uuid not null references identity.users(id),
    created_at timestamptz not null default transaction_timestamp(),
    updated_at timestamptz not null default transaction_timestamp(),
    archived_at timestamptz
);

create unique index uq_tag_project_namespace_slug on taxonomy.tags (project_id, namespace, slug);
create index ix_tags_project_namespace_status on taxonomy.tags (project_id, namespace, status);
create index ix_tags_project_name on taxonomy.tags (project_id, lower(name));

alter table taxonomy.tags owner to migration_owner;
alter table taxonomy.tags enable row level security;

create policy tags_member_select on taxonomy.tags
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = tags.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on taxonomy.tags from public;

-- 5.2 taxonomy.tag_assignments
create table taxonomy.tag_assignments (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    object_id uuid not null references taxonomy.object_registry(id),
    tag_id uuid not null references taxonomy.tags(id),
    assignment_source text not null check (assignment_source in ('human', 'agent', 'system', 'import')),
    status text not null check (status in ('proposed', 'active', 'confirmed', 'rejected', 'removed')),
    text_value text,
    number_value numeric,
    boolean_value boolean,
    date_value date,
    assigned_by_user_id uuid references identity.users(id),
    assigned_by_object_id uuid references taxonomy.object_registry(id),
    confidence numeric check (confidence is null or confidence between 0 and 1),
    evidence_text text check (evidence_text is null or length(evidence_text) <= 4000),
    created_at timestamptz not null default transaction_timestamp(),
    reviewed_by_user_id uuid references identity.users(id),
    reviewed_at timestamptz,
    removed_by_user_id uuid references identity.users(id),
    removed_at timestamptz,
    removal_reason text check (removal_reason is null or length(removal_reason) <= 1000)
);

create unique index uq_tag_assignment_current
    on taxonomy.tag_assignments (object_id, tag_id)
    where status in ('proposed', 'active', 'confirmed');

create index ix_tag_assignments_object_status on taxonomy.tag_assignments (object_id, status, created_at desc);
create index ix_tag_assignments_tag_status on taxonomy.tag_assignments (tag_id, status, created_at desc);
create index ix_tag_assignments_project on taxonomy.tag_assignments (project_id, status, created_at desc);

alter table taxonomy.tag_assignments owner to migration_owner;
alter table taxonomy.tag_assignments enable row level security;

create policy tag_assignments_member_select on taxonomy.tag_assignments
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = tag_assignments.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on taxonomy.tag_assignments from public;

-- 5.3 Tag assignment integrity triggers
create or replace function taxonomy.check_tag_assignment()
returns trigger
language plpgsql
as $$
declare
    v_tag_status text;
    v_tag_value_type text;
    v_object_type text;
    v_object_taggable boolean;
    v_tag_project_id uuid;
    v_object_project_id uuid;
begin
    -- Get tag info
    select t.status, t.value_type, t.project_id
    into v_tag_status, v_tag_value_type, v_tag_project_id
    from taxonomy.tags t
    where t.id = new.tag_id;

    -- Get object info
    select ot.taggable, o.project_id
    into v_object_taggable, v_object_project_id
    from taxonomy.object_registry o
    join taxonomy.object_types ot on ot.object_type = o.object_type
    where o.id = new.object_id;

    -- 5.3.3: Prevent assignment to archived tag
    if v_tag_status = 'archived' then
        raise exception 'TAG_ARCHIVED: Archived tag cannot receive new assignments.';
    end if;

    -- 5.3.4: Prevent assignment to non-taggable object type
    if not v_object_taggable then
        raise exception 'OBJECT_TYPE_NOT_TAGGABLE: Object type does not permit tags.';
    end if;

    -- 5.3.1: Validate project_id matches both object and tag
    if v_tag_project_id != v_object_project_id then
        raise exception 'OBJECT_PROJECT_MISMATCH: Referenced records belong to different projects.';
    end if;
    if new.project_id != v_tag_project_id then
        raise exception 'OBJECT_PROJECT_MISMATCH: Assignment project must match tag and object project.';
    end if;

    -- 5.3.2: Enforce exactly-one-value rule by value_type
    if v_tag_value_type = 'none' then
        if new.text_value is not null or new.number_value is not null
           or new.boolean_value is not null or new.date_value is not null
        then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag value_type is none but value arguments were provided.';
        end if;
    elsif v_tag_value_type = 'text' then
        if new.text_value is null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a text value.';
        end if;
        if new.number_value is not null or new.boolean_value is not null or new.date_value is not null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Only text_value should be set for text tags.';
        end if;
    elsif v_tag_value_type = 'number' then
        if new.number_value is null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a number value.';
        end if;
        if new.text_value is not null or new.boolean_value is not null or new.date_value is not null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Only number_value should be set for number tags.';
        end if;
    elsif v_tag_value_type = 'boolean' then
        if new.boolean_value is null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a boolean value.';
        end if;
        if new.text_value is not null or new.number_value is not null or new.date_value is not null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Only boolean_value should be set for boolean tags.';
        end if;
    elsif v_tag_value_type = 'date' then
        if new.date_value is null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Tag requires a date value.';
        end if;
        if new.text_value is not null or new.number_value is not null or new.boolean_value is not null then
            raise exception 'TAG_VALUE_TYPE_MISMATCH: Only date_value should be set for date tags.';
        end if;
    end if;

    return new;
end;
$$;

alter function taxonomy.check_tag_assignment() owner to migration_owner;

create trigger trg_tag_assignment_check
    before insert on taxonomy.tag_assignments
    for each row
    execute function taxonomy.check_tag_assignment();
