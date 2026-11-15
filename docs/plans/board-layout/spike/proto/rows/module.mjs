// ROWS: rows by dependency level, users above what they use, made crossing-free.
// Cut: the kit's 'hubs'. Units (loose notes, each frame one unit) of the arrows' graph are split into connected components; each is
// layered (cycles broken by a greedy feedback arc set, longest path, then each unit slid to the level its neighbors want), long arrows
// get placeholder lanes, rows ordered by barycenter sweeps and adjacent swaps, x by isotonic pulls toward neighbors. Units with no arrow
// at all are packed as a tidy grid. Components are shelf-packed toward the window's shape. Whatever still crosses, or passes over a note
// or another unit's pill after the kit's arc bends, is cut into a pill (for the more used end) and the board laid out again.
import { boardGraph, cut, footprints, assemble, arrowPoints, pathHitsBox, KIT } from '../planar/kit.mjs';

export const ROWS = { gapX: 64, gapY: 150, dummyW: 28, compGap: 60, aspect: 1.48, rounds: 150, cutShare: 1000, frameGapY: 80, starts: 8, wrap: 1.1, lookahead: 4, sparse: 14, above: false, longBend: 0.5 };
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

const SPACINGS = [{}, { gapY: 90, gapX: 40 }, { gapY: 110, gapX: 48 }, { gapY: 200, dummyW: 50 }, { gapY: 260, dummyW: 90 }, { gapY: 150, gapX: 48, dummyW: 60 }];
export const VARIANTS = SPACINGS.concat(SPACINGS.map((v) => Object.assign({ wrap: 0 }, v)), SPACINGS.map((v) => Object.assign({ wrap: 0.85 }, v)),
  [{ gapY: 70, gapX: 32, dummyW: 20 }, { gapY: 70, gapX: 32, dummyW: 20, wrap: 0 }, { gapY: 70, gapX: 32, dummyW: 20, wrap: 0.85 }, { gapY: 50, gapX: 24, dummyW: 14 }, { gapY: 50, gapX: 24, dummyW: 14, wrap: 0.85 }]);

export async function layoutBoard(m, board, opts = {}) {
  const g = boardGraph(m, board);
  const base = cut(m, g, 'hubs');
  let best = null;
  for (const v of (opts.variants || VARIANTS)) {
    const P = Object.assign({}, ROWS, v, opts);
    const r = attempt(m, g, base, P);
    const dev = Math.abs(Math.log(r.aspect / P.aspect));
    const s = [r.score, r.extra + 4 * dev + P.sparse * Math.log(r.spread) + P.longBend * longBends(r.layout) + (P.lenW ? P.lenW * Math.log(meanLen(r.layout)) : 0)];
    if (!best || s[0] < best.s[0] || (s[0] === best.s[0] && s[1] < best.s[1] - 1e-9)) best = Object.assign(r, { s, v });
  }
  const c = best.c;
  return { layout: best.layout, info: { referenced: c.referenced.map((k) => m.node(k).title), cut: c.cutEdges.length, cutAfter: best.extra, conflicts: best.score, variant: best.v } };
}

function attempt(m, g, base, P) {
  // one layout for a set of cut edges, starting from what earlier rounds laid out (memo: components, levels and orders, kept as edges are cut)
  const run = (extra, memo) => {
    const c = withCuts(base, extra);
    const Q = Object.assign({}, P, { memo });
    const sides = endSides(g, c, P.above);
    let f = rowFootprints(m, g, c, sides, Q);
    let at = place(m, g, c, f, Q);
    // pill side: a middle note whose arrows mostly leave to the right puts its block on the left
    if (chooseSides(m, g, c, f, at, sides)) { f = rowFootprints(m, g, c, sides, Q); at = place(m, g, c, f, Q); }
    const layout = assembleFast(m, g, c, f, at);
    fixBends(m, layout, P);
    return { layout, c, bad: conflicts(m, layout), memo, extra };
  };
  let cur = run(new Set(), new Map());
  let best = null;
  for (let round = 0; round <= P.rounds; round++) {
    if (!best || cur.bad.total < best.score) best = { score: cur.bad.total, layout: cur.layout, c: cur.c, extra: cur.extra.size, aspect: aspectOf(cur.layout), spread: spreadOf(cur.layout) };
    if (!cur.bad.total) break;
    const ranked = [...cur.bad.per.entries()].filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1] || a[0] - b[0]);
    if (!ranked.length) break;
    // look ahead: of the few most conflicted arrows, cut the one that leaves the fewest conflicts
    let next = null;
    for (const [ei] of ranked.slice(0, P.lookahead)) {
      const t = run(new Set([...cur.extra, ei]), new Map(cur.memo));
      if (!next || t.bad.total < next.bad.total) next = t;
    }
    cur = next;
  }
  return best;
}

