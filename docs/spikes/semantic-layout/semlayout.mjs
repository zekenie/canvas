// The spike: every board drawn with all its links as arrows first, laid out by a force model (links are springs, shapes push apart).
// Where arrows cross or run over shapes, the springs there take their stiffness from how alike the two notes are, and the least alike
// crowded link is broken into a reference pill; the board settles again, until nothing is crowded. A link that crosses a container
// (another board, or in or out of a frame) is a reference from the start. References are light: a pill rides in its note's strip
// (this branch's stripAlts) and pushes on nothing but its own footprint.
//
//   node semlayout.mjs --order=sem|struct --sim=mix|contextual|tfidf|sentence --out=DIR
//   sem: the least similar crowded link breaks first. struct (the control): the most crowded link breaks first, no similarity anywhere.
import fs from 'fs';
import { loadSim } from './sim.mjs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges, pillKey } = await import(TOOL + 'sizes.mjs');
const { stripAlts } = await import(TOOL + 'strips.mjs');
const { arrowBetween, segCross, segHitsBox } = await import(TOOL + 'geom.mjs');

const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const ORDER = args.order || 'sem', SIM = args.sim || 'mix', OUT = args.out || 'out-' + ORDER + '-' + SIM;
const P = {
  gap: 80,        // the least gap between two footprints
  arrowGap: 160,  // the gap an arrow's spring wants between its notes
  rep: 0.02, grav: 0.02, spring: 0.1, push: 0.5,
  iters: 400, warm: 160, t0: 400, tmin: 1,
  refK: 0.05,     // a reference's spring, against an arrow's 1
  floor: 0.15,    // the stiffness of the least similar spring where it's crowded
  batch: 0.1,     // the share of crowded links broken each round (at least one)
  rounds: 80,
  corr: 0.3,     // how hard a shape is pushed out of an arrow's way
  margin: 24,    // the room kept between an arrow and a shape it passes
};
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const graph = rd('./data/graph.json'), measure = rd('./data/measure.json'), kinds = rd('./data/kinds.json');
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const sizes = sizesFrom(model, measure), K = sizes.constants;
const node = (k) => model.node(k);
const cont = (k) => node(k).container;                  // 'b:board' or 'f:frame'
const isFrame = (k) => node(k).holds === 'shapes';
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// ---- containers, items, links ----
const keys = graph.nodes.map((n) => n.key).filter((k) => node(k)).sort(byKey);
const kids = new Map();
for (const k of keys) { const c = cont(k); if (!kids.has(c)) kids.set(c, []); kids.get(c).push(k); }
const chain = (k) => { const out = []; let item = k; for (;;) { const c = cont(item); out.push([c, item]); if (c[0] === 'b') return out; item = c.slice(2); } };
const C = new Map();   // container id -> { items, pairs: Map pairKey -> pair, refs: Map pairKey -> weight }
const box = (id) => { if (!C.has(id)) C.set(id, { id, items: kids.get(id) || [], pairs: new Map(), refs: new Map() }); return C.get(id); };
const pillsOf = new Map();   // host -> Set of targets it shows as pills (in the host's container)
const addPill = (h, t) => { if (!pillsOf.has(h)) pillsOf.set(h, new Set()); pillsOf.get(h).add(t); };
const delPill = (h, t) => { const s = pillsOf.get(h); if (s) s.delete(t); };
const seen = new Set(), edges = [];
for (const e of graph.edges) {
  if (!node(e.from) || !node(e.to) || e.from === e.to) continue;
  const id = e.from + '\u0000' + e.to; if (seen.has(id)) continue; seen.add(id); edges.push(e);
}
for (const e of edges) {
  const u = e.from, v = e.to, cu = cont(u), cv = cont(v);
  if (cu === cv) {
    const X = box(cu), pk = [u, v].sort(byKey).join('\u0000');
    if (!X.pairs.has(pk)) X.pairs.set(pk, { key: pk, a: [u, v].sort(byKey)[0], b: [u, v].sort(byKey)[1], dirs: [], broken: false });
    X.pairs.get(pk).dirs.push([u, v]);
    continue;
  }
  addPill(u, v);
  if (node(u).board !== node(v).board) continue;
  // a light spring where the two ends' containers meet, so a frame sits near what its members reach
  const cvs = new Map(chain(v)), at = chain(u).find(([c]) => cvs.has(c));
  if (!at) continue;
  const [c, iu] = at, iv = cvs.get(c);
  if (iu === iv) continue;
  const X = box(c), pk = [iu, iv].sort(byKey).join('\u0000');
  X.refs.set(pk, Math.min(0.3, (X.refs.get(pk) || 0) + P.refK));
}

