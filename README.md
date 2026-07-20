# Supabase Self-Hosted — Task Train Prototype

Self-hosted Supabase stack for the Slice 1 prototype. Provides PostgreSQL (with extensions), PostgREST, Auth (GoTrue), Storage, Realtime, and Studio dashboard.

## Quick Start

```bash
cd docker/supabase
bash setup.sh              # generate .env with random secrets
docker compose up -d       # start all services
```

Secrets are generated automatically by `setup.sh`. If you need to regenerate, delete `.env` and re-run.

## Access

| Service              | URL                             |
|----------------------|---------------------------------|
| Studio (dashboard)   | http://localhost:8000            |
| PostgREST API        | http://localhost:8000/rest/v1    |
| Auth API             | http://localhost:8000/auth/v1    |
| Storage API          | http://localhost:8000/storage/v1 |
| PostgreSQL (direct)  | `localhost:5432`                 |

### Studio login

| Field    | Default value     |
|----------|-------------------|
| Username | `supabase`        |
| Password | generated in .env |

### PostgreSQL connect

```bash
psql postgres://postgres:<password>@localhost:5432/task_train
```

The password is in `docker/supabase/.env` under `POSTGRES_PASSWORD`.

## Services

- **db** — `supabase/postgres:17.6.1.136` with pg_cron, pgsodium, pgjwt, pg_net, and other extensions
- **rest** — `postgrest/postgrest:v14.12` exposing the function API
- **auth** — `supabase/gotrue:v2.189.0` (GoTrue) for identity
- **kong** — `kong/kong:3.9.1` API gateway routing all requests
- **studio** — Supabase dashboard for managing the database
- **storage** — `supabase/storage-api:v1.60.4` for file storage
- **realtime** — `supabase/realtime:v2.102.3` for subscriptions
- **meta** — `supabase/postgres-meta` for schema introspection
- **functions** — `supabase/edge-runtime:v1.74.0` for edge functions
- **supavisor** — `supabase/supavisor:2.9.5` connection pooler
- **imgproxy** — Image transformation proxy

## Daily Commands

| Action                      | Command                        |
|-----------------------------|--------------------------------|
| Start                       | `docker compose up -d`         |
| Stop                        | `docker compose down`          |
| Status                      | `docker compose ps`            |
| Logs (all)                  | `docker compose logs -f`       |
| Logs (specific)             | `docker compose logs -f rest`  |
| Rebuild                     | `docker compose up -d --build` |
| Full reset                  | `docker compose down -v && bash setup.sh && docker compose up -d` |

## PostgREST

The REST API exposes schemas `public`, `app_api_v1`, and `operator_api_v1` (configurable via `PGRST_DB_SCHEMAS` in `.env`).

Requests to `/rest/v1/` require a valid JWT or an API key:
- `anon` role — `apikey` header with `ANON_KEY` value (limited access)
- `service_role` — `apikey` header with `SERVICE_ROLE_KEY` value (admin access)

Both keys are in `docker/supabase/.env`.

## Architecture Notes

- The Supabase db runs alongside the project's existing PostgreSQL; they are independent instances.
- Supabase schemas (`auth`, `_realtime`, `_supabase`, `extensions`) do not conflict with the existing `tagg` schema.
- Slice 1 functions should be placed in schemas exposed via `PGRST_DB_SCHEMAS` (default: `public`, `app_api_v1`, `operator_api_v1`).
