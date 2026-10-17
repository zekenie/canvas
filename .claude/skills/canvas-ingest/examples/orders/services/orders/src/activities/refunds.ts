/** Activities that keep the books on refunds. */

import { insertRefund } from "@shop/db";
import { newId, type Money, type OrderId, type RefundId } from "@shop/shared";

/** Records a refund given on an order. */
export async function recordRefund(order: OrderId, amount: Money, reason: string): Promise<RefundId> {
  const id = newId("ref");
  await insertRefund(id, order, amount, reason);
  return id;
}