// ---- similarity: ranks within a container decide, so only the order of the scores matters ----
const sims = Object.fromEntries(['contextual', 'tfidf', 'sentence'].map((m) => [m, loadSim(m)]));
const allPairs = [...C.values()].flatMap((X) => [...X.pairs.values()]);
function zFor(f) { const v = allPairs.map((p) => f(p.a, p.b)); const mu = v.reduce((a, b) => a + b, 0) / v.length; const sd = Math.sqrt(v.reduce((a, b) => a + (b - mu) ** 2, 0) / v.length) || 1; return (a, b) => (f(a, b) - mu) / sd; }
const simOf = SIM === 'mix' ? (() => { const zc = zFor(sims.contextual), zt = zFor(sims.tfidf); return (a, b) => zc(a, b) + zt(a, b); })() : sims[SIM];
for (const X of C.values()) {
  const ps = [...X.pairs.values()];
  for (const p of ps) p.sim = simOf(p.a, p.b);
  const sorted = [...ps].sort((x, y) => x.sim - y.sim || byKey(x.key, y.key));
  sorted.forEach((p, i) => { p.rank = sorted.length > 1 ? i / (sorted.length - 1) : 1; });
  // --simk=all: every spring as stiff as its two notes are alike, crowded or not
  if (args.simk === 'all' && ORDER === 'sem') for (const p of ps) p.k = P.floor + (1 - P.floor) * p.rank;
  // --precut=density: where a container has more than 1.5 links a shape, its least alike links are references before anything is drawn
  if (args.precut === 'density') {
    const budget = Math.floor(1.5 * X.items.length);
    const order = ORDER === 'sem' ? sorted : [...ps].sort((x, y) => byKey(x.key, y.key));
    for (const p of order.slice(0, Math.max(0, ps.length - budget))) { p.broken = true; p.pre = true; for (const [u, v] of p.dirs) addPill(u, v); }
  }
}

// ---- footprints: a note with its pills' strip (one of stripAlts' arrangements), a frame as laid out, a card ----
const frameBox = new Map();   // frame key -> { w, h, above, at: Map item -> [x, y] of its footprint, relative to the frame's box }
const choice = new Map();     // note key -> the arrangement index it takes
function pillList(k) {
  const t = [...(pillsOf.get(k) || [])];
  // the most similar nearest the note's middle
  t.sort((x, y) => sims.contextual(k, y) - sims.contextual(k, x) || byKey(x, y));
  const c = cont(k);
  return t.map((target) => ({ target, w: sizes.pillWidth[pillKey(target, c)] || sizes.pillWidth[target] || 120 }));
}
function footprint(k) {
  if (isFrame(k)) { const f = frameBox.get(k); return { w: f.w, h: f.h + f.above, nx: 0, ny: f.above, nw: f.w, nh: f.h, pills: [], on: [], mass: Math.sqrt(f.w * f.h) / 300 }; }
  const s = sizes.shapes[k];
  const mass = Math.sqrt(s.w * s.h) / 300;
  const pl = pillList(k);
  if (!pl.length) return { w: s.w, h: s.h + s.above, nx: 0, ny: s.above, nw: s.w, nh: s.h, pills: [], on: [], mass };
  const alts = stripAlts({ w: s.w, h: s.h, above: s.above }, pl.map((p) => ({ w: p.w })), K);
  let i = choice.has(k) ? choice.get(k) : 0;
  if (!alts[i]) i = alts.findIndex(Boolean);
  const a = alts[i];
  return { w: a.w, h: a.h, nx: a.nx, ny: a.ny, nw: a.nw, nh: a.nh, pills: a.pills.map((p, j) => ({ ...p, target: pl[j].target })), on: a.on || [], alts, mass };
}

