// Writes data/texts.json: [{key, text}] for every note and frame, the words an embedding reads.
// A note's title, then its text, with code names split into words (AdornmentLabel -> Adornment Label).
import fs from 'fs';
const g = JSON.parse(fs.readFileSync(new URL('./data/graph.json', import.meta.url)));
const split = (s) => s.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2').replace(/[`_]/g, ' ');
const out = [];
for (const n of g.nodes) {
  
  const p = n.props || {};
  const title = (p.title || '').replace(/\.swift$/, '');
  const body = (p.text || p.description || '').slice(0, 900);
  out.push({ key: n.key, text: split(title + '. ' + body).replace(/\s+/g, ' ').trim() });
}
fs.writeFileSync(new URL('./data/texts.json', import.meta.url), JSON.stringify(out));
console.log(out.length, 'texts; e.g.', out[100].text.slice(0, 200));
