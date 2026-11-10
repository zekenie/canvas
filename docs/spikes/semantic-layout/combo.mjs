// Similarity and popularity together: does a hub penalty fix what similarity misses? AUC of keep (both judges >= 1.5 mean) over chip (both 0).
import fs from 'fs';
import { loadSim } from './sim.mjs';
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const rows = rd('./judge/rows.json'), g = rd('./data/graph.json');
const N = new Map(g.nodes.map((n) => [n.key, n]));
const board = (k) => { let c = N.get(k)?.in; while (c) { const p = N.get(c); if (!p || p.kind === 'subboard') return c; c = p.in; } return 'root'; };
// degree on the board (links inside the board), and in-degree from anywhere
const bdeg = new Map(), indeg = new Map();
for (const e of g.edges) { if (board(e.from) === board(e.to)) for (const t of [e.from, e.to]) bdeg.set(t, (bdeg.get(t) || 0) + 1); indeg.set(e.to, (indeg.get(e.to) || 0) + 1); }
const c = loadSim('contextual'), t = loadSim('tfidf');
const z = (vals) => { const mu = vals.reduce((a, b) => a + b, 0) / vals.length; const sd = Math.sqrt(vals.reduce((a, b) => a + (b - mu) ** 2, 0) / vals.length) || 1; return vals.map((v) => (v - mu) / sd); };
const sim = z(rows.map((r) => c(r.a, r.b))).map((x, i) => x + z(rows.map((r) => t(r.a, r.b)))[i]);
const hub = z(rows.map((r) => Math.sqrt(Math.max(bdeg.get(r.a) || 0, bdeg.get(r.b) || 0))));
const auc = (score) => { const pos = [], neg = []; rows.forEach((r, i) => { const s = r.ja + r.jb; if (s >= 3) pos.push(score[i]); else if (s === 0) neg.push(score[i]); }); let a = 0; for (const p of pos) for (const q of neg) a += p > q ? 1 : p === q ? 0.5 : 0; return (a / (pos.length * neg.length)).toFixed(3); };
console.log('similarity (contextual + tf-idf)          ', auc(sim));
console.log('hub penalty alone (busier end, on board)  ', auc(hub.map((h) => -h)));
for (const lam of [0.25, 0.5, 0.75, 1, 1.5]) console.log(`similarity - ${lam} x hub                  `.slice(0, 43), auc(sim.map((s, i) => s - lam * hub[i])));
