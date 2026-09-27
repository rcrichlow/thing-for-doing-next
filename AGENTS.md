# Repository Guide

## Workflow

- Use `mise run dev` for Docker-based hot reload. It bind-mounts the repository; edits to `src/`, `migrations/`, or `build.zig` rebuild and restart only the app process.
- Use `mise run test` to run tests in the Zig development container. It creates the `thing_for_doing_next_test` database if missing and sets `TEST_DATABASE_URL`, enabling integration tests. Local `zig build test` requires Zig 0.16.0 and `libpq` development files, and skips integration tests unless `TEST_DATABASE_URL` is set.
- Docker runs rootless on this machine (user `docker.service`, `rootless` context).
- Use `mise run prod` for the production image; it builds with `-Doptimize=ReleaseSafe`. The `app` and `app-dev` services share the same `db` service and Postgres volume but both claim host port `3000`, so run only one at a time.
- `mise run down` preserves Postgres data. `docker compose down --volumes` deletes it.

## Application

- `src/main.zig` is the sole HTTP entrypoint and routing location. The app uses Zig's standard HTTP server. At startup it requires `DATABASE_URL`, opens the database pool, and applies migrations before listening; any failure exits the process.
- Each connection runs as a task in an `Io.Group` on `Io.Threaded`, whose `concurrent_limit` (`max_concurrent_tasks`, 16) is process-wide and shared with any other `concurrent` work. Connections beyond the limit get a 503. There is no idle keep-alive timeout yet.
- Routing is an if-chain in `route`: compare static paths directly, use `pathParam("/x/{id}", path)` for one captured segment, and `switch` on method with `methodNotAllowed` as the fallback. `Context.path` excludes the query string and is not percent-decoded.
- Handlers get a `Context` with a per-request arena. Read bodies with `Context.readForm` (urlencoded only, 64 KiB max) and query strings with `Context.queryForm`. Return `error.PayloadTooLarge`, `error.UnsupportedMediaType`, or `error.InvalidForm` for 4xx; other errors become a 500. Handlers must respond exactly once, as their last action, so errors never follow partial output.
- Requests with a body method but no `Content-Length` or chunked encoding get a 411 before routing; `std.http.Server` asserts on discarding such bodies.
- HTML is compiled into the binary through `@embedFile`. `src/template.zig` supports only escaped `{{field}}` interpolation from a struct whose fields are `[]const u8`; it intentionally has no control flow, partials, or trusted/raw HTML. Compose in Zig instead: `src/layout.zig` writes `public/layout/` fragments around page bodies in `public/pages/` and renders nav with `public/components/`. Loop in Zig to render repeated items.
- Template parsing occurs at comptime. Keep third-party JavaScript out of templates; serve it as a static asset when vendored. Pages render into a growable arena buffer via `Context.page` before responding.

## Database

- `src/db.zig` is the app-owned PostgreSQL API (`Pool`, `Conn.exec/query/row`, `Result.next`, `Row.get(T, col)`, `error.PG` with details in `conn.err`). It is intentionally shaped like pg.zig so the libpq implementation can be swapped. Only `src/db.zig` may import `src/db/libpq.zig`.
- Parameters and results use PostgreSQL text format; parameter types are inferred by the server, so cast ambiguous ones in SQL (`$1::text`). `Row.get` is strict: `i16`/`i32`/`i64` need smallint/int/bigint, `bool` needs boolean, `[]const u8` reads any column's text; use `?T` for nullable columns. Returned slices live until the result is deinitialized.
- Handlers get their connection from `ctx.dbConn()`, which acquires one lazily and releases it after the response. Hold at most one connection per request; the pool is sized to `max_concurrent_tasks` so requests never wait. Released connections with an open transaction are rolled back.
- Put SQL and row mapping in per-feature query modules (e.g. `src/entries.zig`) that take a `*db.Conn`; handlers never write SQL.
- Migrations are `migrations/*.sql`, embedded by `build.zig`, applied in filename order at startup by `src/migrate.zig`. Each runs in a transaction with its `schema_migrations` row, under an advisory lock. They are forward-only, must not contain transaction control, and must never be edited once applied. Name them `NNN_description.sql` using letters, digits, `_`, and `-`.
- Database integration tests call `db.testing.pool(size)`, which skips without `TEST_DATABASE_URL`, refuses databases not ending in `_test`, and resets the `public` schema.
