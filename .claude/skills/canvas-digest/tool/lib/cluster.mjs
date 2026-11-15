// Clusters: before the plan, each container's shapes are grouped by how tightly their links hold them, and the links between two groups are
// marked cut (`layout.cut`), pills before anything is placed, the engine's own further cuts going the loosest first (`layout.weight`). The groups add no
// shape to the document: no frame, no container, nothing moves across what the lens drew; they only weigh the links and cut the ones between
// groups, and a link cut so can come back as an arrow once everything is placed (restore.mjs). A pure transform of a graph document: the plan then
// lays the result out as any document.
// The groups are Louvain's (modularity over the container's links, each weighing as tight as the two notes are alike: the app's `canvas measure
// --tightness`, ranked within the board), the notes taken in key order, so the same document and the same tightness give the same groups. The spike
// that found this is docs/plans/board-layout/spike (cluster.mjs); docs/plans/board-layout/README.md says what it found.
import { buildModel, kindsTable, holdsShapes } from './model.mjs';
import { refusedEdges, tightnessFrom } from './sizes.mjs';
import { cuttable } from './cut.mjs';
import { byTitle } from './util.mjs';
import { carried, currentFrom, changedFrom } from './plan.mjs';

const SEP = '\u0000';
/** The resolution the groups are found at: smaller groups than Louvain's usual 1 (a higher resolution makes smaller ones). */
export const RESOLUTION = 1.5;

/**
 * Modularity at resolution `res` over a weighted graph of `n` nodes, `links` [i, j, w]: each node's cluster, numbered 0.. in the order the clusters
 * first appear. The nodes are taken in index order, a tie goes to the lower cluster, a gain counts past 1e-12, at most 20 levels of 100 passes each.
 */
