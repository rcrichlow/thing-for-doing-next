-- Migration bookkeeping. The migrations themselves live in migrations/.

-- name: lock
SELECT pg_advisory_lock($1);

-- name: unlock
SELECT pg_advisory_unlock($1);

-- name: create_table
CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

-- name: is_applied
SELECT 1 FROM schema_migrations WHERE version = $1;

-- name: record
INSERT INTO schema_migrations (version) VALUES ($1);
