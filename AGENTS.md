# Repository Guide

## Workflow

- Use `mise run dev` for Docker-based hot reload. It bind-mounts the repository; edits to `src/` or `build.zig` rebuild and restart only the app process.
- Use `mise run test` to run tests in the Zig development container. Local `zig build test` requires Zig 0.16.0 and `libpq` development files.
- Use `mise run prod` for the production image; it builds with `-Doptimize=ReleaseSafe`. The `app` and `app-dev` services share the same `db` service and Postgres volume but both claim host port `3000`, so run only one at a time.
- `mise run down` preserves Postgres data. `docker compose down --volumes` deletes it.

## Application

- `src/main.zig` is the sole HTTP entrypoint and routing location. The app uses Zig's standard HTTP server and links `libpq`, but no PostgreSQL client is implemented yet.
- Each connection runs as a task in an `Io.Group` on `Io.Threaded`, whose `concurrent_limit` (`max_concurrent_tasks`, 16) is process-wide and shared with any other `concurrent` work. Connections beyond the limit get a 503. There is no idle keep-alive timeout yet.
- Routing is an if-chain in `route`: compare static paths directly, use `pathParam("/x/{id}", path)` for one captured segment, and `switch` on method with `methodNotAllowed` as the fallback. `Context.path` excludes the query string and is not percent-decoded.
- Handlers get a `Context` with a per-request arena. Read bodies with `Context.readForm` (urlencoded only, 64 KiB max) and query strings with `Context.queryForm`. Return `error.PayloadTooLarge`, `error.UnsupportedMediaType`, or `error.InvalidForm` for 4xx; other errors become a 500. Handlers must respond exactly once, as their last action, so errors never follow partial output.
- Requests with a body method but no `Content-Length` or chunked encoding get a 411 before routing; `std.http.Server` asserts on discarding such bodies.
- HTML is compiled into the binary through `@embedFile`. `src/template.zig` supports only escaped `{{field}}` interpolation from a struct whose fields are `[]const u8`; it intentionally has no control flow, partials, or trusted/raw HTML. Compose in Zig instead: `src/layout.zig` writes `public/layout/` fragments around page bodies in `public/pages/` and renders nav with `public/components/`. Loop in Zig to render repeated items.
- Template parsing occurs at comptime. Keep third-party JavaScript out of templates; serve it as a static asset when vendored. Pages render into a growable arena buffer via `Context.page` before responding.

## Database

- `migrations/` is mounted only into Postgres initialization and runs only when `postgres_data` is first created. It is temporary bootstrap infrastructure, not an application migration system.
