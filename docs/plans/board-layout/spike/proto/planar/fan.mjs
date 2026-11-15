// A note's pills in a fan, a pass after any direction (and after shared pills). The app draws a note's arrow into its pill straight between
// the two centers, so a block of pills beside a note is a patch of lines over pills. Here each note's own pills (a shared pill stays where
// it is) are put down again one at a time, the nearest spot first, leaning toward where the block was: a spot where the pill overlaps
// nothing (a note with room for its title tab, another pill, a frame it isn't in; inside its frame when it's in one), its line passes over
// no note and no pill and crosses no line but its own note's, and no line passes over it. A pill with no such spot within reach goes to the
// nearest spot where it at least overlaps nothing. Lines from one note never cross each other, so the block becomes a fan of clean spokes.
//   fanPills(m, board, layout, { step, maxRadius, angles }) -> { layout, fanned, kept }
import { arrowPoints } from '../harness.mjs';

const TAB = 30;     // room above a note for its title tab
const GAP = 8;      // between a pill and anything it sits beside
const CELL = 160;
const segsCross = (p1, p2, p3, p4) => {
  const o = (a, b, c) => { const v = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]); return v > 1e-9 ? 1 : v < -1e-9 ? -1 : 0; };
  return o(p1, p2, p3) * o(p1, p2, p4) < 0 && o(p3, p4, p1) * o(p3, p4, p2) < 0;
};
const boxOfPts = (pts) => { const bb = pts.reduce((r, q) => [Math.min(r[0], q[0]), Math.min(r[1], q[1]), Math.max(r[2], q[0]), Math.max(r[3], q[1])], [Infinity, Infinity, -Infinity, -Infinity]); return { x: bb[0], y: bb[1], w: bb[2] - bb[0], h: bb[3] - bb[1] }; };
const overlaps = (a, b, g = 0) => a.x < b.x + b.w + g && b.x < a.x + a.w + g && a.y < b.y + b.h + g && b.y < a.y + a.h + g;
function segHitsBox(p, q, b) {
  let t0 = 0, t1 = 1;
  const dx = q[0] - p[0], dy = q[1] - p[1];
  const clip = (pp, qq) => { if (pp === 0) return qq >= 0; const r = qq / pp; if (pp < 0) { if (r > t1) return false; if (r > t0) t0 = r; } else { if (r < t0) return false; if (r < t1) t1 = r; } return true; };
  return clip(-dx, p[0] - b.x) && clip(dx, b.x + b.w - p[0]) && clip(-dy, p[1] - b.y) && clip(dy, b.y + b.h - p[1]) && t1 - t0 > 1e-9;
}
const pathHits = (pts, b) => { for (let j = 1; j < pts.length; j++) if (segHitsBox(pts[j - 1], pts[j], b)) return true; return false; };
const shrink = (b, d) => ({ x: b.x + d, y: b.y + d, w: b.w - 2 * d, h: b.h - 2 * d });

/** A uniform grid of cells holding items by their boxes: what is near a box, without looking at everything. */
class Grid {
  constructor() { this.cells = new Map(); }
  span(b) { return [Math.floor(b.x / CELL), Math.floor((b.x + b.w) / CELL), Math.floor(b.y / CELL), Math.floor((b.y + b.h) / CELL)]; }
  add(it) { const [x0, x1, y0, y1] = this.span(it.b); it.cells = []; for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) { const k = x * 100003 + y; if (!this.cells.has(k)) this.cells.set(k, new Set()); this.cells.get(k).add(it); it.cells.push(k); } }
  remove(it) { for (const k of it.cells || []) this.cells.get(k).delete(it); it.cells = []; }
  near(b) { const [x0, x1, y0, y1] = this.span(b), out = new Set(); for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) { const s = this.cells.get(x * 100003 + y); if (s) for (const it of s) out.add(it); } return out; }
}

