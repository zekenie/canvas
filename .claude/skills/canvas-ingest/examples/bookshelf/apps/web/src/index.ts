/** The bookshelf's web app: the catalog, a member's page, and borrowing, each drawn into the page's body. */

import { borrowPage } from "./pages/borrow";
import { catalogPage } from "./pages/catalog";
import { memberPage } from "./pages/member";

/** The page the address names. */
async function show(path: string): Promise<HTMLElement> {
  const member = /^\/members\/([^/]+)$/.exec(path);
  if (member) return memberPage(member[1]);
  if (path === "/borrow") return borrowPage();
  return catalogPage();
}

show(location.pathname).then((page) => document.body.replaceChildren(page));
