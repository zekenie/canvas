/** The web app's calls to the API, one for each route it uses. */

import type { Book, Loan, Member } from "@bookshelf/shared";

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(`/api${path}`, { method, body: body === undefined ? undefined : JSON.stringify(body) });
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status}`);
  return (await response.json()) as T;
}

export function getBooks(): Promise<Book[]> {
  return call("GET", "/books");
}

export function getMember(id: string): Promise<{ member: Member; loans: Loan[] }> {
  return call("GET", `/members/${id}`);
}

export function borrow(isbn: string, memberId: string): Promise<Loan> {
  return call("POST", "/loans", { isbn, memberId });
}

export function giveBack(isbn: string): Promise<void> {
  return call("POST", `/loans/${isbn}/return`);
}
