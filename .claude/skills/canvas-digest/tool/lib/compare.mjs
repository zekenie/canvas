// One run's result (a dry run's or a real one's) against the plan: every shape row's box and every pill row's spot, relative to its board's
// header note, must be the planned one (within a unit), and a shape the plan creates must have been `created`, never found `unchanged`.
// state = { origins: { <board>: {x, y} } } carries each board's header note from the run that drew it.
export function classifyWarning(w) {
  const m = String(w.message || w.reason || '');
  if (/landed outside the view/.test(m)) return 'view';   // the window is the user's: a big board is bigger than it
  if (w.code) return /order/i.test(w.code) ? 'order' : /push/i.test(w.code) ? 'push' : 'other';
  if (/was pushed|moved \w+ along with|\bpushed\b/.test(m)) return 'push';
  if (/unordered|no order|can't be ordered|order/i.test(m)) return 'order';
  return 'other';
}

export function compareRun(plan, result, state, runName) {
  const changes = result.changes || [];
  const boardOf = {};
  for (const b of plan.boards) for (const s of b.shapes) boardOf[s.title] = b;
  const origins = Object.assign({}, state.origins || {});
  const newOrigins = {};
  for (const c of changes) {
    const b = boardOf[c.title];
    if (b && c.title === b.origin && c.at) { origins[b.board] = { x: c.at[0][0], y: c.at[0][1] }; newOrigins[b.board] = origins[b.board]; }
  }
  const out = { run: runName, ok: true, shapeRows: 0, shapesWithin1: 0, worstShape: 0, mismatches: [], pillRows: 0, pillsWithin1: 0, worstPill: 0, pillDeltas: [], pushedPast: 0, warnings: { push: 0, order: 0, other: 0, view: 0 }, warningMessages: [] };
  const used = new Set();
  for (const c of changes) {
    if (c.kind !== 'reference' && c.kind !== 'arrow' && boardOf[c.title] && c.did && c.did !== 'created') {
      // a digest never restates a shape: one the plan creates and the board has already is a plan drawn before, or a title taken
      out.ok = false; out.mismatches.push(`"${c.title}" was ${c.did}, not created: it is on the board already, so this plan was drawn before`);
      continue;
    }
    if (!c.at) continue;
    if (c.kind === 'reference') {
      out.pillRows++;
      if (c.pushedPast && c.pushedPast.length) out.pushedPast++;
      let bn = (result.on && result.on.title) || 'root';
      if (plan.into && bn === plan.into) bn = 'root';   // the digest's own board is the subboard it was drawn into
      const b = plan.boards.find((x) => x.board === bn);
      const o = origins[bn];
      if (!b || !o) continue;
      let best = null;
      b.pills.forEach((p, i) => {
        if (used.has(bn + '#' + i)) return;
        const d = Math.abs(c.at[0][0] - o.x - p.x) + Math.abs(c.at[0][1] - o.y - p.y);
        if (!best || d < best.d) best = { i, d, p };
      });
      if (best) {
        used.add(bn + '#' + best.i);
        const dx = c.at[0][0] - o.x - best.p.x, dy = c.at[0][1] - o.y - best.p.y, dw = c.at[1][0] - best.p.w;
        const worst = Math.max(Math.abs(dx), Math.abs(dy));
        out.worstPill = Math.max(out.worstPill, worst);
        if (worst <= 1) out.pillsWithin1++;
        else { out.ok = false; out.mismatches.push(`pill of ${best.p.start} for ${best.p.for}: delta ${dx},${dy}`); }
        out.pillDeltas.push({ start: best.p.start, for: best.p.for, dx, dy, dw });
      }
      continue;
    }
    const b = boardOf[c.title];
    if (!b) continue;
    const o = origins[b.board];
    if (!o) { out.ok = false; out.mismatches.push(`${c.title}: board ${b.board} has no header yet`); continue; }
    const s = b.shapes.find((x) => x.title === c.title);
    const d = { x: c.at[0][0] - o.x - s.x, y: c.at[0][1] - o.y - s.y, w: c.at[1][0] - s.w, h: c.at[1][1] - s.h };
    const worst = Math.max(Math.abs(d.x), Math.abs(d.y), Math.abs(d.w), Math.abs(d.h));
    out.shapeRows++;
    out.worstShape = Math.max(out.worstShape, worst);
    if (worst <= 1) out.shapesWithin1++;
    else { out.ok = false; out.mismatches.push(`${c.title}: delta ${d.x},${d.y} ${d.w}x${d.h}`); }
  }
  for (const w of result.warnings || []) {
    const k = classifyWarning(w);
    out.warnings[k]++;
    if (k !== 'other' && k !== 'view') out.warningMessages.push(w.line == null ? w.message : `line ${w.line}: ${w.message}`);
  }
  if (out.warnings.push || out.warnings.order || out.pushedPast) out.ok = false;
  out.newOrigins = newOrigins;
  return out;
}