/** Mean straight length of the arrows between notes. */
function meanLen(layout) { const b = layout.boxes, ar = layout.arrows.filter((a) => !a.pill && b[a.from] && b[a.to]); if (!ar.length) return 1; return Math.max(1, ar.reduce((t, a) => t + Math.hypot(b[a.from].x + b[a.from].w / 2 - b[a.to].x - b[a.to].w / 2, b[a.from].y + b[a.from].h / 2 - b[a.to].y - b[a.to].h / 2), 0) / ar.length); }

/** Arcs bent far (|bend| over 260): the long swoops. */
function longBends(layout) { return layout.arrows.filter((a) => !a.pill && Math.abs(a.bend || 0) > 260).length; }

/** The board's area over what its notes and pills cover: 1 is packed solid. */
function spreadOf(layout) {
  const all = Object.values(layout.boxes).concat(layout.pills);
  const x0 = Math.min(...all.map((b) => b.x)), y0 = Math.min(...all.map((b) => b.y)), x1 = Math.max(...all.map((b) => b.x + b.w)), y1 = Math.max(...all.map((b) => b.y + b.h));
  const used = layout.pills.reduce((t, p) => t + p.w * p.h, 0) + Object.entries(layout.boxes).reduce((t, [, b]) => t + b.w * b.h, 0);
  return (x1 - x0) * (y1 - y0) / Math.max(1, used);
}
function aspectOf(layout) {
  const all = Object.values(layout.boxes).concat(layout.pills);
  const x0 = Math.min(...all.map((b) => b.x)), y0 = Math.min(...all.map((b) => b.y)), x1 = Math.max(...all.map((b) => b.x + b.w)), y1 = Math.max(...all.map((b) => b.y + b.h));
  return (x1 - x0) / Math.max(1, y1 - y0);
}

/** A loose note that uses nothing on the board keeps its pills below it, one nothing uses above it: out of every arrow's way. */
function endSides(g, c, above = true) {
  const ins = new Set(), outs = new Set();
  for (const e of c.arrows) { const a = g.unitOf(e.from), b = g.unitOf(e.to); if (a === b) continue; outs.add(a); ins.add(b); }
  const sides = new Map();
  for (const u of g.units) {
    if (g.isFrame(u)) continue;
    if (!outs.has(u) && ins.has(u)) sides.set(u, 'below');
    else if (above && outs.has(u) && !ins.has(u)) sides.set(u, 'above');
  }
  return sides;
}

function withCuts(base, extra) {
  if (!extra.size) return base;
  const arrows = [], pills = base.pills.slice();
  for (const e of base.arrows) { if (extra.has(e.i)) pills.push({ edge: e, user: e.from, for: e.to }); else arrows.push(e); }
  return Object.assign({}, base, { arrows, pills, extraCut: extra.size });
}

/** Where each unit's footprint goes: Map unit -> {x, y}. */
function place(m, g, c, f, P) {
  const ue = new Map(); // "a\0b" -> weight, a uses b
  for (const e of c.arrows) {
    const a = g.unitOf(e.from), b = g.unitOf(e.to);
    if (a === b) continue;
    const k = a + '\u0000' + b; ue.set(k, (ue.get(k) || 0) + 1);
  }
  return placeUnits(g.units, ue, f, P, 'board').pos;
}

/** Units (with footprints f) and their arrows (Map "a\0b" -> weight) in rows: { pos: Map unit -> {x, y}, w, h }. */
function placeUnits(units, ue, f, P, scope) {
  const edges = [...ue.entries()].map(([k, w]) => { const [a, b] = k.split('\u0000'); return { a, b, w }; }).sort((x, y) => byKey(x.a, y.a) || byKey(x.b, y.b));
  const nb = new Map(units.map((u) => [u, new Set()]));
  for (const e of edges) { nb.get(e.a).add(e.b); nb.get(e.b).add(e.a); }
  const memo = P.memo, ck = 'C:' + scope;
  let comps = memo && memo.get(ck);
  if (!comps) { comps = components(units, nb); if (memo) memo.set(ck, comps); }
  const blocks = [], lonely = [];
  for (const list of comps) {
    if (list.length === 1) { lonely.push(list[0]); continue; }
    const S = new Set(list);
    blocks.push(layered(list, edges.filter((e) => S.has(e.a) && S.has(e.b)), f, P, 'L:' + scope + ':' + list[0]));
  }
  if (lonely.length) blocks.push(gridBlock(lonely, f, P));
  return pack(blocks, P);
}

function components(units, nb) {
  const comp = new Map(), comps = [];
  for (const u of units) {
    if (comp.has(u)) continue;
    const list = [], st = [u]; comp.set(u, comps.length);
    while (st.length) { const x = st.pop(); list.push(x); for (const y of [...nb.get(x)].sort(byKey)) if (!comp.has(y)) { comp.set(y, comps.length); st.push(y); } }
    comps.push(list.sort(byKey));
  }
  return comps;
}

