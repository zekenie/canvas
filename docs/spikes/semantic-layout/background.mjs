// The owner's idea (2026-11-10): a force simulation run in the background, never drawn, whose only job is to decide which links break
// into references; the layout branch's engine then draws what is left, clean. Since nobody sees it, its physics can be chosen for the
// decision alone. Every note on a board is a point, pushing the others away with its size plus a share (--refmass) of its pills' (point 5
// as stated), and every link inside the board is a spring that wants a gap of --rest between its notes. Three physics (--physics):
//  - load (the default): every spring as stiff as the next, so how hard a link is pulled comes from the board's crowding alone (a hub's fan
//    of notes pushing each other out, two clusters pushing apart). Its notes' similarity sets how much pull it holds before it breaks:
//    --snap for the most alike link on the board, --sfloor of that for the least alike. Notes push with a charge falling off with the
//    square of their distance, out to --reach springs' length, and a little gravity holds the board together;
//  - crowding: the same, but two notes push only where their rooms overlap, so a link carries load only where its notes can't all fit
//    where their links want them (a lone link carries none); strength by similarity's rank across the corpus;
//  - meaning: springs as strong as their notes are alike (as stated), and every pair of notes on the board, linked or not, pulled toward a
//    distance set by how alike they are (--lambda), so notes that aren't alike drift apart and the link between them stretches. A link
//    breaks when stretched past --snap.
// The link pulled hardest past what it holds breaks first, one at a time, and the board settles again after each, its new pills pushing
// with the note. It stops when every link holds.
// Out (--out): cut.json, the links that broke, for the engine's SIM_CUT; graph.json, the corpus with every link inside a board weighted by
// its place in the order (the first to break the lightest), which the engine's own further cuts, its mend and its put-back go by; stats.json.
// --emit picks another cut to write, for the controls: simcut (the simulation's cut, weighted by similarity), same (on each board as many
// links as the simulation broke there, the least alike), half, frac (--frac of each board's links, the least alike), judges (every judged
// link the judges wouldn't keep), chips (every judged link both judges chip), and simjudges and simchips (on each judged board as many
// links as those two cut there, the least alike); all but sim and simcut weighted by similarity, as same is.
// Similarity is the mix with what each board shares taken out (springs.mjs --sim=board). --score ranks links by something else wherever
// similarity would: the springs' strength, the controls and the cuts (jev.mjs's answers: --score=board is data/jev-board.json, each
// probability a logit; levels.more, one field of such a file; several joined with +, each a z-score over the links inside boards, sim for
// similarity itself; a>b ranks by a and breaks its ties by b). --counts=FILE takes
// each board's number of links to cut (same) from an earlier run's stats.json; --emit=below cuts every link whose first answer's
// probability is under --below. --dump=FILE writes each link's score. Deterministic: no randomness.
//   node background.mjs [--physics=load|crowding|meaning] [--snap=1] [--sfloor=0.25] [--refmass=0.25] [--rest=160] [--lambda=1]
//     [--others=hide] [--boards=module:A,...] [--auc=1] [--line=LABEL] [--each=1] [--bands=1] [--emit=sim|simcut|same|half|frac|...]
//     [--score=board+sim] [--counts=out/x/stats.json] [--below=0.5] [--dump=FILE] --out=DIR
import fs from 'fs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges, pillKey } = await import(TOOL + 'sizes.mjs');
const { cuttable } = await import(TOOL + 'cut.mjs');

