// The commands. Everything that touches a file goes through `io`, which main.js builds for jsc or node.
import { buildModel } from './model.mjs';
import { measureScript, sizesFrom } from './sizes.mjs';
import { loadElk } from './elk.mjs';
import { planDigest, DEFAULTS } from './plan.mjs';
import { verify, formatVerify } from './verify.mjs';
import { compareRun } from './compare.mjs';
import { replay, extract } from './replay.mjs';
import { boardField, boardView, drawnRecord, sameFile, pickRecord, needsTitles, readRecords, recordName, beyond, minus, foreign, replaceScript, hasTitle } from './redraw.mjs';
import { checkDigest } from './check.mjs';
import { typeProblems } from './types.mjs';
import { TOOL_DIR, fold } from './util.mjs';

export const USAGE = `digest tool (the driver, ./digest, runs these; the tool never runs canvas)
  check <digest.json> [--existing titles.json] [--kinds kinds.json] [--into "Title"]
                                                                       {"errors": [...], "warnings": [...]}; titles.json and kinds.json are arrays of strings
  check-text <check.json>                                              what check found, as "error: ..." and "warning: ..." lines ("ok" for none)
  measure-script <digest.json>                                         the draw script for \`canvas measure -\`
  plan <digest.json> <measure.json> <outdir> [--mess 0..1] [--promote off] [--prefer N] [--cap 0..1] [--margin PILLS] [--popular ARROWS] [--into "Title"]
                                             [--view WxH] [--ranks rows|columns|auto]
                                                                       writes <outdir>/plan.json, report.json and runs/NN-<board>-<step>.draw; --into puts the
                                                                       whole digest in a new subboard of that title (runs/00-into.draw makes it)
  compare <plan.json> <result.json> [--name run] [--text true]       one run's result (dry or real) against the plan: every shape's box and every pill's spot
                                                                       from its board's origin, and that every shape is created; --text prints "ok ..." or "MISMATCH ..."
  clashes <plan.json> <titles.json>                                    the plan's titles that the file already holds, as "error: ..." lines (none: nothing printed)
  runs <plan.json>                                                     the run files in the order they are drawn, one a line
  into <plan.json>                                                     the title of the subboard the plan draws into (nothing for a new file)
  replay <plan.json> <resultsdir> [--titles titles.json]               the real runs' saved results (<resultsdir>/<run>.json), all of them, against the plan
  extract titles|root-titles|kinds|id|count|errors <answer.json>       what the driver reads out of canvas's JSON (or check's), printed as JSON
  board <boards.json> <front|id|file|name> id|path|fileShapes|shows [path]   one open board's field, from \`canvas boards\` ([path]: the file named, its links resolved)
  view <boards.json> <front|id>                                        the room that board's window has for a board fit to it, as --view takes it (1312x772); nothing
                                                                       when no such board is open or its window has no size
  drawn <plan.json> <path> <id> [shapes] [--over drawn.json --was N]   what drawing the plan makes, to keep as drawn.json (the board's file and id, the subboard, the titles,
                                                                       how many shapes the file held once drawn); --over: with the drawing it replaces, while it is drawn,
                                                                       and --was, how many shapes the file held before that one was taken back
  same-file <drawn.json> <path> <id> [titles.json]                     "yes" when the last drawing is in that board's file (by its path, else by its id and its shapes), else "no"
  record-pick <path> <id> <titles.json> [record.json ...]              which record of a folder of them (--records) is the last drawing in that board's file (as same-file tells);
                                                                       prints the record's argument as given, nothing when none is
  record-name <path> <id> <plan.json>                                  the file name for a new record: from the path, else from the id and the drawing's name
  name <plan.json|digest.json> [--into "Title"]                        what a drawing is told by in a board with no file: the subboard it goes into, else the digest's title
  has-title <titles.json> <title>                                      "yes" when the file holds that title, else "no"
  beyond <drawn.json> <fileShapes>                                     how many shapes the file holds beyond the last drawing (drawn as the board)
  minus <titles.json> <drawn.json>                                     the file's titles less the last drawing's, as JSON
  foreign <titles.json> <drawn.json>                                   the file's titles the last drawing didn't make, one a line
  replace-script <drawn.json> <titles.json> [root-titles.json]         the draw script that takes the last drawing back (nothing when it is gone); with the titles
                                                                       on the file's root board, a shape drawn on the root is deleted only where it is on it
(under jsc, make <outdir>/runs first: jsc cannot make a folder)

THE MESS DIAL: --mess 0..1 (or "policy": {"mess": 0.5} in the digest; the flag wins; default 0.1). 0 is tidy, 1 is loose. One number sets all of:
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
--promote off: no hub is promoted, only the pills that cross boards or ask via: reference. --prefer N (default 2): each extra pill of a hub in one frame must save N pills' prices.
A move promotes a node many point at (it is made public, and each user reaches it through a pill beside the user) or fans out a node that points at many (each of
its uses is a pill beside it, and what they stand for is made public). After the popular ones, the loop stops when the board is good enough, when the best candidates
cut the cost by no more than the margin, or at the cap (the report says which).

THE VIEW: --view WxH is the room the window has for a board fit to it (\`canvas boards\` says each window's, as view; the driver hands on the target's). Every board
is laid out toward that shape, so that it fills the view when it is fit to it: its containers' arrows run down or across, a stress layout is stretched, and ranked
children run as rows or as columns, whichever the view shows larger (--ranks rows or columns says which outright, over the digest's policy.ranks). A board the view
shows whole at its own size is left whatever shape it is. An arrow is too long as the view sees it: further across a wide view than down it. With no --view, a view
of 1440 x 960 is assumed, and the summary says so.`;

