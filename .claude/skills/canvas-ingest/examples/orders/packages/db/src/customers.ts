/** Customers: who places orders, and where their receipts go. */

import type { CustomerId } from "@shop/shared";
import { query } from "./client";

export interface CustomerRow {
  id: CustomerId;
  email: string;
  name: string | null;
}

/** The customer with this id, if there is one. */
export async function findCustomer(id: CustomerId): Promise<CustomerRow | undefined> {
  const rows = await query<CustomerRow>(`SELECT id, email, name FROM customers WHERE id = $1`, [id]);
  return rows[0];
}

/** Every customer who placed an order between two instants, for their statement. */
export async function customersWithOrdersBetween(from: Date, to: Date): Promise<CustomerRow[]> {
  return query<CustomerRow>(
    `SELECT DISTINCT c.id, c.email, c.name
       FROM customers c JOIN orders o ON o.customer_id = c.id
      WHERE o.created_at >= $1 AND o.created_at < $2`,
    [from, to],
  );
}
