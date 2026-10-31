// The digest, read into a model: nodes, the board and frames each is on, edges, boards.
import { byTitle, fold, label } from './util.mjs';

export const MAX_TITLE = 80;
import { dial } from './dial.mjs';
import { isEndOf, isKey, canon } from './types.mjs';

export const LEAF_KINDS = new Set(['sticky-note', 'subboard']);
const isPlain = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/**
 * Why the digest draws no arrow for edge `e`, from node a to node b, at a frame; null where it draws one: an edge at a frame is an arrow, on `frame-link`,
 * between two frames or a frame and a subboard on one board, as the app joins them. A frame and what it holds, at any depth, are never joined (the
 * app's `cannot_connect`); a note and a frame share no channel; and a pill can neither stand for a frame (which is never public) nor sit beside one.
 */
function frameRefusal(a, b, e) {
  if (a.kind !== 'frame' && b.kind !== 'frame') return null;
  if (a.chain.includes(b.key) || b.chain.includes(a.key)) return 'a frame and what it holds are never connected';
  if (a.kind === 'sticky-note' || b.kind === 'sticky-note') return 'a note and a frame share no channel';
  if (a.board !== b.board || e.via === 'reference') return 'an edge at a frame is an arrow on one board, never a pill (none stands for a frame, which is never public, nor sits beside one)';
  return null;
}

/** `is` as the digest writes it (a title, or a list of them) as a list of folded titles, without repeats; bad: it is neither. */
function isList(v) {
  if (v == null) return { list: [], bad: false };
  const raw = typeof v === 'string' ? [v] : v;
  if (!Array.isArray(raw) || raw.some((t) => typeof t !== 'string' || !fold(t))) return { list: [], bad: true };
  return { list: [...new Set(raw.map(fold))], bad: false };
}

/**
 * The digest's nodes read: who has which id and title, what each is in, and every refusal found in that, all of them (`errors`). A node's title is
 * unique among the nodes in one container (the first board's top level is one; compared as folded text, case aside), so two nodes in different
 * containers may share one; a node may also carry an `id`, unique in the digest. `in`, `from` and `to` name a node by its id, or by its title when
 * exactly one node has that title (an id wins where a string is both some node's id and another's title). A type's title (a node with a `schema`)
 * is unique across the whole digest, since `is` names a type by its title.
 *
 * Each node gets a `key`, which is how the rest of the tool tells nodes apart: its id when it has one, else its title, as long as nothing else
 * has that string; a title that two nodes have is qualified by the containers the node is in (`title  in a > b`, two spaces, which a folded title
 * never has: keys sort as the titles do, so a row of shapes keeps its title order). With titles all unique and no ids, a key is the title.
 */
