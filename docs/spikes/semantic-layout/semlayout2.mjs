// The spike, second version: every board drawn with all its links as arrows first, laid out by a force model. Links are springs and
// shapes push apart. A reference is light: the notes of a container that use one target share one pill, a small node tied to each of them
// by a short spring, pushing on little; a note whose line into a shared pill is crowded gets a pill of its own, in its strip beside it
// (this branch's stripAlts). Where arrows or lines cross or run over shapes, the springs there take their stiffness from how alike the two
// ends are, and the least alike crowded link is broken into a reference; the board settles again, until nothing is crowded. Then each
// broken link whose straight line is clear is an arrow again, the most alike first. A link across containers (another board, in or out of
// a frame) is a reference from the start.
//
//   node semlayout2.mjs --order=sem|struct --sim=mix|emb|tfidf|sentence (emb: the embedding EMB names) --out=DIR [--boards=a,b]
//   sem: the least alike crowded link breaks first. struct (the control): the most crowded first, and no similarity anywhere.
import fs from 'fs';
import { EMB, loadSim } from './sim.mjs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges, pillKey } = await import(TOOL + 'sizes.mjs');
const { stripAlts } = await import(TOOL + 'strips.mjs');
const { arrowBetween, segCross, segHitsBox } = await import(TOOL + 'geom.mjs');

const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const ORDER = args.order || 'sem', SIM = args.sim || 'mix', OUT = args.out || 'out2-' + ORDER + '-' + SIM;
const P = {
  gap: 80, pillGap: 40,     // the least gap between two footprints; when one is a shared pill
  arrowGap: 160,            // the gap an arrow's spring wants between its notes
  pillLine: 60,             // the gap a line into a shared pill wants
  rep: 0.02, grav: 0.02, spring: 0.1, push: 0.5, pillK: 0.6, pillMass: 0.15,
  iters: 400, warm: 160, t0: 400, tmin: 1,
  refK: 0.05, floor: 0.15, batch: 0.1, rounds: 100, corr: 0.3, margin: 24,
};
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const graph = rd('./data/graph.json'), measure = rd('./data/measure.json'), kinds = rd('./data/kinds.json');
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const sizes = sizesFrom(model, measure), K = sizes.constants;
const node = (k) => model.node(k);
const cont = (k) => node(k).container;
const isFrame = (k) => node(k).holds === 'shapes';
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const PILL = 'pill\u0001';

// ---- containers, items, links ----
const keys = graph.nodes.map((n) => n.key).filter((k) => node(k)).sort(byKey);
const kids = new Map();
for (const k of keys) { const c = cont(k); if (!kids.has(c)) kids.set(c, []); kids.get(c).push(k); }
const chain = (k) => { const out = []; let item = k; for (;;) { const c = cont(item); out.push([c, item]); if (c[0] === 'b') return out; item = c.slice(2); } };
const C = new Map();
const box = (id) => { if (!C.has(id)) C.set(id, { id, items: kids.get(id) || [], pairs: new Map(), refs: new Map(), shared: new Map(), split: new Set() }); return C.get(id); };
const refsOf = new Map();   // host -> Set of targets it shows as pills
const addRef = (h, t) => { if (!refsOf.has(h)) refsOf.set(h, new Set()); refsOf.get(h).add(t); };
const delRef = (h, t) => { const s = refsOf.get(h); if (s) s.delete(t); };
const seen = new Set(), edges = [];
for (const e of graph.edges) {
  if (!node(e.from) || !node(e.to) || e.from === e.to) continue;
  const id = e.from + '\u0000' + e.to; if (seen.has(id)) continue; seen.add(id); edges.push(e);
}
for (const id of kids.keys()) box(id);
for (const e of edges) {
  const u = e.from, v = e.to, cu = cont(u), cv = cont(v);
  if (cu === cv) {
    const X = box(cu), [a, b] = [u, v].sort(byKey), pk = a + '\u0000' + b;
    if (!X.pairs.has(pk)) X.pairs.set(pk, { key: pk, a, b, dirs: [], broken: false });
    X.pairs.get(pk).dirs.push([u, v]);
    continue;
  }
  addRef(u, v);
  if (node(u).board !== node(v).board) continue;
  const cvs = new Map(chain(v)), at = chain(u).find(([c]) => cvs.has(c));
  if (!at) continue;
  const [c, iu] = at, iv = cvs.get(c);
  if (iu === iv) continue;
  const X = box(c), pk = [iu, iv].sort(byKey).join('\u0000');
  X.refs.set(pk, Math.min(0.3, (X.refs.get(pk) || 0) + P.refK));
}

