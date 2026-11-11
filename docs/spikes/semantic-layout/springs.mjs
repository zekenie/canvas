// The owner's strategy, built as stated:
//  1. Every board is drawn with all its links as arrows. A link that crosses a container (to another board, or into or out of a
//     frame) is a reference from the start.
//  2. Congested areas come from the graph alone: in each container, the part where every note has at least --core links to others in
//     that part (its k-core). An arrow is congested when both its notes are in that part. Nothing about the picture decides it.
//  3. There, each arrow's spring is as strong as its two notes are alike, relative to the area's other arrows: the most alike pull
//     with the full force, the least alike with --floor of it. Arrows outside congested areas pull with the full force.
//  4. Past a threshold a congested arrow breaks into a reference. Three readings (--break): stretch, where it breaks when stretched
//     past --snap times its area's typical arrow; strength (the default), the same but a more alike arrow holds more, from --sfloor of
//     the limit to all of it; force, where an arrow less alike than --cut is a reference before anything is drawn. Under the first two
//     the most stretched breaks first, one at a time, and the board settles after each break.
//  5. References count for little in the repulsion: a note pushes with its own size plus --refmass of its pills'.
//  Crossings are allowed, and nothing is put back. It is deterministic: no randomness.
//
//   node springs.mjs [--break=strength|stretch|force] [--core=3] [--floor=0.1] [--snap=3] [--sfloor=0.25] [--cut=0] [--refmass=0.25]
//     [--sim=board] [--frames=arrows] [--others=hide] [--boards=module:A,...] [--auc=1] --out=DIR
import fs from 'fs';
import { EMB, loadSim, readVectors } from './sim.mjs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges, pillKey } = await import(TOOL + 'sizes.mjs');
const { stripAlts } = await import(TOOL + 'strips.mjs');
const { arrowBetween, segHitsBox } = await import(TOOL + 'geom.mjs');

const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const OUT = args.out || 'out/springs';
const P = {
  gap: 80,        // the least gap between two footprints
  arrowGap: 160,  // the gap an arrow's spring wants between its notes
  rep: 0.02, grav: 0.02, spring: 0.1, push: 0.5,
  iters: 400, warm: 160, t0: 400, tmin: 1,
  refK: 0.05,     // a reference's own spring, against an arrow's 1
  corr: 0.3,      // how hard a shape is pushed out of an arrow's way
  margin: 24,     // the room kept between an arrow and a shape it passes
  core: +(args.core ?? 3),
  floor: +(args.floor ?? 0.1),
  snap: +(args.snap ?? 3),
  refmass: +(args.refmass ?? 0.25),
  sfloor: +(args.sfloor ?? 0.25),
  cut: +(args.cut ?? 0),
  maxBreaks: 400,
};
// what the threshold is on: stretch (a congested arrow breaks when stretched past --snap times the area's typical arrow), strength
// (it breaks when stretched past what its similarity can hold: --snap times sfloor..1, the least alike to the most), force (the
// force itself: below --cut it is a reference from the start)
const BREAK = args.break || 'strength';
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const graph = rd('./data/graph.json'), measure = rd('./data/measure.json'), kinds = rd('./data/kinds.json');
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const sizes = sizesFrom(model, measure), K = sizes.constants;
const node = (k) => model.node(k);
const cont = (k) => node(k).container;                  // 'b:board' or 'f:frame'
const isFrame = (k) => node(k).holds === 'shapes';
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// ---- 1. containers, items, links: an arrow for every link inside a container, a reference for every link across one ----
const keys = graph.nodes.map((n) => n.key).filter((k) => node(k)).sort(byKey);
const kids = new Map();
for (const k of keys) { const c = cont(k); if (!kids.has(c)) kids.set(c, []); kids.get(c).push(k); }
const chain = (k) => { const out = []; let item = k; for (;;) { const c = cont(item); out.push([c, item]); if (c[0] === 'b') return out; item = c.slice(2); } };
const C = new Map();   // container id -> { items, pairs: Map pairKey -> pair, refs: Map pairKey -> weight }
const box = (id) => { if (!C.has(id)) C.set(id, { id, items: kids.get(id) || [], pairs: new Map(), refs: new Map() }); return C.get(id); };
const pillsOf = new Map();   // host -> Set of targets it shows as pills (in the host's container)
const addPill = (h, t) => { if (!pillsOf.has(h)) pillsOf.set(h, new Set()); pillsOf.get(h).add(t); };
const seen = new Set(), edges = [];
for (const e of graph.edges) {
  if (!node(e.from) || !node(e.to) || e.from === e.to) continue;
  const id = e.from + '\u0000' + e.to; if (seen.has(id)) continue; seen.add(id); edges.push(e);
}
for (const e of edges) {
  const u = e.from, v = e.to, cu = cont(u), cv = cont(v);
  if (cu === cv) {
    const X = box(cu), [a, b] = [u, v].sort(byKey), pk = a + '\u0000' + b;
    if (!X.pairs.has(pk)) X.pairs.set(pk, { key: pk, a, b, dirs: [], broken: false });
    X.pairs.get(pk).dirs.push([u, v]);
    continue;
  }
  // --others=hide: a link to another board is drawn nowhere (as a chip inside the note would be), so it takes no room
  if (node(u).board !== node(v).board) { if (args.others !== 'hide') addPill(u, v); continue; }
  const cvs = new Map(chain(v)), at = chain(u).find(([c]) => cvs.has(c));
  // --frames=arrows (a variant, not the rule as stated): a link into or out of a frame is an arrow, its spring between the two items
  // that hold its ends where their containers meet
  if (args.frames === 'arrows' && at && at[1] !== cvs.get(at[0])) {
    const X = box(at[0]), [a, b] = [at[1], cvs.get(at[0])].sort(byKey), pk = a + '\u0000' + b;
    if (!X.pairs.has(pk)) X.pairs.set(pk, { key: pk, a, b, dirs: [], broken: false, lifted: true });
    X.pairs.get(pk).dirs.push([u, v]);
    continue;
  }
  addPill(u, v);
  // a light spring where the two ends' containers meet, so a frame sits near what its members reach
  if (!at) continue;
  const [c, iu] = at, iv = cvs.get(c);
  if (iu === iv) continue;
  const X = box(c), pk = [iu, iv].sort(byKey).join('\u0000');
  X.refs.set(pk, Math.min(0.3, (X.refs.get(pk) || 0) + P.refK));
}