// ---- the force model ----
function settle(X, F, pos, iters, t0) {
  const n = F.length, ix = new Map(X.items.map((k, i) => [k, i]));
  const springs = [];
  for (const p of X.pairs.values()) if (!p.broken) springs.push([ix.get(p.a), ix.get(p.b), p.k == null ? 1 : p.k, true]);
  for (const [pk, w] of X.refs) { const [a, b] = pk.split('\u0000'); const pair = X.pairs.get(pk); if (!pair || pair.broken) springs.push([ix.get(a), ix.get(b), w, false]); }
  for (const p of X.pairs.values()) if (p.broken) springs.push([ix.get(p.a), ix.get(p.b), P.refK, false]);
  for (let t = 0; t < iters; t++) {
    const temp = t0 * (1 - t / iters) + P.tmin, fx = new Float64Array(n), fy = new Float64Array(n);
    let mx = 0, my = 0;
    for (let i = 0; i < n; i++) { mx += pos[i][0] / n; my += pos[i][1] / n; }
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) {
      let dx = pos[j][0] - pos[i][0], dy = pos[j][1] - pos[i][1];
      if (dx === 0 && dy === 0) { dx = (j - i) * 0.01; dy = 0.01; }
      const d = Math.sqrt(dx * dx + dy * dy), ux = dx / d, uy = dy / d;
      const gx = Math.abs(dx) - (F[i].w + F[j].w) / 2, gy = Math.abs(dy) - (F[i].h + F[j].h) / 2;
      const gap = gx > 0 && gy > 0 ? Math.sqrt(gx * gx + gy * gy) : Math.max(gx, gy);
      let f = P.rep * 90000 * F[i].mass * F[j].mass / Math.max(d, 1);
      if (gap < P.gap) f += P.push * (P.gap - gap);
      fx[i] -= f * ux; fy[i] -= f * uy; fx[j] += f * ux; fy[j] += f * uy;
    }
    for (const [i, j, k] of springs) {
      const A = noteBox(F[i], pos[i]), B = noteBox(F[j], pos[j]);
      const dx = (B.x + B.w / 2) - (A.x + A.w / 2), dy = (B.y + B.h / 2) - (A.y + A.h / 2), d = Math.sqrt(dx * dx + dy * dy) || 1;
      const gx = Math.abs(dx) - (A.w + B.w) / 2, gy = Math.abs(dy) - (A.h + B.h) / 2;
      const gap = gx > 0 && gy > 0 ? Math.sqrt(gx * gx + gy * gy) : Math.max(gx, gy);
      if (gap <= P.arrowGap) continue;
      const f = P.spring * k * (gap - P.arrowGap) / 2;
      fx[i] += f * dx / d; fy[i] += f * dy / d; fx[j] -= f * dx / d; fy[j] -= f * dy / d;
    }
    for (const [i, j, , arrow] of springs) {
      if (!arrow) continue;
      const A = noteBox(F[i], pos[i]), B = noteBox(F[j], pos[j]);
      const ax = A.x + A.w / 2, ay = A.y + A.h / 2, bx = B.x + B.w / 2, by = B.y + B.h / 2, lx = bx - ax, ly = by - ay;
      const L2 = lx * lx + ly * ly; if (L2 < 1) continue;
      const Ln = Math.sqrt(L2), nx = -ly / Ln, ny = lx / Ln;
      for (let k = 0; k < n; k++) {
        if (k === i || k === j) continue;
        const cx = pos[k][0], cy = pos[k][1], t = ((cx - ax) * lx + (cy - ay) * ly) / L2;
        if (t <= 0 || t >= 1) continue;
        const side = (cx - ax) * nx + (cy - ay) * ny, r = Math.abs(nx) * F[k].w / 2 + Math.abs(ny) * F[k].h / 2 + P.margin;
        const dist = Math.abs(side);
        if (dist >= r) continue;
        const sg = side > 0 || (side === 0 && k % 2 === 0) ? 1 : -1, f = P.corr * (r - dist);
        fx[k] += sg * nx * f; fy[k] += sg * ny * f;
        fx[i] -= sg * nx * f / 2; fy[i] -= sg * ny * f / 2; fx[j] -= sg * nx * f / 2; fy[j] -= sg * ny * f / 2;
      }
    }
    for (let i = 0; i < n; i++) {
      fx[i] -= P.grav * (pos[i][0] - mx); fy[i] -= P.grav * (pos[i][1] - my);
      const m = Math.sqrt(fx[i] * fx[i] + fy[i] * fy[i]), s = m > temp ? temp / m : 1;
      pos[i][0] += fx[i] * s; pos[i][1] += fy[i] * s;
    }
  }
  // no footprint on another, the gap kept: push apart along the shorter way out, in key order
  for (let r = 0; r < 200; r++) {
    let moved = false;
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) {
      const dx = pos[j][0] - pos[i][0], dy = pos[j][1] - pos[i][1];
      const ox = (F[i].w + F[j].w) / 2 + P.gap / 2 - Math.abs(dx), oy = (F[i].h + F[j].h) / 2 + P.gap / 2 - Math.abs(dy);
      if (ox <= 0 || oy <= 0) continue;
      moved = true;
      if (ox < oy) { const s = (dx >= 0 ? 1 : -1) * ox / 2; pos[i][0] -= s; pos[j][0] += s; } else { const s = (dy >= 0 ? 1 : -1) * oy / 2; pos[i][1] -= s; pos[j][1] += s; }
    }
    if (!moved) break;
  }
}
function refit(F, F2, pos) { F.forEach((f, i) => { const nb = noteBox(f, pos[i]); pos[i] = [nb.x - F2[i].nx + F2[i].w / 2, nb.y - F2[i].ny + F2[i].h / 2]; }); return F2; }
const noteBox = (f, c) => ({ x: c[0] - f.w / 2 + f.nx, y: c[1] - f.h / 2 + f.ny, w: f.nw, h: f.nh });
const pillBoxes = (f, c) => f.pills.map((p) => ({ x: c[0] - f.w / 2 + p.x, y: c[1] - f.h / 2 + p.y, w: p.w, h: p.h, target: p.target }));

