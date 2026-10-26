/** Days as the shelf keeps them, YYYY-MM-DD, and how long a loan lasts. */

/** How many days a loan lasts. */
export const LOAN_DAYS = 21;

/** The day a loan made on `from` is due back. */
export function dueDate(from: Date): string {
  return day(new Date(from.getTime() + LOAN_DAYS * 24 * 60 * 60 * 1000));
}

/** Whether a loan due on `due` is late on `today`. */
export function isOverdue(due: string, today: Date): boolean {
  return due < day(today);
}

function day(date: Date): string {
  return date.toISOString().slice(0, 10);
}
