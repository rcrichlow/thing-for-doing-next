-- Board lists. Statements returning lists select, in order: id, board_id,
-- title.

-- name: for_board
SELECT id, board_id, title FROM lists WHERE board_id = $1 ORDER BY id;

-- name: find
SELECT id, board_id, title FROM lists WHERE id = $1;

-- name: create
-- Inserts nothing if the board does not exist.
INSERT INTO lists (board_id, title)
SELECT id, $2 FROM boards WHERE id = $1
RETURNING id, board_id, title;

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
