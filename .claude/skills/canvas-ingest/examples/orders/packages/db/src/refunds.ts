/** Refunds: money given back on an order, and why. */

import type { Money, OrderId, RefundId } from "@shop/shared";
import { query } from "./client";

export interface RefundRow {
  id: RefundId;
  order_id: OrderId;
  amount_cents: number;
  reason: string;
}

/** A refund given on an order. */
export async function insertRefund(id: RefundId, order: OrderId, amount: Money, reason: string): Promise<void> {
  await query(`INSERT INTO refunds (id, order_id, amount_cents, reason) VALUES ($1, $2, $3, $4)`, [id, order, amount.cents, reason]);
}

/** The refunds given between two instants, with the customer each order was for. */
export async function refundsBetween(from: Date, to: Date): Promise<(RefundRow & { customer_id: string })[]> {
  return query(
    `SELECT r.id, r.order_id, r.amount_cents, r.reason, o.customer_id
       FROM refunds r JOIN orders o ON o.id = r.order_id
      WHERE r.created_at >= $1 AND r.created_at < $2`,
    [from, to],
  );
}
