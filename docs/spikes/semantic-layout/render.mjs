// An SVG of one board of a drawing.json: frames, notes (title), pills (what they stand for), arrows and pill lines, straight as health reads them.
// node render.mjs <drawing.json> <board> <out.svg> [labels: judge rows.json to colour judged arrows: blue keep, red chip, grey between]
import fs from 'fs';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { sizesFrom, refusedEdges } = await import(TOOL + 'sizes.mjs');
const { readDrawing } = await import(TOOL + 'health.mjs');
const rd = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const here = (p) => new URL(p, import.meta.url);
const [file, board, out, labelsPath] = process.argv.slice(2);
const graph = rd(here('./data/graph.json')), measure = rd(here('./data/measure.json')), kinds = rd(here('./data/kinds.json'));
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const sizes = sizesFrom(model, measure);
const B = readDrawing(model, rd(file), sizes).get(board);
const judged = new Map();
if (labelsPath) for (const r of rd(labelsPath)) judged.set([r.a, r.b].sort().join('|'), r.ja + r.jb);
const title = (k) => { const n = graph.nodes.find((x) => x.key === k); return n ? n.props.title : k; };
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
for (const s of [...B.shapes, ...B.pills]) { x0 = Math.min(x0, s.box.x); y0 = Math.min(y0, s.box.y - 30); x1 = Math.max(x1, s.box.x + s.box.w); y1 = Math.max(y1, s.box.y + s.box.h); }
const pad = 60; x0 -= pad; y0 -= pad; x1 += pad; y1 += pad;
let svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${x0} ${y0} ${x1 - x0} ${y1 - y0}" width="${Math.round((x1 - x0) / 4)}" height="${Math.round((y1 - y0) / 4)}" font-family="Helvetica, Arial">`;
svg += `<rect x="${x0}" y="${y0}" width="${x1 - x0}" height="${y1 - y0}" fill="#fbfaf7"/>`;
for (const s of B.shapes.filter((s) => s.frame)) svg += `<rect x="${s.box.x}" y="${s.box.y}" width="${s.box.w}" height="${s.box.h}" rx="12" fill="#f1efe9" stroke="#b9b4a8" stroke-width="4"/><text x="${s.box.x + 10}" y="${s.box.y - 10}" font-size="34" fill="#6b665c">${esc(title(s.id))}</text>`;
// Lines are drawn as thick as a board's size needs to show at a picture's scale, and the judges' classes in the dataviz reference
// palette's blue and red (a colour-blind-safe pair) with a neutral grey between: pale lines into pills first, keep and chip arrows on top.
const k = (x1 - x0) / 1000, line = (l) => { const j = l.intoPill ? undefined : judged.get([l.a, l.b].sort().join('|')); return { l, j, rank: l.intoPill ? 0 : j == null ? 1 : j >= 3 || j === 0 ? 3 : 2 }; };
for (const { l, j, rank } of B.lines.map(line).sort((p, q) => p.rank - q.rank)) {
  const pts = l.path.map((p) => p.join(',')).join(' ');
  const [col, w] = rank === 0 ? ['#d6d3ca', Math.max(3, 0.8 * k)] : rank === 1 ? ['#52514e', Math.max(4, 1.6 * k)] : rank === 2 ? ['#a19d92', Math.max(5, 2 * k)] : [j >= 3 ? '#2a78d6' : '#e34948', Math.max(7, 3.2 * k)];
  svg += `<polyline points="${pts}" fill="none" stroke="${col}" stroke-width="${w.toFixed(1)}" stroke-linejoin="round"/>`;
}
for (const s of B.shapes.filter((s) => !s.frame)) {
  const card = model.node(s.id).holds === 'board';
  svg += `<rect x="${s.box.x}" y="${s.box.y}" width="${s.box.w}" height="${s.box.h}" rx="${card ? 16 : 4}" fill="${card ? '#e8eef8' : '#fff4b8'}" stroke="#a89b5c" stroke-width="3"/>`;
  svg += `<text x="${s.box.x + 12}" y="${s.box.y + 40}" font-size="30" font-weight="bold" fill="#333">${esc(title(s.id).replace(/\.swift$/, '').slice(0, 22))}</text>`;
}
for (const p of B.pills) svg += `<rect x="${p.box.x}" y="${p.box.y}" width="${p.box.w}" height="${p.box.h}" rx="20" fill="#dfeaf5" stroke="#7d9bb8" stroke-width="2"/><text x="${p.box.x + 12}" y="${p.box.y + 28}" font-size="22" fill="#2d4a66">${esc(title(p.target).replace(/\.swift$/, '').slice(0, 14))}</text>`;
svg += '</svg>';
fs.writeFileSync(out, svg);
console.log(out, Math.round(x1 - x0), 'x', Math.round(y1 - y0), 'lines', B.lines.length, 'pills', B.pills.length);