const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const OUT = args.out || 'out/background';
const PHYS = args.physics || 'load';
// each physics' push (rep 2: a charge over distance squared; 0: rooms that overlap), and what a link's strength ranks its similarity among
const D = { load: { rep: 2, press: 0.3, rankby: 'board', sfloor: 0.25 }, crowding: { rep: 0, press: 4, rankby: 'corpus', sfloor: 0.25 }, meaning: { rep: 2, press: 0.3, rankby: 'board', sfloor: 1 } }[PHYS];
if (!D) throw new Error('--physics is load, crowding or meaning');
const P = {
  snap: +(args.snap ?? 1), sfloor: +(args.sfloor ?? D.sfloor), refmass: +(args.refmass ?? 0.25), rankby: args.rankby || D.rankby,
  rest: +(args.rest ?? 160), lambda: +(args.lambda ?? 1), rep: +(args.rep ?? D.rep), press: +(args.press ?? D.press), reach: 4, floor: 0.1, tau: 2,
  iters: 600, warm: 120, maxBreaks: 2000,
};
P.grav = +(args.grav ?? (P.rep === 0 ? 0 : 0.02));
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const graph = rd('./data/graph.json'), measure = rd('./data/measure.json'), kinds = rd('./data/kinds.json');
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const sizes = sizesFrom(model, measure), K = sizes.constants;
const node = (k) => model.node(k);
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const SEP = '\u0000';

