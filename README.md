# Thing for Doing Next

Thing for Doing Next is a personal productivity app built with Zig, server-rendered HTML, HTMX,
and PostgreSQL. It is built around two connected workflows:

- **Working Memory** for fast capture
- **Boards** for organizing items into lists and cards

The current app treats Working Memory as the default home experience. You can quickly capture
thoughts, keep them in place, and optionally turn them into board cards without deleting the
original entry.

The idea behind working memory is to quickly capture thoughts and ideas so that you can move on to
other things without losing them. It's not a TODO list at heart, but it can be used that way. Really,
it's an "I don't want to lose the context that's currently in my head, so I will write down this
random thought so I can stop thinking about it" list. Then you can return to it later and decide
if it's actionable or not.

## Current Features

- Working Memory is the default landing flow
- Keyboard-open working memory composer for fast capture
- Inline editing for working memory entries
- Per-entry working memory deletion
- Multiline working memory entries with `Shift+Enter`
- Clear all working memory entries in one action
- Send a working memory entry to a board without removing the entry
- Create boards from the boards page or inline during send-to-board
- Edit board titles inline from the board page
- Archive boards so they leave the main boards list without deleting their contents
- Browse archived boards separately and unarchive them back into the main boards list
- Delete boards from board-level archive/detail flows
- Create lists inside a board or inline during send-to-board
- Edit list titles inline from the board page
- Create cards inside lists
- Edit and delete cards in a modal
- Delete lists from the board UI, with optional card transfer to another list
- Reorder cards within a list and move them across lists with drag-and-drop or keyboard shortcuts
- Reorder lists with drag-and-drop, move buttons, or keyboard shortcuts

## Current Product Flow

- `/` shows working memory entries and a lightweight composer
- `/boards` shows the board index and board creation flow
- `/boards/archived` shows archived boards that have been removed from the main board index
- `/boards/:id` shows a board with lists, cards, drag-and-drop, and card detail editing

### Working Memory behavior

- Typing anywhere outside form fields opens the composer
- Working memory entries can be edited inline by clicking them
- `Shift+Enter` inserts new lines and `Enter` submits
- Individual entries and all entries can be deleted with confirmation
- Clicking away saves an inline edit; saving empty text keeps the original
- `Escape` or clicking outside closes the composer without saving
- `Escape` cancels an inline edit
- Entries can be sent to a board through a modal that supports:
  - choosing an existing active board
  - creating a new board inline
  - choosing an existing list
  - creating a new list inline
  - previewing multiline entry text with preserved line breaks

The entry remains unchanged. Its content becomes the card title, with line breaks flattened to spaces like other card titles. Boards and lists created in the dialog are saved immediately, even if the dialog is cancelled before creating a card.

### Board behavior

- Lists and cards appear in their saved order; new lists are appended
- Card details open in a centered modal
- Board titles are click-to-edit from the board header
- List titles are click-to-edit from each list header
- Card title and description are click-to-edit fields
- Card details include a delete action with confirmation
- Lists can be deleted from the board UI
- Deleting a non-empty list can optionally transfer its cards to another list before deletion
- Active boards are shown on `/boards`, while archived boards are hidden from that list and moved to `/boards/archived`
- Archived boards keep their normal board detail page and show an archived indicator when viewed directly
- Archived boards can be unarchived from the archived boards page or from the archived board view
- Archived boards remain editable, but cannot be selected as send-to-board destinations until unarchived
- Cards can be moved with drag-and-drop or, when focused, with `Alt+Up/Down` and `Alt+Left/Right`
- Lists can be dragged by their handle, moved with the arrow buttons, or moved with `Alt+Left/Right` when the handle is focused

## Stack

### Backend

- Zig 0.17.1 HTTP server and libpq PostgreSQL client
- PostgreSQL 17
- Docker Compose

### Frontend

- Server-rendered HTML
- HTMX 4.0.2
- Tailwind CSS
- Dependency-free JavaScript for page behavior and drag-and-drop
- Playwright

Docker keeps the database, compiler/runtime assumptions, and production-style image build reproducible. The multi-stage application image does not include the Zig compiler at runtime.

## Data Model

| Model | Description | Key Fields |
|---|---|---|
| Board | Container for lists | `title`, `archived_at` |
| List | Column within a board | `title`, `position`, `board_id` |
| Card | Task item within a list | `title`, `description`, `position`, `list_id` |
| WorkingMemoryEntry | Quick capture item | `content` |

## HTTP Routes

The server renders full pages and HTMX fragments for working memory, boards, lists, and cards. See `src/main.zig` for the full route definitions. The health check is available at `/up`.

## Local Development

