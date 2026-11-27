-- Boards. Statements returning boards select, in order: id, title,
-- created_at, archived_at, with timestamps as ISO 8601 UTC text.

-- name: list_active
SELECT id, title,
    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    to_char(archived_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
FROM boards
WHERE archived_at IS NULL
ORDER BY id;

-- name: list_archived
SELECT id, title,
    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    to_char(archived_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
FROM boards
WHERE archived_at IS NOT NULL
ORDER BY archived_at DESC, id DESC;

-- name: count_archived
SELECT count(*) FROM boards WHERE archived_at IS NOT NULL;

-- name: find
SELECT id, title,
    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    to_char(archived_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
FROM boards
WHERE id = $1;

-- name: create
INSERT INTO boards (title) VALUES ($1)
RETURNING id, title,
    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    to_char(archived_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

-- name: rename
UPDATE boards
SET title = $2,
    updated_at = CASE WHEN title = $2 THEN updated_at ELSE now() END
WHERE id = $1
RETURNING id, title,
    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    to_char(archived_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

-- name: archive
-- Keeps the original time if the board is already archived.
UPDATE boards SET archived_at = coalesce(archived_at, now()) WHERE id = $1;

-- name: unarchive
UPDATE boards SET archived_at = NULL WHERE id = $1;

-- name: delete
DELETE FROM boards WHERE id = $1;