/** Footprints, each frame's inside laid out in rows by this direction (members' own arrows), not by the kit. */
function rowFootprints(m, g, c, sides, P) {
  // every note's footprint in one call of the kit's, with no frame in it (the kit's own frame layout is not used)
  const notes = g.units.filter((u) => !g.isFrame(u));
  const memOf = new Map(g.units.filter((u) => g.isFrame(u)).map((u) => [u, membersOf(m, u).sort(byKey)]));
  const all = notes.concat(...memOf.values());
  const fm = footprints(m, { units: all, isFrame: () => false }, c, sides);
  const f = new Map(notes.map((u) => [u, fm.get(u)]));
  for (const u of g.units) {
    if (!g.isFrame(u)) continue;
    const mem = memOf.get(u);
    const S = new Set(mem), ue = new Map();
    for (const e of c.arrows) if (S.has(e.from) && S.has(e.to) && e.from !== e.to) { const k = e.from + '\u0000' + e.to; ue.set(k, (ue.get(k) || 0) + 1); }
    const Q = Object.assign({}, P, { gapY: P.frameGapY, compGap: P.gapX * 1.5 });
    const r = placeUnits(mem, ue, fm, Q, u);
    const F = { top: 84, side: 48, bottom: 48 };
    const members = {}, pills = [];
    for (const k of mem) {
      const p = r.pos.get(k), fp = fm.get(k);
      members[k] = { dx: F.side + p.x + fp.note.dx, dy: F.top + p.y + fp.note.dy, w: fp.note.w, h: fp.note.h };
      for (const q of fp.pills) pills.push(Object.assign({}, q, { dx: F.side + p.x + q.dx, dy: F.top + p.y + q.dy }));
    }
    f.set(u, { key: u, frame: true, w: Math.max(320, r.w + 2 * F.side), h: Math.max(200, r.h + F.top + F.bottom), members, pills });
  }
  return f;
}
function membersOf(m, frame) { const out = []; for (const k of m.kids(frame)) { if (m.node(k).isFrame) out.push(...membersOf(m, k)); else out.push(k); } return out; }

/** A grid of units, in key order, as wide as makes it about the window's shape. */
function gridBlock(list, f, P, k = 1) {
  const area = list.reduce((t, u) => t + (f.get(u).w + P.gapX) * (f.get(u).h + P.gapX), 0);
  const width = Math.max(...list.map((u) => f.get(u).w), Math.sqrt(area * P.aspect) * k);
  const pos = new Map();
  let x = 0, y = 0, rh = 0, w = 0;
  for (const u of list) { const fp = f.get(u); if (x > 0 && x + fp.w > width) { x = 0; y += rh + P.gapX; rh = 0; } pos.set(u, { x, y }); x += fp.w + P.gapX; w = Math.max(w, x - P.gapX); rh = Math.max(rh, fp.h); }
  return { pos, w, h: y + rh, lonely: true, regrid: (k2) => gridBlock(list, f, P, k2) };
}

/** Shelf-pack blocks, biggest first, the shelf width chosen for the window's shape. */
function pack(blocks0, P) {
  // the loose notes' grid may take other widths; blocks go in shelves (rows) or in columns, whichever is nearest the window's shape and smallest
  const G = P.compGap;
  const gi = blocks0.findIndex((b) => b.lonely);
  const grids = gi < 0 ? [null] : [1, 0.75, 0.5, 0.35, 0.25, 0.15].map((k) => blocks0[gi].regrid(k));
  let best = null;
  for (const grid of grids) {
    const blocks = blocks0.map((b, i) => (i === gi ? grid : b));
    const order = blocks.map((b, i) => i).sort((a, b) => (blocks[a].lonely - blocks[b].lonely) || blocks[b].w * blocks[b].h - blocks[a].w * blocks[a].h || a - b);
    const shelves = (W) => {
      const at = []; let x = 0, y = 0, rh = 0, mw = 0;
      for (const i of order) { const b = blocks[i]; if (x > 0 && x + b.w > W) { x = 0; y += rh + G; rh = 0; } at[i] = { x, y }; x += b.w + G; mw = Math.max(mw, x - G); rh = Math.max(rh, b.h); }
      return { at, w: mw, h: y + rh };
    };
    const columns = (H) => {
      const at = []; let x = 0, y = 0, cw = 0, mh = 0;
      for (const i of order) { const b = blocks[i]; if (y > 0 && y + b.h > H) { y = 0; x += cw + G; cw = 0; } at[i] = { x, y }; y += b.h + G; mh = Math.max(mh, y - G); cw = Math.max(cw, b.w); }
      return { at, w: x + cw, h: mh };
    };
    const maxW = blocks.reduce((t, b) => t + b.w + G, 0), minW = Math.max(...blocks.map((b) => b.w));
    const maxH = blocks.reduce((t, b) => t + b.h + G, 0), minH = Math.max(...blocks.map((b) => b.h));
    const tries = [];
    for (let k = 0; k <= 24; k++) { tries.push(shelves(minW + (maxW - minW) * k / 24)); tries.push(columns(minH + (maxH - minH) * k / 24)); }
    for (const r of tries) {
      const asp = r.w / Math.max(1, r.h), area = r.w * r.h;
      const sc = Math.abs(Math.log(asp / P.aspect)) * 2 + Math.log(area);
      if (!best || sc < best.s - 1e-9) best = Object.assign(r, { s: sc, blocks });
    }
  }
  const out = new Map();
  best.blocks.forEach((b, i) => { const o = best.at[i]; for (const [u, p] of b.pos) out.set(u, { x: o.x + p.x, y: o.y + p.y }); });
  return { pos: out, w: best.w, h: best.h };
}

