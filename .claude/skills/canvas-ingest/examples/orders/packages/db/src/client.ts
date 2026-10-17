/** The one Postgres pool every service shares, and `query`, which every repository function goes through. */

import { Pool } from "pg";

export const pool = new Pool({ connectionString: process.env.DATABASE_URL });

/** The rows a statement returns. */
export async function query<T>(text: string, values: unknown[] = []): Promise<T[]> {
  const result = await pool.query(text, values);
  return result.rows as T[];
}
