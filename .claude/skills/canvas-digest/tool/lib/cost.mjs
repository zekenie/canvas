// What a container's layout costs, for choosing between two layouts of it (rows down or across, a tree down or across, the ways ranked
// children run), and what being off the shape it is to be costs: its arrows (crossings, arrows over boxes, length), its shape against the
// view's (elk.mjs's offShapeOf) and the room it leaves empty. Arrows are measured as straight segments between box borders.
import { median } from './util.mjs';
import { arrowBetween, segLength, crossings, segHitsBox, BoxGrid } from './geom.mjs';
import { offShapeOf, DEFAULT_ASPECT } from './elk.mjs';

/** What the room a layout leaves empty costs, beside its shape (SHAPE_WEIGHT): the two together are how small the view shows it, fit to it. */
export const FILL_WEIGHT = 3;

/** How far off the shape wanted a container may be for nothing (a tenth too wide or too tall shows at 95% of the size), and what each time further off costs. */
export const FREE_SHAPE = 1.1, SHAPE_WEIGHT = 10;

/**
 * What being off the shape wanted costs a container (or a board) with `arrows` arrows: it counts for more where there are more arrows to be
 * told apart, since a board of 300 arrows wants a shape a screen can show.
 */
export const shapeCost = (off, arrows) => (1 + 0.25 * arrows) * SHAPE_WEIGHT * Math.max(0, off - FREE_SHAPE);

/**
 * A container's own cost, for choosing between two layouts of it: its children (items with a width and height, laid out at pos)
 * and the arrows among them (edges {a, b, n, np}: n arrows between the two, np of them into a pill beside b). X + 2 NE + 0.25 len/rank,
 * what its shape costs (`shape`: {aspect, viewW, viewH}, the shape it is to be and the view's size: elk.mjs's offShapeOf, shapeCost) and what the room it leaves empty does (area over the area of the children, less 1, times `fillWeight`). A child with pills (nw, nh,
 * nx, ny: its note's size and place in the child's box; `strips`, the boxes its pills take) is its note and its strips to an arrow: the
 * arrow leaves and meets the note (or, into a pill, the strips), and runs over the strips, as an arrow that goes sideways from a note does.
 * Returns {total, arrows, shape, off, w, h, n}: the whole cost, the arrows' part of it, the shape's and the room's, how far off its shape it is, its size and how many arrows it has.
 */
export function ownCostParts(items, pos, edges, fillWeight = FILL_WEIGHT, shape = null) {
  const boxes = items.map((it, i) => ({ x: pos[i].x, y: pos[i].y, w: it.w, h: it.h }));
  const split = items.map((it) => it.nw != null && !!it.strips && it.strips.length > 0);
  // the note at `nx`, `ny` in its box; its pills' strips (`strips`, in the box's coordinates) the rest
  const bodies = items.map((it, i) => (split[i] ? { x: pos[i].x + (it.nx || 0), y: pos[i].y + it.ny, w: it.nw, h: it.nh } : boxes[i]));
  const strips = items.map((it, i) => (split[i] ? it.strips.map((s) => ({ x: pos[i].x + s.x, y: pos[i].y + s.y, w: s.w, h: s.h })) : []));
  // the room an arrow into one of a child's pills runs to: what its strips take, as one box
  const tails = strips.map((ss) => {
    if (!ss.length) return null;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const s of ss) { x0 = Math.min(x0, s.x); y0 = Math.min(y0, s.y); x1 = Math.max(x1, s.x + s.w); y1 = Math.max(y1, s.y + s.h); }
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  });
  let x1 = 0, y1 = 0, area = 0;
  boxes.forEach((b) => { x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); area += b.w * b.h; });
  // an arrow a pair: two when some of the pair's arrows run to the note and some to a pill beside it
  const segs = [];
  for (const e of edges) {
    const np = tails[e.b] ? Math.min(e.n, e.np || 0) : 0;
    if (e.n - np > 0) { const s = arrowBetween(bodies[e.a], bodies[e.b]); s.a = e.a; s.b = e.b; s.n = e.n - np; s.over = strips[e.a].concat(strips[e.b]); segs.push(s); }
    if (np > 0) { const s = arrowBetween(bodies[e.a], tails[e.b]); s.a = e.a; s.b = e.b; s.n = np; s.over = strips[e.a].concat([bodies[e.b]]); segs.push(s); }
  }
  const cr = crossings(segs);
  const grid = new BoxGrid(boxes);
  let X = 0, NE = 0, len = 0;
  segs.forEach((s, i) => {
    for (const j of grid.near(s)) { if (j === s.a || j === s.b) continue; if (segHitsBox(s, boxes[j])) NE += s.n; }
    for (const b of s.over) if (b && segHitsBox(s, b)) NE += s.n;
    len += segLength(s) * s.n;
    X += cr.per[i] * s.n * 0.5;   // each crossing is counted by both arrows
  });
  const rank = (median(boxes.map((b) => b.h)) || 200) + 64;
  const sh = shape || { aspect: DEFAULT_ASPECT };
  const off = offShapeOf(x1, y1, sh);
  const emptiness = area > 0 ? (x1 * y1) / area - 1 : 0;
  const n = edges.reduce((t, e) => t + e.n, 0);
  const arrows = X + 2 * NE + 0.25 * len / rank;
  const shapeTerm = shapeCost(off, n) + (1 + 0.25 * n) * fillWeight * emptiness;
  return { total: arrows + shapeTerm, arrows, shape: shapeTerm, off, w: x1, h: y1, n };
}

export function ownCost(items, pos, edges, fillWeight = FILL_WEIGHT, shape = null) {
  return ownCostParts(items, pos, edges, fillWeight, shape).total;
}
