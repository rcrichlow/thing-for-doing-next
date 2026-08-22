# Repository Guide

## Workflow

- Use `mise run dev` for Docker-based hot reload. It bind-mounts the repository; edits to `src/` or `build.zig` rebuild and restart only the app process.
- Use `mise run test` to run tests in the Zig development container. Local `zig build test` requires Zig 0.16.0 and `libpq` development files.
- Use `mise run prod` for the production image; it builds with `-Doptimize=ReleaseSafe`. The `app` and `app-dev` services share the same `db` service and Postgres volume but both claim host port `3000`, so run only one at a time.
- `mise run down` preserves Postgres data. `docker compose down --volumes` deletes it.

## Application

- `src/main.zig` is the sole HTTP entrypoint and routing location. The app uses Zig's standard HTTP server and links `libpq`, but no PostgreSQL client is implemented yet.
- HTML is compiled into the binary through `@embedFile`. `src/template.zig` supports only escaped `{{field}}` interpolation from a struct whose fields are `[]const u8`; it intentionally has no control flow, partials, or trusted/raw HTML.
- Template parsing occurs at comptime. Keep third-party JavaScript out of templates; serve it as a static asset when vendored. Page responses currently render into a fixed 16 KiB buffer in `route`.

## Database

- `migrations/` is mounted only into Postgres initialization and runs only when `postgres_data` is first created. It is temporary bootstrap infrastructure, not an application migration system.
