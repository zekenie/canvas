// The whole plan for a graph document: every board's links cut and laid out (cut.mjs), then the apply document and every board's health.
import { Layouter } from './layout.mjs';
import { cutBoard } from './cut.mjs';
import { buildBoards, buildDrawing, buildReport } from './emit.mjs';
import { buildModel, kindsTable } from './model.mjs';
import { byTitle } from './util.mjs';
import { DEFAULT_VIEW } from './elk.mjs';
import { healthOf } from './health.mjs';

// view is the room the view has for a board fit to it ({w, h}); one is assumed when it is left out;
// ranks is which way ranked children run (rows or columns; left out, the document's layout.ranks, else whichever the view shows larger)
// refused is the app's own refusals of edges (measure's, as sizes.mjs's refusedEdges reads them); current the drawing's rows now (`currentFrom`);
// changed the drawing's shapes a person changed (`:changed`'s rows, `changedFrom`): those they moved, resized or put elsewhere are held where they are
export const DEFAULTS = { view: null, ranks: null, progress: null, refused: null, current: null, changed: null };
const SLOW = 10000;   // a board that takes longer than this to lay out is said as it ends (progress), so a long plan is seen to move

/**
 * Where the drawing's shapes are now, from `canvas query ':drawn-by("NAME")' --brief` (its rows, or the answer with `rows`): the box of each key
 * (`at`: [[x, y], [w, h]], world units), and the key of the drawing's shape it is in now (the row's `in`, which the app says: the frame, or the
 * shape whose board it is on, when the drawing made that one; none: the drawing's board). A row's `inside` is names, not keys, and is not read.
 * Besides the shapes there is a row for each pill an edge made (`pill <edge key>`, with a place) and for each edge (`edge <edge key>`, with no
 * place): its `connection` names the ends it joins (`from`, `to`: the shapes, a pill resolved to what it stands for) and `via` the pill it
 * runs through at an end (`via.to.id`), none for an arrow between its notes. `edges` is those, by the pair of ends (resolved here, by the
 * keys of the shapes' rows): {via: the pill's id, or null}; `pillMaker` the pair that makes each pill (the edge whose key the pill's row names).
 */
export function currentFrom(answer) {
  const list = (Array.isArray(answer) ? answer : (answer && (answer.rows || answer.results)) || []).filter((r) => r && typeof r.key === 'string');
  const placed = (r) => Array.isArray(r.at) && Array.isArray(r.at[0]) && Array.isArray(r.at[1]);
  const at = new Map(), holder = new Map(), keyOfId = new Map(), edgeRows = [];
  for (const r of list) {
    if (r.key.startsWith('edge ') && r.connection && !placed(r)) { edgeRows.push(r); continue; }
    if (!placed(r)) continue;
    at.set(r.key, { x: r.at[0][0], y: r.at[0][1], w: r.at[1][0], h: r.at[1][1] });
    holder.set(r.key, typeof r.in === 'string' ? r.in : null);
    if (typeof r.id === 'string') keyOfId.set(r.id, r.key);
  }
  // each edge row's pair of ends and the id of the pill it runs through; the pair that makes a pill is the one whose edge's key the pill's row has
  const edges = new Map(), byKey = new Map(), pillKeyOfId = new Map();
  for (const r of edgeRows) {
    const c = r.connection, a = c.from && keyOfId.get(c.from.id), b = c.to && keyOfId.get(c.to.id);
    if (a == null || b == null) continue;
    const pair = a + '\u0000' + b, via = c.via && c.via.to && typeof c.via.to.id === 'string' ? c.via.to.id : null;
    byKey.set(r.key.slice(5), pair);
    const had = edges.get(pair);
    if (!had || (via != null && had.via == null)) edges.set(pair, { via });
  }
  for (const [id, key] of keyOfId) if (key.startsWith('pill ')) pillKeyOfId.set(id, key);
  const pillMaker = new Map();
  for (const [id, key] of pillKeyOfId) { const pair = byKey.get(key.slice(5)); if (pair != null) pillMaker.set(id, pair); }
  return { at, holder, edges, pillMaker, pillKeyOfId };
}

