// Where each link (a pair of notes on one board, as the health check counts them: an arrow if any of its edges is drawn as one) ended up,
// against the groups cluster.mjs found: the links between groups (pills from the start) and how many of them came back as arrows where
// their line crosses nothing, and the links inside groups and how many of them the engine still cut to draw clean. All boards and the six.
//   node strategy-pairs.mjs <cluster dir> <drawing.json> <name>
import fs from 'fs';
const rd = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const [dir, drawingFile, name] = process.argv.slice(2);
const d = rd(drawingFile), SEP = '\u0000';
const N = new Map(d.nodes.map((n) => [n.key, n]));
const board = (k) => { let c = N.get(k)?.in; while (c) { const p = N.get(c); if (!p || p.kind === 'subboard') return c; c = p.in; } return 'root'; };
const pairOf = (a, b) => (a < b ? a + SEP + b : b + SEP + a);
const between = new Set(rd(dir + '/cut.json').map(([a, b]) => pairOf(a, b)));
const links = new Map();
for (const e of d.edges) {
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
const say = (c) => `${c.arrows} of ${c.links} links are arrows; ${c.between} run between groups, ${c.back} of them came back as arrows; ` +
  `${c.inside} are inside groups, ${c.insideCut} of them cut by the engine`;
console.log(`${name}: all boards: ${say(count(() => true))}`);
console.log(`  the six boards: ${say(count((l) => SIX.has(l.board)))}`);
