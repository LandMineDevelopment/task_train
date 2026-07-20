-- Slice 1: Phase 7 — Command Deduplication

create table platform.command_requests (
    id uuid primary key default gen_random_uuid(),
    initiating_user_id uuid not null references identity.users(id),
    project_id uuid references project.projects(id),
    function_key text not null,
    idempotency_key text not null check (length(idempotency_key) between 1 and 200),
    status text not null check (status in ('started', 'completed', 'failed')),
    result_entity_kind text,
    result_entity_id uuid,
    error_code text,
    created_at timestamptz not null default transaction_timestamp(),
    completed_at timestamptz
);

create unique index uq_command_request_idempotency
    on platform.command_requests (initiating_user_id, function_key, idempotency_key);

alter table platform.command_requests owner to migration_owner;
revoke all on platform.command_requests from public;
