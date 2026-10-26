/** Lending: a member borrows a book, and brings it back. */

import { MAX_LOANS, dueDate } from "@bookshelf/shared";
import { findBook } from "../db/books";
import { closeLoan, insertLoan, loansOf } from "../db/loans";
import type { Router } from "../router";

export function loansRoutes(router: Router): void {
  router.add("POST", "/loans", async (_, body) => {
    const { isbn, memberId } = body as { isbn: string; memberId: string };
    if (!(await findBook(isbn))) throw new Error(`no book ${isbn}`);
    if ((await loansOf(memberId)).length >= MAX_LOANS) throw new Error(`${memberId} has ${MAX_LOANS} books out`);
    return insertLoan({ isbn, memberId, due: dueDate(new Date()), returned: null });
  });
  router.add("POST", "/loans/:isbn/return", ({ isbn }) => closeLoan(isbn, new Date()));
}