This project runs through Docker Compose. Start the development server with:

```bash
mise run dev
```

### Notes

- App runs on `http://localhost:3000`
- Health check runs on `http://localhost:3000/up`
- PostgreSQL is available on `localhost:5433`
- Startup runs migrations automatically
- The development container mounts the source tree; changes to `src/`, `migrations/`, `build.zig`, or `build.zig.zon` rebuild and restart only the app process
- The development watcher rebuilds Tailwind CSS before recompiling the app

Build and run the production-style image with `mise run prod`. It shares the database and port 3000 with the development server, so run only one at a time. Stop services with `mise run down`; `docker compose down --volumes` also deletes local database data.

## Verification Commands

Zig tests, including database integration tests against a separate `thing_for_doing_next_test` database:

```bash
mise run test
```

Browser tests against an isolated server on port 3001 and a separate `thing_for_doing_next_e2e` database:

```bash
mise run e2e
```

Arguments are passed to Playwright, e.g. `mise run e2e -- -g "boards"`. Tests need Node.js; npm dependencies are installed into `e2e/node_modules` on first run. They use Chromium at `/usr/bin/chromium` (override with `CHROMIUM_PATH`) if it exists, otherwise Playwright's installed Chromium (`npx playwright install chromium` from `e2e/`). The tests reset their database before each test.

For local builds, install Zig 0.17.1, libpq development files, pkg-config, and the Tailwind CSS 4.1.18 CLI. Zig fetches the pinned `translate-c` dependency on the first build. Generate the ignored stylesheet before building (and regenerate it after changing templates or styles):

```bash
tailwindcss --input src/public/input.css --output src/public/app.css
zig build test
zig build
DATABASE_URL=postgresql://thing_for_doing:thing_for_doing@localhost:5433/thing_for_doing_next zig build run
```

Local `zig build test` skips database integration tests when `TEST_DATABASE_URL` is unset. When it is set, tests require a database whose name ends in `_test` and **reset its `public` schema**, deleting its contents. The container image pins Zig 0.17.1; keep local Zig aligned before relying on local builds.

## Implementation Notes

- Working Memory is the current home experience
- Full pages use normal document navigation; HTMX handles page-local CRUD and partial updates
- Card ordering is persisted through `position`; drag-and-drop updates the page immediately and submits the new order through an HTMX form
- Pending card moves protect affected columns from being replaced until they can be refreshed
- Board and list titles support inline editing from the board view
- Working memory supports inline editing, per-entry deletion, and multiline content
- The send-to-board dialog uses HTMX to update its picker and create boards, lists, and cards; it checks that the selected list still belongs to an active board
- Board archive, unarchive, and deletion flows use confirmations or inline action affordances, and list deletion can transfer cards before removal
- Tests include Zig tests and Playwright browser tests
- The app requires `DATABASE_URL` and exits at startup if the database is unreachable or a migration fails; Compose sets it for both app services
- Migrations in `migrations/*.sql` are embedded, applied in filename order at startup, and recorded in `schema_migrations`; add a new file rather than editing an applied migration
- The libpq wrapper in `src/db.zig` is shaped like [pg.zig](https://github.com/karlseguin/pg.zig) so it can be replaced without changing callers
- The build uses the pinned Zig `translate-c` package to generate libpq bindings from `src/db/libpq.h`
- HTMX is vendored in `src/public/htmx-4.0.2.min.js` from [the pinned distribution](https://cdn.jsdelivr.net/npm/htmx.org@4.0.2/dist/htmx.min.js), with its license in `src/public/htmx-LICENSE.txt`; update the versioned filename, embedded asset route, and script URL together when upgrading
- Generated CSS is served at `/assets/styles.css` with revalidation, not `/assets/app.css`, which an early build cached immutably
- At most 16 connections are served concurrently; further connections receive `503 Service Unavailable`. Idle keep-alive connections are not timed out yet, so revisit this before exposing the app beyond local use
- Form bodies read by handlers are limited to 64 KiB and must be `application/x-www-form-urlencoded`

## Future Enhancement Ideas

These are ideas, not committed roadmap items.

- UI refresh with improved spacing, hierarchy, and visual consistency
- Accessibility improvements across keyboard use, semantics, and screen reader support
- Light mode or theme toggle
- Better empty states
- Global search across boards and cards
- Labels or tags
- Filtering tools
- Additional keyboard shortcuts
- Command palette for fast navigation and creation
- Better card detail editing and visibility
- Due dates and reminders
- Recurring tasks
- Completed-item views
- Progress indicators at the list or board level
- Activity history
- Recent changes dashboard
- Saved filters and smart views such as “My tasks” or “Due this week”
