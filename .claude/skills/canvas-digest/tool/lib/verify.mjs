// A plan against what landed on the boards: rows {board, title, kind, x, y, w, h, in, for, from, to}, one per shape, pill (kind reference, `for` the end it stands for) and arrow.
import { byTitle } from './util.mjs';

export function verify(plan, rows) {
  const out = [];
  const summary = { shapes: 0, shapesWithin1: 0, pills: 0, pillsWithin1: 0, missing: [], wrongFrame: [], worstShape: 0, worstPill: 0, worstPillWidth: 0, pillWidthError: { mean: 0, max: 0 }, extraPills: 0, edgesPlanned: 0, edgesMissing: [] };
  let widthSum = 0;
  for (const b of plan.boards) {
    const here = rows.filter((r) => r.board === b.board);
    const origin = here.find((r) => r.title === b.origin);
    if (!origin) { summary.missing.push(`${b.board}: the header "${b.origin}"`); continue; }
    const rel = (r) => ({ x: r.x - origin.x, y: r.y - origin.y, w: r.w, h: r.h });
    for (const s of b.shapes) {
      const r = here.find((x) => x.title === s.title);
      summary.shapes++;
      if (!r) { summary.missing.push(`${b.board}: ${s.title}`); continue; }
      const l = rel(r);
      const d = { x: l.x - s.x, y: l.y - s.y, w: l.w - s.w, h: l.h - s.h };
      const worst = Math.max(Math.abs(d.x), Math.abs(d.y), Math.abs(d.w), Math.abs(d.h));
      summary.worstShape = Math.max(summary.worstShape, worst);
      if (worst <= 1) summary.shapesWithin1++;
      if ((r.in || null) !== (s.in || null)) summary.wrongFrame.push(`${b.board}: ${s.title} planned in ${s.in || '-'}, landed in ${r.in || '-'}`);
      out.push({ what: 'shape', board: b.board, title: s.title, planned: pick(s), landed: l, delta: d, worst });
    }
    // pills: matched to the landed references for the same shape by nearest spot
    const landed = here.filter((r) => r.kind === 'reference').map((r) => Object.assign({ used: false, for: r.for }, rel(r)));
    const pairs = [];
    b.pills.forEach((p, i) => landed.forEach((l, j) => { if (l.for === p.for) pairs.push({ i, j, d: Math.abs(l.x - p.x) + Math.abs(l.y - p.y) }); }));
    pairs.sort((a, c) => a.d - c.d || a.i - c.i || a.j - c.j);
    const match = new Map();
    for (const pr of pairs) if (!match.has(pr.i) && !landed[pr.j].used) { match.set(pr.i, pr.j); landed[pr.j].used = true; }
    b.pills.forEach((p, i) => {
      summary.pills++;
      if (!match.has(i)) { summary.missing.push(`${b.board}: pill ${p.start} -> ${p.for}`); return; }
      const l = landed[match.get(i)];
      const d = { x: l.x - p.x, y: l.y - p.y, w: l.w - p.w, h: l.h - p.h };
      const worst = Math.max(Math.abs(d.x), Math.abs(d.y));
      summary.worstPill = Math.max(summary.worstPill, worst);
      if (worst <= 1) summary.pillsWithin1++;
      widthSum += Math.abs(d.w); summary.pillWidthError.max = Math.max(summary.pillWidthError.max, Math.abs(d.w));
      out.push({ what: 'pill', board: b.board, title: `${p.start} -> ${p.for}`, planned: pick(p), landed: { x: l.x, y: l.y, w: l.w, h: l.h }, delta: d, worst });
    });
    summary.extraPills += landed.filter((l) => !l.used).length;
    // arrows
    for (const e of b.edges) {
      summary.edgesPlanned++;
      const ok = here.some((r) => r.kind === 'arrow' && r.from === e.from && r.to === (e.via ? 'pill:' + e.to : e.to));
      if (!ok) summary.edgesMissing.push(`${b.board}: ${e.from} -> ${e.to}${e.via ? ' (pill)' : ''}`);
    }
  }
  summary.pillWidthError.mean = summary.pills ? Math.round((widthSum / summary.pills) * 10) / 10 : 0;
  summary.worstPillWidth = summary.pillWidthError.max;
  return { rows: out, summary };
}

const pick = (s) => ({ x: s.x, y: s.y, w: s.w, h: s.h });

export function formatVerify(res) {
  const lines = [];
  const f = (b) => `${r1(b.x)},${r1(b.y)} ${r1(b.w)}x${r1(b.h)}`;
  for (const r of res.rows.slice().sort((a, b) => byTitle(a.board, b.board) || byTitle(a.what, b.what) || byTitle(a.title, b.title))) {
    lines.push(`${r.what.padEnd(5)} ${r.board} | ${r.title} | planned ${f(r.planned)} | landed ${f(r.landed)} | delta ${r1(r.delta.x)},${r1(r.delta.y)} ${r1(r.delta.w)}x${r1(r.delta.h)}${r.worst > 1 ? '  <<' : ''}`);
  }
  const s = res.summary;
  lines.push('');
  lines.push(`shapes ${s.shapesWithin1}/${s.shapes} within 1 unit, worst ${r1(s.worstShape)}`);
  lines.push(`pills ${s.pillsWithin1}/${s.pills} within 1 unit (x,y), worst ${r1(s.worstPill)}; pill width estimate error mean ${s.pillWidthError.mean}, max ${s.pillWidthError.max}; extra landed pills ${s.extraPills}`);
  lines.push(`missing ${s.missing.length}${s.missing.length ? ': ' + s.missing.slice(0, 10).join('; ') : ''}`);
  lines.push(`wrong frame ${s.wrongFrame.length}${s.wrongFrame.length ? ': ' + s.wrongFrame.slice(0, 10).join('; ') : ''}`);
  lines.push(`arrows missing ${s.edgesMissing.length} of ${s.edgesPlanned}${s.edgesMissing.length ? ': ' + s.edgesMissing.slice(0, 10).join('; ') : ''}`);
  lines.push('summary: ' + JSON.stringify(s));
  return lines.join('\n');
}

const r1 = (x) => Math.round(x * 10) / 10;