function overlaps(F, pos) {
  for (let i = 0; i < F.length; i++) for (let j = i + 1; j < F.length; j++) {
    if (Math.abs(pos[j][0] - pos[i][0]) < (F[i].w + F[j].w) / 2 + 8 && Math.abs(pos[j][1] - pos[i][1]) < (F[i].h + F[j].h) / 2 + 8) return true;
  }
  return false;
}
// ---- what crowds a container: each arrow's crossings and the shapes it runs over ----
function crowding(X, F, pos) {
  const ix = new Map(X.items.map((k, i) => [k, i]));
  const live = [...X.pairs.values()].filter((p) => !p.broken);
  const segs = live.map((p) => ({ p, i: ix.get(p.a), j: ix.get(p.b), s: arrowBetween(noteBox(F[ix.get(p.a)], pos[ix.get(p.a)]), noteBox(F[ix.get(p.b)], pos[ix.get(p.b)])) }));
  const obstacles = [], pillLines = [];
  F.forEach((f, i) => {
    const nb = noteBox(f, pos[i]);
    obstacles.push({ i, b: nb, own: true });
    // --light: a reference blocks nothing (the user's "references count less"): its pill takes room but a line may cross it
    if (!args.light) for (const pb of pillBoxes(f, pos[i])) { obstacles.push({ i, b: pb, own: false }); pillLines.push({ i, s: arrowBetween(nb, pb) }); }
  });
  for (const a of segs) {
    let c = 0;
    for (const b of segs) if (a !== b && a.i !== b.i && a.i !== b.j && a.j !== b.i && a.j !== b.j && segCross(a.s, b.s)) c++;
    for (const l of pillLines) if (l.i !== a.i && l.i !== a.j && segCross(a.s, l.s)) c++;
    for (const o of obstacles) if (!(o.own && (o.i === a.i || o.i === a.j)) && segHitsBox(a.s, o.b, 1)) { c++; if (args.debug) (a.why = a.why || []).push((o.own ? 'shape ' : 'pill of ') + X.items[o.i] + (o.i === a.i || o.i === a.j ? ' (an end)' : '')); }
    a.p.crowd = c;
  }
  return segs;
}

