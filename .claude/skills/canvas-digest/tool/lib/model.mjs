// The graph document, read into a model: nodes, the board and frames each is on, edges, boards. The tool reads a node's key, its `in`, its kind
// (by what `canvas kinds` says of it) and its `layout`; it never looks inside `props`.
import { byTitle } from './util.mjs';
import { dial } from './dial.mjs';

const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/**
 * Of what the app says of its kinds (`canvas kinds`'s answer, a list), what the tool reads, in the answer's own shape: each kind's name, whether
 * a document can draw it (`drawable`, and `why` not), what its shapes hold (`holds`: `shapes`, on the board they're on; `board`, a board of their
 * own) and the pills that can stand for one (`via`). The rest is the app's alone. `extract kinds` prints it, and the tool's tests read a copy
 * (test/fixtures/kinds.json) that DigestTests holds to the app's answer.
 */
export function kindsRead(list) {
  if (!Array.isArray(list)) throw new Error("the app's kinds (canvas kinds) are needed: the driver gives them, as --kinds");
  return list.filter((k) => k && typeof k.kind === 'string').map((k) => {
    const out = { kind: k.kind, drawable: k.drawable !== false };
    if (k.drawable === false && typeof k.why === 'string') out.why = k.why;
    if (k.holds === 'shapes' || k.holds === 'board') out.holds = k.holds;
    const via = (Array.isArray(k.via) ? k.via : []).filter((v) => v && typeof v.kind === 'string').map((v) => ({ kind: v.kind }));
    if (via.length) out.via = via;
    return out;
  });
}

/** The app's kinds as the tool reads them (`kindsRead`), by name. The tool knows no kind by its name: it lays a node out by what its kind holds. */
export function kindsTable(list) {
  const table = new Map();
  for (const k of kindsRead(list)) table.set(k.kind, { kind: k.kind, drawable: k.drawable, why: k.why || null, holds: k.holds || null, via: k.via || [] });
  return table;
}

/** Whether a node holds shapes on the board it is on (its kind's, as `canvas kinds` says). */
export const holdsShapes = (n) => n.holds === 'shapes';
/** Whether a node holds a board of its own. */
export const holdsBoard = (n) => n.holds === 'board';

/** The pill an edge to a node goes through, when it goes through one: the first that can stand for the node's kind (`canvas kinds`' via); null for none. */
export const pillFor = (model, n) => model.kinds.get(n.kind).via[0] || null;

const keyOf = (v) => (typeof v === 'string' ? v : JSON.stringify(v));
const hint = (what, bad) => `${what} is ${bad}`;

/**
 * The document's structure, every refusal found, naming keys: a document with nodes (and edges), a key that is a non-empty string and unique, a kind
 * the app can draw, an `in` that names a node whose kind holds shapes or a board and does not lead back to the node, edges whose ends name nodes,
 * and the layout hints the tool itself reads (`rank`, `public`, `weight`, `direct`, the dial). What the app refuses of a value, it says.
 */
