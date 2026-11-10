// Similarity between two notes from their vectors: centered on the corpus mean, then cosine. Models: sentence, contextual, tfidf.
import fs from 'fs';
const here = (p) => new URL(p, import.meta.url);
function unit(v) { let s = 0; for (const x of v) s += x * x; s = Math.sqrt(s) || 1; return v.map((x) => x / s); }
function centered(vecs) {
  const keys = Object.keys(vecs).sort(); const d = vecs[keys[0]].length; const mean = new Array(d).fill(0);
  for (const k of keys) for (let i = 0; i < d; i++) mean[i] += vecs[k][i] / keys.length;
  const out = {}; for (const k of keys) out[k] = unit(vecs[k].map((x, i) => x - mean[i])); return out;
}
const STOP = new Set('a an the and or of to in on for by with is are be as it its at from that this what which into each one when where how not no but than then so their they them a s t'.split(' '));
function tfidf() {
  const texts = JSON.parse(fs.readFileSync(here('./data/texts.json')));
  const docs = texts.map((t) => t.text.toLowerCase().match(/[a-z][a-z0-9]+/g)?.filter((w) => !STOP.has(w) && w.length > 2) || []);
  const df = new Map(); for (const d of docs) for (const w of new Set(d)) df.set(w, (df.get(w) || 0) + 1);
  const n = docs.length; const vocab = [...df.keys()].sort(); const idx = new Map(vocab.map((w, i) => [w, i]));
  const out = {};
  texts.forEach((t, j) => {
    const tf = new Map(); for (const w of docs[j]) tf.set(w, (tf.get(w) || 0) + 1);
    const v = new Map(); let s = 0;
    for (const [w, c] of tf) { const x = (1 + Math.log(c)) * Math.log(n / df.get(w)); v.set(idx.get(w), x); s += x * x; }
    s = Math.sqrt(s) || 1; for (const [i, x] of v) v.set(i, x / s); out[t.key] = v;
  });
  return out;
}
export function loadSim(model) {
  if (model === 'tfidf') {
    const V = tfidf();
    return (a, b) => { const x = V[a], y = V[b]; if (!x || !y) return 0; let s = 0; const [p, q] = x.size < y.size ? [x, y] : [y, x]; for (const [i, w] of p) { const u = q.get(i); if (u) s += w * u; } return s; };
  }
  const V = centered(JSON.parse(fs.readFileSync(here('./data/vec-' + model + '.json'))));
  return (a, b) => { const x = V[a], y = V[b]; if (!x || !y) return 0; let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * y[i]; return s; };
}