/** The model of a digest, refused when its types are wrong (what `check` says of them): a script made of a bad `is` would only fail later, in the app. */
function typedModel(digest) {
  const model = buildModel(digest);
  const typed = typeProblems(model);
  if (typed.errors.length) throw new Error(typed.errors.slice(0, 10).join('\n') + (typed.errors.length > 10 ? `\nand ${typed.errors.length - 10} more` : '') + '\n(digest check says all of them)');
  return model;
}

function parseFlags(args) {
  const pos = [], flags = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) { const k = args[i].slice(2); if (k === 'json') flags[k] = true; else flags[k] = args[++i]; } else pos.push(args[i]);
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
    const res = checkDigest(json(pos[1]), { existing: flags.existing ? json(flags.existing) : [], kinds: flags.kinds ? json(flags.kinds) : null, into: flags.into || null });
    io.print(JSON.stringify(res));
    return;
  }
  if (cmd === 'check-text') { io.print(checkText(json(pos[1]))); return; }
  if (cmd === 'clashes') { const lines = clashes(json(pos[1]), json(pos[2])); if (lines.length) io.print(lines.join('\n')); return; }
  if (cmd === 'into') { const p = json(pos[1]); if (p.into) io.print(p.into); return; }
  if (cmd === 'runs') { io.print(json(pos[1]).runs.join('\n')); return; }
  if (cmd === 'measure-script') { io.print(measureScript(typedModel(json(pos[1]))).replace(/\n$/, '')); return; }
  if (cmd === 'plan') {
    const [, digestPath, measurePath, outdir] = pos;
    if (!outdir) throw new Error(USAGE);
    for (const k of Object.keys(flags)) if (!['mess', 'promote', 'prefer', 'cap', 'margin', 'popular', 'into', 'view', 'ranks'].includes(k)) throw new Error(`unknown option --${k}\n${USAGE}`);
    const digest = json(digestPath);
    const opts = { promote: onOff(flags.promote, DEFAULTS.promote), cap: num(flags.cap), marginPills: num(flags.margin), popular: num(flags.popular), prefer: num(flags.prefer), mess: num(flags.mess), into: flags.into || null, view: viewOf(flags.view), ranks: ranksOf(flags.ranks), progress: io.warn };
    const model = typedModel(digest);
    const sizes = sizesFrom(model, json(measurePath));
    const elk = await loadElk(io, TOOL_DIR);
    const t0 = io.now();
    const r = await planDigest(digest, sizes, opts, elk, io.now);
    const totalMs = io.now() - t0;
    io.mkdirp(outdir + '/runs');
    for (const run of r.runs) io.writeText(`${outdir}/runs/${run.name}`, run.text);
    io.writeText(outdir + '/plan.json', JSON.stringify(r.plan, null, 1));
    r.report.timings.totalMs = totalMs; r.report.timings.engine = io.engine;
    io.writeText(outdir + '/report.json', JSON.stringify(r.report, null, 1));
    io.print(summarize(r));
    return;
  }
  if (cmd === 'compare') {
    const res = compareRun(json(pos[1]), json(pos[2]), flags.name || pos[2]);
    if (flags.text === 'true') io.print(compareText(res)); else io.print(JSON.stringify(res));
    return;
  }
  if (cmd === 'replay') {
    const plan = json(pos[1]);
    const results = {};
    for (const name of plan.runs) { try { results[name] = json(`${pos[2]}/${name.replace(/\.draw$/, '')}.json`); } catch (e) { /* a run that did not happen has no result */ } }
    const res = replay(plan, results, flags.titles ? json(flags.titles) : null);
    io.print(res.lines.join('\n'));
    return;
  }
  if (cmd === 'extract') { io.print(JSON.stringify(extract(pos[1], json(pos[2])))); return; }
  if (cmd === 'board') { io.print(String(boardField(json(pos[1]), pos[2], pos[3], pos[4]))); return; }
  if (cmd === 'view') { const v = boardView(json(pos[1]), pos[2]); if (v) io.print(v); return; }
  if (cmd === 'drawn') { io.print(JSON.stringify(drawnRecord(json(pos[1]), pos[2] || null, pos[3], pos[4], flags.over ? json(flags.over) : null, flags.was, io.now()), null, 1)); return; }
  if (cmd === 'record-pick' || cmd === 'record-needs-titles') {
    // record-pick PATH ID TITLES|'' FILES... [--name NAME] [--quiet true];  record-needs-titles PATH ID FILES... [--quiet true]
    const picking = cmd === 'record-pick', files = pos.slice(picking ? 4 : 3);
    const { records, skipped } = readRecords(files, json);
    if (skipped.length && flags.quiet !== 'true') (io.warn || (() => {}))(`digest: ignored ${skipped.length} file(s) in the records folder that aren't drawing records: ${skipped.map((s) => `${s.name.split('/').pop()} (${s.why})`).join(', ')}`);
    if (picking) {
      const name = pickRecord(records, pos[1] || null, pos[2], pos[3] ? json(pos[3]) : null, flags.name);
      if (name) io.print(name);
    } else if (needsTitles(records, pos[2]) && !pickRecord(records, pos[1] || null, pos[2], null)) io.print('yes');
    return;
  }
  if (cmd === 'name') {
    // what a drawing is told by in one unsaved board: the subboard a plan (or `--into`) draws into, else the digest's title
    try {
      const v = json(pos[1]);
      const n = Array.isArray(v.boards) ? v.into || v.title : (flags.into ? fold(flags.into) : buildModel(v).title);
      if (n) io.print(n);
    } catch (e) { /* none: the pick goes by the newest */ }
    return;
  }
  if (cmd === 'record-name') { const plan = json(pos[3]); io.print(recordName(pos[1] || null, pos[2], plan.into || plan.title)); return; }
  if (cmd === 'has-title') { io.print(hasTitle(json(pos[1]), pos[2]) ? 'yes' : 'no'); return; }
  if (cmd === 'same-file') { io.print(sameFile(json(pos[1]), pos[2] || null, pos[3], pos[4] ? json(pos[4]) : null) ? 'yes' : 'no'); return; }
  if (cmd === 'beyond') { io.print(String(beyond(json(pos[1]), pos[2]))); return; }
  if (cmd === 'minus') { io.print(JSON.stringify(minus(json(pos[1]), json(pos[2])))); return; }
  if (cmd === 'foreign') { const f = foreign(json(pos[1]), json(pos[2])); if (f.length) io.print(f.join('\n')); return; }
  if (cmd === 'replace-script') { const t = replaceScript(json(pos[1]), json(pos[2]), pos[3] ? json(pos[3]) : null); if (t) io.print(t); return; }
  if (cmd === 'verify') {
    const rows = io.readText(pos[2]).split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
    const res = verify(json(pos[1]), rows);
    io.print(flags.json ? JSON.stringify(res, null, 1) : formatVerify(res));
    return;
  }
  throw new Error(USAGE);
}

