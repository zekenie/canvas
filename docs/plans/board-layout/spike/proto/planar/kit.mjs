// The planar directions' shared kit: what every direction does the same, so their boards compare and only the placing differs.
//
//   const g = boardGraph(m, board)        the board's units (loose notes, and each frame as one unit), its edges inside, its edges to other boards
//   const c = cut(m, g, 'hubs')           what becomes a pill so the rest can be drawn with no crossing ('hubs': whole notes referenced, the
//                                          fewest found greedily, most connected first; 'edges': single edges; 'none')
//   const f = footprints(m, g, c)         each unit's box with its pills beside it (a loose note's block of pills on its right; a frame laid out
//                                          inside with its members' pills): what a direction places
//   ... a direction decides where every unit goes: at = Map(unit key -> {x, y}), the footprint's top-left ...
//   const layout = assemble(m, g, c, f, at, { bends })   the harness's layout: boxes, pills, arrows (each with its graph edge's index),
//                                          an arrow given no bend bent to clear what it would pass over, where a bend can
//   evaluate(m, board, layout)            harness.measure plus `clean` (no crossing, no arrow over a note or a pill)
//
// Only the app as it is: arrows are straight or one arc between two shapes' centers; every edge is drawn, as an arrow or into a pill.
import { measure, arrowPoints } from '../harness.mjs';
import { isPlanar, edgeCuts, hubCuts } from './planar.mjs';

export const TAB = 28;   // the room a note's or a frame's title tab takes above it (canvas measure's `above` is 27)

export const KIT = {
  pillGap: 16,        // between a note and its block of pills
  pillStep: 8,        // between pills in a column, and between columns
  pillsPerColumn: 8,  // a block wraps into another column past this many
  frame: { top: 84, side: 48, bottom: 48, gapX: 64, gapY: 96 },
  bends: [0, 40, -40, 80, -80, 120, -120, 180, -180, 260, -260, 360, -360, 480, -480],
  pad: 10,
  pillShape: process.env.KIT_PILLS || 'column',   // a note's pills: one column (a row above or below) centered on the note, its lines arcing clear of the pills between ('column'); a fan ('fan'); the first round's block of columns ('block')
};

const SEP = '\u0000';
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/** A board as the directions see it. A unit is what is placed: a loose note, or a frame (its members laid out inside by the kit). */
export function boardGraph(m, board) {
  const B = m.board(board);
  const frames = B.frames.slice();
  const outerFrame = (k) => { const fs = m.framesOf(k).filter((f) => m.boardOf(f) === board); return fs.length ? fs[0] : null; };
  const unitOf = (k) => outerFrame(k) || k;
  const units = B.top.slice().sort(byKey);
  const notes = B.leaves.filter((k) => !m.node(k).isFrame).sort(byKey);
  const on = m.edgesOn(board);
  const inner = on.same.filter((e) => !m.node(e.from).isFrame && !m.node(e.to).isFrame);
  const cross = on.cross.filter((e) => !m.node(e.from).isFrame);
  return { board, units, notes, frames, unitOf, inner, cross, isFrame: (k) => m.node(k).isFrame };
}

/**
 * What becomes a pill so that the rest is planar, asked of the units' graph (loose notes, each frame one vertex; an edge inside a frame is
 * the frame's own and stays an arrow inside it). Returns { mode, referenced: [note keys], cutEdges: [edge index], arrows: [edges drawn as
 * arrows], pills: [{edge, user, for}] (a pill for `for` beside `user`; an edge to another board is always one) }.
 */
