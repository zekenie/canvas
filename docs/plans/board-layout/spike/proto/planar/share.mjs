// Shared pills, a pass after any direction: where two notes each have a pill for the same target, one of them may draw its arrow into the
// other's pill instead, and its own pill goes. A merge is taken only when the new arrow is clean (crosses no arrow, passes over no note and
// no pill but its own end) and short; the shortest first. Then each block that lost pills closes up, where that keeps the board as clean
// as it was. Fewer pills, the same promise: nothing gets worse.
//   sharePills(m, board, layout, { maxLength }) -> { layout, merged, closed }
import { arrowPoints } from '../harness.mjs';
import { pathHitsBox, evaluate } from './kit.mjs';

const segsCross = (p1, p2, p3, p4) => {
  const o = (a, b, c) => { const v = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]); return v > 1e-9 ? 1 : v < -1e-9 ? -1 : 0; };
  return o(p1, p2, p3) * o(p1, p2, p4) < 0 && o(p3, p4, p1) * o(p3, p4, p2) < 0;
};
const bbox = (pts) => pts.reduce((r, q) => [Math.min(r[0], q[0]), Math.min(r[1], q[1]), Math.max(r[2], q[0]), Math.max(r[3], q[1])], [Infinity, Infinity, -Infinity, -Infinity]);
const pathsCross = (a, b, ba, bb) => {
  if (ba[0] > bb[2] || bb[0] > ba[2] || ba[1] > bb[3] || bb[1] > ba[3]) return false;
  for (let s = 1; s < a.length; s++) for (let t = 1; t < b.length; t++) if (segsCross(a[s - 1], a[s], b[t - 1], b[t])) return true;
  return false;
};
const length = (pts) => { let s = 0; for (let i = 1; i < pts.length; i++) s += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); return s; };

