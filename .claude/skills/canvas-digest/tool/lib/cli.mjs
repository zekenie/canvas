// The commands. Everything that touches a file goes through `io`, which main.js builds for jsc or node.
import { kindsRead } from './model.mjs';
import { sizesFrom, refusedEdges, tightnessFrom } from './sizes.mjs';
import { clusterGraph, clusterLine } from './cluster.mjs';
import { loadElk } from './elk.mjs';
import { planGraph, DEFAULTS } from './plan.mjs';
import { checkGraph } from './check.mjs';
import { TOOL_DIR } from './util.mjs';
import { healthLines } from './health.mjs';

export const USAGE = `digest tool (the driver, ./digest, runs these; the tool never runs canvas)
  check <graph.json> --kinds kinds.json                                {"errors": [...], "warnings": [...]}; kinds.json is canvas kinds' answer, which every command that reads a graph takes
  check-text <check.json>                                              what check found, as "error: ..." and "warning: ..." lines ("ok" for none)
  plan <graph.json> <measure.json> <outdir> --kinds kinds.json [--view WxH] [--ranks rows|columns|auto] [--current current.json [--changed changed.json]]
                                                                       writes <outdir>/drawing.json (the document canvas apply takes) and report.json;
                                                                       measure.json is canvas measure's answer for the graph; --current: canvas query ':drawn-by("NAME")' --brief
                                                                       (the drawing as the file holds it is drawn again in place: what is there stays, what is new goes beside it);
                                                                       --changed: canvas query ':changed("NAME")' --brief (what a person moved, resized or put elsewhere is held where they put it)
  cluster <graph.json> <measure.json> <outdir> --kinds kinds.json [--current current.json [--changed changed.json]]
                                                                       writes <outdir>/clustered.json (the document, in its own containers, with the links between two groups of a container's shapes marked layout.cut, and every
                                                                       link weighed by layout.weight; no shape is added or moved) and clusters.json; measure.json is canvas measure --tightness's answer
                                                                       for the graph; --current, --changed: as plan's (a shape a person carried into another container is grouped where it is now, and
                                                                       reported in clusters.json; then <outdir>/carried.json is the document with it there, for canvas measure)
  tightness <measure.json>                                             what canvas measure said of tightness, in a line
  name <graph.json>                                                    the drawing's name
  drawn-by <graph.json>                                                the canvas query that finds the drawing's shapes (:drawn-by("NAME"))
  changed-by <graph.json>                                              the canvas query that finds the shapes of the drawing a person changed (:changed("NAME"))
  view <boards.json> [id]                                              the room a board's window has for a board fit to it (canvas boards' view), WxH
  count nodes|rows <answer.json>                                       how many nodes canvas measure measured, or rows canvas query answered
  refusals <error.json> [drawing.json]                                 the key and the app's words for each refusal of canvas apply (its JSON on standard error), one a line; with drawing.json, an edge by its ends
  applied <apply.json> [drawing.json]                                  what canvas apply answered, in a few lines: shapes by what was done, deleted, and each warning by key (an edge by its ends)
  extract kinds|errors <answer.json>                                   what the driver reads out of canvas's JSON (or check's), printed as JSON

CLUSTERS (cluster, before plan): on every board each container's shapes are grouped by how tightly their links hold them: a link is as tight as its two notes are alike
(canvas measure --tightness, an embedding of their words), ranked within the board, and the groups are Louvain's over those weights (resolution 1.5), a frame of the document's
one item in what holds it, so what holds what is never split. The groups add no frame and move no shape: they only weigh the links, and a link between two groups is marked
layout.cut, a pill before anything is placed (never one marked direct or into a node marked layout.pill: false) that is an arrow again where the finished drawing has a
clear line for it. Where the app gave no tightness the links weigh the same and the groups are by the links alone, which the summary says. plan then lays the document out
as any other. A redraw finds the groups again over the document as it now is, only to weigh its links: every shape, arrow and pill stays as the file has it, so to group a drawn board again, draw it into a new file (a drawing is found by its name anywhere in the file).

THE CUT: on every board, the links the board can't draw with no arrow crossing another become reference pills, the fewest found, and nothing
else does. First the links are made planar (a graph that can be drawn with no crossing): the most wanted added first (the heavier,
layout.weight; then the one at the busier shape, so a hub keeps its arrows and gives up its weakest users; then by key), each that would make
them not planar cut. Then each container is placed: as stars where its links have a cycle (a drawing of them with none crossing, the children
put down one at a time, the most linked first), else in rows (down or across, or a tree), or as layout.placement says (stars or rows, on the
document or a node). The drawing is measured as the app will draw it, and a link in a crossing, or whose arrow runs over a shape, is cut too,
until the board is clean (8 rounds at most), the link in the most conflicts first (the least wanted on a tie), and in a document clustered by tightness (layout.clustered.by) the
least wanted first (the loosest). A link marked layout.cut (between two groups) is a pill before anything is placed, and is an arrow again below like any other where the line is clear. A link marked layout.direct is never cut, nor one into a node marked layout.pill: false. Then
each link the cut made a pill whose line the finished drawing has room for (it crosses no line and runs over no shape or pill) is an arrow
again, its pill gone. Last, the notes of a container that use one target share a pill where the drawing has a spot each of them reaches by a
clear straight line. There is no knob: the summary says how many links were cut on each count, and which boards are still not clean.

DRAWING AGAIN IN PLACE (--current): the file's drawing is read, not decided again. Which links are arrows, which are pills and which pill each shares are what the
file says (its rows for the edges); every note, frame and pill stays where it is, a note that is new goes to the nearest free spot by its links, and only a conflict
the check finds is mended (a link cut into a pill, a note's pills put about it again). What a person moved, resized or put elsewhere (--changed) stays exactly
where they put it, its pills come with it, and a shape of the tool's that it covers is put down again; a board is laid out afresh only where the file holds none of
it. The summary says which boards were as the file has them, which had shapes put down, which were laid out afresh, and what of a person's was held.

THE VIEW: --view WxH is the room the window has for a board fit to it. Every board is laid out toward that shape, so that it fills the view when it is fit to it: its
containers' arrows run down or across, stars are stretched toward it, and ranked children run as rows or as columns, whichever the view shows larger (--ranks rows or
columns says which outright, over the graph's layout.ranks). A board the view shows whole at its own size is left whatever shape it is.
With no --view, a view of 1440 x 960 is assumed, and the summary says so.`;

