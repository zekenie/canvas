// Writes judge/boards.md: five dense boards, each note's title and text, and every link inside the board once (either direction).
import fs from 'fs';
const g = JSON.parse(fs.readFileSync(new URL('./data/graph.json', import.meta.url)));
const N = new Map(g.nodes.map((n) => [n.key, n]));
const board = (k) => { let c = N.get(k)?.in; while (c) { const p = N.get(c); if (!p || p.kind === 'subboard') return c; c = p.in; } return 'root'; };
const BOARDS = ['module:Selection', 'module:Mentions', 'module:Draw', 'module:Canvas/Model', 'module:References'];
let md = '', pairs = {}, total = 0;
for (const b of BOARDS) {
  const notes = g.nodes.filter((n) => n.kind === 'sticky-note' && board(n.key) === b);
  const name = new Map(); const used = new Map();
  for (const n of notes) { let t = n.props.title; used.set(t, (used.get(t) || 0) + 1); if (used.get(t) > 1) t += ' (' + used.get(t) + ')'; name.set(n.key, t); }
  const seen = new Set(); const links = [];
  for (const e of g.edges) {
    if (!name.has(e.from) || !name.has(e.to) || e.from === e.to) continue;
    const id = [e.from, e.to].sort().join('|'); if (seen.has(id)) continue; seen.add(id);
    links.push([e.from, e.to]);
  }
  links.sort((x, y) => (name.get(x[0]) + name.get(x[1])).localeCompare(name.get(y[0]) + name.get(y[1])));
  pairs[b] = links.map(([a, c]) => ({ a, b: c, label: name.get(a) + ' -> ' + name.get(c) })); total += links.length;
  md += `\n## Board "${b.replace('module:', '')}" (${notes.length} notes, ${links.length} links)\n\n### Notes\n\n`;
  for (const n of notes) md += `- **${name.get(n.key)}**: ${(n.props.text || '').replace(/\s+/g, ' ').slice(0, 400)}\n`;
  md += `\n### Links (the first uses the second)\n\n`;
  links.forEach(([a, c], i) => { md += `${i + 1}. ${name.get(a)} -> ${name.get(c)}\n`; });
}
fs.writeFileSync(new URL('./judge/boards.md', import.meta.url), md);
fs.writeFileSync(new URL('./judge/pairs.json', import.meta.url), JSON.stringify(pairs, null, 1));
console.log('links', total, Object.fromEntries(Object.entries(pairs).map(([k, v]) => [k, v.length])), 'chars', md.length);
