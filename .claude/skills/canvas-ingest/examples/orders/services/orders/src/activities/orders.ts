/** Activities on the order itself: making it, and moving its status along. */

import { findCustomer, findOrder, insertOrder, markOrderPaid, markOrderRefunded, type OrderRow } from "@shop/db";
import { newId, type CustomerId, type Money, type OrderId } from "@shop/shared";

/** Makes a pending order for a customer who exists. */
export async function createOrder(customer: CustomerId, total: Money): Promise<OrderId> {
  if (!(await findCustomer(customer))) throw new Error(`no customer ${customer}`);
  const id = newId("ord");
  await insertOrder(id, customer, total);
  return id;
}

/** Marks the order paid. */
export async function markPaid(order: OrderId): Promise<void> {
  await markOrderPaid(order);
}

/** Marks the order refunded. */
export async function markRefunded(order: OrderId): Promise<void> {
  await markOrderRefunded(order);
}

/** Reads the order, for a workflow that decides by it. */
export async function loadOrder(order: OrderId): Promise<OrderRow> {
  const row = await findOrder(order);
  if (!row) throw new Error(`no order ${order}`);
  return row;
}
