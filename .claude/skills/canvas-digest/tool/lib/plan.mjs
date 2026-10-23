// The whole plan for a digest: every board laid out and its promotions decided, then the files.
import { Layouter } from './layout.mjs';
import { runBoard } from './promote.mjs';
import { buildPlan, buildReport } from './emit.mjs';
import { buildModel } from './model.mjs';
import { byTitle, label } from './util.mjs';
import { DEFAULT_VIEW } from './elk.mjs';

// promote: false takes every promotion off (only the pills that cross boards or ask via: reference); mess: null is policy.mess, else the default 0.1;
// cap (0..1, the share of a board's leaves), marginPills and popular (arrows) override the dial's; prefer is how many pills' prices each extra pill of a hub in one frame must save
// view is the room the view has for a board fit to it ({w, h}: the driver hands on the window's, from `canvas boards`; one is assumed when it is left out);
// ranks is which way ranked children run (rows or columns; left out, the digest's policy.ranks, else whichever the view shows larger)
// existing (not a default: the plan says nothing of it) is the titles the file holds beside the drawing, which a name in a script must not be able to mean (names.mjs)
export const DEFAULTS = { promote: true, split: true, cap: null, marginPills: null, popular: null, prefer: null, mess: null, pack: 'auto', view: null, ranks: null, progress: null };
const SLOW = 10000;   // a board that takes longer than this to lay out is said as it ends (progress), so a long plan is seen to move

export async function planDigest(digest, sizes, options, elk, now) {
  const opts = Object.assign({}, DEFAULTS, options);
  const model = buildModel(digest, opts.mess);
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
    results.set(board, r);
    done++;
    if (opts.progress && r.report.ms > SLOW) opts.progress(`plan: board "${label(board)}" (${layouter.leaves.length} shapes) took ${Math.round(r.report.ms / 1000)} s; ${done} of ${order.length} boards laid out`);
  }
  const ordered = new Map(model.boards.map((b) => [b, results.get(b)]));
  const { plan, runs, statements } = buildPlan(model, ordered, opts);
  const report = buildReport(model, ordered, { loopMs: (now || Date.now)() - t0, perBoard: Object.fromEntries(model.boards.map((b) => [b, ordered.get(b).report.ms])) });
  report.view = view;
  return { model, results: ordered, plan, runs, report, statements };
}