/** One connected component in rows. edges: [{a, b, w}] a uses b. */
function layered(list, edges, f, P, key) {
  // a component laid out before (an earlier round, before some of its arrows were cut) keeps its levels and starts from its order
  const memo = P.memo, was = memo && memo.get(key);
  // 1. break cycles: Eades–Lin–Smyth greedy order
  const seq = was ? was.seq : fasOrder(list, edges);
  const rank = new Map(seq.map((u, i) => [u, i]));
  const dag = edges.map((e) => (rank.get(e.a) < rank.get(e.b) ? { a: e.a, b: e.b, w: e.w, rev: false } : { a: e.b, b: e.a, w: e.w, rev: true }));
  const succ = new Map(list.map((u) => [u, []])), pred = new Map(list.map((u) => [u, []]));
  for (const e of dag) { succ.get(e.a).push(e.b); pred.get(e.b).push(e.a); }
  // 2. levels: candidates (longest path from the top, slid to neighbors' median; from the bottom; plain), the one ordered with fewest crossings
  const top = new Map();
  for (const u of seq) top.set(u, Math.max(0, ...pred.get(u).map((p) => top.get(p) + 1)));
  const slid = new Map(top);
  slide(slid, seq, pred, succ);
  const bot = new Map(), hgt = new Map();
  for (const u of [...seq].reverse()) hgt.set(u, Math.max(0, ...succ.get(u).map((s) => hgt.get(s) + 1)));
  const H = Math.max(...hgt.values());
  for (const u of seq) bot.set(u, H - hgt.get(u));
  const botSlid = new Map(bot); slide(botSlid, seq, pred, succ);
  let pick = null;
  const area = list.reduce((t, u) => t + (f.get(u).w + P.gapX) * (f.get(u).h + P.gapY), 0), W = Math.sqrt(area * P.aspect) * P.wrap;
  const cands = [slid, botSlid, top, bot];
  if (P.wrap) for (const lv of cands.slice()) cands.push(wrapRows(lv, list, pred, succ, f, P, W));
  for (const lev of was ? [was.lev] : cands) {
    const r = orderRows(list, dag, lev, f, P, was && was.cx);
    const sc = r.crossings * 1000 + r.dummies + 300 * Math.abs(Math.log(rowsAspect(r.rows, f, P) / P.aspect));
    if (!pick || sc < pick.sc) pick = Object.assign(r, { sc });
  }
  const rows = pick.rows;
  // 5. x: each row pulled toward its neighbors' anchors, order kept, gaps kept (isotonic regression)
  for (const r of rows) { let x = 0; for (const n of r) { n.x = x; x += n.w + P.gapX; } }
  const ctr = (n) => n.x + n.anchor;
  const gapOf = (a, b) => (a.real && b.real ? P.gapX : P.gapX / 2);
  for (let it = 0; it < 40; it++) {
    const ls = it % 2 === 0 ? [...rows.keys()] : [...rows.keys()].reverse();
    for (const l of ls) {
      const r = rows[l];
      const target = r.map((n) => {
        const ref = n.up.concat(n.down);
        const want = ref.length ? ref.reduce((s, x) => s + ctr(x), 0) / ref.length : ctr(n);
        return want - n.anchor;
      });
      const xs = isotonic(r, target, gapOf);
      r.forEach((n, i) => (n.x = xs[i]));
    }
  }
  if (memo) memo.set(key, { seq, lev: pick.lev, cx: new Map(rows.flat().filter((n) => n.real).map((n) => [n.id, ctr(n)])) });
  // 6. y: rows top-aligned
  const posOut = new Map();
  let y = 0, minX = Infinity, maxX = -Infinity;
  const dyOf = (u) => (f.get(u).note ? f.get(u).note.dy : 0);
  for (const r of rows) {
    const real = r.filter((n) => n.real);
    const top = Math.max(0, ...real.map((n) => dyOf(n.id)));
    const h = Math.max(0, ...real.map((n) => top - dyOf(n.id) + f.get(n.id).h));
    for (const n of r) { minX = Math.min(minX, n.x); maxX = Math.max(maxX, n.x + n.w); if (n.real) posOut.set(n.id, { x: n.x, y: y + top - dyOf(n.id) }); }
    y += h + P.gapY;
  }
  for (const p of posOut.values()) p.x -= minX;
  return { pos: posOut, w: maxX - minX, h: y - P.gapY };
}

