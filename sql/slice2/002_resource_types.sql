-- Slice 2: Phase 1 — Resource-Type Registry

create table resource.resource_types (
    resource_type text primary key,
    display_name text not null,
    user_creatable boolean not null default true,
    worker_creatable boolean not null default false,
    enabled boolean not null default true,
    created_at timestamptz not null default transaction_timestamp()
);

alter table resource.resource_types owner to migration_owner;
revoke all on resource.resource_types from public;

create table resource.resource_type_content_kinds (
    resource_type text not null references resource.resource_types(resource_type),
    content_kind text not null check (content_kind in ('text', 'file', 'link')),
    is_default boolean not null,
    created_at timestamptz not null default transaction_timestamp(),
    primary key (resource_type, content_kind)
);

alter table resource.resource_type_content_kinds owner to migration_owner;
revoke all on resource.resource_type_content_kinds from public;

create unique index uq_resource_type_default_kind
    on resource.resource_type_content_kinds (resource_type)
    where is_default = true;

insert into resource.resource_types (resource_type, display_name, user_creatable, worker_creatable) values
    ('note',          'Note',           true,  false),
    ('file',          'File',           true,  false),
    ('link',          'Link',           true,  false),
    ('code_artifact', 'Code Artifact',  false, true),
    ('git_diff',      'Git Diff',       false, true),
    ('agent_output',  'Agent Output',   false, true);

insert into resource.resource_type_content_kinds (resource_type, content_kind, is_default) values
    ('note',          'text', true),
    ('file',          'file', true),
    ('link',          'link', true),
    ('code_artifact', 'file', true),
    ('git_diff',      'text', true),
    ('agent_output',  'text', true),
    ('agent_output',  'file', false);