export function cut(m, g, mode = 'hubs') {
  const ix = new Map(g.units.map((k, i) => [k, i]));
  const pairs = new Map();   // undirected unit pair -> the edges it stands for
  for (const e of g.inner) {
    const a = g.unitOf(e.from), b = g.unitOf(e.to);
    if (a === b) continue;
    const u = ix.get(a), v = ix.get(b), key = Math.min(u, v) + ',' + Math.max(u, v);
    if (!pairs.has(key)) pairs.set(key, { u: Math.min(u, v), v: Math.max(u, v), edges: [] });
    pairs.get(key).edges.push(e);
  }
  const n = g.units.length, list = [...pairs.values()];
  const edges = list.map((p) => [p.u, p.v]);
  const referenced = new Set(), cutPairs = new Set();
  if (mode === 'hubs' && !isPlanar(n, edges)) {
    // whole notes, most connected first (never a frame: a pill can't stand for one); what is still not planar then is cut edge by edge
    let rest = edges.map((e, i) => [e[0], e[1], i]);
    const deg = () => { const d = new Array(n).fill(0); for (const [u, v] of rest) { d[u]++; d[v]++; } return d; };
    while (!isPlanar(n, rest.map(([u, v]) => [u, v]))) {
      const d = deg();
      let best = -1;
      for (let x = 0; x < n; x++) if (!g.isFrame(g.units[x]) && d[x] > 0 && (best < 0 || d[x] > d[best])) best = x;
      if (best < 0) break;
      referenced.add(g.units[best]);
      rest = rest.filter(([u, v]) => u !== best && v !== best);
    }
    if (!isPlanar(n, rest.map(([u, v]) => [u, v]))) for (const i of cutOrder(n, rest)) cutPairs.add(i);
  } else if (mode === 'edges' && !isPlanar(n, edges)) {
    for (const i of cutOrder(n, edges.map((e, i) => [e[0], e[1], i]))) cutPairs.add(i);
  }
  const cutEdges = new Set();
  list.forEach((p, i) => { if (cutPairs.has(i)) for (const e of p.edges) cutEdges.add(e.i); });
  const arrows = [], pills = [];
  for (const e of g.inner) {
    if (referenced.has(e.to)) pills.push({ edge: e, user: e.from, for: e.to });
    else if (referenced.has(e.from)) pills.push({ edge: e, user: e.from, for: e.to });
    else if (cutEdges.has(e.i)) pills.push({ edge: e, user: e.from, for: e.to });
    else arrows.push(e);
  }
  for (const e of g.cross) pills.push({ edge: e, user: e.from, for: e.to });
  return { mode, referenced: [...referenced], cutEdges: [...cutEdges], arrows, pills };
}

/** The pairs a greedy maximal planar subgraph leaves out, adding the pairs at the least connected units first (so the cuts fall at hubs). */
function cutOrder(n, triples) {
  const d = new Array(n).fill(0);
  for (const [u, v] of triples) { d[u]++; d[v]++; }
  const ordered = triples.slice().sort((a, b) => Math.max(d[a[0]], d[a[1]]) - Math.max(d[b[0]], d[b[1]]) || a[2] - b[2]);
  // edgeCuts returns the very arrays it was given, each carrying its pair's index
  const arrs = ordered.map(([u, v, i]) => Object.assign([u, v], { idx: i }));
  return edgeCuts(n, arrs).map((a) => a.idx);
}

/** A unit's pills, one per target (a user with two edges to one target shares the pill): in-board ones first, then by board and title. */
function pillsByUser(m, c) {
  const by = new Map();
  for (const p of c.pills) {
    if (!by.has(p.user)) by.set(p.user, new Map());
    const mine = by.get(p.user);
    if (!mine.has(p.for)) mine.set(p.for, { for: p.for, user: p.user, edges: [] });
    mine.get(p.for).edges.push(p.edge);
  }
  const out = new Map();
  for (const [user, mine] of by) {
    const userBoard = m.boardOf(user);
    out.set(user, [...mine.values()].sort((a, b) => {
      const ab = m.boardOf(a.for) === userBoard ? 0 : 1, bb = m.boardOf(b.for) === userBoard ? 0 : 1;
      return ab - bb || byKey(m.boardOf(a.for), m.boardOf(b.for)) || byKey(m.node(a.for).title, m.node(b.for).title) || byKey(a.for, b.for);
    }));
  }
  return out;
}

