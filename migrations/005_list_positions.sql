ALTER TABLE lists ADD COLUMN position bigint NOT NULL DEFAULT 0;

WITH ordered AS (
  SELECT id, row_number() OVER (PARTITION BY board_id ORDER BY id) - 1 AS position
  FROM lists
)
UPDATE lists SET position = ordered.position FROM ordered WHERE lists.id = ordered.id;

CREATE INDEX lists_board_position_idx ON lists (board_id, position, id);
