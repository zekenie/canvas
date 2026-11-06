// The whole plan for a graph document: every board laid out and its promotions decided, then the apply document.
import { Layouter } from './layout.mjs';
import { runBoard } from './promote.mjs';
import { buildBoards, buildDrawing, buildReport } from './emit.mjs';
import { buildModel } from './model.mjs';
import { byTitle } from './util.mjs';
import { DEFAULT_VIEW } from './elk.mjs';

// promote: false takes every promotion off (only the pills that cross boards); mess: null is layout.mess, else the default 0.1;
// cap (0..1, the share of a board's leaves), marginPills and popular (arrows) override the dial's; prefer is how many pills' prices each extra pill of a hub in one frame must save
// view is the room the view has for a board fit to it ({w, h}); one is assumed when it is left out;
// ranks is which way ranked children run (rows or columns; left out, the document's layout.ranks, else whichever the view shows larger)
// refused is the app's own refusals of edges (measure's, as sizes.mjs's refusedEdges reads them); current the drawing's rows now (`currentFrom`)
export const DEFAULTS = { promote: true, split: true, cap: null, marginPills: null, popular: null, prefer: null, mess: null, pack: 'auto', view: null, ranks: null, progress: null, refused: null, current: null };
const SLOW = 10000;   // a board that takes longer than this to lay out is said as it ends (progress), so a long plan is seen to move

/**
 * Where the drawing's shapes are now, from `canvas query ':drawn-by("NAME")' --brief` (its rows, or the answer with `rows`): the box of each key
 * (`at`: [[x, y], [w, h]], world units), and the key of the drawing's shape it is in now (the row's `in`, which the app says: the frame, or the
 * shape whose board it is on, when the drawing made that one; none: the drawing's board). A row's `inside` is names, not keys, and is not read..
 */
export function currentFrom(answer) {
  const rows = (Array.isArray(answer) ? answer : (answer && (answer.rows || answer.results)) || []).filter((r) => r && typeof r.key === 'string' && Array.isArray(r.at) && Array.isArray(r.at[0]) && Array.isArray(r.at[1]));
  const at = new Map(), holder = new Map();
  for (const r of rows) {
    at.set(r.key, { x: r.at[0][0], y: r.at[0][1], w: r.at[1][0], h: r.at[1][1] });
    holder.set(r.key, typeof r.in === 'string' ? r.in : null);
  }
  return { at, holder };
}

/** `currentFrom`'s answer for a model: each container's members now, by the container ids the layout has (`f:<frame key>`, `b:<subboard key>`, `b:root`). */
function currentFor(model, cur) {
  const members = new Map();
  for (const [key, up] of cur.holder) {
    // the drawing's own shapes that are no node (the pills and arrows its edges drew, keyed `pill …` and `edge …`) hold no place in a container
    if (!model.node(key)) continue;
    const h = up == null ? null : model.node(up);
    // a holder the document no longer has matches no container: the one it held is not what the drawing holds now
    const cid = up == null ? 'b:root' : h ? (h.holds === 'shapes' ? 'f:' : 'b:') + up : 'x:' + up;
    if (!members.has(cid)) members.set(cid, new Set());
    members.get(cid).add(key);
  }
  return { at: cur.at, members };
}

/** `sizes` is sizesFrom's answer, or a function of the model that gives it (the model is built here, with the edges the app refuses left out). */
export async function planGraph(graph, sizesOrFn, options, elk, now) {
  const opts = Object.assign({}, DEFAULTS, options);
  const model = buildModel(graph, opts.mess, opts.kinds, { refused: opts.refused });
  const sizes = typeof sizesOrFn === 'function' ? sizesOrFn(model) : sizesOrFn;
  const current = opts.current ? currentFor(model, opts.current.holder ? opts.current : currentFrom(opts.current)) : null;
  // the view every board is laid out for: the one given, else one assumed
  const view = opts.view && opts.view.w > 0 && opts.view.h > 0 ? { w: opts.view.w, h: opts.view.h, from: 'given' } : { w: DEFAULT_VIEW.w, h: DEFAULT_VIEW.h, from: 'assumed' };
  const ranks = opts.ranks || model.ranks || 'auto';
  const t0 = (now || Date.now)();
  const results = new Map();
  // inner boards first: what is public there costs less on the outer ones
  const order = model.boards.slice().sort((a, b) => model.boardDepth.get(b) - model.boardDepth.get(a) || byTitle(a, b));
  let done = 0;
  for (const board of order) {
    // a spine turns every arrow of its shapes into a pill: none where no arrow on a board is to be one (`--promote off`, the dial at 1)
    const spines = opts.promote && model.promote && model.dial.mess < 1;
    const layouter = new Layouter(model, board, sizes, { pack: opts.pack, view, ranks, spines }, elk);
    const r = await runBoard(model, layouter, { promote: opts.promote && model.promote, now, split: opts.split, cap: opts.cap, popular: opts.popular, prefer: opts.prefer, debug: opts.debug, margin: opts.marginPills == null ? null : opts.marginPills * model.mu });
    // drawing again in place: the search above decided the pills as it does afresh (so the same document decides the same); the board is then laid out once
    // more from where the drawing's shapes are, each container whose members are what the file holds keeping them there (layout.mjs's keepCurrent)
    if (current) {
      layouter.current = current; layouter.kept = new Set();
      layouter.hold = false; layouter.warm = false; layouter.force = null;
      r.layout = await layouter.layout(r.state);
      r.report.kept = [...layouter.kept].sort(byTitle);
    }
    results.set(board, r);
    done++;
    if (opts.progress && r.report.ms > SLOW) opts.progress(`plan: board "${board}" (${layouter.leaves.length} shapes) took ${Math.round(r.report.ms / 1000)} s; ${done} of ${order.length} boards laid out`);
  }
  const ordered = new Map(model.boards.map((b) => [b, results.get(b)]));
  const plan = buildBoards(model, ordered, opts);
  const drawing = buildDrawing(model, graph, ordered);
  const report = buildReport(model, ordered, { loopMs: (now || Date.now)() - t0, perBoard: Object.fromEntries(model.boards.map((b) => [b, ordered.get(b).report.ms])) });
  report.view = view;
  return { model, results: ordered, plan, drawing, report };
}