export function louvain(n, links, res = 1) {
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
        let best = ci, gain = (kin.get(ci) || 0) - (res * tot[ci] * deg[i]) / m2;
        for (const [cj, w] of [...kin].sort((x, y) => x[0] - y[0])) { const g = w - (res * tot[cj] * deg[i]) / m2; if (g > gain + 1e-12) { gain = g; best = cj; } }
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

/**
 * The document with the links between groups cut: {graph, report}. `measure` is `canvas measure`'s answer for the document (its `tightness` member and
 * the edges the app refuses); `opts.kinds` is `canvas kinds`' answer; `opts.res` the resolution the groups are found at (RESOLUTION, 1.5, by default: a
 * higher one makes smaller groups). Throws on a document that has been clustered already (`layout.clustered`). A redraw (`opts.current`, the drawing's
 * rows now; `opts.changed`, what a person changed) starts from the shapes a person carried into another container (plan.mjs's `carried`), so a note is
 * grouped where it is now; the groups are then found afresh over the document as it is, only to weigh and cut its links: nothing of the file's is kept here.
 *
 * On each board that has a link between two notes (a pair, however many links it holds, both ways; a pair with a shape that holds shapes is no pair):
 *   - a pair weighs 0.1 for the board's loosest to 1 for its tightest (rank by tightness), or 1 for every pair where there is no tightness;
 *   - topology first: a frame of the lens's is one item in what holds it, its own notes grouped inside it, a pair lifted to the container where its
 *     two ends' containers meet, between the items there that hold them (the note, or the frame the note is in), the lifted weights added;
 *   - each container's items are grouped (louvain), and a pair between two groups is cut unless a link of it may not be a pill (marked `direct`,
 *     or into a shape no pill stands for), when it stays an arrow; nothing is added to the document and no shape changes container;
 *   - with tightness, each pair's links get the weight the engine's own cutting goes by: the cut pairs 1..49, the others 50..100, the loosest lightest.
 */
export function clusterGraph(graph, measure, opts = {}) {
  if (graph && graph.layout && graph.layout.clustered != null) throw new Error('the document has layout.clustered: it was clustered already, and the lens\'s own document is clustered once');
  const res = opts.res == null ? RESOLUTION : opts.res;
  if (!(typeof res === 'number' && res > 0 && res < Infinity)) throw new Error(`the resolution of the groups is a number above 0, not ${JSON.stringify(res)}`);
  const table = opts.kinds instanceof Map ? opts.kinds : kindsTable(opts.kinds);
  // a redraw (`opts.current`, the drawing's rows now; `opts.changed`, what a person changed): the shapes a person carried into another container are there first
  const cur = opts.current ? (opts.current.holder ? opts.current : currentFrom(opts.current)) : null;
  const changed = opts.changed ? (opts.changed instanceof Map ? opts.changed : changedFrom(opts.changed)) : null;
  // the groups are found over the carried document; what is written keeps the document's own containers (the plan carries the shapes itself)
  const own = graph, moved = cur ? carried(graph, cur, changed, table) : null;
  if (moved) graph = moved.graph;
  const model = buildModel(graph, table, { refused: refusedEdges(measure) });
  const T = tightnessFrom(measure);
  const node = (k) => model.node(k);

  // ---- each board's pairs: the links between two of its notes, every link between them a direction of the pair ----
  const pairsOn = new Map();
  for (const e of model.edges) {
    const a = node(e.from), b = node(e.to);
    if (e.from === e.to || a.board !== b.board || holdsShapes(a) || holdsShapes(b)) continue;
    const [x, y] = e.from < e.to ? [e.from, e.to] : [e.to, e.from], pk = x + SEP + y;
    if (!pairsOn.has(a.board)) pairsOn.set(a.board, new Map());
    const M = pairsOn.get(a.board);
    if (!M.has(pk)) M.set(pk, { key: pk, a: x, b: y, board: a.board, edges: [], fixed: false, tight: T.by ? (T.of.get(pk) ?? 0) : 0, absent: !!T.by && !T.of.has(pk) });
    const p = M.get(pk); p.edges.push(e); if (!cuttable(model, e)) p.fixed = true;
  }
  const byBoard = new Map();
  for (const n of model.nodes.values()) { if (!byBoard.has(n.board)) byBoard.set(n.board, []); byBoard.get(n.board).push(n); }

  const boards = [], weightOf = new Map(), cutKeys = new Set();
  for (const board of [...pairsOn.keys()].sort(byTitle)) {
    const ps = [...pairsOn.get(board).values()].sort((x, y) => byTitle(x.key, y.key));
    const byTight = ps.slice().sort((x, y) => x.tight - y.tight || byTitle(x.key, y.key));
    byTight.forEach((p, i) => { p.w = T.by ? 0.1 + 0.9 * (byTight.length > 1 ? i / (byTight.length - 1) : 1) : 1; });
    const all = byBoard.get(board) || [], ks = all.filter((n) => !holdsShapes(n)).map((n) => n.key).sort(byTitle);
    // topology first: each pair is lifted to the container where its two notes' containers meet, between the items there that hold them
    const chain = (k) => ['b:' + board].concat(node(k).frames.map((f) => 'f:' + f));
    for (const p of ps) {
      const ca = chain(p.a), cb = chain(p.b); let d = 0;
      while (d + 1 < ca.length && d + 1 < cb.length && ca[d + 1] === cb[d + 1]) d++;
      p.at = ca[d]; p.ia = d + 1 < ca.length ? node(p.a).frames[d] : p.a; p.ib = d + 1 < cb.length ? node(p.b).frames[d] : p.b;
    }
    const conts = ['b:' + board].concat(all.filter(holdsShapes).map((n) => 'f:' + n.key).sort(byTitle));
    const level = new Map(), levels = {};   // container -> Map(item key -> group); the same, as it is reported
    for (const C of conts) {
      const items = all.filter((n) => n.container === C).map((n) => n.key).sort(byTitle), ix = new Map(items.map((k, i) => [k, i]));
      // the lifted links in pair-key order, a pair of items first seen first: the sums louvain adds up are in this order
      const lifted = new Map();
      for (const p of ps) if (p.at === C) { const key = [p.ia, p.ib].sort(byTitle).join(SEP); lifted.set(key, (lifted.get(key) || 0) + p.w); }
      const cl = louvain(items.length, [...lifted].map(([key, w]) => { const [x, y] = key.split(SEP); return [ix.get(x), ix.get(y), w]; }), res);
      level.set(C, new Map(items.map((k, i) => [k, cl[i]])));
      levels[C] = Object.fromEntries(items.map((k, i) => [k, cl[i]]));
    }
    for (const p of ps) p.between = level.get(p.at).get(p.ia) !== level.get(p.at).get(p.ib);
    const groupOf = (k) => level.get('b:' + board).get(node(k).frames.length ? node(k).frames[0] : k);
    const cut = ps.filter((p) => p.between && !p.fixed), cutSet = new Set(cut);
    const linked = new Set(ps.flatMap((p) => [p.a, p.b]));
    const sizes = new Map(); for (const k of ks) if (linked.has(k)) sizes.set(groupOf(k), (sizes.get(groupOf(k)) || 0) + 1);
    // the engine's own weights (its further cuts, mend and put-back go by them): the cut pairs 1..49, the others 50..100, the loosest lightest
    if (T.by) {
      const out = byTight.filter((p) => cutSet.has(p)), held = byTight.filter((p) => !cutSet.has(p));
      out.forEach((p, i) => { p.ew = 1 + Math.round(48 * (out.length > 1 ? i / (out.length - 1) : 0)); });
      held.forEach((p, i) => { p.ew = 50 + Math.round(50 * (held.length > 1 ? i / (held.length - 1) : 1)); });
    }
    for (const p of ps) for (const e of p.edges) { if (T.by) weightOf.set(e.from + SEP + e.to, p.ew); if (cutSet.has(p)) cutKeys.add(e.from + SEP + e.to); }
    boards.push({ board, notes: ks.length, links: ps.length, cut: cut.length, clusters: [...sizes.values()].sort((a, b) => b - a), levels, missing: ps.filter((p) => p.absent).length });
  }

  // ---- the document: the cut and the weights ----
  const g2 = JSON.parse(JSON.stringify(own));
  for (const e of g2.edges || []) {
    const k = e.from + SEP + e.to, w = weightOf.get(k), c = cutKeys.has(k);
    if (w == null && !c) continue;
    const lay = Object.assign({}, e.layout || {});
    if (w != null) lay.weight = w;
    if (c) lay.cut = true;
    e.layout = lay;
  }
  g2.layout = Object.assign({}, own.layout || {}, { clustered: T.by ? { by: T.by } : { by: null, why: T.why } });
  const sum = (f) => boards.reduce((s, b) => s + f(b), 0);
  const report = {
    tightness: T.by ? { by: T.by } : { by: null, why: T.why }, resolution: res, boards,
    totals: { boards: boards.length, links: sum((b) => b.links), cut: sum((b) => b.cut), missing: sum((b) => b.missing) },
  };
  const was = moved && moved.carried.size;
  if (was) report.carried = [...moved.carried].map(([key, holder]) => ({ key, in: holder }));
  // `carried`: the document with the carried shapes in their new containers, which is what canvas measure is asked of (a pill is sized by its note's container)
  return { graph: g2, report, carried: was ? moved.graph : null };
}

/** The one line `cluster` prints; `redraw` (a --current was given): the file's arrows and pills stay, and the groups only weigh the links. */
export function clusterLine(report, redraw = false) {
  const t = report.totals, by = report.tightness;
  const how = by.by ? `tightness: ${by.by}` : `no tightness: ${by.why}; grouped by the links alone, each weighing the same`;
  const what = redraw
    ? `${t.cut} of ${t.links} linked pairs between two groups only weigh the links: the file's arrows and pills stay`
    : `${t.cut} of ${t.links} linked pairs between two groups are cut before anything is placed, and come back as arrows where their line is clear`;
  return `clusters: each container's shapes grouped by how tightly their links hold them, on ${t.boards} board(s); ${what} (${how})`
    + (t.missing > 0 ? `; ${t.missing} pair(s) had no tightness` : '');
}
