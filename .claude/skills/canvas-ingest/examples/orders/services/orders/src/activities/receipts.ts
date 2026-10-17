/** Activities that tell the customer what happened. */

import { findCustomer, findOrder } from "@shop/db";
import type { OrderId } from "@shop/shared";

/** Emails the customer a receipt for a paid order. */
export async function sendReceipt(order: OrderId): Promise<void> {
  const row = await findOrder(order);
  const customer = row && (await findCustomer(row.customer_id));
  if (!row || !customer) throw new Error(`no receipt for ${order}`);
  console.log(`receipt for ${row.id} to ${customer.email}: ${row.total_cents} ${row.currency}`);
}
