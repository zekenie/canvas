// Every direction's totals over the 71 module boards beside today's, and Mentions: node table.mjs <scratch> [label=path/to/metrics.json ...]
import fs from 'fs';
import { load, layoutFromDrawing } from '../harness.mjs';
import { evaluate } from './kit.mjs';
const S = process.argv[2];
const m = load(S + '/data');
const today = JSON.parse(fs.readFileSync(S + '/run/today/drawing.json', 'utf8'));
const rows = {};
const t = {};
for (const b of m.boards.keys()) if (b !== 'root') t[b] = evaluate(m, b, layoutFromDrawing(m, today, b));
rows.today = t;
for (const D of ['grid', 'map', 'rows', 'stars', 'islands']) { const f = `${S}/run/planar-${D}/metrics.json`; if (fs.existsSync(f)) rows[D] = JSON.parse(fs.readFileSync(f, 'utf8')); }
for (const a of process.argv.slice(3)) { const [label, f] = a.split('='); rows[label] = JSON.parse(fs.readFileSync(f, 'utf8')); }
const area = (r) => r.size[0] * r.size[1];
console.log('direction  clean  crossings  overNotes  overOtherPills  pills   area vs today (median)   Mentions: crossings/overNotes/pills, size');
for (const [D, ms] of Object.entries(rows)) {
  const v = Object.values(ms), sum = (k) => v.reduce((s, r) => s + (r[k] || 0), 0);
  const ratios = Object.entries(ms).map(([b, r]) => area(r) / area(rows.today[b])).sort((a, b) => a - b);
  const mn = ms['module:Mentions'];
  console.log(D.padEnd(10), String(v.filter((r) => r.clean).length).padStart(5), String(sum('crossings')).padStart(10), String(sum('overNotes')).padStart(10), String(sum('overOtherPills')).padStart(15), String(sum('pills')).padStart(6),
    ('x' + ratios[Math.floor(ratios.length / 2)].toFixed(2)).padStart(12), '            ', `${mn.crossings}/${mn.overNotes}/${mn.pills}, ${mn.size.join('x')}`);
}
