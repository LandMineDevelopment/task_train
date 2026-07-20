#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"

if [ ! -f "$EXAMPLE_FILE" ]; then
  echo "Missing $EXAMPLE_FILE — cannot continue."
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  echo ".env already exists. Remove it first to regenerate."
  echo "  rm $ENV_FILE"
  exit 1
fi

umask 077

# Use hex for URL-safe passwords (no + / = chars that break connection URLs)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
SECRET_KEY_BASE=$(openssl rand -hex 48)
VAULT_ENC_KEY=$(openssl rand -hex 16)
REALTIME_DB_ENC_KEY=$(openssl rand -hex 8)
PG_META_CRYPTO_KEY=$(openssl rand -hex 24)
S3_ACCESS_KEY=$(openssl rand -hex 16)
S3_SECRET_KEY=$(openssl rand -hex 32)
DASHBOARD_PASSWORD=$(openssl rand -hex 16)

sed \
  -e "s|your-super-secret-postgres-password|$POSTGRES_PASSWORD|" \
  -e "s|your-super-secret-jwt-token-at-least-32-characters|$JWT_SECRET|" \
  -e "s|this_password_is_insecure_and_should_be_updated|$DASHBOARD_PASSWORD|" \
  -e "s|your-secret-key-base-at-least-64-chars|$SECRET_KEY_BASE|" \
  -e "s|your-32-character-encryption-key|$VAULT_ENC_KEY|" \
  -e "s|supabaserealtime|$REALTIME_DB_ENC_KEY|" \
  -e "s|your-encryption-key-32-chars-min|$PG_META_CRYPTO_KEY|" \
  -e "s|your-s3-access-key-id|$S3_ACCESS_KEY|" \
  -e "s|your-s3-secret-access-key|$S3_SECRET_KEY|" \
  "$EXAMPLE_FILE" > "$ENV_FILE"

echo "Generated $ENV_FILE with secure random values."
echo
echo "To start Supabase services:"
echo "  docker compose up -d"
echo
echo "Supabase Studio: http://localhost:8000"
echo "PostgREST API:   http://localhost:8000/rest/v1"
echo "Auth API:        http://localhost:8000/auth/v1"
echo
echo "PostgreSQL (via supavisor): psql postgres://postgres:$POSTGRES_PASSWORD@localhost:${SUPABASE_DB_PORT:-5435}/task_train"