/** Rows wider than W wrap: the units that use more than they are used go down a new row, every lower row moving down one. */
function wrapRows(lev0, list, pred, succ, f, P, W) {
  const lev = new Map(lev0);
  for (let l = 0; l < 200; l++) {
    const row = list.filter((u) => lev.get(u) === l);
    if (!row.length) { if (![...lev.values()].some((v) => v > l)) break; continue; }
    let width = row.reduce((t, u) => t + f.get(u).w + P.gapX, 0);
    if (width <= W || row.length < 2) continue;
    const order = row.slice().sort((a, b) => (pred.get(a).length - succ.get(a).length) - (pred.get(b).length - succ.get(b).length) || byKey(a, b));
    const push = new Set();
    for (const u of order) { if (width <= W || push.size >= row.length - 1) break; push.add(u); width -= f.get(u).w + P.gapX; }
    for (const u of list) if (lev.get(u) > l) lev.set(u, lev.get(u) + 1);
    for (const u of push) lev.set(u, l + 1);
  }
  return lev;
}

function rowsAspect(rows, f, P) {
  const w = Math.max(...rows.map((r) => r.reduce((t, n) => t + n.w + P.gapX, 0)));
  const h = rows.reduce((t, r) => t + Math.max(0, ...r.filter((n) => n.real).map((n) => f.get(n.id).h)) + P.gapY, 0);
  return w / Math.max(1, h);
}

function slide(lev, seq, pred, succ) {
  for (let it = 0; it < 12; it++) {
    let moved = false;
    for (const u of [...seq].reverse().concat(seq)) {
      const lo = Math.max(0, ...pred.get(u).map((p) => lev.get(p) + 1));
      const hi = succ.get(u).length ? Math.min(...succ.get(u).map((s) => lev.get(s) - 1)) : Infinity;
      const want = [...pred.get(u).map((p) => lev.get(p) + 1), ...succ.get(u).map((s) => lev.get(s) - 1)].sort((a, b) => a - b);
      if (!want.length) continue;
      let t = want[Math.floor((want.length - 1) / 2)];
      t = Math.max(lo, Math.min(t, hi));
      if (t !== lev.get(u)) { lev.set(u, t); moved = true; }
    }
    if (!moved) break;
  }
}

function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

/** Rows for levels `lev`, with placeholders on long arrows, ordered by barycenter sweeps from several starts, then adjacent swaps. */
function orderRows(list, dag, lev, f, P, init) {
  const L = Math.max(...list.map((u) => lev.get(u))) + 1;
  const rows = Array.from({ length: L }, () => []);
  const node = new Map();
  for (const u of list) { const n = { id: u, real: true, w: f.get(u).w, anchor: f.get(u).note ? f.get(u).note.dx + f.get(u).note.w / 2 : f.get(u).w / 2, up: [], down: [] }; node.set(u, n); rows[lev.get(u)].push(n); }
  let d = 0;
  for (const e of dag) {
    let prev = node.get(e.a);
    for (let l = lev.get(e.a) + 1; l < lev.get(e.b); l++) {
      const n = { id: '~' + (d++), real: false, w: P.dummyW, anchor: P.dummyW / 2, up: [], down: [], ends: [e.a, e.b, (l - lev.get(e.a)) / (lev.get(e.b) - lev.get(e.a))] };
      rows[l].push(n); prev.down.push(n); n.up.push(prev); prev = n;
    }
    const b = node.get(e.b); prev.down.push(b); b.up.push(prev);
  }
  const initKey = (n) => (n.real ? init.get(n.id) || 0 : (init.get(n.ends[0]) || 0) * (1 - n.ends[2]) + (init.get(n.ends[1]) || 0) * n.ends[2]);
  const seen = new Set(), ordIdx = new Map();
  let cnt = 0;
  const dfs = (n) => { if (seen.has(n)) return; seen.add(n); ordIdx.set(n, cnt++); for (const x of n.down) dfs(x); };
  for (const r of rows) for (const n of r) dfs(n);
  const pos = (rs) => { for (const r of rs) r.forEach((n, i) => (n.o = i)); };
  let best = null;
  const starts = init ? 1 : d > 200 ? 2 : P.starts;
  for (let s = 0; s < starts; s++) {
    const rs = rows.map((r) => r.slice());
    if (s === 0 && init) for (const r of rs) r.sort((a, b) => initKey(a) - initKey(b) || ordIdx.get(a) - ordIdx.get(b));
    else if (s === 0) for (const r of rs) r.sort((a, b) => ordIdx.get(a) - ordIdx.get(b));
    else { const R = rng(s * 7919 + list.length); for (const r of rs) { const k = new Map(r.map((n) => [n, R()])); r.sort((a, b) => k.get(a) - k.get(b)); } }
    pos(rs);
    let bx = crossCount(rs), br = rs.map((r) => r.slice());
    for (let it = 0; it < 30 && bx > 0; it++) {
      const down = it % 2 === 0;
      const seqL = down ? [...rs.keys()].slice(1) : [...rs.keys()].reverse().slice(1);
      for (const l of seqL) {
        const r = rs[l];
        const bc = new Map(r.map((n) => { const ref = down ? n.up : n.down; return [n, ref.length ? ref.reduce((t, x) => t + x.o, 0) / ref.length : n.o]; }));
        r.sort((a, b) => bc.get(a) - bc.get(b) || a.o - b.o);
        r.forEach((n, i) => (n.o = i));
      }
      if (d <= 200) transpose(rs);
      const x = crossCount(rs);
      if (x < bx) { bx = x; br = rs.map((r) => r.slice()); }
    }
    pos(br); transpose(br); bx = crossCount(br);
    if (!best || bx < best.crossings) best = { rows: br.map((r) => r.slice()), crossings: bx };
    if (!bx) break;
  }
  pos(best.rows);
  return { rows: best.rows, crossings: best.crossings, dummies: d, lev };
}

