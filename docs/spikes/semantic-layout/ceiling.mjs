// What similarity alone would draw: on each judged board, as many arrows as a drawing has there, the most alike links. Against the judges.
import fs from 'fs';
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const rows = rd('./judge/rows.json'), g = rd('./data/graph-sem.json');
const w = new Map(); for (const e of g.edges) { const k = [e.from, e.to].sort().join('|'); w.set(k, Math.max(w.get(k) || 0, (e.layout && e.layout.weight) || 0)); }
const cons = (r) => r.ja + r.jb;
const tally = (pick) => { const keep = rows.filter((r) => cons(r) >= 3), chip = rows.filter((r) => cons(r) === 0); const n = rows.filter(pick).length, k = keep.filter(pick).length, c = chip.filter(pick).length; return `${String(n).padStart(3)} arrows: keep ${k}/76 (${(100 * k / 76).toFixed(0)}%), chip ${c}/210 (${(100 * c / 210).toFixed(0)}%); of its arrows keep ${(100 * k / n).toFixed(0)}% / chip ${(100 * c / n).toFixed(0)}%`; };
for (const [name, file] of [['main', './out-main/drawing.json'], ['branch', './out-branch/drawing.json'], ['pre50', './out-pre50/drawing.json'], ['dens', './out-dens/drawing.json'], ['pre50nr', './out-pre50nr/drawing.json']]) {
  const d = rd(file); const arrow = new Set(); for (const e of d.edges) if (!e.place) arrow.add([e.from, e.to].sort().join('|'));
  const per = new Map(); for (const r of rows) if (arrow.has([r.a, r.b].sort().join('|'))) per.set(r.board, (per.get(r.board) || 0) + 1);
  // the same count per board, the most alike
  const chosen = new Set();
  for (const b of new Set(rows.map((r) => r.board))) rows.filter((r) => r.board === b).sort((x, y) => w.get([y.a, y.b].sort().join('|')) - w.get([x.a, x.b].sort().join('|'))).slice(0, per.get(b) || 0).forEach((r) => chosen.add(r));
  console.log(`${name.padEnd(7)} as drawn        ${tally((r) => arrow.has([r.a, r.b].sort().join('|')))}`);
  console.log(`${''.padEnd(7)} similarity alone ${tally((r) => chosen.has(r))}`);
}
