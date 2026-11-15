// The owner's idea, as restated on 2026-11-13: topology constrains where notes can be placed; links exist, and are tighter or looser by
// how alike their two notes are; the looser links get cut, strategically, so the graph moves toward decomposed clusters.
// Here: on each board, every link between two of its notes has a tightness from the embedding (EMB, OpenAI's text-embedding-3-large unless
// it names another: the cosine of the two notes' vectors, each centred on its board's mean), as a weight from 0.1 for the board's loosest
// link to 1 for its tightest (rank within the board). The board's notes are grouped into clusters by those weighted links alone (Louvain,
// modularity at resolution --res, nodes taken in key order, so deterministic), and only the links between clusters are cut. A loose link
// inside a cluster stays an arrow; a link the lens pins (direct) is never cut.
// --emit=control writes the comparison instead: on each board as many links cut as the clusters cut there, but the loosest anywhere.
// Out (--out): cut.json for the engine's SIM_CUT, graph.json with every link inside a board weighted (cut links 1..49, kept 50..100, the
// loosest lightest), stats.json.
// --frames=units: topology first, a frame one unit in what holds it and its own notes clustered inside it (stats.json's levels: each
// container's items and their clusters); without it a frame's notes are clustered with the board's, as if it weren't there.
// --weight=value weighs a link by how alike its two notes are (0.1 to 1 between the board's loosest and tightest), not by its rank.
//   EMB=openai-3-large DIGEST_TOOL=... node cluster.mjs [--res=1] [--weight=rank|value] [--frames=none|units] [--emit=cluster|control] [--boards=module:A,...] [--each=1] --out=DIR
import fs from 'fs';
import { readVectors } from './sim.mjs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { refusedEdges } = await import(TOOL + 'sizes.mjs');
const { cuttable } = await import(TOOL + 'cut.mjs');

const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const EMB = process.env.EMB || 'openai-3-large';
const RES = +(args.res ?? 1), EMIT = args.emit || 'cluster', OUT = args.out, FRAMES = args.frames || 'none';
const WEIGHT = args.weight || 'rank';
if (!['rank', 'value'].includes(WEIGHT)) throw new Error('--weight is rank (a link counts by its place in its board\'s order) or value (by how alike its two notes are)');
if (!['cluster', 'control'].includes(EMIT)) throw new Error('--emit is cluster or control');
if (!['none', 'units'].includes(FRAMES)) throw new Error('--frames is none (a frame\'s notes clustered with the board\'s) or units (a frame one unit in what holds it)');
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const graph = rd('./data/graph.json'), measure = rd('./data/measure.json'), kinds = rd('./data/kinds.json');
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const node = (k) => model.node(k);
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const SEP = '\u0000';

// ---- each board's notes (and cards; not frames), their vectors centred on the board's mean ----
const raw = readVectors(EMB);
const unit = (v) => { let s = 0; for (const x of v) s += x * x; s = Math.sqrt(s) || 1; return v.map((x) => x / s); };
const points = new Map();
for (const k of [...model.nodes.keys()].sort(byKey)) { const n = node(k); if (n.holds === 'shapes') continue; if (!points.has(n.board)) points.set(n.board, []); points.get(n.board).push(k); }
const vec = new Map();
for (const [, ks] of points) {
  const have = ks.filter((k) => raw[k]); if (!have.length) continue;
  const d = raw[have[0]].length, mean = new Array(d).fill(0);
  for (const k of have) for (let i = 0; i < d; i++) mean[i] += raw[k][i] / have.length;
  for (const k of have) vec.set(k, unit(raw[k].map((x, i) => x - mean[i])));
}
const cos = (a, b) => { const x = vec.get(a), y = vec.get(b); if (!x || !y) return 0; let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * y[i]; return s; };

// ---- each board's links: pairs of its notes, every link between them a direction of the pair ----
const pairsOn = new Map();
for (const e of model.edges) {
  const a = node(e.from), b = node(e.to);
  if (!a || !b || e.from === e.to || a.board !== b.board || a.holds === 'shapes' || b.holds === 'shapes') continue;
  const [x, y] = [e.from, e.to].sort(byKey), pk = x + SEP + y;
  if (!pairsOn.has(a.board)) pairsOn.set(a.board, new Map());
  const M = pairsOn.get(a.board);
  if (!M.has(pk)) M.set(pk, { key: pk, a: x, b: y, board: a.board, edges: [], fixed: false, tight: cos(x, y) });
  const p = M.get(pk); p.edges.push(e); if (!cuttable(model, e)) p.fixed = true;
}

