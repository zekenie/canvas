/** Members: one signed up, and one looked up with the books they have out. */

import type { Member } from "@bookshelf/shared";
import { loansOf } from "../db/loans";
import { findMember, insertMember } from "../db/members";
import type { Router } from "../router";

export function membersRoutes(router: Router): void {
  router.add("POST", "/members", (_, body) => insertMember(body as Member));
  router.add("GET", "/members/:id", async ({ id }) => ({ member: await findMember(id), loans: await loansOf(id) }));
}
