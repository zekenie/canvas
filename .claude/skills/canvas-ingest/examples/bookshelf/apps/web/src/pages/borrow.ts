/** Borrowing: a book lent to a member, by its ISBN and the member's id. */

import { isValidIsbn } from "@bookshelf/shared";
import { borrow } from "../api";
import { button, page } from "../view";

export function borrowPage(): HTMLElement {
  const isbn = Object.assign(document.createElement("input"), { placeholder: "ISBN" });
  const member = Object.assign(document.createElement("input"), { placeholder: "Member" });
  const lend = button("Lend", () => {
    if (isValidIsbn(isbn.value)) void borrow(isbn.value, member.value);
  });
  return page("Borrow", isbn, member, lend);
}
