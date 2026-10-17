/** Checkout: the order is made, the card charged, and the order marked paid. A failed charge leaves it pending. */

import { proxyActivities } from "@temporalio/workflow";
import type { CustomerId, Money, OrderId } from "@shop/shared";
import type * as activities from "../activities";

const { createOrder, chargeCard, markPaid } = proxyActivities<typeof activities>({
  startToCloseTimeout: "1 minute",
  retry: { maximumAttempts: 3 },
});

export interface CheckoutInput {
  customer: CustomerId;
  total: Money;
}

/** Takes a customer's order and their money. */
export async function checkoutWorkflow(input: CheckoutInput): Promise<OrderId> {
  const order = await createOrder(input.customer, input.total);
  await chargeCard(order, input.total);
  await markPaid(order);
  return order;
}
