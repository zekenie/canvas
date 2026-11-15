// A direction's layout of every module board as a drawing the app can apply (the root, and any board the direction fails on, as today's),
// with each board's measures. node build.mjs <scratch> <direction module.mjs> <out dir> [board ...]
//   <out dir>/drawing.json, kinds.json, measure.json (for `digest apply --out <out dir>`), metrics.json (each board: kit.evaluate and the
//   direction's info), failed boards on standard error.
import fs from 'fs';
import path from 'path';
import { load } from '../harness.mjs';
import { evaluate } from './kit.mjs';

const [S, modPath, outDir, ...only] = process.argv.slice(2);
const mod = await import(path.resolve(modPath));
const m = load(S + '/data');
const today = JSON.parse(fs.readFileSync(S + '/run/today/drawing.json', 'utf8'));
const graph = m.graph;
fs.mkdirSync(outDir, { recursive: true });
for (const f of ['kinds.json', 'measure.json']) fs.copyFileSync(S + '/data/' + f, outDir + '/' + f);   // the app's answers, kept beside the drawing for `digest apply`

const layouts = new Map(), failed = [], metrics = {};
for (const b of m.boards.keys()) {
  if (b === 'root' || (only.length && !only.includes(b))) continue;
  try {
    const r = await mod.layoutBoard(m, b);
    layouts.set(b, r.layout);
    metrics[b] = Object.assign(evaluate(m, b, r.layout), { info: r.info || null });
  } catch (e) { failed.push(`${b}: ${String(e && e.stack || e).split('\n').slice(0, 3).join(' | ')}`); }
}

const round = (v) => Math.round(v);
const nodes = today.nodes.map((n) => {
  const lay = layouts.get(m.boardOf(n.key));
  const box = lay && lay.boxes[n.key];
  if (!box) return n;
  const holder = n.in != null && m.node(n.in).isFrame ? lay.boxes[n.in] : null;
  const at = holder ? [box.x - holder.x, box.y - holder.y] : [box.x, box.y];
  const size = m.node(n.key).isFrame ? [box.w, box.h] : n.place.size;
  return Object.assign({}, n, { place: { at: at.map(round), size: size.map(round) } });
});

const arrowOf = new Map();
for (const lay of layouts.values()) for (const a of lay.arrows) if (a.edge != null && !arrowOf.has(a.edge)) arrowOf.set(a.edge, { a, lay });
const todayByIndex = new Map();
{
  const seen = new Map();
  graph.edges.forEach((e, i) => { const k = e.from + '\u0000' + e.to; if (!seen.has(k)) seen.set(k, []); seen.get(k).push(i); });
  const used = new Map();
  for (const e of today.edges) { const k = e.from + '\u0000' + e.to, l = seen.get(k) || [], u = used.get(k) || 0; if (u < l.length) todayByIndex.set(l[u], e); used.set(k, u + 1); }
}
const hosts = [], sharers = [], pillHost = new Map();
const stats = { arrows: 0, bent: 0, pillsMade: 0, pillsShared: 0, keptToday: 0, missing: [] };
graph.edges.forEach((raw, i) => {
  const base = todayByIndex.get(i);
  if (!base) return;
  const found = arrowOf.get(i);
  const board = m.nodes.has(raw.from) ? m.boardOf(raw.from) : null;
  if (!found) {
    if (layouts.has(board)) stats.missing.push(i); else stats.keptToday++;
    ((base.place && base.place.pill && base.place.pill.share != null) ? sharers : hosts).push(base);
    return;
  }
  const { a, lay } = found;
  const edge = Object.assign({}, raw);
  delete edge.place;
  const props = Object.assign({}, raw.props || {});
  const pill = lay.pills.find((p) => p.id === a.to);
  if (pill && a.bend && Math.abs(a.bend) >= 8) { props.bend = round(a.bend); stats.bent++; }
  if (pill) {
    const key = board + '\u0000' + pill.id, host = pillHost.get(key);
    if (host != null) { edge.place = { pill: { share: host } }; stats.pillsShared++; }
    else {
      pillHost.set(key, raw.from);
      const n = m.node(raw.from), frame = n.in != null && m.node(n.in).isFrame ? n.in : null, fb = frame ? lay.boxes[frame] : null;
      edge.place = { pill: Object.assign({ at: fb ? [round(pill.x - fb.x), round(pill.y - fb.y)] : [round(pill.x), round(pill.y)] }, frame ? { in: frame } : {}) };
      stats.pillsMade++;
    }
  } else {
    stats.arrows++;
    if (a.bend && Math.abs(a.bend) >= 8) { props.bend = round(a.bend); stats.bent++; }
  }
  if (Object.keys(props).length) edge.props = props;
  ((edge.place && edge.place.pill && edge.place.pill.share != null) ? sharers : hosts).push(edge);
});
const out = { drawing: today.drawing || 'drawing' };
if (today.layout) out.layout = today.layout;
out.nodes = nodes;
out.edges = hosts.concat(sharers);
fs.writeFileSync(outDir + '/drawing.json', JSON.stringify(out, null, 1));
fs.writeFileSync(outDir + '/metrics.json', JSON.stringify(metrics, null, 1));
const vals = Object.values(metrics);
const sum = (k) => vals.reduce((s, r) => s + (r[k] || 0), 0);
console.log(JSON.stringify({ boards: layouts.size, clean: vals.filter((r) => r.clean).length, crossings: sum('crossings'), overNotes: sum('overNotes'), overPills: sum('overPills'), pills: sum('pills'), stats: Object.assign({}, stats, { missing: stats.missing.length }) }));
if (failed.length) console.error('FAILED\n' + failed.join('\n'));