// ---- Louvain: modularity at resolution RES over a board's weighted links; nodes taken in key order, ties to the lower community ----
function louvain(n, links) {   // links: [i, j, w]; returns each node's cluster, numbered 0..
  let comm = Array.from({ length: n }, (_, i) => i);       // original node -> current cluster
  let N = n, adj = Array.from({ length: n }, () => new Map()), deg = new Float64Array(n), m2 = 0;
  for (const [i, j, w] of links) { adj[i].set(j, (adj[i].get(j) || 0) + w); adj[j].set(i, (adj[j].get(i) || 0) + w); deg[i] += w; deg[j] += w; m2 += 2 * w; }
  if (m2 === 0) return comm;
  for (let level = 0; level < 20; level++) {
    const c = Array.from({ length: N }, (_, i) => i), tot = Float64Array.from(deg);
    let moved = false;
    for (let pass = 0; pass < 100; pass++) {
      let any = false;
      for (let i = 0; i < N; i++) {
        const ci = c[i]; tot[ci] -= deg[i];
        const kin = new Map(); for (const [j, w] of adj[i]) if (j !== i) kin.set(c[j], (kin.get(c[j]) || 0) + w);
        let best = ci, gain = (kin.get(ci) || 0) - (RES * tot[ci] * deg[i]) / m2;
        for (const [cj, w] of [...kin].sort((x, y) => x[0] - y[0])) { const g = w - (RES * tot[cj] * deg[i]) / m2; if (g > gain + 1e-12) { gain = g; best = cj; } }
        tot[best] += deg[i]; if (best !== ci) { c[i] = best; any = true; moved = true; }
      }
      if (!any) break;
    }
    if (!moved) break;
    const ids = new Map(); for (let i = 0; i < N; i++) if (!ids.has(c[i])) ids.set(c[i], ids.size);
    comm = comm.map((x) => ids.get(c[x]));
    const N2 = ids.size, adj2 = Array.from({ length: N2 }, () => new Map()), deg2 = new Float64Array(N2);
    for (let i = 0; i < N; i++) { const a = ids.get(c[i]); deg2[a] += deg[i]; for (const [j, w] of adj[i]) { const b = ids.get(c[j]); if (a !== b) adj2[a].set(b, (adj2[a].get(b) || 0) + w); } }
    N = N2; adj = adj2; deg = deg2;
  }
  return comm;
}

// ---- each board: its clusters, and the links between them cut ----
const results = [];
for (const board of [...pairsOn.keys()].sort(byKey)) {
  const ps = [...pairsOn.get(board).values()].sort((x, y) => byKey(x.key, y.key));
  const byTight = ps.slice().sort((x, y) => x.tight - y.tight || byKey(x.key, y.key));
  byTight.forEach((p, i) => { p.w = 0.1 + 0.9 * (byTight.length > 1 ? i / (byTight.length - 1) : 1); });
  // --weight=value: a link counts by how alike its two notes are, scaled from the board's loosest (0.1) to its tightest (1), not by its rank
  if (WEIGHT === 'value') { const lo = byTight[0].tight, hi = byTight[byTight.length - 1].tight; byTight.forEach((p) => { p.w = 0.1 + 0.9 * (hi > lo ? (p.tight - lo) / (hi - lo) : 1); }); }
  const ks = points.get(board) || [];
  let clusterOf, levels = null;
  if (FRAMES === 'units') {
    // topology first: a frame is one unit in what holds it, so its notes are never split among clusters outside it. Each link is lifted to
    // the container where its two notes' containers meet, between the two items there (a note, or the frame a note is in); each container's
    // items are clustered by the links lifted to it (their weights summed), and a link is cut when its two items there are in two clusters
    const chain = (k) => ['b:' + board, ...node(k).frames.map((f) => 'f:' + f)];
    for (const p of ps) {
      const ca = chain(p.a), cb = chain(p.b); let d = 0;
      while (d + 1 < ca.length && d + 1 < cb.length && ca[d + 1] === cb[d + 1]) d++;
      p.at = ca[d]; p.ia = d + 1 < ca.length ? node(p.a).frames[d] : p.a; p.ib = d + 1 < cb.length ? node(p.b).frames[d] : p.b;
    }
    const all = [...model.nodes.values()].filter((n) => n.board === board);
    const conts = ['b:' + board, ...all.filter((n) => n.holds === 'shapes').map((n) => 'f:' + n.key).sort(byKey)];
    levels = {};
    for (const C of conts) {
      const items = all.filter((n) => n.container === C).map((n) => n.key).sort(byKey), ix = new Map(items.map((k, i) => [k, i]));
      const lifted = new Map();
      for (const p of ps) if (p.at === C) { const key = [p.ia, p.ib].sort(byKey).join(SEP); lifted.set(key, (lifted.get(key) || 0) + p.w); }
      const cl = louvain(items.length, [...lifted].map(([key, w]) => { const [x, y] = key.split(SEP); return [ix.get(x), ix.get(y), w]; }));
      levels[C] = Object.fromEntries(items.map((k, i) => [k, cl[i]]));
    }
    for (const p of ps) p.between = levels[p.at][p.ia] !== levels[p.at][p.ib];
    // a note's cluster on the board is its outermost frame's, or its own
    clusterOf = (k) => levels['b:' + board][node(k).frames.length ? node(k).frames[0] : k];
  } else {
    const ix = new Map(ks.map((k, i) => [k, i]));
    const cl = louvain(ks.length, ps.map((p) => [ix.get(p.a), ix.get(p.b), p.w]));
    clusterOf = (k) => cl[ix.get(k)];
    for (const p of ps) p.between = clusterOf(p.a) !== clusterOf(p.b);
  }
  let cut = ps.filter((p) => p.between && !p.fixed);
  if (EMIT === 'control') { const free = byTight.filter((p) => !p.fixed); cut = free.slice(0, cut.length); }
  const linked = new Set(ps.flatMap((p) => [p.a, p.b]));
  const sizes = new Map(); for (const k of ks) if (linked.has(k)) sizes.set(clusterOf(k), (sizes.get(clusterOf(k)) || 0) + 1);
  results.push({ board, ps, cut: new Set(cut), notes: ks.length, links: ps.length, clusters: [...sizes.values()].sort((a, b) => b - a), clusterOf, levels });
}

