// Asks Jev (TypeSafe's yes-or-no model, the app's decision model) the judges' question about every link inside a board: do its two notes
// form one idea, so it should be an arrow that keeps them side by side, or is it incidental, so a chip will do? Each answer is a
// probability of yes. The links are the pairs background.mjs simulates (both directions of a pair are one link; frames left out).
// Variants (--variant), each its own file of answers, data/jev-<variant>.json, {model, asked, scores: {"<a>|<b>": p}}:
//  - pair: one request a link, its state the board's name, the two notes' titles and text (the judges' 400 characters) and which uses
//    which: what the judges read of a link, without the rest of the board;
//  - roles: pair, plus each note's type from the lens (file, plugin, extension point, kind, property, module) and the link's relationship
//    where the lens gave one ("declares", "fills", "holds"...);
//  - board: one request a board (at most 150 questions a request), its state every note and link on it, as the judges read it, and one
//    question a link;
//  - boardroles: board, with roles' types and relationships;
//  - levels: board, but the judges' three labels asked as two questions a link: is it more than incidental (related or one idea, against
//    incidental), and are its notes one idea (against merely related or incidental); its score the mean of the two answers' logits,
//    the two answers kept beside it (more, one).
// Every request and answer is kept in out/jev-cache.jsonl by a hash of the request, so a run asks only what it hasn't, and --offline
// asks nothing. The key is TYPESAFE_API_KEY, else its export line in ~/.zshrc, else the app's key file; it is never printed or written.
//   DIGEST_TOOL=... node jev.mjs --variant=pair|roles|board|boardroles [--boards=module:A,...] [--workers=8] [--dry=1] [--offline=1]
import fs from 'fs';
import os from 'os';
import crypto from 'crypto';
const TOOL = (process.env.DIGEST_TOOL || (() => { throw new Error('set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)'); })()).replace(/\/$/, '') + '/lib/';
const { buildModel } = await import(TOOL + 'model.mjs');
const { refusedEdges } = await import(TOOL + 'sizes.mjs');

const args = Object.fromEntries(process.argv.slice(2).map((a) => a.replace(/^--/, '').split('=')));
const VARIANT = args.variant || 'pair';
if (!['pair', 'roles', 'board', 'boardroles', 'levels'].includes(VARIANT)) throw new Error('--variant is pair, roles, board, boardroles or levels');
const ROLES = VARIANT === 'roles' || VARIANT === 'boardroles', BOARD = VARIANT !== 'pair' && VARIANT !== 'roles', LEVELS = VARIANT === 'levels';
const WORKERS = +(args.workers || 8);
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const graph = rd('./data/graph.json'), measure = rd('./data/measure.json'), kinds = rd('./data/kinds.json');
const model = buildModel(graph, kinds, { refused: refusedEdges(measure) });
const node = (k) => model.node(k);
const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const SEP = '\u0000';
const G = new Map(graph.nodes.map((n) => [n.key, n]));
const roleOf = new Map(); for (const e of graph.edges) { const is = e.props?.is?.[0]; if (is) roleOf.set(e.from + SEP + e.to, is.replace(/^type:/, '')); }

// ---- the links: as background.mjs makes them ----
const pairsOn = new Map();
for (const e of model.edges) {
  const a = node(e.from), b = node(e.to);
  if (!a || !b || e.from === e.to || a.board !== b.board || a.holds === 'shapes' || b.holds === 'shapes') continue;
  const [x, y] = [e.from, e.to].sort(byKey), pk = x + SEP + y;
  if (!pairsOn.has(a.board)) pairsOn.set(a.board, new Map());
  const M = pairsOn.get(a.board);
  if (!M.has(pk)) M.set(pk, { key: pk, a: x, b: y, board: a.board, dirs: new Set() });
  M.get(pk).dirs.add(e.from + SEP + e.to);
}
const only = args.boards ? new Set(args.boards.split(',')) : null;
const boards = [...pairsOn.keys()].sort(byKey).filter((b) => !only || only.has(b));

