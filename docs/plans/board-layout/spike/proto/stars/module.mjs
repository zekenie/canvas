// STARS: keep the hubs as notes. Cut single edges (kit mode 'edges') so the rest is planar, then place each unit by stress (graph distance
// as the ideal distance, so a hub lands at the center of its users and hubs that share users sit side by side), push overlaps apart, and
// polish by a deterministic local search that removes crossings, arrows over notes and over pill blocks, shortens arrows, lines arrows up
// with an axis, and turns each note's pill block to the side its arrows don't leave by.
import { boardGraph, cut, footprints, assemble, evaluate as kitEvaluate, arrowPoints, pathHitsBox, isPlanar } from './kit.mjs';
import { edgeCuts } from '../planar/planar.mjs';
import { overlaps } from '../planar/overlaps.mjs';
import { deoverlap } from '../planar/deoverlap.mjs';

// Mode 'stars' (this direction's own, beside the kit's 'edges'): the fewest single edges, found greedily, but adding the edges at the most
// connected units FIRST, so a hub keeps its arrows and the cuts fall between the less connected notes (the kit's 'edges' adds them last,
// so its cuts fall at the hubs). Same result shape as kit.cut.
function starsCut(m, g) {
  const ix = new Map(g.units.map((k, i) => [k, i]));
  const pairs = new Map();
  for (const e of g.inner) {
    const a = g.unitOf(e.from), b = g.unitOf(e.to);
    if (a === b) continue;
    const u = ix.get(a), v = ix.get(b), key = Math.min(u, v) + ',' + Math.max(u, v);
    if (!pairs.has(key)) pairs.set(key, { u: Math.min(u, v), v: Math.max(u, v), edges: [] });
    pairs.get(key).edges.push(e);
  }
  const n = g.units.length, list = [...pairs.values()];
  const cutPairs = new Set();
  if (!isPlanar(n, list.map((p) => [p.u, p.v]))) {
    const d = new Array(n).fill(0);
    for (const p of list) { d[p.u]++; d[p.v]++; }
    const ord = list.map((p, i) => Object.assign([p.u, p.v], { idx: i }))
      .sort((a, b) => Math.max(d[b[0]], d[b[1]]) - Math.max(d[a[0]], d[a[1]]) || Math.min(d[b[0]], d[b[1]]) - Math.min(d[a[0]], d[a[1]]) || a.idx - b.idx);
    for (const e of edgeCuts(n, ord)) cutPairs.add(e.idx);
  }
  const cutEdges = new Set();
  list.forEach((p, i) => { if (cutPairs.has(i)) for (const e of p.edges) cutEdges.add(e.i); });
  const arrows = [], pills = [];
  for (const e of g.inner) { if (cutEdges.has(e.i)) pills.push({ edge: e, user: e.from, for: e.to }); else arrows.push(e); }
  for (const e of g.cross) pills.push({ edge: e, user: e.from, for: e.to });
  return { mode: 'stars', referenced: [], cutEdges: [...cutEdges], arrows, pills };
}

const GAP = 56;            // between two units' footprints
const SIDES = ['right', 'left', 'below', 'above'];
const W = { cross: 10000, over: 4000, len: 1, align: 40, area: +(process.env.AREA || 0.0003) };

