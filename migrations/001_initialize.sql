-- Bootstrap migration. The application will receive its own migration runner
-- once a PostgreSQL client library is selected and exercised.
CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO schema_migrations (version)
VALUES ('001_initialize')
ON CONFLICT (version) DO NOTHING;