// ---- similarity: contextual embedding plus word overlap, what each board shares taken out, each a z-score over the links inside boards ----
const raw = rd('./data/vec-contextual.json');
const texts = new Map(rd('./data/texts.json').map((t) => [t.key, t.text]));
const STOP = new Set('a an the and or of to in on for by with is are be as it its at from that this what which into each one when where how not no but than then so their they them a s t'.split(' '));
const words = (k) => (texts.get(k) || '').toLowerCase().match(/[a-z][a-z0-9]+/g)?.filter((w) => !STOP.has(w) && w.length > 2) || [];
const unit = (v) => { let s = 0; for (const x of v) s += x * x; s = Math.sqrt(s) || 1; return v.map((x) => x / s); };
const points = new Map();   // board -> its notes (and cards), every shape on it but frames
for (const k of [...model.nodes.keys()].sort(byKey)) { const n = node(k); if (n.holds === 'shapes') continue; if (!points.has(n.board)) points.set(n.board, []); points.get(n.board).push(k); }
const vec = new Map(), bag = new Map();
for (const [, ks] of points) {
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
const cosC = (a, b) => { const x = vec.get(a), y = vec.get(b); if (!x || !y) return 0; let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * y[i]; return s; };
const cosT = (a, b) => { const x = bag.get(a), y = bag.get(b); if (!x || !y) return 0; let s = 0; const [p, q] = x.size < y.size ? [x, y] : [y, x]; for (const [w, u] of p) { const t = q.get(w); if (t) s += u * t; } return s; };

// ---- each board's links: pairs of its notes, every link between them a direction of the pair; and each note's pills for other boards ----
const pairsOn = new Map(), crossPills = new Map();
for (const e of model.edges) {
  const a = node(e.from), b = node(e.to);
  if (!a || !b || e.from === e.to) continue;
  if (a.board !== b.board) { if (args.others !== 'hide') crossPills.set(e.from, (crossPills.get(e.from) || 0) + (sizes.pillWidth[pillKey(e.to, a.container)] || sizes.pillWidth[e.to] || 120)); continue; }
  if (a.holds === 'shapes' || b.holds === 'shapes') continue;
  const [x, y] = [e.from, e.to].sort(byKey), pk = x + SEP + y;
  if (!pairsOn.has(a.board)) pairsOn.set(a.board, new Map());
  const M = pairsOn.get(a.board);
  if (!M.has(pk)) M.set(pk, { key: pk, a: x, b: y, board: a.board, edges: [], fixed: false, broken: false });
  const p = M.get(pk); p.edges.push(e); if (!cuttable(model, e)) p.fixed = true;
}
const all = [...pairsOn.values()].flatMap((M) => [...M.values()]);
const zOf = (f) => { const v = all.map((p) => f(p.a, p.b)); const mu = v.reduce((s, x) => s + x, 0) / v.length; const sd = Math.sqrt(v.reduce((s, x) => s + (x - mu) ** 2, 0) / v.length) || 1; return (a, b) => (f(a, b) - mu) / sd; };
const zc = zOf(cosC), zt = zOf(cosT), simOf = (a, b) => zc(a, b) + zt(a, b);
for (const p of all) p.sim = simOf(p.a, p.b);
if (args.score) {
  const zs = (v) => { const mu = v.reduce((s, x) => s + x, 0) / v.length, sd = Math.sqrt(v.reduce((s, x) => s + (x - mu) ** 2, 0) / v.length) || 1; return v.map((x) => (x - mu) / sd); };
  // a>b ranks by a and breaks its ties by b (Jev's probabilities come in hundredths, so many links tie)
  const [main, tie] = args.score.split('>');
  const parts = main.split('+').map((name, n) => {
    if (name === 'sim') return zs(all.map((p) => p.sim));
    const [file, field] = name.split('.'), S = rd(`./data/jev-${file}.json`)[field || 'scores'];
    return zs(all.map((p) => { const q = S[p.a + '|' + p.b]; if (q == null) throw new Error(`no answer for ${p.a} | ${p.b} in data/jev-${name}.json`); if (p.prob == null) p.prob = q; const c = Math.min(0.999, Math.max(0.001, q)); return Math.log(c / (1 - c)); }));
  });
  const ties = tie ? zs(tie === 'sim' ? all.map((p) => p.sim) : (() => { const S = rd(`./data/jev-${tie}.json`).scores; return all.map((p) => S[p.a + '|' + p.b]); })()) : null;
  all.forEach((p, i) => { p.sim = parts.reduce((s, z) => s + z[i], 0) + (ties ? 1e-3 * ties[i] : 0); });
}
if (args.dump) fs.writeFileSync(args.dump, JSON.stringify(Object.fromEntries(all.map((p) => [p.a + '|' + p.b, +p.sim.toFixed(4)]))));
const countOf = args.counts ? new Map(JSON.parse(fs.readFileSync(args.counts, 'utf8')).boards.map((b) => [b.board, b.broken])) : null;
all.slice().sort((x, y) => x.sim - y.sim || byKey(x.key, y.key)).forEach((p, i, xs) => { p.grank = xs.length > 1 ? i / (xs.length - 1) : 1; });

// ---- the simulation of one board ----
function simulate(board) {
  const ks = points.get(board) || [], n = ks.length, ix = new Map(ks.map((k, i) => [k, i]));
  const ps = [...(pairsOn.get(board) || new Map()).values()].sort((x, y) => byKey(x.key, y.key));
  const byRank = ps.slice().sort((x, y) => x.sim - y.sim || byKey(x.key, y.key));
  byRank.forEach((p, i) => { p.rank = byRank.length > 1 ? i / (byRank.length - 1) : 1; });
  const R = ks.map((k) => { const s = sizes.shapes[k] || { w: 260, h: 200 }; return Math.sqrt(s.w * s.h) / 2; });
  const unitLen = 2 * (R.reduce((s, r) => s + r, 0) / Math.max(1, n)) + P.rest;   // the typical gap a spring wants, centre to centre
  const pillArea = ks.map((k) => (crossPills.get(k) || 0) * K.pillHeight);
  const area = ks.map((k) => { const s = sizes.shapes[k] || { w: 260, h: 200 }; return s.w * s.h; });
  // a note's room: its own size and a share (--refmass) of its pills'. An arrow wants --rest between two notes' rooms, and two notes push
  // each other only where their rooms (and that gap) overlap, so a link is loaded only where its notes can't all fit where links want them
  const F = new Float64Array(n);
  const rest = new Float64Array(ps.length);
  const refit = () => {
    for (let i = 0; i < n; i++) F[i] = Math.sqrt(area[i] + P.refmass * pillArea[i]) / 2 / unitLen;
    ps.forEach((p, s) => { rest[s] = F[ix.get(p.a)] + F[ix.get(p.b)] + P.rest / unitLen; });
  };
  refit();
  // load and meaning: a charge by a note's room
  const q = new Float64Array(n);
  const charge = () => { const a0 = area.reduce((s, x) => s + x, 0) / Math.max(1, n); for (let i = 0; i < n; i++) q[i] = Math.sqrt((area[i] + P.refmass * pillArea[i]) / a0); };
  charge();
  const stiff = ps.map((p) => (PHYS === 'meaning' ? P.floor + (1 - P.floor) * p.rank : 1));
  const holds = ps.map((p) => P.snap * (P.sfloor + (1 - P.sfloor) * (P.rankby === 'board' ? p.rank : p.grank)));
  // meaning: every pair of notes pulled toward a distance by how alike they are, weighted so that a note's pull from meaning is about one link's
  let target = null, mw = 0;
  if (PHYS === 'meaning' && n > 1) {
    target = new Float64Array(n * n);
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) { const t = ((R[i] + R[j] + P.rest) / unitLen) * Math.exp(-simOf(ks[i], ks[j]) / P.tau) * 1.5; target[i * n + j] = target[j * n + i] = Math.max(t, (R[i] + R[j]) / unitLen); }
    mw = P.lambda / (n - 1);
  }
  // start: a spiral in key order, spread by the board's size
  const x = new Float64Array(n), y = new Float64Array(n), fx = new Float64Array(n), fy = new Float64Array(n);
  const G = Math.PI * (3 - Math.sqrt(5)), R0 = Math.sqrt(n) * 0.8;
  for (let i = 0; i < n; i++) { const r = R0 * Math.sqrt((i + 0.5) / n); x[i] = r * Math.cos(i * G); y[i] = r * Math.sin(i * G); }
  // what loads a link is the crowding around it, not the size of the board; each note steps by its force over its own stiffness, so a busy
  // note doesn't overshoot
  const reach2 = P.reach * P.reach;
  const settle = (iters, t0) => {
    const kk = new Float64Array(n).fill(1 + (target ? P.lambda : 0) + (P.rep === 0 ? 4 * P.press : 0));
    ps.forEach((p, s) => { if (!p.broken) { kk[ix.get(p.a)] += stiff[s]; kk[ix.get(p.b)] += stiff[s]; } });
    for (let it = 0; it < iters; it++) {
      const t = t0 * Math.pow(0.002 / t0, it / Math.max(1, iters - 1));
      fx.fill(0); fy.fill(0);
      let cx = 0, cy = 0; for (let i = 0; i < n; i++) { cx += x[i]; cy += y[i]; } cx /= n || 1; cy /= n || 1;
      for (let i = 0; i < n; i++) {
        for (let j = i + 1; j < n; j++) {
          let dx = x[i] - x[j], dy = y[i] - y[j], d2 = dx * dx + dy * dy;
          if (d2 < 1e-12) { dx = 1e-3 * (i - j); dy = 1e-3; d2 = dx * dx + dy * dy; }
          let f = 0;
          const d = Math.sqrt(d2), room = F[i] + F[j] + P.rest / unitLen;
          if (P.rep === 0) { if (d < room) f = P.press * (room - d); }
          else if (d2 < reach2) f = (P.press * q[i] * q[j]) / Math.pow(Math.max(d, 0.3), P.rep);
          if (target) f -= mw * (d - target[i * n + j]);
          if (f === 0) continue;
          const ux = dx / d, uy = dy / d;
          fx[i] += f * ux; fy[i] += f * uy; fx[j] -= f * ux; fy[j] -= f * uy;
        }
        if (P.grav) { fx[i] -= P.grav * q[i] * (x[i] - cx); fy[i] -= P.grav * q[i] * (y[i] - cy); }
      }
      ps.forEach((p, s) => {
        if (p.broken) return;
        const i = ix.get(p.a), j = ix.get(p.b), dx = x[j] - x[i], dy = y[j] - y[i], d = Math.hypot(dx, dy) || 1e-6;
        const f = stiff[s] * (d - rest[s]);
        fx[i] += (f * dx) / d; fy[i] += (f * dy) / d; fx[j] -= (f * dx) / d; fy[j] -= (f * dy) / d;
      });
      let moved = 0;
      for (let i = 0; i < n; i++) { const gx = fx[i] / kk[i], gy = fy[i] / kk[i], m = Math.hypot(gx, gy); if (m > 0) { const s = Math.min(m, t) / m; x[i] += gx * s; y[i] += gy * s; moved = Math.max(moved, m); } }
      residual = moved;
    }
  };
  let residual = 0;
  const strain = (s) => { const p = ps[s], i = ix.get(p.a), j = ix.get(p.b); return (Math.hypot(x[j] - x[i], y[j] - y[i]) - rest[s]) / rest[s]; };
  settle(P.iters, 0.5 * R0);
  const order = [];
  for (let b = 0; b < P.maxBreaks; b++) {
    let worst = -1, wr = 1;
    ps.forEach((p, s) => { if (p.broken || p.fixed) return; const r = strain(s) / holds[s]; if (r > wr) { wr = r; worst = s; } });
    if (worst < 0) break;
    const p = ps[worst]; p.broken = true; p.breakRatio = wr; order.push(p);
    for (const e of p.edges) { const h = ix.get(e.from); pillArea[h] += (sizes.pillWidth[pillKey(e.to, node(e.from).container)] || sizes.pillWidth[e.to] || 120) * K.pillHeight; }
    refit(); charge();
    settle(P.warm, 0.05 * R0);
  }
  ps.forEach((p, s) => { if (!p.broken) p.hold = p.fixed ? Infinity : holds[s] / Math.max(1e-9, strain(s)); });
  return { board, notes: n, links: ps.length, broken: order.length, order, ps, residual };
}