const FAN = { tab: 30, gap: 8, between: 22, span: 80 * Math.PI / 180, angleStep: 2 * Math.PI / 180, radiusStep: 10 };
const boxesOverlap = (a, b, g = 0) => a.x < b.x + b.w + g && b.x < a.x + a.w + g && a.y < b.y + b.h + g && b.y < a.y + a.h + g;
const inset = (b, d) => ({ x: b.x + d, y: b.y + d, w: b.w - 2 * d, h: b.h - 2 * d });

/**
 * A note's pills fanned out on one side, laid out on their own: the app draws a note's arrow into its pill straight between the centers, so
 * each pill goes, nearest first and leaning to the side's middle, where its line passes over no other pill and no line passes over it (and
 * clear of the note and the room its title tab takes above it). Lines from one note never cross, so the fan's lines are clean by
 * construction. Returns the pills' places in a box that holds the note and the fan: { items, note: {dx, dy}, w, h }.
 */
function fanBlock(m, user, pills, side, nw, nh) {
  if (!pills.length) return { items: [], note: { dx: 0, dy: 0 }, w: nw, h: nh };
  const note = { x: 0, y: 0, w: nw, h: nh }, room = { x: 0, y: -FAN.tab, w: nw, h: nh + FAN.tab };
  const C = [nw / 2, nh / 2];
  const dir = { right: 0, below: Math.PI / 2, left: Math.PI, above: -Math.PI / 2 }[side] || 0;
  const angles = [dir];
  for (let a = FAN.angleStep; a <= FAN.span + 1e-9; a += FAN.angleStep) angles.push(dir + a, dir - a);
  const placed = [];
  for (const p of pills) {
    const [pw, ph] = m.pillSize(p.for, user);
    let spot = null;
    for (let r = Math.min(nw, nh) / 2 + Math.min(pw, ph) / 2; !spot && r < 6000; r += FAN.radiusStep) {
      for (const t of angles) {
        const B = { x: C[0] + r * Math.cos(t) - pw / 2, y: C[1] + r * Math.sin(t) - ph / 2, w: pw, h: ph };
        if (boxesOverlap(B, room, FAN.gap)) continue;
        // room between pills, so lines to the pills further out pass between them
        if (placed.some((q) => boxesOverlap(B, q, FAN.between))) continue;
        const line = arrowPoints(note, B, { bend: 0 }, 2);
        if (placed.some((q) => pathHitsBox(line, inset(q, 1)))) continue;
        if (placed.some((q) => pathHitsBox(q.line, inset(B, 1)))) continue;
        spot = Object.assign(B, { line });
        break;
      }
    }
    if (!spot) {   // never seen: past every ring, straight out from the side's middle beyond everything placed
      const far = Math.max(...placed.map((q) => Math.hypot(q.x + q.w / 2 - C[0], q.y + q.h / 2 - C[1])), 0) + 200;
      const B = { x: C[0] + far * Math.cos(dir) - pw / 2, y: C[1] + far * Math.sin(dir) - ph / 2, w: pw, h: ph };
      spot = Object.assign(B, { line: arrowPoints(note, B, { bend: 0 }, 2) });
    }
    placed.push(Object.assign(spot, { p }));
  }
  const x0 = Math.min(0, ...placed.map((q) => q.x)), y0 = Math.min(0, ...placed.map((q) => q.y));
  const x1 = Math.max(nw, ...placed.map((q) => q.x + q.w)), y1 = Math.max(nh, ...placed.map((q) => q.y + q.h));
  return {
    items: placed.map((q) => Object.assign({}, q.p, { dx: q.x - x0, dy: q.y - y0, w: q.w, h: q.h })),
    note: { dx: -x0, dy: -y0 }, w: x1 - x0, h: y1 - y0,
  };
}