function transpose(rows) {
  for (let pass = 0; pass < 8; pass++) {
    let gain = false;
    for (const r of rows) for (let i = 0; i + 1 < r.length; i++) {
      const a = r[i], b = r[i + 1];
      if (pairX(b, a) < pairX(a, b)) { r[i] = b; r[i + 1] = a; a.o = i + 1; b.o = i; gain = true; }
    }
    if (!gain) break;
  }
}

/** Lefts as close as can be to `target` (least squares), in order, each at least the one before's width plus a gap past it. */
function isotonic(r, target, gapOf) {
  const off = [0];
  for (let i = 1; i < r.length; i++) off[i] = off[i - 1] + r[i - 1].w + gapOf(r[i - 1], r[i]);
  const z = target.map((t, i) => t - off[i]);
  const blocks = []; // {sum, n}
  for (const v of z) {
    blocks.push({ sum: v, n: 1 });
    while (blocks.length > 1 && blocks[blocks.length - 2].sum / blocks[blocks.length - 2].n > blocks[blocks.length - 1].sum / blocks[blocks.length - 1].n) {
      const b = blocks.pop(); blocks[blocks.length - 1].sum += b.sum; blocks[blocks.length - 1].n += b.n;
    }
  }
  const out = []; let i = 0;
  for (const b of blocks) for (let k = 0; k < b.n; k++, i++) out.push(b.sum / b.n + off[i]);
  return out;
}

function pairX(a, b) { // crossings between a's and b's arrows, a left of b, both sides
  let x = 0;
  for (const side of ['up', 'down']) for (const p of a[side]) for (const q of b[side]) if (p.o > q.o) x++;
  return x;
}

function crossCount(rows) {
  let x = 0;
  for (let l = 0; l + 1 < rows.length; l++) {
    const es = [];
    for (const n of rows[l]) for (const d of n.down) es.push([n.o, d.o]);
    for (let i = 0; i < es.length; i++) for (let j = i + 1; j < es.length; j++) if ((es[i][0] - es[j][0]) * (es[i][1] - es[j][1]) < 0) x++;
  }
  return x;
}

/** Eades–Lin–Smyth: sinks to the back, sources to the front, else the unit with most out minus in. */
function fasOrder(list, edges) {
  const outW = new Map(list.map((u) => [u, new Map()])), inW = new Map(list.map((u) => [u, new Map()]));
  for (const e of edges) { if (e.a === e.b) continue; outW.get(e.a).set(e.b, (outW.get(e.a).get(e.b) || 0) + e.w); inW.get(e.b).set(e.a, (inW.get(e.b).get(e.a) || 0) + e.w); }
  const left = new Set(list), s1 = [], s2 = [];
  const drop = (u) => { left.delete(u); for (const v of outW.get(u).keys()) inW.get(v).delete(u); for (const v of inW.get(u).keys()) outW.get(v).delete(u); };
  const sum = (mp) => { let s = 0; for (const v of mp.values()) s += v; return s; };
  while (left.size) {
    let changed = true;
    while (changed) {
      changed = false;
      for (const u of [...left].sort(byKey)) if (left.has(u) && outW.get(u).size === 0) { s2.unshift(u); drop(u); changed = true; }
      for (const u of [...left].sort(byKey)) if (left.has(u) && inW.get(u).size === 0) { s1.push(u); drop(u); changed = true; }
    }
    if (!left.size) break;
    let best = null, bv = -Infinity;
    for (const u of [...left].sort(byKey)) { const v = sum(outW.get(u)) - sum(inW.get(u)); if (v > bv) { bv = v; best = u; } }
    s1.push(best); drop(best);
  }
  return s1.concat(s2);
}

