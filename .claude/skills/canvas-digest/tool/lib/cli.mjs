// The commands. Everything that touches a file goes through `io`, which main.js builds for jsc or node.
import { buildModel } from './model.mjs';
import { measureScript, sizesFrom } from './sizes.mjs';
import { loadElk } from './elk.mjs';
import { planDigest, DEFAULTS } from './plan.mjs';
import { verify, formatVerify } from './verify.mjs';
import { compareRun } from './compare.mjs';
import { replay, extract } from './replay.mjs';
import { checkDigest } from './check.mjs';
import { TOOL_DIR, fold } from './util.mjs';

export const USAGE = `digest tool (the driver, ./digest, runs these; the tool never runs canvas)
  check <digest.json> [--existing titles.json] [--kinds kinds.json] [--into "Title"]
                                                                       {"errors": [...], "warnings": [...]}; titles.json and kinds.json are arrays of strings
  check-text <check.json>                                              what check found, as "error: ..." and "warning: ..." lines ("ok" for none)
  measure-script <digest.json>                                         the draw script for \`canvas measure -\`
  plan <digest.json> <measure.json> <outdir> [--mess 0..1] [--promote off] [--prefer N] [--cap 0..1] [--margin PILLS] [--into "Title"]
                                                                       writes <outdir>/plan.json, report.json and runs/NN-<board>-<step>.draw; --into puts the
                                                                       whole digest in a new subboard of that title (runs/00-into.draw makes it)
  compare <plan.json> <result.json> <state.json> [--name run] [--save true] [--text true]
                                                                       one run's result (dry or real) against the plan: every shape's box and every pill's spot
                                                                       relative to its board's header, and that every shape is created; --text prints "ok ..." or "MISMATCH ..."
  clashes <plan.json> <titles.json>                                    the plan's titles that the file already holds, as "error: ..." lines (none: nothing printed)
  runs <plan.json>                                                     the run files in the order they are drawn, one a line
  into <plan.json>                                                     the title of the subboard the plan draws into (nothing for a new file)
  replay <plan.json> <resultsdir> [--titles titles.json]               the real runs' saved results (<resultsdir>/<run>.json), all of them, against the plan
  extract titles|kinds|id|count|errors <answer.json>                   what the driver reads out of canvas's JSON (or check's), printed as JSON
(under jsc, make <outdir>/runs first: jsc cannot make a folder)

THE MESS DIAL: --mess 0..1 (or "policy": {"mess": 0.5} in the digest; the flag wins; default 0.1). 0 is tidy, 1 is loose. One number sets all of:
  mess        0.0   0.2   0.5   0.8   1.0
  mu (pill)   2.0   2.8   4.0   5.2   6.0    = 2 + 4 mess            the price of a pill in the cost C
  cap         50%   40%   25%   10%   0%     = 0.5 (1 - mess)        most leaves promoted (at least 1 unless mess = 1)
  margin      the gain a promotion must beat: the layout's measured noise (3 sd) times (0.5 + mess), never under round(1 + 2 mess) pills
  X/arrow     0     .04   .10   .16   .20    = 0.2 mess              good enough: crossings per arrow at most
  Fx/arrow    0     .02   .05   .08   .10    = 0.1 mess              good enough: frame-border crossings per arrow at most
  NE/arrow    0     0     0     .12   .20    = 0.4 max(0, mess-.5)   good enough: arrows over shapes per arrow at most
  aspect      2     2.4   3     3.6   4      = 2 + 2 mess            good enough: aspect at most
The order of promotions is the same at every mess; the dial says how far down it the loop goes. --cap and --margin override the dial's cap and margin.
--promote off: no hub is promoted, only the pills that cross boards or ask via: reference. --prefer N (default 2): each extra pill of a hub in one frame must save N pills' prices.
The loop stops when the board is good enough, when the best candidates cut the cost by no more than the margin, or at the cap (the report says which).`;

function parseFlags(args) {
  const pos = [], flags = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) { const k = args[i].slice(2); if (k === 'json') flags[k] = true; else flags[k] = args[++i]; } else pos.push(args[i]);
  }
  return { pos, flags };
}

const onOff = (v, d) => (v == null ? d : v === 'on' || v === 'true' || v === 'yes');
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
  if (cmd === 'measure-script') { io.print(measureScript(buildModel(json(pos[1]))).replace(/\n$/, '')); return; }
  if (cmd === 'plan') {
    const [, digestPath, measurePath, outdir] = pos;
    if (!outdir) throw new Error(USAGE);
    for (const k of Object.keys(flags)) if (!['mess', 'promote', 'prefer', 'cap', 'margin', 'into'].includes(k)) throw new Error(`unknown option --${k}\n${USAGE}`);
    const digest = json(digestPath);
    const opts = { promote: onOff(flags.promote, DEFAULTS.promote), cap: num(flags.cap), marginPills: num(flags.margin), prefer: num(flags.prefer), mess: num(flags.mess), into: flags.into || null };
    const model = buildModel(digest);
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
    const state = (() => { try { return json(pos[3]); } catch (e) { return {}; } })();
    const res = compareRun(json(pos[1]), json(pos[2]), state, flags.name || pos[2]);
    if (flags.text === 'true') io.print(compareText(res)); else io.print(JSON.stringify(res));
    if (flags.save === 'true') {
      const origins = Object.assign({}, state.origins || {}, res.newOrigins);
      io.writeText(pos[3], JSON.stringify({ origins }));
    }
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
  if (res.ok) return `ok ${res.run}: ${res.shapeRows} shapes within ${res.worstShape} units of the plan, ${res.pillRows} pills (worst ${res.worstPill})`;
  const lines = [`MISMATCH ${res.run}: the run is not the plan`];
  for (const m of res.mismatches.slice(0, 10)) lines.push('  ' + m);
  if (res.mismatches.length > 10) lines.push(`  and ${res.mismatches.length - 10} more`);
  for (const m of res.warningMessages.slice(0, 10)) lines.push('  ' + m);
  if (res.pushedPast) lines.push(`  ${res.pushedPast} pill(s) pushed past a shape`);
  return lines.join('\n');
}

/** The few lines an agent can relay: what is drawn, what goes public and why, where the loop stopped. */
export function summarize(r) {
  const rep = r.report, t = rep.totals;
  const shapes = r.plan.boards.reduce((s, b) => s + b.shapes.length, 0);
  const lines = [`plan: ${r.plan.boards.length} board(s), ${shapes} shapes, ${t.pills} pills (${t.sharedArrows} arrows into shared ones), ${t.arrows} plain arrows; ${r.runs.length} runs; mess ${r.model.dial.mess}`];
  lines.push(`public (${rep.public.length}), all made by this run: ` + (rep.public.length ? rep.public.map((p) => `${p} (${rep.publicWhy[p]})`).join('; ') : 'none'));
  lines.push('stop: ' + Object.entries(rep.boards).map(([b, x]) => `${b === 'root' ? 'root' : b} ${x.stop}`).join(', ') + (rep.promotions.length ? `; promoted ${rep.promotions.length}: ${rep.promotions.map((p) => p.node).join(', ')}` : ''));
  for (const w of rep.warnings) lines.push('warning: ' + w);
  return lines.join('\n');
}
