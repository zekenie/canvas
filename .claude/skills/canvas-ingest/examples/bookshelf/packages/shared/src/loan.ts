/** A loan: a book a member has out, and the day it is due back. */

import type { Isbn } from "./book";

export interface Loan {
  isbn: Isbn;
  memberId: string;
  due: string;
  returned: string | null;
}
