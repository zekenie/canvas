-- A charge the card provider took for an order.
CREATE TABLE payments (
  id text PRIMARY KEY,
  order_id text NOT NULL REFERENCES orders (id),
  provider_ref text NOT NULL UNIQUE,
  amount_cents integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  settled_at timestamptz
);
