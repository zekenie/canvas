// The graph document with each cluster cluster.mjs made held in a frame of its own (key cluster:<board>:<n>), so semlayout.mjs lays each
// cluster out by itself and then places the clusters as blocks, the lines cut between two clusters a light pull between the blocks. Only
// for the picture: what holds what in the lens's graph stays as it is. A note at the board's top level goes into its cluster's frame; a
// frame of the lens's (Plugin system) whose notes are all in one cluster goes in with them, and one whose notes are in several stays on the
// board, the clusters it reaches into placed around it. A note alone in its cluster stays on the board.
// A cluster that holds every item of its container gets no frame: it would only draw a second box round the first.
//   node cluster-frames.mjs <cluster dir: stats.json> <out graph.json> [graph in: the lens's, data/graph.json unless named]
import fs from 'fs';
const [dir, out, from] = process.argv.slice(2);
const graph = JSON.parse(fs.readFileSync(from || new URL('./data/graph.json', import.meta.url), 'utf8'));
const stats = JSON.parse(fs.readFileSync(dir + '/stats.json', 'utf8'));
const byKey = new Map(graph.nodes.map((n) => [n.key, n]));
const frameOf = (b, c) => `cluster:${b}:${c}`;
const added = [], moved = new Map();   // node key -> its new container
for (const b of stats.boards) {
  if (b.levels) {
    // cluster.mjs --frames=units: each container's clusters of two or more items (notes, and frames as one unit) go in a frame of their own
    // inside that container, so a lens frame goes in with its cluster on the board, and its own clusters are frames inside it
    for (const [C, items] of Object.entries(b.levels)) {
      const size = new Map(); for (const c of Object.values(items)) size.set(c, (size.get(c) || 0) + 1);
      const holder = C.slice(2), need = new Set();
      const whole = (c) => size.get(c) === Object.keys(items).length;
      for (const [k, c] of Object.entries(items)) if (size.get(c) > 1 && !whole(c)) { moved.set(k, `cluster:${C}:${c}`); need.add(c); }
      // the root board is written as no container at all
      // untitled: the app takes no blank title
      for (const c of [...need].sort((x, y) => x - y)) added.push({ key: `cluster:${C}:${c}`, ...(C === 'b:root' ? {} : { in: holder }), kind: 'frame', props: {} });
    }
    continue;
  }
  const size = new Map(); for (const c of Object.values(b.members)) size.set(c, (size.get(c) || 0) + 1);
  const need = new Set();
  for (const [k, c] of Object.entries(b.members)) if (size.get(c) > 1 && byKey.get(k).in === b.board) { moved.set(k, frameOf(b.board, c)); need.add(c); }
  // the lens's frames on this board: in with a cluster when every note in them is in that one
  for (const f of graph.nodes.filter((n) => n.in === b.board && n.kind === 'frame')) {
    const cs = new Set(graph.nodes.filter((n) => n.in === f.key && b.members[n.key] != null).map((n) => b.members[n.key]));
    if (cs.size === 1) { const [c] = cs; if (size.get(c) > 1) { moved.set(f.key, frameOf(b.board, c)); need.add(c); } }
  }
  for (const c of [...need].sort((x, y) => x - y)) added.push({ key: frameOf(b.board, c), in: b.board, kind: 'frame', props: { title: ' ' } });
}
const nodes = graph.nodes.map((n) => (moved.has(n.key) ? { ...n, in: moved.get(n.key) } : n)).concat(added);
fs.writeFileSync(out, JSON.stringify({ ...graph, nodes }));
console.log(out, 'cluster frames', added.length, 'moved', moved.size);
