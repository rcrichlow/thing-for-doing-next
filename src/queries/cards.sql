-- Cards, ordered by position within their list. Statements returning cards
-- select, in order: id, list_id, title, description.

-- name: for_board
SELECT c.id, c.list_id, c.title, c.description
FROM cards c JOIN lists l ON l.id = c.list_id
WHERE l.board_id = $1
ORDER BY c.list_id, c.position, c.id;

-- name: for_list
SELECT c.id, c.list_id, c.title, c.description
FROM cards c
WHERE c.list_id = $1
ORDER BY c.list_id, c.position, c.id;

-- name: find
SELECT c.id, c.list_id, c.title, c.description FROM cards c WHERE c.id = $1;

-- name: create
-- Appends to list $1; inserts nothing if the list does not exist.
INSERT INTO cards (list_id, title, position)
SELECT l.id, $2, coalesce((SELECT max(position) + 1 FROM cards WHERE list_id = l.id), 0)
FROM lists l WHERE l.id = $1
RETURNING id, list_id, title, description;

-- name: update_title
UPDATE cards c
SET title = $2,
    updated_at = CASE WHEN c.title = $2 THEN c.updated_at ELSE now() END
WHERE c.id = $1
RETURNING c.id, c.list_id, c.title, c.description;

-- name: update_description
UPDATE cards c
SET description = $2,
    updated_at = CASE WHEN c.description = $2 THEN c.updated_at ELSE now() END
WHERE c.id = $1
RETURNING c.id, c.list_id, c.title, c.description;

-- name: lock_reorder_target
-- Locking the board serializes reorders on it, and the list row keeps it from
-- being deleted until the cards are in place.
SELECT 1
FROM lists l JOIN boards b ON b.id = l.board_id
WHERE l.id = $1 AND b.id = $2
FOR UPDATE;

-- name: reorder
-- Gives list $2 the cards $1, in order. Listed cards from other lists on board
-- $3 move into it; unknown cards, cards on other boards, and repeats are
-- ignored, and unlisted cards already in the list keep their order after the
-- rest.
WITH wanted AS (
    SELECT DISTINCT ON (c.id) c.id, w.n
    FROM unnest($1::bigint[]) WITH ORDINALITY AS w(id, n)
    JOIN cards c ON c.id = w.id JOIN lists l ON l.id = c.list_id
    WHERE l.board_id = $3
    ORDER BY c.id, w.n
), ordered AS (
    SELECT id, (row_number() OVER (ORDER BY listed DESC, n, id) - 1)::integer AS position
    FROM (
        SELECT id, true AS listed, n FROM wanted
        UNION ALL
        SELECT id, false, position::bigint FROM cards
        WHERE list_id = $2 AND id NOT IN (SELECT id FROM wanted)
    ) cards_in_list
)
UPDATE cards c
SET list_id = $2, position = o.position,
    updated_at = CASE WHEN c.list_id <> $2 THEN now() ELSE c.updated_at END
FROM ordered o
WHERE c.id = o.id AND (c.list_id <> $2 OR c.position <> o.position);

-- name: renumber
-- Renumbers the cards in lists $1 from 0, closing gaps.
UPDATE cards c SET position = o.position
FROM (
    SELECT id, (row_number() OVER (PARTITION BY list_id ORDER BY position, id) - 1)::integer AS position
    FROM cards WHERE list_id = ANY($1::bigint[])
) o
WHERE c.id = o.id AND c.position <> o.position;

-- name: lists_holding
SELECT DISTINCT c.list_id
FROM cards c JOIN lists l ON l.id = c.list_id
WHERE c.id = ANY($1::bigint[]) AND l.board_id = $2
ORDER BY c.list_id;

-- name: delete
DELETE FROM cards WHERE id = $1 RETURNING list_id;
