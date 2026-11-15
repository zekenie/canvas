// How a drawing came out, by the layout branch's health check against the graph it was drawn from: the links inside boards drawn as
// arrows, the boards drawn clean, and the same for the six boards the pictures show. Given cluster.mjs's folder, also how many of those
// six boards' links were cut between clusters before layout, and so how many more the engine cut inside clusters to draw clean: right
// only where no cut link is put back (SIM_KEEPCUT); where some are, strategy-pairs.mjs counts each way.
//   DIGEST_TOOL=... node strategy-counts.mjs <graph.json> <drawing.json> <name> [cluster dir]
import fs from 'fs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges } = await import(TOOL + 'sizes.mjs');
const { healthOf } = await import(TOOL + 'health.mjs');
const rd = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const here = (p) => new URL(p, import.meta.url);
const [graphFile, drawingFile, name, clusters] = process.argv.slice(2);
const measure = rd(here('./data/measure.json')), kinds = rd(here('./data/kinds.json'));
const model = buildModel(rd(graphFile), kinds, { refused: refusedEdges(measure) });
const h = healthOf(model, rd(drawingFile), sizesFrom(model, measure), { view: { w: 1322, h: 893 } });
const SIX = ['Selection', 'Mentions', 'Draw', 'References', 'Canvas/Model', 'Types/Form'].map((b) => 'module:' + b);
let links = 0, drawn = 0, six = 0, sixDrawn = 0;
const rows = [];
for (const [b, v] of Object.entries(h.boards)) {
  links += v.links; drawn += v.links - v.cut;
  if (SIX.includes(b)) { six += v.links; sixDrawn += v.links - v.cut; rows.push(`${b.slice(7)} ${v.links - v.cut}/${v.links}`); }
}
const t = h.totals;
console.log(`${name}: ${drawn} of ${links} links inside boards are arrows; ${t.clean} of ${t.boards} boards clean, ${t.crossings} crossings`);
console.log(`  the six boards: ${sixDrawn} of ${six} (${rows.sort().join(', ')})`);
if (clusters) {
  const between = rd(clusters + '/stats.json').boards.filter((b) => SIX.includes(b.board)).reduce((s, b) => s + b.cut, 0);
  console.log(`  of the six boards' links: ${between} between clusters are pills from the start, ${six - between - sixDrawn} more inside clusters the engine cut to draw clean`);
}
