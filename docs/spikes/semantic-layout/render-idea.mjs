// The owner's idea (2026-11-13) drawn on one board, as a square picture panel: each note filled in the colour of the cluster cluster.mjs
// put it in (a note alone is grey), each arrow as dark and thick as its link is tight (cluster.mjs's weight, the board's loosest palest),
// each pill in the colour of the cluster of the note it stands for, the lines into pills pale. Frames, notes and pills as render.mjs.
//   node render-idea.mjs <drawing.json> <board> <out.svg> <cluster dir: stats.json, tight.json> "<title>" "<subtitle>"
import fs from 'fs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges } = await import(TOOL + 'sizes.mjs');
const { readDrawing } = await import(TOOL + 'health.mjs');
const rd = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const here = (p) => new URL(p, import.meta.url);
const [file, board, out, dir, heading, sub] = process.argv.slice(2);
const graph = rd(process.env.GRAPH || here('./data/graph.json')), measure = rd(here('./data/measure.json')), kinds = rd(here('./data/kinds.json'));
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const B = readDrawing(model, rd(file), sizesFrom(model, measure)).get(board);
const members = rd(dir + '/stats.json').boards.find((b) => b.board === board).members, tight = rd(dir + '/tight.json');
const titles = new Map(graph.nodes.map((n) => [n.key, n.props.title]));
const title = (k) => titles.get(k) || k;
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');

// the clusters of two or more notes, largest first, take the dataviz reference palette's categorical hues in order
const HUES = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#6250d6', '#e34948'];
const size = new Map(); for (const c of Object.values(members)) size.set(c, (size.get(c) || 0) + 1);
const big = [...size.keys()].filter((c) => size.get(c) > 1).sort((a, b) => size.get(b) - size.get(a) || a - b);
if (big.length > HUES.length) throw new Error(`${board}: ${big.length} clusters, more than the palette's ${HUES.length} hues`);
const hueOf = new Map(big.map((c, i) => [c, HUES[i]]));
const hue = (k) => hueOf.get(members[k]);
const mix = (hex, t) => '#' + [1, 3, 5].map((i) => Math.round(255 + (parseInt(hex.slice(i, i + 2), 16) - 255) * t).toString(16).padStart(2, '0')).join('');
const fillOf = (k) => (hue(k) ? mix(hue(k), 0.32) : '#efede8'), strokeOf = (k) => (hue(k) ? hue(k) : '#a8a49a');

let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
for (const s of [...B.shapes, ...B.pills]) { x0 = Math.min(x0, s.box.x); y0 = Math.min(y0, s.box.y - 30); x1 = Math.max(x1, s.box.x + s.box.w); y1 = Math.max(y1, s.box.y + s.box.h); }
const pad = 60; x0 -= pad; y0 -= pad; x1 += pad; y1 += pad;
let g = `<rect x="${x0}" y="${y0}" width="${x1 - x0}" height="${y1 - y0}" fill="#fbfaf7"/>`;
// a cluster's frame (cluster-frames.mjs) is only a faint wash of its colour behind it, drawn first; the lens's frames as render.mjs
// a cluster's frame takes the colour of the notes in it (inside a lens frame, the lens frame's cluster); frames drawn outermost first
const inOf = new Map(graph.nodes.map((n) => [n.key, n.in])), kids = new Map();
for (const n of graph.nodes) { if (!kids.has(n.in)) kids.set(n.in, []); kids.get(n.in).push(n.key); }
const noteIn = (id) => { for (const k of kids.get(id) || []) { if (members[k] != null) return k; const d = noteIn(k); if (d) return d; } return null; };
const depth = (id) => (inOf.has(id) && inOf.get(id) !== board ? 1 + depth(inOf.get(id)) : 0);
const isCluster = (s) => s.id.startsWith('cluster:'), clusterHue = (s) => hue(noteIn(s.id)) || '#a8a49a';
for (const s of B.shapes.filter((s) => s.frame).sort((p, q) => depth(p.id) - depth(q.id)))
  g += isCluster(s) ? `<rect x="${s.box.x}" y="${s.box.y}" width="${s.box.w}" height="${s.box.h}" rx="40" fill="${mix(clusterHue(s), 0.1)}" stroke="${mix(clusterHue(s), 0.35)}" stroke-width="4"/>`
    : `<rect x="${s.box.x}" y="${s.box.y}" width="${s.box.w}" height="${s.box.h}" rx="12" fill="#f1efe9" stroke="#b9b4a8" stroke-width="4"/><text x="${s.box.x + 10}" y="${s.box.y - 10}" font-size="34" fill="#6b665c">${esc(title(s.id))}</text>`;
// lines: into pills pale and thin, then arrows from the loosest (pale, thin) to the tightest (near black, thick) on top
const k = (x1 - x0) / 1000;
const w = (l) => tight[[...l.edge].sort().join('\u0000')] ?? 0.1;
const lines = B.lines.slice().sort((p, q) => (p.intoPill ? -1 : w(p)) - (q.intoPill ? -1 : w(q)));
for (const l of lines) {
  const pts = l.path.map((p) => p.join(',')).join(' ');
  let col, width;
  if (l.intoPill) { col = '#d3cfc5'; width = Math.max(3, 0.7 * k); } else { const t = (w(l) - 0.1) / 0.9; col = mix('#2b2a27', 0.18 + 0.82 * t); width = Math.max(3, (0.8 + 2.8 * t) * k); }
  g += `<polyline points="${pts}" fill="none" stroke="${col}" stroke-width="${width.toFixed(1)}" stroke-linejoin="round"/>`;
}
for (const s of B.shapes.filter((s) => !s.frame)) {
  g += `<rect x="${s.box.x}" y="${s.box.y}" width="${s.box.w}" height="${s.box.h}" rx="6" fill="${fillOf(s.id)}" stroke="${strokeOf(s.id)}" stroke-width="5"/>`;
  g += `<text x="${s.box.x + 12}" y="${s.box.y + 40}" font-size="30" font-weight="bold" fill="#222">${esc(title(s.id).replace(/\.swift$/, '').slice(0, 22))}</text>`;
}
for (const p of B.pills) g += `<rect x="${p.box.x}" y="${p.box.y}" width="${p.box.w}" height="${p.box.h}" rx="20" fill="${hue(p.target) ? mix(hue(p.target), 0.22) : '#efede8'}" stroke="${strokeOf(p.target)}" stroke-width="3"/><text x="${p.box.x + 12}" y="${p.box.y + 28}" font-size="22" fill="#222">${esc(title(p.target).replace(/\.swift$/, '').slice(0, 14))}</text>`;

const W = 1400, CAP = 120;
const text = [heading, sub].filter(Boolean).map((l, i) => `<text x="24" y="${50 + i * 42}" font-family="Helvetica" font-size="${i ? 28 : 38}" font-weight="${i ? 'normal' : 'bold'}" fill="${i ? '#555' : '#222'}">${esc(l)}</text>`).join('');
fs.writeFileSync(out, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${W}" width="${W}" height="${W}" font-family="Helvetica, Arial"><rect width="${W}" height="${W}" fill="#ffffff"/>${text}<svg x="0" y="${CAP}" width="${W}" height="${W - CAP}" viewBox="${x0} ${y0} ${x1 - x0} ${y1 - y0}" preserveAspectRatio="xMidYMid meet">${g}</svg></svg>`);
console.log(out, 'clusters', big.length, 'arrows', B.lines.filter((l) => !l.intoPill).length, 'pills', B.pills.length);
