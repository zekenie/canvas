// The busiest notes on a judged board, by the judged links they're in: how many of those links a background.mjs run broke, and how many
// each drawing draws as arrows, with the judges' labels (chip/split/keep).  node hubs.mjs <Board> <stats.json> <name=drawing.json> ...
import fs from 'fs';
const [board, statsF, ...drawings] = process.argv.slice(2);
const rows = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8')).filter((r) => r.board === board);
const pk = (a, b) => [a, b].sort().join('|');
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
const t = (xs) => ['chip', 'split', 'keep'].map((c) => xs.filter((r) => cls(r) === c).length).join('/');
const deg = new Map(); for (const r of rows) for (const k of [r.a, r.b]) deg.set(k, (deg.get(k) || 0) + 1);
const hubs = [...deg].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, 3).map(([k]) => k);
const name = (k) => k.replace(/^[^:]*:/, '').replace(/^.*\//, '');
const st = JSON.parse(fs.readFileSync(statsF, 'utf8')).boards.find((b) => b.board === 'module:' + board);
const broke = new Set(st.order.map(([a, b]) => pk(a, b)));
for (const h of hubs) {
  const sp = rows.filter((r) => r.a === h || r.b === h), gone = sp.filter((r) => broke.has(pk(r.a, r.b)));
  const drawn = drawings.map((d) => { const [n, f] = d.split('='), D = JSON.parse(fs.readFileSync(f, 'utf8')), A = new Set(D.edges.filter((e) => !e.place).map((e) => pk(e.from, e.to))); const a = sp.filter((r) => A.has(pk(r.a, r.b))); return `${n} ${a.length} (${t(a)})`; });
  console.log(`${board} ${name(h)}: ${sp.length} judged links (${t(sp)}), the simulation broke ${gone.length} (${t(gone)}); arrows drawn: ${drawn.join(', ')}  [chip/split/keep]`);
}
