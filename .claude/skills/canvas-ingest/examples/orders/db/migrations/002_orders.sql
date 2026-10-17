-- An order, from checkout to paid or refunded.
CREATE TABLE orders (
  id text PRIMARY KEY,
  customer_id uuid NOT NULL REFERENCES customers (id),
  total_cents integer NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  paid_at timestamptz
);

CREATE INDEX orders_customer ON orders (customer_id, created_at);