/** A block of pills in columns of at most `most` (KIT.pillsPerColumn), top-left at (0, 0): [{...pill, dx, dy, w, h}], and its size. */
function pillBlock(m, user, pills, most = KIT.pillsPerColumn) {
  if (!pills.length) return { items: [], w: 0, h: 0 };
  const cols = Math.ceil(pills.length / most), per = Math.ceil(pills.length / cols);
  const items = [];
  let x = 0, h = 0;
  for (let c = 0; c < cols; c++) {
    const col = pills.slice(c * per, (c + 1) * per);
    let y = 0, w = 0;
    for (const p of col) {
      const [pw, ph] = m.pillSize(p.for, user);
      items.push(Object.assign({}, p, { dx: x, dy: y, w: pw, h: ph }));
      y += ph + KIT.pillStep; w = Math.max(w, pw);
    }
    h = Math.max(h, y - KIT.pillStep);
    x += w + KIT.pillStep;
  }
  return { items, w: x - KIT.pillStep, h };
}

/**
 * Every unit's footprint, what a direction places: { key, w, h, frame, note: {dx, dy, w, h} (a loose note's own box in it), members:
 * {key: {dx, dy, w, h}} (a frame's), pills: [{for, user, edges, dx, dy, w, h}], side }. A loose note's block goes on the side `sides` says
 * (Map or object, unit key -> 'right' (the default), 'left', 'below' or 'above'; a block above or below is wide: columns of at most 3);
 * a frame's members are laid out inside in rows (longest path down its own edges, then by key), each with its block on its right.
 */
export function footprints(m, g, c, sides = new Map()) {
  const by = pillsByUser(m, c);
  const fps = new Map();
  const sideOf = (k) => (sides instanceof Map ? sides.get(k) : sides[k]) || 'right';
  // every note's footprint keeps room above the note for its title tab: nothing else is placed there
  const noteFp = (k, side = 'right') => {
    const fp = noteFp0(k, side);
    if (fp.side === 'above' && fp.pills.length) {   // a row above: the tab goes between the row and the note
      const rowBottom = Math.max(...fp.pills.map((p) => p.dy + p.h));
      const need = rowBottom + TAB + 8 - fp.note.dy;
      if (need > 0) { fp.note.dy += need; fp.h += need; }
    }
    const shift = Math.max(0, TAB - Math.min(fp.note.dy, ...fp.pills.map((p) => p.dy + TAB)));
    if (shift > 0) { fp.note.dy += shift; for (const p of fp.pills) p.dy += shift; fp.h += shift; }
    return fp;
  };
  const noteFp0 = (k, side = 'right') => {
    const n = m.node(k), wide = side === 'below' || side === 'above';
    if (KIT.pillShape === 'fan') {
      const f = fanBlock(m, k, by.get(k) || [], side, n.w, n.h);
      return { w: f.w, h: f.h, side, note: { dx: f.note.dx, dy: f.note.dy, w: n.w, h: n.h }, pills: f.items };
    }
    if (KIT.pillShape === 'column') {
      // one column beside the note (one row above or below it), its middle level with the note's
      const items = by.get(k) || [];
      if (!items.length) return { w: n.w, h: n.h, side, note: { dx: 0, dy: 0, w: n.w, h: n.h }, pills: [] };
      const g0 = KIT.pillGap, sized = items.map((p) => { const [pw, ph] = m.pillSize(p.for, k); return Object.assign({}, p, { w: pw, h: ph }); });
      if (!wide) {
        const bw = Math.max(...sized.map((p) => p.w)), bh = sized.reduce((t, p) => t + p.h, 0) + KIT.pillStep * (sized.length - 1);
        const top = Math.max(0, (bh - n.h) / 2), ny = Math.max(0, (bh - n.h) / 2), by0 = Math.max(0, (n.h - bh) / 2);
        const noteX = side === 'left' ? bw + g0 : 0, colX = side === 'left' ? 0 : n.w + g0;
        let y = by0;
        const pills = sized.map((p) => { const q = Object.assign(p, { dx: colX + (side === 'left' ? bw - p.w : 0), dy: y }); y += p.h + KIT.pillStep; return q; });
        void top;
        return { w: n.w + g0 + bw, h: Math.max(n.h, bh), side, note: { dx: noteX, dy: ny, w: n.w, h: n.h }, pills };
      }
      const bh = Math.max(...sized.map((p) => p.h)), bw = sized.reduce((t, p) => t + p.w, 0) + KIT.pillStep * (sized.length - 1);
      const nx = Math.max(0, (bw - n.w) / 2), bx0 = Math.max(0, (n.w - bw) / 2);
      const noteY = side === 'above' ? bh + g0 : 0, rowY = side === 'above' ? 0 : n.h + g0;
      let x = bx0;
      const pills = sized.map((p) => { const q = Object.assign(p, { dx: x, dy: rowY }); x += p.w + KIT.pillStep; return q; });
      return { w: Math.max(n.w, bw), h: n.h + g0 + bh, side, note: { dx: nx, dy: noteY, w: n.w, h: n.h }, pills };
    }
    const block = pillBlock(m, k, by.get(k) || [], wide ? 3 : KIT.pillsPerColumn);
    if (!block.items.length) return { w: n.w, h: n.h, side, note: { dx: 0, dy: 0, w: n.w, h: n.h }, pills: [] };
    const g0 = KIT.pillGap;
    let note, bx, by0, w, h;
    if (side === 'left') { w = block.w + g0 + n.w; h = Math.max(n.h, block.h); note = { dx: block.w + g0, dy: 0 }; bx = 0; by0 = 0; }
    else if (side === 'below') { w = Math.max(n.w, block.w); h = n.h + g0 + block.h; note = { dx: 0, dy: 0 }; bx = 0; by0 = n.h + g0; }
    else if (side === 'above') { w = Math.max(n.w, block.w); h = block.h + g0 + n.h; note = { dx: 0, dy: block.h + g0 }; bx = 0; by0 = 0; }
    else { w = n.w + g0 + block.w; h = Math.max(n.h, block.h); note = { dx: 0, dy: 0 }; bx = n.w + g0; by0 = 0; }
    return { w, h, side, note: Object.assign(note, { w: n.w, h: n.h }), pills: block.items.map((p) => Object.assign(p, { dx: bx + p.dx, dy: by0 + p.dy })) };
  };
  for (const u of g.units) {
    if (!g.isFrame(u)) { fps.set(u, Object.assign({ key: u, frame: false }, noteFp(u, sideOf(u)))); continue; }
    fps.set(u, frameFootprint(m, g, c, u, noteFp));
  }
  return fps;
}

