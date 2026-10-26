/** The members table. */

import type { Member } from "@bookshelf/shared";
import { query } from "./client";

export async function findMember(id: string): Promise<Member | undefined> {
  return (await query<Member>(`SELECT id, name, email FROM members WHERE id = $1`, [id]))[0];
}

export async function insertMember(member: Member): Promise<Member> {
  await query(`INSERT INTO members (id, name, email) VALUES ($1, $2, $3)`, [member.id, member.name, member.email]);
  return member;
}
