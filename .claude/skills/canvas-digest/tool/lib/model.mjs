// The digest, read into a model: nodes, the board and frames each is on, edges, boards.
import { byTitle, fold } from './util.mjs';
import { dial } from './dial.mjs';

export const LEAF_KINDS = new Set(['sticky-note', 'subboard']);

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
    nodes.set(t, {
      title: t, kind: n.kind || 'sticky-note', parent: n.in ? fold(n.in) : null, text: n.text || '',
      pin: n.public === true, never: n.public === false, children: [],
      rank: typeof n.rank === 'number' && isFinite(n.rank) ? n.rank : null,
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
  // header notes, one a board
  // (a title no node and no other board's header has: the digest's own gives way when a subboard is called what the digest is)
  const headers = new Map(), taken = new Set();
  for (const b of boards.filter((x) => x !== 'root').concat(['root'])) {
    let t = 'About ' + (b === 'root' ? title : b);
    while (nodes.has(t) || taken.has(t)) t += ' (digest)';
    headers.set(b, t); taken.add(t);
  }
  // edges
  const edgeMap = new Map();
  for (const e of digest.edges || []) {
    const from = fold(e.from), to = fold(e.to);
    const a = nodes.get(from), b = nodes.get(to);
    if (!a || !b) throw new Error(`edge ${from} -> ${to}: unknown title`);
    if (from === to) continue;
    if (a.kind === 'frame' || b.kind === 'frame') { warnings.push(`edge "${from}" -> "${to}" dropped: a frame has no ports`); continue; }
    const key = from + '\u0000' + to;
    const w = e.weight == null ? 1 : +e.weight;
    const old = edgeMap.get(key);
    if (old) { old.weight += w; old.direct = old.direct || !!e.direct; old.via = old.via || (e.via === 'reference' ? 'reference' : null); continue; }
    edgeMap.set(key, { from, to, weight: w, text: e.text || '', via: e.via === 'reference' ? 'reference' : null, direct: !!e.direct, cross: a.board !== b.board });
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
    title, text: typeof digest.text === 'string' ? digest.text : '', policy, nodes, boards, boardDepth, kids, headers, edges, out, inn, warnings,
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
