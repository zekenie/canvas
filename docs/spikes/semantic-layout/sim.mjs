// Similarity between two notes from their vectors: centered on the corpus mean, then cosine. Models: sentence and contextual (Apple's
// NaturalLanguage, on this Mac: embed.swift), openai-3-small and openai-3-large (OpenAI's text-embedding-3 models: embed-openai.mjs), tfidf.
// EMB is the embedding every script uses where it says "the embedding": Apple's contextual unless EMB names another.
import fs from 'fs';
import crypto from 'crypto';
const here = (p) => new URL(p, import.meta.url);
export const EMB = process.env.EMB || 'contextual';
// what the vectors were made from: every note's key and text
export const textsHash = (texts) => crypto.createHash('sha256').update(texts.map((t) => t.key + '\u0000' + t.text).join('\u0001')).digest('hex');
// The vectors of one embedding by note key: data/vec-<name>.json (embed.swift's), or data/emb-<name>.f16 with its keys in data/emb-<name>.json
// (embed-openai.mjs's, half floats one vector after another), refused if the texts have changed since.
export function readVectors(name) {
  const json = here('./data/vec-' + name + '.json');
  if (fs.existsSync(json)) return JSON.parse(fs.readFileSync(json, 'utf8'));
  if (!fs.existsSync(here('./data/emb-' + name + '.json'))) throw new Error(`no vectors for ${name}: data/vec-${name}.json or data/emb-${name}.f16`);
  const meta = JSON.parse(fs.readFileSync(here('./data/emb-' + name + '.json'), 'utf8')), buf = fs.readFileSync(here('./data/emb-' + name + '.f16'));
  const texts = JSON.parse(fs.readFileSync(here('./data/texts.json'), 'utf8'));
  if (meta.texts !== textsHash(texts)) throw new Error(`data/emb-${name}: the texts changed since they were embedded; ASK_OPENAI=1 embeds them again`);
  const d = meta.dimensions, out = {};
  if (buf.length !== meta.keys.length * d * 2) throw new Error(`data/emb-${name}.f16: ${buf.length} bytes for ${meta.keys.length} vectors of ${d}`);
  meta.keys.forEach((k, j) => { const v = new Array(d); for (let i = 0; i < d; i++) v[i] = HALF[buf.readUInt16LE(2 * (j * d + i))]; out[k] = v; });
  return out;
}
// every half float's value (sign, 5 exponent bits, 10 of mantissa)
const HALF = new Float64Array(65536);
for (let h = 0; h < 65536; h++) { const s = h & 0x8000 ? -1 : 1, e = (h >> 10) & 31, m = h & 1023; HALF[h] = e === 0 ? s * m * 2 ** -24 : e === 31 ? (m ? NaN : s * Infinity) : s * (1024 + m) * 2 ** (e - 25); }
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
  const V = centered(readVectors(model));
  return (a, b) => { const x = V[a], y = V[b]; if (!x || !y) return 0; let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * y[i]; return s; };
}