// ---- run every board (or the named ones) ----
const only = args.boards ? new Set(args.boards.split(',')) : null;
const boards = [...pairsOn.keys()].sort(byKey).filter((b) => !only || only.has(b));
const t0 = process.hrtime.bigint();
const results = boards.map(simulate);
const secs = Number(process.hrtime.bigint() - t0) / 1e9;

// the order every link inside a board ends in: the broken in the order they broke (the first the lightest), then the held by how much they
// held to spare (the least first); a weight 1..49 for broken links and 50..100 for held, both directions of a pair alike
const EMIT = args.emit || 'sim';
const weightOf = new Map(), cutKeys = [];
for (const r of results) {
  let broken = r.order, held = r.ps.filter((p) => !p.broken).sort((x, y) => x.hold - y.hold || byKey(x.key, y.key));
  if (EMIT === 'simcut') {
    const bySim = r.ps.slice().sort((x, y) => x.sim - y.sim || byKey(x.key, y.key));
    broken = bySim.filter((p) => p.broken); held = bySim.filter((p) => !p.broken);
  } else if (EMIT === 'below') {
    const bySim = r.ps.slice().sort((x, y) => x.sim - y.sim || byKey(x.key, y.key)), under = (p) => p.prob != null && p.prob < +args.below;
    broken = bySim.filter(under); held = bySim.filter((p) => !under(p));
  } else if (EMIT !== 'sim' && !['same', 'half', 'frac', 'judges', 'chips', 'simjudges', 'simchips'].includes(EMIT)) {
    throw new Error('--emit is sim, simcut, same, half, frac, below, judges, chips, simjudges or simchips');
  } else if (EMIT !== 'sim') {
    const bySim = r.ps.slice().sort((x, y) => x.sim - y.sim || byKey(x.key, y.key)), m = EMIT === 'half' ? Math.floor(r.ps.length / 2) : EMIT === 'frac' ? Math.floor(r.ps.length * +args.frac) : countOf ? countOf.get(r.board) ?? 0 : r.order.length;
    broken = bySim.slice(0, m); held = bySim.slice(m);
  }
  const out = new Set(broken);
  broken.forEach((p, i) => { p.w = 1 + Math.round(48 * (broken.length > 1 ? i / (broken.length - 1) : 0)); p.score = -1e6 + i; });
  held.forEach((p, i) => { p.w = 50 + Math.round(50 * (held.length > 1 ? i / (held.length - 1) : 1)); p.score = EMIT !== 'sim' ? p.sim : Number.isFinite(p.hold) ? p.hold : 1e6; });
  for (const p of r.ps) for (const e of p.edges) { weightOf.set(e.from + SEP + e.to, p.w); if (out.has(p)) cutKeys.push(e.from + SEP + e.to); }
  r.emitted = broken.length;
}