// ---- similarity (ranks within a container decide, so only the order of the scores matters) ----
const sims = { emb: loadSim(EMB), tfidf: loadSim('tfidf'), sentence: loadSim('sentence') };
const allPairs = [...C.values()].flatMap((X) => [...X.pairs.values()]);
function zFor(f) { const v = allPairs.map((p) => f(p.a, p.b)); const mu = v.reduce((a, b) => a + b, 0) / v.length; const sd = Math.sqrt(v.reduce((a, b) => a + (b - mu) ** 2, 0) / v.length) || 1; return (a, b) => (f(a, b) - mu) / sd; }
const simOf = SIM === 'mix' ? (() => { const zc = zFor(sims.emb), zt = zFor(sims.tfidf); return (a, b) => zc(a, b) + zt(a, b); })() : sims[SIM];
for (const X of C.values()) {
  const ps = [...X.pairs.values()];
  for (const p of ps) p.sim = simOf(p.a, p.b);
  const sorted = [...ps].sort((x, y) => x.sim - y.sim || byKey(x.key, y.key));
  sorted.forEach((p, i) => { p.rank = sorted.length > 1 ? i / (sorted.length - 1) : 1; });
}

// ---- sharing: the notes of a container that use one target share its pill, but those split off from it ----
function reshare(X) {
  const hosts = new Map();
  for (const u of X.items) for (const t of refsOf.get(u) || []) { if (X.split.has(u + '\u0000' + t)) continue; if (!hosts.has(t)) hosts.set(t, []); hosts.get(t).push(u); }
  const next = new Map();
  for (const [t, hs] of [...hosts].sort((x, y) => byKey(x[0], y[0]))) if (hs.length >= 2) next.set(t, new Set(hs));
  X.shared = next;
}
const sharedFor = (X, u, t) => { const s = X.shared.get(t); return !!s && s.has(u); };

// ---- footprints ----
const frameBox = new Map();
const choice = new Map();
const pillW = (t, cid) => sizes.pillWidth[pillKey(t, cid)] || sizes.pillWidth[t] || 120;
function ownPills(X, k) {
  const t = [...(refsOf.get(k) || [])].filter((x) => !sharedFor(X, k, x));
  t.sort((x, y) => sims.emb(k, y) - sims.emb(k, x) || byKey(x, y));
  return t.map((target) => ({ target, w: pillW(target, X.id) }));
}
function footprint(X, id) {
  if (id.startsWith(PILL)) { const t = id.slice(PILL.length), w = pillW(t, X.id); return { w, h: K.pillHeight, nx: 0, ny: 0, nw: w, nh: K.pillHeight, pills: [], mass: P.pillMass, pill: true }; }
  if (isFrame(id)) { const f = frameBox.get(id); return { w: f.w, h: f.h + f.above, nx: 0, ny: f.above, nw: f.w, nh: f.h, pills: [], mass: Math.sqrt(f.w * f.h) / 300 }; }
  const s = sizes.shapes[id], mass = Math.sqrt(s.w * s.h) / 300, pl = ownPills(X, id);
  if (!pl.length) return { w: s.w, h: s.h + s.above, nx: 0, ny: s.above, nw: s.w, nh: s.h, pills: [], mass };
  const alts = stripAlts({ w: s.w, h: s.h, above: s.above }, pl.map((p) => ({ w: p.w })), K);
  let i = choice.has(id) ? choice.get(id) : 0;
  if (!alts[i]) i = alts.findIndex(Boolean);
  const a = alts[i];
  return { w: a.w, h: a.h, nx: a.nx, ny: a.ny, nw: a.nw, nh: a.nh, pills: a.pills.map((p, j) => ({ ...p, target: pl[j].target })), alts, mass };
}
const noteBox = (f, c) => ({ x: c[0] - f.w / 2 + f.nx, y: c[1] - f.h / 2 + f.ny, w: f.nw, h: f.nh });
const pillBoxes = (f, c) => f.pills.map((p) => ({ x: c[0] - f.w / 2 + p.x, y: c[1] - f.h / 2 + p.y, w: p.w, h: p.h, target: p.target }));

