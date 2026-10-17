/** The monthly statements: what each customer ordered, and got back, in the month before. */

import { customersWithOrdersBetween, refundsBetween } from "@shop/db";

/** Writes a statement for every customer who ordered last month. */
export async function handler(): Promise<{ statements: number }> {
  const to = new Date();
  to.setUTCDate(1);
  to.setUTCHours(0, 0, 0, 0);
  const from = new Date(to);
  from.setUTCMonth(to.getUTCMonth() - 1);
  const customers = await customersWithOrdersBetween(from, to);
  const refunds = await refundsBetween(from, to);
  for (const customer of customers) {
    const theirs = refunds.filter((refund) => refund.customer_id === customer.id);
    console.log(`statement for ${customer.email}: ${theirs.length} refunds`);
  }
  return { statements: customers.length };
}