// stars2: lay the board out under several configurations, from the most compact to the first round's default, each in a worker thread
// of its own, and keep the clean one with the least area (a pill counts as 25,000 square units), more the farther its shape is from 1.5 wide to 1 high. The first round's default is among them,
// so no board is worse off than it was. Deterministic: the choice doesn't depend on which worker finishes first.
import { Worker } from 'worker_threads';
import { fileURLToPath } from 'url';
export const CONFIGS = [
  { cmode: 'free', q: 0.5, aspect: 1.6, rounds: 9 },
  { cmode: 'free', q: 0.8, aspect: 1.6, rounds: 9 },
  { cmode: 'free', q: 0.5, aspect: 1.6, rounds: 9, abut: true },
  { slack: 5000, q: 0.4, aspect: 1.6, rounds: 7 },
  { abut: false },
  // stars3: the same search with the placement rules (v3): link weight in the ideal distances, a long arrow's overshoot past four note
  // widths paid for, right-up-against candidates beside each unit's heaviest neighbours, a frame tried flush with the board's side nearest
  // what it connects to, a pill block's side counted against the note's own arrows, and loose notes beside their neighbour
  { cmode: 'free', q: 0.5, aspect: 1.6, rounds: 9, abut: true, v3: true },
  { slack: 5000, q: 0.4, aspect: 1.6, rounds: 7, v3: true },
  { abut: false, v3: true },
];
import fs from 'fs';
let TODAY = null;
const todayArea = (board) => { try { if (!TODAY) TODAY = JSON.parse(fs.readFileSync(new URL('./today-metrics.json', import.meta.url), 'utf8')); const t = TODAY[board]; return t ? t.size[0] * t.size[1] : null; } catch (e) { return null; } };
// what a board's arrows overshoot: each note-to-note arrow's length past four note widths (the median note's), summed
function overshoot(m, layout) {
  const ws = Object.keys(layout.boxes).filter((k) => !m.node(k).isFrame).map((k) => layout.boxes[k].w).sort((a, b) => a - b);
  const LONG = 4 * (ws.length ? ws[Math.floor(ws.length / 2)] : 240);
  let o = 0;
  for (const a of layout.arrows) { const A = layout.boxes[a.from], B = layout.boxes[a.to]; if (!A || !B) continue; const d = Math.hypot(A.x + A.w / 2 - B.x - B.w / 2, A.y + A.h / 2 - B.y - B.h / 2); o += Math.max(0, d - LONG); }
  return o;
}
export function score(r, board) {
  let s = (r.area + PILL * r.pills) * (1 + 0.5 * Math.abs(Math.log(Math.max(0.1, r.aspect) / 1.5)));
  s += 2500 * (r.over || 0);
  const t = todayArea(board);
  if (t) { const k = r.area / t; if (k > 1.1) s *= 1 + 1.5 * (k - 1.1); }
  return s;
}
const PILL = 25000;
let pool = null;
function job(w, msg) { return new Promise((res, rej) => { w.ref(); const onErr = (e) => { w.off('message', onMsg); rej(e); }; const onMsg = (v) => { w.off('error', onErr); w.unref(); res(v); }; w.once('message', onMsg); w.once('error', onErr); w.postMessage(msg); }); }
export async function layoutBoard(m, board, opts = {}) {
  if (process.env.ONE) return layoutOne(m, board, opts);
  let results;
  try {
    if (!pool) pool = CONFIGS.map(() => { const w = new Worker(new URL('./worker.mjs', import.meta.url), { workerData: { data: m.dataDir || null } }); w.unref(); return w; });
    results = await Promise.all(CONFIGS.map((cfg, i) => job(pool[i], { board, i })));
  } catch (e) {
    results = [];
    for (let i = 0; i < CONFIGS.length; i++) results.push(await runConfig(m, board, i));
  }
  // a configuration wins only when it is clean and nothing in it sits on anything else (a pill on a pill or on a note's title tab, a note
  // on a note, a shape on a frame that isn't its)
  const nOver = (L) => { const o = overlaps(m, board, L); return o.pillPill + o.pillNote + o.pillTab + o.noteNote + o.onFrame; };
  // a clean configuration with pills on top of something is repaired first (each such pill to a clean free spot by its note)
  results = results.map((r) => { if (!r || !r.clean || !nOver(r.layout)) return r; const d = deoverlap(m, board, r.layout); return Object.assign({}, r, { layout: d.layout, clean: kitEvaluate(m, board, d.layout).clean }); });
  // the winner: the best of the sound ones (clean, nothing on anything); with none, the least bad (crossings and arrows over shapes weigh
  // more than an overlap)
  const sound = (r) => !!(r && r.clean && !nOver(r.layout));
  let best = null;
  results.forEach((r, i) => { if (!sound(r)) return; const s = score(r, board); if (!best || s < best.s) best = { s, r, i }; });
  if (!best) results.forEach((r, i) => { if (!r || !r.layout) return; const e = kitEvaluate(m, board, r.layout); const bad = 1000 * (e.crossings + e.overNotes + e.overOtherPills) + 500 * nOver(r.layout); if (!best || bad < best.bad) best = { bad, r, i }; });
  best.r.info.config = best.i;
  return { layout: best.r.layout, info: best.r.info };
}
export async function runConfig(m, board, i) {
  // never failing: a configuration that throws is one that isn't clean (round 2's five are always among the rest)
  let r;
  try { r = await layoutOne(m, board, Object.assign({}, CONFIGS[i])); } catch (e) { if (process.env.DBG) console.error(board, i, e); return { layout: null, info: { error: String(e) }, clean: false }; }
  const e = kitEvaluate(m, board, r.layout);
  return { layout: r.layout, info: r.info, clean: e.clean, area: e.size[0] * e.size[1], pills: e.pills, aspect: e.aspect, over: overshoot(m, r.layout) };
}
export async function layoutOne(m, board, opts = {}) {
  const g = boardGraph(m, board);
  const mode = opts.mode || process.env.MODE || 'edges';
  let c = mode === 'stars' ? starsCut(m, g) : cut(m, g, mode), r = null, extra = 0;
  const rounds = opts.rounds ?? 5;
  if (opts.abut != null) opts = Object.assign({}, opts);
  for (let round = 0; ; round++) {
    r = place(m, g, c, board, opts, r);
    if (round >= rounds) break;
    const blame = conflicts(m, r.layout);
    if (!blame.length) break;
    const out = new Set(blame);
    extra += out.size;
    c = Object.assign({}, c, { arrows: c.arrows.filter((e) => !out.has(e.i)), cutEdges: c.cutEdges.concat([...out]),
      pills: c.pills.concat(c.arrows.filter((e) => out.has(e.i)).map((e) => ({ edge: e, user: e.from, for: e.to }))) });
  }
  let layout = r.layout, back = 0;
  // stars2: with the board laid out, each cut edge (between two notes on it) tried as an arrow again, where it stands: kept if the board
  // stays clean (its pill goes, its user's block closes up)
  if (opts.restore !== false && c.cutEdges.length) {
    const cutSet = new Set(c.cutEdges);
    for (const ei of c.cutEdges.slice().sort((a, b) => a - b)) {
      const e = g.inner.find((x) => x.i === ei);
      if (!e || g.unitOf(e.from) === g.unitOf(e.to)) continue;
      const c2 = Object.assign({}, c, { arrows: c.arrows.concat([e]), cutEdges: c.cutEdges.filter((x) => x !== ei), pills: c.pills.filter((p) => p.edge.i !== ei) });
      const lay = assemble(m, g, c2, footprints(m, g, c2, r.sides), r.at);
      if (kitEvaluate(m, board, lay).clean) { c = c2; layout = lay; back++; cutSet.delete(ei); }
    }
  }
  return { layout, info: { cut: c.cutEdges.length, extraCut: extra, restored: back, pills: c.pills.length } };
}

