/** A member of the library: who may borrow, and how many books at once. */

/** How many books a member may have out at once. */
export const MAX_LOANS = 5;

export interface Member {
  id: string;
  name: string;
  email: string;
}