// each note takes the arrangement of its pills that the board's arrows run over least (its own and the others'), then the one with
// fewest of its own lines over its pills, then the smallest; its note stays where it is
function arrange(X, F, pos) {
  const ix = new Map(X.items.map((k, i) => [k, i]));
  const segs = [];
  for (const p of X.pairs.values()) {
    if (p.broken) continue;
    const i = ix.get(p.a), j = ix.get(p.b);
    segs.push({ i, j, s: arrowBetween(noteBox(F[i], pos[i]), noteBox(F[j], pos[j])) });
  }
  let changed = false;
  X.items.forEach((k, i) => {
    const f = F[i];
    if (!f.alts) return;
    const nb = noteBox(f, pos[i]);
    let best = -1, bestCost = Infinity;
    f.alts.forEach((a, ai) => {
      if (!a) return;
      let hits = 0;
      for (const p of a.pills) {
        const pb = { x: nb.x - a.nx + p.x, y: nb.y - a.ny + p.y, w: p.w, h: p.h };
        for (const sg of segs) if (segHitsBox(sg.s, pb, -4)) hits++;
      }
      const cost = hits * 1e6 + (a.own || 0) * 1e4 + a.w * a.h;
      if (cost < bestCost) { bestCost = cost; best = ai; }
    });
    if (best >= 0 && best !== (choice.has(k) ? choice.get(k) : 0)) { choice.set(k, best); changed = true; }
  });
  return changed;
}
function sideOf(b, x, y) {
  const d = [['left', Math.abs(x - b.x)], ['right', Math.abs(x - b.x - b.w)], ['above', Math.abs(y - b.y)], ['below', Math.abs(y - b.y - b.h)]];
  return d.reduce((m, e) => (e[1] < m[1] ? e : m))[0];
}