function parseFlags(args) {
  const pos = [], flags = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) flags[args[i].slice(2)] = args[++i]; else pos.push(args[i]);
  }
  return { pos, flags };
}

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
  if (cmd === 'changed-by') { const g = json(pos[1]); io.print(`:changed(${JSON.stringify(String(g.drawing))})`); return; }
  // the room the window of a board has for a board fit to it, as `canvas boards` says it (`view`), as WxH: the board whose id is given, else the one in front
  if (cmd === 'view') {
    const boards = json(pos[1]), want = pos[2];
    const list = Array.isArray(boards) ? boards : boards.boards || [];
    const b = list.find((x) => want ? String(x.id) === String(want) : x.frontmost) || (want ? null : list[0]);
    if (b && Array.isArray(b.view) && b.view.length === 2) io.print(`${Math.round(b.view[0])}x${Math.round(b.view[1])}`);
    return;
  }
  if (cmd === 'count') { const a = json(pos[2]); io.print(String(pos[1] === 'nodes' ? Object.keys(a.nodes || {}).length : (a.rows || a || []).length)); return; }
  if (cmd === 'cluster') {
    const [, graphPath, measurePath, outdir] = pos;
    if (!outdir) throw new Error(USAGE);
    for (const k of Object.keys(flags)) if (!['kinds', 'current', 'changed'].includes(k)) throw new Error(`unknown option --${k}\n${USAGE}`);
    const copts = { kinds: flags.kinds ? json(flags.kinds) : null };
    if (flags.current) copts.current = json(flags.current);
    if (flags.changed && flags.current) copts.changed = json(flags.changed);
    const r = clusterGraph(json(graphPath), json(measurePath), copts);
    io.mkdirp(outdir);
    io.writeText(outdir + '/clustered.json', JSON.stringify(r.graph));
    io.writeText(outdir + '/clusters.json', JSON.stringify(r.report, null, 1));
    // the carried document (a shape a person moved is in its new container there), which canvas measure is asked of: a pill is sized from its note's container
    if (r.carried) io.writeText(outdir + '/carried.json', JSON.stringify(r.carried));
    io.print(clusterLine(r.report, !!copts.current));
    return;
  }
  if (cmd === 'tightness') { io.print(tightnessLine(json(pos[1]))); return; }
  if (cmd === 'plan') {
    const [, graphPath, measurePath, outdir] = pos;
    if (!outdir) throw new Error(USAGE);
    for (const k of Object.keys(flags)) if (!['view', 'ranks', 'kinds', 'current', 'changed'].includes(k)) throw new Error(`unknown option --${k}\n${USAGE}`);
    const graph = json(graphPath), measure = json(measurePath);
    const opts = { view: viewOf(flags.view), ranks: ranksOf(flags.ranks), progress: io.warn };
    opts.kinds = flags.kinds ? json(flags.kinds) : null;
    opts.refused = refusedEdges(measure);
    if (flags.current) opts.current = json(flags.current);
    if (flags.changed && flags.current) opts.changed = json(flags.changed);
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

/** What `canvas measure --tightness` said, in a line (no member, or one with none to give, says why the clusters are by the links alone). */
export function tightnessLine(measure) {
  const t = tightnessFrom(measure), m = measure && measure.tightness;
  if (!t.by) return `tightness: unavailable (${t.why}): clusters by the links alone`;
  return `tightness: ${t.of.size} linked pairs of notes, by ${t.by} (asked for ${m && Number.isInteger(m.asked) ? m.asked : '?'} of ${m && Number.isInteger(m.texts) ? m.texts : '?'} texts)`;
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

/**
 * What a redraw in place did, in a line: the boards as the file has them (nothing put down), the boards with shapes put down and how many (new
 * notes, and the shapes a new or a person's shape moved out of the way of), the boards laid out afresh, the links the mend turned from arrows to
 * pills, and the shapes of a person's held where they put them (and what of theirs is left in conflict).
 */
export function redrawLine(rep) {
  const bs = Object.values(rep.boards);
  const fresh = bs.filter((b) => b.afresh).length, put = bs.filter((b) => !b.afresh && b.putDown > 0), same = bs.length - fresh - put.length;
  const shapes = put.reduce((n, b) => n + b.putDown, 0), mend = bs.reduce((n, b) => n + (b.afresh ? 0 : b.cutFurther), 0);
  const held = bs.reduce((n, b) => n + (b.held ? b.held.length : 0), 0), conflicts = bs.reduce((n, b) => n + (b.conflicts ? b.conflicts.length : 0), 0);
  return `redraw: ${same} board(s) as the file has them, ${put.length} with ${shapes} shape(s) put down, ${fresh} laid out afresh; ${mend} link(s) the mend turned from arrows into pills; ${held} shape(s) a person put where they are held`
    + (conflicts ? `, ${conflicts} of them in a conflict left as it is` : '') + (rep.carried && rep.carried.length ? `; ${rep.carried.length} of them carried into another container, which they stay in` : '');
}

/** The few lines an agent can relay: what is drawn, how many links the cut made pills, and how many boards are clean. */
export function summarize(r) {
  const rep = r.report, t = rep.totals;
  const shapes = r.plan.boards.reduce((s, b) => s + b.shapes.length, 0);
  const v = rep.view;
  const lines = [`plan: ${r.plan.boards.length} board(s), ${shapes} shapes, ${t.pills} pills (${t.sharedPills} shared, ${t.sharedLines} lines into them), ${t.arrows} plain arrows`
    + (v ? `; laid out for a view of ${Math.round(v.w)} x ${Math.round(v.h)}` + (v.from === 'assumed' ? ' (assumed: no view was given)' : '') : '')];
  if (rep.redraw) lines.push(redrawLine(rep));
  else {
    if (t.precut > 0) lines.push(`cut: ${t.precut + t.cut + t.cutFurther} of ${t.links} links made pills: ${t.precut} between groups before anything was placed, ${t.cut} so each board's links are planar and ${t.cutFurther} more where a drawing still crossed or ran over a shape; ${t.restoredCut} of the ${t.precut} between groups and ${t.restored - t.restoredCut} of the others put back as arrows where the finished drawing had a clear line`);
    else lines.push(`cut: ${t.cut + t.cutFurther} of ${t.links} links made pills, ${t.cut} so each board's links are planar and ${t.cutFurther} more where a drawing still crossed or ran over a shape; ${t.restored} of them put back as arrows where the finished drawing had a clear line`);
    if (rep.clusters && rep.clusters.by === null) lines.push(`clusters: by the links alone, each weighing the same (no tightness: ${rep.clusters.why || 'none was measured'})`);
    lines.push(`shared: a pill is shared by a spine's cards, and by the notes of a container that reach one spot by clear lines; ${t.unshared + t.unsharedFurther} lines into a spine's shared pills given a pill of their own, ${t.unshared} so each board's lines are planar and ${t.unsharedFurther} more where a drawing still crossed or ran over a shape`);
  }
  for (const l of healthLines(rep)) lines.push(l);
  for (const w of rep.warnings) lines.push('warning: ' + w);
  return lines.join('\n');
}