// A container's scene: its items (shapes, then shared pills), their footprints and centres, its springs.
function scene(X) {
  const ids = X.items.concat([...X.shared.keys()].map((t) => PILL + t));
  const F = ids.map((id) => footprint(X, id));
  const ix = new Map(ids.map((id, i) => [id, i]));
  for (const id of ids) if (!X.pos.has(id)) {
    // a new shared pill starts among its users
    const hs = [...X.shared.get(id.slice(PILL.length))].filter((h) => X.pos.has(h));
    let x = 0, y = 0; for (const h of hs) { x += X.pos.get(h)[0] / hs.length; y += X.pos.get(h)[1] / hs.length; }
    X.pos.set(id, [x + 7 * (ix.get(id) % 5), y + 5 * (ix.get(id) % 3)]);
  }
  const pos = ids.map((id) => [...X.pos.get(id)]);
  const springs = [];   // [i, j, stiffness, gap, kind, ref]
  for (const p of X.pairs.values()) if (!p.broken) springs.push([ix.get(p.a), ix.get(p.b), p.k == null ? 1 : p.k, P.arrowGap, 'arrow', p]);
  for (const [t, hs] of X.shared) for (const h of hs) springs.push([ix.get(h), ix.get(PILL + t), P.pillK, P.pillLine, 'line', { host: h, target: t }]);
  for (const [pk, w] of X.refs) { const [a, b] = pk.split('\u0000'); const pair = X.pairs.get(pk); if (!pair || pair.broken) springs.push([ix.get(a), ix.get(b), w, P.arrowGap, 'ref', null]); }
  for (const p of X.pairs.values()) if (p.broken) springs.push([ix.get(p.a), ix.get(p.b), P.refK, P.arrowGap, 'ref', null]);
  return { ids, F, ix, pos, springs };
}
const save = (X, S) => S.ids.forEach((id, i) => X.pos.set(id, S.pos[i]));
// footprints changed (pills came or went): each note stays where it is, its footprint moves about it
function refit(X, S) {
  const S2 = scene(X);
  S2.ids.forEach((id, i) => { const j = S.ix.get(id); if (j == null) return; const nb = noteBox(S.F[j], S.pos[j]); S2.pos[i] = [nb.x - S2.F[i].nx + S2.F[i].w / 2, nb.y - S2.F[i].ny + S2.F[i].h / 2]; });
  return S2;
}

