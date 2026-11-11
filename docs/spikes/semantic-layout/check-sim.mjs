// Does similarity carry meaning? Linked pairs against unlinked pairs on the same board, same-frame pairs against the rest, and nearest neighbours.
import fs from 'fs';
import { EMB, loadSim } from './sim.mjs';
const g = JSON.parse(fs.readFileSync(new URL('./data/graph.json', import.meta.url)));
const N = new Map(g.nodes.map((n) => [n.key, n]));
const board = (k) => { let c = N.get(k)?.in; while (c) { const p = N.get(c); if (!p || p.kind === 'subboard') return c; c = p.in; } return 'root'; };
const notes = g.nodes.filter((n) => n.kind === 'sticky-note');
const byBoard = new Map(); for (const n of notes) { const b = board(n.key); if (!byBoard.has(b)) byBoard.set(b, []); byBoard.get(b).push(n.key); }
const linked = new Set(); for (const e of g.edges) { linked.add(e.from + '|' + e.to); linked.add(e.to + '|' + e.from); }
// AUC: chance a linked pair scores above an unlinked pair of the same board.
function auc(pos, neg) { const all = [...pos.map((x) => [x, 1]), ...neg.map((x) => [x, 0])].sort((a, b) => a[0] - b[0]); let r = 0, np = 0; all.forEach(([, l], i) => { if (l) { r += i + 1; np++; } }); const nn = all.length - np; return (r - np * (np + 1) / 2) / (np * nn); }
for (const model of ['sentence', 'contextual', 'openai-3-small', 'openai-3-large', 'tfidf']) {
  const sim = loadSim(model); const pos = [], neg = [];
  for (const [b, ks] of byBoard) { if (b === 'root') continue; for (let i = 0; i < ks.length; i++) for (let j = i + 1; j < ks.length; j++) (linked.has(ks[i] + '|' + ks[j]) ? pos : neg).push(sim(ks[i], ks[j])); }
  const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(p * (s.length - 1))].toFixed(3); };
  console.log(model.padEnd(15), 'linked', pos.length, 'median', q(pos, .5), '| unlinked', neg.length, 'median', q(neg, .5), '| AUC linked>unlinked', auc(pos, neg).toFixed(3), '| linked p10/p90', q(pos, .1), q(pos, .9));
}
const sim = loadSim(process.argv[2] || EMB);
for (const probe of ['file:Sources/Selection/Faces.swift', 'extension-point:ShapeParts', 'file:Sources/Canvas/Model/ShapeRecord.swift']) {
  const ks = byBoard.get(board(probe)).filter((k) => k !== probe).map((k) => [k, sim(probe, k)]).sort((a, b) => b[1] - a[1]);
  console.log('\n' + probe, '(' + board(probe) + ')\n  nearest: ' + ks.slice(0, 5).map(([k, s]) => k.split(/[:/]/).pop() + ' ' + s.toFixed(2)).join(', ') + '\n  farthest: ' + ks.slice(-3).map(([k, s]) => k.split(/[:/]/).pop() + ' ' + s.toFixed(2)).join(', '));
}