export function readNodes(digest) {
  const errors = [];
  const raw = Array.isArray(digest.nodes) ? digest.nodes : [];
  const items = raw.map((n, index) => ({ index, raw: n, title: fold(n && n.title), id: null, parent: -1, kind: (n && n.kind) || 'sticky-note' }));
  const at = (it) => `nodes[${it.index}] "${it.title}"`;
  for (const it of items) {
    const n = it.raw;
    if (!it.title) { errors.push(`a node has no title (nodes[${it.index}])`); continue; }
    if (it.title.length > MAX_TITLE) errors.push(`"${it.title}" is over ${MAX_TITLE} characters`);
    if (n.id != null) {
      if (typeof n.id !== 'string' || !n.id.trim()) errors.push(`${at(it)}: id is a non-empty string, not ${JSON.stringify(n.id)}`);
      else it.id = n.id;
    }
  }
  const titled = items.filter((it) => it.title);
  const ids = new Map();
  for (const it of titled) if (it.id != null) { if (!ids.has(it.id)) ids.set(it.id, []); ids.get(it.id).push(it); }
  for (const [id, list] of ids) if (list.length > 1) errors.push(`two nodes have the id "${id}" (${list.map((it) => `nodes[${it.index}] "${it.title}"`).join(' and ')}): an id is unique in the digest`);
  const titles = new Map();
  for (const it of titled) { if (!titles.has(it.title)) titles.set(it.title, []); titles.get(it.title).push(it); }

  /** What a reference (`in`, `from`, `to`) names: {item}, or {unknown}, or {several: [items]} for a title that more than one node has. */
  const resolve = (ref) => {
    const s = typeof ref === 'string' ? ref : String(ref);
    if (ids.has(s)) return ids.get(s).length === 1 ? { item: ids.get(s)[0] } : { several: ids.get(s) };
    const list = titles.get(fold(s)) || [];
    return list.length === 1 ? { item: list[0] } : list.length ? { several: list } : { unknown: true };
  };
  const severalSaid = (ref, list) => `a title ${list.length} nodes have (${list.map((it) => `nodes[${it.index}]`).join(', ')}): give the nodes ids and name one by its id`;
  // what holds each node
  for (const it of titled) {
    const ref = it.raw.in;
    if (!ref) continue;
    const r = resolve(ref);
    if (r.item) it.parent = r.item.index;
    else if (r.several) errors.push(`${at(it)} is in "${fold(ref)}", ${severalSaid(ref, r.several)}`);
    else errors.push(`"${it.title}" is in "${fold(ref)}", which is not a node`);
  }
  // `in` must lead to the top: a shape inside itself, or two inside each other, has no board to be on
  const byIndex = (i) => items[i];
  const ringed = new Set();
  for (const it of titled) {
    if (it.parent < 0 || ringed.has(it.index)) continue;
    const chain = [it];
    for (let p = it.parent; p >= 0; p = byIndex(p).parent) {
      const seen = chain.findIndex((c) => c.index === p);
      if (seen >= 0) {
        const ring = chain.slice(seen).concat([byIndex(p)]);
        for (const r of ring) ringed.add(r.index);
        errors.push(ring.length === 2 ? `"${byIndex(p).title}" is in itself` : `"in" runs in a circle: ${ring.map((r) => `"${r.title}"`).join(' is in ')}; a shape cannot be inside itself`);
        break;
      }
      if (ringed.has(p)) break;
      chain.push(byIndex(p));
    }
  }
  const cyclic = ringed.size > 0;
  // a title is unique among the nodes in one container (case aside)
  const where = new Map();
  for (const it of titled) {
    const k = it.parent + '\u0000' + it.title.toLowerCase();
    if (!where.has(k)) where.set(k, []);
    where.get(k).push(it);
  }
  const containerSaid = (it) => {
    if (it.parent < 0) return "the first board's top level";
    return `"${byIndex(it.parent).title}"` + (titles.get(byIndex(it.parent).title).length > 1 ? ` (nodes[${it.parent}])` : '');
  };
  for (const list of where.values()) {
    if (list.length < 2) continue;
    const a = list[0], b = list[1];
    errors.push(`duplicate title "${b.title}"` + (a.title === b.title ? '' : ` (also "${a.title}")`) + `: nodes[${a.index}] and nodes[${b.index}] are both in ${containerSaid(a)}; a title is unique among the nodes in one container (give one another title, or put one elsewhere)`);
  }
  // a type's title is unique across the digest: `is` names a type by its title, and draw finds a type anywhere in the file
  const types = new Map();
  for (const it of titled) {
    if (it.raw.schema == null) continue;
    if (!types.has(it.title)) types.set(it.title, []);
    types.get(it.title).push(it);
  }
  for (const [t, list] of types) if (list.length > 1) errors.push(`two types are called "${t}" (${list.map((it) => `nodes[${it.index}]`).join(' and ')}): a type's title is unique in the whole digest, since is names a type by its title`);
  // edges: both ends name a node
  (Array.isArray(digest.edges) ? digest.edges : []).forEach((e, index) => {
    for (const end of ['from', 'to']) {
      const ref = e && e[end];
      if (typeof ref !== 'string' || !fold(ref)) { errors.push(`edges[${index}]: ${end} is the id or title of a node, not ${JSON.stringify(ref)}`); continue; }
      const r = resolve(ref);
      if (r.unknown) errors.push(`edge ${fold(e.from)} -> ${fold(e.to)}: unknown title "${fold(ref)}" in edges[${index}] (no node has that id or title)`);
      else if (r.several) errors.push(`edges[${index}] ${end} "${fold(ref)}" is ${severalSaid(ref, r.several)}`);
    }
  });
  // the key of each node
  const ancestors = (it) => { const out = []; for (let p = it.parent; p >= 0 && out.length <= items.length; p = byIndex(p).parent) out.unshift(byIndex(p)); return out; };
  if (!cyclic) {
    const qualified = (it, json) => {
      const chain = ancestors(it).map((a) => a.title);
      return `${it.title}  in ${json ? JSON.stringify(chain) : chain.join(' > ') || 'the first board'}`;
    };
    for (const it of titled) {
      const shared = titles.get(it.title).length > 1 || (it.id == null && ids.has(it.title));
      it.key = it.id != null ? it.id : shared ? qualified(it) : it.title;
    }
    const held = new Map();
    for (const it of titled) { if (!held.has(it.key)) held.set(it.key, []); held.get(it.key).push(it); }
    for (const list of held.values()) if (list.length > 1) for (const it of list) if (it.id == null) it.key = qualified(it, true);
  }
  return { errors, items: titled, all: items, titles, ids, types, resolve, ancestors, severalSaid };
}

