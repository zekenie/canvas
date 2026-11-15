// How the corpus drew, counted as the spike's strategy-pairs.mjs counts it: a link is a pair of notes on one board (however many edges join them, both ways),
// an arrow if any of its edges has no place (is drawn as one), and the links between groups are the pairs `cluster` marked layout.cut (the clustered document's
// edges). For all boards and for the six the spike's pictures show: the links drawn as arrows; the links between groups, and how many of them came back as
// arrows (the put-back, restore.mjs); the links inside groups, and how many of them the engine cut. And the boards drawn clean, by the health check against
// the clustered document the drawing was planned from, with the spike's measurement. Prints the lines the check compares; fails on none itself.
//   node corpus-counts.mjs <data folder> <clustered.json> <drawing.json> <measure.json>
import fs from 'fs';
const here = (p) => new URL(p, import.meta.url).href;
const { buildModel } = await import(here('../lib/model.mjs'));
const { sizesFrom, refusedEdges } = await import(here('../lib/sizes.mjs'));
const { healthOf } = await import(here('../lib/health.mjs'));
const [data, graphFile, drawingFile, measureFile] = process.argv.slice(2);
const rd = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const measure = rd(measureFile), kinds = rd(data + '/kinds.json'), graph = rd(graphFile), drawing = rd(drawingFile);
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const h = healthOf(model, drawing, sizesFrom(model, measure), { view: { w: 1322, h: 893 } });

const SEP = '\u0000', pairOf = (a, b) => (a < b ? a + SEP + b : b + SEP + a);
const N = new Map(drawing.nodes.map((n) => [n.key, n]));
const board = (k) => { let c = N.get(k)?.in; while (c) { const p = N.get(c); if (!p || p.kind === 'subboard') return c; c = p.in; } return 'root'; };
// the pairs `cluster` cut between two groups
const between = new Set(graph.edges.filter((e) => e.layout && e.layout.cut === true).map((e) => pairOf(e.from, e.to)));
// every link: the pairs of notes on one board, an arrow if any of its edges is drawn as one
const links = new Map();
for (const e of drawing.edges) {
  const b = board(e.from);
  if (b !== board(e.to)) continue;
  const k = pairOf(e.from, e.to);
  if (!links.has(k)) links.set(k, { board: b, arrow: false });
  if (!e.place) links.get(k).arrow = true;
}
const SIX = new Set(['Selection', 'Mentions', 'Draw', 'References', 'Canvas/Model', 'Types/Form'].map((b) => 'module:' + b));
const count = (keep) => {
  const c = { links: 0, arrows: 0, between: 0, back: 0, inside: 0, insideCut: 0 };
  for (const [k, l] of links) {
    if (!keep(l)) continue;
    c.links++; if (l.arrow) c.arrows++;
    if (between.has(k)) { c.between++; if (l.arrow) c.back++; } else { c.inside++; if (!l.arrow) c.insideCut++; }
  }
  return c;
};
const all = count(() => true), six = count((l) => SIX.has(l.board)), t = h.totals;
console.log(`${all.arrows} of ${all.links} links inside boards are arrows; ${t.clean} of ${t.boards} boards clean`);
console.log(`${all.between} links between groups, ${all.back} of them back as arrows; ${all.inside} inside groups, ${all.insideCut} of them cut by the engine`);
console.log(`the six boards ${six.arrows} of ${six.links} arrows: ${six.between} between groups, ${six.back} back; ${six.inside} inside, ${six.insideCut} cut`);