// ---- similarity: the embedding (EMB: Apple's on-device contextual unless it names another) plus word overlap, each as a z-score over the corpus's arrows ----
const sims = { emb: loadSim(EMB), tfidf: loadSim('tfidf') };
// --sim=board (an adjustment, not the rule as stated): what every note on a board shares is taken out first. The embedding is centred
// on its board's mean rather than the corpus's, and a word counts by how few of its board's notes use it, so a module's own name,
// which runs through all its files, ties nothing together
if (args.sim === 'board') {
  const unit = (v) => { let s = 0; for (const x of v) s += x * x; s = Math.sqrt(s) || 1; return v.map((x) => x / s); };
  const raw = readVectors(EMB);
  const texts = new Map(JSON.parse(fs.readFileSync(new URL('./data/texts.json', import.meta.url), 'utf8')).map((t) => [t.key, t.text]));
  const STOP = new Set('a an the and or of to in on for by with is are be as it its at from that this what which into each one when where how not no but than then so their they them a s t'.split(' '));
  const words = (k) => (texts.get(k) || '').toLowerCase().match(/[a-z][a-z0-9]+/g)?.filter((w) => !STOP.has(w) && w.length > 2) || [];
  const onB = new Map();
  for (const k of keys) { const b = node(k).board; if (!onB.has(b)) onB.set(b, []); onB.get(b).push(k); }
  const vec = new Map(), bag = new Map();
  for (const [, ks] of onB) {
    const have = ks.filter((k) => raw[k]);
    if (have.length) {
      const d = raw[have[0]].length, mean = new Array(d).fill(0);
      for (const k of have) for (let i = 0; i < d; i++) mean[i] += raw[k][i] / have.length;
      for (const k of have) vec.set(k, unit(raw[k].map((x, i) => x - mean[i])));
    }
    const df = new Map(); for (const k of ks) for (const w of new Set(words(k))) df.set(w, (df.get(w) || 0) + 1);
    for (const k of ks) {
      const tf = new Map(); for (const w of words(k)) tf.set(w, (tf.get(w) || 0) + 1);
      const v = new Map(); let s = 0;
      for (const [w, c] of tf) { const x = (1 + Math.log(c)) * Math.log(ks.length / df.get(w)); if (x > 0) { v.set(w, x); s += x * x; } }
      s = Math.sqrt(s) || 1; for (const [w, x] of v) v.set(w, x / s); bag.set(k, v);
    }
  }
  sims.emb = (a, b) => { const x = vec.get(a), y = vec.get(b); if (!x || !y) return 0; let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * y[i]; return s; };
  sims.tfidf = (a, b) => { const x = bag.get(a), y = bag.get(b); if (!x || !y) return 0; let s = 0; const [p, q] = x.size < y.size ? [x, y] : [y, x]; for (const [w, u] of p) { const t = q.get(w); if (t) s += u * t; } return s; };
}
const allPairs = [...C.values()].flatMap((X) => [...X.pairs.values()]);
const endsOf = (p) => (p.lifted ? p.dirs[0] : [p.a, p.b]);
function zFor(f) { const v = allPairs.map((p) => f(...endsOf(p))); const mu = v.reduce((a, b) => a + b, 0) / v.length; const sd = Math.sqrt(v.reduce((a, b) => a + (b - mu) ** 2, 0) / v.length) || 1; return (a, b) => (f(a, b) - mu) / sd; }
const zc = zFor(sims.emb), zt = zFor(sims.tfidf), simOf = (a, b) => zc(a, b) + zt(a, b);
// --auc=1: how well this similarity ranks the judged links (the chance a link both judges keep outranks one both chip), then stop
if (args.auc) {
  const rows = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8'));
  const auc = (f) => { const Kp = rows.filter((r) => r.ja + r.jb >= 3), Ch = rows.filter((r) => r.ja + r.jb === 0); let w = 0; for (const k of Kp) for (const c of Ch) { const a = f(k.a, k.b), b = f(c.a, c.b); w += a > b ? 1 : a === b ? 0.5 : 0; } return +(w / Kp.length / Ch.length).toFixed(2); };
  console.log(JSON.stringify({ sim: args.sim || 'corpus', mix: auc(simOf), emb: EMB, embedding: auc(sims.emb), words: auc(sims.tfidf) }));
  process.exit(0);
}