// ---- against the judges ----
const rows = rd('./judge/rows.json');
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
// judges, chips: the judges' cut on the boards they judged, nothing elsewhere; simjudges, simchips: on each of those boards as many links
// as that cut takes there, but the least alike
if (['judges', 'chips', 'simjudges', 'simchips'].includes(EMIT)) {
  const theirs = (r) => (EMIT.endsWith('judges') ? cls(r) !== 'keep' : cls(r) === 'chip');
  const take = new Set(rows.filter(theirs).map((r) => [r.a, r.b].sort(byKey).join(SEP)));
  cutKeys.length = 0;
  for (const r of results) {
    let ps = r.ps.filter((p) => take.has(p.key));
    if (EMIT.startsWith('sim')) ps = r.ps.slice().sort((x, y) => x.sim - y.sim || byKey(x.key, y.key)).slice(0, ps.length);
    for (const p of ps) for (const e of p.edges) cutKeys.push(e.from + SEP + e.to);
  }
}
const pairOf = new Map(results.flatMap((r) => r.ps.map((p) => [p.key, p])));
const pk = (r) => [r.a, r.b].sort(byKey).join(SEP);
const judged = rows.filter((r) => pairOf.has(pk(r)));
const tally = (xs) => ['chip', 'split', 'keep'].map((t) => xs.filter((r) => cls(r) === t).length).join('/');
const auc = (f) => { const Kp = judged.filter((r) => cls(r) === 'keep'), Ch = judged.filter((r) => cls(r) === 'chip'); let w = 0; for (const k of Kp) for (const c of Ch) { const a = f(k), b = f(c); w += a > b ? 1 : a === b ? 0.5 : 0; } return +(w / Kp.length / Ch.length).toFixed(3); };
const brokenJ = judged.filter((r) => pairOf.get(pk(r)).broken), heldJ = judged.filter((r) => !pairOf.get(pk(r)).broken);
const meanRank = (xs) => (xs.length ? +(xs.reduce((s, p) => s + p.rank, 0) / xs.length).toFixed(2) : null);
const brokenAll = results.flatMap((r) => r.order);
// the control: on each board, as many links broken as the simulation broke there, but chosen by similarity alone (the least alike first)
const ctrlBroken = new Set();
for (const r of results) r.ps.slice().sort((x, y) => x.sim - y.sim || byKey(x.key, y.key)).slice(0, r.order.length).forEach((p) => ctrlBroken.add(p.key));
const ctrlHeld = judged.filter((r) => !ctrlBroken.has(pk(r)));
const ctrlRank = meanRank(results.flatMap((r) => r.ps.filter((p) => ctrlBroken.has(p.key))));
const share = (xs) => (xs.length ? `${Math.round((100 * xs.filter((r) => cls(r) === 'keep').length) / xs.length)}% keep, ${Math.round((100 * xs.filter((r) => cls(r) === 'chip').length) / xs.length)}% chip` : '');
const summary = {
  physics: PHYS, snap: P.snap, sfloor: P.sfloor, refmass: P.refmass, press: P.press, rankby: P.rankby, others: args.others || 'pills', lambda: PHYS === 'meaning' ? P.lambda : undefined, rep: P.rep,
  residual: +Math.max(...results.map((r) => r.residual)).toExponential(1),
  boards: results.length, links: all.filter((p) => !only || only.has(p.board)).length, broken: brokenAll.length, emit: EMIT, cut: cutKeys.length, seconds: +secs.toFixed(1),
  judged: judged.length, brokenJudged: `${brokenJ.length} (${tally(brokenJ)})`, heldJudged: `${heldJ.length} (${tally(heldJ)})`,
  heldShare: heldJ.length ? `${Math.round((100 * heldJ.filter((r) => cls(r) === 'keep').length) / heldJ.length)}% keep, ${Math.round((100 * heldJ.filter((r) => cls(r) === 'chip').length) / heldJ.length)}% chip` : '',
  aucOrder: auc((r) => pairOf.get(pk(r)).score), aucSim: auc((r) => pairOf.get(pk(r)).sim), brokenMeanRank: meanRank(brokenAll),
  control: `held ${ctrlHeld.length} (${tally(ctrlHeld)}) ${share(ctrlHeld)}`,
};
// --line=LABEL: one line for a person instead of the summary
const pctOf = (xs) => (xs.length ? `${Math.round((100 * xs.filter((r) => cls(r) === 'keep').length) / xs.length)}% keep / ${Math.round((100 * xs.filter((r) => cls(r) === 'chip').length) / xs.length)}% chip` : '');
if (args.line) console.log(`${(args.line + ', threshold ' + P.snap).padEnd(32)} broken ${String(summary.broken).padStart(4)} of ${summary.links} | arrows left: ${pctOf(heldJ)} | similarity, the same counts: ${pctOf(ctrlHeld)} | mean similarity rank of what broke ${summary.brokenMeanRank}, of similarity's own cut ${ctrlRank}`);
else console.log(JSON.stringify(summary));
if (args.each) for (const r of results) if (!only || only.has(r.board)) {
  const J = rows.filter((x) => 'module:' + x.board === r.board || (r.board === 'root' && x.board === 'root'));
  const bj = J.filter((x) => pairOf.get(pk(x))?.broken);
  console.log(`  ${r.board.padEnd(28)} notes ${String(r.notes).padStart(3)} links ${String(r.links).padStart(3)} broken ${String(r.broken).padStart(3)}${J.length ? `  judged broken ${bj.length} (${tally(bj)}) of ${J.length} (${tally(J)})` : ''}`);
}
if (args.bands) {
  const bands = [[0, 10], [10, 20], [20, 40], [40, 80], [80, Infinity]];
  console.log('  broken by how many links a board has: ' + bands.map(([a, b]) => { const rs = results.filter((r) => r.links >= a && r.links < b), L = rs.reduce((s, r) => s + r.links, 0), B = rs.reduce((s, r) => s + r.broken, 0); return `${a}${b === Infinity ? '+' : '-' + (b - 1)}: ${rs.length} boards, ${B} of ${L} (${Math.round((100 * B) / Math.max(1, L))}%)`; }).join('; '));
}
if (args.auc) process.exit(0);

fs.mkdirSync(OUT, { recursive: true });
const g2 = JSON.parse(JSON.stringify(graph));
for (const e of g2.edges) { const w = weightOf.get(e.from + SEP + e.to); if (w != null) e.layout = { ...(e.layout || {}), weight: w }; }
fs.writeFileSync(OUT + '/graph.json', JSON.stringify(g2));
fs.writeFileSync(OUT + '/cut.json', JSON.stringify(cutKeys.map((k) => k.split(SEP))));
fs.writeFileSync(OUT + '/stats.json', JSON.stringify({ summary, boards: results.map((r) => ({ board: r.board, notes: r.notes, links: r.links, broken: r.broken, order: r.order.map((p) => [p.a, p.b, +p.breakRatio.toFixed(3), +p.rank.toFixed(3)]) })) }, null, 1));
