/** Ids with a prefix that says what they name: ord_..., pay_..., ref_... */

import { randomUUID } from "crypto";

export type OrderId = string;
export type PaymentId = string;
export type RefundId = string;
export type CustomerId = string;

/** A new id for a row, as `<prefix>_<uuid without dashes>`. */
export function newId(prefix: "ord" | "pay" | "ref"): string {
  return `${prefix}_${randomUUID().replace(/-/g, "")}`;
}
