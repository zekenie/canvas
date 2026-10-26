/** A member's page: the books they have out, and which are late. */

import { isOverdue, type Loan } from "@bookshelf/shared";
import { getMember, giveBack } from "../api";
import { button, list, page } from "../view";

function line(loan: Loan, today: Date): string {
  return `${loan.isbn}, due ${loan.due}${isOverdue(loan.due, today) ? " (late)" : ""}`;
}

export async function memberPage(id: string): Promise<HTMLElement> {
  const { member, loans } = await getMember(id);
  const today = new Date();
  const back = loans.map((loan) => button(`Bring back ${loan.isbn}`, () => void giveBack(loan.isbn)));
  return page(member.name, list(loans.map((loan) => line(loan, today))), ...back);
}
