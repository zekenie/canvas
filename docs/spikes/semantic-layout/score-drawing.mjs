// Scores any drawing.json (graph + place) with canvas-digest's own health check (this branch's tool): the same numbers for every strategy.
// node score-drawing.mjs <drawing.json> [boards...]  -> one JSON line, and per-board lines for the boards named
import fs from 'fs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges } = await import(TOOL + 'sizes.mjs');
const { healthOf } = await import(TOOL + 'health.mjs');
const rd = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const here = (p) => new URL(p, import.meta.url);
const graph = rd(here('./data/graph.json')), measure = rd(here('./data/measure.json')), kinds = rd(here('./data/kinds.json'));
export function score(drawing) {
  const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
  const sizes = sizesFrom(model, measure);
  const h = healthOf(model, drawing, sizes, { view: { w: 1322, h: 893 } });
  const N = new Map(drawing.nodes.map((n) => [n.key, n]));
  const board = (k) => { let c = N.get(k)?.in; while (c) { const p = N.get(c); if (!p || p.kind === 'subboard') return c; c = p.in; } return 'root'; };
  let arrows = 0, intraPills = 0, crossPills = 0;
  for (const e of drawing.edges) { const intra = board(e.from) === board(e.to); if (!e.place) arrows++; else if (intra) intraPills++; else crossPills++; }
  let area = 0; for (const [b, v] of Object.entries(h.boards)) if (b !== 'root') area += v.size[0] * v.size[1];
  const t = h.totals;
  return { summary: { arrows, intraPills, crossPills, clean: t.clean, of: t.boards, crossings: t.crossings, overShapes: t.overShapes, onTop: t.onTop, ownLines: t.overOwnPills, areaM: Math.round(area / 1e6) }, boards: h.boards };
}
// run as a command only (another script may import score)
if (process.argv[1] && new URL(import.meta.url).pathname === fs.realpathSync(process.argv[1])) {
  const r = score(rd(process.argv[2]));
  console.log(JSON.stringify(r.summary));
  for (const b of process.argv.slice(3)) { const v = r.boards[b]; console.log(b, JSON.stringify({ status: v.status, crossings: v.crossings, overShapes: v.overShapes, onTop: v.onTop, links: v.links, cut: v.cut, pills: v.pills, size: v.size })); }
}