/** Pill sides: a loose note whose arrows leave mostly to its right takes its block on its left. */
function chooseSides(m, g, c, f, at, sides) {
  let changed = false;
  const cx = (u) => at.get(u).x + f.get(u).note.dx + f.get(u).note.w / 2;
  const score = new Map();
  for (const e of c.arrows) {
    const a = g.unitOf(e.from), b = g.unitOf(e.to);
    if (a === b) continue;
    const ua = f.get(a), ub = f.get(b);
    const xa = ua.frame ? at.get(a).x + ua.w / 2 : cx(a), xb = ub.frame ? at.get(b).x + ub.w / 2 : cx(b);
    if (!ua.frame) score.set(a, (score.get(a) || 0) + Math.sign(xb - xa));
    if (!ub.frame) score.set(b, (score.get(b) || 0) + Math.sign(xa - xb));
  }
  for (const [u, s] of score) if (s > 0 && f.get(u).pills.length && !sides.has(u)) { sides.set(u, 'left'); changed = true; }
  return changed;
}

/** Each arrow's conflicts: crossings with another arrow (no shared end), passing over a note, or over another unit's pill. */
export function conflicts(m, layout) {
  const pillById = new Map(layout.pills.map((p) => [p.id, p]));
  const boxOf = (id) => layout.boxes[id] || pillById.get(id);
  const leaves = Object.keys(layout.boxes).filter((k) => !m.node(k).isFrame);
  const arrows = layout.arrows;
  const paths = arrows.map((a) => arrowPoints(boxOf(a.from), boxOf(a.to), a, 16));
  const per = new Map();
  const add = (a, n = 1) => { if (a.pill) return; per.set(a.edge, (per.get(a.edge) || 0) + n); };
  let total = 0;
  const bb = paths.map((p) => p.reduce((r, q) => [Math.min(r[0], q[0]), Math.min(r[1], q[1]), Math.max(r[2], q[0]), Math.max(r[3], q[1])], [Infinity, Infinity, -Infinity, -Infinity]));
  arrows.forEach((a, i) => {
    const pts = paths[i];
    if (pts.length < 2) return;
    const B = bb[i], off = (o) => o.x > B[2] || o.x + o.w < B[0] || o.y > B[3] || o.y + o.h < B[1];
    for (const k of leaves) if (k !== a.from && k !== a.to && !off(layout.boxes[k]) && pathHitsBox(pts, inset(layout.boxes[k]))) { total++; add(a, 2); }
    for (const p of layout.pills) {
      if (p.id === a.from || p.id === a.to || off(p)) continue;
      if (a.pill && p.user === a.from) continue;
      if (pathHitsBox(pts, inset(p))) { total++; add(a, 1); }
    }
  });
  for (let i = 0; i < arrows.length; i++) for (let j = i + 1; j < arrows.length; j++) {
    const a = arrows[i], c = arrows[j];
    if (a.from === c.from || a.from === c.to || a.to === c.from || a.to === c.to) continue;
    if (bb[i][0] > bb[j][2] || bb[j][0] > bb[i][2] || bb[i][1] > bb[j][3] || bb[j][1] > bb[i][3]) continue;
    if (polyCross(paths[i], paths[j])) { total++; add(a); add(c); }
  }
  return { total, per };
}
const inset = (b) => ({ x: b.x + 1, y: b.y + 1, w: b.w - 2, h: b.h - 2 });
function polyCross(p, q) {
  for (let s = 1; s < p.length; s++) for (let t = 1; t < q.length; t++) if (segX(p[s - 1], p[s], q[t - 1], q[t])) return true;
  return false;
}
function segX(a, b, c, d) {
  const o = (p, q, r) => Math.sign((q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]));
  return o(a, b, c) * o(a, b, d) < 0 && o(c, d, a) * o(c, d, b) < 0;
}

/** The kit's assemble with its bends found as the kit's clearBend finds them (same bends, same order, same pad), only faster: obstacles
 *  outside an arc's bounds are skipped. A copy of kit.clearBend's rule, with a bounding-box test added. */
