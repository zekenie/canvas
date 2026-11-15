// Boxes and segments, and a uniform grid that finds the crossings without testing every pair.
// What the layout decides by must come out the same under every engine the tool runs in (jsc for the app, node for the tests), and an
// engine may round Math.hypot, Math.cos, Math.sin, Math.atan2 and Math.log its own way in the last bit, where a square root and the four
// operations round as IEEE 754 says: so the tool measures with `len` and turns with `cosd`, `sind` and `atan2d`, which use nothing else.

/** The length of (dx, dy). */
export const len = (dx, dy) => Math.sqrt(dx * dx + dy * dy);

const HALF_PI = 1.5707963267948966, PI = 3.141592653589793;
/** sin x, |x| <= pi / 4: Taylor to x^17, past the last bit. */
function sinSmall(x) { const x2 = x * x; let t = x, s = x; for (let k = 1; k <= 8; k++) { t *= -x2 / ((2 * k) * (2 * k + 1)); s += t; } return s; }
/** cos x, |x| <= pi / 4: Taylor to x^16. */
function cosSmall(x) { const x2 = x * x; let t = 1, s = 1; for (let k = 1; k <= 8; k++) { t *= -x2 / ((2 * k - 1) * (2 * k)); s += t; } return s; }
/** sin and cos of x as [sin, cos], the angle taken to within pi / 4 of a multiple of pi / 2 first. */
function sinCos(x) {
  const k = Math.round(x / HALF_PI), r = x - k * HALF_PI, s = sinSmall(r), c = cosSmall(r);
  switch (((k % 4) + 4) % 4) { case 0: return [s, c]; case 1: return [c, -s]; case 2: return [-s, -c]; default: return [-c, s]; }
}
export const sind = (x) => sinCos(x)[0];
export const cosd = (x) => sinCos(x)[1];
const TAN_PI_12 = 0.2679491924311227, SQRT3 = Math.sqrt(3);
/** atan t, 0 <= t <= 1: past tan(pi / 12), atan t = pi / 6 + atan((t sqrt 3 - 1) / (t + sqrt 3)); then the series, to u^25. */
function atanUnit(t) {
  let base = 0, u = t;
  if (t > TAN_PI_12) { base = PI / 6; u = (t * SQRT3 - 1) / (t + SQRT3); }
  const u2 = u * u;
  let p = u, s = u;
  for (let k = 1; k <= 12; k++) { p *= -u2; s += p / (2 * k + 1); }
  return base + s;
}
/** The angle of (x, y), as atan2d(y, x) has it, from -pi to pi. */
export function atan2d(y, x) {
  if (x === 0 && y === 0) return 0;
  const ax = Math.abs(x), ay = Math.abs(y);
  let a = ay <= ax ? atanUnit(ay / ax) : HALF_PI - atanUnit(ax / ay);
  if (x < 0) a = PI - a;
  return y < 0 ? -a : a;
}

/** The segment of the straight line between two boxes' centers that lies between their borders. */
export function arrowBetween(a, b) {
  const ax = a.x + a.w / 2, ay = a.y + a.h / 2, bx = b.x + b.w / 2, by = b.y + b.h / 2;
  const dx = bx - ax, dy = by - ay;
  const exit = (cx, cy, w, h, sx, sy) => {   // where the ray from the center leaves the box
    const tx = sx === 0 ? Infinity : (w / 2) / Math.abs(sx), ty = sy === 0 ? Infinity : (h / 2) / Math.abs(sy);
    const t = Math.min(tx, ty, 1);
    return [cx + sx * t, cy + sy * t];
  };
  const [x1, y1] = exit(ax, ay, a.w, a.h, dx, dy);
  const [x2, y2] = exit(bx, by, b.w, b.h, -dx, -dy);
  // boxes that overlap along the line: a point
  if ((x2 - x1) * dx + (y2 - y1) * dy < 0) { const mx = (ax + bx) / 2, my = (ay + by) / 2; return { x1: mx, y1: my, x2: mx, y2: my }; }
  return { x1, y1, x2, y2 };
}

export const segLength = (s) => len(s.x2 - s.x1, s.y2 - s.y1);

/** The circle through three points: [ux, uy, r], or null when they are in a line. */
function circle3(a, c, b) {
  const d = 2 * (a[0] * (c[1] - b[1]) + c[0] * (b[1] - a[1]) + b[0] * (a[1] - c[1]));
  if (Math.abs(d) < 1e-9) return null;
  const s = (p) => p[0] * p[0] + p[1] * p[1];
  const ux = (s(a) * (c[1] - b[1]) + s(c) * (b[1] - a[1]) + s(b) * (a[1] - c[1])) / d;
  const uy = (s(a) * (b[0] - c[0]) + s(c) * (a[0] - b[0]) + s(b) * (c[0] - a[0])) / d;
  return [ux, uy, len(a[0] - ux, a[1] - uy)];
}