// ---- one container: settle, break the crowded links one batch at a time, settle again; then put back what has room ----
const stats = {};
function layOut(X) {
  const items = X.items, n = items.length;
  if (!n) return;
  let F = items.map(footprint);
  const ix = new Map(items.map((k, i) => [k, i]));
  // start: the most linked first, breadth first along arrows, on a snake grid
  const adj = items.map(() => []);
  for (const p of X.pairs.values()) { adj[ix.get(p.a)].push(ix.get(p.b)); adj[ix.get(p.b)].push(ix.get(p.a)); }
  const order = [], seenI = new Array(n).fill(false);
  const byDeg = [...Array(n).keys()].sort((a, b) => adj[b].length - adj[a].length || byKey(items[a], items[b]));
  for (const s of byDeg) { if (seenI[s]) continue; const q = [s]; seenI[s] = true; while (q.length) { const x = q.shift(); order.push(x); for (const y of [...adj[x]].sort((a, b) => byKey(items[a], items[b]))) if (!seenI[y]) { seenI[y] = true; q.push(y); } } }
  const cols = Math.ceil(Math.sqrt(n)), cw = Math.max(...F.map((f) => f.w)) + P.gap, ch = Math.max(...F.map((f) => f.h)) + P.gap;
  const pos = new Array(n);
  order.forEach((i, r) => { const row = Math.floor(r / cols), col = r % cols; pos[i] = [(row % 2 ? cols - 1 - col : col) * cw, row * ch]; });
  const st = { items: n, links: X.pairs.size, broken: [...X.pairs.values()].filter((p) => p.pre).length, putBack: 0, rounds: 0, crowdedLeft: 0, lastBrokenRank: null };
  settle(X, F, pos, P.iters, P.t0);
  for (let round = 0; round < P.rounds; round++) {
    if (arrange(X, F, pos)) { F = refit(F, items.map(footprint), pos); settle(X, F, pos, P.warm, P.t0 / 4); }
    const segs = crowding(X, F, pos);
    const bad = segs.filter((s) => s.p.crowd > 0).map((s) => s.p);
    st.rounds = round + 1;
    if (args.debug && X.id === args.debug && bad.length <= 3) for (const sg of segs.filter((s) => s.p.crowd > 0)) console.log('round', round, sg.p.key.replace('\u0000', ' <> '), 'crowd', sg.p.crowd, JSON.stringify(sg.why || []).slice(0, 400));
    if (!bad.length) break;
    // where it's crowded, a spring is as stiff as its two notes are alike
    if (ORDER === 'sem') {
      const near = new Set(bad.flatMap((p) => [p.a, p.b]));
      for (const p of X.pairs.values()) if (near.has(p.a) || near.has(p.b)) p.k = P.floor + (1 - P.floor) * p.rank;
    }
    bad.sort(ORDER === 'sem' ? (x, y) => x.sim - y.sim || byKey(x.key, y.key) : (x, y) => y.crowd - x.crowd || byKey(x.key, y.key));
    const take = Math.max(1, Math.ceil(bad.length * P.batch));
    for (const p of bad.slice(0, take)) { p.broken = true; st.broken++; st.lastBrokenRank = p.rank; for (const [u, v] of p.dirs) addPill(u, v); }
    F = refit(F, items.map(footprint), pos);
    settle(X, F, pos, P.warm, P.t0 / 4);
  }
  // put back: a broken link becomes an arrow again where its line has room (the most similar first; the control: the shortest first)
  const segsNow = () => crowding(X, F, pos);
  segsNow();
  const back = [...X.pairs.values()].filter((p) => p.broken && !p.pre);   // a link cut by meaning stays a reference
  const lenOf = (p) => { const s = arrowBetween(noteBox(F[ix.get(p.a)], pos[ix.get(p.a)]), noteBox(F[ix.get(p.b)], pos[ix.get(p.b)])); return Math.sqrt((s.x2 - s.x1) ** 2 + (s.y2 - s.y1) ** 2); };
  back.sort(ORDER === 'sem' ? (x, y) => y.sim - x.sim || byKey(x.key, y.key) : (x, y) => lenOf(x) - lenOf(y) || byKey(x.key, y.key));
  for (const p of back) {
    p.broken = false;
    for (const [u, v] of p.dirs) delPill(u, v);
    const pos2 = pos.map((c) => [...c]), F2 = refit(F, items.map(footprint), pos2);
    const segs = crowding(X, F2, pos2);
    if (segs.some((s) => s.p.crowd > 0) || overlaps(F2, pos2)) { p.broken = true; for (const [u, v] of p.dirs) addPill(u, v); crowding(X, F, pos); continue; }
    F = F2; pos2.forEach((c, i) => { pos[i] = c; }); st.putBack++;
  }
  st.crowdedLeft = crowding(X, F, pos).filter((s) => s.p.crowd > 0).length;
  stats[X.id] = st;
  X.F = F; X.pos = pos;
  // the container's own box: its footprints' bounds and the inset
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  F.forEach((f, i) => { x0 = Math.min(x0, pos[i][0] - f.w / 2); y0 = Math.min(y0, pos[i][1] - f.h / 2); x1 = Math.max(x1, pos[i][0] + f.w / 2); y1 = Math.max(y1, pos[i][1] + f.h / 2); });
  X.bounds = { x0, y0, x1, y1 };
  if (X.id[0] === 'f') {
    const k = X.id.slice(2), fs0 = sizes.frames[k] || { min: null, above: 0 }, inset = K.frameInset;
    const min = fs0.min || K.frameMin;
    const w = Math.max(min.w, x1 - x0 + 2 * inset), h = Math.max(min.h, y1 - y0 + 2 * inset);
    frameBox.set(k, { w, h, above: fs0.above || 0, ox: x0 - inset - (w - (x1 - x0 + 2 * inset)) / 2, oy: y0 - inset - (h - (y1 - y0 + 2 * inset)) / 2 });
  }
}

