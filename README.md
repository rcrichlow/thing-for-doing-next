# Thing for Doing Next

An experimental personal application built to evaluate Zig, server-rendered HTML, HTMX, and PostgreSQL. This repository intentionally starts with infrastructure only; it does not port product behavior from the Rails/React application.

## Stack

- Zig HTTP server, currently dependency-free
- PostgreSQL 17
- Docker Compose for local development and deployment-like validation
- HTMX will be vendored or pinned locally when the first interactive vertical slice is built

Docker is intentional here. It keeps the database, compiler/runtime assumptions, and production-style image build reproducible while the stack is being evaluated. The application image is a multi-stage build and does not include the Zig compiler at runtime.

## Development

```bash
mise run dev
```

- App: `http://localhost:3000`
- Health check: `http://localhost:3000/up`
- PostgreSQL: `localhost:5433`

The development container mounts the source tree. Changes to `src/` or `build.zig` rebuild and restart only the app process; the database container and application container remain running.

The development watcher rebuilds Tailwind CSS from `src/` into `src/public/app.css` before recompiling the app. The generated stylesheet is embedded and served at `/assets/app.css`.

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

With Zig 0.16.0 installed locally:

```bash
zig build test
zig build
zig build run
```

The container image pins Zig 0.16.0. Keep local Zig aligned before relying on local builds.

Run the test suite in the development container with:

```bash
mise run test
```

## Database Migrations

`migrations/001_initialize.sql` only establishes migration bookkeeping. PostgreSQL runs initialization scripts on the first creation of its data volume. This is intentionally temporary: before adding application tables, select and validate a Zig PostgreSQL client and implement an application-owned migration runner. Do not treat Docker initialization scripts as the long-term migration mechanism.

## Product Direction

This is a rewrite of the personal productivity app in the adjacent `thing-for-doing` repository. That application is the behavior reference, not an implementation dependency: it is a Rails JSON API with a React frontend, while this project is intentionally server-rendered Zig with HTMX.

The target workflows are:

- Working Memory as the default capture surface, with fast creation, inline editing, multiline entries, deletion, and sending an entry to a board without removing it.
- Boards, lists, and cards, including inline titles, card details, archived boards, and list deletion with optional card transfer.
- Drag-and-drop card reordering within and between lists.

Build the working-memory vertical slice first. Use normal document navigation for the working-memory, boards, archived-boards, and board-detail pages. Use HTMX for page-local CRUD and partial updates. Drag-and-drop will require a focused client-side JavaScript module rather than a full SPA.

## Inspiration

The product is inspired by working-memory capture: record a thought quickly so it no longer needs to occupy attention, then later decide whether to organize it into actionable board work. The application should favor personal speed and low interaction overhead over feature breadth.