const within = (p, b) => p[0] > b.x && p[0] < b.x + b.w && p[1] > b.y && p[1] < b.y + b.h;

/** Whether `hub` is as good as on the line from `first` to `last` (points): under a quarter of a unit off it, or the two far ends are one point (the app's ArrowThrough.isStraight). */
export function isStraightThrough(first, hub, last) {
  const cx = last[0] - first[0], cy = last[1] - first[1], length = len(cx, cy);
  if (!(length > 0)) return true;
  return Math.abs(cx * (hub[1] - first[1]) - cy * (hub[0] - first[0])) / length < 0.25;
}

/**
 * The bend of an arrow from `start` to `end` (points) that makes it the part of the circle through `start`, `end` and `third` between them, on the
 * side of the chord away from `third` (the app's ArrowThrough.bend): how a relationship type's two ends are drawn as one arc through it. Zero where
 * the three are on a line.
 */
export function throughBend(start, end, third) {
  const cx = end[0] - start[0], cy = end[1] - start[1], length = len(cx, cy);
  if (!(length > 0)) return 0;
  const circle = circle3(start, third, end);
  if (!circle) return 0;
  const [ux, uy, r] = circle;
  const mx = (start[0] + end[0]) / 2, my = (start[1] + end[1]) / 2;
  const ax = -cy / length, ay = cx / length;   // the chord's perpendicular, as the app's (-y, x)
  const tx = mx - ux, ty = my - uy, tl = len(tx, ty);
  const dx = tl > 1e-9 ? tx / tl : ax, dy = tl > 1e-9 ? ty / tl : ay;
  // the circle's points on the chord's perpendicular bisector are the middles of its two arcs between the ends: the one away from `third`
  const cross = (px, py) => cx * (py - start[1]) - cy * (px - start[0]);
  const side = cross(third[0], third[1]);
  const point = cross(ux + dx * r, uy + dy * r) * side < 0 ? [ux + dx * r, uy + dy * r] : [ux - dx * r, uy - dy * r];
  return (point[0] - mx) * ax + (point[1] - my) * ay;
}

/**
 * An arrow as the app draws it between two boxes, as points: straight between their centers, or (a `bend` of a unit or more) the arc through the
 * point `bend` units off the middle of that line, along its perpendicular (-dy, dx) as the app's ArrowGeometry has it, sampled (`samples` at
 * least, and a point every 40 units of a long arc, 400 at most); cut at both outlines.
 */
export function arrowPath(A, B, bend = 0, samples = 16) {
  const straight = () => { const s = arrowBetween(A, B); return [[s.x1, s.y1], [s.x2, s.y2]]; };
  if (!(Math.abs(bend) >= 1)) return straight();
  const a = [A.x + A.w / 2, A.y + A.h / 2], b = [B.x + B.w / 2, B.y + B.h / 2];
  const dx = b[0] - a[0], dy = b[1] - a[1], L = len(dx, dy);
  if (!(L > 0)) return straight();
  const c = [(a[0] + b[0]) / 2 - (dy / L) * bend, (a[1] + b[1]) / 2 + (dx / L) * bend];
  const circ = circle3(a, c, b);
  if (!circ) return straight();
  const [ux, uy, r] = circ, t0 = atan2d(a[1] - uy, a[0] - ux);
  const norm = (t) => { while (t < t0) t += 2 * Math.PI; while (t >= t0 + 2 * Math.PI) t -= 2 * Math.PI; return t; };
  let t1 = norm(atan2d(b[1] - uy, b[0] - ux));
  const tc = norm(atan2d(c[1] - uy, c[0] - ux));
  if (!(tc > t0 && tc < t1)) t1 -= 2 * Math.PI;   // the arc runs the other way round, through the bend point
  const pts = [], n = Math.max(samples, Math.min(400, Math.ceil(Math.abs(t1 - t0) * r / 40)));
  for (let i = 0; i <= n; i++) { const t = t0 + (t1 - t0) * i / n; const p = [ux + r * cosd(t), uy + r * sind(t)]; if (!within(p, A) && !within(p, B)) pts.push(p); }
  return pts.length >= 2 ? pts : straight();
}

function orient(ax, ay, bx, by, cx, cy) {
  const v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  return v > 1e-9 ? 1 : v < -1e-9 ? -1 : 0;
}

/** A proper crossing: the segments cross at a point interior to both. */
export function segCross(s, t) {
  const o1 = orient(s.x1, s.y1, s.x2, s.y2, t.x1, t.y1), o2 = orient(s.x1, s.y1, s.x2, s.y2, t.x2, t.y2);
  const o3 = orient(t.x1, t.y1, t.x2, t.y2, s.x1, s.y1), o4 = orient(t.x1, t.y1, t.x2, t.y2, s.x2, s.y2);
  return o1 * o2 < 0 && o3 * o4 < 0;
}

