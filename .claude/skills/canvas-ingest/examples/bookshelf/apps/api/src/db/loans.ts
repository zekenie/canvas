/** The loans table: who has which book out, and until when. */

import type { Loan } from "@bookshelf/shared";
import { query } from "./client";

/** The books a member has out now. */
export async function loansOf(memberId: string): Promise<Loan[]> {
  return query<Loan>(
    `SELECT isbn, member_id AS "memberId", due, returned FROM loans WHERE member_id = $1 AND returned IS NULL`,
    [memberId],
  );
}

export async function insertLoan(loan: Loan): Promise<Loan> {
  await query(`INSERT INTO loans (isbn, member_id, due) VALUES ($1, $2, $3)`, [loan.isbn, loan.memberId, loan.due]);
  return loan;
}

/** A book brought back: its open loan closed on `on`. */
export async function closeLoan(isbn: string, on: Date): Promise<void> {
  await query(`UPDATE loans SET returned = $2 WHERE isbn = $1 AND returned IS NULL`, [isbn, on.toISOString().slice(0, 10)]);
}
