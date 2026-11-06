// The commands. Everything that touches a file goes through `io`, which main.js builds for jsc or node.
import { kindsRead } from './model.mjs';
import { sizesFrom, refusedEdges } from './sizes.mjs';
import { loadElk } from './elk.mjs';
import { planGraph, DEFAULTS } from './plan.mjs';
import { checkGraph } from './check.mjs';
import { TOOL_DIR } from './util.mjs';

export const USAGE = `digest tool (the driver, ./digest, runs these; the tool never runs canvas)
  check <graph.json> --kinds kinds.json                                {"errors": [...], "warnings": [...]}; kinds.json is canvas kinds' answer, which every command that reads a graph takes
  check-text <check.json>                                              what check found, as "error: ..." and "warning: ..." lines ("ok" for none)
  plan <graph.json> <measure.json> <outdir> --kinds kinds.json [--mess 0..1] [--promote off] [--prefer N] [--cap 0..1] [--margin PILLS] [--popular ARROWS]
                                             [--view WxH] [--ranks rows|columns|auto] [--current current.json]
                                                                       writes <outdir>/drawing.json (the document canvas apply takes) and report.json;
                                                                       measure.json is canvas measure's answer for the graph; --current: canvas query ':drawn-by("NAME")' --brief
                                                                       (a container whose members are what the file holds now keeps them where they are)
  name <graph.json>                                                    the drawing's name
  drawn-by <graph.json>                                                the canvas query that finds the drawing's shapes (:drawn-by("NAME"))
  view <boards.json> [id]                                              the room a board's window has for a board fit to it (canvas boards' view), WxH
  count nodes|rows <answer.json>                                       how many nodes canvas measure measured, or rows canvas query answered
  refusals <error.json> [drawing.json]                                 the key and the app's words for each refusal of canvas apply (its JSON on standard error), one a line; with drawing.json, an edge by its ends
  applied <apply.json> [drawing.json]                                  what canvas apply answered, in a few lines: shapes by what was done, deleted, and each warning by key (an edge by its ends)
  extract kinds|errors <answer.json>                                   what the driver reads out of canvas's JSON (or check's), printed as JSON

THE MESS DIAL: --mess 0..1 (or "layout": {"mess": 0.5} in the graph; the flag wins; default 0.1). 0 is tidy, 1 is loose. One number sets all of:
  mess        0.0   0.2   0.5   0.8   1.0
  mu (pill)   2.0   2.8   4.0   5.2   6.0    = 2 + 4 mess            the price of a pill in the cost C
  popular     4     6     9     12    14     = round(4 + 10 mess)    on a board not good enough as it is, a node with this many arrows a move would turn into pills
                                                                      (pointing at it, or leaving it) is moved first, the most arrows first, whatever its trial
                                                                      measures: promoted, or fanned out
  longest     1000  1600  2500  3400  4000   = round(1000 + 3000 mess)  an arrow longer than this (in the board's units) becomes a pill of its own beside its start
  cap         50%   40%   25%   10%   0%     = 0.5 (1 - mess)        most leaves moved by judgment (at least 1 unless mess = 1): the popular ones count, and are never held back
  margin      the gain a promotion must beat: the layout's measured noise (3 sd) times (0.5 + mess), never under round(1 + 2 mess) pills
  X/arrow     0     .04   .10   .16   .20    = 0.2 mess              good enough: crossings per arrow at most
  Fx/arrow    0     .02   .05   .08   .10    = 0.1 mess              good enough: frame-border crossings per arrow at most
  NE/arrow    0     0     0     .12   .20    = 0.4 max(0, mess-.5)   good enough: arrows over shapes per arrow at most
  aspect      2     2.4   3     3.6   4      = 2 + 2 mess            good enough: the board at most this many times too wide for the view's shape, or too tall
The popular moves come in the same order at every mess; the dial says how far down them the loop goes. --cap, --margin and --popular override the dial's.
--promote off: no hub is promoted, only the pills that cross boards. --prefer N (default 2): each extra pill of a hub in one frame must save N pills' prices.
A move promotes a node many point at (it is made public, and each user reaches it through a pill beside the user) or fans out a node that points at many (each of
its uses is a pill beside it, and what they stand for is made public). After the popular ones, the loop stops when the board is good enough, when the best candidates
cut the cost by no more than the margin, or at the cap (the report says which).

THE VIEW: --view WxH is the room the window has for a board fit to it. Every board is laid out toward that shape, so that it fills the view when it is fit to it: its
containers' arrows run down or across, a stress layout is stretched, and ranked children run as rows or as columns, whichever the view shows larger (--ranks rows or
columns says which outright, over the graph's layout.ranks). A board the view shows whole at its own size is left whatever shape it is. An arrow is too long as the view
sees it: further across a wide view than down it. With no --view, a view of 1440 x 960 is assumed, and the summary says so.`;