/** Whether a segment passes through the inside of a box shrunk by `inset` (Liang-Barsky). */
export function segHitsBox(s, b, inset = 1) {
  const xmin = b.x + inset, xmax = b.x + b.w - inset, ymin = b.y + inset, ymax = b.y + b.h - inset;
  if (xmin >= xmax || ymin >= ymax) return false;
  let t0 = 0, t1 = 1;
  const dx = s.x2 - s.x1, dy = s.y2 - s.y1;
  const clip = (p, qq) => {
    if (p === 0) return qq >= 0;
    const r = qq / p;
    if (p < 0) { if (r > t1) return false; if (r > t0) t0 = r; } else { if (r < t0) return false; if (r < t1) t1 = r; }
    return true;
  };
  return clip(-dx, s.x1 - xmin) && clip(dx, xmax - s.x1) && clip(-dy, s.y1 - ymin) && clip(dy, ymax - s.y1) && t1 - t0 > 1e-9;
}

export const inside = (x, y, b) => x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h;

/** The cells of a grid of `cell` units that a segment passes through (each cell's key as `cellsOf` makes it). */
export function cellsAlong(s, cell, fn) {
  let x1 = s.x1, y1 = s.y1, x2 = s.x2, y2 = s.y2;
  if (x1 > x2) { [x1, x2] = [x2, x1]; [y1, y2] = [y2, y1]; }
  const c0 = Math.floor(x1 / cell), c1 = Math.floor(x2 / cell);
  for (let cx = c0; cx <= c1; cx++) {
    const xa = Math.max(x1, cx * cell), xb = Math.min(x2, (cx + 1) * cell);
    const ya = x2 === x1 ? y1 : y1 + (y2 - y1) * (xa - x1) / (x2 - x1), yb = x2 === x1 ? y2 : y1 + (y2 - y1) * (xb - x1) / (x2 - x1);
    const r0 = Math.floor(Math.min(ya, yb) / cell), r1 = Math.floor(Math.max(ya, yb) / cell);
    for (let cy = r0; cy <= r1; cy++) fn(cx * 100003 + cy);
  }
}

/** Cells a bounding box covers, in a grid of `cell` units. */
export function cellsOf(x0, y0, x1, y1, cell, fn) {
  const cx0 = Math.floor(Math.min(x0, x1) / cell), cx1 = Math.floor(Math.max(x0, x1) / cell);
  const cy0 = Math.floor(Math.min(y0, y1) / cell), cy1 = Math.floor(Math.max(y0, y1) / cell);
  for (let cx = cx0; cx <= cx1; cx++) for (let cy = cy0; cy <= cy1; cy++) fn(cx * 100003 + cy);
}

/**
 * Segment-segment crossings, on a grid. `segs[i].ends` (two ids) lets a pair that shares an end go uncounted.
 * Returns the number of crossings and, per segment, how many it takes part in.
 */
export function crossings(segs, cell = 320) {
  const grid = new Map();
  segs.forEach((s, i) => cellsOf(s.x1, s.y1, s.x2, s.y2, cell, (k) => { let l = grid.get(k); if (!l) grid.set(k, l = []); l.push(i); }));
  const seen = new Set(), per = new Array(segs.length).fill(0);
  let total = 0;
  for (const list of grid.values()) {
    for (let a = 0; a < list.length; a++) {
      for (let b = a + 1; b < list.length; b++) {
        const i = list[a], j = list[b];
        const key = i * segs.length + j;
        if (seen.has(key)) continue;
        seen.add(key);
        const s = segs[i], t = segs[j];
        if (s.a === t.a || s.a === t.b || s.b === t.a || s.b === t.b) continue;
        if (segCross(s, t)) { total++; per[i]++; per[j]++; }
      }
    }
  }
  return { total, per };
}

/** A grid of boxes: `query(segment)` lists the boxes whose cells the segment's bounding box touches. */
export class BoxGrid {
  constructor(boxes, cell = 320) {
    this.cell = cell; this.boxes = boxes; this.grid = new Map();
    boxes.forEach((b, i) => cellsOf(b.x, b.y, b.x + b.w, b.y + b.h, cell, (k) => { let l = this.grid.get(k); if (!l) this.grid.set(k, l = []); l.push(i); }));
  }
  near(s) {
    const out = new Set();
    cellsOf(s.x1, s.y1, s.x2, s.y2, this.cell, (k) => { const l = this.grid.get(k); if (l) for (const i of l) out.add(i); });
    return [...out].sort((a, b) => a - b);
  }
}
