-- Money given back on an order, and why.
CREATE TABLE refunds (
  id text PRIMARY KEY,
  order_id text NOT NULL REFERENCES orders (id),
  amount_cents integer NOT NULL,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
