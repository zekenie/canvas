// What a layout costs, and whether it is good enough.
//   C = X + 2 NE + 3 Fx + 0.25 sum(len)/rank + mu sum_s(p_s + 0.25 p_s(p_s-1)/2) + 10 orphans + alpha max(0, aspect-3)
// Arrows are measured as straight segments between box borders (the tool draws no bends).
// A pill shared by several users is one pill, counted once for its host (the user whose column it is in); the other users'
// arrows run to it and are measured like any arrow (they are what the host choice keeps short).
import { median } from './util.mjs';
import { isGood } from './dial.mjs';
import { arrowBetween, segLength, crossings, segHitsBox, BoxGrid } from './geom.mjs';

export const ALPHA = 5;
export const pillId = (i) => '\u0001pill' + i;

/**
 * Every arrow of a layout, as {a, b, A, B, fromNode, toNode, kind}: a, b are ids (a title, or a pill's id), A, B their boxes.
 * Plain arrows first, in plan.direct's order (so `per` lines up with it), then arrows into shared pills, then each start to its own pills.
 */
export function arrowsOf(layout) {
  const { boxes, pills, plan } = layout;
  const out = [];
  for (const e of plan.direct) out.push({ a: e.from, b: e.to, A: boxes.get(e.from), B: boxes.get(e.to), fromNode: e.from, toNode: e.to, kind: 'plain', n: 1 });
  for (const m of plan.members) out.push({ a: m.e.from, b: pillId(m.pill), A: boxes.get(m.e.from), B: pills[m.pill], fromNode: m.e.from, toNode: m.host, kind: 'shared', n: 1 });
  pills.forEach((p, i) => out.push({ a: p.start, b: pillId(i), A: boxes.get(p.start), B: p, fromNode: p.start, toNode: p.start, kind: 'link', n: 1 }));
  return out;
}

export function evaluate(model, layout, mu) {
  const { boxes, pills, plan } = layout;
  const all = arrowsOf(layout);
  const segs = all.map((x) => { const s = arrowBetween(x.A, x.B); s.a = x.a; s.b = x.b; return s; });
  const cr = crossings(segs);
  // arrows over a shape that is not one of their ends (leaf boxes, and the pills)
  const owners = [], solids = [];
  for (const [t, b] of boxes) { owners.push(t); solids.push(b); }
  pills.forEach((p, i) => { owners.push(pillId(i)); solids.push(p); });
  const grid = new BoxGrid(solids);
  const frameList = [...layout.frames].map(([t, b]) => ({ t, b }));
  let NE = 0, NEnote = 0, NEpill = 0, Fx = 0, len = 0;
  const nNotes = boxes.size;
  const per = [];
  all.forEach((x, i) => {
    if (x.kind === 'link') return;
    const s = segs[i];
    let ne = 0, fx = 0;
    for (const j of grid.near(s)) { if (owners[j] === x.a || owners[j] === x.b) continue; if (segHitsBox(s, solids[j])) { ne++; if (j < nNotes) NEnote++; else NEpill++; } }
    const na = model.node(x.fromNode).frames, nb = model.node(x.toNode).frames;
    for (const f of frameList) {
      if (na.includes(f.t) || nb.includes(f.t)) continue;
      const bx = f.b;
      if (Math.max(s.x1, s.x2) < bx.x || Math.min(s.x1, s.x2) > bx.x + bx.w || Math.max(s.y1, s.y2) < bx.y || Math.min(s.y1, s.y2) > bx.y + bx.h) continue;
      if (segHitsBox(s, bx, 0)) fx++;
    }
    NE += ne; Fx += fx; len += segLength(s);
    per[i] = { x: cr.per[i], ne, fx };
  });
  const heights = [...boxes.values()].map((b) => b.h);
  const rank = (median(heights) || 200) + 64;
  const lenR = len / rank;
  // pills: per start (a shared pill is its host's), a pill for a node public regardless counted at 0.8
  const perStart = new Map();
  for (const p of pills) { let r = perStart.get(p.start); if (!r) perStart.set(p.start, r = { n: 0, w: 0 }); r.n++; r.w += model.forcedPublic.has(p.target) ? 0.8 : 1; }
  let pillTerm = 0;
  for (const r of perStart.values()) pillTerm += r.w + 0.25 * r.n * (r.n - 1) / 2;
  // orphans: shapes with edges on this board and nothing shown for them (no arrow, no pill beside them)
  const shown = new Set();
  for (const x of all) { shown.add(x.a); shown.add(x.b); }
  let orphans = 0;
  for (const t of boxes.keys()) {
    if (shown.has(t)) continue;
    const touched = (model.out.get(t) || []).some((e) => !e.cross && model.node(e.to).board === layout.board) || (model.inn.get(t) || []).some((e) => !e.cross && model.node(e.from).board === layout.board);
    if (touched) orphans++;
  }
  const aspect = layout.w > 0 && layout.h > 0 ? Math.max(layout.w / layout.h, layout.h / layout.w) : 1;
  const hw = layout.w > 0 && layout.h > 0 ? layout.h / layout.w : 1;   // taller than wide: > 1
  const cost = cr.total + 2 * NE + 3 * Fx + 0.25 * lenR + mu * pillTerm + 10 * orphans + ALPHA * Math.max(0, aspect - 3);   // the cost's aspect term does not move with the dial (the search must not), only what is good enough does
  const arrows = plan.direct.length + plan.members.length;
  const n = Math.max(1, arrows);
  return {
    cost, X: cr.total, NE, NEnote, NEpill, Fx, len: lenR, pillTerm, orphans, aspect, hw, arrows: plan.direct.length, sharedArrows: plan.members.length, pills: pills.length, per, segs,
    good: isGood(model.dial, { NE, X: cr.total, Fx, aspect }, n),
  };
}