export function readGraph(graph, kinds) {
  const errors = [];
  if (!isPlain(graph)) return { errors: ['the document is a JSON object with nodes'], nodes: [], index: new Map() };
  const raw = Array.isArray(graph.nodes) ? graph.nodes : null;
  if (!raw) errors.push('nodes is a list');
  if (graph.edges != null && !Array.isArray(graph.edges)) errors.push('edges is a list');
  if (typeof graph.drawing !== 'string' || !graph.drawing.trim()) errors.push('drawing is the drawing\'s name, a non-empty string');
  const lay = graph.layout;
  if (lay != null && !isPlain(lay)) errors.push('layout is an object');
  else if (lay) {
    if (lay.mess != null && !(typeof lay.mess === 'number' && lay.mess >= 0 && lay.mess <= 1)) errors.push(`layout.mess is a number from 0 to 1, not ${JSON.stringify(lay.mess)}`);
    if (lay.ranks != null && !['rows', 'columns'].includes(lay.ranks)) errors.push(`layout.ranks is rows or columns (left out: whichever the view shows larger), not ${JSON.stringify(lay.ranks)}`);
    if (lay.promote != null && typeof lay.promote !== 'boolean') errors.push(`layout.promote is true or false, not ${JSON.stringify(lay.promote)}`);
  }
  const nodes = [], index = new Map();
  (raw || []).forEach((n, i) => {
    if (!isPlain(n)) { errors.push(`nodes[${i}] is an object`); return; }
    if (typeof n.key !== 'string' || !n.key) { errors.push(`nodes[${i}] has no key (a non-empty string)`); return; }
    if (index.has(n.key)) { errors.push(`two nodes have the key "${n.key}" (nodes[${index.get(n.key).index}] and nodes[${i}])`); return; }
    const item = { key: n.key, raw: n, index: i };
    index.set(n.key, item);
    nodes.push(item);
    if (typeof n.kind !== 'string' || !n.kind) { errors.push(`"${n.key}" has no kind`); return; }
    const k = kinds.get(n.kind);
    if (!k) errors.push(`"${n.key}": the app has no kind ${n.kind} (canvas kinds lists ${[...kinds.keys()].sort().join(', ')})`);
    else if (!k.drawable) errors.push(`"${n.key}": a document can't draw the kind ${n.kind}${k.why ? `: ${k.why}` : ''} (canvas kinds)`);
    else if (k.holds === 'board' && n.key === 'root') errors.push('"root" names the drawing\'s own board in the layout: give the node that holds a board another key');
    const l = n.layout;
    if (l != null && !isPlain(l)) errors.push(`"${n.key}": layout is an object`);
    else if (l) {
      if (l.rank != null && !(typeof l.rank === 'number' && isFinite(l.rank))) errors.push(`"${n.key}": layout.rank is a number, not ${JSON.stringify(l.rank)}`);
      if (l.public != null && typeof l.public !== 'boolean') errors.push(`"${n.key}": layout.public is true or false, not ${JSON.stringify(l.public)}`);
    }
  });
  // what holds each node
  for (const it of nodes) {
    const ref = it.raw.in;
    if (ref == null) continue;
    const holder = typeof ref === 'string' ? index.get(ref) : null;
    if (!holder) { errors.push(`"${it.key}" is in ${keyOf(ref)}, which is not a node's key`); continue; }
    const k = kinds.get(holder.raw.kind);
    if (k && !k.holds) errors.push(`"${it.key}" is in "${holder.key}", and the kind ${holder.raw.kind} holds no shapes or board (canvas kinds)`);
    it.parent = holder;
  }
  // `in` must lead to the top: a shape inside itself, or two inside each other, has no board to be on
  const ringed = new Set();
  for (const it of nodes) {
    if (!it.parent || ringed.has(it.key)) continue;
    const chain = [it];
    for (let p = it.parent; p; p = p.parent) {
      const seen = chain.indexOf(p);
      if (seen >= 0) {
        const ring = chain.slice(seen).concat([p]);
        for (const r of ring) ringed.add(r.key);
        errors.push(ring.length === 2 ? `"${p.key}" is in itself` : `"in" runs in a circle: ${ring.map((r) => `"${r.key}"`).join(' is in ')}; a shape cannot be inside itself`);
        break;
      }
      if (ringed.has(p.key)) break;
      chain.push(p);
    }
  }
  (Array.isArray(graph.edges) ? graph.edges : []).forEach((e, i) => {
    if (!isPlain(e)) { errors.push(`edges[${i}] is an object`); return; }
    for (const end of ['from', 'to']) {
      if (typeof e[end] !== 'string' || !e[end]) errors.push(`edges[${i}]: ${end} is the key of a node, not ${JSON.stringify(e[end])}`);
      else if (!index.has(e[end])) errors.push(`edges[${i}] ${keyOf(e.from)} -> ${keyOf(e.to)}: ${end} "${e[end]}" is not a node's key`);
    }
    const l = e.layout;
    if (l != null && !isPlain(l)) errors.push(`edges[${i}]: layout is an object`);
    else if (l) {
      if (l.weight != null && !(typeof l.weight === 'number' && isFinite(l.weight))) errors.push(`edges[${i}]: layout.weight is a number, not ${JSON.stringify(l.weight)}`);
      if (l.direct != null && typeof l.direct !== 'boolean') errors.push(`edges[${i}]: layout.direct is true or false, not ${JSON.stringify(l.direct)}`);
    }
  });
  return { errors, nodes, index, cyclic: ringed.size > 0 };
}