export function sharePills(m, board, layout, opts = {}) {
  const maxLength = opts.maxLength || 520;
  const L = { boxes: layout.boxes, pills: layout.pills.map((p) => Object.assign({}, p)), arrows: layout.arrows.map((a) => Object.assign({}, a)) };
  const pillById = () => new Map(L.pills.map((p) => [p.id, p]));
  let byId = pillById();
  const boxOf = (id) => L.boxes[id] || byId.get(id);
  const notes = Object.entries(L.boxes).filter(([k]) => !m.node(k).isFrame);
  const pathOf = (a) => { const A = boxOf(a.from), B = boxOf(a.to); return A && B ? arrowPoints(A, B, a, 16) : []; };
  let paths = L.arrows.map(pathOf), boxes = paths.map((p) => (p.length ? bbox(p) : null));
  // a candidate arrow from note v into pill P is clean: crosses no arrow that doesn't share an end with it, passes over no note but v and
  // no pill but P (and v's own, which v's other arrows already pass)
  const clean = (v, P, pts, skip) => {
    const bb = bbox(pts);
    for (const [k, b] of notes) if (k !== v && !(b.x > bb[2] || b.x + b.w < bb[0] || b.y > bb[3] || b.y + b.h < bb[1]) && pathHitsBox(pts, b)) return false;
    for (const p of L.pills) {
      if (p.id === P.id || skip.has(p.id) || p.user === v) continue;
      if (p.x > bb[2] || p.x + p.w < bb[0] || p.y > bb[3] || p.y + p.h < bb[1]) continue;
      if (pathHitsBox(pts, { x: p.x + 1, y: p.y + 1, w: p.w - 2, h: p.h - 2 })) return false;
    }
    for (let i = 0; i < L.arrows.length; i++) {
      const a = L.arrows[i];
      if (!paths[i].length || skip.has(a.to) || a.from === v || a.to === v || a.to === P.id) continue;
      if (pathsCross(pts, paths[i], bb, boxes[i])) return false;
    }
    return true;
  };
  // candidates: pairs of pills for one target, users apart, the new arrow short; the shortest first
  const holderOf = (k) => { const n = m.node(k); return n.in != null && m.node(n.in).isFrame ? n.in : null; };
  const byTarget = new Map();
  for (const p of L.pills) { if (!byTarget.has(p.for)) byTarget.set(p.for, []); byTarget.get(p.for).push(p); }
  const cands = [];
  for (const list of byTarget.values()) {
    if (list.length < 2) continue;
    for (const P of list) for (const Q of list) {
      // a pill is shared by shapes in one container only (the same frame, or none), as the app has it
      if (P === Q || P.user === Q.user || holderOf(P.user) !== holderOf(Q.user)) continue;
      const V = L.boxes[Q.user];
      if (!V) continue;
      const d = Math.hypot(V.x + V.w / 2 - (P.x + P.w / 2), V.y + V.h / 2 - (P.y + P.h / 2));
      if (d <= maxLength + 200) cands.push({ P, Q, d });
    }
  }
  cands.sort((a, b) => a.d - b.d || (a.Q.id < b.Q.id ? -1 : 1));
  const gone = new Set(), lost = new Set();
  let merged = 0;
  for (const { P, Q } of cands) {
    // a pill already shared stays: its other users' arrows would move with it, unchecked
    if (gone.has(P.id) || gone.has(Q.id) || (Q.users && Q.users.length > 1)) continue;
    const v = Q.user, V = L.boxes[v];
    const skip = new Set([Q.id]);
    // straight only: an arrow into a pill is drawn as the app draws a pill's arrow, between the centers
    const bend = 0;
    const pts = arrowPoints(V, P, { bend }, 16);
    if (pts.length < 2 || length(pts) > maxLength || !clean(v, P, pts, skip)) continue;
    // take it: v's arrows into Q go into P
    for (let i = 0; i < L.arrows.length; i++) if (L.arrows[i].to === Q.id) { L.arrows[i].to = P.id; L.arrows[i].bend = bend; paths[i] = pts; boxes[i] = bbox(pts); }
    gone.add(Q.id);
    lost.add(v);
    L.pills = L.pills.filter((p) => p.id !== Q.id);
    byId = pillById();
    if (!P.users) P.users = [P.user];
    P.users.push(v);
    merged++;
    if (opts.debug) { const e = evaluate(m, board, { boxes: L.boxes, pills: L.pills, arrows: L.arrows }); if (e.crossings !== opts.debug.c || e.overNotes !== opts.debug.n) { console.error('merge', merged, m.node(v).title, '->', P.id.slice(5, 60), 'crossings', opts.debug.c, '->', e.crossings, 'over notes', opts.debug.n, '->', e.overNotes, 'len', Math.round(length(pts)), JSON.stringify(pts.map((q) => q.map(Math.round)))); opts.debug.c = e.crossings; opts.debug.n = e.overNotes; } }
  }
  // close up the blocks that lost pills: each remaining pill of a user moves up its column into a gap, if the board stays as clean
  const before = evaluate(m, board, L);
  if (opts.debug) console.error("after merges", before.crossings, before.overNotes, before.overOtherPills);
  let closed = 0;
  for (const u of lost) {
    const mine = L.pills.filter((p) => p.user === u).sort((a, b) => a.x - b.x || a.y - b.y);
    if (!mine.length) continue;
    // a column is the pills whose x ranges overlap (a block on a note's left is right-aligned); a row (pills side by side) isn't closed up
    const cols = [];
    for (const p of mine.slice().sort((a, b) => a.x - b.x)) { const c = cols.find((cc) => cc.some((q) => q.x < p.x + p.w && p.x < q.x + q.w)); if (c) c.push(p); else cols.push([p]); }
    const saved = mine.map((p) => [p, p.x, p.y]);
    for (const col of cols) { if (col.length < 2) continue; let y = Math.min(...col.map((p) => p.y)); for (const p of col.sort((a, b) => a.y - b.y)) { p.y = y; y += p.h + 8; } }
    byId = pillById();
    const after = evaluate(m, board, L);
    const hit = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
    const clash = mine.some((p) => L.pills.some((q) => q !== p && hit(p, q)) || Object.entries(L.boxes).some(([k, b]) => !m.node(k).isFrame && hit(p, { x: b.x, y: b.y - 28, w: b.w, h: b.h + 28 })));
    if (clash || after.crossings > before.crossings || after.overNotes > before.overNotes || after.overOtherPills > before.overOtherPills) {
      for (const [p, x, y] of saved) { p.x = x; p.y = y; }
      byId = pillById();
    } else closed++;
  }
  return { layout: L, merged, closed };
}