/** check's answer in words: an `error: ` or `warning: ` line each, or `ok`. */
export function checkText(res) {
  const lines = res.errors.map((e) => 'error: ' + e).concat(res.warnings.map((w) => 'warning: ' + w));
  return (lines.length ? lines : ['ok']).join('\n');
}

/** The titles the plan draws (every shape on every board, and the subboard it goes into) that the file's titles already hold, as `error: ` lines. */
export function clashes(plan, titles) {
  const have = new Set(titles.map((t) => fold(t).toLowerCase()));
  const planned = [];
  if (plan.into) planned.push(plan.into);
  for (const b of plan.boards) for (const s of b.shapes) planned.push(s.title);
  return planned.filter((t) => have.has(fold(t).toLowerCase())).map((t) => `error: "${t}" is already on a board in the file; titles are file-wide`);
}

/** compare's answer in words: `ok ...`, or `MISMATCH ...` and what is off, for the driver to print when it stops. */
export function compareText(res) {
  const others = res.otherMessages && res.otherMessages.length ? `; ${res.otherMessages.length} other warning(s): ${res.otherMessages.slice(0, 3).join(' | ')}${res.otherMessages.length > 3 ? ' | ...' : ''}` : '';
  if (res.ok) return `ok ${res.run}: ${res.shapeRows} shapes within ${res.worstShape} units of the plan, ${res.pillRows} pills (worst ${res.worstPill})` + (res.warnings.typed ? `; ${res.warnings.typed} warning(s) a typed drawing gives by design: ${res.typedMessages.slice(0, 3).join(' | ')}${res.typedMessages.length > 3 ? ' | ...' : ''}` : '') + others;
  const lines = [`MISMATCH ${res.run}: the run is not the plan`];
  for (const m of res.mismatches.slice(0, 10)) lines.push('  ' + m);
  if (res.mismatches.length > 10) lines.push(`  and ${res.mismatches.length - 10} more`);
  for (const m of res.warningMessages.slice(0, 10)) lines.push('  ' + m);
  if (res.pushedPast) lines.push(`  ${res.pushedPast} pill(s) pushed past a shape`);
  if (others) lines.push('  and' + others.slice(1));
  return lines.join('\n');
}