function membersOf(m, frame) { const out = []; for (const k of m.kids(frame)) { if (m.node(k).isFrame) out.push(...membersOf(m, k)); else out.push(k); } return out; }

function frameFootprint(m, g, c, frame, noteFp) {
  // a frame's inside: rows by longest path down its own edges; each row's order the best of key order and barycenter sweeps (then adjacent
  // swaps), judged by laying the frame out alone and measuring it (crossings, arrows over notes and pills), so the inside is as clean as
  // the frame can be on its own
  const mem = membersOf(m, frame).sort(byKey);
  const S = new Set(mem), inn = new Map(mem.map((k) => [k, []])), nb = new Map(mem.map((k) => [k, []]));
  const own = g.inner.filter((e) => S.has(e.from) && S.has(e.to) && e.from !== e.to);
  for (const e of own) { inn.get(e.to).push(e.from); nb.get(e.from).push(e.to); nb.get(e.to).push(e.from); }
  const level = new Map();
  const lv = (k, seen) => { if (level.has(k)) return level.get(k); if (seen.has(k)) return 0; seen.add(k); let l = 0; for (const u of inn.get(k)) l = Math.max(l, lv(u, seen) + 1); level.set(k, l); return l; };
  for (const k of mem) lv(k, new Set());
  const rows0 = [];
  for (const k of mem) { const l = level.get(k); (rows0[l] = rows0[l] || []).push(k); }
  const rows = rows0.filter(Boolean);
  // a level's row wraps at about the width that gives the frame the window's shape, so a frame of many plugins isn't one long strip
  const fpOf = new Map(mem.map((k) => [k, noteFp(k)]));
  const area = mem.reduce((t, k) => t + (fpOf.get(k).w + KIT.frame.gapX) * (fpOf.get(k).h + KIT.frame.gapY), 0);
  const widest = Math.max(...mem.map((k) => fpOf.get(k).w));
  const wrapAt = Math.max(widest, Math.sqrt(area * 1.5));
  const wrap = (order, limit) => {
    if (!limit) return order;
    const out = [];
    for (const row of order) {
      let cur = [], w = 0;
      for (const k of row) { const fw = fpOf.get(k).w + KIT.frame.gapX; if (cur.length && w + fw > limit) { out.push(cur); cur = []; w = 0; } cur.push(k); w += fw; }
      if (cur.length) out.push(cur);
    }
    return out;
  };
  const build = (order0, roomy = 0, wrapped = true) => {
    const order = wrapped ? wrap(order0, wrapAt) : order0;
    const F = Object.assign({}, KIT.frame, roomy ? { gapX: KIT.frame.gapX + 60 * roomy, gapY: KIT.frame.gapY + 70 * roomy } : {}), members = {}, pills = [];
    let y = F.top, w = 0;
    for (const row of order) {
      let x = F.side, rh = 0;
      for (const k of row) {
        const fp = fpOf.get(k);
        members[k] = { dx: x + fp.note.dx, dy: y + fp.note.dy, w: fp.note.w, h: fp.note.h };
        for (const p of fp.pills) pills.push(Object.assign({}, p, { dx: x + p.dx, dy: y + p.dy }));
        x += fp.w + F.gapX; rh = Math.max(rh, fp.h);
      }
      w = Math.max(w, x - F.gapX + F.side);
      y += rh + F.gapY;
    }
    const h = y - F.gapY + F.bottom;
    for (const k in members) members[k].dy += TAB;
    for (const p of pills) p.dy += TAB;
    return { key: frame, frame: true, w: Math.max(w, 320), h: Math.max(h, 200) + TAB, tabRoom: TAB, members, pills };
  };
  const score = (fp) => {
    const lay = assemble(m, { units: [frame] }, { arrows: own }, new Map([[frame, fp]]), new Map([[frame, { x: 0, y: 0 }]]));
    const e = evaluate(m, g.board, lay);
    return (e.crossings + e.overNotes + e.overOtherPills) * 1e6 + e.meanLength;
  };
  const candidates = [rows.map((r) => r.slice())];
  // barycenter sweeps: a member's place, the mean index of its neighbors in the rows already ordered
  const bary = rows.map((r) => r.slice());
  const idx = () => { const at = new Map(); bary.forEach((r) => r.forEach((k, i) => at.set(k, i / Math.max(1, r.length - 1)))); return at; };
  for (let sweep = 0; sweep < 6; sweep++) {
    const order = sweep % 2 ? bary.map((_, i) => bary.length - 1 - i) : bary.map((_, i) => i);
    for (const ri of order) {
      const at = idx();
      const key = (k) => { const ns = nb.get(k).filter((x) => level.get(x) !== level.get(k)); return ns.length ? ns.reduce((s, x) => s + at.get(x), 0) / ns.length : at.get(k); };
      bary[ri].sort((a, b) => key(a) - key(b) || byKey(a, b));
    }
    candidates.push(bary.map((r) => r.slice()));
  }
  // more room between members only when the tight frame can't be clean (an arc needs room to clear a note)
  // the score adds the frame's distance from the window's shape, so a long strip loses to a wrapped frame as clean
  const shapeCost = (fp) => 400 * Math.abs(Math.log(fp.w / Math.max(1, fp.h) / 1.5));
  let best = null;
  for (const roomy of [0, 1, 2]) {
    if (best && best.s < 1e6) break;
    for (const cand of candidates) for (const wrapped of [true, false]) { const fp = build(cand, roomy, wrapped); const s = score(fp) + roomy + shapeCost(fp); if (!best || s < best.s) best = { s, cand, fp, roomy, wrapped }; }
    // adjacent swaps while they help
    for (let pass = 0; pass < 3 && best.s >= 1e6; pass++) {
      let gained = false;
      for (let ri = 0; ri < best.cand.length; ri++) for (let i = 0; i + 1 < best.cand[ri].length; i++) {
        const cand = best.cand.map((r) => r.slice());
        [cand[ri][i], cand[ri][i + 1]] = [cand[ri][i + 1], cand[ri][i]];
        const fp = build(cand, best.roomy, best.wrapped), s = score(fp) + best.roomy + shapeCost(fp);
        if (s < best.s) { best = { s, cand, fp, roomy: best.roomy, wrapped: best.wrapped }; gained = true; }
      }
      if (!gained) break;
    }
  }
  return best.fp;
}

