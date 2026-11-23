# Thing for Doing Next

An experimental personal application built to evaluate Zig, server-rendered HTML, HTMX, and PostgreSQL.

## Stack

- Zig HTTP server with a libpq PostgreSQL client
- PostgreSQL 17
- Docker Compose for local development and deployment-like validation
- HTMX 4.0.0-beta6, vendored locally and served as an embedded static asset

Docker is intentional here. It keeps the database, compiler/runtime assumptions, and production-style image build reproducible while the stack is being evaluated. The application image is a multi-stage build and does not include the Zig compiler at runtime.

## Development

```bash
mise run dev
```

- App: `http://localhost:3000`
- Health check: `http://localhost:3000/up`
- PostgreSQL: `localhost:5433`

The development container mounts the source tree. Changes to `src/` or `build.zig` rebuild and restart only the app process; the database container and application container remain running.

The development watcher rebuilds Tailwind CSS from `src/` into `src/public/app.css` before recompiling the app. The generated stylesheet is embedded and served at `/assets/styles.css` with `Cache-Control: no-cache` so browsers revalidate it on each use. Don't serve it at `/assets/app.css`: an early build sent that URL with year-long immutable caching, so browsers that loaded it would keep using a stale copy.

HTMX is vendored in `src/public/htmx-4.0.0-beta6.min.js` from [the pinned distribution](https://cdn.jsdelivr.net/npm/htmx.org@4.0.0-beta6/dist/htmx.min.js), with its license in `src/public/htmx-LICENSE.txt`. It is embedded directly as JavaScript and served at `/assets/htmx-4.0.0-beta6.min.js` with immutable caching. When upgrading HTMX, update the versioned filename, embedded asset route, and script URL together.

## HTTP Server Limits

- At most 16 connections are served concurrently; further connections receive `503 Service Unavailable` and are closed.
- Idle keep-alive connections are not timed out yet, so each holds a slot until the client closes it. Revisit before exposing the app beyond local use.
- Request bodies are limited to 64 KiB and must be `application/x-www-form-urlencoded`, which matches HTMX's default encoding.

## Production Image

Build and run the production-style image with:

```bash
mise run prod
```

Stop services with:

```bash
mise run down
```

To also delete local database data:

```bash
docker compose down --volumes
```

## Local Development Commands

With Zig 0.16.0 and libpq installed locally:

```bash
zig build test
zig build
DATABASE_URL=postgresql://thing_for_doing:thing_for_doing@localhost:5433/thing_for_doing_next zig build run
```

Local `zig build test` skips database integration tests unless `TEST_DATABASE_URL` points at a database whose name ends in `_test`.

The container image pins Zig 0.16.0. Keep local Zig aligned before relying on local builds.

Run the test suite in the development container with:

```bash
mise run test
```

## Working Memory

The home page lists working-memory entries, newest first.

- Type anywhere on the page to open the composer. Enter saves, Shift+Enter adds a line, and Escape or clicking outside discards the draft.
- Click an entry to edit it. Enter or clicking away saves, Escape cancels, and saving empty text keeps the original.
- The trash icon deletes an entry and Clear All deletes every entry; both ask for confirmation.

The keyboard behaviour is in `src/public/app.js`, a small dependency-free script with JSDoc types. HTMX makes every request.

## Boards

`/boards` lists active boards in creation order, with a tile for creating one. Archiving a board (with confirmation) moves it to `/boards/archived`, where it can be restored or permanently deleted. A board's page shows its title, which is edited in place (Enter or clicking away saves, Escape cancels), and actions to archive or delete it; archived boards show a banner instead and stay editable.

Board pages follow the original app's board view: lists are columns in creation order, with titles edited in place and a delete button revealed on hover. A board with no lists shows a "Start your workflow" form; otherwise an add-list form follows the last list. Lists remain editable on archived boards, and deleting a board also deletes its lists and cards.

Each list ends with "Add a card", which appends a card to the list. Clicking a card opens its details dialog, where the title and description are edited in place (the description is multiline and may be cleared) and the card can be deleted. Deleting an empty list asks for confirmation; deleting a list with cards opens a dialog that can move them, in order, to the end of another list on the board, or delete them with it.

Drag-and-drop and sending working-memory entries to a board are being built next, in that order.

## Browser Tests

```bash
mise run e2e
```

Runs the Playwright tests in `e2e/` against a separate server on port 3001 backed by its own `thing_for_doing_next_e2e` database, so the dev server and its data are untouched. Arguments are passed to `playwright test`, e.g. `mise run e2e -- -g "boards"`. The tests use the system Chromium at `/usr/bin/chromium` (override with `CHROMIUM_PATH`) and need Node.js; their npm dependencies are installed into `e2e/node_modules` on first run.

## Database

The app requires `DATABASE_URL` (a libpq connection string or `postgresql://` URI) and exits at startup if the database is unreachable or a migration fails. Compose sets it for both app services.

The PostgreSQL client is a thin libpq wrapper in `src/db.zig`, deliberately shaped like [pg.zig](https://github.com/karlseguin/pg.zig) so it can be replaced without changing callers.

Migrations live in `migrations/*.sql`, are embedded into the binary at build time, and are applied in filename order on startup. Each migration runs in its own transaction and is recorded in `schema_migrations`. Migrations are forward-only; add a new file rather than editing an applied one.

`mise run test` also runs database integration tests against a separate `thing_for_doing_next_test` database, which it creates when missing.

## Product Direction

This is a rewrite of the personal productivity app in the adjacent `thing-for-doing` repository. That application is the behavior reference, not an implementation dependency: it is a Rails JSON API with a React frontend, while this project is intentionally server-rendered Zig with HTMX.

The target workflows are:

- Working Memory as the default capture surface, with fast creation, inline editing, multiline entries, deletion, and sending an entry to a board without removing it.
- Boards, lists, and cards, including inline titles, card details, archived boards, and list deletion with optional card transfer.
- Drag-and-drop card reordering within and between lists.

Working Memory, board management, lists, and cards are implemented. Use normal document navigation for the working-memory, boards, archived-boards, and board-detail pages. Use HTMX for page-local CRUD and partial updates. Drag-and-drop will require a focused client-side JavaScript module rather than a full SPA.

## Inspiration

The product is inspired by working-memory capture: record a thought quickly so it no longer needs to occupy attention, then later decide whether to organize it into actionable board work. The application should favor personal speed and low interaction overhead over feature breadth.