// ---- the force model ----
function settle(S, iters, t0) {
  const { F, pos, springs } = S, n = F.length;
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
      const least = F[i].pill || F[j].pill ? P.pillGap : P.gap;
      let f = P.rep * 90000 * F[i].mass * F[j].mass / Math.max(d, 1);
      if (gap < least) f += P.push * (least - gap);
      fx[i] -= f * ux; fy[i] -= f * uy; fx[j] += f * ux; fy[j] += f * uy;
    }
    for (const [i, j, k, want] of springs) {
      const A = noteBox(F[i], pos[i]), B = noteBox(F[j], pos[j]);
      const dx = (B.x + B.w / 2) - (A.x + A.w / 2), dy = (B.y + B.h / 2) - (A.y + A.h / 2), d = Math.sqrt(dx * dx + dy * dy) || 1;
      const gx = Math.abs(dx) - (A.w + B.w) / 2, gy = Math.abs(dy) - (A.h + B.h) / 2;
      const gap = gx > 0 && gy > 0 ? Math.sqrt(gx * gx + gy * gy) : Math.max(gx, gy);
      if (gap <= want) continue;
      const f = P.spring * k * (gap - want) / 2;
      fx[i] += f * dx / d; fy[i] += f * dy / d; fx[j] -= f * dx / d; fy[j] -= f * dy / d;
    }
    // a shape a line runs over is pushed off it, the line's ends the other way
    for (const [i, j, , , kind] of springs) {
      if (kind === 'ref') continue;
      const A = noteBox(F[i], pos[i]), B = noteBox(F[j], pos[j]);
      const ax = A.x + A.w / 2, ay = A.y + A.h / 2, lx = B.x + B.w / 2 - ax, ly = B.y + B.h / 2 - ay, L2 = lx * lx + ly * ly;
      if (L2 < 1) continue;
      const Ln = Math.sqrt(L2), nx = -ly / Ln, ny = lx / Ln;
      for (let k = 0; k < n; k++) {
        if (k === i || k === j) continue;
        const cx = pos[k][0], cy = pos[k][1], t2 = ((cx - ax) * lx + (cy - ay) * ly) / L2;
        if (t2 <= 0 || t2 >= 1) continue;
        const side = (cx - ax) * nx + (cy - ay) * ny, r = Math.abs(nx) * F[k].w / 2 + Math.abs(ny) * F[k].h / 2 + P.margin, dist = Math.abs(side);
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
  unoverlap(S);
}
function unoverlap(S) {
  const { F, pos } = S, n = F.length;
  for (let r = 0; r < 300; r++) {
    let moved = false;
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) {
      const least = F[i].pill || F[j].pill ? P.pillGap : P.gap;
      const dx = pos[j][0] - pos[i][0], dy = pos[j][1] - pos[i][1];
      const ox = (F[i].w + F[j].w) / 2 + least / 2 - Math.abs(dx), oy = (F[i].h + F[j].h) / 2 + least / 2 - Math.abs(dy);
      if (ox <= 0 || oy <= 0) continue;
      moved = true;
      if (ox < oy) { const s = (dx >= 0 ? 1 : -1) * ox / 2; pos[i][0] -= s; pos[j][0] += s; } else { const s = (dy >= 0 ? 1 : -1) * oy / 2; pos[i][1] -= s; pos[j][1] += s; }
    }
    if (!moved) return true;
  }
  return false;
}
function overlaps(S) {
  const { F, pos } = S;
  for (let i = 0; i < F.length; i++) for (let j = i + 1; j < F.length; j++)
    if (Math.abs(pos[j][0] - pos[i][0]) < (F[i].w + F[j].w) / 2 + 8 && Math.abs(pos[j][1] - pos[i][1]) < (F[i].h + F[j].h) / 2 + 8) return true;
  return false;
}

