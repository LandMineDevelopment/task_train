-- Slice 1: Phase 3 — Project Model

-- 3.1 project.projects
create table project.projects (
    id uuid primary key default gen_random_uuid(),
    project_kind text not null check (project_kind in ('personal', 'shared')),
    name text not null check (length(trim(name)) between 1 and 120),
    slug text not null,
    description text check (description is null or length(description) <= 2000),
    created_by_user_id uuid not null references identity.users(id),
    status text not null check (status in ('active', 'archived')),
    revision bigint not null default 1 check (revision >= 1),
    created_at timestamptz not null default transaction_timestamp(),
    updated_at timestamptz not null default transaction_timestamp(),
    archived_at timestamptz
);

create unique index uq_project_slug on project.projects (slug);
create unique index uq_personal_project_owner on project.projects (created_by_user_id)
    where project_kind = 'personal';

alter table project.projects owner to migration_owner;
alter table project.projects enable row level security;
revoke all on project.projects from public;

-- 3.2 project.project_memberships
create table project.project_memberships (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null references project.projects(id),
    user_id uuid not null references identity.users(id),
    role text not null check (role in ('owner', 'member')),
    status text not null check (status in ('active', 'disabled')),
    revision bigint not null default 1 check (revision >= 1),
    added_by_user_id uuid references identity.users(id),
    created_at timestamptz not null default transaction_timestamp(),
    updated_at timestamptz not null default transaction_timestamp(),
    disabled_at timestamptz
);

create unique index uq_project_membership on project.project_memberships (project_id, user_id);
create index ix_project_membership_user_status on project.project_memberships (user_id, status, project_id);

alter table project.project_memberships owner to migration_owner;
alter table project.project_memberships enable row level security;
revoke all on project.project_memberships from public;

-- RLS policies (after both tables exist)
create policy projects_member_select on project.projects
    for select
    using (exists (
        select 1 from project.project_memberships
        where project_id = id
          and user_id = current_setting('app.current_user_id')::uuid
          and status = 'active'
    ));

create policy projects_owner_update on project.projects
    for update
    using (exists (
        select 1 from project.project_memberships
        where project_id = id
          and user_id = current_setting('app.current_user_id')::uuid
          and role = 'owner'
          and status = 'active'
    ))
    with check (exists (
        select 1 from project.project_memberships
        where project_id = id
          and user_id = current_setting('app.current_user_id')::uuid
          and role = 'owner'
          and status = 'active'
    ));

create policy memberships_member_select on project.project_memberships
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

create policy memberships_owner_all on project.project_memberships
    for all
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.role = 'owner'
          and pm.status = 'active'
    ))
    with check (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.role = 'owner'
          and pm.status = 'active'
    ));

-- 3.3 Final-owner integrity triggers
create or replace function project.prevent_last_owner()
returns trigger
language plpgsql
as $$
declare
    v_active_owner_count bigint;
begin
    if tg_op in ('UPDATE', 'DELETE') then
            if old.role = 'owner' and old.status = 'active' then
                select count(*) into v_active_owner_count
                from project.project_memberships
                where project_id = old.project_id
                  and role = 'owner'
                  and status = 'active'
                  and id != old.id;

                if v_active_owner_count = 0 then
                    raise exception 'PROJECT_LAST_OWNER: Action would leave the project without an active owner.';
                end if;
            end if;
        end if;

        if tg_op = 'UPDATE' then
        if old.role = 'owner' and old.status = 'active'
           and (new.role != 'owner' or new.status != 'active')
        then
            raise exception 'PROJECT_LAST_OWNER: Final active owner cannot be disabled or demoted.';
        end if;
    end if;

    return coalesce(new, old);
end;
$$;

alter function project.prevent_last_owner() owner to migration_owner;

create trigger trg_membership_prevent_last_owner
    before update or delete on project.project_memberships
    for each row
    execute function project.prevent_last_owner();