/**
 * The harness's layout from where each unit's footprint goes (`at`: Map or object, unit key -> {x, y}). Arrows: every kept edge (a bend from
 * `opts.bends`, by edge index, else the first of KIT.bends that passes over no note, pill or frame it doesn't end at, when `opts.autoBend`
 * isn't false), and every pill's edges into it.
 */
export function assemble(m, g, c, fps, at, opts = {}) {
  const get = (k) => (at instanceof Map ? at.get(k) : at[k]);
  const boxes = {}, pills = [], arrows = [];
  const pillId = (p) => 'pill:' + p.user + '>' + p.for;
  for (const u of g.units) {
    const fp = fps.get(u), p = get(u);
    if (!p) throw new Error('no place for ' + u);
    if (!fp.frame) boxes[u] = { x: p.x + fp.note.dx, y: p.y + fp.note.dy, w: fp.note.w, h: fp.note.h };
    else {
      const t = fp.tabRoom || 0;   // the frame's box sits below the room its title tab takes
      boxes[u] = { x: p.x, y: p.y + t, w: fp.w, h: fp.h - t };
      for (const [k, b] of Object.entries(fp.members)) boxes[k] = { x: p.x + b.dx, y: p.y + b.dy, w: b.w, h: b.h };
    }
    for (const q of fp.pills) {
      const id = pillId(q);
      pills.push({ id, for: q.for, user: q.user, x: p.x + q.dx, y: p.y + q.dy, w: q.w, h: q.h });
      for (const e of q.edges) arrows.push({ from: e.from, to: id, edge: e.i, pill: true });
    }
  }
  // a pill's arrow: straight when that passes over nothing, else the least arc that does (its note's other pills are what it must clear)
  if (opts.pillBends !== false) {
    const byId = new Map(pills.map((q) => [q.id, q]));
    const near = Object.entries(boxes).filter(([k]) => !m.node(k).isFrame).map(([k, b]) => Object.assign({ key: k }, b)).concat(pills.map((q) => Object.assign({ key: q.id }, q)));
    for (const a of arrows) {
      if (!a.pill) continue;
      const A = boxes[a.from], B = byId.get(a.to);
      const ob = near.filter((o) => o.key !== a.from && o.key !== a.to && Math.abs(o.x + o.w / 2 - (A.x + A.w / 2)) < Math.abs(B.x - A.x) + B.w + A.w + 400 && Math.abs(o.y + o.h / 2 - (A.y + A.h / 2)) < Math.abs(B.y - A.y) + B.h + A.h + 400);
      a.bend = pillBend(A, B, ob);
    }
  }
  const bends = opts.bends || new Map();
  const obstacles = Object.entries(boxes).filter(([k]) => !m.node(k).isFrame).map(([k, b]) => Object.assign({ key: k }, b)).concat(pills.map((p) => Object.assign({ key: p.id }, p)));
  for (const e of c.arrows) {
    const given = bends instanceof Map ? bends.get(e.i) : bends[e.i];
    let bend = given == null ? 0 : given;
    if (given == null && opts.autoBend !== false) bend = clearBend(boxes[e.from], boxes[e.to], obstacles.filter((o) => o.key !== e.from && o.key !== e.to));
    arrows.push({ from: e.from, to: e.to, edge: e.i, bend });
  }
  return { boxes, pills, arrows };
}

