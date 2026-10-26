/** A small router: a handler for each method and path, and the one that answers a request. */

import type { IncomingMessage, ServerResponse } from "node:http";

/** What answers one route: the request's path parameters and body in, a JSON value out. */
export type Handler = (params: Record<string, string>, body: unknown) => Promise<unknown>;

export class Router {
  private routes: { method: string; pattern: RegExp; names: string[]; handler: Handler }[] = [];

  /** Adds a route: `path` may name parameters, as `/books/:isbn`. */
  add(method: string, path: string, handler: Handler): void {
    const names = [...path.matchAll(/:(\w+)/g)].map((m) => m[1]);
    const pattern = new RegExp("^" + path.replace(/:\w+/g, "([^/]+)") + "$");
    this.routes.push({ method, pattern, names, handler });
  }

  /** Answers a request with the first route that matches it, or 404. */
  async answer(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", "http://localhost");
    for (const route of this.routes) {
      const found = request.method === route.method ? route.pattern.exec(url.pathname) : null;
      if (found) {
        const params = Object.fromEntries(route.names.map((name, i) => [name, found[i + 1]]));
        const chunks: Buffer[] = [];
        for await (const chunk of request) chunks.push(chunk as Buffer);
        const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : undefined;
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify(await route.handler(params, body)));
        return;
      }
    }
    response.statusCode = 404;
    response.end();
  }
}
