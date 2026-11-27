-- Board lists. Statements returning lists select, in order: id, board_id,
-- title.

-- name: for_board
SELECT id, board_id, title FROM lists WHERE board_id = $1 ORDER BY position, id;

-- name: find
SELECT id, board_id, title FROM lists WHERE id = $1;

-- name: create
-- Inserts nothing if the board does not exist.
INSERT INTO lists (board_id, title, position)
SELECT id, $2, coalesce((SELECT max(position) + 1 FROM lists WHERE board_id = $1), 0) FROM boards WHERE id = $1
RETURNING id, board_id, title;

-- name: create_on_active_board
INSERT INTO lists (board_id, title, position)
SELECT id, $2, coalesce((SELECT max(position) + 1 FROM lists WHERE board_id = $1), 0) FROM boards WHERE id = $1 AND archived_at IS NULL
RETURNING id, board_id, title;

-- name: lock_board
SELECT id FROM boards WHERE id = $1 FOR UPDATE;

-- name: lock_reorder_lists
SELECT id FROM lists WHERE board_id = $1 AND id IN ($2, $3) ORDER BY id FOR UPDATE;

-- name: reorder
-- Place $2 immediately before or after $3, leaving other lists in order.
WITH others AS (
  SELECT id, row_number() OVER (ORDER BY position, id) AS n
  FROM lists WHERE board_id = $1 AND id <> $2
), anchor AS (
  SELECT n FROM others WHERE id = $3
), ordered AS (
  SELECT id, row_number() OVER (ORDER BY sort_key, id) - 1 AS position
  FROM (
    SELECT id, n * 2 AS sort_key FROM others
    UNION ALL
    SELECT $2::bigint, n * 2 + CASE WHEN $4::boolean THEN -1 ELSE 1 END FROM anchor
  ) positions
)
UPDATE lists SET position = ordered.position FROM ordered
WHERE lists.id = ordered.id AND lists.board_id = $1 AND lists.position <> ordered.position;

-- name: rename
UPDATE lists
SET title = $2,
    updated_at = CASE WHEN title = $2 THEN updated_at ELSE now() END
WHERE id = $1
RETURNING id, board_id, title;

-- name: delete
DELETE FROM lists WHERE id = $1 RETURNING board_id;

-- name: count
SELECT count(*) FROM lists WHERE board_id = $1;

-- name: lock_for_transfer
SELECT board_id FROM lists WHERE id = $1 FOR UPDATE;

-- name: lock_transfer_target
-- $1 is the target, which must be another list ($3) on board $2.
SELECT id FROM lists WHERE id = $1 AND board_id = $2 AND id <> $3 FOR UPDATE;

-- name: transfer_cards
-- Moves list $1's cards, in order, to the end of list $2.
UPDATE cards c
SET list_id = $2, position = base.next + ranked.n - 1, updated_at = now()
FROM (SELECT id, row_number() OVER (ORDER BY position, id) AS n FROM cards WHERE list_id = $1) ranked,
     (SELECT coalesce(max(position) + 1, 0) AS next FROM cards WHERE list_id = $2) base
WHERE c.id = ranked.id;
