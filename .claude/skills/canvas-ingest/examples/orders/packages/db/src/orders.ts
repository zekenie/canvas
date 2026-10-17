/** Orders: placed at checkout, then paid or refunded. */

import type { CustomerId, Money, OrderId } from "@shop/shared";
import { query } from "./client";

export interface OrderRow {
  id: OrderId;
  customer_id: CustomerId;
  total_cents: number;
  currency: string;
  status: "pending" | "paid" | "refunded";
}

/** A new order, pending until it is paid. */
export async function insertOrder(id: OrderId, customer: CustomerId, total: Money): Promise<void> {
  await query(
    `INSERT INTO orders (id, customer_id, total_cents, currency, status) VALUES ($1, $2, $3, $4, 'pending')`,
    [id, customer, total.cents, total.currency],
  );
}

/** The order is paid. */
export async function markOrderPaid(id: OrderId): Promise<void> {
  await query(`UPDATE orders SET status = 'paid', paid_at = now() WHERE id = $1`, [id]);
}

/** The order's money went back. */
export async function markOrderRefunded(id: OrderId): Promise<void> {
  await query(`UPDATE orders SET status = 'refunded' WHERE id = $1`, [id]);
}

/** The order with this id, if there is one. */
export async function findOrder(id: OrderId): Promise<OrderRow | undefined> {
  const rows = await query<OrderRow>(`SELECT id, customer_id, total_cents, currency, status FROM orders WHERE id = $1`, [id]);
  return rows[0];
}
