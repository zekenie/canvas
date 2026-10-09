// Boxes and segments, and a uniform grid that finds the crossings without testing every pair.

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

export const segLength = (s) => Math.hypot(s.x2 - s.x1, s.y2 - s.y1);

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

/** Cells a bounding box covers, in a grid of `cell` units. */
function cellsOf(x0, y0, x1, y1, cell, fn) {
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