// ---- 2 and 3. congestion from the graph (k-cores), and each congested spring as strong as its notes are alike ----
function coreNumbers(n, adj) {
  const deg = adj.map((s) => s.size), core = new Array(n).fill(0), done = new Array(n).fill(false);
  let k = 0;
  for (let step = 0; step < n; step++) {
    let best = -1;
    for (let i = 0; i < n; i++) if (!done[i] && (best < 0 || deg[i] < deg[best])) best = i;
    k = Math.max(k, deg[best]); core[best] = k; done[best] = true;
    for (const j of adj[best]) if (!done[j]) deg[j]--;
  }
  return core;
}
for (const X of C.values()) {
  const ps = [...X.pairs.values()], ix = new Map(X.items.map((k, i) => [k, i]));
  const adj = X.items.map(() => new Set());
  for (const p of ps) { adj[ix.get(p.a)].add(ix.get(p.b)); adj[ix.get(p.b)].add(ix.get(p.a)); }
  const core = coreNumbers(X.items.length, adj);
  X.core = new Map(X.items.map((k, i) => [k, core[i]]));
  for (const p of ps) {
    p.sim = p.lifted ? Math.max(...p.dirs.map(([u, v]) => simOf(u, v))) : simOf(p.a, p.b);
    p.congested = core[ix.get(p.a)] >= P.core && core[ix.get(p.b)] >= P.core;
    p.k = 1;
  }
  const cg = ps.filter((p) => p.congested).sort((x, y) => x.sim - y.sim || byKey(x.key, y.key));
  cg.forEach((p, i) => { p.rank = cg.length > 1 ? i / (cg.length - 1) : 1; p.k = P.floor + (1 - P.floor) * p.rank; });
  // --break=force: the threshold is on the force itself: a congested arrow whose two notes are less alike than --cut (the
  // similarity's z-score) is a reference before anything is drawn
  if (BREAK === 'force') for (const p of cg) if (p.sim < P.cut) { p.broken = true; p.pre = true; for (const [u, v] of p.dirs) addPill(u, v); }
}