const grow = (b, d) => ({ x: b.x - d, y: b.y - d, w: b.w + 2 * d, h: b.h + 2 * d });
function segHitsBox(p, q, b) {
  let t0 = 0, t1 = 1;
  const dx = q[0] - p[0], dy = q[1] - p[1];
  const clip = (pp, qq) => { if (pp === 0) return qq >= 0; const r = qq / pp; if (pp < 0) { if (r > t1) return false; if (r > t0) t0 = r; } else { if (r < t0) return false; if (r < t1) t1 = r; } return true; };
  return clip(-dx, p[0] - b.x) && clip(dx, b.x + b.w - p[0]) && clip(-dy, p[1] - b.y) && clip(dy, b.y + b.h - p[1]) && t1 - t0 > 1e-9;
}
export const pathHitsBox = (pts, b) => { for (let j = 1; j < pts.length; j++) if (segHitsBox(pts[j - 1], pts[j], b)) return true; return false; };

/** The least arc for a pill's arrow (shares of the chord up to 0.95, either side) that passes over none of `obstacles`; else the one over fewest. */
export function pillBend(A, B, obstacles) {
  const chord = Math.hypot(A.x + A.w / 2 - B.x - B.w / 2, A.y + A.h / 2 - B.y - B.h / 2);
  let best = null;
  for (const f of [0, 0.08, -0.08, 0.16, -0.16, 0.25, -0.25, 0.35, -0.35, 0.45, -0.45, 0.6, -0.6, 0.75, -0.75, 0.95, -0.95]) {
    const bend = Math.round(f * chord);
    const pts = arrowPoints(A, B, { bend }, 24);
    let hits = 0;
    for (const o of obstacles) if (pathHitsBox(pts, { x: o.x + 1, y: o.y + 1, w: o.w - 2, h: o.h - 2 })) hits++;
    if (!best || hits < best.hits) best = { bend, hits };
    if (!hits) break;
  }
  return best ? best.bend : 0;
}

