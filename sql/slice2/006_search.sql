-- Slice 2: Phase 5 — Full-Text Search Documents

create table resource.resource_search_documents (
    resource_id uuid primary key references resource.resources(id),
    resource_version_id uuid not null references resource.resource_versions(id),
    project_id uuid not null references project.projects(id),
    resource_type text not null references resource.resource_types(resource_type),
    title_text text not null,
    description_text text,
    content_text text,
    filename_text text,
    link_text text,
    search_vector tsvector not null,
    updated_at timestamptz not null default transaction_timestamp()
);

create index ix_resource_search_documents_vector
    on resource.resource_search_documents using gin(search_vector);

create index ix_resource_search_documents_project
    on resource.resource_search_documents(project_id, updated_at desc);

alter table resource.resource_search_documents owner to migration_owner;
alter table resource.resource_search_documents enable row level security;

create policy search_documents_member_select on resource.resource_search_documents
    for select
    using (exists (
        select 1 from project.project_memberships pm
        where pm.project_id = resource_search_documents.project_id
          and pm.user_id = current_setting('app.current_user_id')::uuid
          and pm.status = 'active'
    ));

revoke all on resource.resource_search_documents from public;
