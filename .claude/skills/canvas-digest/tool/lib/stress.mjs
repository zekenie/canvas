// A warm stress layout: stress majorization (SMACOF) started from the positions a container already has, so that a small change
// to the sizes or the arrows moves the boxes a little. ELK's own stress ignores the positions it is given, and lays the container
// out afresh: a new draw each time, which in the cost C is noise of a size no promotion's gain stands out of.
// Deterministic, and about a millisecond a container (ELK takes 4 to 20).
import { removeOverlaps } from './elk.mjs';

const DETACHED = 99;   // hops a box in another component is taken to be away at most (99: as far as ELK puts it; 2 or 3 tried: it did not help)
const GAP = 100;   // the length of an arrow between two boxes, between their borders (ELK's 460 between the centers of two notes)

/** Hop counts between the boxes (undirected), Infinity between components. edges: [{a, b}] indexes. */
function hops(n, edges) {
  const adj = Array.from({ length: n }, () => []);
  for (const e of edges) { if (e.a === e.b) continue; adj[e.a].push(e.b); adj[e.b].push(e.a); }
  const d = [];
  for (let s = 0; s < n; s++) {
    const row = new Array(n).fill(Infinity); row[s] = 0;
    const q = [s];
    for (let h = 0; h < q.length; h++) { const u = q[h]; for (const v of adj[u]) if (row[v] === Infinity) { row[v] = row[u] + 1; q.push(v); } }
    d.push(row);
  }
  return d;
}

/**
 * items: [{w, h}], edges: [{a, b}], init: [{x, y}] top-lefts. Returns {raw, pos}: the top-lefts the majorization comes to (what the
 * next layout starts from: it is the same again when nothing has changed), and the same with overlaps removed (on the 16 grid, not
 * yet moved to the origin).
 */
export function warmStress(items, edges, init, iterations = 300) {
  const n = items.length;
  const rad = items.map((it) => Math.hypot(it.w, it.h) / 2);
  const medR = rad.slice().sort((p, q) => p - q)[n >> 1];
  const h = hops(n, edges);
  let maxH = 0;
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) if (h[i][j] !== Infinity && h[i][j] > maxH) maxH = h[i][j];
  // a box with no arrows to the others (another component) is taken to be DETACHED hops away: near them, not a board away
  const D = (i, j) => { const k = h[i][j] === Infinity ? Math.min(maxH + 2, DETACHED) : h[i][j]; return rad[i] + rad[j] + GAP + (k - 1) * (2 * medR + GAP); };
  const d = [], w = [];
  for (let i = 0; i < n; i++) { d.push([]); w.push([]); for (let j = 0; j < n; j++) { const v = i === j ? 0 : D(i, j); d[i].push(v); w[i].push(i === j ? 0 : 1 / (v * v)); } }
  const x = init.map((p, i) => p.x + items[i].w / 2), y = init.map((p, i) => p.y + items[i].h / 2);
  for (let it = 0; it < iterations; it++) {
    let move = 0;
    for (let i = 0; i < n; i++) {
      let sw = 0, sx = 0, sy = 0;
      for (let j = 0; j < n; j++) {
        if (i === j) continue;
        const dx = x[i] - x[j], dy = y[i] - y[j], dist = Math.hypot(dx, dy) || 1e-6;
        const wij = w[i][j];
        sw += wij; sx += wij * (x[j] + d[i][j] * dx / dist); sy += wij * (y[j] + d[i][j] * dy / dist);
      }
      if (sw === 0) continue;
      const nx = sx / sw, ny = sy / sw;
      move = Math.max(move, Math.abs(nx - x[i]), Math.abs(ny - y[i]));
      x[i] = nx; y[i] = ny;
    }
    if (move < 0.25) break;
  }
  const raw = x.map((cx, i) => ({ x: cx - items[i].w / 2, y: y[i] - items[i].h / 2 }));
  return { raw, pos: removeOverlaps(items, raw) };
}