const hints = (x) => (x && isPlain(x.layout) ? x.layout : {});   // a node's or an edge's layout hints

/**
 * The model of a document over the app's kinds. `opts.refused` is the app's own refusals of edges (measure's `edges`: a Map from an edge's place in
 * the list to {reason, message, hint}); those, and the edges the layout has no way to draw, are left out, each with a warning in `model.warnings`.
 * Throws the first refusal of `readGraph`, or of a pill the layout is told to make where none can stand.
 */
export function buildModel(graph, mess, kinds, opts = {}) {
  const warnings = [];
  const table = kinds instanceof Map ? kinds : kindsTable(kinds);
  const read = readGraph(graph, table);
  if (read.errors.length) throw new Error(read.errors[0]);
  const layoutOpts = graph.layout || {};
  const nodes = new Map();
  const sorted = read.nodes.slice().sort((x, y) => byTitle(x.key, y.key));
  for (const it of sorted) {
    const n = it.raw, k = table.get(n.kind);
    const rank = hints(n).rank, pub = hints(n).public;
    nodes.set(it.key, {
      key: it.key, index: it.index, kind: n.kind, holds: k.holds, parent: it.parent ? it.parent.key : null, children: [],
      chain: [], pin: pub === true, never: pub === false || !k.via.length, rank: typeof rank === 'number' ? rank : null,
    });
  }
  for (const it of read.nodes) {
    const chain = [];
    for (let p = it.parent; p; p = p.parent) chain.unshift(p.key);
    nodes.get(it.key).chain = chain;
  }
  for (const n of nodes.values()) if (n.parent) nodes.get(n.parent).children.push(n.key);
  for (const n of nodes.values()) {
    if (n.pin && holdsShapes(n)) throw new Error(`"${n.key}" holds shapes, and the layout never makes one public: it draws edges at one only as arrows on one board`);
    if (n.pin && !table.get(n.kind).via.length) throw new Error(`"${n.key}" is public: true, and no pill can stand for the kind ${n.kind} (canvas kinds)`);
  }
  // which board, which frames, which container
  const place = (n) => {
    if (n.board) return;
    if (!n.parent) { n.board = 'root'; n.frames = []; n.container = 'b:root'; return; }
    const p = nodes.get(n.parent);
    place(p);
    if (holdsBoard(p)) { n.board = p.key; n.frames = []; n.container = 'b:' + p.key; }
    else { n.board = p.board; n.frames = p.frames.concat([p.key]); n.container = 'f:' + p.key; }
  };
  for (const n of nodes.values()) place(n);
  // boards: root first, then subboards by depth, then key
  const boardDepth = new Map([['root', 0]]);
  const subs = [...nodes.values()].filter(holdsBoard);
  const depth = (s) => (s.board === 'root' ? 1 : 1 + depth(nodes.get(s.board)));
  for (const s of subs) boardDepth.set(s.key, depth(s));
  const boards = ['root'].concat(subs.map((s) => s.key).sort((a, b) => boardDepth.get(a) - boardDepth.get(b) || byTitle(a, b)));
  const kids = new Map();
  for (const b of boards) kids.set('b:' + b, []);
  for (const n of nodes.values()) if (holdsShapes(n)) kids.set('f:' + n.key, []);
  for (const n of nodes.values()) kids.get(n.container).push(n.key);
  for (const v of kids.values()) v.sort(byTitle);
  // edges: the ones between a pair are one edge to the layout (their weights added); `items` are the document's edges it stands for
  const pairs = new Map(), dropped = new Set();
  const refused = opts.refused || new Map();
  (Array.isArray(graph.edges) ? graph.edges : []).forEach((e, index) => {
    const a = nodes.get(e.from), b = nodes.get(e.to);
    if (a === b) return;
    const no = refused.get(index);
    const why = no ? `the app refuses it: ${no.message}${no.hint ? ` (${no.hint})` : ''}` : edgeRefusal(a, b, table);
    if (why) { warnings.push(`edge "${e.from}" -> "${e.to}" left out: ${why}`); dropped.add(index); return; }
    const key = e.from + '\u0000' + e.to;
    let g = pairs.get(key);
    if (!g) pairs.set(key, g = { from: e.from, to: e.to, a, b, items: [] });
    const w = hints(e).weight;
    g.items.push({ index, w: w == null ? 1 : w, direct: hints(e).direct === true });
  });
  const edges = [...pairs.values()].map((g) => ({
    from: g.from, to: g.to, weight: g.items.reduce((s, i) => s + i.w, 0), direct: g.items.some((i) => i.direct) || holdsShapes(g.a) || holdsShapes(g.b),
    cross: g.a.board !== g.b.board, items: g.items.map((i) => i.index).sort((x, y) => x - y),
  })).sort((x, y) => byTitle(x.from, y.from) || byTitle(x.to, y.to));
  const out = new Map(), inn = new Map(), has = new Set();
  for (const e of edges) {
    if (!out.has(e.from)) out.set(e.from, []);
    if (!inn.has(e.to)) inn.set(e.to, []);
    out.get(e.from).push(e); inn.get(e.to).push(e);
    has.add(e.from + '\u0000' + e.to);
  }
  // the mess dial (the option, else the document's layout.mess, else 0.1) sets the price of a pill and the rest
  const dl = dial(mess != null ? mess : layoutOpts.mess);
  const model = {
    drawing: graph.drawing, layout: layoutOpts, nodes, boards, boardDepth, kids, edges, out, inn, warnings, dropped, kinds: table,
    mu: dl.mu, dial: dl, promote: layoutOpts.promote !== false, ranks: layoutOpts.ranks || null,
    hasEdge: (a, b) => has.has(a + '\u0000' + b),
    node: (t) => nodes.get(t),
    boardIndex: new Map(boards.map((b, i) => [b, i])),
  };
  // what is public no matter the loop: pinned, or the end of an edge that crosses boards
  model.forcedPublic = new Set();
  model.publicWhy = new Map();   // key -> why it is public, for the report
  for (const e of edges) if (e.cross) { model.forcedPublic.add(e.to); if (!model.publicWhy.has(e.to)) model.publicWhy.set(e.to, 'an edge from another board points at it'); }
  for (const n of nodes.values()) if (n.pin) { model.forcedPublic.add(n.key); model.publicWhy.set(n.key, 'layout.public in the document'); }
  for (const t of model.forcedPublic) if (hints(graph.nodes[nodes.get(t).index]).public === false) throw new Error(`"${t}" is layout.public: false, but an edge reaches it through a pill`);
  return model;
}

/** Why the layout draws no edge from a to b, from what it can do itself (the app's own refusals come from measure); null where it draws one. */
function edgeRefusal(a, b, table) {
  if (a.board === b.board) return null;
  // an edge between boards goes through a pill for its far end, beside the near one: none beside or for a shape that holds shapes, and none for a kind no pill stands for
  if (holdsShapes(a) || holdsShapes(b)) return 'the layout draws an edge at a shape that holds shapes only as an arrow on one board, never through a pill';
  if (!table.get(b.kind).via.length) return `no pill can stand for the kind ${b.kind} (canvas kinds), and this edge goes through one`;
  return null;
}

/** The leaf shapes on a board: those that hold no shapes on it (notes, and cards, whose own board is apart). */
export function leavesOn(model, board) {
  return [...model.nodes.values()].filter((n) => n.board === board && !holdsShapes(n));
}
