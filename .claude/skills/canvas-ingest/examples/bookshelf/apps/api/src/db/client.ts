/** The database connection the API shares, and `query`, which every table's functions go through. */

import { Pool } from "pg";

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

/** Runs one statement and gives back its rows. */
export async function query<Row>(text: string, values: unknown[] = []): Promise<Row[]> {
  const result = await pool.query(text, values);
  return result.rows as Row[];
}
