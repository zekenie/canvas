// A plan against what landed on the boards: rows {board, in, title, kind, x, y, w, h, for, from, to, is}, one per shape, pill (kind reference, `for` the title of
// the end it stands for) and arrow (`is`: the titles of the relationship types it is of, when it is of any; two arrows of a pair are told apart by it). A row says
// where it is as a query row does: `board` is the containers of the board it is on (the `--into` card and the subboards, outermost first, as titles) and `in` the
// frames it is in on that board, so two shapes of one title are told apart by their places; an arrow's `from` and `to` are the places of its ends, each an
// array (the containers, then the title), and `pill: true` when its end is a reference, whose `to` is then [label].
import { byTitle, label } from './util.mjs';
import { placesOf, shapeKey } from './places.mjs';

const same = (a, b) => (a || []).length === (b || []).length && (a || []).every((x, i) => x === b[i]);
const say = (p) => p.join(' > ');

export function verify(plan, rows) {
  const out = [];
  const summary = { shapes: 0, shapesWithin1: 0, pills: 0, pillsWithin1: 0, missing: [], wrongFrame: [], worstShape: 0, worstPill: 0, worstPillWidth: 0, pillWidthError: { mean: 0, max: 0 }, extraPills: 0, edgesPlanned: 0, edgesMissing: [] };
  let widthSum = 0;
  const where = placesOf(plan);
  const titleOf = (key) => where.byKey.get(key).title;
  const placeOf = (key) => where.containers(key).concat([titleOf(key)]);
  for (const b of plan.boards) {
    const chain = where.boardChain(b.board);
    const here = rows.filter((r) => same(r.board, chain));
    const name = b.board === 'root' ? 'root' : label(b.board);
    // the plan's (0, 0) is the board's origin, so a row is where it landed as it is
    const boxOf = (r) => ({ x: r.x, y: r.y, w: r.w, h: r.h });
    const shapeRows = here.filter((r) => r.kind !== 'reference' && r.kind !== 'arrow');
    const taken = new Set();
    for (const s of b.shapes) {
      const key = shapeKey(s), frames = where.byKey.get(key).frames;
      summary.shapes++;
      // the row in the frames the plan says; failing that the only one of the title in some other frame of the board (it landed in the wrong one)
      let r = shapeRows.find((x) => !taken.has(x) && x.title === s.title && same(x.in, frames));
      if (!r) {
        const other = shapeRows.filter((x) => !taken.has(x) && x.title === s.title);
        if (other.length === 1) { r = other[0]; summary.wrongFrame.push(`${name}: ${label(key)} planned in ${frames.length ? frames.join(' > ') : '-'}, landed in ${(r.in || []).length ? r.in.join(' > ') : '-'}`); }
      }
      if (!r) { summary.missing.push(`${name}: ${label(key)}`); continue; }
      taken.add(r);
      const l = boxOf(r);
      const d = { x: l.x - s.x, y: l.y - s.y, w: l.w - s.w, h: l.h - s.h };
      const worst = Math.max(Math.abs(d.x), Math.abs(d.y), Math.abs(d.w), Math.abs(d.h));
      summary.worstShape = Math.max(summary.worstShape, worst);
      if (worst <= 1) summary.shapesWithin1++;
      out.push({ what: 'shape', board: name, title: label(key), planned: pick(s), landed: l, delta: d, worst });
    }
    // pills: matched to the landed references for the same shape by nearest spot
    const landed = here.filter((r) => r.kind === 'reference').map((r) => Object.assign({ used: false, for: r.for }, boxOf(r)));
    const pairs = [];
    b.pills.forEach((p, i) => landed.forEach((l, j) => { if (l.for === titleOf(p.for)) pairs.push({ i, j, d: Math.abs(l.x - p.x) + Math.abs(l.y - p.y) }); }));
    pairs.sort((a, c) => a.d - c.d || a.i - c.i || a.j - c.j);
    const match = new Map();
    for (const pr of pairs) if (!match.has(pr.i) && !landed[pr.j].used) { match.set(pr.i, pr.j); landed[pr.j].used = true; }
    b.pills.forEach((p, i) => {
      summary.pills++;
      if (!match.has(i)) { summary.missing.push(`${name}: pill ${label(p.start)} -> ${label(p.for)}`); return; }
      const l = landed[match.get(i)];
      const d = { x: l.x - p.x, y: l.y - p.y, w: l.w - p.w, h: l.h - p.h };
      const worst = Math.max(Math.abs(d.x), Math.abs(d.y));
      summary.worstPill = Math.max(summary.worstPill, worst);
      if (worst <= 1) summary.pillsWithin1++;
      widthSum += Math.abs(d.w); summary.pillWidthError.max = Math.max(summary.pillWidthError.max, Math.abs(d.w));
      out.push({ what: 'pill', board: name, title: `${label(p.start)} -> ${label(p.for)}`, planned: pick(p), landed: { x: l.x, y: l.y, w: l.w, h: l.h }, delta: d, worst });
    });
    summary.extraPills += landed.filter((l) => !l.used).length;
    // arrows
    for (const e of b.edges) {
      summary.edgesPlanned++;
      const is = [...(e.is || [])].sort().join('\u0001');   // a list of types is a set
      const from = placeOf(e.from), to = e.via ? [titleOf(e.to)] : placeOf(e.to);
      const ok = here.some((r) => r.kind === 'arrow' && same(r.from, from) && !!r.pill === !!e.via && same(r.to, to) && [...(r.is || [])].sort().join('\u0001') === is);
      if (!ok) summary.edgesMissing.push(`${name}: ${label(e.from)} -> ${label(e.to)}${e.via ? ' (pill)' : ''}${is ? ` is ${e.is.join(', ')}` : ''}`);
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
