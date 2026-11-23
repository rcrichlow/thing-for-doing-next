CREATE TABLE lists (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  board_id bigint NOT NULL REFERENCES boards (id) ON DELETE CASCADE,
  title text NOT NULL CHECK (title ~ '\S'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX lists_board_id_id_idx ON lists (board_id, id);