/** `:changed("NAME")`'s answer (its rows, or the answer with `rows`): the drawing's shapes that differ from what it last wrote, by key, each with `changed`, the list of what a person changed. */
export function changedFrom(answer) {
  const list = Array.isArray(answer) ? answer : (answer && (answer.rows || answer.results)) || [];
  const out = new Map();
  for (const r of list) if (r && typeof r.key === 'string' && Array.isArray(r.changed)) out.set(r.key, new Set(r.changed));
  return out;
}

/**
 * Whether what a person changed holds a shape where they put it: it was moved, resized, put on another board, or in another frame (which the app
 * words by the name of the kind that holds shapes: `frameWord`, from the kinds).
 */
export const heldChange = (set, frameWord) => !!set && (set.has('moved') || set.has('resized') || set.has('board') || (!!frameWord && set.has(frameWord)));

/**
 * `currentFrom`'s answer for a model: each container's members now, by the container ids the layout has (`f:<frame key>`, `b:<subboard key>`,
 * `b:root`), and the key of the shape that holds each pill the drawing drew (`pillIn`: `pill <edge key>` -> the frame, or the shape whose
 * board it is on; null for the top of the root board). `person`: the keys of the shapes a person put where they are (`changed`), and `personPills`
 * the pills they moved, by row key.
 */
function currentFor(model, cur, changed) {
  const members = new Map(), pillIn = new Map();
  for (const [key, up] of cur.holder) {
    // the drawing's own shapes that are no node (the pills and arrows its edges drew, keyed `pill …` and `edge …`) hold no place in a container
    if (!model.node(key)) { if (key.startsWith('pill ')) pillIn.set(key, up); continue; }
    const h = up == null ? null : model.node(up);
    // a holder the document no longer has matches no container: the one it held is not what the drawing holds now
    const cid = up == null ? 'b:root' : h ? (h.holds === 'shapes' ? 'f:' : 'b:') + up : 'x:' + up;
    if (!members.has(cid)) members.set(cid, new Set());
    members.get(cid).add(key);
  }
  const person = new Set(), personPills = new Set(), frameKind = [...model.kinds.values()].find((k) => k.holds === 'shapes');
  if (changed) for (const [key, set] of changed) {
    if (!heldChange(set, frameKind && frameKind.kind) || !cur.at.has(key)) continue;
    if (key.startsWith('pill ')) personPills.add(key); else if (model.node(key)) person.add(key);
  }
  return { at: cur.at, members, pillIn, edges: cur.edges, pillMaker: cur.pillMaker, pillKeyOfId: cur.pillKeyOfId, person, personPills, changed: changed || new Map() };
}

/** `sizes` is sizesFrom's answer, or a function of the model that gives it (the model is built here, with the edges the app refuses left out). */
/**
 * The document with each shape a person carried into another container (changed: `frame` or `board`, and the file's row names a holder that is not
 * the document's) put in the container the file has it in: they put it there and it stays there, whatever the document says. The shapes moved, by
 * key, with the holder they are now in (null: the drawing's own board), and the document's copy; a holder the document lacks, or that would hold a
 * shape in itself, leaves the document's alone.
 */