function assembleFast(m, g, c, f, at) {
  const plain = assemble(m, g, c, f, at, { autoBend: false });
  const obstacles = Object.entries(plain.boxes).filter(([k]) => !m.node(k).isFrame).map(([k, b]) => Object.assign({ key: k }, b)).concat(plain.pills.map((p) => Object.assign({ key: p.id }, p)));
  const bends = new Map();
  for (const e of c.arrows) bends.set(e.i, clearBendFast(plain.boxes[e.from], plain.boxes[e.to], obstacles, e.from, e.to));
  return assemble(m, g, c, f, at, { bends });
}
function clearBendFast(A, B, obstacles, ka, kb) {
  const chord = Math.hypot(A.x + A.w / 2 - B.x - B.w / 2, A.y + A.h / 2 - B.y - B.h / 2);
  let best = null;
  for (const bend of KIT.bends) {
    if (Math.abs(bend) > Math.max(40, 0.45 * chord)) continue;
    const pts = arrowPoints(A, B, { bend }, 24);
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const q of pts) { x0 = Math.min(x0, q[0]); y0 = Math.min(y0, q[1]); x1 = Math.max(x1, q[0]); y1 = Math.max(y1, q[1]); }
    let hits = 0;
    const d = KIT.pad;
    for (const o of obstacles) {
      if (o.key === ka || o.key === kb) continue;
      if (o.x - d > x1 || o.x + o.w + d < x0 || o.y - d > y1 || o.y + o.h + d < y0) continue;
      if (pathHitsBox(pts, { x: o.x - d, y: o.y - d, w: o.w + 2 * d, h: o.h + 2 * d })) hits++;
    }
    if (!best || hits < best.hits) best = { bend, hits };
    if (!hits) break;
  }
  return best ? best.bend : 0;
}

/** Each arrow still in a conflict tries every bend of the kit's list (one arc, as the app draws) and keeps the one with fewest conflicts. */
const BENDS = [0, 40, -40, 80, -80, 120, -120, 180, -180, 260, -260, 360, -360, 480, -480, 640, -640];
function fixBends(m, layout, P = {}) {
  const cap = P.bendCap || 0.6, capAbs = P.bendMax || 640;
  const pillById = new Map(layout.pills.map((p) => [p.id, p]));
  const boxOf = (id) => layout.boxes[id] || pillById.get(id);
  const leaves = Object.keys(layout.boxes).filter((k) => !m.node(k).isFrame).map((k) => Object.assign({ key: k }, layout.boxes[k]));
  const A = layout.arrows;
  const bbox = (pts) => { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const q of pts) { x0 = Math.min(x0, q[0]); y0 = Math.min(y0, q[1]); x1 = Math.max(x1, q[0]); y1 = Math.max(y1, q[1]); } return [x0, y0, x1, y1]; };
  const paths = A.map((a) => arrowPoints(boxOf(a.from), boxOf(a.to), a, 16));
  const bbs = paths.map(bbox);
  const cost = (i, pts, B) => {
    const a = A[i];
    const off = (o) => o.x > B[2] || o.x + o.w < B[0] || o.y > B[3] || o.y + o.h < B[1];
    let n = 0;
    for (const o of leaves) if (o.key !== a.from && o.key !== a.to && !off(o) && pathHitsBox(pts, inset(o))) n += 2;
    for (const p of layout.pills) if (p.id !== a.to && p.id !== a.from && !off(p) && pathHitsBox(pts, inset(p))) n += 1;
    for (let j = 0; j < A.length; j++) {
      if (j === i) continue;
      const c = A[j];
      if (a.from === c.from || a.from === c.to || a.to === c.from || a.to === c.to) continue;
      const C = bbs[j];
      if (B[0] > C[2] || C[0] > B[2] || B[1] > C[3] || C[1] > B[3]) continue;
      if (polyCross(pts, paths[j])) n += 1;
    }
    return n;
  };
  for (let pass = 0; pass < 3; pass++) {
    let changed = false;
    A.forEach((a, i) => {
      if (a.pill) return;
      const now = cost(i, paths[i], bbs[i]);
      if (!now) return;
      let best = { n: now, bend: a.bend || 0, pts: paths[i], bb: bbs[i] };
      const chord = Math.hypot(boxOf(a.from).x - boxOf(a.to).x, boxOf(a.from).y - boxOf(a.to).y);
      for (const bend of BENDS) {
        if (bend === (a.bend || 0) || Math.abs(bend) > Math.min(capAbs, Math.max(80, cap * chord))) continue;
        const pts = arrowPoints(boxOf(a.from), boxOf(a.to), { bend }, 16), bb = bbox(pts);
        const n = cost(i, pts, bb) + Math.abs(bend) / 10000;
        if (n < best.n - 1e-9) best = { n, bend, pts, bb };
      }
      if (best.bend !== (a.bend || 0)) { a.bend = best.bend; paths[i] = best.pts; bbs[i] = best.bb; changed = true; }
    });
    if (!changed) break;
  }
}
