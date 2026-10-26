/** The bookshelf's API: the routes the web app calls, on one HTTP server. */

import { createServer } from "node:http";
import { Router } from "./router";
import { booksRoutes } from "./routes/books";
import { loansRoutes } from "./routes/loans";
import { membersRoutes } from "./routes/members";

const router = new Router();
booksRoutes(router);
loansRoutes(router);
membersRoutes(router);

createServer((request, response) => router.answer(request, response)).listen(Number(process.env.PORT ?? 3000));
