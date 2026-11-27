-- Working-memory entries. Statements returning entries select, in order: id,
-- content, updated_at as ISO 8601 UTC text.

-- name: list
SELECT id, content, to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
FROM working_memory_entries
ORDER BY id DESC;

-- name: find
SELECT id, content, to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
FROM working_memory_entries
WHERE id = $1;

-- name: create
INSERT INTO working_memory_entries (content) VALUES ($1)
RETURNING id, content, to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

-- name: update
UPDATE working_memory_entries
SET content = $2,
    updated_at = CASE WHEN content = $2 THEN updated_at ELSE now() END
WHERE id = $1
RETURNING id, content, to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

-- name: delete
DELETE FROM working_memory_entries WHERE id = $1;

-- name: delete_all
DELETE FROM working_memory_entries;

-- name: send_to_board
-- The entry and destination must still exist, and the list must belong to
-- the selected active board. The normalized title is supplied by the caller.
INSERT INTO cards (list_id, title, position)
SELECT l.id, $4, coalesce((SELECT max(position) + 1 FROM cards WHERE list_id = l.id), 0)
FROM working_memory_entries e
JOIN boards b ON b.id = $2 AND b.archived_at IS NULL
JOIN lists l ON l.board_id = b.id AND l.id = $3
WHERE e.id = $1
RETURNING id;
