-- Orders in more than one currency.
ALTER TABLE orders ADD COLUMN currency char(3) NOT NULL DEFAULT 'USD';
