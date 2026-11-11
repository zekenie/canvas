// How well does each way of choosing arrows agree with the two blind judges? Judged links: 459 on five boards.
import fs from 'fs';
import { loadSim } from './sim.mjs';
const rd = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const pairs = rd(new URL('./judge/pairs.json', import.meta.url));
const A = rd(new URL('./judge/labels-a.json', import.meta.url)), B = rd(new URL('./judge/labels-b.json', import.meta.url));
const rows = [];
for (const [board, list] of Object.entries(pairs)) {
  const short = board.replace('module:', '');
  list.forEach((p, i) => rows.push({ board: short, a: p.a, b: p.b, ja: A[short][String(i + 1)], jb: B[short][String(i + 1)] }));
}
// Judges against each other.
const agree = rows.filter((r) => r.ja === r.jb).length;
const kappa = (() => { const cats = [0, 1, 2]; const n = rows.length; let po = agree / n, pe = 0; for (const c of cats) pe += (rows.filter((r) => r.ja === c).length / n) * (rows.filter((r) => r.jb === c).length / n); return (po - pe) / (1 - pe); })();
const both2 = rows.filter((r) => r.ja === 2 && r.jb === 2).length, both0 = rows.filter((r) => r.ja === 0 && r.jb === 0).length;
console.log(`judges: ${rows.length} links; same label ${agree} (${(100 * agree / rows.length).toFixed(0)}%), kappa ${kappa.toFixed(2)}; both say keep side by side (2): ${both2}; both say chip (0): ${both0}`);
// Each judge as a ranker of the other: how well does judge A's score order judge B's keep (2) over chip (0)?
function auc(scored) { // scored: [score, isKeep]; ties count half
  const pos = scored.filter((x) => x[1]).map((x) => x[0]), neg = scored.filter((x) => !x[1]).map((x) => x[0]); let s = 0;
  for (const p of pos) for (const q of neg) s += p > q ? 1 : p === q ? 0.5 : 0; return s / (pos.length * neg.length);
}
const keepVsChip = (score) => { // consensus: mean label >= 1.5 is keep, mean label 0 is chip
  const xs = rows.filter((r) => (r.ja + r.jb) >= 3 || (r.ja + r.jb) === 0).map((r) => [score(r), (r.ja + r.jb) >= 3]); return auc(xs);
};
console.log(`consensus keep (mean >= 1.5): ${rows.filter((r) => r.ja + r.jb >= 3).length}, consensus chip (both 0): ${both0}`);
console.log(`ceiling, one judge ranking the other's keep over chip: A ranks B ${auc(rows.filter((r) => r.jb !== 1).map((r) => [r.ja, r.jb === 2])).toFixed(3)}, B ranks A ${auc(rows.filter((r) => r.ja !== 1).map((r) => [r.jb, r.ja === 2])).toFixed(3)}`);
// Rankers: similarity models, a mix, the link's weight, and popularity (main's idea: the busier end goes to a chip).
const g = rd(new URL('./data/graph.json', import.meta.url));
const deg = new Map(); for (const e of g.edges) { deg.set(e.from, (deg.get(e.from) || 0) + 1); deg.set(e.to, (deg.get(e.to) || 0) + 1); }
const indeg = new Map(); for (const e of g.edges) indeg.set(e.to, (indeg.get(e.to) || 0) + 1);
const weight = new Map(); for (const e of g.edges) { const k = [e.from, e.to].sort().join('|'); weight.set(k, (weight.get(k) || 0) + ((e.layout && e.layout.weight) || 1)); }
const sims = Object.fromEntries(['sentence', 'contextual', 'openai-3-small', 'openai-3-large', 'tfidf'].map((m) => [m, loadSim(m)]));
const z = (m) => { const v = rows.map((r) => sims[m](r.a, r.b)); const mu = v.reduce((a, b) => a + b) / v.length; const sd = Math.sqrt(v.reduce((a, b) => a + (b - mu) ** 2, 0) / v.length); return new Map(rows.map((r, i) => [r, (v[i] - mu) / sd])); };
const zt = z('tfidf'), mix = (m) => { const zm = z(m); return (r) => zm.get(r) + zt.get(r); };
const rankers = {
  'similarity: sentence (on-device)': (r) => sims.sentence(r.a, r.b),
  'similarity: contextual (on-device)': (r) => sims.contextual(r.a, r.b),
  'similarity: OpenAI text-embedding-3-small': (r) => sims['openai-3-small'](r.a, r.b),
  'similarity: OpenAI text-embedding-3-large': (r) => sims['openai-3-large'](r.a, r.b),
  'similarity: tf-idf words': (r) => sims.tfidf(r.a, r.b),
  'similarity: contextual + tf-idf': mix('contextual'),
  'similarity: 3-small + tf-idf': mix('openai-3-small'),
  'similarity: 3-large + tf-idf': mix('openai-3-large'),
  'link weight (uses)': (r) => weight.get([r.a, r.b].sort().join('|')),
  'popularity: busier end (in-degree), low keeps': (r) => -Math.max(indeg.get(r.a) || 0, indeg.get(r.b) || 0),
};
for (const [name, f] of Object.entries(rankers)) console.log(`AUC keep over chip, ${name.padEnd(46)} ${keepVsChip(f).toFixed(3)}`);
// The two drawings: an arrow (no place) on either direction of the pair counts as drawn.
for (const [name, file] of [['main', './out-main/drawing.json'], ['branch (slice 4)', './out-branch/drawing.json']]) {
  const d = rd(new URL(file, import.meta.url)); const arrow = new Set();
  for (const e of d.edges) if (!e.place) arrow.add([e.from, e.to].sort().join('|'));
  const isArrow = (r) => arrow.has([r.a, r.b].sort().join('|'));
  const by = (pred) => { const xs = rows.filter(pred); return `${xs.filter(isArrow).length}/${xs.length} arrows`; };
  console.log(`${name.padEnd(17)} consensus keep: ${by((r) => r.ja + r.jb >= 3)}; consensus chip: ${by((r) => r.ja + r.jb === 0)}; all judged: ${by(() => true)}; AUC ${keepVsChip((r) => (isArrow(r) ? 1 : 0)).toFixed(3)}`);
}
fs.writeFileSync(new URL('./judge/rows.json', import.meta.url), JSON.stringify(rows));
