// The digest, read into a model: nodes, the board and frames each is on, edges, boards.
import { byTitle, fold } from './util.mjs';
import { dial } from './dial.mjs';
import { isEndOf, isKey, canon } from './types.mjs';

export const LEAF_KINDS = new Set(['sticky-note', 'subboard']);
const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/** `is` as the digest writes it (a title, or a list of them) as a list of folded titles, without repeats; bad: it is neither. */
function isList(v) {
  if (v == null) return { list: [], bad: false };
  const raw = typeof v === 'string' ? [v] : v;
  if (!Array.isArray(raw) || raw.some((t) => typeof t !== 'string' || !fold(t))) return { list: [], bad: true };
  return { list: [...new Set(raw.map(fold))], bad: false };
}

export function buildModel(digest, mess) {
  const warnings = [];
  const title = fold(digest.title || 'Digest');
  const policy = digest.policy || {};
  if (policy.ranks != null && !['rows', 'columns'].includes(policy.ranks)) throw new Error(`policy.ranks is "rows" or "columns" (left out: whichever the view shows larger), not ${JSON.stringify(policy.ranks)}`);
  const nodes = new Map();
  const sorted = (digest.nodes || []).slice().sort((a, b) => byTitle(fold(a.title), fold(b.title)));
  for (const n of sorted) {
    const t = fold(n.title);
    if (!t) throw new Error('a node has no title');
    if (nodes.has(t)) throw new Error(`duplicate title "${t}"`);
    if (t.length > 80) throw new Error(`"${t}" is over 80 characters`);
    const is = isList(n.is);
    nodes.set(t, {
      title: t, kind: n.kind || 'sticky-note', parent: n.in ? fold(n.in) : null, text: n.text || '',
      pin: n.public === true, never: n.public === false, children: [],
      rank: typeof n.rank === 'number' && isFinite(n.rank) ? n.rank : null,
      // what a note is: a type (it holds a schema), a relationship type, an instance (`is` the types, `fieldValues` its values); check says what is wrong with them
      schemaGiven: n.schema != null, schema: n.schema != null ? n.schema : null,
      relationshipGiven: n.relationship != null && n.relationship !== false, relationshipRaw: n.relationship, relationship: n.relationship === true,
      is: is.list, isBad: is.bad, fieldValuesGiven: n.fieldValues != null, fieldValues: n.fieldValues != null ? n.fieldValues : null,
    });
  }
  for (const n of nodes.values()) {
    if (!n.parent) continue;
    const p = nodes.get(n.parent);
    if (!p) throw new Error(`"${n.title}" is in "${n.parent}", which is not a node`);
    p.children.push(n.title);
  }
  // `in` must lead to the top: a shape inside itself, or two inside each other, has no board to be on
  for (const n of nodes.values()) {
    const chain = [n.title];
    for (let p = n.parent; p; p = nodes.get(p).parent) {
      const at = chain.indexOf(p);
      if (at >= 0) {
        const ring = chain.slice(at).concat([p]);
        throw new Error(ring.length === 2 ? `"${p}" is in itself` : `"in" runs in a circle: ${ring.map((t) => `"${t}"`).join(' is in ')}; a shape cannot be inside itself`);
      }
      chain.push(p);
    }
  }
  // kind: auto is a subboard when its subtree has over 40 leaves or is over two frames deep, else a frame
  const leavesUnder = (n) => (n.children.length ? n.children.reduce((s, c) => s + leavesUnder(nodes.get(c)), 0) : 1);
  const depthUnder = (n) => 1 + Math.max(0, ...n.children.map((c) => depthUnder(nodes.get(c))));
  for (const n of nodes.values()) if (n.kind === 'auto') n.kind = leavesUnder(n) > 40 || depthUnder(n) > 3 ? 'subboard' : 'frame';
  for (const n of nodes.values()) {
    const container = n.kind === 'frame' || n.kind === 'subboard';
    if (!container && n.kind !== 'sticky-note') throw new Error(`"${n.title}": kind ${n.kind} is not supported`);
    if (n.pin && container && n.kind === 'frame') throw new Error(`"${n.title}" is a frame, and a frame is never public`);
    if (n.children.length && !container) throw new Error(`"${n.title}" holds shapes but is a ${n.kind}`);
    if (n.parent && !['frame', 'subboard'].includes(nodes.get(n.parent).kind)) throw new Error(`"${n.title}" is in "${n.parent}", which holds no shapes`);
  }
  // which board, which frames, which container
  const place = (n) => {
    if (n.board) return;
    if (!n.parent) { n.board = 'root'; n.frames = []; n.container = 'b:root'; return; }
    const p = nodes.get(n.parent);
    place(p);
    if (p.kind === 'subboard') { n.board = p.title; n.frames = []; n.container = 'b:' + p.title; }
    else { n.board = p.board; n.frames = p.frames.concat([p.title]); n.container = 'f:' + p.title; }
  };
  for (const n of nodes.values()) place(n);
  // boards: root first, then subboards by depth, then title
  const boardDepth = new Map([['root', 0]]);
  const subs = [...nodes.values()].filter((n) => n.kind === 'subboard');
  const depth = (s) => (s.board === 'root' ? 1 : 1 + depth(nodes.get(s.board)));
  for (const s of subs) boardDepth.set(s.title, depth(s));
  const boards = ['root'].concat(subs.map((s) => s.title).sort((a, b) => boardDepth.get(a) - boardDepth.get(b) || byTitle(a, b)));
  const kids = new Map();
  for (const b of boards) kids.set('b:' + b, []);
  for (const n of nodes.values()) if (n.kind === 'frame') kids.set('f:' + n.title, []);
  for (const n of nodes.values()) kids.get(n.container).push(n.title);
  for (const v of kids.values()) v.sort(byTitle);
  // edges: the ones between a pair are one edge to the layout (their weights added), and each typed one is an arrow of its own when it is drawn
  const pairs = new Map();
  (digest.edges || []).forEach((e, index) => {
    const from = fold(e.from), to = fold(e.to);
    const a = nodes.get(from), b = nodes.get(to);
    if (!a || !b) throw new Error(`edge ${from} -> ${to}: unknown title`);
    if (from === to) return;
    if (a.kind === 'frame' || b.kind === 'frame') { warnings.push(`edge "${from}" -> "${to}" dropped: a frame has no ports`); return; }
    const key = from + '\u0000' + to;
    let g = pairs.get(key);
    if (!g) pairs.set(key, g = { from, to, a, b, items: [] });
    const is = isList(e.is);
    g.items.push({ e, index, is: is.list, isBad: is.bad, w: e.weight == null ? 1 : +e.weight });
  });
  const edgeMap = new Map();
  for (const [key, g] of pairs) {
    // two arrows between one pair with no `is` to tell them apart are one, and draw answers `ambiguous_edge` for an arrow written without one beside typed ones
    const typed = g.items.some((i) => i.is.length || i.isBad);
    const items = typed ? g.items.filter((i) => i.is.length || i.isBad) : g.items;
    if (typed) for (const i of g.items) if (!i.is.length && !i.isBad) warnings.push(`edge "${g.from}" -> "${g.to}" without is dropped: the pair has typed arrows, and draw answers ambiguous_edge for an edge written without one`);
    // arrows of a pair that say what they hold are merged in a canonical order (by what they say), never the order the digest lists them in
    if (typed || items.some((i) => i.e.fieldValues != null || i.e.endRule != null)) {
      const said = (i) => canon({ d: !!i.e.direct, er: i.e.endRule == null ? null : i.e.endRule, fv: i.e.fieldValues == null ? null : i.e.fieldValues, text: i.e.text || '', via: i.e.via || null, w: i.w });
      const keyed = new Map(items.map((i) => [i, said(i)]));
      items.sort((x, y) => (keyed.get(x) < keyed.get(y) ? -1 : keyed.get(x) > keyed.get(y) ? 1 : 0));
    }
    const edge = { from: g.from, to: g.to, weight: 0, text: '', via: null, direct: false, cross: g.a.board !== g.b.board, arrows: [], end: isEndOf(g.a, g.b) };
    const arrows = new Map(), src = new Map();   // src: the edge each member of an arrow's values came from
    items.forEach((i, n) => {
      const e = i.e;
      edge.weight += i.w;
      edge.direct = edge.direct || !!e.direct;
      edge.via = edge.via || (e.via === 'reference' ? 'reference' : null);
      if (n === 0) edge.text = e.text || '';
      const k = i.isBad ? '\u0001bad' : isKey(i.is);
      let ar = arrows.get(k);
      if (!ar) arrows.set(k, ar = { is: i.is, isBad: i.isBad, text: e.text || '', fieldValuesGiven: false, fieldValues: null, endRuleGiven: false, endRule: null, conflicts: [], orders: [] });
      if (!src.has(ar)) src.set(ar, { fieldValues: {}, endRule: {} });
      if (!ar.orders.some((o) => o.join('\u0000') === i.is.join('\u0000'))) ar.orders.push(i.is);
      for (const which of ['fieldValues', 'endRule']) {
        const v = e[which];
        if (v == null) continue;
        ar[which + 'Given'] = true;
        if (!isPlain(v) || (ar[which] !== null && !isPlain(ar[which]))) { ar[which] = v; continue; }
        const next = Object.assign({}, ar[which]);
        for (const m of Object.keys(v)) {
          if (Object.prototype.hasOwnProperty.call(next, m) && canon(next[m]) !== canon(v[m])) ar.conflicts.push({ which, member: m, a: { index: src.get(ar)[which][m], value: next[m] }, b: { index: i.index, value: v[m] } });
          next[m] = v[m]; src.get(ar)[which][m] = i.index;
        }
        ar[which] = next;
      }
    });
    // a list of types is a set; the order it is drawn in means something to draw (a later type wins where two say the same), so the one written that sorts first
    for (const ar of arrows.values()) { ar.orders.sort((x, y) => (x.join('\u0000') < y.join('\u0000') ? -1 : x.join('\u0000') > y.join('\u0000') ? 1 : 0)); ar.is = ar.orders[0]; }
    edge.arrows = [...arrows.entries()].sort((x, y) => byTitle(x[0], y[0])).map((x) => x[1]);
    if (edge.end) edge.direct = true;   // an end is an arrow between two types: never a pill, which would be an arrow into a reference
    edgeMap.set(key, edge);
  }
  const edges = [...edgeMap.values()].sort((x, y) => byTitle(x.from, y.from) || byTitle(x.to, y.to));
  const out = new Map(), inn = new Map(), has = new Set();
  for (const e of edges) {
    if (!out.has(e.from)) out.set(e.from, []);
    if (!inn.has(e.to)) inn.set(e.to, []);
    out.get(e.from).push(e); inn.get(e.to).push(e);
    has.add(e.from + '\u0000' + e.to);
  }
  // the mess dial (the option, else the digest's policy.mess, else 0.5) sets the price of a pill and the rest; policy.references is gone
  const dl = dial(mess != null ? mess : policy.mess);
  const mu = dl.mu;
  const model = {
    title, policy, nodes, boards, boardDepth, kids, edges, out, inn, warnings,
    mu, dial: dl, promote: policy.promote !== false, ranks: policy.ranks || null,
    hasEdge: (a, b) => has.has(a + '\u0000' + b),
    node: (t) => nodes.get(t),
    boardIndex: new Map(boards.map((b, i) => [b, i])),
  };
  // what is public no matter the loop: pinned, or the end of an edge that crosses boards or asks via
  model.forcedPublic = new Set();
  model.publicWhy = new Map();   // title -> why it is public, for the report
  for (const e of edges) if (e.cross || e.via) { model.forcedPublic.add(e.to); if (!model.publicWhy.has(e.to)) model.publicWhy.set(e.to, e.cross ? 'an edge from another board points at it' : 'an edge asks for a reference to it'); }
  for (const n of nodes.values()) if (n.pin) { model.forcedPublic.add(n.title); model.publicWhy.set(n.title, 'public: true in the digest'); }
  for (const t of model.forcedPublic) if (nodes.get(t).never) throw new Error(`"${t}" is public: false, but an edge reaches it through a pill`);
  return model;
}

/** The leaf shapes (notes and cards) on a board. */
export function leavesOn(model, board) {
  return [...model.nodes.values()].filter((n) => n.board === board && LEAF_KINDS.has(n.kind));
}