// ---- what crowds a container: each arrow's and each shared pill line's crossings and the shapes it runs over ----
function crowding(S) {
  const { F, pos, springs } = S;
  const lines = springs.filter((s) => s[4] !== 'ref').map(([i, j, , , kind, ref]) => ({ i, j, kind, ref, s: arrowBetween(noteBox(F[i], pos[i]), noteBox(F[j], pos[j])), crowd: 0 }));
  const obstacles = [], own = [];
  F.forEach((f, i) => {
    const nb = noteBox(f, pos[i]);
    obstacles.push({ i, b: nb, end: true });
    for (const pb of pillBoxes(f, pos[i])) { obstacles.push({ i, b: pb, end: false }); own.push({ i, s: arrowBetween(nb, pb) }); }
  });
  for (const a of lines) {
    let c = 0;
    for (const b of lines) if (a !== b && a.i !== b.i && a.i !== b.j && a.j !== b.i && a.j !== b.j && segCross(a.s, b.s)) c++;
    for (const l of own) if (l.i !== a.i && l.i !== a.j && segCross(a.s, l.s)) c++;
    for (const o of obstacles) if (!(o.end && (o.i === a.i || o.i === a.j)) && segHitsBox(a.s, o.b, 1)) c++;
    a.crowd = c;
  }
  return lines;
}

// each note takes the arrangement of its own pills that the container's lines run over least, then the fewest of its own lines over
// its pills, then the smallest; the note stays where it is
function arrange(X, S) {
  const lines = S.springs.filter((s) => s[4] !== 'ref').map(([i, j]) => arrowBetween(noteBox(S.F[i], S.pos[i]), noteBox(S.F[j], S.pos[j])));
  let changed = false;
  S.ids.forEach((id, i) => {
    const f = S.F[i];
    if (!f.alts) return;
    const nb = noteBox(f, S.pos[i]);
    let best = -1, bestCost = Infinity;
    f.alts.forEach((a, ai) => {
      if (!a) return;
      let hits = 0;
      for (const p of a.pills) { const pb = { x: nb.x - a.nx + p.x, y: nb.y - a.ny + p.y, w: p.w, h: p.h }; for (const s of lines) if (segHitsBox(s, pb, -4)) hits++; }
      const cost = hits * 1e6 + (a.own || 0) * 1e4 + a.w * a.h;
      if (cost < bestCost) { bestCost = cost; best = ai; }
    });
    if (best >= 0 && best !== (choice.has(id) ? choice.get(id) : 0)) { choice.set(id, best); changed = true; }
  });
  return changed;
}

