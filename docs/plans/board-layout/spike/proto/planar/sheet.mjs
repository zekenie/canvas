// Every module board of a built drawing as pictures (the whole board as a window first shows it, and readable), and per-board measures a
// reviewer reads beside them: node sheet.mjs <scratch> <run dir> <out dir> [label]
//   <out dir>/<Board>-fit.png, <Board>.png, measures.json
import fs from 'fs';
import { load, layoutFromDrawing, arrowPoints } from '../harness.mjs';
import { renderBoth } from '../backbone-quiet/render.mjs';
import { evaluate } from './kit.mjs';
const [S, run, out, label = 'stars'] = process.argv.slice(2);
const m = load(S + '/data');
const drawing = JSON.parse(fs.readFileSync(run + '/drawing.json', 'utf8'));
const today = JSON.parse(fs.readFileSync(S + '/run/today/drawing.json', 'utf8'));
fs.mkdirSync(out, { recursive: true });
const measures = {};
for (const b of m.boards.keys()) {
  if (b === 'root') continue;
  const lay = layoutFromDrawing(m, drawing, b), t = layoutFromDrawing(m, today, b);
  const e = evaluate(m, b, lay), et = evaluate(m, b, t);
  const boxOf = (id) => lay.boxes[id] || lay.pills.find((p) => p.id === id);
  // the longest arrows between notes, and the tallest column of one note's pills
  const lens = [];
  for (const a of lay.arrows) { if (lay.pills.some((p) => p.id === a.to)) continue; const A = boxOf(a.from), B = boxOf(a.to); if (!A || !B) continue; const pts = arrowPoints(A, B, a, 16); let L = 0; for (let i = 1; i < pts.length; i++) L += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); lens.push({ L: Math.round(L), from: m.node(a.from).title, to: m.node(a.to).title }); }
  lens.sort((x, y) => y.L - x.L);
  const perUser = new Map();
  for (const a of lay.arrows) { const p = lay.pills.find((q) => q.id === a.to); if (p) perUser.set(a.from, (perUser.get(a.from) || 0) + 1); }
  const most = [...perUser.entries()].sort((x, y) => y[1] - x[1])[0];
  const name = b.replace('module:', '').replace(/[^A-Za-z]/g, '');
  measures[b] = { file: name, notes: e.shapes, arrows: e.arrows, pills: e.pills, clean: e.clean, size: e.size, aspect: e.aspect,
    areaVsToday: Math.round(100 * e.size[0] * e.size[1] / (et.size[0] * et.size[1])) / 100, meanLength: e.meanLength,
    longestArrows: lens.slice(0, 3), mostPills: most ? { note: m.node(most[0]).title, pills: most[1] } : null, overOwnPills: e.overOwnPills };
  renderBoth(m, b, lay, `${out}/${name}`, { title: `${m.node(b).title || name} (${label}): ${e.arrows} arrows, ${e.pills} pills, ${e.size.join('x')}, aspect ${e.aspect}`, scale: 0.3 });
}
fs.writeFileSync(out + '/measures.json', JSON.stringify(measures, null, 1));
console.log('boards', Object.keys(measures).length);