// ---- weights for the engine (its own further cuts, mend and put-back go by them), and the cut ----
const weightOf = new Map(), cutKeys = [];
for (const r of results) {
  const byTight = r.ps.slice().sort((x, y) => x.tight - y.tight || byKey(x.key, y.key));
  const out = byTight.filter((p) => r.cut.has(p)), held = byTight.filter((p) => !r.cut.has(p));
  out.forEach((p, i) => { p.ew = 1 + Math.round(48 * (out.length > 1 ? i / (out.length - 1) : 0)); });
  held.forEach((p, i) => { p.ew = 50 + Math.round(50 * (held.length > 1 ? i / (held.length - 1) : 1)); });
  for (const p of r.ps) for (const e of p.edges) { weightOf.set(e.from + SEP + e.to, p.ew); if (r.cut.has(p)) cutKeys.push(e.from + SEP + e.to); }
}

// ---- against the judges, before anything is drawn ----
const rows = rd('./judge/rows.json');
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
const pairOf = new Map(results.flatMap((r) => r.ps.map((p) => [p.key, p]))), cutOf = new Map(results.flatMap((r) => r.ps.map((p) => [p.key, r.cut.has(p)])));
const pk = (r) => [r.a, r.b].sort(byKey).join(SEP);
const judged = rows.filter((r) => pairOf.has(pk(r)));
const tally = (xs) => ['chip', 'split', 'keep'].map((t) => xs.filter((r) => cls(r) === t).length).join('/');
const cutJ = judged.filter((r) => cutOf.get(pk(r))), heldJ = judged.filter((r) => !cutOf.get(pk(r)));
const pct = (xs, t) => Math.round((100 * xs.filter((r) => cls(r) === t).length) / Math.max(1, xs.length));
const total = results.reduce((s, r) => s + r.cut.size, 0), links = results.reduce((s, r) => s + r.links, 0);
const summary = { emb: EMB, res: RES, emit: EMIT, boards: results.length, links, cut: total, cutShare: +(total / links).toFixed(2), judged: judged.length,
  cutJudged: `${cutJ.length} (${tally(cutJ)})`, heldJudged: `${heldJ.length} (${tally(heldJ)}) ${pct(heldJ, 'keep')}% keep, ${pct(heldJ, 'chip')}% chip`, keepsHeld: heldJ.filter((r) => cls(r) === 'keep').length };
console.log(JSON.stringify(summary));
if (args.each) for (const r of results) {
  const J = rows.filter((x) => 'module:' + x.board === r.board || (r.board === 'root' && x.board === 'root'));
  if (!J.length && !(args.boards || '').split(',').includes(r.board)) continue;
  const cj = J.filter((x) => cutOf.get(pk(x)));
  console.log(`  ${r.board.padEnd(24)} notes ${String(r.notes).padStart(3)} links ${String(r.links).padStart(3)} cut ${String(r.cut.size).padStart(3)}  clusters ${r.clusters.join(' ')}${J.length ? `  judged cut ${cj.length} (${tally(cj)}) of ${J.length} (${tally(J)})` : ''}`);
}
if (!OUT) process.exit(0);
fs.mkdirSync(OUT, { recursive: true });
const g2 = JSON.parse(JSON.stringify(graph));
for (const e of g2.edges) { const w = weightOf.get(e.from + SEP + e.to); if (w != null) e.layout = { ...(e.layout || {}), weight: w }; }
fs.writeFileSync(OUT + '/graph.json', JSON.stringify(g2));
fs.writeFileSync(OUT + '/cut.json', JSON.stringify(cutKeys.map((k) => k.split(SEP))));
// each link's weight in the clusters (0.1 the board's loosest to 1 its tightest), for semlayout.mjs --tight and the pictures
fs.writeFileSync(OUT + '/tight.json', JSON.stringify(Object.fromEntries(results.flatMap((r) => r.ps.map((p) => [p.key, +p.w.toFixed(4)])))));
fs.writeFileSync(OUT + '/stats.json', JSON.stringify({ summary, boards: results.map((r) => ({ board: r.board, notes: r.notes, links: r.links, cut: r.cut.size, clusters: r.clusters,
  members: Object.fromEntries((points.get(r.board) || []).map((k) => [k, r.clusterOf(k)])), ...(r.levels ? { levels: r.levels } : {}) })) }, null, 1));
