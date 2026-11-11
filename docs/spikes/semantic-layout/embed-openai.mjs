// Embeds data/texts.json, the texts embed.swift embeds (each note's title, doc comment and declarations), with OpenAI's embedding models,
// and keeps the vectors as half floats so drawing again needs no key: data/emb-openai-3-large.f16 and data/emb-openai-3-small.f16, one
// vector after another (little-endian), in the order of the keys in the .json beside each, which also names the model, its dimensions,
// the tokens it read and a hash of the texts. sim.mjs's readVectors reads them (EMB=openai-3-large).
// The key is OPENAI_API_KEY, else the file OPENAI_KEY_FILE names; it is never printed, and errors are scrubbed of it. Needs node 24
// (Float16Array).
//   node embed-openai.mjs [large] [small]
import fs from 'fs';
import { textsHash } from './sim.mjs';
const here = (p) => new URL(p, import.meta.url);
const MODELS = { large: 'text-embedding-3-large', small: 'text-embedding-3-small' };
const which = process.argv.slice(2).length ? process.argv.slice(2) : ['large', 'small'];
const key = (process.env.OPENAI_API_KEY || (process.env.OPENAI_KEY_FILE ? fs.readFileSync(process.env.OPENAI_KEY_FILE, 'utf8') : '')).trim();
if (!key) { console.error('embed-openai: set OPENAI_API_KEY, or OPENAI_KEY_FILE to a file that holds it'); process.exit(2); }
const scrub = (s) => String(s).split(key).join('[key]').replace(/sk-[A-Za-z0-9_*.-]{6,}/g, 'sk-[redacted]');
const texts = JSON.parse(fs.readFileSync(here('./data/texts.json'), 'utf8'));
const BATCH = 128;

async function ask(model, input) {
  for (let attempt = 0; ; attempt++) {
    let r;
    try {
      r = await fetch('https://api.openai.com/v1/embeddings', {
        method: 'POST',
        headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
        body: JSON.stringify({ model, input, encoding_format: 'float' }),
      });
    } catch (e) {
      if (attempt < 5) { await new Promise((res) => setTimeout(res, 1000 * 2 ** attempt)); continue; }
      throw new Error(scrub(e.message));
    }
    if (r.ok) return r.json();
    const body = scrub(await r.text());
    if ((r.status === 429 || r.status >= 500) && attempt < 5) { await new Promise((res) => setTimeout(res, 1000 * 2 ** attempt)); continue; }
    throw new Error(`OpenAI answered ${r.status}: ${body.slice(0, 400)}`);
  }
}

for (const w of which) {
  const model = MODELS[w];
  if (!model) { console.error(`embed-openai: no model "${w}" (large, small)`); process.exit(2); }
  const t0 = Date.now();
  let dims = 0, tokens = 0, requests = 0, answered = null, rows = [];
  for (let i = 0; i < texts.length; i += BATCH) {
    const chunk = texts.slice(i, i + BATCH);
    const res = await ask(model, chunk.map((t) => t.text));
    requests++; tokens += res.usage?.prompt_tokens || 0; answered = res.model || model;
    const got = [...res.data].sort((a, b) => a.index - b.index);
    if (got.length !== chunk.length) throw new Error(`${model}: asked ${chunk.length} texts, got ${got.length} vectors`);
    for (const d of got) { dims = d.embedding.length; rows.push(d.embedding); }
  }
  const half = new Float16Array(texts.length * dims);
  rows.forEach((v, j) => { if (v.length !== dims) throw new Error(`${model}: vectors of ${v.length} and ${dims} numbers`); half.set(v, j * dims); });
  const name = `openai-3-${w}`;
  fs.writeFileSync(here(`./data/emb-${name}.f16`), Buffer.from(half.buffer));
  fs.writeFileSync(here(`./data/emb-${name}.json`), JSON.stringify({ model: answered, dimensions: dims, tokens, texts: textsHash(texts), keys: texts.map((t) => t.key) }) + '\n');
  console.log(`${name}: ${texts.length} texts embedded by ${answered}, ${dims} numbers each, ${tokens} tokens in ${requests} requests, ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}