const t0 = Date.now();
for (const id of [...kids.keys()]) box(id);
const ONLY = args.boards ? new Set(args.boards.split(',')) : null;
const onBoard = (id) => !ONLY || ONLY.has(id[0] === 'b' ? id.slice(2) : node(id.slice(2)).board);
// frames before what holds them: the deepest first
const frames = [...C.keys()].filter((id) => id[0] === 'f').sort((a, b) => node(b.slice(2)).frames.length - node(a.slice(2)).frames.length || byKey(a, b));
for (const id of frames) if (onBoard(id)) layOut(C.get(id));
for (const id of [...C.keys()].filter((id) => id[0] === 'b').sort(byKey)) if (onBoard(id)) layOut(C.get(id));
const ms = Date.now() - t0;

// ---- the drawing: the graph, each node placed (in its frame's box where it has one), each link an arrow or a pill ----
const placeOf = new Map(), pillAt = new Map();
for (const X of C.values()) {
  if (!X.F) continue;
  const org = X.id[0] === 'f' ? frameBox.get(X.id.slice(2)) : { ox: X.bounds.x0, oy: X.bounds.y0 };
  X.items.forEach((k, i) => {
    const f = X.F[i], nb = noteBox(f, X.pos[i]);
    placeOf.set(k, { at: [nb.x - org.ox, nb.y - org.oy], size: [nb.w, nb.h] });
    for (const pb of pillBoxes(f, X.pos[i])) pillAt.set(k + '\u0000' + pb.target, { at: [pb.x - org.ox, pb.y - org.oy], ...(X.id[0] === 'f' ? { in: X.id.slice(2) } : {}) });
  });
}
const arrowSet = new Set();
for (const X of C.values()) for (const p of X.pairs.values()) if (!p.broken) for (const [u, v] of p.dirs) arrowSet.add(u + '\u0000' + v);
const drawing = { ...graph, nodes: graph.nodes.map((n) => (placeOf.has(n.key) ? { ...n, place: placeOf.get(n.key) } : n)), edges: graph.edges.map((e) => {
  const id = e.from + '\u0000' + e.to;
  if (arrowSet.has(id)) return e;
  const p = pillAt.get(id);
  return p ? { ...e, place: { pill: p } } : e;
}) };
fs.mkdirSync(new URL('./' + OUT + '/', import.meta.url), { recursive: true });
fs.writeFileSync(new URL('./' + OUT + '/drawing.json', import.meta.url), JSON.stringify(drawing));
fs.writeFileSync(new URL('./' + OUT + '/stats.json', import.meta.url), JSON.stringify({ ms, order: ORDER, sim: SIM, P, stats }, null, 1));
const tot = Object.values(stats).reduce((a, s) => ({ links: a.links + s.links, broken: a.broken + s.broken, putBack: a.putBack + s.putBack, crowdedLeft: a.crowdedLeft + s.crowdedLeft }), { links: 0, broken: 0, putBack: 0, crowdedLeft: 0 });
console.log(JSON.stringify({ order: ORDER, sim: SIM, seconds: ms / 1000, ...tot, arrowsKept: tot.links - tot.broken + tot.putBack }));