function parseFlags(args) {
  const pos = [], flags = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) flags[args[i].slice(2)] = args[++i]; else pos.push(args[i]);
  }
  return { pos, flags };
}

const onOff = (v, d) => (v == null ? d : v === 'on' || v === 'true' || v === 'yes');
/** --view 1440x900: the view's size, width by height. */
function viewOf(v) {
  if (v == null) return null;
  const m = /^(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)$/.exec(v);
  if (!m || !(+m[1] > 0) || !(+m[2] > 0)) throw new Error(`--view takes a width and a height, as in 1440x900, not ${v}`);
  return { w: +m[1], h: +m[2] };
}
function ranksOf(v) {
  if (v == null) return null;
  if (!['auto', 'rows', 'columns'].includes(v)) throw new Error(`--ranks is auto, rows or columns, not ${v}`);
  return v;
}
const num = (v) => (v == null ? null : +v);

export async function run(args, io) {
  const { pos, flags } = parseFlags(args);
  const cmd = pos[0];
  const json = (p) => JSON.parse(io.readText(p));
  if (cmd === 'check') {
    io.print(JSON.stringify(checkGraph(json(pos[1]), { kinds: flags.kinds ? json(flags.kinds) : null })));
    return;
  }
  if (cmd === 'check-text') { io.print(checkText(json(pos[1]))); return; }
  if (cmd === 'name') { const g = json(pos[1]); if (typeof g.drawing === 'string' && g.drawing) io.print(g.drawing); return; }
  if (cmd === 'drawn-by') { const g = json(pos[1]); io.print(`:drawn-by(${JSON.stringify(String(g.drawing))})`); return; }
  // the room the window of a board has for a board fit to it, as `canvas boards` says it (`view`), as WxH: the board whose id is given, else the one in front
  if (cmd === 'view') {
    const boards = json(pos[1]), want = pos[2];
    const list = Array.isArray(boards) ? boards : boards.boards || [];
    const b = list.find((x) => want ? String(x.id) === String(want) : x.frontmost) || (want ? null : list[0]);
    if (b && Array.isArray(b.view) && b.view.length === 2) io.print(`${Math.round(b.view[0])}x${Math.round(b.view[1])}`);
    return;
  }
  if (cmd === 'count') { const a = json(pos[2]); io.print(String(pos[1] === 'nodes' ? Object.keys(a.nodes || {}).length : (a.rows || a || []).length)); return; }
  if (cmd === 'plan') {
    const [, graphPath, measurePath, outdir] = pos;
    if (!outdir) throw new Error(USAGE);
    for (const k of Object.keys(flags)) if (!['mess', 'promote', 'prefer', 'cap', 'margin', 'popular', 'view', 'ranks', 'kinds', 'current'].includes(k)) throw new Error(`unknown option --${k}\n${USAGE}`);
    const graph = json(graphPath), measure = json(measurePath);
    const opts = { promote: onOff(flags.promote, DEFAULTS.promote), cap: num(flags.cap), marginPills: num(flags.margin), popular: num(flags.popular), prefer: num(flags.prefer), mess: num(flags.mess), view: viewOf(flags.view), ranks: ranksOf(flags.ranks), progress: io.warn };
    opts.kinds = flags.kinds ? json(flags.kinds) : null;
    opts.refused = refusedEdges(measure);
    if (flags.current) opts.current = json(flags.current);
    const elk = await loadElk(io, TOOL_DIR);
    const t0 = io.now();
    // sizes need the model's nodes: the plan builds it, so the sizes are read from the measurement once it has
    const r = await planGraph(graph, (model) => sizesFrom(model, measure), opts, elk, io.now);
    const totalMs = io.now() - t0;
    io.mkdirp(outdir);
    io.writeText(outdir + '/drawing.json', JSON.stringify(r.drawing, null, 1));
    r.report.timings.totalMs = totalMs; r.report.timings.engine = io.engine;
    io.writeText(outdir + '/report.json', JSON.stringify(r.report, null, 1));
    io.print(summarize(r));
    return;
  }
  if (cmd === 'refusals') {
    const raw = json(pos[1]), e = raw.error || raw;
    const all = Array.isArray(e.refusals) && e.refusals.length ? e.refusals : [e];
    const drawing = pos[2] ? json(pos[2]) : null;
    io.print(all.map((x) => `${x.key != null ? x.key : x.edge != null ? edgeName(x.edge, drawing) : 'canvas apply'}: ${x.message}${x.hint ? ` (${x.hint})` : ''}`).join('\n'));
    return;
  }
  if (cmd === 'applied') { io.print(appliedText(json(pos[1]), pos[2] ? json(pos[2]) : null)); return; }
  if (cmd === 'extract') {
    const answer = json(pos[2]);
    if (pos[1] === 'kinds') io.print(JSON.stringify(kindsRead(answer)));
    else if (pos[1] === 'errors') io.print(String(answer.errors.length));
    else throw new Error(`extract: kinds or errors, not ${pos[1]}`);
    return;
  }
  throw new Error(USAGE);
}

