// One board of a drawing as a square picture panel: the board (render.mjs), captioned with its title, the judged links it draws as arrows
// (with judge rows) and its health on that board.
// node panel.mjs <drawing.json> <board> <out.svg> "<title>" [judge rows.json]
import fs from 'fs';
import { execFileSync } from 'child_process';
import { score } from './score-drawing.mjs';
const [file, board, out, title, rows] = process.argv.slice(2);
const here = (p) => new URL(p, import.meta.url).pathname;
execFileSync('node', [here('./render.mjs'), file, board, out + '.board.svg'].concat(rows ? [rows] : []));
const h = score(JSON.parse(fs.readFileSync(file, 'utf8'))).boards[board];
const d = JSON.parse(fs.readFileSync(file, 'utf8')), arrow = new Set(d.edges.filter((e) => !e.place).map((e) => [e.from, e.to].sort().join('|')));
const judged = rows ? JSON.parse(fs.readFileSync(rows, 'utf8')).filter((r) => 'module:' + r.board === board) : [];
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split'), drawn = judged.filter((r) => arrow.has([r.a, r.b].sort().join('|')));
const n = (xs, c) => xs.filter((r) => cls(r) === c).length;
const W = 1400, CAP = judged.length ? 150 : 110, src = fs.readFileSync(out + '.board.svg', 'utf8');
const vb = /viewBox="([^"]+)"/.exec(src)[1];
const inner = src.replace(/^<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '');
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
const sub = `${h.links - h.cut} arrows of ${h.links} links, ${h.crossings} crossings, ${h.overShapes} lines over shapes`;
const lines = [title].concat(judged.length ? [`${n(drawn, 'keep')} of ${n(judged, 'keep')} keep links drawn as arrows, ${n(drawn, 'chip')} chip arrows`] : [], [sub]);
const text = lines.map((l, k) => `<text x="20" y="${46 + k * 40}" font-family="Helvetica" font-size="${k ? 28 : 36}" font-weight="${k ? 'normal' : 'bold'}" fill="#222">${esc(l)}</text>`).join('');
fs.writeFileSync(out, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${W}" width="${W}" height="${W}"><rect width="${W}" height="${W}" fill="#ffffff"/>${text}<svg x="0" y="${CAP}" width="${W}" height="${W - CAP}" viewBox="${vb}" preserveAspectRatio="xMidYMid meet">${inner}</svg></svg>`);