// ---- what a note says: its title and the judges' 400 characters; its type from the lens ----
const titleOf = (k) => G.get(k)?.props?.title || k.replace(/^[a-z-]+:/, '');
const textOf = (k) => { const p = G.get(k)?.props || {}; return (p.text || p.description || '').replace(/\s+/g, ' ').trim().slice(0, 400); };
const typeOf = (k) => { const n = G.get(k); if (n?.kind === 'subboard') return 'module'; const t = n?.props?.is?.[0]; return t ? t.replace(/^type:/, '').toLowerCase() : 'note'; };
const boardName = (b) => (b === 'root' ? 'the codebase' : titleOf(b));
// a board's names for its notes, one each (a second note of a title gets " (2)", as the judges' boards did)
const namesOn = (b) => { const used = new Map(), name = new Map(); for (const k of [...new Set([...pairsOn.get(b).values()].flatMap((p) => [p.a, p.b]))].sort(byKey)) { let t = titleOf(k); used.set(t, (used.get(t) || 0) + 1); if (used.get(t) > 1) t += ` (${used.get(t)})`; name.set(k, t); } return name; };
const said = (p, name) => { // which uses which, in words
  const ab = p.dirs.has(p.a + SEP + p.b), ba = p.dirs.has(p.b + SEP + p.a);
  const [f, t] = ab ? [p.a, p.b] : [p.b, p.a];
  const role = ROLES ? (roleOf.get(f + SEP + t) || roleOf.get(t + SEP + f)) : null;
  return { first: f, second: t, words: ab && ba ? `${name.get(f)} and ${name.get(t)} use each other` : `${name.get(f)} uses ${name.get(t)}${role ? ` (it ${role} it)` : ''}` };
};
const noteState = (k, name) => ({ title: name.get(k), ...(ROLES ? { type: typeOf(k) } : {}), text: textOf(k) });

const PREFACE = 'A board draws part of a Swift codebase as sticky notes: one note per source file, extension point or plugin (or one card per module), its text the doc comment and declarations. A link between two notes is drawn either as an arrow, which puts the two notes next to each other, or as a small reference chip naming the other note, which lets the two sit far apart. Drawing every link as an arrow turns the board into a ball of mud, so arrows go where the two notes form one idea or feature, and chips go on links that are incidental: plumbing, a utility, a registration or plugin list, a style constant, a shared helper.';
const ASK = (words) => `The link: ${words}. Do these two notes form one idea, so this link should be an arrow that keeps them side by side?`;
const YES = 'One idea: draw the arrow', NO = 'Incidental: use a chip';
const question = (words) => ({ type: 'noul', instructions: PREFACE + '\n' + ASK(words), criteria: { true: YES, false: NO } });
const ASK_MORE = (words) => `The link: ${words}. Is this link more than incidental: are the two notes related, or one idea?`;
const ASK_ONE = (words) => `The link: ${words}. Do these two notes form one idea or feature, more than merely being related?`;
const levels = (words) => [
  { type: 'noul', instructions: PREFACE + '\n' + ASK_MORE(words), criteria: { true: 'Related or one idea', false: 'Incidental: a chip is better' } },
  { type: 'noul', instructions: PREFACE + '\n' + ASK_ONE(words), criteria: { true: 'One idea: draw the arrow', false: 'Merely related, or incidental' } },
];

// ---- the requests ----
const jobs = []; // {body, links: [[qid, pairKey]]}
for (const b of boards) {
  const name = namesOn(b), ps = [...pairsOn.get(b).values()].sort((x, y) => byKey(x.key, y.key));
  if (BOARD) {
    const ks = [...name.keys()];
    const state = { board: boardName(b), notes: ks.map((k) => noteState(k, name)), links: ps.map((p) => said(p, name).words) };
    // at most 150 questions a request (Jev refuses the root's 359 at once as too many tokens), each with the whole board as its state
    const parts = Math.ceil(ps.length / (LEVELS ? 75 : 150)), per = Math.ceil(ps.length / parts);
    for (let c = 0; c < parts; c++) {
      const qs = {}, links = [];
      ps.slice(c * per, (c + 1) * per).forEach((p, i) => {
        const id = 'l' + (c * per + i + 1), w = said(p, name).words;
        if (LEVELS) { const [m, o] = levels(w); qs[id + 'm'] = m; qs[id + 'o'] = o; } else qs[id] = question(w);
        links.push([id, p.key]);
      });
      jobs.push({ body: { state, model: 'jev-latest', questions: qs }, links });
    }
  } else {
    for (const p of ps) {
      const s = said(p, name);
      const state = { board: boardName(b), link: s.words, first: noteState(s.first, name), second: noteState(s.second, name) };
      jobs.push({ body: { state, model: 'jev-latest', questions: { link: question(s.words) } }, links: [['link', p.key]] });
    }
  }
}
const nq = jobs.reduce((s, j) => s + j.links.length, 0);
if (args.dry) { console.log(JSON.stringify(jobs[+(args.dry) - 1 || 0].body, null, 1)); console.error(`${jobs.length} requests, ${nq} questions, ${Math.round(jobs.reduce((s, j) => s + JSON.stringify(j.body).length, 0) / 1000)}k characters`); process.exit(0); }

