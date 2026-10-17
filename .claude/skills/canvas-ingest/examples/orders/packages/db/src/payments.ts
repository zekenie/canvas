/** Payments: a charge taken for an order, settled when the provider says the money arrived. */

import type { Money, OrderId, PaymentId } from "@shop/shared";
import { query } from "./client";

export interface PaymentRow {
  id: PaymentId;
  order_id: OrderId;
  provider_ref: string;
  amount_cents: number;
}

/** A charge the provider took for an order. */
export async function insertPayment(id: PaymentId, order: OrderId, providerRef: string, amount: Money): Promise<void> {
  await query(
    `INSERT INTO payments (id, order_id, provider_ref, amount_cents) VALUES ($1, $2, $3, $4)`,
    [id, order, providerRef, amount.cents],
  );
}

/** The provider says the money arrived. */
export async function settlePayment(providerRef: string): Promise<void> {
  await query(`UPDATE payments SET settled_at = now() WHERE provider_ref = $1`, [providerRef]);
}

/** The payment taken for an order, if there is one. */
export async function findPaymentForOrder(order: OrderId): Promise<PaymentRow | undefined> {
  const rows = await query<PaymentRow>(`SELECT id, order_id, provider_ref, amount_cents FROM payments WHERE order_id = $1`, [order]);
  return rows[0];
}
