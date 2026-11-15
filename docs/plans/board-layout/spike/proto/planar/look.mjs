// Pictures of boards, a direction's beside today's, at one scale: node look.mjs <scratch> <direction module.mjs> <out dir> <label> board ...
//   <out dir>/<Board>-today(.png|-fit.png), <Board>-<label>(...), and <Board>-<label>-vs-today.png (side by side, readable) and -fit (whole board as a window first shows it)
import fs from 'fs';
import path from 'path';
import { execFileSync } from 'child_process';
import { load, layoutFromDrawing } from '../harness.mjs';
import { renderBoth } from '../backbone-quiet/render.mjs';
import { evaluate } from './kit.mjs';

const [S, modPath, outDir, label, ...boards] = process.argv.slice(2);
const mod = await import(path.resolve(modPath));
const m = load(S + '/data');
const today = JSON.parse(fs.readFileSync(S + '/run/today/drawing.json', 'utf8'));
fs.mkdirSync(outDir, { recursive: true });
const compose = S + '/compose';
for (const b of boards) {
  const name = b.replace('module:', '').replace(/[^A-Za-z]/g, '');
  const t = layoutFromDrawing(m, today, b), mt = evaluate(m, b, t);
  const r = await mod.layoutBoard(m, b), md = evaluate(m, b, r.layout);
  const say = (x) => `${x.arrows} arrows, ${x.pills} pills, ${x.crossings} crossings, ${x.overNotes} over notes, ${x.overPills} over pills`;
  renderBoth(m, b, t, `${outDir}/${name}-today`, { title: `${name}, today: ${say(mt)}`, scale: 0.3 });
  renderBoth(m, b, r.layout, `${outDir}/${name}-${label}`, { title: `${name}, ${label}: ${say(md)}`, scale: 0.3 });
  for (const suf of ['', '-fit']) execFileSync(compose, [`${outDir}/${name}-${label}-vs-today${suf}.png`, `${outDir}/${name}-today${suf}.png`, 'today', `${outDir}/${name}-${label}${suf}.png`, label]);
  console.log(b, 'today', say(mt), '|', label, say(md), r.info ? JSON.stringify(r.info).slice(0, 300) : '');
}