// ---- asking, through the cache ----
const CACHE = new URL('./out/jev-cache.jsonl', import.meta.url);
fs.mkdirSync(new URL('./out/', import.meta.url), { recursive: true });
const cache = new Map();
if (fs.existsSync(CACHE)) for (const l of fs.readFileSync(CACHE, 'utf8').split('\n')) if (l) { const o = JSON.parse(l); cache.set(o.hash, o.response); }
const hashOf = (body) => crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex');
function key() {
  if (process.env.TYPESAFE_API_KEY) return process.env.TYPESAFE_API_KEY.trim();
  try { for (const l of fs.readFileSync(os.homedir() + '/.zshrc', 'utf8').split('\n')) { const m = l.match(/^\s*export\s+TYPESAFE_API_KEY=['"]?([^'"\s]+)/); if (m) return m[1]; } } catch {}
  try { const k = fs.readFileSync(os.homedir() + '/Library/Application Support/InfiniteCanvas/typesafe-api-key', 'utf8').trim(); if (k) return k; } catch {}
  throw new Error('no TypeSafe key');
}
const todo = jobs.filter((j) => !cache.has(hashOf(j.body)));
let K = null, failures = 0, tokens = 0, asked = 0;
const scrub = (s) => (K ? String(s).split(K).join('…') : String(s));
async function ask(body) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const t = Date.now();
    try {
      const r = await fetch('https://api.typesafe.ai/v1/systemone', { method: 'POST', headers: { authorization: 'Bearer ' + K, 'content-type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(120000) });
      const text = await r.text();
      if (r.status === 429 || r.status >= 500) { await new Promise((ok) => setTimeout(ok, 2000 * (attempt + 1))); continue; }
      if (!r.ok) return { error: `HTTP ${r.status}: ${scrub(text.slice(0, 300))}`, seconds: (Date.now() - t) / 1000 };
      return { ...JSON.parse(text), seconds: (Date.now() - t) / 1000 };
    } catch (e) { if (attempt === 4) return { error: scrub(e.message) }; await new Promise((ok) => setTimeout(ok, 2000 * (attempt + 1))); }
  }
  return { error: 'gave up after 5 tries' };
}
if (todo.length && !args.offline) {
  K = key();
  const out = fs.createWriteStream(CACHE, { flags: 'a' });
  let next = 0; const t0 = Date.now();
  await Promise.all(Array.from({ length: Math.min(WORKERS, todo.length) }, async () => {
    while (next < todo.length) {
      const j = todo[next++], resp = await ask(j.body);
      if (resp.error || !resp.answers) { failures++; if (failures <= 3) console.error('failed:', resp.error || JSON.stringify(resp).slice(0, 200)); continue; }
      const h = hashOf(j.body); cache.set(h, resp); out.write(JSON.stringify({ hash: h, response: resp }) + '\n');
      asked++; tokens += resp.usage?.input_tokens || 0;
      if (asked % 100 === 0) console.error(`  ${asked} of ${todo.length} asked, ${Math.round((Date.now() - t0) / 1000)} s`);
    }
  }));
  out.end(); await new Promise((ok) => out.on('finish', ok));
  console.error(`asked ${asked} requests (${failures} failed) in ${Math.round((Date.now() - t0) / 1000)} s, ${tokens} input tokens`);
}

// ---- the answers ----
const scores = {}, more = {}, one = {}, models = new Set(); let missing = 0, secs = [], used = 0, requests = 0;
const logit = (q) => { const c = Math.min(0.999, Math.max(0.001, q)); return Math.log(c / (1 - c)); };
const ok = (q) => Number.isFinite(q) && q >= 0 && q <= 1;
for (const j of jobs) {
  const resp = cache.get(hashOf(j.body));
  if (!resp) { missing += j.links.length; continue; }
  models.add(resp.model); if (resp.seconds) secs.push(resp.seconds); used += resp.usage?.input_tokens || 0; requests++;
  for (const [qid, pk] of j.links) {
    const k = pk.replace(SEP, '|');
    if (LEVELS) {
      const m = Number(resp.answers?.[qid + 'm']?.noul), o = Number(resp.answers?.[qid + 'o']?.noul);
      if (ok(m) && ok(o)) { more[k] = m; one[k] = o; scores[k] = +(1 / (1 + Math.exp(-(logit(m) + logit(o)) / 2))).toFixed(4); } else missing++;
      continue;
    }
    const p = Number(resp.answers?.[qid]?.noul); if (ok(p)) scores[k] = p; else missing++;
  }
}
const file = new URL(`./data/jev-${VARIANT}${only ? '-some' : ''}.json`, import.meta.url);
fs.writeFileSync(file, JSON.stringify({ model: [...models].sort().join(', '), variant: VARIANT, preface: PREFACE, ...(LEVELS ? { ask: [ASK_MORE('<the link>'), ASK_ONE('<the link>')], more, one } : { ask: ASK('<the link>'), yes: YES, no: NO }), asked: Object.keys(scores).length, scores }, null, 0));
secs.sort((a, b) => a - b);
console.log(`${VARIANT}: ${Object.keys(scores).length} of ${nq} links answered (${missing} not), by ${[...models].join(', ')}, in ${requests} requests, ${used} input tokens; median request ${secs.length ? secs[Math.floor(secs.length / 2)].toFixed(2) : '?'} s; wrote ${file.pathname.split('/').slice(-2).join('/')}`);