// ---- one container ----
const stats = {};
function layOut(X) {
  if (!X.items.length) return;
  X.pos = new Map();
  reshare(X);
  // start: the most linked first, breadth first along arrows, on a snake grid; shared pills among their users (scene)
  const items = X.items, n = items.length, ix = new Map(items.map((k, i) => [k, i]));
  const adj = items.map(() => []);
  for (const p of X.pairs.values()) { adj[ix.get(p.a)].push(ix.get(p.b)); adj[ix.get(p.b)].push(ix.get(p.a)); }
  const order = [], seenI = new Array(n).fill(false);
  const byDeg = [...Array(n).keys()].sort((a, b) => adj[b].length - adj[a].length || byKey(items[a], items[b]));
  for (const s of byDeg) { if (seenI[s]) continue; const q = [s]; seenI[s] = true; while (q.length) { const x = q.shift(); order.push(x); for (const y of [...adj[x]].sort((a, b) => byKey(items[a], items[b]))) if (!seenI[y]) { seenI[y] = true; q.push(y); } } }
  const F0 = items.map((id) => footprint(X, id));
  const cols = Math.ceil(Math.sqrt(n)), cw = Math.max(...F0.map((f) => f.w)) + P.gap, ch = Math.max(...F0.map((f) => f.h)) + P.gap;
  order.forEach((i, r) => { const row = Math.floor(r / cols), col = r % cols; X.pos.set(items[i], [(row % 2 ? cols - 1 - col : col) * cw, row * ch]); });
  const st = { items: n, links: X.pairs.size, broken: 0, split: 0, putBack: 0, rounds: 0, crowdedLeft: 0, shared: 0 };
  let S = scene(X);
  settle(S, P.iters, P.t0);
  for (let round = 0; round < P.rounds; round++) {
    if (arrange(X, S)) { S = refit(X, S); settle(S, P.warm, P.t0 / 4); }
    const lines = crowding(S), bad = lines.filter((l) => l.crowd > 0);
    st.rounds = round + 1;
    if (!bad.length) break;
    const badArrows = bad.filter((l) => l.kind === 'arrow').map((l) => l.ref), badLines = bad.filter((l) => l.kind === 'line');
    if (ORDER === 'sem') {
      const near = new Set(badArrows.flatMap((p) => [p.a, p.b]));
      for (const p of X.pairs.values()) if (near.has(p.a) || near.has(p.b)) p.k = P.floor + (1 - P.floor) * p.rank;
    }
    const simLine = (l) => sims.emb(l.ref.host, l.ref.target);
    badLines.sort(ORDER === 'sem' ? (x, y) => simLine(x) - simLine(y) || byKey(x.ref.host + x.ref.target, y.ref.host + y.ref.target) : (x, y) => y.crowd - x.crowd || byKey(x.ref.host + x.ref.target, y.ref.host + y.ref.target));
    for (const l of badLines.slice(0, Math.max(1, Math.ceil(badLines.length * P.batch)))) { X.split.add(l.ref.host + '\u0000' + l.ref.target); st.split++; }
    const crowdOf = new Map(bad.filter((l) => l.kind === 'arrow').map((l) => [l.ref, l.crowd]));
    badArrows.sort(ORDER === 'sem' ? (x, y) => x.sim - y.sim || byKey(x.key, y.key) : (x, y) => crowdOf.get(y) - crowdOf.get(x) || byKey(x.key, y.key));
    for (const p of badArrows.slice(0, badArrows.length ? Math.max(1, Math.ceil(badArrows.length * P.batch)) : 0)) { p.broken = true; st.broken++; for (const [u, v] of p.dirs) addRef(u, v); }
    save(X, S); reshare(X); S = refit(X, S);
    settle(S, P.warm, P.t0 / 4);
  }
  // put back: a broken link is an arrow again where every line stays clear (the most alike first; the control: the shortest first)
  save(X, S);
  const back = [...X.pairs.values()].filter((p) => p.broken);
  const lenOf = (p) => { const i = S.ix.get(p.a), j = S.ix.get(p.b); const s = arrowBetween(noteBox(S.F[i], S.pos[i]), noteBox(S.F[j], S.pos[j])); return Math.sqrt((s.x2 - s.x1) ** 2 + (s.y2 - s.y1) ** 2); };
  back.sort(ORDER === 'sem' ? (x, y) => y.sim - x.sim || byKey(x.key, y.key) : (x, y) => lenOf(x) - lenOf(y) || byKey(x.key, y.key));
  for (const p of back) {
    p.broken = false; for (const [u, v] of p.dirs) delRef(u, v);
    const before = X.shared; reshare(X);
    const S2 = refit(X, S);
    if (crowding(S2).some((l) => l.crowd > 0) || overlaps(S2)) { p.broken = true; for (const [u, v] of p.dirs) addRef(u, v); X.shared = before; continue; }
    S = S2; save(X, S); st.putBack++;
  }
  st.crowdedLeft = crowding(S).filter((l) => l.crowd > 0).length;
  st.shared = X.shared.size;
  stats[X.id] = st;
  X.S = S;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  S.F.forEach((f, i) => { x0 = Math.min(x0, S.pos[i][0] - f.w / 2); y0 = Math.min(y0, S.pos[i][1] - f.h / 2); x1 = Math.max(x1, S.pos[i][0] + f.w / 2); y1 = Math.max(y1, S.pos[i][1] + f.h / 2); });
  X.bounds = { x0, y0, x1, y1 };
  if (X.id[0] === 'f') {
    const k = X.id.slice(2), fs0 = sizes.frames[k] || { min: null, above: 0 }, inset = K.frameInset, min = fs0.min || K.frameMin;
    const w = Math.max(min.w, x1 - x0 + 2 * inset), h = Math.max(min.h, y1 - y0 + 2 * inset);
    frameBox.set(k, { w, h, above: fs0.above || 0, ox: x0 - inset - (w - (x1 - x0 + 2 * inset)) / 2, oy: y0 - inset - (h - (y1 - y0 + 2 * inset)) / 2 });
  }
}