/** The few lines an agent can relay: what is drawn, what goes public and why, where the loop stopped. */
export function summarize(r) {
  const rep = r.report, t = rep.totals;
  const shapes = r.plan.boards.reduce((s, b) => s + b.shapes.length, 0);
  const v = rep.view;
  const lines = [`plan: ${r.plan.boards.length} board(s), ${shapes} shapes, ${t.pills} pills (${t.sharedArrows} arrows into shared ones), ${t.arrows} plain arrows; ${r.runs.length} runs; mess ${r.model.dial.mess}`
    + (v ? `; laid out for a view of ${Math.round(v.w)} x ${Math.round(v.h)}` + (v.from === 'assumed' ? ' (assumed: no view was given)' : '') : '')];
  lines.push(`public (${rep.public.length}), all made by this run: ` + (rep.public.length ? rep.public.map((p) => `${p} (${rep.publicWhy[p]})`).join('; ') : 'none'));
  // the moves the plan keeps: one the loop took back again is in its board's demotions
  const back = new Set(Object.values(rep.boards).flatMap((x) => (x.demotions || []).map((d) => [d.board, d.mode, d.node].join('\u0000'))));
  const kept = rep.promotions.filter((p) => !back.has([p.board, p.mode || 'in', p.node].join('\u0000')));
  const ins = kept.filter((p) => p.mode !== 'out'), outs = kept.filter((p) => p.mode === 'out');
  lines.push('stop: ' + Object.entries(rep.boards).map(([b, x]) => `${b === 'root' ? 'root' : b} ${x.stop}`).join(', ') + (ins.length ? `; promoted ${ins.length}: ${ins.map((p) => p.node).join(', ')}` : '') + (outs.length ? `; fanned out ${outs.length}: ${outs.map((p) => p.node).join(', ')}` : ''));
  const long = Object.values(rep.boards).reduce((s, x) => s + (x.long || []).length, 0), left = Object.values(rep.boards).reduce((s, x) => s + (x.longLeft || 0), 0);
  if (long || left) lines.push(`long arrows: ${long} made pills of their own (over ${r.model.dial.longest} units, as the view sees them)` + (left ? `; ${left} still longer after the last pass` : ''));
  const all = r.model.nodes ? [...r.model.nodes.values()] : [];
  const types = all.filter((n) => n.schema && !n.relationship).length, rels = all.filter((n) => n.schema && n.relationship).length;
  const notes = all.filter((n) => n.is.length).length, arrows = (r.model.edges || []).reduce((s, e) => s + e.arrows.filter((a) => a.is.length).length, 0);
  if (types + rels + notes + arrows) lines.push(`types: ${types} type(s), ${rels} relationship type(s), ${notes} note(s) of a type, ${arrows} arrow(s) of a relationship type; a board's types, relationship types and their ends are one script, and the notes of a type are drawn after every such script`);
  for (const w of rep.warnings) lines.push('warning: ' + w);
  return lines.join('\n');
}
