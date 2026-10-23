// What the real runs did against the plan, read from their saved results (the driver's `verify`): every run replayed through `compare`
// in order, every planned shape and pill counted, every planned arrow found, and the titles the file now holds checked when it is told them.
import { compareRun } from './compare.mjs';

const ARROW_DID = new Set(['connected', 'reconnected', 'unchanged']);
const arrowKey = (from, to, is) => [from, to, [...(is || [])].sort().join('\u0001')].join('\u0000');   // a list of types is a set

/** results: {runName: the real run's JSON}. titles: the file's titles after the runs (an array), or null. Returns {ok, lines, ...counts}. */
export function replay(plan, results, titles) {
  const problems = [], others = [];
  const out = { runs: 0, shapes: 0, shapesWithin1: 0, pills: 0, pillsWithin1: 0, worstShape: 0, worstPill: 0, arrows: 0, arrowsPlanned: 0, described: 0, warnings: 0, outOfView: 0, restated: 0, typed: 0 };
  const planned = new Set();
  const typedPlanned = new Map();   // the arrows of a relationship type the plan draws (an arrow of a pair is told from the others by its `is`)
  const typedLanded = new Set();
  const described = plan.described || {};   // run -> the subboards it writes a description of
  out.describedPlanned = 0;
  for (const names of Object.values(described)) out.describedPlanned += names.length;
  for (const b of plan.boards) {
    out.shapes += b.shapes.length; out.pills += b.pills.length; out.arrowsPlanned += b.edges.length;
    for (const s of b.shapes) planned.add(s.title);
    for (const e of b.edges) if (e.is && e.is.length) typedPlanned.set(arrowKey(e.from, e.to, e.is), `${e.from} -> ${e.to} is ${e.is.join(', ')}`);
  }
  for (const name of plan.runs) {
    const result = results[name];
    if (!result) { problems.push(`${name}: no result was saved (the run did not happen)`); continue; }
    out.runs++;
    const cmp = compareRun(plan, result, name);
    out.shapesWithin1 += cmp.shapesWithin1; out.pillsWithin1 += cmp.pillsWithin1; out.described += cmp.described;
    out.worstShape = Math.max(out.worstShape, cmp.worstShape); out.worstPill = Math.max(out.worstPill, cmp.worstPill);
    out.warnings += cmp.warnings.push + cmp.warnings.order + cmp.warnings.other; out.outOfView += cmp.warnings.view; out.typed += cmp.warnings.typed;
    for (const m of cmp.mismatches) problems.push(`${name}: ${m}`);
    for (const m of cmp.warningMessages) problems.push(`${name}: ${m}`);
    for (const m of cmp.otherMessages) others.push(`${name}: ${m}`);
    for (const c of result.changes || []) {
      if (c.kind === 'arrow' && ARROW_DID.has(c.did)) { out.arrows++; if (c.is && c.is.length) typedLanded.add(arrowKey(c.from, c.to, c.is)); }
      if (planned.has(c.title) && c.did !== 'created' && !(described[name] || []).includes(c.title)) out.restated++;   // compare names each one (a digest never restates a shape, but to describe a subboard)
    }
  }
  if (out.shapesWithin1 !== out.shapes && !problems.length) problems.push(`${out.shapes - out.shapesWithin1} of ${out.shapes} shapes are not within 1 unit of the plan`);
  if (out.arrows !== out.arrowsPlanned) problems.push(`${out.arrows} arrows landed, ${out.arrowsPlanned} were planned`);
  if (out.described !== out.describedPlanned) problems.push(`${out.described} descriptions landed, ${out.describedPlanned} were planned`);
  const typedMissing = [...typedPlanned].filter(([k]) => !typedLanded.has(k)).map(([, name]) => name);
  if (typedMissing.length) problems.push(`not drawn as the relationship the plan says: ${typedMissing.slice(0, 10).join('; ')}${typedMissing.length > 10 ? ` and ${typedMissing.length - 10} more` : ''}`);
  if (titles) {
    const have = new Set(titles);
    const missing = [...planned].filter((t) => !have.has(t));
    if (missing.length) problems.push(`not in the file: ${missing.slice(0, 10).join(', ')}${missing.length > 10 ? ` and ${missing.length - 10} more` : ''}`);
  }
  const ok = problems.length === 0;
  const lines = [ok ? 'verify ok' : 'verify FAILED'];
  lines.push(`runs ${out.runs}/${plan.runs.length}; shapes ${out.shapesWithin1}/${out.shapes} within 1 unit of the plan (worst ${r1(out.worstShape)}); pills ${out.pillsWithin1}/${out.pills} within 1 unit (worst ${r1(out.worstPill)}); arrows ${out.arrows}/${out.arrowsPlanned}` + (out.describedPlanned ? `; descriptions ${out.described}/${out.describedPlanned}` : '') + `; warnings ${out.warnings}` + (out.outOfView ? `; ${out.outOfView} warning(s) that shapes landed outside the window's view (the camera is the user's)` : '') + (out.typed ? `; ${out.typed} warning(s) a typed drawing gives by design (a Needed row empty when its note is drawn, a relationship that doesn't fit its ends...; not failures: canvas query ":incomplete, :invalid" says what is still wrong)` : ''));
  for (const p of problems.slice(0, 20)) lines.push('  ' + p);
  if (problems.length > 20) lines.push(`  and ${problems.length - 20} more`);
  // the drawing's other warnings fail nothing, and are said, never only counted (a title near one the board has, say)
  for (const w of others.slice(0, 5)) lines.push('  warning: ' + w);
  if (others.length > 5) lines.push(`  and ${others.length - 5} more warnings (each run's are in its results/<run>.json)`);
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
