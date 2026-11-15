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
import { isPlanar, edgeCuts, hubCuts } from '../planar/planar.mjs';

export const TAB = 28;   // the room a note's or a frame's title tab takes above it (canvas measure's `above` is 27)

export const KIT = {
  pillGap: 16,        // between a note and its block of pills
  pillStep: 8,        // between pills in a column, and between columns
  pillsPerColumn: 8,  // a block wraps into another column past this many
  stripMost: 8,       // a column strip's most pills (about twice a note's height); past it the pills go on further sides, then further columns
  rowMost: 6,         // a row strip's most
  pillBendMost: 120,  // a pill's line bends at most this much, and at most pillBendShare of its chord: never a loop around a strip
  pillBendShare: 0.25,
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
 * A note's pills in strips beside it, each centered on the note: one strip on the side asked for while it holds no more than KIT.stripMost
 * (a column) or KIT.rowMost (a row); past that the pills are shared between that side and the opposite one (a column each side: right
 * and left; rows above and below past 2 rows' worth are columns instead), the first half (in-board ones first) on the side asked for.
 * A strip on each side keeps every line short: a line from the note's center to a pill on one side never passes over the other side's.
 * Returns the footprint { w, h, side, note: {dx, dy, w, h}, pills } with the room for the note's title tab above it kept clear.
 */
function stripsVariant(n, sized, side, variant, rowMost0) {
  const g0 = KIT.pillGap, step = KIT.pillStep, N = sized.length;
  const out = [];
  const colAt = (ps, s, cy) => {   // a column centered at height cy on side s
    const bh = ps.reduce((t, p) => t + p.h, 0) + step * (ps.length - 1);
    let y = cy - bh / 2;
    for (const p of ps) { out.push(Object.assign(p, { dx: s === 'right' ? n.w + g0 : -g0 - p.w, dy: y })); y += p.h + step; }
    return { top: cy - bh / 2, bottom: cy + bh / 2 };
  };
  const rowAt = (ps, s, edge, cx, lo, hi) => {   // a row below `edge` (or above it) centered at cx, kept within [lo, hi]
    const bh = Math.max(...ps.map((p) => p.h)), bw = ps.reduce((t, p) => t + p.w, 0) + step * (ps.length - 1);
    let x = cx - bw / 2;
    if (hi != null && x + bw > hi) x = hi - bw;
    if (lo != null && x < lo) x = lo;
    const y = s === 'below' ? edge + g0 : edge - g0 - bh;
    for (const p of ps) { out.push(Object.assign(p, { dx: x, dy: y })); x += p.w + step; }
  };
  const wide = side === 'below' || side === 'above';
  const scale = Math.max(1, N / (KIT.stripMost + 2 * (rowMost0 || KIT.rowMost)));
  const colMost = Math.ceil(KIT.stripMost * scale), rowMost = Math.ceil((rowMost0 || KIT.rowMost) * scale);
  if (variant === 'one' && wide) {
    rowAt(sized, side, side === 'below' ? n.h : -(TAB + 8 - g0), n.w / 2);
  } else if (variant === 'one') {
    colAt(sized, side, n.h / 2);
  } else if (variant === 'two') {
    const h1 = sized.slice(0, Math.ceil(N / 2));
    colAt(h1, side, n.h / 2); colAt(sized.slice(h1.length), side === 'right' ? 'left' : 'right', n.h / 2);
  } else if (variant === 'grid') {
    // short strips on every side: rows below and above (rowMost0 pills a side), each row no wider than the columns' outer edges so its lines
    // come out steep and pass over no column, stacked outward when that is too narrow for them; the rest in columns of at most
    // KIT.stripMost on the column side asked for and the other, further columns outward past that (their lines short and straight over the
    // inner column's pills, never an arc around it)
    const R = Math.min(rowMost0 || KIT.rowMost, Math.ceil(N / 4)), cm = KIT.stripMost;
    const rb = sized.slice(0, R), ra = sized.slice(rb.length, rb.length + R), rest = sized.slice(rb.length + ra.length);
    const colSide = wide ? 'right' : side, other = colSide === 'right' ? 'left' : 'right';
    const cols = Math.ceil(rest.length / cm), mine = Math.ceil(cols / 2);
    const perCol = cols ? Math.ceil(rest.length / cols) : 0;
    const span = { top: 0, bottom: n.h };
    let k = 0;
    const off = { right: 0, left: 0 };
    for (let c = 0; c < cols; c++) {
      const s2 = c < mine ? colSide : other;
      const ps = rest.slice(k, k + perCol); k += ps.length;
      if (!ps.length) continue;
      const before = out.length;
      const a = colAt(ps, s2, n.h / 2);
      const w = Math.max(...ps.map((p) => p.w));
      for (const p of out.slice(before)) p.dx += s2 === 'right' ? off[s2] : -off[s2];
      off[s2] += w + step;
      span.top = Math.min(span.top, a.top); span.bottom = Math.max(span.bottom, a.bottom);
    }
    const lo = off.left ? -g0 - off.left + step : -g0, hi = off.right ? n.w + g0 + off.right - step : n.w + g0;
    const first = wide ? side : 'below', second = first === 'below' ? 'above' : 'below';
    const stack = (ps, s3) => {
      let edge = s3 === 'below' ? span.bottom : Math.min(span.top, -(TAB + 8 - g0));
      let i = 0;
      while (i < ps.length) {
        let w = 0, j = i;
        while (j < ps.length && (j === i || w + step + ps[j].w <= Math.max(hi - lo, ps[i].w))) { w += (j > i ? step : 0) + ps[j].w; j++; }
        const row = ps.slice(i, j);
        rowAt(row, s3, edge, n.w / 2, lo, hi);
        const h = Math.max(...row.map((p) => p.h));
        edge = s3 === 'below' ? edge + g0 + h : edge - g0 - h;
        i = j;
      }
    };
    stack(rb, first); stack(ra, second);
  } else if (variant === 'ring' || (variant === 'rows' && wide)) {
    // rows above and below, the first on the side asked for; past two rows' worth, columns at both ends
    const r1 = sized.slice(0, Math.min(rowMost, Math.ceil(N / 2))), r2 = sized.slice(r1.length, r1.length + rowMost), rest = sized.slice(r1.length + r2.length);
    const c1 = rest.slice(0, Math.ceil(rest.length / 2)), c2 = rest.slice(c1.length);
    const span = { top: 0, bottom: n.h };
    if (c1.length) { const a = colAt(c1, 'right', n.h / 2); span.top = Math.min(span.top, a.top); span.bottom = Math.max(span.bottom, a.bottom); }
    if (c2.length) { const a = colAt(c2, 'left', n.h / 2); span.top = Math.min(span.top, a.top); span.bottom = Math.max(span.bottom, a.bottom); }
    const lo = c2.length ? -g0 : null, hi = c1.length ? n.w + g0 : null;
    const other = side === 'below' ? 'above' : 'below';
    const put = (ps, s) => { if (ps.length) rowAt(ps, s, s === 'below' ? span.bottom : Math.min(span.top, -(TAB + 8 - g0)), n.w / 2, lo != null ? lo - 0 : null, hi); };
    put(r1, side); put(r2, other);
  } else {
    // a column on the side asked for, then rows below and above the column's ends (kept off the column's side, so no line to a row passes
    // over the column), then a column on the other side
    const c1 = sized.slice(0, colMost);
    let rest = sized.slice(c1.length);
    const rb = rest.slice(0, Math.min(rowMost, Math.ceil(rest.length / 2))); rest = rest.slice(rb.length);
    const ra = rest.slice(0, rowMost); rest = rest.slice(ra.length);
    const c2 = rest;
    const other = side === 'right' ? 'left' : 'right';
    const a = colAt(c1, side, n.h / 2);
    let top = Math.min(a.top, 0), bottom = Math.max(a.bottom, n.h);
    if (c2.length) { const b = colAt(c2, other, n.h / 2); top = Math.min(top, b.top); bottom = Math.max(bottom, b.bottom); }
    const lo = side === 'left' ? -g0 + 0 : (c2.length ? -g0 : null), hi = side === 'right' ? n.w + g0 : (c2.length ? n.w + g0 : null);
    // a row clear of a column on its side: it ends where that column starts
    const cx = n.w / 2;
    if (rb.length) rowAt(rb, 'below', bottom, cx, side === 'left' || c2.length ? 0 - g0 + 0 : null, side === 'right' || c2.length ? n.w + g0 : null);
    if (ra.length) rowAt(ra, 'above', Math.min(top, -(TAB + 8 - g0)), cx, side === 'left' || c2.length ? 0 - g0 : null, side === 'right' || c2.length ? n.w + g0 : null);
    void lo; void hi;
  }
  const x0 = Math.min(0, ...out.map((p) => p.dx)), y0 = Math.min(0, ...out.map((p) => p.dy));
  const x1 = Math.max(n.w, ...out.map((p) => p.dx + p.w)), y1 = Math.max(n.h, ...out.map((p) => p.dy + p.h));
  for (const p of out) { p.dx -= x0; p.dy -= y0; }
  return { w: x1 - x0, h: y1 - y0, side, note: { dx: -x0, dy: -y0, w: n.w, h: n.h }, pills: out };
}


/** How many of a footprint's own pills its lines pass over, each line given its least clear arc (as assemble bends it). */
function ownHits(fp) {
  const A = { x: fp.note.dx, y: fp.note.dy, w: fp.note.w, h: fp.note.h };
  const ps = fp.pills.map((p) => ({ x: p.dx, y: p.dy, w: p.w, h: p.h }));
  let hits = 0;
  for (const B of ps) {
    const others = ps.filter((q) => q !== B).map((q) => Object.assign({ user: 0 }, q));
    const bend = pillBend(A, B, others, 0);
    const pts = arrowPoints(A, B, { bend }, 16);
    for (const o of others) if (pathHitsBox(pts, { x: o.x + 1, y: o.y + 1, w: o.w - 2, h: o.h - 2 })) hits++;
  }
  return hits;
}
const stripMemo = new Map();
/** A footprint's longest strip: the most pills in one column (same left or right edge, touching in turn) or one row (same top). */
function strip(fp) {
  const c = new Map();
  for (const p of fp.pills) for (const k of ['L' + Math.round(p.dx), 'R' + Math.round(p.dx + p.w), 'T' + Math.round(p.dy)]) c.set(k, (c.get(k) || 0) + 1);
  return Math.max(0, ...c.values());
}
/**
 * A note's pills in strips around it. Up to KIT.stripMost (a column) or KIT.rowMost (a row), one strip centered on the side asked for, as
 * before. Past that, the better of two arrangements, each no strip longer than about the cap: a column on each side ('two'), or the
 * column on the side asked for with rows of a few above and below it, kept off the column's side ('rows'); judged by the lines that pass
 * over the note's own pills, then by area. Memoized by the note, the side and its pills.
 */
function stripsAround(n, sized, side) {
  const wide = side === 'below' || side === 'above';
  if (sized.length <= (wide ? KIT.rowMost : KIT.stripMost)) return stripsVariant(n, sized.map((p) => Object.assign({}, p)), side, 'one');
  const key = n.key + SEP + side + SEP + sized.map((p) => p.for).join(SEP);
  if (!stripMemo.has(key)) {
    let best = null;
    const opts = (wide ? [['rows', 0, side], ['rows', 4, side], ['two', 0, 'right']] : [['two', 0, side], ['rows', 4, side], ['rows', 6, side], ['ring', 4, 'below'], ['ring', 6, 'below']])
      .concat([['grid', 2, side], ['grid', 3, side], ['grid', 4, side], ['grid', 6, side], ['grid', 8, side]]);
    for (const [variant, rm, sd] of opts) {
      const fp = stripsVariant(n, sized.map((p) => Object.assign({}, p)), sd, variant, rm);
      fp.side = side;
      // a line over an own pill weighs most; then each pill a strip runs past the cap (a long strip is what reads worst); then area
      // (200,000 square units, about a pill's line)
      // a strip past the cap is out while any arrangement keeps every strip within it (the grid always does)
      const s = (strip(fp) > KIT.stripMost ? 1e6 : 0) + 3 * ownHits(fp) + 4 * Math.max(0, strip(fp) - KIT.stripMost) + fp.w * fp.h / 200000;
      if (!best || s < best.s - 1e-9) best = { s, variant, rm, sd };
    }
    stripMemo.set(key, best || { variant: 'two', rm: 0, sd: wide ? 'right' : side });
  }
  const b = stripMemo.get(key);
  return Object.assign(stripsVariant(n, sized.map((p) => Object.assign({}, p)), b.sd, b.variant, b.rm), { side });
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
      const items = by.get(k) || [];
      if (!items.length) return { w: n.w, h: n.h, side, note: { dx: 0, dy: 0, w: n.w, h: n.h }, pills: [] };
      const sized = items.map((p) => { const [pw, ph] = m.pillSize(p.for, k); return Object.assign({}, p, { w: pw, h: ph }); });
      return stripsAround(n, sized, side);
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

const frameMemo = new Map();
function frameFootprint(m, g, c, frame, noteFp) {
  // a frame's inside depends only on its members' pills: laid out once for each set of them
  const S0 = new Set(membersOf(m, frame));
  const key = g.board + SEP + frame + SEP + c.pills.filter((p) => S0.has(p.user)).map((p) => p.user + '>' + p.for).sort().join(SEP);
  if (!frameMemo.has(key)) frameMemo.set(key, frameFootprint0(m, g, c, frame, noteFp));
  return JSON.parse(JSON.stringify(frameMemo.get(key)));
}
function frameFootprint0(m, g, c, frame, noteFp) {
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
  // a frame with a hub (a member most of the others use): the hub in the middle, the rest on a ring around it, each one's pills on its
  // outer side, so every spoke runs across the empty middle; kept when it scores better (as clean, nearer the window's shape, shorter)
  const deg = new Map(mem.map((k) => [k, new Set(nb.get(k)).size]));
  const hub = mem.slice().sort((a, b) => deg.get(b) - deg.get(a) || byKey(a, b))[0];
  if (mem.length >= 6 && deg.get(hub) >= 5 && deg.get(hub) >= 0.5 * (mem.length - 1)) {
    for (const cand of starCandidates(m, g, frame, mem, hub, nb, noteFp)) {
      const sc = score(cand) + shapeCost(cand);
      if (sc < best.s) best = { s: sc, fp: cand };
    }
  }
  return best.fp;
}

/** Ring orders and spreads for a frame laid out as a star around `hub` (see frameFootprint). */
function starCandidates(m, g, frame, mem, hub, nb, noteFp) {
  const others = mem.filter((k) => k !== hub);
  const hubN = new Set(nb.get(hub));
  // ring order: a walk that keeps members joined by an edge next to each other (members the hub doesn't use next to one that does)
  const orders = [];
  const walk = (start) => {
    const seen = new Set(), out = [];
    const visit = (k) => { if (seen.has(k)) return; seen.add(k); out.push(k); for (const x of nb.get(k).slice().sort(byKey)) if (x !== hub) visit(x); };
    for (const k of start) visit(k);
    for (const k of others) visit(k);   // every member, also one no walk from the start reaches (else it would be left out of the frame)
    return out;
  };
  orders.push(others.slice());
  orders.push(walk(others.filter((k) => hubN.has(k))));
  orders.push(walk(others.slice().sort((a, b) => nb.get(a).length - nb.get(b).length || byKey(a, b))));
  const F = KIT.frame;
  const out = [];
  for (const order of orders) for (const spread of [1, 1.5, 2.2]) for (const hubSide of ['below', 'right']) {
    const n = order.length;
    // sides of the ring: top and bottom rows take about 3/4 of the members (the frame landscape), the left and right columns the rest
    const sideN = Math.max(0, Math.round(n * 0.12)), topN = Math.ceil((n - 2 * sideN) / 2), botN = n - 2 * sideN - topN;
    const top = order.slice(0, topN), right = order.slice(topN, topN + sideN), bottom = order.slice(topN + sideN, topN + sideN + botN).reverse(), left = order.slice(topN + sideN + botN).reverse();
    const fp = (k, side) => noteFp(k, side);
    const T = top.map((k) => fp(k, 'above')), R = right.map((k) => fp(k, 'right')), Bm = bottom.map((k) => fp(k, 'below')), L = left.map((k) => fp(k, 'left'));
    const H = fp(hub, hubSide);
    const gx = F.gapX * spread, gy = F.gapY * spread;
    const rowW = (fs) => fs.reduce((t, f) => t + f.w, 0) + gx * Math.max(0, fs.length - 1);
    const colH = (fs) => fs.reduce((t, f) => t + f.h, 0) + gy * Math.max(0, fs.length - 1);
    const topH = Math.max(0, ...T.map((f) => f.h)), botH = Math.max(0, ...Bm.map((f) => f.h));
    const leftW = Math.max(0, ...L.map((f) => f.w)), rightW = Math.max(0, ...R.map((f) => f.w));
    // the middle: room for the hub and its spokes, at least the side columns' height
    const midH = Math.max(colH(R), colH(L), H.h + 2 * gy);
    const innerW = Math.max(rowW(T), rowW(Bm), leftW + rightW + H.w + 4 * gx);
    const W = F.side * 2 + innerW;
    const members = {}, pills = [];
    const put = (k, f, x, y) => {
      members[k] = { dx: x + f.note.dx, dy: y + f.note.dy, w: f.note.w, h: f.note.h };
      for (const p of f.pills) pills.push(Object.assign({}, p, { dx: x + p.dx, dy: y + p.dy }));
    };
    let y = F.top;
    let x = F.side + (innerW - rowW(T)) / 2;
    T.forEach((f, i) => { put(top[i], f, x, y + topH - f.h); x += f.w + gx; });
    y += topH + gy;
    const midTop = y;
    let yy = midTop + (midH - colH(L)) / 2;
    L.forEach((f, i) => { put(left[i], f, F.side, yy); yy += f.h + gy; });
    yy = midTop + (midH - colH(R)) / 2;
    R.forEach((f, i) => { put(right[i], f, F.side + innerW - f.w, yy); yy += f.h + gy; });
    put(hub, H, F.side + (innerW - H.w) / 2, midTop + (midH - H.h) / 2);
    y = midTop + midH + gy;
    x = F.side + (innerW - rowW(Bm)) / 2;
    Bm.forEach((f, i) => { put(bottom[i], f, x, y); x += f.w + gx; });
    y += botH;
    const h = y + F.bottom;
    for (const k in members) members[k].dy += TAB;
    for (const p of pills) p.dy += TAB;
    out.push({ key: frame, frame: true, w: Math.max(W, 320), h: Math.max(h, 200) + TAB, tabRoom: TAB, members, pills });
  }
  return out;
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
      a.bend = pillBend(A, B, ob, a.from);
    }
  }
  const bends = opts.bends || new Map();
  const obstacles = Object.entries(boxes).filter(([k]) => !m.node(k).isFrame).map(([k, b]) => Object.assign({ key: k }, b)).concat(pills.map((p) => Object.assign({ key: p.id }, p)));
  for (const e of c.arrows) {
    const given = bends instanceof Map ? bends.get(e.i) : bends[e.i];
    let bend = given == null ? 0 : given;
    if (!boxes[e.from] || !boxes[e.to]) throw new Error('no box for ' + (boxes[e.from] ? e.to : e.from) + ' (edge ' + e.from + ' -> ' + e.to + ')');
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

// the arcs a pill's arrow tries, least first: every 0.04 of the chord up to 1.1, either side
const PILL_BENDS_COARSE = [0, 0.08, -0.08, 0.16, -0.16, 0.25, -0.25, 0.35, -0.35, 0.45, -0.45, 0.6, -0.6, 0.75, -0.75, 0.95, -0.95];
const PILL_BENDS = []; for (let f = 0.04; f <= 1.1 + 1e-9; f += 0.04) if (!PILL_BENDS_COARSE.includes(+f.toFixed(2))) PILL_BENDS.push(+f.toFixed(2), -f.toFixed(2));
/**
 * The least arc for a pill's arrow that passes over none of `obstacles`, bent at most a little (KIT.pillBendShare of its chord and
 * KIT.pillBendMost): a pill's line never loops around a strip, a note or a frame. When no such arc is clear, the one over none but the
 * note's own pills (an obstacle whose `user` is `own`) and fewest of them, least bent first: a short line over its own pill reads far
 * better than a giant arc. Only when even that can't be had (something else is in the way of every slight arc) are the larger arcs tried,
 * so the board stays clean.
 */
export function pillBend(A, B, obstacles, own) {
  const chord = Math.hypot(A.x + A.w / 2 - B.x - B.w / 2, A.y + A.h / 2 - B.y - B.h / 2);
  const most = Math.min(KIT.pillBendMost, KIT.pillBendShare * chord);
  const isOwn = (o) => own != null && o.user === own;
  const judge = (bend) => {
    // judged on the paths the measures draw (16 and 40 samples), so an arc found clear is clear when measured
    const p16 = arrowPoints(A, B, { bend }, 16), p40 = arrowPoints(A, B, { bend }, 40);
    let foreign = 0, mine = 0;
    for (const o of obstacles) { const b = { x: o.x, y: o.y, w: o.w, h: o.h }; if (pathHitsBox(p16, b) || pathHitsBox(p40, b)) { if (isOwn(o)) mine++; else foreign++; } }
    return { bend, foreign, mine };
  };
  const slight = [0];
  for (let f = 0.02; f <= KIT.pillBendShare + 1e-9; f += 0.02) { const b = Math.round(f * chord); if (b > most) break; slight.push(b, -b); }
  let best = null;
  for (const bend of slight) {
    const r = judge(bend);
    if (!r.foreign && !r.mine) return bend;
    if (!r.foreign && (!best || r.mine < best.mine)) best = r;
  }
  if (best) return best.bend;
  let any = null;
  for (const f of PILL_BENDS_COARSE.concat(PILL_BENDS)) {   // the coarse list first; the finer arcs only when none of it is clear
    const r = judge(Math.round(f * chord));
    const score = r.foreign * 1000 + r.mine;
    if (!any || score < any.score) any = Object.assign(r, { score });
    if (!r.foreign) break;
  }
  return any ? any.bend : 0;
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
