// What the real runs did against the plan, read from their saved results (the driver's `verify`): every run replayed through `compare`
// in order, every planned shape and pill counted, every planned arrow found, and the titles the file now holds checked when it is told them.
import { compareRun } from './compare.mjs';

const ARROW_DID = new Set(['connected', 'reconnected', 'unchanged']);

/** results: {runName: the real run's JSON}. titles: the file's titles after the runs (an array), or null. Returns {ok, lines, ...counts}. */
export function replay(plan, results, titles) {
  const problems = [];
  const state = {};
  const out = { runs: 0, shapes: 0, shapesWithin1: 0, pills: 0, pillsWithin1: 0, worstShape: 0, worstPill: 0, arrows: 0, arrowsPlanned: 0, warnings: 0, outOfView: 0, restated: 0 };
  const planned = new Set();
  for (const b of plan.boards) {
    out.shapes += b.shapes.length; out.pills += b.pills.length; out.arrowsPlanned += b.edges.length;
    for (const s of b.shapes) planned.add(s.title);
  }
  for (const name of plan.runs) {
    const result = results[name];
    if (!result) { problems.push(`${name}: no result was saved (the run did not happen)`); continue; }
    out.runs++;
    const cmp = compareRun(plan, result, state, name);
    Object.assign(state.origins = state.origins || {}, cmp.newOrigins);
    out.shapesWithin1 += cmp.shapesWithin1; out.pillsWithin1 += cmp.pillsWithin1;
    out.worstShape = Math.max(out.worstShape, cmp.worstShape); out.worstPill = Math.max(out.worstPill, cmp.worstPill);
    out.warnings += cmp.warnings.push + cmp.warnings.order + cmp.warnings.other; out.outOfView += cmp.warnings.view;
    for (const m of cmp.mismatches) problems.push(`${name}: ${m}`);
    for (const m of cmp.warningMessages) problems.push(`${name}: ${m}`);
    for (const c of result.changes || []) {
      if (c.kind === 'arrow' && ARROW_DID.has(c.did)) out.arrows++;
      if (planned.has(c.title) && c.did !== 'created') out.restated++;   // compare names each one (a digest never restates a shape)
    }
  }
  if (out.shapesWithin1 !== out.shapes && !problems.length) problems.push(`${out.shapes - out.shapesWithin1} of ${out.shapes} shapes are not within 1 unit of the plan`);
  if (out.arrows !== out.arrowsPlanned) problems.push(`${out.arrows} arrows landed, ${out.arrowsPlanned} were planned`);
  if (titles) {
    const have = new Set(titles);
    const missing = [...planned].filter((t) => !have.has(t));
    if (missing.length) problems.push(`not in the file: ${missing.slice(0, 10).join(', ')}${missing.length > 10 ? ` and ${missing.length - 10} more` : ''}`);
  }
  const ok = problems.length === 0;
  const lines = [ok ? 'verify ok' : 'verify FAILED'];
  lines.push(`runs ${out.runs}/${plan.runs.length}; shapes ${out.shapesWithin1}/${out.shapes} within 1 unit of the plan (worst ${r1(out.worstShape)}); pills ${out.pillsWithin1}/${out.pills} within 1 unit (worst ${r1(out.worstPill)}); arrows ${out.arrows}/${out.arrowsPlanned}; warnings ${out.warnings}` + (out.outOfView ? `; ${out.outOfView} warning(s) that shapes landed outside the window's view (the camera is the user's)` : ''));
  for (const p of problems.slice(0, 20)) lines.push('  ' + p);
  if (problems.length > 20) lines.push(`  and ${problems.length - 20} more`);
  return Object.assign({ ok, problems, lines }, out);
}

const r1 = (x) => Math.round(x * 10) / 10;

/** The few things the driver reads out of canvas's JSON, so it never parses JSON in sh. */
export function extract(what, json) {
  if (what === 'titles') {
    const rows = json.rows || [];
    // one query lists at most the app's row limit and cannot be paged: a file with more titles than it lists cannot be checked for a clash
    if (json.count != null && json.count > rows.length) throw new Error(`the file holds ${json.count} titled shapes and one query lists only ${rows.length}, so a title the digest shares with one of them could be missed: use a smaller file, or a new file (--new-file)`);
    return rows.map((r) => r.title).filter((t) => typeof t === 'string');
  }
  // the titles on the file's root board (each row of a query says its board)
  if (what === 'root-titles') return (json.rows || []).filter((r) => r.board === 'root').map((r) => r.title).filter((t) => typeof t === 'string');
  if (what === 'errors') return (json.errors || []).length;
  if (what === 'kinds') return (Array.isArray(json) ? json : []).map((k) => k.kind).filter((k) => typeof k === 'string');
  if (what === 'id') { if (json.id == null) throw new Error('no id in the answer'); return json.id; }
  if (what === 'count') return json.count == null ? (json.rows || []).length : json.count;
  throw new Error(`extract: ${what} is not titles, root-titles, kinds, id, count or errors`);
}
