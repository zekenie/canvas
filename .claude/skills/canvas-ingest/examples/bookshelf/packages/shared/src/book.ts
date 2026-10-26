/** A book on the shelf: its ISBN, title and author. */

/** An ISBN-13, digits only. */
export type Isbn = string;

export interface Book {
  isbn: Isbn;
  title: string;
  author: string;
}

/** Whether an ISBN-13's check digit is right. */
export function isValidIsbn(isbn: Isbn): boolean {
  if (!/^\d{13}$/.test(isbn)) return false;
  const sum = [...isbn].reduce((total, digit, i) => total + Number(digit) * (i % 2 === 0 ? 1 : 3), 0);
  return sum % 10 === 0;
}