/** check's answer in words: an `error: ` or `warning: ` line each, or `ok`. */
export function checkText(res) {
  const lines = res.errors.map((e) => 'error: ' + e).concat(res.warnings.map((w) => 'warning: ' + w));
  return (lines.length ? lines : ['ok']).join('\n');
}

/**
 * An edge the app names by its place in the apply document's list, which is drawing.json's (makers of pills first, then their sharers), not the graph
 * document's: with drawing.json at hand it is named by its ends; without it, by the number.
 */
export function edgeName(index, drawing) {
  const e = drawing && drawing.edges && drawing.edges[index];
  return e ? `edge from ${JSON.stringify(e.from)} to ${JSON.stringify(e.to)}` : `edge ${index}`;
}

/** What `canvas apply` answered, in a few lines: counts by what was done, what was deleted, and each warning with the key it names. */
export function appliedText(res, drawing) {
  const count = (list) => { const c = {}; for (const x of list || []) c[x.did] = (c[x.did] || 0) + 1; return Object.keys(c).sort().map((k) => `${c[k]} ${k}`).join(', ') || 'none'; };
  const lines = [`${res.dryRun ? 'dry run' : 'applied'} ${res.drawing}: shapes ${count(res.nodes)}; edges ${count(res.edges)}; ${(res.deleted || []).length} deleted`];
  const over = (res.nodes || []).filter((n) => n.overrode && n.overrode.length);
  if (over.length) lines.push(`overrode a person's change on ${over.length} shape(s): ${over.slice(0, 5).map((n) => `${n.key} (${n.overrode.join(', ')})`).join('; ')}${over.length > 5 ? '; ...' : ''}`);
  for (const w of res.warnings || []) lines.push(`warning: ${w.key != null ? w.key + ': ' : w.edge != null ? edgeName(w.edge, drawing) + ': ' : ''}${w.message}`);
  return lines.join('\n');
}

/** The few lines an agent can relay: what is drawn, what goes public and why, where the loop stopped. */
export function summarize(r) {
  const rep = r.report, t = rep.totals;
  const shapes = r.plan.boards.reduce((s, b) => s + b.shapes.length, 0);
  const v = rep.view;
  const lines = [`plan: ${r.plan.boards.length} board(s), ${shapes} shapes, ${t.pills} pills (${t.sharedArrows} arrows into shared ones), ${t.arrows} plain arrows; mess ${r.model.dial.mess}`
    + (v ? `; laid out for a view of ${Math.round(v.w)} x ${Math.round(v.h)}` + (v.from === 'assumed' ? ' (assumed: no view was given)' : '') : '')];
  lines.push(`public (${rep.public.length}), all made by this run: ` + (rep.public.length ? rep.public.map((p) => `${p} (${rep.publicWhy[p]})`).join('; ') : 'none'));
  // the moves the plan keeps: one the loop took back again is in its board's demotions
  const back = new Set(Object.values(rep.boards).flatMap((x) => (x.demotions || []).map((d) => [d.board, d.mode, d.node].join('\u0000'))));
  const kept = rep.promotions.filter((p) => !back.has([p.board, p.mode || 'in', p.node].join('\u0000')));
  const ins = kept.filter((p) => p.mode !== 'out'), outs = kept.filter((p) => p.mode === 'out');
  lines.push('stop: ' + Object.entries(rep.boards).map(([b, x]) => `${b} ${x.stop}`).join(', ') + (ins.length ? `; promoted ${ins.length}: ${ins.map((p) => p.node).join(', ')}` : '') + (outs.length ? `; fanned out ${outs.length}: ${outs.map((p) => p.node).join(', ')}` : ''));
  const long = Object.values(rep.boards).reduce((s, x) => s + (x.long || []).length, 0), left = Object.values(rep.boards).reduce((s, x) => s + (x.longLeft || 0), 0);
  if (long || left) lines.push(`long arrows: ${long} made pills of their own (over ${r.model.dial.longest} units, as the view sees them)` + (left ? `; ${left} still longer after the last pass` : ''));
  for (const w of rep.warnings) lines.push('warning: ' + w);
  return lines.join('\n');
}
