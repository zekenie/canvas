/** The books table: the shelf as the database keeps it. */

import type { Book } from "@bookshelf/shared";
import { query } from "./client";

export async function allBooks(): Promise<Book[]> {
  return query<Book>(`SELECT isbn, title, author FROM books ORDER BY title`);
}

export async function findBook(isbn: string): Promise<Book | undefined> {
  return (await query<Book>(`SELECT isbn, title, author FROM books WHERE isbn = $1`, [isbn]))[0];
}

export async function insertBook(book: Book): Promise<void> {
  await query(`INSERT INTO books (isbn, title, author) VALUES ($1, $2, $3)`, [book.isbn, book.title, book.author]);
}
