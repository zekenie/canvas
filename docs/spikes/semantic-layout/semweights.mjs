// The graph again, every link inside a board weighted by how alike its two notes are (ranked within the board, 1 to 100), the rest as they were:
// this branch's tool then keeps, mends and puts back by meaning instead of by uses and hubs. node semweights.mjs <out graph.json> [sim]
import fs from 'fs';
import { loadSim } from './sim.mjs';
const g = JSON.parse(fs.readFileSync(new URL('./data/graph.json', import.meta.url), 'utf8'));
const N = new Map(g.nodes.map((n) => [n.key, n]));
const board = (k) => { let c = N.get(k)?.in; while (c) { const p = N.get(c); if (!p || p.kind === 'subboard') return c; c = p.in; } return 'root'; };
const which = process.argv[3] || 'mix';
const c = loadSim('contextual'), t = loadSim('tfidf');
const intra = g.edges.filter((e) => e.from !== e.to && board(e.from) === board(e.to));
const z = (f) => { const v = intra.map((e) => f(e.from, e.to)); const mu = v.reduce((a, b) => a + b, 0) / v.length; const sd = Math.sqrt(v.reduce((a, b) => a + (b - mu) ** 2, 0) / v.length); return (a, b) => (f(a, b) - mu) / sd; };
const zc = z(c), zt = z(t);
const sim = which === 'mix' ? (a, b) => zc(a, b) + zt(a, b) : loadSim(which);
const byBoard = new Map();
for (const e of intra) { const b = board(e.from); if (!byBoard.has(b)) byBoard.set(b, []); byBoard.get(b).push(e); }
for (const es of byBoard.values()) {
  const s = es.map((e) => [e, sim(e.from, e.to)]).sort((x, y) => x[1] - y[1] || (x[0].from + x[0].to < y[0].from + y[0].to ? -1 : 1));
  s.forEach(([e], i) => { e.layout = { ...(e.layout || {}), weight: 1 + Math.round(99 * (s.length > 1 ? i / (s.length - 1) : 1)) }; });
}
fs.writeFileSync(process.argv[2], JSON.stringify(g));
console.log('weighted', intra.length, 'links on', byBoard.size, 'boards');