// ---- footprints: a note with its pills' strip (one of stripAlts' arrangements), a frame as laid out ----
const frameBox = new Map();   // frame key -> { w, h, above, ox, oy }
const choice = new Map();     // note key -> the arrangement index it takes
function pillList(k) {
  const t = [...(pillsOf.get(k) || [])];
  t.sort((x, y) => sims.emb(k, y) - sims.emb(k, x) || byKey(x, y));   // the most alike nearest the note's middle
  const c = cont(k);
  return t.map((target) => ({ target, w: sizes.pillWidth[pillKey(target, c)] || sizes.pillWidth[target] || 120 }));
}
// 5. a note pushes with its own size and a share of its pills'
const massOf = (w, h, pills) => Math.sqrt(w * h + P.refmass * pills.reduce((s, p) => s + p.w * p.h, 0)) / 300;
function footprint(k) {
  if (isFrame(k)) { const f = frameBox.get(k); return { w: f.w, h: f.h + f.above, nx: 0, ny: f.above, nw: f.w, nh: f.h, pills: [], mass: Math.sqrt(f.w * f.h) / 300 }; }
  const s = sizes.shapes[k];
  const pl = pillList(k);
  if (!pl.length) return { w: s.w, h: s.h + s.above, nx: 0, ny: s.above, nw: s.w, nh: s.h, pills: [], mass: massOf(s.w, s.h, []) };
  const alts = stripAlts({ w: s.w, h: s.h, above: s.above }, pl.map((p) => ({ w: p.w })), K);
  let i = choice.has(k) ? choice.get(k) : 0;
  if (!alts[i]) i = alts.findIndex(Boolean);
  const a = alts[i];
  const pills = a.pills.map((p, j) => ({ ...p, target: pl[j].target }));
  return { w: a.w, h: a.h, nx: a.nx, ny: a.ny, nw: a.nw, nh: a.nh, pills, alts, mass: massOf(s.w, s.h, pills) };
}
const noteBox = (f, c) => ({ x: c[0] - f.w / 2 + f.nx, y: c[1] - f.h / 2 + f.ny, w: f.nw, h: f.nh });
const pillBoxes = (f, c) => f.pills.map((p) => ({ x: c[0] - f.w / 2 + p.x, y: c[1] - f.h / 2 + p.y, w: p.w, h: p.h, target: p.target }));
function refit(F, F2, pos) { F.forEach((f, i) => { const nb = noteBox(f, pos[i]); pos[i] = [nb.x - F2[i].nx + F2[i].w / 2, nb.y - F2[i].ny + F2[i].h / 2]; }); return F2; }
// the gap between two notes' boxes: what an arrow's spring pulls on
function gapBetween(A, B) {
  const dx = (B.x + B.w / 2) - (A.x + A.w / 2), dy = (B.y + B.h / 2) - (A.y + A.h / 2);
  const gx = Math.abs(dx) - (A.w + B.w) / 2, gy = Math.abs(dy) - (A.h + B.h) / 2;
  return { dx, dy, gap: gx > 0 && gy > 0 ? Math.sqrt(gx * gx + gy * gy) : Math.max(gx, gy) };
}