export function carried(graph, cur, changed, kinds) {
  const out = new Map();
  if (!cur || !changed || !graph || !Array.isArray(graph.nodes)) return { graph, carried: out };
  const table = kinds instanceof Map ? kinds : kindsTable(kinds), by = new Map(graph.nodes.map((n) => [n.key, n]));
  const frameKind = [...table.values()].find((k) => k.holds === 'shapes');
  for (const [key, set] of [...changed].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
    const n = by.get(key);
    if (!n || key.startsWith('pill ') || !cur.at.has(key) || !heldChange(set, frameKind && frameKind.kind) || !(set.has('board') || (!!frameKind && set.has(frameKind.kind)))) continue;
    const was = n.in == null ? null : n.in, up = cur.holder.get(key);
    if (up === undefined || up === was) continue;
    if (up != null) {
      const h = by.get(up), k = h && table.get(h.kind);
      if (!h || !k || !k.holds) continue;
      const upOf = (k) => { const q = by.get(k); return out.has(k) ? out.get(k) : q && q.in != null ? q.in : null; };
      let ring = false;
      for (let p = up, guard = 0; p != null && guard < 1000; guard++, p = upOf(p)) if (p === key) { ring = true; break; }
      if (ring) continue;
    }
    out.set(key, up);
  }
  if (!out.size) return { graph, carried: out };
  const nodes = graph.nodes.map((n) => {
    if (!out.has(n.key)) return n;
    const c = Object.assign({}, n), up = out.get(n.key);
    if (up == null) delete c.in; else c.in = up;
    return c;
  });
  return { graph: Object.assign({}, graph, { nodes }), carried: out };
}

export async function planGraph(graph0, sizesOrFn, options, elk, now) {
  const opts = Object.assign({}, DEFAULTS, options);
  const cur0 = opts.current ? (opts.current.holder ? opts.current : currentFrom(opts.current)) : null;
  const changed0 = opts.changed ? (opts.changed instanceof Map ? opts.changed : changedFrom(opts.changed)) : null;
  const { graph, carried: carriedTo } = carried(graph0, cur0, changed0, opts.kinds);
  const model = buildModel(graph, opts.kinds, { refused: opts.refused });
  const sizes = typeof sizesOrFn === 'function' ? sizesOrFn(model) : sizesOrFn;
  const current = cur0 ? currentFor(model, cur0, changed0) : null;
  // the view every board is laid out for: the one given, else one assumed
  const view = opts.view && opts.view.w > 0 && opts.view.h > 0 ? { w: opts.view.w, h: opts.view.h, from: 'given' } : { w: DEFAULT_VIEW.w, h: DEFAULT_VIEW.h, from: 'assumed' };
  const ranks = opts.ranks || model.ranks || 'auto';
  const t0 = (now || Date.now)();
  const results = new Map();
  // inner boards first: what is a pill target there costs less on the outer ones
  const order = model.boards.slice().sort((a, b) => model.boardDepth.get(b) - model.boardDepth.get(a) || byTitle(a, b));
  let done = 0;
  for (const board of order) {
    // every pill beside the shape whose link it is (a spine's shared), each container placed as stars, or in rows where it is ranked or its
    // links have no cycle, and its links cut until it draws with no crossing (cut.mjs)
    const layouter = new Layouter(model, board, sizes, { view, ranks, spines: true }, elk);
    // drawing again in place (`current`): the cut is decided as it is afresh, then the board laid out from where the drawing's shapes are and mended
    const r = await cutBoard(model, layouter, { now, current });
    results.set(board, r);
    done++;
    if (opts.progress && r.report.ms > SLOW) opts.progress(`plan: board "${board}" (${layouter.leaves.length} shapes) took ${Math.round(r.report.ms / 1000)} s; ${done} of ${order.length} boards laid out`);
  }
  const ordered = new Map(model.boards.map((b) => [b, results.get(b)]));
  const plan = buildBoards(model, ordered, opts);
  const drawing = buildDrawing(model, graph, ordered);
  const report = buildReport(model, ordered, { layoutMs: (now || Date.now)() - t0, perBoard: Object.fromEntries(model.boards.map((b) => [b, ordered.get(b).report.ms])) });
  report.view = view;
  report.redraw = !!current;
  report.clusters = (graph.layout && graph.layout.clustered) || null;
  if (carriedTo.size) report.carried = [...carriedTo].map(([key, holder]) => ({ key, in: holder }));
  // every board's health, measured on the drawing the app will get: each board's in its report, the totals beside them
  const health = healthOf(model, drawing, sizes, { view, ms: new Map(model.boards.map((b) => [b, ordered.get(b).report.ms])) });
  for (const b of model.boards) report.boards[b].health = health.boards[b];
  report.health = health.totals;
  return { model, results: ordered, plan, drawing, report };
}
