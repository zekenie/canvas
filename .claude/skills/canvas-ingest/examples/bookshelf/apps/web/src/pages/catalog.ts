/** The catalog: every book on the shelf, by title. */

import type { Book } from "@bookshelf/shared";
import { getBooks } from "../api";
import { list, page } from "../view";

function line(book: Book): string {
  return `${book.title}, ${book.author}`;
}

export async function catalogPage(): Promise<HTMLElement> {
  return page("Catalog", list((await getBooks()).map(line)));
}