export function buildModel(digest, mess) {
  const warnings = [];
  const title = fold(digest.title || 'Digest');
  const policy = digest.policy || {};
  if (policy.ranks != null && !['rows', 'columns'].includes(policy.ranks)) throw new Error(`policy.ranks is "rows" or "columns" (left out: whichever the view shows larger), not ${JSON.stringify(policy.ranks)}`);
  const read = readNodes(digest);
  if (read.errors.length) throw new Error(read.errors[0]);
  const nodes = new Map();
  const sorted = read.items.slice().sort((x, y) => byTitle(x.key, y.key));
  const keyOf = new Map(read.items.map((it) => [it.index, it.key]));
  for (const it of sorted) {
    const n = it.raw;
    const is = isList(n.is);
    nodes.set(it.key, {
      key: it.key, title: it.title, id: it.id, index: it.index, kind: n.kind || 'sticky-note', parent: it.parent >= 0 ? keyOf.get(it.parent) : null, text: n.text || '',
      pin: n.public === true, never: n.public === false, children: [],
      chain: read.ancestors(it).map((a) => keyOf.get(a.index)),   // the containers it is in, outermost first (frames and subboards alike)
      rank: typeof n.rank === 'number' && isFinite(n.rank) ? n.rank : null,
      // what a note is: a type (it holds a schema), a relationship type, an instance (`is` the types, `fieldValues` its values); check says what is wrong with them
      schemaGiven: n.schema != null, schema: n.schema != null ? n.schema : null,
      relationshipGiven: n.relationship != null && n.relationship !== false, relationshipRaw: n.relationship, relationship: n.relationship === true,
      is: is.list, isBad: is.bad, fieldValuesGiven: n.fieldValues != null, fieldValues: n.fieldValues != null ? n.fieldValues : null,
    });
  }
  for (const n of nodes.values()) if (n.parent) nodes.get(n.parent).children.push(n.key);
  // kind: auto is a subboard when its subtree has over 40 leaves or is over two frames deep, else a frame
  const leavesUnder = (n) => (n.children.length ? n.children.reduce((s, c) => s + leavesUnder(nodes.get(c)), 0) : 1);
  const depthUnder = (n) => 1 + Math.max(0, ...n.children.map((c) => depthUnder(nodes.get(c))));
  for (const n of nodes.values()) if (n.kind === 'auto') n.kind = leavesUnder(n) > 40 || depthUnder(n) > 3 ? 'subboard' : 'frame';
  for (const n of nodes.values()) {
    const container = n.kind === 'frame' || n.kind === 'subboard';
    if (!container && n.kind !== 'sticky-note') throw new Error(`"${label(n.key)}": kind ${n.kind} is not supported`);
    if (n.pin && container && n.kind === 'frame') throw new Error(`"${label(n.key)}" is a frame, and a frame is never public`);
    if (n.children.length && !container) throw new Error(`"${label(n.key)}" holds shapes but is a ${n.kind}`);
    if (n.parent && !['frame', 'subboard'].includes(nodes.get(n.parent).kind)) throw new Error(`"${label(n.key)}" is in "${label(n.parent)}", which holds no shapes`);
  }
  // which board, which frames, which container
  const place = (n) => {
    if (n.board) return;
    if (!n.parent) { n.board = 'root'; n.frames = []; n.container = 'b:root'; return; }
    const p = nodes.get(n.parent);
    place(p);
    if (p.kind === 'subboard') { n.board = p.key; n.frames = []; n.container = 'b:' + p.key; }
    else { n.board = p.board; n.frames = p.frames.concat([p.key]); n.container = 'f:' + p.key; }
  };
  for (const n of nodes.values()) place(n);
  // boards: root first, then subboards by depth, then title
  const boardDepth = new Map([['root', 0]]);
  const subs = [...nodes.values()].filter((n) => n.kind === 'subboard');
  const depth = (s) => (s.board === 'root' ? 1 : 1 + depth(nodes.get(s.board)));
  for (const s of subs) boardDepth.set(s.key, depth(s));
  const boards = ['root'].concat(subs.map((s) => s.key).sort((a, b) => boardDepth.get(a) - boardDepth.get(b) || byTitle(a, b)));
  const kids = new Map();
  for (const b of boards) kids.set('b:' + b, []);
  for (const n of nodes.values()) if (n.kind === 'frame') kids.set('f:' + n.key, []);
  for (const n of nodes.values()) kids.get(n.container).push(n.key);
  for (const v of kids.values()) v.sort(byTitle);
  // edges: the ones between a pair are one edge to the layout (their weights added), and each typed one is an arrow of its own when it is drawn
  const pairs = new Map();
  (digest.edges || []).forEach((e, index) => {
    const a = nodes.get(read.resolve(e.from).item.key), b = nodes.get(read.resolve(e.to).item.key);
    const from = a.key, to = b.key;
    if (from === to) return;
    const refused = frameRefusal(a, b, e);
    if (refused) { warnings.push(`edge "${label(from)}" -> "${label(to)}" dropped: ${refused}`); return; }
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
    if (typed) for (const i of g.items) if (!i.is.length && !i.isBad) warnings.push(`edge "${label(g.from)}" -> "${label(g.to)}" without is dropped: the pair has typed arrows, and draw answers ambiguous_edge for an edge written without one`);
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
    if (g.a.kind === 'frame' || g.b.kind === 'frame') { edge.atFrame = true; edge.direct = true; }   // never a pill: none stands for a frame, nor sits beside one
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
    types: new Map([...nodes.values()].filter((n) => n.schemaGiven).map((n) => [n.title, n])),   // a type by its title (unique across the digest)
    boardIndex: new Map(boards.map((b, i) => [b, i])),
  };
  // what is public no matter the loop: pinned, or the end of an edge that crosses boards or asks via
  model.forcedPublic = new Set();
  model.publicWhy = new Map();   // key -> why it is public, for the report
  for (const e of edges) if (e.cross || e.via) { model.forcedPublic.add(e.to); if (!model.publicWhy.has(e.to)) model.publicWhy.set(e.to, e.cross ? 'an edge from another board points at it' : 'an edge asks for a reference to it'); }
  for (const n of nodes.values()) if (n.pin) { model.forcedPublic.add(n.key); model.publicWhy.set(n.key, 'public: true in the digest'); }
  for (const t of model.forcedPublic) if (nodes.get(t).never) throw new Error(`"${label(t)}" is public: false, but an edge reaches it through a pill`);
  return model;
}

/** The leaf shapes (notes and cards) on a board. */
export function leavesOn(model, board) {
  return [...model.nodes.values()].filter((n) => n.board === board && LEAF_KINDS.has(n.kind));
}