export function fanPills(m, board, layout, opts = {}) {
  const step = opts.step || 24, maxRadius = opts.maxRadius || 1100, angles = opts.angles || 72;
  const L = { boxes: layout.boxes, pills: layout.pills.map((p) => Object.assign({}, p)), arrows: layout.arrows.map((a) => Object.assign({}, a)) };
  const holderOf = (k) => { const n = m.node(k); return n.in != null && m.node(n.in).isFrame ? n.in : null; };
  const pillById = new Map(L.pills.map((p) => [p.id, p]));
  const boxOf = (id) => L.boxes[id] || pillById.get(id);
  // what is in the way, by kind: notes (with their title tab's room), frames, pills, arrows' paths
  const G = new Grid();
  for (const [k, b] of Object.entries(L.boxes)) G.add(m.node(k).isFrame ? { kind: 'frame', key: k, b } : { kind: 'note', key: k, b: { x: b.x, y: b.y - TAB, w: b.w, h: b.h + TAB }, body: b });
  const pillItem = new Map();
  for (const p of L.pills) { const it = { kind: 'pill', p, b: p }; pillItem.set(p.id, it); G.add(it); }
  const arrowItem = L.arrows.map((a, i) => {
    const A = boxOf(a.from), B = boxOf(a.to);
    const pts = A && B ? arrowPoints(A, B, a, 16) : [];
    const it = { kind: 'arrow', i, a, pts, b: pts.length ? boxOfPts(pts) : { x: 0, y: 0, w: 0, h: 0 } };
    if (pts.length) G.add(it);
    return it;
  });
  const usersOf = new Map();
  for (const a of L.arrows) if (pillById.has(a.to)) { if (!usersOf.has(a.to)) usersOf.set(a.to, new Set()); usersOf.get(a.to).add(a.from); }
  const own = new Map();
  for (const p of L.pills) { const us = usersOf.get(p.id); if (us && us.size === 1) { const u = [...us][0]; if (!own.has(u)) own.set(u, []); own.get(u).push(p); } }
  if (opts.only) for (const [u, list] of own) { const keep = list.filter((p) => opts.only.has(p.id)); if (keep.length) own.set(u, keep); else own.delete(u); }
  const order = [...own.keys()].sort((a, b) => own.get(b).length - own.get(a).length || (a < b ? -1 : 1));
  let fanned = 0, kept = 0;
  for (const u of order) {
    const U = L.boxes[u];
    if (!U) continue;
    const mine = own.get(u), mineIds = new Set(mine.map((p) => p.id)), uHolder = holderOf(u);
    const C = [U.x + U.w / 2, U.y + U.h / 2];
    const mx = mine.reduce((s, p) => s + p.x + p.w / 2, 0) / mine.length - C[0], my = mine.reduce((s, p) => s + p.y + p.h / 2, 0) / mine.length - C[1];
    const lean = Math.atan2(my, mx);
    const fb = uHolder ? L.boxes[uHolder] : null;
    const inside = fb ? { x: fb.x + 16, y: fb.y + 56, w: fb.w - 32, h: fb.h - 72 } : null;
    const home = new Map(mine.map((p) => [p.id, { x: p.x, y: p.y }]));
    // lift this note's pills and their lines out of the way
    const myArrows = arrowItem.filter((it) => mineIds.has(it.a.to));
    for (const p of mine) G.remove(pillItem.get(p.id));
    for (const it of myArrows) G.remove(it);
    const angleList = [];
    for (let k = 0; k < angles; k++) angleList.push(lean + Math.ceil(k / 2) * (2 * Math.PI / angles) * (k % 2 ? 1 : -1));
    const fits = (B, strict) => {
      if (inside && !(B.x >= inside.x && B.y >= inside.y && B.x + B.w <= inside.x + inside.w && B.y + B.h <= inside.y + inside.h)) return false;
      const near = G.near({ x: B.x - GAP, y: B.y - GAP, w: B.w + 2 * GAP, h: B.h + 2 * GAP });
      for (const it of near) {
        if (it.kind === 'note' && overlaps(B, it.b, GAP)) return false;
        if (it.kind === 'frame' && it.key !== uHolder && overlaps(B, it.b, GAP)) return false;
        if (it.kind === 'pill' && overlaps(B, it.b, GAP / 2)) return false;
        if (strict && it.kind === 'arrow' && overlaps(B, it.b) && pathHits(it.pts, shrink(B, 1))) return false;   // no line runs under it
      }
      if (!strict) return true;
      // its own line passes over nothing and crosses no line but its note's
      const pts = arrowPoints(U, B, { bend: 0 }, 2), lb = boxOfPts(pts);
      for (const it of G.near(lb)) {
        if (it.kind === 'note' && it.key !== u && pathHits(pts, shrink(it.body, 1))) return false;
        if (it.kind === 'pill' && pathHits(pts, shrink(it.b, 1))) return false;
        if (it.kind === 'arrow' && it.a.from !== u && it.a.to !== u && overlaps(lb, it.b)) { const P = it.pts; for (let s = 1; s < P.length; s++) if (segsCross(pts[0], pts[1], P[s - 1], P[s])) return false; }
      }
      return true;
    };
    const search = (p, strict) => {
      const r0 = Math.max(U.w, U.h) / 2 + Math.min(p.w, p.h) / 2 + GAP;
      for (let r = r0; r <= maxRadius; r += step) for (const t of angleList) {
        const B = { x: C[0] + r * Math.cos(t) - p.w / 2, y: C[1] + r * Math.sin(t) - p.h / 2, w: p.w, h: p.h };
        if (fits(B, strict)) return B;
      }
      return null;
    };
    for (const p of mine) {
      let spot = search(p, true);
      if (spot) fanned++; else { spot = (opts.only ? null : search(p, false)) || home.get(p.id); kept++; }
      p.x = spot.x; p.y = spot.y;
      const pit = pillItem.get(p.id); pit.b = p; G.add(pit);
      for (const it of myArrows) if (it.a.to === p.id) { it.pts = arrowPoints(U, p, it.a, 16); it.b = boxOfPts(it.pts); G.add(it); }
    }
  }
  return { layout: L, fanned, kept };
}