/** Ranks: the rows of shapes, by their centers' height. */
export function ranksOf(layout, tol = 60) {
  const cs = [...layout.boxes].map(([t, b]) => ({ t, y: b.y + b.h / 2 })).sort((p, q) => p.y - q.y || (p.t < q.t ? -1 : 1));
  const rank = new Map();
  let r = -1, base = -Infinity;
  for (const c of cs) { if (c.y - base > tol) { r++; base = c.y; } rank.set(c.t, r); }
  return rank;
}

export const FILL_WEIGHT = 1, OWN_ASPECT = 2;

/**
 * A container's own cost, for choosing between two layouts of it: its children (items with a width and height, laid out at pos)
 * and the arrows among them (edges {a, b, n}: n arrows between the two). X + 2 NE + 0.25 len/rank + alpha aspect, and a little
 * for the room left empty (area over the area of the children, less 1).
 */
export function ownCost(items, pos, edges, fillWeight = FILL_WEIGHT) {
  const boxes = items.map((it, i) => ({ x: pos[i].x, y: pos[i].y, w: it.w, h: it.h }));
  let x1 = 0, y1 = 0, area = 0;
  boxes.forEach((b) => { x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); area += b.w * b.h; });
  const segs = edges.map((e) => { const s = arrowBetween(boxes[e.a], boxes[e.b]); s.a = e.a; s.b = e.b; return s; });
  const cr = crossings(segs);
  const grid = new BoxGrid(boxes);
  let X = 0, NE = 0, len = 0;
  segs.forEach((s, i) => {
    const e = edges[i];
    for (const j of grid.near(s)) { if (j === e.a || j === e.b) continue; if (segHitsBox(s, boxes[j])) NE += e.n; }
    len += segLength(s) * e.n;
    X += cr.per[i] * e.n * 0.5;   // each crossing is counted by both arrows
  });
  const rank = (median(boxes.map((b) => b.h)) || 200) + 64;
  const aspect = x1 > 0 && y1 > 0 ? Math.max(x1 / y1, y1 / x1) : 1;
  const emptiness = area > 0 ? (x1 * y1) / area - 1 : 0;
  // the shape terms count for more where there are more arrows to be told apart: a board of 300 arrows wants a shape a screen can show
  const scale = 1 + 0.25 * edges.reduce((s, e) => s + e.n, 0);
  return X + 2 * NE + 0.25 * len / rank + scale * (ALPHA * Math.max(0, aspect - OWN_ASPECT) + fillWeight * emptiness);
}
