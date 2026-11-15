// Writes the corpus check's fixtures (strategy/: tightness.json, groups.json, measure.json) from the spike's untracked data, which the tracked
// data.tar.gz does not hold: OpenAI's vectors (data/emb-openai-3-large.f16, 962 of them, half floats) and the groups they made at resolution 1.5, the
// strategy's (data/groups-decided.json: cluster.mjs --frames=units --res=1.5; the respike's groups at resolution 1 are data/groups.json).
// A one-off record, run once with no task (the vectors are the spike folder's own and not in git): tightness.json is a `tightness` member as
// `canvas measure --tightness` answers one, from the spike's own arithmetic (cluster.mjs 33-45 and 55: each board's notes' vectors centred on the
// board's mean, in key order, then the cosine), over the pairs the tool's model has. strategy.tar.gz is `tar czf strategy.tar.gz strategy`.
//   node strategy-tightness.mjs <spike folder> <canvas-digest tool folder> [out folder, strategy]
import fs from 'fs';
const [SPIKE, TOOL, OUT = 'strategy'] = process.argv.slice(2);
if (!SPIKE || !TOOL) throw new Error('usage: node strategy-tightness.mjs <the spike folder (docs/spikes/semantic-layout, with data/)> <the canvas-digest tool folder> [out folder]');
const lib = TOOL.replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(lib + 'model.mjs');
const { refusedEdges } = await import(lib + 'sizes.mjs');
const { readVectors } = await import(SPIKE.replace(/\/$/, '') + '/sim.mjs');
const rd = (p) => JSON.parse(fs.readFileSync(SPIKE + '/data/' + p, 'utf8'));
const graph = rd('graph.json'), measure = rd('measure.json'), kinds = rd('kinds.json');
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

const raw = readVectors('openai-3-large');
const unit = (v) => { let s = 0; for (const x of v) s += x * x; s = Math.sqrt(s) || 1; return v.map((x) => x / s); };
const points = new Map();
for (const k of [...model.nodes.keys()].sort(byKey)) { const n = model.node(k); if (n.holds === 'shapes') continue; if (!points.has(n.board)) points.set(n.board, []); points.get(n.board).push(k); }
const vec = new Map();
for (const [, ks] of points) {
  const have = ks.filter((k) => raw[k]); if (!have.length) continue;
  const d = raw[have[0]].length, mean = new Array(d).fill(0);
  for (const k of have) for (let i = 0; i < d; i++) mean[i] += raw[k][i] / have.length;
  for (const k of have) vec.set(k, unit(raw[k].map((x, i) => x - mean[i])));
}
const cos = (a, b) => { const x = vec.get(a), y = vec.get(b); if (!x || !y) return 0; let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * y[i]; return s; };

const pairs = new Map();
for (const e of model.edges) {
  const a = model.node(e.from), b = model.node(e.to);
  if (e.from === e.to || a.board !== b.board || a.holds === 'shapes' || b.holds === 'shapes') continue;
  const [x, y] = [e.from, e.to].sort(byKey), k = x + '\u0000' + y;
  if (!pairs.has(k)) pairs.set(k, { a: x, b: y, ...(a.board === 'root' ? {} : { board: a.board }), tightness: cos(x, y) });
}
const list = [...pairs.values()].sort((p, q) => byKey(p.a, q.a) || byKey(p.b, q.b));
const texts = new Set(); for (const [, ks] of points) for (const k of ks) texts.add(k);
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(OUT + '/tightness.json', JSON.stringify({ model: 'openai/text-embedding-3-large', texts: texts.size, asked: 0, pairs: list }));
fs.copyFileSync(SPIKE + '/data/groups-decided.json', OUT + '/groups.json');
fs.copyFileSync(SPIKE + '/data/measure.json', OUT + '/measure.json');
console.log(`${OUT}: ${list.length} pairs on ${new Set(list.map((p) => p.board || 'root')).size} boards, ${texts.size} notes' vectors`);
