/** Activities that move money through the card provider. */

import { findPaymentForOrder, insertPayment } from "@shop/db";
import { newId, type Money, type OrderId, type PaymentId } from "@shop/shared";

const PROVIDER = "https://payments.example.com/v1";

/** Charges the customer's card for the order, and records the payment. */
export async function chargeCard(order: OrderId, amount: Money): Promise<PaymentId> {
  const response = await fetch(`${PROVIDER}/charges`, { method: "POST", body: JSON.stringify({ order, amount }) });
  if (!response.ok) throw new Error(`the charge for ${order} failed: ${response.status}`);
  const { ref } = (await response.json()) as { ref: string };
  const id = newId("pay");
  await insertPayment(id, order, ref, amount);
  return id;
}

/** Gives the order's payment back through the provider. */
export async function refundCard(order: OrderId, amount: Money): Promise<void> {
  const payment = await findPaymentForOrder(order);
  if (!payment) throw new Error(`nothing was paid for ${order}`);
  const response = await fetch(`${PROVIDER}/charges/${payment.provider_ref}/refunds`, { method: "POST", body: JSON.stringify({ amount }) });
  if (!response.ok) throw new Error(`the refund for ${order} failed: ${response.status}`);
}
