-- Who places orders.
CREATE TABLE customers (
  id uuid PRIMARY KEY,
  email text NOT NULL UNIQUE,
  name text,
  created_at timestamptz NOT NULL DEFAULT now()
);
