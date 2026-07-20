-- Slice 1: Phase 2 — Identity Model

-- 2.1 identity.users
create table identity.users (
    id uuid primary key default gen_random_uuid(),
    display_name text not null check (length(trim(display_name)) between 1 and 100),
    email_display text,
    status text not null default 'active' check (status in ('active', 'disabled', 'deleted')),
    created_at timestamptz not null default transaction_timestamp(),
    updated_at timestamptz not null default transaction_timestamp()
);

alter table identity.users owner to migration_owner;

-- RLS enabled; SELECT policy deferred until internal_api.current_user_id() exists (Phase 8).
-- All access goes through SECURITY DEFINER functions, so default-deny is correct.
alter table identity.users enable row level security;

revoke all on identity.users from public;

-- 2.2 identity.auth_identities
create table identity.auth_identities (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references identity.users(id),
    issuer text not null,
    subject text not null,
    provider text not null default 'supabase',
    email_at_last_login text,
    created_at timestamptz not null default transaction_timestamp(),
    last_authenticated_at timestamptz,
    unique (issuer, subject)
);

create index ix_auth_identity_user on identity.auth_identities (user_id);

alter table identity.auth_identities owner to migration_owner;

revoke all on identity.auth_identities from public;
