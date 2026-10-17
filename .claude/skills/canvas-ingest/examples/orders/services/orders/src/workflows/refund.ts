/** Refund: the money goes back through the provider, the refund is recorded, and the order marked refunded. */

import { proxyActivities } from "@temporalio/workflow";
import { money, type OrderId } from "@shop/shared";
import type * as activities from "../activities";

const { loadOrder, refundCard, recordRefund, markRefunded } = proxyActivities<typeof activities>({
  startToCloseTimeout: "2 minutes",
});

/** Gives a paid order's money back, saying why. */
export async function refundWorkflow(order: OrderId, reason: string): Promise<void> {
  const row = await loadOrder(order);
  if (row.status !== "paid") return;
  const amount = money(row.total_cents, row.currency);
  await refundCard(order, amount);
  await recordRefund(order, amount, reason);
  await markRefunded(order);
}