// The arrows to cut so what is left is clean: every crossing, arrow over a note and arrow over another unit's pill names the drawn (not
// pill) arrows in it; the arrow named most goes first, until none is left.
function conflicts(m, L) {
  const boxOf = (id) => L.boxes[id] || L.pills.find((p) => p.id === id);
  const A = L.arrows.map((a) => { const pts = arrowPoints(boxOf(a.from), boxOf(a.to), a, 16); return { a, pts }; });
  const sc = (p, q, r, s) => { const o = (a, b, c2) => (b[0] - a[0]) * (c2[1] - a[1]) - (b[1] - a[1]) * (c2[0] - a[0]); const d1 = o(p, q, r), d2 = o(p, q, s), d3 = o(r, s, p), d4 = o(r, s, q); return d1 * d2 < 0 && d3 * d4 < 0; };
  const issues = [];
  const notes = Object.keys(L.boxes).filter((k) => !m.node(k).isFrame);
  for (let i = 0; i < A.length; i++) {
    const { a, pts } = A[i];
    if (!a.pill) {
      for (const k of notes) if (k !== a.from && k !== a.to && pathHitsBox(pts, { x: L.boxes[k].x + 1, y: L.boxes[k].y + 1, w: L.boxes[k].w - 2, h: L.boxes[k].h - 2 })) issues.push([a.edge]);
      for (const p of L.pills) if (p.id !== a.to && pathHitsBox(pts, { x: p.x + 1, y: p.y + 1, w: p.w - 2, h: p.h - 2 })) issues.push([a.edge]);
    }
    for (let j = i + 1; j < A.length; j++) {
      const b = A[j].a;
      if (a.from === b.from || a.from === b.to || a.to === b.from || a.to === b.to) continue;
      let hit = false;
      for (let s = 1; s < pts.length && !hit; s++) for (let t = 1; t < A[j].pts.length && !hit; t++) if (sc(pts[s - 1], pts[s], A[j].pts[t - 1], A[j].pts[t])) hit = true;
      if (hit) issues.push([a, b].filter((x) => !x.pill).map((x) => x.edge));
    }
  }
  const out = [];
  let open = issues.filter((x) => x.length);
  while (open.length) {
    const cnt = new Map();
    for (const x of open) for (const e of x) cnt.set(e, (cnt.get(e) || 0) + 1);
    let best = null; for (const [e, v] of cnt) if (best == null || v > cnt.get(best) || (v === cnt.get(best) && e < best)) best = e;
    out.push(best);
    open = open.filter((x) => !x.includes(best));
  }
  return out;
}

