CREATE TABLE cards (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  list_id bigint NOT NULL REFERENCES lists (id) ON DELETE CASCADE,
  title text NOT NULL CHECK (title ~ '\S'),
  description text NOT NULL DEFAULT '',
  position integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX cards_list_id_position_idx ON cards (list_id, position, id);
