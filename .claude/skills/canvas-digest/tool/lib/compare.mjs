import { shapeKey } from './places.mjs';
import { label } from './util.mjs';
// One run's result (a dry run's or a real one's) against the plan: every shape row's box and every pill row's spot must be the planned one
// (within a unit), and a shape the plan creates must have been `created`, never found `unchanged`. A plan's (0, 0) is its board's origin,
// which every shape on the board itself is placed from, so a row's `at` is held to the plan as it is.
export function classifyWarning(w) {
  const m = String(w.message || w.reason || '');
  if (/landed outside the view/.test(m)) return 'view';   // the window is the user's: a big board is bigger than it
  // what a typed drawing says by design: a Needed row still empty (severity incomplete), a relationship that doesn't fit its ends, a row that holds
  // more than it allows, a value that breaks its field. They are what the data is, not that the run is off its plan.
  if (w.severity === 'incomplete' || (w.attribute && w.severity === 'error') || /\bis needed$|should have at most|\bruns (from|to) an? |misfit|fieldValues/.test(m)) return 'typed';
  if (w.code) return /order/i.test(w.code) ? 'order' : /push/i.test(w.code) ? 'push' : 'other';
  if (/was pushed|moved \w+ along with|\bpushed\b/.test(m)) return 'push';
  if (/unordered|no order|can't be ordered|order/i.test(m)) return 'order';
  return 'other';
}

/** What a saved plan says of one run: `statements` is the plan's beside file (`statements.json`): the board each run draws on and what each of its lines says. */
export function runStatements(statements, runName) {
  const key = String(runName).replace(/ \(dry run\)$/, '').replace(/\.draw$/, '') + '.draw';
  return (statements && statements.runs && statements.runs[key]) || { board: null, lines: [] };
}

/**
 * compareRun(plan, result, runName, statements): a result's rows are matched to the run's statements by `line` (a title may be a shape's among several
 * with it), and each shape row held to the box of the node its statement says.
 */
export function compareRun(plan, result, runName, statements) {
  const changes = result.changes || [];
  const planned = new Map();
  for (const b of plan.boards) for (const s of b.shapes) planned.set(shapeKey(s), { board: b, shape: s });
  const run = runStatements(statements, runName);
  const says = (c) => (c.line != null ? run.lines[c.line - 1] : null) || {};
  const nameOf = (key) => `"${label(key)}"`;
  // the subboards this run writes a description of: restated, not created
  const describing = new Set();
  for (const l of run.lines) if (l && l.describe != null) describing.add(l.describe);
  const out = { run: runName, ok: true, shapeRows: 0, shapesWithin1: 0, worstShape: 0, described: 0, mismatches: [], pillRows: 0, pillsWithin1: 0, worstPill: 0, pillDeltas: [], pushedPast: 0, warnings: { push: 0, order: 0, other: 0, view: 0, typed: 0, invalid: 0 }, warningMessages: [], typedMessages: [], otherMessages: [] };
  const used = new Set();
  for (const c of changes) {
    const st = says(c);
    // what the app says of a shape or an arrow it drew (a row's `problems`: a Needed row still empty, a value that breaks its field, an end that doesn't fit): the data, not the run
    for (const p of c.problems || []) {
      const name = c.title != null ? c.title : `${c.from} -> ${c.to}`;
      // a value that breaks its field's schema is wrong at a path in the value (a misfit, a row that holds too many and a rule across fields have none): the digest's
      // check should have refused it, so one here means the check and the app disagree. The dry run stops before drawing it.
      if (p.class === 'wrong' && p.path) {
        out.warnings.invalid++; out.ok = false;
        out.mismatches.push(`${name}: ${p.message} (a value that breaks its type's schema${p.path === '' ? '' : ` at ${p.path}`}: digest check should have refused it)`);
        continue;
      }
      out.warnings.typed++;
      out.typedMessages.push(`${name}: ${p.message}`);
    }
    if (st.describe != null) {
      // a description or the types of a shape are written on a shape that is drawn already: it must be changed by it, and it is where it was
      if (c.did === 'unchanged') { out.ok = false; out.mismatches.push(`${nameOf(st.describe)} was unchanged: its description or types were not written`); }
      else out.described++;
      continue;
    }
    if (c.kind !== 'reference' && c.kind !== 'arrow' && st.shape != null && planned.has(st.shape) && c.did && c.did !== 'created') {
      // a digest never restates a shape: one the plan creates and the board has already is a plan drawn before, or a title taken
      out.ok = false; out.mismatches.push(`${nameOf(st.shape)} was ${c.did}, not created: it is on the board already, so this plan was drawn before`);
      continue;
    }
    if (!c.at) continue;
    if (c.kind === 'reference') {
      out.pillRows++;
      if (c.pushedPast && c.pushedPast.length) out.pushedPast++;
      let bn = run.board;
      if (bn == null) { bn = (result.on && result.on.title) || 'root'; if (plan.into && bn === plan.into) bn = 'root'; }   // a result with no run to read it by: the board's title
      const b = plan.boards.find((x) => x.board === bn);
      if (!b) continue;
      let best = null;
      b.pills.forEach((p, i) => {
        if (used.has(bn + '#' + i)) return;
        const d = Math.abs(c.at[0][0] - p.x) + Math.abs(c.at[0][1] - p.y);
        if (!best || d < best.d) best = { i, d, p };
      });
      if (best) {
        used.add(bn + '#' + best.i);
        const dx = c.at[0][0] - best.p.x, dy = c.at[0][1] - best.p.y, dw = c.at[1][0] - best.p.w;
        const worst = Math.max(Math.abs(dx), Math.abs(dy));
        out.worstPill = Math.max(out.worstPill, worst);
        if (worst <= 1) out.pillsWithin1++;
        else { out.ok = false; out.mismatches.push(`pill of ${label(best.p.start)} for ${label(best.p.for)}: delta ${dx},${dy}`); }
        out.pillDeltas.push({ start: best.p.start, for: best.p.for, dx, dy, dw });
      }
      continue;
    }
    const at = st.shape != null ? planned.get(st.shape) : null;
    if (!at) continue;
    const s = at.shape;
    const d = { x: c.at[0][0] - s.x, y: c.at[0][1] - s.y, w: c.at[1][0] - s.w, h: c.at[1][1] - s.h };
    const worst = Math.max(Math.abs(d.x), Math.abs(d.y), Math.abs(d.w), Math.abs(d.h));
    out.shapeRows++;
    out.worstShape = Math.max(out.worstShape, worst);
    if (worst <= 1) out.shapesWithin1++;
    else { out.ok = false; out.mismatches.push(`${label(st.shape)}: delta ${d.x},${d.y} ${d.w}x${d.h}`); }
  }
  for (const w of result.warnings || []) {
    const k = classifyWarning(w);
    out.warnings[k]++;
    const said = w.line == null ? w.message : `line ${w.line}: ${w.message}`;
    // the typed ones are the data's; the others (a title near another's, say) are said too, never only counted, and fail nothing
    if (k === 'typed') out.typedMessages.push(said);
    else if (k === 'other') out.otherMessages.push(said);
    else if (k !== 'view') out.warningMessages.push(said);
  }
  if (out.warnings.push || out.warnings.order || out.pushedPast) out.ok = false;
  return out;
}