const t0 = Date.now();
const ONLY = args.boards ? new Set(args.boards.split(',')) : null;
const onBoard = (id) => !ONLY || ONLY.has(id[0] === 'b' ? id.slice(2) : node(id.slice(2)).board);
const frames = [...C.keys()].filter((id) => id[0] === 'f').sort((a, b) => node(b.slice(2)).frames.length - node(a.slice(2)).frames.length || byKey(a, b));
for (const id of frames) if (onBoard(id)) layOut(C.get(id));
for (const id of [...C.keys()].filter((id) => id[0] === 'b').sort(byKey)) if (onBoard(id)) layOut(C.get(id));
const ms = Date.now() - t0;

// ---- the drawing ----
const placeOf = new Map(), pillAt = new Map(), shareOf = new Map();
for (const X of C.values()) {
  if (!X.S) continue;
  const S = X.S, org = X.id[0] === 'f' ? frameBox.get(X.id.slice(2)) : { ox: X.bounds.x0, oy: X.bounds.y0 };
  const inFrame = X.id[0] === 'f' ? { in: X.id.slice(2) } : {};
  S.ids.forEach((id, i) => {
    const f = S.F[i], nb = noteBox(f, S.pos[i]);
    if (id.startsWith(PILL)) {
      const t = id.slice(PILL.length), hs = [...X.shared.get(t)].sort(byKey), owner = hs[0];
      pillAt.set(owner + '\u0000' + t, { at: [nb.x - org.ox, nb.y - org.oy], ...inFrame });
      for (const h of hs.slice(1)) shareOf.set(h + '\u0000' + t, owner);
      return;
    }
    placeOf.set(id, { at: [nb.x - org.ox, nb.y - org.oy], size: [nb.w, nb.h] });
    for (const pb of pillBoxes(f, S.pos[i])) pillAt.set(id + '\u0000' + pb.target, { at: [pb.x - org.ox, pb.y - org.oy], ...inFrame });
  });
}
const arrowSet = new Set();
for (const X of C.values()) for (const p of X.pairs.values()) if (!p.broken) for (const [u, v] of p.dirs) arrowSet.add(u + '\u0000' + v);
const drawing = { ...graph, nodes: graph.nodes.map((n) => (placeOf.has(n.key) ? { ...n, place: placeOf.get(n.key) } : n)), edges: graph.edges.map((e) => {
  const id = e.from + '\u0000' + e.to;
  if (arrowSet.has(id)) return e;
  if (shareOf.has(id)) return { ...e, place: { pill: { share: shareOf.get(id) } } };
  const p = pillAt.get(id);
  return p ? { ...e, place: { pill: p } } : e;
}) };
fs.mkdirSync(new URL('./' + OUT + '/', import.meta.url), { recursive: true });
fs.writeFileSync(new URL('./' + OUT + '/drawing.json', import.meta.url), JSON.stringify(drawing));
fs.writeFileSync(new URL('./' + OUT + '/stats.json', import.meta.url), JSON.stringify({ ms, order: ORDER, sim: SIM, P, stats }, null, 1));
const tot = Object.values(stats).reduce((a, s) => ({ links: a.links + s.links, broken: a.broken + s.broken, split: a.split + s.split, putBack: a.putBack + s.putBack, crowdedLeft: a.crowdedLeft + s.crowdedLeft, shared: a.shared + s.shared }), { links: 0, broken: 0, split: 0, putBack: 0, crowdedLeft: 0, shared: 0 });
console.log(JSON.stringify({ order: ORDER, sim: SIM, seconds: ms / 1000, ...tot, arrowsKept: tot.links - tot.broken + tot.putBack }));
