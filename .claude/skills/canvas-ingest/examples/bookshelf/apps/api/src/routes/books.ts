/** The catalog's routes: the shelf, one book, and a book added. */

import { isValidIsbn, type Book } from "@bookshelf/shared";
import { allBooks, findBook, insertBook } from "../db/books";
import type { Router } from "../router";

export function booksRoutes(router: Router): void {
  router.add("GET", "/books", () => allBooks());
  router.add("GET", "/books/:isbn", ({ isbn }) => findBook(isbn));
  router.add("POST", "/books", async (_, body) => {
    const book = body as Book;
    if (!isValidIsbn(book.isbn)) throw new Error(`not an ISBN: ${book.isbn}`);
    await insertBook(book);
    return book;
  });
}
