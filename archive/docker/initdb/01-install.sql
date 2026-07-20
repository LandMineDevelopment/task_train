\set ON_ERROR_STOP on
\i /workspace/sql/bootstrap_manifest.sql
\getenv worker_password POSTGRES_WORKER_PASSWORD
\i /workspace/sql/worker_role.sql
