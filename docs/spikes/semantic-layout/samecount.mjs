// Selection cut by similarity alone, as many links as both judges chip: how many of them the judges chip, and what the misses are.
import fs from 'fs';
import { EMB, loadSim } from './sim.mjs';
const rows = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8')).filter((r) => r.board === 'Selection');
const c = loadSim(EMB), t = loadSim('tfidf');
const z = (v) => { const mu = v.reduce((a, b) => a + b, 0) / v.length, sd = Math.sqrt(v.reduce((a, b) => a + (b - mu) ** 2, 0) / v.length) || 1; return v.map((x) => (x - mu) / sd); };
const zc = z(rows.map((r) => c(r.a, r.b))), zt = z(rows.map((r) => t(r.a, r.b)));
rows.forEach((r, i) => { r.sim = zc[i] + zt[i]; r.cls = r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split'; });
const sorted = [...rows].sort((x, y) => x.sim - y.sim || (x.a + x.b).localeCompare(y.a + y.b));
const n = rows.filter((r) => r.cls === 'chip').length, cut = sorted.slice(0, n);
const count = (xs) => ['chip', 'split', 'keep'].map((k) => xs.filter((r) => r.cls === k).length).join('/');
const nm = (k) => k.replace(/^.*\//, '').replace(/\.swift$/, '');
console.log(`Selection: the ${n} least alike of ${rows.length} links are ${count(cut)} [chip/split/keep]; chips left as arrows: ${sorted.slice(n).filter((r) => r.cls === 'chip').map((r) => nm(r.a) + '~' + nm(r.b)).join(', ')}`);