function place(m, g, c, board, opts, prev) {
  const prevP = prev && prev.P;
  const fpBySide = {};
  for (const s of SIDES) fpBySide[s] = footprints(m, g, c, new Map(g.units.map((u) => [u, s])));
  const U = g.units, n = U.length, ix = new Map(U.map((u, i) => [u, i]));
  const side = prev ? prev.side.slice() : U.map(() => 'right');
  const fp = (i) => fpBySide[side[i]].get(U[i]);

  // the drawn edges, note to note, with their units
  const E = c.arrows.map((e) => ({ e, a: e.from, b: e.to, ua: ix.get(g.unitOf(e.from)), ub: ix.get(g.unitOf(e.to)) }));
  const inc = U.map(() => []);
  E.forEach((d, k) => { inc[d.ua].push(k); if (d.ub !== d.ua) inc[d.ub].push(k); });

  // where a note's center is in its unit's footprint
  const off = (i, key) => { const f = fp(i); if (!f.frame) return [f.note.dx + f.note.w / 2, f.note.dy + f.note.h / 2]; const b = f.members[key]; return [b.dx + b.w / 2, b.dy + b.h / 2]; };

  // ---- stress layout of the units' graph (arrows only; a unit with no arrow goes on a shelf afterwards) ----
  const adj = U.map(() => new Map());
  for (const d of E) if (d.ua !== d.ub) { adj[d.ua].set(d.ub, (adj[d.ua].get(d.ub) || 0) + 1); adj[d.ub].set(d.ua, (adj[d.ub].get(d.ua) || 0) + 1); }
  // stars3: every edge between two units, drawn or cut, as the link weight between them
  const wt = U.map(() => new Map());
  for (const e of g.inner) { const a = ix.get(g.unitOf(e.from)), b = ix.get(g.unitOf(e.to)); if (a == null || b == null || a === b) continue; wt[a].set(b, (wt[a].get(b) || 0) + (e.weight || 1)); wt[b].set(a, (wt[b].get(a) || 0) + (e.weight || 1)); }
  const heaviest = (i, k) => [...wt[i].entries()].sort((x, y) => y[1] - x[1] || x[0] - y[0]).slice(0, k).map((x) => x[0]);
  const noteWs = U.map((u, i) => fp(i)).filter((f) => !f.frame).map((f) => f.note.w).sort((a, b) => a - b);
  const LONG = 4 * (noteWs.length ? noteWs[Math.floor(noteWs.length / 2)] : 240);
  const diag = (i) => { const f = fp(i); return Math.hypot(f.w, f.h); };
  const linked = U.map((_, i) => adj[i].size > 0);
  const P = U.map(() => [0, 0]);
  const conn = [...Array(n).keys()].filter((i) => linked[i]);
  if (prevP) for (let i = 0; i < n; i++) P[i] = prevP[i].slice();
  if (conn.length && !prevP) {
    // weighted shortest paths: an edge's length is what its two footprints need
    const D = conn.map(() => new Array(conn.length).fill(Infinity));
    const cix = new Map(conn.map((i, k) => [i, k]));
    const el = (i, j) => ((diag(i) + diag(j)) / 2 * 0.62 + GAP + 40) / (opts.v3 ? 1 + 0.25 * Math.log(adj[i].get(j) || 1) : 1);
    for (let s = 0; s < conn.length; s++) {
      const dist = D[s]; dist[s] = 0;
      const done = new Array(conn.length).fill(false);
      for (;;) {
        let u = -1;
        for (let k = 0; k < conn.length; k++) if (!done[k] && dist[k] < Infinity && (u < 0 || dist[k] < dist[u])) u = k;
        if (u < 0) break;
        done[u] = true;
        for (const [v] of adj[conn[u]]) { const kv = cix.get(v), nd = dist[u] + el(conn[u], v); if (nd < dist[kv]) dist[kv] = nd; }
      }
    }
    let maxD = 0;
    for (const r of D) for (const x of r) if (x < Infinity) maxD = Math.max(maxD, x);
    for (const r of D) for (let k = 0; k < r.length; k++) if (r[k] === Infinity) r[k] = maxD * 0.6 + 300;
    // start: by degree, hubs in the middle, on a golden-angle spiral
    const order = conn.slice().sort((a, b) => adj[b].size - adj[a].size || (U[a] < U[b] ? -1 : 1));
    const X = conn.map(() => [0, 0]);
    order.forEach((i, r) => { const k = cix.get(i), t = r * 2.39996, rad = 220 * Math.sqrt(r); X[k] = [rad * Math.cos(t) * 1.4, rad * Math.sin(t)]; });
    // SMACOF
    const N = conn.length;
    for (let it = 0; it < 300; it++) {
      const Y = X.map(() => [0, 0]);
      for (let a = 0; a < N; a++) {
        let sx = 0, sy = 0, sw = 0;
        for (let b = 0; b < N; b++) {
          if (a === b) continue;
          const d = D[a][b], w = 1 / (d * d), dx = X[a][0] - X[b][0], dy = X[a][1] - X[b][1], cur = Math.hypot(dx, dy) || 1e-3;
          sx += w * (X[b][0] + d * dx / cur); sy += w * (X[b][1] + d * dy / cur); sw += w;
        }
        Y[a] = [sx / sw, sy / sw];
      }
      for (let a = 0; a < N; a++) X[a] = Y[a];
    }
    // untangle as points: move each unit an arrow of which crosses another to where its arrows cross least (lattice, its neighbors'
    // barycenter), stress breaking ties, keeping points apart; a planar graph almost always comes out with no crossing
    {
      const pr = [];
      for (let a = 0; a < N; a++) for (const [v] of adj[conn[a]]) { const b = cix.get(v); if (a < b) pr.push([a, b]); }
      const inP = conn.map(() => []);
      pr.forEach(([a, b], k) => { inP[a].push(k); inP[b].push(k); });
      const sx = (p, q, r, s2) => { const o = (a, b, c2) => (b[0] - a[0]) * (c2[1] - a[1]) - (b[1] - a[1]) * (c2[0] - a[0]); const d1 = o(p, q, r), d2 = o(p, q, s2), d3 = o(r, s2, p), d4 = o(r, s2, q); return d1 * d2 < 0 && d3 * d4 < 0; };
      const crossAt = (a) => { let c2 = 0; for (const k of inP[a]) { const [u, v] = pr[k]; for (let l = 0; l < pr.length; l++) { const [x, y] = pr[l]; if (x === u || x === v || y === u || y === v) continue; if (sx(X[u], X[v], X[x], X[y])) c2++; } } return c2; };
      const stressAt = (a) => { let s2 = 0; for (let b = 0; b < N; b++) { if (b === a) continue; const d = D[a][b], cur = Math.hypot(X[a][0] - X[b][0], X[a][1] - X[b][1]); s2 += (cur - d) * (cur - d) / (d * d); } return s2; };
      const tooNear = (a, p) => { for (let b = 0; b < N; b++) if (b !== a && Math.hypot(p[0] - X[b][0], p[1] - X[b][1]) < 0.45 * Math.min(D[a][b], 400)) return true; return false; };
      const cost = (a) => crossAt(a) * 1000 + stressAt(a);
      for (let round = 0; round < 12; round++) {
        let any = false;
        for (let a = 0; a < N; a++) {
          if (!crossAt(a)) continue;
          let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
          for (const p of X) { x0 = Math.min(x0, p[0]); y0 = Math.min(y0, p[1]); x1 = Math.max(x1, p[0]); y1 = Math.max(y1, p[1]); }
          const orig = X[a]; let best = cost(a), bp = orig;
          const cands = [];
          const st = Math.max(x1 - x0, y1 - y0) / 24;
          for (let y = y0 - 3 * st; y <= y1 + 3 * st; y += st) for (let x = x0 - 3 * st; x <= x1 + 3 * st; x += st) cands.push([x, y]);
          if (inP[a].length) { let bx = 0, by = 0; for (const k of inP[a]) { const o = pr[k][0] === a ? pr[k][1] : pr[k][0]; bx += X[o][0]; by += X[o][1]; } cands.push([bx / inP[a].length, by / inP[a].length]); }
          for (const p of cands) { if (tooNear(a, p)) continue; X[a] = p; const v = cost(a); if (v < best - 1e-6) { best = v; bp = p; } X[a] = orig; }
          if (bp !== orig) { X[a] = bp; any = true; }
        }
        // a few stress steps that keep what untangling won (a point moves only if its crossings don't grow)
        for (let it = 0; it < 20; it++) for (let a = 0; a < N; a++) {
          let sx2 = 0, sy2 = 0, sw = 0;
          for (let b = 0; b < N; b++) { if (a === b) continue; const d = D[a][b], w = 1 / (d * d), dx = X[a][0] - X[b][0], dy = X[a][1] - X[b][1], cur = Math.hypot(dx, dy) || 1e-3; sx2 += w * (X[b][0] + d * dx / cur); sy2 += w * (X[b][1] + d * dy / cur); sw += w; }
          const orig = X[a], c0 = crossAt(a); X[a] = [sx2 / sw, sy2 / sw];
          if (crossAt(a) > c0 || tooNear(a, X[a])) X[a] = orig;
        }
        if (!any) break;
      }
      if (process.env.DBG) { let t = 0; for (let a = 0; a < N; a++) t += crossAt(a); console.error(board, 'point crossings', t / 2); }
    }
    // turn the long axis horizontal
    let mx = 0, my = 0; for (const p of X) { mx += p[0]; my += p[1]; } mx /= N; my /= N;
    let sxx = 0, syy = 0, sxy = 0; for (const p of X) { const dx = p[0] - mx, dy = p[1] - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy; }
    const th = 0.5 * Math.atan2(2 * sxy, sxx - syy), co = Math.cos(-th), si = Math.sin(-th);
    const C = conn.map((i) => { const p = X[cix.get(i)], dx = p[0] - mx, dy = p[1] - my; return [dx * co - dy * si, dx * si + dy * co]; });
    // stretch to the window's shape (an affine map keeps a drawing with no crossing so), then grow it evenly until no two footprints overlap
    if (opts.affine !== false && N > 2) {
      let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity, fw = 0, fh = 0;
      conn.forEach((i, k) => { x0 = Math.min(x0, C[k][0]); x1 = Math.max(x1, C[k][0]); y0 = Math.min(y0, C[k][1]); y1 = Math.max(y1, C[k][1]); fw += fp(i).w; fh += fp(i).h; });
      fw /= N; fh /= N;
      const w = x1 - x0 + fw, h = y1 - y0 + fh, want = opts.aspect || 1.5;
      if (w / h < want) { const k = Math.min(3, Math.sqrt(want * h / w)); for (const p of C) { p[0] *= k; p[1] /= k; } }
      const ok = (s2) => { for (let a = 0; a < N; a++) for (let b = a + 1; b < N; b++) { const fa = fp(conn[a]), fb = fp(conn[b]); if (Math.abs(C[a][0] - C[b][0]) * s2 < (fa.w + fb.w) / 2 + GAP && Math.abs(C[a][1] - C[b][1]) * s2 < (fa.h + fb.h) / 2 + GAP) return false; } return true; };
      // the scale each unit needs from its tightest neighbor; the overlaps past the chosen quantile are pushed apart below
      const need = conn.map(() => 0);
      for (let a = 0; a < N; a++) for (let b = a + 1; b < N; b++) { const fa = fp(conn[a]), fb = fp(conn[b]); const sx = ((fa.w + fb.w) / 2 + GAP) / Math.max(1, Math.abs(C[a][0] - C[b][0])), sy = ((fa.h + fb.h) / 2 + GAP) / Math.max(1, Math.abs(C[a][1] - C[b][1])); const r = Math.min(sx, sy); need[a] = Math.max(need[a], r); need[b] = Math.max(need[b], r); }
      const sorted = need.slice().sort((a, b) => a - b), q = opts.quantile ?? +(opts.q ?? process.env.Q ?? 0.3);
      let s2 = q >= 1 ? 0.25 : sorted[Math.min(N - 1, Math.floor(q * N))];
      if (q >= 1) while (!ok(s2) && s2 < 20) s2 *= 1.04;
      for (const p of C) { p[0] *= s2; p[1] *= s2; }
    }
    conn.forEach((i, k) => { const f = fp(i); P[i] = [C[k][0] - f.w / 2, C[k][1] - f.h / 2]; });
  }

  // ---- overlaps pushed apart (footprints plus GAP), deterministically ----
  const box = (i, p = P[i], f = fp(i)) => ({ x: p[0], y: p[1], w: f.w, h: f.h });
  const overl = (A, B) => Math.min(A.x + A.w + GAP - B.x, B.x + B.w + GAP - A.x) > 0 && Math.min(A.y + A.h + GAP - B.y, B.y + B.h + GAP - A.y) > 0;
  for (let it = 0; it < 2000; it++) {
    let moved = false;
    const all = prevP ? [...Array(n).keys()] : conn;
    for (let a = 0; a < all.length; a++) for (let b = a + 1; b < all.length; b++) {
      const i = all[a], j = all[b], A = box(i), B = box(j);
      const ox = Math.min(A.x + A.w + GAP - B.x, B.x + B.w + GAP - A.x), oy = Math.min(A.y + A.h + GAP - B.y, B.y + B.h + GAP - A.y);
      if (ox <= 0 || oy <= 0) continue;
      moved = true;
      if (ox * 1.5 < oy) { const s = (A.x + A.w / 2 <= B.x + B.w / 2 ? 1 : -1) * (ox / 2 + 0.5); P[i][0] -= s; P[j][0] += s; }
      else { const s = (A.y + A.h / 2 <= B.y + B.h / 2 ? 1 : -1) * (oy / 2 + 0.5); P[i][1] -= s; P[j][1] += s; }
    }
    if (!moved) break;
  }

  // ---- geometry for the objective ----
  const anchor = (i, key, p = P[i]) => { const o = off(i, key); return [p[0] + o[0], p[1] + o[1]]; };
  // a unit's obstacles: loose note: its note and its pill block; frame: each member and each pill
  const obsCache = new Map();
  const obstacles = (i, p = P[i]) => {
    const ck = obsCache.get(i);
    if (ck && ck.p === p && ck.s === side[i]) return ck.v;
    const v = obstaclesRaw(i, p);
    obsCache.set(i, { p, s: side[i], v });
    return v;
  };
  const obstaclesRaw = (i, p) => {
    const f = fp(i), out = [];
    if (!f.frame) {
      out.push({ key: U[i], x: p[0] + f.note.dx, y: p[1] + f.note.dy, w: f.note.w, h: f.note.h });
      if (f.pills.length) { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const q of f.pills) { x0 = Math.min(x0, q.dx); y0 = Math.min(y0, q.dy); x1 = Math.max(x1, q.dx + q.w); y1 = Math.max(y1, q.dy + q.h); } out.push({ key: null, x: p[0] + x0, y: p[1] + y0, w: x1 - x0, h: y1 - y0 }); }
    } else {
      for (const [k, b] of Object.entries(f.members)) out.push({ key: k, x: p[0] + b.dx, y: p[1] + b.dy, w: b.w, h: b.h });
      for (const q of f.pills) out.push({ key: null, x: p[0] + q.dx, y: p[1] + q.dy, w: q.w, h: q.h });
    }
    return out;
  };
  const seg = (k) => { const d = E[k]; return [anchor(d.ua, d.a), anchor(d.ub, d.b)]; };
  const cross = (p, q, r, s) => {
    const o = (a, b, c2) => (b[0] - a[0]) * (c2[1] - a[1]) - (b[1] - a[1]) * (c2[0] - a[0]);
    const d1 = o(p, q, r), d2 = o(p, q, s), d3 = o(r, s, p), d4 = o(r, s, q);
    return ((d1 > 0) !== (d2 > 0)) && ((d3 > 0) !== (d4 > 0)) && d1 * d2 < 0 && d3 * d4 < 0;
  };
  const hits = (p, q, b, pad = 8) => {
    const x0 = b.x - pad, x1 = b.x + b.w + pad, y0 = b.y - pad, y1 = b.y + b.h + pad;
    let t0 = 0, t1 = 1; const dx = q[0] - p[0], dy = q[1] - p[1];
    const cl = (pp, qq) => { if (pp === 0) return qq >= 0; const r = qq / pp; if (pp < 0) { if (r > t1) return false; if (r > t0) t0 = r; } else { if (r < t0) return false; if (r < t1) t1 = r; } return true; };
    return cl(-dx, p[0] - x0) && cl(dx, x1 - p[0]) && cl(-dy, p[1] - y0) && cl(dy, y1 - p[1]) && t1 - t0 > 1e-9;
  };
  const shares = (k, l) => { const a = E[k], b = E[l]; return a.a === b.a || a.a === b.b || a.b === b.a || a.b === b.b; };
  // the part of the cost that touches unit i (its arrows against everything, everyone's arrows against its obstacles, its overlaps)
  const local = (i) => {
    let cost = 0;
    const mine = new Set(inc[i]);
    const S = E.map((_, k) => seg(k));
    for (const k of inc[i]) {
      const [p, q] = S[k];
      for (let l = 0; l < E.length; l++) { if (l === k || shares(k, l) || (mine.has(l) && l < k)) continue; if (cross(p, q, S[l][0], S[l][1])) cost += W.cross; }
      for (let j = 0; j < n; j++) for (const o of obstacles(j)) { if (o.key === E[k].a || o.key === E[k].b) continue; if (hits(p, q, o)) cost += W.over; }
      const dx = q[0] - p[0], dy = q[1] - p[1];
      const len = Math.hypot(dx, dy);
      cost += W.len * len;
      if (opts.v3 && len > LONG) cost += 6 * (len - LONG);
      if (Math.abs(dx) < 2 || Math.abs(dy) < 2) cost -= W.align;
      // stars3: a pill block on the side its own note's arrows leave by
      if (opts.v3) for (const [u, key, ox, oy] of [[E[k].ua, E[k].a, q[0] - p[0], q[1] - p[1]], [E[k].ub, E[k].b, p[0] - q[0], p[1] - q[1]]]) {
        const f = fp(u); if (f.frame || !f.pills.length) continue;
        const dir = Math.abs(ox) > Math.abs(oy) ? (ox > 0 ? 'right' : 'left') : (oy > 0 ? 'below' : 'above');
        if (dir === side[u]) cost += 300;
      }
    }
    const mo = obstacles(i);
    for (let l = 0; l < E.length; l++) { if (mine.has(l)) continue; const [p, q] = S[l]; for (const o of mo) { if (o.key === E[l].a || o.key === E[l].b) continue; if (hits(p, q, o)) cost += W.over; } }
    return cost;
  };
  const free = (i, p, f = fp(i)) => { const A = { x: p[0], y: p[1], w: f.w, h: f.h }; for (let j = 0; j < n; j++) if (j !== i && P[j] && overl(A, box(j))) return false; return true; };

  // ---- units with no arrow: a shelf under the rest ----
  const TAB0 = 0;
  const placedB2 = (set) => { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const i of set) { const b = box(i); x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); } return { x0, y0, x1, y1 }; };
  const freeP = (i, p, set) => { const f = fp(i), A = { x: p[0], y: p[1], w: f.w, h: f.h }; for (const j of set) if (j !== i && P[j] && overl(A, box(j))) return false; return true; };
  const placedB = () => { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const i of conn) { const b = box(i); x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); } return conn.length ? { x0, y0, x1, y1 } : { x0: 0, y0: 0, x1: 1200, y1: -GAP * 2 }; };
  const lone = [...Array(n).keys()].filter((i) => !linked[i]);
  // stars3: a loose note (every arrow cut) right beside the unit it has most edges with, where it's free and no arrow passes; the rest in
  // a tight grid along the short side of what's placed
  const loneLinks = U.map(() => new Map());
  for (const p of c.pills) { const a = ix.get(g.unitOf(p.user)), b = p.for != null ? ix.get(g.unitOf(p.for)) : null; if (a == null || b == null || a === b) continue; loneLinks[a].set(b, (loneLinks[a].get(b) || 0) + 1); loneLinks[b].set(a, (loneLinks[b].get(a) || 0) + 1); }
  const clearOfArrows = (i, p) => { for (const o of obstaclesRaw(i, p)) for (let k = 0; k < E.length; k++) { if (!P[E[k].ua] || !P[E[k].ub]) continue; const S2 = seg(k); if (hits(S2[0], S2[1], o, 24)) return false; } return true; };
  const shelf = () => {
    if (!lone.length) return;
    if (opts.v3) {
      const placed = new Set(conn), rest = [];
      const order = lone.slice().sort((a, b) => loneLinks[b].size - loneLinks[a].size || a - b);
      for (const i of order) { P[i] = null; }
      for (const i of order) {
        const f = fp(i), nb = [...loneLinks[i].entries()].filter(([j]) => placed.has(j)).sort((x, y) => y[1] - x[1] || x[0] - y[0]);
        let bestP = null, bestV = Infinity;
        const pb0 = placed.size ? placedB2(placed) : null;
        for (const [j] of nb.slice(0, 2)) {
          const B = box(j);
          const xs = [B.x - f.w - GAP - 1, B.x, B.x + (B.w - f.w) / 2, B.x + B.w - f.w, B.x + B.w + GAP + 1], ys = [B.y - f.h - GAP - 1, B.y, B.y + (B.h - f.h) / 2, B.y + B.h - f.h, B.y + B.h + GAP + 1];
          for (const x of xs) for (const y of ys) {
            const p = [Math.round(x), Math.round(y)];
            if (!freeP(i, p, placed) || !clearOfArrows(i, p)) continue;
            const x0 = Math.min(pb0.x0, p[0]), y0 = Math.min(pb0.y0, p[1]), x1 = Math.max(pb0.x1, p[0] + f.w), y1 = Math.max(pb0.y1, p[1] + f.h);
            const w = x1 - x0, h = y1 - y0, v = w * h * (1 + 0.5 * Math.abs(Math.log(w / h / 1.5))) + Math.hypot(p[0] + f.w / 2 - B.x - B.w / 2, p[1] + f.h / 2 - B.y - B.h / 2);
            if (v < bestV - 1e-6) { bestV = v; bestP = p; }
          }
        }
        if (bestP && bestV <= ((pb0.x1 - pb0.x0) * (pb0.y1 - pb0.y0) * (1 + 0.5 * Math.abs(Math.log((pb0.x1 - pb0.x0) / Math.max(1, pb0.y1 - pb0.y0) / 1.5)))) * 1.08 + 4 * (f.w + GAP) * (f.h + GAP)) { P[i] = bestP; placed.add(i); }
        else rest.push(i);
      }
      if (!rest.length) return;
      const pb = placed.size ? placedB2(placed) : { x0: 0, y0: 0, x1: 1200, y1: -GAP * 2 };
      const W2 = pb.x1 - pb.x0, H2 = pb.y1 - pb.y0;
      const areaR = rest.reduce((s, i) => s + (fp(i).w + GAP) * (fp(i).h + GAP), 0);
      if (placed.size && W2 > 1.5 * H2) {
        // a grid down the right side, as tall as what's placed
        const height = Math.max(H2, Math.sqrt(areaR / 1.5));
        let x = pb.x1 + GAP * 2, y = pb.y0, cw = 0;
        for (const i of rest) { const f = fp(i); if (y > pb.y0 && y + f.h > pb.y0 + height) { y = pb.y0; x += cw + GAP; cw = 0; } P[i] = [x, y + TAB0]; y += f.h + GAP + TAB0; cw = Math.max(cw, f.w); }
      } else {
        const width = Math.max(W2, Math.sqrt(areaR * 1.5));
        let x = pb.x0, y = pb.y1 + GAP * 2, rh = 0;
        for (const i of rest) { const f = fp(i); if (x > pb.x0 && x + f.w > pb.x0 + width) { x = pb.x0; y += rh + GAP; rh = 0; } P[i] = [x, y]; x += f.w + GAP; rh = Math.max(rh, f.h); }
      }
      return;
    }
    const pb = placedB(), width = Math.max(pb.x1 - pb.x0, Math.sqrt(lone.reduce((s, i) => s + (fp(i).w + GAP) * (fp(i).h + GAP), 0) * 1.5));
    let x = pb.x0, y = pb.y1 + GAP * 2, rh = 0;
    for (const i of lone) { const f = fp(i); if (x > pb.x0 && x + f.w > pb.x0 + width) { x = pb.x0; y += rh + GAP; rh = 0; } P[i] = [x, y]; x += f.w + GAP; rh = Math.max(rh, f.h); }
  };
  if (!prevP) shelf();

  // ---- local search: moves, aligning with a neighbor, pill sides ----
  const STEP = 40, snap = (v) => Math.round(v / STEP) * STEP * 0 + Math.round(v);
  const bbArea = () => { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (let i = 0; i < n; i++) { const b = box(i); x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); } const w = x1 - x0, h = y1 - y0; return w * h + 0.4 * Math.pow(Math.max(0, h * 1.5 - w), 2) + 0.4 * Math.pow(Math.max(0, w - h * 1.8), 2); };
  const total = (i) => local(i) + W.area * bbArea();
  const search = (sweeps) => { for (let sw = 0; sw < sweeps; sw++) {
    let improved = 0;
    for (const i of conn) {
      let best = total(i), bestP = P[i], bestS = side[i];
      const orig = P[i], origS = side[i];
      const cands = [];
      for (const s of [1, 2, 4, 7]) for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]) cands.push([orig[0] + dx * s * STEP, orig[1] + dy * s * STEP, origS]);
      // line up with a neighbor (same row or same column of centers)
      for (const k of inc[i]) {
        const d = E[k], mineKey = d.ua === i ? d.a : d.b, other = d.ua === i ? d.b : d.a, j = d.ua === i ? d.ub : d.ua;
        if (j === i) continue;
        const o = off(i, mineKey), t = anchor(j, other);
        cands.push([orig[0], t[1] - o[1], origS], [t[0] - o[0], orig[1], origS]);
      }
      // the barycenter of its neighbors
      if (inc[i].length) { let sx = 0, sy = 0, c2 = 0; for (const k of inc[i]) { const d = E[k], j = d.ua === i ? d.ub : d.ua; if (j === i) continue; const t = anchor(j, d.ua === i ? d.b : d.a); sx += t[0]; sy += t[1]; c2++; } if (c2) { const f = fp(i); for (const r of [0, 1, 2, 3]) for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) cands.push([sx / c2 - f.w / 2 + dx * r * 120, sy / c2 - f.h / 2 + dy * r * 120, origS]); } }
      // stars2: right up against a neighbor's footprint (8 spots round it), so a note with few arrows sits next to what it uses
      if (opts.abut === true && inc[i].length <= 3) { const f = fp(i); for (const k of inc[i]) { const d = E[k], j = d.ua === i ? d.ub : d.ua; if (j === i) continue; const B = box(j); const xs = [B.x - f.w - GAP - 1, B.x + (B.w - f.w) / 2, B.x + B.w + GAP + 1], ys = [B.y - f.h - GAP - 1, B.y + (B.h - f.h) / 2, B.y + B.h + GAP + 1]; for (const x of xs) for (const y of ys) cands.push([x, y, origS]); } }
      if (opts.v3) {
        const f = fp(i);
        for (const j of heaviest(i, 2)) { if (!P[j]) continue; const B = box(j); const xs = [B.x - f.w - GAP - 1, B.x + (B.w - f.w) / 2, B.x + B.w + GAP + 1, B.x, B.x + B.w - f.w], ys = [B.y - f.h - GAP - 1, B.y + (B.h - f.h) / 2, B.y + B.h + GAP + 1, B.y, B.y + B.h - f.h]; for (const x of xs) for (const y of ys) cands.push([x, y, origS]); }
        // a frame: flush with the side of the rest of the board nearest the centroid of what it connects to, beside it
        if (f.frame && inc[i].length) {
          let sx = 0, sy = 0, c2 = 0; for (const k of inc[i]) { const d = E[k], j = d.ua === i ? d.ub : d.ua; if (j === i) continue; const t = anchor(j, d.ua === i ? d.b : d.a); sx += t[0]; sy += t[1]; c2++; }
          if (c2) { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const j of conn) { if (j === i) continue; const b = box(j); x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); }
            const cx = sx / c2, cy = sy / c2;
            if (x0 < Infinity) for (const t of [0, 0.5, 1]) { const ax = cx - f.w / 2 + (t - 0.5) * f.w * 0.6, ay = cy - f.h / 2 + (t - 0.5) * f.h * 0.6; cands.push([x0 - f.w - GAP - 1, ay, origS], [x1 + GAP + 1, ay, origS], [ax, y0 - f.h - GAP - 1, origS], [ax, y1 + GAP + 1, origS]); } }
        }
      }
      if (!fp(i).frame) for (const s of SIDES) if (s !== origS) cands.push([orig[0], orig[1], s]);
      // toward the middle of the board
      { const bb = placedB(), mxc = (bb.x0 + bb.x1) / 2, myc = (bb.y0 + bb.y1) / 2, f = fp(i), cx = orig[0] + f.w / 2, cy = orig[1] + f.h / 2; for (const t of [0.1, 0.2, 0.35, 0.5]) cands.push([orig[0] + (mxc - cx) * t, orig[1] + (myc - cy) * t, origS], [orig[0] + (mxc - cx) * t, orig[1], origS], [orig[0], orig[1] + (myc - cy) * t, origS]); }
      for (const [x, y, s] of cands) {
        side[i] = s;
        const p = [snap(x), snap(y)];
        if (!free(i, p)) { side[i] = origS; continue; }
        P[i] = p;
        const v = total(i);
        if (v < best - 0.5) { best = v; bestP = p; bestS = s; }
        P[i] = orig; side[i] = origS;
      }
      if (bestP !== orig || bestS !== origS) { P[i] = bestP; side[i] = bestS; improved++; }
    }
    // the whole board: each unit tried on a lattice, and swapped with every other
    if (opts.global !== false) for (const i of conn) {
      const bb = placedB(), fi = fp(i), orig = P[i];
      let best = total(i), bestP = orig;
      const LS = Math.max(100, Math.round(Math.sqrt((bb.x1 - bb.x0) * (bb.y1 - bb.y0) / 500)));
      for (let y = bb.y0 - 2 * LS; y <= bb.y1 + LS; y += LS) for (let x = bb.x0 - 2 * LS; x <= bb.x1 + LS; x += LS) {
        const p = [x, y];
        if (!free(i, p)) continue;
        P[i] = p; const v = total(i); if (v < best - 0.5) { best = v; bestP = p; } P[i] = orig;
      }
      if (bestP !== orig) { P[i] = bestP; improved++; continue; }
      for (const j of conn) {
        if (j <= i) continue;
        const pi = P[i], pj = P[j], fj = fp(j);
        const before = total(i) + local(j);
        const ci = [pi[0] + fi.w / 2, pi[1] + fi.h / 2], cj = [pj[0] + fj.w / 2, pj[1] + fj.h / 2];
        const ni = [cj[0] - fi.w / 2, cj[1] - fi.h / 2], nj = [ci[0] - fj.w / 2, ci[1] - fj.h / 2];
        P[i] = ni; P[j] = nj;
        if (free(i, ni) && free(j, nj)) { const v = total(i) + local(j); if (v < before - 0.5) { improved++; continue; } }
        P[i] = pi; P[j] = pj;
      }
    }
    if (process.env.DBG) console.error("sweep", sw, improved);
    if (!improved) break;
  } };
  search(opts.sweeps ?? 14);
  // close the gaps: slide every unit left, then up, as far as the units already slid that share its rows (or columns) allow; the order
  // across stays as it was, so a drawing mostly keeps no crossing, and the search after mends what it broke
  const compact = (ax) => {
    const o = conn.slice().sort((a, b) => P[a][ax] - P[b][ax] || a - b), done = [];
    const lo = Math.min(...conn.map((i) => P[i][ax]));
    for (const i of o) {
      const A = box(i);
      let v = lo;
      for (const j of done) { const B = box(j); const lap = ax === 0 ? (A.y < B.y + B.h + GAP && B.y < A.y + A.h + GAP) : (A.x < B.x + B.w + GAP && B.x < A.x + A.w + GAP); if (lap) v = Math.max(v, ax === 0 ? B.x + B.w + GAP : B.y + B.h + GAP); }
      const orig = P[i], before = local(i);
      if (v < orig[ax]) for (const t of [1, 0.75, 0.5, 0.25]) {
        const p = orig.slice(); p[ax] = orig[ax] + (v - orig[ax]) * t; P[i] = p;
        if (!free(i, p) || ((opts.cmode || process.env.CMODE) !== "free" && local(i) > before + +(opts.slack ?? process.env.SLACK ?? 1000))) P[i] = orig; else break;
      }
      done.push(i);
    }
  };
  if (opts.compact ?? (process.env.COMPACT !== '0')) { compact(0); compact(1); search(8); }
  shelf();

  if (process.env.DBG) { let cr = 0, ov = 0; const S = E.map((_, k) => seg(k)); for (let k = 0; k < E.length; k++) { for (let l = k + 1; l < E.length; l++) if (!shares(k, l) && cross(S[k][0], S[k][1], S[l][0], S[l][1])) cr++; for (let j = 0; j < n; j++) for (const o of obstacles(j)) if (o.key !== E[k].a && o.key !== E[k].b && hits(S[k][0], S[k][1], o)) ov++; } console.error(board, 'straight crossings', cr, 'overs', ov); }
  // ---- out ----
  let x0 = Infinity, y0 = Infinity; for (let i = 0; i < n; i++) { x0 = Math.min(x0, P[i][0]); y0 = Math.min(y0, P[i][1]); }
  const at = new Map(U.map((u, i) => [u, { x: Math.round(P[i][0] - x0), y: Math.round(P[i][1] - y0) }]));
  const sides = new Map(U.map((u, i) => [u, side[i]]));
  const f = footprints(m, g, c, sides);
  const layout = assemble(m, g, c, f, at);
  return { layout, P, side, at, sides };
}