// ---- the force model: shapes push apart, arrows are springs, gravity holds the board, shapes step out of arrows' way ----
function settle(X, F, pos, iters, t0) {
  const n = F.length, ix = new Map(X.items.map((k, i) => [k, i]));
  const springs = [];
  for (const p of X.pairs.values()) springs.push([ix.get(p.a), ix.get(p.b), p.broken ? P.refK : p.k, !p.broken]);
  for (const [pk, w] of X.refs) { const [a, b] = pk.split('\u0000'); const pair = X.pairs.get(pk); if (!pair || pair.broken) springs.push([ix.get(a), ix.get(b), w, false]); }
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
      const { dx, dy, gap } = gapBetween(noteBox(F[i], pos[i]), noteBox(F[j], pos[j])), d = Math.sqrt(dx * dx + dy * dy) || 1;
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

// each note takes the arrangement of its pills that the board's arrows run over least, then the one with fewest of its own lines over
// its pills, then the smallest; its note stays where it is
function arrange(X, F, pos) {
  const ix = new Map(X.items.map((k, i) => [k, i]));
  const segs = [];
  for (const p of X.pairs.values()) {
    if (p.broken) continue;
    const i = ix.get(p.a), j = ix.get(p.b);
    segs.push(arrowBetween(noteBox(F[i], pos[i]), noteBox(F[j], pos[j])));
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
        for (const s of segs) if (segHitsBox(s, pb, -4)) hits++;
      }
      const cost = hits * 1e6 + (a.own || 0) * 1e4 + a.w * a.h;
      if (cost < bestCost) { bestCost = cost; best = ai; }
    });
    if (best >= 0 && best !== (choice.has(k) ? choice.get(k) : 0)) { choice.set(k, best); changed = true; }
  });
  return changed;
}

// ---- 4. one container: settle with every arrow, then break the most stretched congested arrow past the threshold, settle, again ----
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
  const ps = [...X.pairs.values()];
  const st = { items: n, links: ps.length, congested: ps.filter((p) => p.congested).length, broken: ps.filter((p) => p.pre).length, order: [] };
  settle(X, F, pos, P.iters, P.t0);
  const gapOf = (p) => gapBetween(noteBox(F[ix.get(p.a)], pos[ix.get(p.a)]), noteBox(F[ix.get(p.b)], pos[ix.get(p.b)])).gap;
  for (let b = 0; b < P.maxBreaks && BREAK !== 'force'; b++) {
    const live = ps.filter((p) => !p.broken && p.congested).map((p) => [p, gapOf(p)]);
    if (!live.length) break;
    // the scale: --snapto=rest, the gap a spring wants; --snapto=median (the default), the area's typical arrow, measured again after
    // every break, so a board that spreads as it gains pills doesn't break by spreading
    const g = live.map(([, x]) => x).sort((a, b) => a - b), med = g[Math.floor((g.length - 1) / 2)];
    const scale = args.snapto === 'rest' ? P.arrowGap : Math.max(med, P.arrowGap);
    const holds = (p) => P.snap * scale * (BREAK === 'strength' ? P.sfloor + (1 - P.sfloor) * p.rank : 1);
    let worst = null, worstR = 1, worstGap = 0;
    for (const [p, gap] of live) { const r = gap / holds(p); if (r > worstR || (r === worstR && worst && byKey(p.key, worst.key) < 0)) { worst = p; worstR = r; worstGap = gap; } }
    if (!worst) break;
    worst.broken = true; st.broken++; st.order.push({ key: worst.key, rank: +worst.rank.toFixed(2), gap: Math.round(worstGap), limit: Math.round(holds(worst)) });
    for (const [u, v] of worst.dirs) addPill(u, v);
    F = refit(F, items.map(footprint), pos);
    settle(X, F, pos, P.warm, P.t0 / 4);
  }
  for (let r = 0; r < 3; r++) { if (!arrange(X, F, pos)) break; F = refit(F, items.map(footprint), pos); settle(X, F, pos, P.warm, P.t0 / 4); }
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
fs.writeFileSync(new URL('./' + OUT + '/stats.json', import.meta.url), JSON.stringify({ ms, P, stats }, null, 1));
const done = Object.entries(stats);
const tot = done.reduce((a, [, s]) => ({ links: a.links + s.links, congested: a.congested + s.congested, broken: a.broken + s.broken }), { links: 0, congested: 0, broken: 0 });
// how alike the links the threshold broke were: their similarity rank in their area, 0 the least alike, 1 the most (0.5 is chance)
const ranks = done.flatMap(([, s]) => s.order.map((o) => o.rank));
const brokenRank = ranks.length ? +(ranks.reduce((a, b) => a + b, 0) / ranks.length).toFixed(2) : null;
console.log(JSON.stringify({ seconds: ms / 1000, break: BREAK, sim: args.sim || 'corpus', core: P.core, floor: P.floor, snap: P.snap, cut: P.cut, refmass: P.refmass, frames: args.frames || 'references', others: args.others || 'pills', ...tot, arrows: tot.links - tot.broken, brokenRank }));
