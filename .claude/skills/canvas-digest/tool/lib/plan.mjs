// The whole plan for a digest: every board laid out and its promotions decided, then the files.
import { Layouter } from './layout.mjs';
import { runBoard } from './promote.mjs';
import { buildPlan, buildReport } from './emit.mjs';
import { buildModel } from './model.mjs';
import { byTitle } from './util.mjs';
import { DEFAULT_VIEW } from './elk.mjs';

// promote: false takes every promotion off (only the pills that cross boards or ask via: reference); mess: null is policy.mess, else the default 0.1;
// cap (0..1, the share of a board's leaves), marginPills and popular (arrows) override the dial's; prefer is how many pills' prices each extra pill of a hub in one frame must save
// view is the room the view has for a board fit to it ({w, h}: the driver hands on the window's, from `canvas boards`; one is assumed when it is left out);
// ranks is which way ranked children run (rows or columns; left out, the digest's policy.ranks, else whichever the view shows larger)
export const DEFAULTS = { promote: true, split: true, cap: null, marginPills: null, popular: null, prefer: null, mess: null, pack: 'auto', view: null, ranks: null };

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
  for (const board of order) {
    const layouter = new Layouter(model, board, sizes, { pack: opts.pack, view, ranks }, elk);
    results.set(board, await runBoard(model, layouter, { promote: opts.promote && model.promote, now, split: opts.split, cap: opts.cap, popular: opts.popular, prefer: opts.prefer, debug: opts.debug, margin: opts.marginPills == null ? null : opts.marginPills * model.mu }));
  }
  const ordered = new Map(model.boards.map((b) => [b, results.get(b)]));
  const { plan, runs } = buildPlan(model, sizes, ordered, opts);
  const report = buildReport(model, ordered, { loopMs: (now || Date.now)() - t0, perBoard: Object.fromEntries(model.boards.map((b) => [b, ordered.get(b).report.ms])) });
  report.view = view;
  return { model, results: ordered, plan, runs, report };
}