/** The least bend (of KIT.bends, no more than 0.45 of the chord) whose arc passes over none of `obstacles`; else the one over fewest. */
export function clearBend(A, B, obstacles) {
  const chord = Math.hypot(A.x + A.w / 2 - B.x - B.w / 2, A.y + A.h / 2 - B.y - B.h / 2);
  let best = null;
  for (const bend of KIT.bends) {
    if (Math.abs(bend) > Math.max(40, 0.45 * chord)) continue;
    const pts = arrowPoints(A, B, { bend }, 24);
    let hits = 0;
    for (const o of obstacles) if (pathHitsBox(pts, grow(o, KIT.pad))) hits++;
    if (!best || hits < best.hits) best = { bend, hits };
    if (!hits) break;
  }
  return best ? best.bend : 0;
}

/**
 * harness.measure, with arrows over pills told apart: `overOwnPills`, a note's arrow into one of its own pills passing over another of its
 * pills (its block's short lines: a matter of how a block is arranged), and `overOtherPills`, any other arrow over a pill. Plus `aspect`
 * (width over height) and `clean`: no crossing, no arrow over a note, no arrow over another unit's pill.
 */
export function evaluate(m, board, layout) {
  const r = measure(m, board, layout);
  const boxOf = (id) => layout.boxes[id] || layout.pills.find((p) => p.id === id);
  let own = 0, other = 0;
  for (const a of layout.arrows) {
    const A = boxOf(a.from), B = boxOf(a.to);
    if (!A || !B) continue;
    const pts = arrowPoints(A, B, a, 16);
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
    for (const p of layout.pills) {
      if (p.id === a.to || p.id === a.from || p.x > x1 || p.x + p.w < x0 || p.y > y1 || p.y + p.h < y0) continue;
      if (!pathHitsBox(pts, { x: p.x + 1, y: p.y + 1, w: p.w - 2, h: p.h - 2 })) continue;
      if (a.pill && p.user === a.from) own++; else other++;
    }
  }
  return Object.assign(r, { overOwnPills: own, overOtherPills: other, aspect: Math.round(100 * r.size[0] / Math.max(1, r.size[1])) / 100,
    clean: r.crossings === 0 && r.overNotes === 0 && other === 0 });
}

export { isPlanar, edgeCuts, hubCuts, arrowPoints };
