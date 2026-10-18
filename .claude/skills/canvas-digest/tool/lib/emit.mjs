// plan.json and the draw scripts. Every shape at an exact offset from its container's top-left (the first board's header note, or two of a
// subboard's board's shapes, for the board itself), frames at their final size, shapes made public one run before the edges through them.
// Typed shapes change the order of the runs (below): every type, relationship type and end of a board in one run, every note that is of a type
// after every such run. A subboard's `text` is its description, written in a run of its own once everything it may mention is drawn.
import { q, lit, byTitle, slug, pad2, fold } from './util.mjs';
import { headerText, HEADER_GAP } from './sizes.mjs';
import { fanTargets } from './moves.mjs';
import { noteTyping, arrowTyping } from './types.mjs';

/** What the plan makes public by its moves: the promoted nodes, and what the fanned-out nodes' pills stand for. */
export function madePublic(model, results) {
  const made = new Map();   // title -> why
  for (const r of results.values()) {
    for (const t of r.report.promoted) if (!made.has(t)) made.set(t, 'promoted: its users reach it through pills');
    for (const v of r.report.fanned || []) for (const t of fanTargets(model, v)) if (!made.has(t)) made.set(t, `${v} uses it, and points at so many shapes that its uses are pills beside it (fanned out)`);
    for (const x of r.report.long || []) if (!made.has(x.to)) made.set(x.to, `an arrow to it would run ${x.length} units, longer than the dial allows, so it is a pill`);
    for (const t of (r.layout && r.layout.plan.spined) || []) if (!made.has(t)) made.set(t, 'cards that point at many of the same shapes reach it through a pill (a spine)');
  }
  return made;
}

const at = (anchor, x, y) => `right of ${q(anchor)} left (gap: ${x}) below ${q(anchor)} top (gap: ${y})`;

// A shape on a board is placed exactly, from shapes already drawn on it, and a gap is never negative (language.md, "An exact offset"). On each axis a
// shape is placed against any drawn shape it does not wholly span: its left edge a gap right of that shape's left edge, or else its right edge a
// gap left of that shape's right edge (and the same down the page), so what is drawn first is the shape no later one spans: the widest, and the tallest.
const EPS = 1e-6;
const spansX = (s, p) => s.x < p.x - EPS && s.x + s.w > p.x + p.w + EPS;
const spansY = (s, p) => s.y < p.y - EPS && s.y + s.h > p.y + p.h + EPS;
const gap = (v) => Math.max(0, v);

/** The placement of the box `s` against the drawn shapes `refs` (titles, in the order to try them; `boxes` has theirs), or '' with none drawn. */
export function against(board, s, title, refs, boxes) {
  if (!refs.length) return '';
  let px = null, py = null;
  for (const t of refs) {
    const p = boxes.get(t);
    if (px === null && !spansX(s, p)) px = t;
    if (py === null && !spansY(s, p)) py = t;
    if (px !== null && py !== null) break;
  }
  if (px === null || py === null) throw new Error(`board "${board}": "${title}" is ${px === null ? 'wider' : 'taller'} than every shape drawn before it, so it cannot be placed against one of them (a gap is never negative)`);
  const P = boxes.get(px), Q = boxes.get(py);
  const x = s.x >= P.x - EPS ? `right of ${q(px)} left (gap: ${gap(s.x - P.x)})` : `left of ${q(px)} right (gap: ${gap(P.x + P.w - (s.x + s.w))})`;
  const y = s.y >= Q.y - EPS ? `below ${q(py)} top (gap: ${gap(s.y - Q.y)})` : `above ${q(py)} bottom (gap: ${gap(Q.y + Q.h - (s.y + s.h))})`;
  return `${x} ${y}`;
}

export function buildPlan(model, sizes, results, opts) {
  const publicSet = new Set([...model.forcedPublic, ...madePublic(model, results).keys()]);
  const into = opts.into ? fold(opts.into) : null;   // the subboard the whole digest goes in: its card is the first run, and the root board's shapes are `in` it
  const plan = { title: model.title, options: opts, into, boards: [], promotions: [], stop: {}, cost: {}, public: [...publicSet].sort(byTitle) };
  const runs = [];
  let seq = 0;
  if (into) runs.push({ name: '00-into.draw', text: `subboard ${q(into)}\n` });
  const addRun = (board, step, lines) => { seq++; runs.push({ name: `${pad2(seq)}-${slug(board)}-${step}.draw`, text: lines.join('\n') + '\n' }); };

  const drawn = new Map();   // board -> {boxOf, hdrTitle, dy}
  const planOf = new Map();   // board -> its entry in plan.boards
  for (const board of model.boards) {
    const { layout } = results.get(board);
    // the first board has a header note, above what is laid out, which its shapes are placed from; another board has none (its subboard's `text` is the
    // subboard's description) and is laid out where it is, its shapes placed from two of its own (below)
    const hdrTitle = model.headers.get(board) || null;
    let dy = 0;
    const shapes = [];
    if (hdrTitle) {
      const hs = sizes.shapes[hdrTitle];
      const hh = Math.ceil(hs.h), hw = Math.ceil(hs.w);
      dy = hh + HEADER_GAP;
      shapes.push({ title: hdrTitle, kind: 'sticky-note', in: null, x: 0, y: 0, w: hw, h: hh });
    }
    const boxOf = new Map();
    for (const [t, b] of layout.boxes) boxOf.set(t, { x: b.x, y: b.y + dy, w: b.w, h: b.h });
    for (const [t, b] of layout.frames) boxOf.set(t, { x: b.x, y: b.y + dy, w: b.w, h: b.h });
    for (const t of [...boxOf.keys()].sort(byTitle)) {
      const n = model.node(t), b = boxOf.get(t);
      shapes.push({ title: t, kind: n.kind, in: n.container[0] === 'f' ? n.container.slice(2) : null, x: b.x, y: b.y, w: b.w, h: b.h });
    }
    const pills = layout.pills.map((p) => ({ start: p.start, for: p.target, x: p.x, y: p.y + dy, w: p.w, h: p.h, users: p.users }))
      .sort((a, b) => byTitle(a.start, b.start) || a.y - b.y);
    // an edge through a reference: the host's edge first and every edge of a shared group saying share: true; `host` is whose column the pill is in
    // (a pair with typed arrows is an entry for each, saying `is`; an end of a relationship type says `end`)
    const edges = [];
    const entry = (e, a, rest) => Object.assign({ from: e.from, to: e.to }, rest, a.is.length ? { is: a.is } : {}, e.end ? { end: true } : {});
    const leftOf = new Set(layout.pills.filter((p) => p.left).map((p) => p.start + '\u0000' + p.target));   // pills in a column on their start's left
    for (const l of layout.plan.byStart.values()) for (const en of l) for (const a of en.e.arrows) edges.push(entry(en.e, a, Object.assign({ via: 'reference' }, en.shared ? { share: true, host: en.e.from } : {}, leftOf.has(en.e.from + '\u0000' + en.e.to) ? { side: 'left' } : {})));
    for (const f of layout.plan.free) for (const a of f.e.arrows) edges.push(entry(f.e, a, { via: 'reference', share: true, host: f.e.from }));
    for (const m of layout.plan.members) for (const a of m.e.arrows) edges.push(entry(m.e, a, { via: 'reference', share: true, sharedWith: m.host, host: m.host }));
    for (const e of layout.plan.direct) for (const a of e.arrows) edges.push(entry(e, a, { via: null }));
    edges.sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to));
    const boardPlan = hdrTitle ? { board, origin: hdrTitle, shapes, pills, edges } : { board, shapes, pills, edges };
    plan.boards.push(boardPlan);
    planOf.set(board, boardPlan);
    drawn.set(board, { boxOf, hdrTitle, dy });
    const r = results.get(board).report;
    for (const p of r.promotions) plan.promotions.push(p);
    plan.stop[board] = r.stop;
    plan.cost[board] = { start: r.start, end: r.end };
  }

  // shape runs, board by board: the header and what is on the board itself, then what is in the frames, a depth at a time.
  // A type's note, a relationship type's and the ends between them are one script on one board (an end gives each note of its types a row, and a
  // type's note grows by the rows its ends give it; a run lays a note out against the ends it draws itself): they go in the run of the deepest frame
  // any of them is in, whatever depth each is at. A note that is of a type waits for every such run (`is:` finds a type anywhere in the file, drawn
  // before it), in a run of its own for its board after the last of them; an arrow that is of a relationship type is in the edge runs, after them.
  const typedDepth = new Map();   // board -> the depth of the run that draws its types (none: the board has no type)
  const isInstance = (n) => n.kind === 'sticky-note' && n.is.length > 0;
  const isTyped = (n) => !!n.schema;
  for (const board of model.boards) {
    const { boxOf } = drawn.get(board);
    const types = [...boxOf.keys()].map((t) => model.node(t)).filter(isTyped);
    if (types.length) typedDepth.set(board, Math.max(...types.map((n) => n.frames.length)));
  }
  const depthOf = (board, t) => { const n = model.node(t); return isTyped(n) ? typedDepth.get(board) : n.frames.length; };
  // What a board's shapes are placed from. The first board's is its header note, drawn first. A subboard's board has none, so two of its own shapes
  // are: of those the earliest run draws on the board itself (a note that is of a type waits for the types, so those are the last run), the widest and
  // the tallest, which no other of them spans, drawn first. The first lands where the app puts a drawing with nothing to hang on, and the second is
  // placed against it, whichever of the two can be placed against the other. Everything after is placed against them (`against`).
  const boxes = new Map();    // board -> title -> box, the header note's too
  const anchors = new Map();  // board -> {x, y, order}: the shapes the plan's origin is read from, and the order they are drawn in
  const sortedOf = new Map(); // board -> its shapes' titles in the order they are drawn: the anchors first, then by title
  for (const board of model.boards) {
    const { boxOf, hdrTitle } = drawn.get(board);
    const all = new Map(boxOf);
    boxes.set(board, all);
    let a = null;
    if (hdrTitle) {
      const h = planOf.get(board).shapes[0];
      all.set(hdrTitle, { x: h.x, y: h.y, w: h.w, h: h.h });
      a = { x: hdrTitle, y: hdrTitle, order: [] };
    } else {
      const top = [...boxOf.keys()].filter((t) => model.node(t).container === 'b:' + board);
      if (top.length) {
        const runOf = (t) => (isInstance(model.node(t)) ? Infinity : depthOf(board, t));
        const first = Math.min(...top.map(runOf));
        const pool = top.filter((t) => runOf(t) === first);
        const box = (t) => boxOf.get(t);
        const widest = pool.slice().sort((s, t) => box(t).w - box(s).w || box(s).x - box(t).x || box(s).y - box(t).y || byTitle(s, t))[0];
        const tallest = pool.slice().sort((s, t) => box(t).h - box(s).h || box(s).y - box(t).y || box(s).x - box(t).x || byTitle(s, t))[0];
        const fits = (s, p) => !spansX(box(s), box(p)) && !spansY(box(s), box(p));
        let order;
        if (widest === tallest) order = [widest];
        else if (fits(tallest, widest)) order = [widest, tallest];
        else if (fits(widest, tallest)) order = [tallest, widest];
        else throw new Error(`board "${board}": "${widest}" and "${tallest}" cross, so neither can be placed against the other`);
        a = { x: widest, y: tallest, order };
      }
    }
    if (a) { anchors.set(board, a); planOf.get(board).anchors = { x: a.x, y: a.y }; }
    const rank = (t) => { const i = a ? a.order.indexOf(t) : -1; return i < 0 ? 2 : i; };
    sortedOf.set(board, [...boxOf.keys()].sort((s, t) => rank(s) - rank(t) || byTitle(s, t)));
  }
  const stmts = new Map();
  const drawnTop = new Map();   // board -> the shapes on the board itself drawn so far, in the order they were: the ones the next is placed against
  for (const board of model.boards) {
    const { boxOf, hdrTitle } = drawn.get(board);
    const holder = board === 'root' ? into : board;
    const inClause = (h) => (h ? ` in ${q(h)}` : '');
    const refs = hdrTitle ? [hdrTitle] : [];
    drawnTop.set(board, refs);
    const stmt = (t) => {
      const n = model.node(t), b = boxOf.get(t);
      const parent = n.container[0] === 'f' ? n.container.slice(2) : null;
      let place;
      if (parent) { const pb = boxOf.get(parent); place = at(parent, b.x - pb.x, b.y - pb.y); }
      else { place = against(board, b, t, refs, boxes.get(board)); refs.push(t); }
      const sp = place ? ' ' + place : '';
      const pub = publicSet.has(t) ? ' public: true' : '';
      if (n.kind === 'frame') return `frame ${q(t)}${inClause(parent || holder)}${sp} size: ${b.w}x${b.h}`;
      if (n.kind === 'subboard') return `subboard ${q(t)}${inClause(parent || holder)}${sp} size: ${b.w}x${b.h}${pub}`;
      return `sticky-note ${q(t)}${inClause(parent || holder)}${sp} size: ${b.w}x${b.h}${pub}` + (n.text ? ` text: ${lit(n.text)}` : '') + noteTyping(n);
    };
    stmts.set(board, stmt);
    const titles = sortedOf.get(board).filter((t) => !isInstance(model.node(t)));
    const header = [];
    if (hdrTitle) {
      const hs = sizes.shapes[hdrTitle];
      header.push(`sticky-note ${q(hdrTitle)}${inClause(holder)} size: ${Math.ceil(hs.w)}x${Math.ceil(hs.h)} text: ${lit(headerText(model))}`);
    }
    // the ends of this board's relationship types, after the shapes of the run that draws the types
    const ends = model.edges.filter((e) => e.end && model.node(e.from).board === board).sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to));
    const endLines = (d) => (typedDepth.get(board) === d
      ? ends.flatMap((e) => e.arrows.map((a) => `edge ${q(e.from)} -> ${q(e.to)}` + (a.text ? ` text: ${lit(a.text)}` : '') + arrowTyping(a)))
      : []);
    const top = header.concat(titles.filter((t) => depthOf(board, t) === 0).map(stmt), endLines(0));
    if (top.length) addRun(board, 'top', top);
    const maxDepth = Math.max(0, ...titles.map((t) => depthOf(board, t)));
    for (let d = 1; d <= maxDepth; d++) {
      const lines = titles.filter((t) => depthOf(board, t) === d).map(stmt).concat(endLines(d));
      if (lines.length) addRun(board, 'in-' + d, lines);
    }
  }
  for (const board of model.boards) {
    const lines = sortedOf.get(board).filter((t) => isInstance(model.node(t))).map(stmts.get(board));
    if (lines.length) addRun(board, 'notes', lines);
  }
  // a subboard's `text` is its description, written once every shape it may mention is drawn (a mention names a shape of any board, in a run after its
  // own), by a statement of the card with nothing else in it, which restates the card as it is
  const subsOn = new Map();   // board -> its subboards that have a description
  for (const n of model.nodes.values()) if (n.kind === 'subboard' && n.text) subsOn.set(n.board, (subsOn.get(n.board) || []).concat([n.title]));
  const described = {};       // run -> the titles it describes
  for (const board of model.boards) {
    const subs = (subsOn.get(board) || []).sort(byTitle);
    if (!subs.length) continue;
    addRun(board, 'describe', subs.map((t) => `subboard ${q(t)} description: ${lit(model.node(t).text)}`));
    described[runs[runs.length - 1].name] = subs;
  }
  if (Object.keys(described).length) plan.described = described;
  // edge runs, after every shape that is to be public is. In a run, a start's pills in the order of its column come first (the host's
  // edge of a shared group is among them, so the pill exists), then the edges of the users of a shared pill, then the plain arrows.
  for (const board of model.boards) {
    const { layout } = results.get(board);
    const { boxOf, dy } = drawn.get(board);
    // a spine's shared pill is where its maker's edge says: at its offset from the top-left of the spine's frame, and in it, or, for a spine
    // that is the board itself, against the shapes drawn on the board, as the shapes are placed
    const placed = (f) => {
      const p = layout.pills[f.at], cid = model.node(f.e.from).container;
      if (cid[0] === 'f') { const frame = cid.slice(2), fb = boxOf.get(frame); return ` in ${q(frame)} ` + at(frame, p.x - fb.x, p.y + dy - fb.y); }
      return ' ' + against(board, { x: p.x, y: p.y + dy, w: p.w, h: p.h }, `the pill for ${f.e.to}`, drawnTop.get(board), boxes.get(board));
    };
    const lines = [];
    // an edge of a pair with typed arrows is a line for each arrow, saying what it is (draw reuses the pill the first made for the pair)
    const line = (e, head) => e.arrows.map((a) => `edge ${q(e.from)} -> ${q(e.to)}${head}` + (a.text ? ` text: ${lit(a.text)}` : '') + arrowTyping(a));
    const starts = [...layout.plan.byStart.keys()].sort(byTitle);
    // the pills others share first (draw reuses the first pill made for an end in a container, so that has to be the host's), and a spine's,
    // then the other pills (a column's pills keep their order: the shared ones are first in it; a spine's left leaf's column is on its left,
    // `from: left`), then the users of a shared pill, each saying `share: "<host>"`
    for (const s of starts) for (const en of layout.plan.byStart.get(s)) if (en.shared) lines.push(...line(en.e, ' via: reference'));   // the host's own: a pill beside it (no share, so it is never another cluster's)
    for (const f of layout.plan.free.slice().sort((a, b) => byTitle(a.e.from, b.e.from) || byTitle(a.e.to, b.e.to))) lines.push(...line(f.e, ' via: reference' + placed(f)));   // a spine's shared pill, made where it goes
    const leftOf = new Set(layout.pills.filter((p) => p.left).map((p) => p.start + '\u0000' + p.target));
    for (const s of starts) for (const en of layout.plan.byStart.get(s)) if (!en.shared) lines.push(...line(en.e, ' via: reference' + (leftOf.has(en.e.from + '\u0000' + en.e.to) ? ' from: left' : '')));
    for (const m of layout.plan.members.slice().sort((a, b) => byTitle(a.e.from, b.e.from) || byTitle(a.e.to, b.e.to))) lines.push(...line(m.e, ` via: reference share: ${q(m.host)}`));
    for (const e of layout.plan.direct.slice().sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to))) if (!e.end) lines.push(...line(e, ''));
    if (lines.length) addRun(board, 'edges', lines);
  }
  plan.runs = runs.map((r) => r.name);
  return { plan, runs };
}

export function buildReport(model, results, timings) {
  const boards = {};
  for (const [b, r] of results) boards[b] = r.report;
  const flat = [];
  for (const r of results.values()) for (const p of r.report.promotions) flat.push(p);
  const total = { pills: 0, arrows: 0, sharedArrows: 0 };
  for (const r of results.values()) { total.pills += r.report.end.pills; total.arrows += r.report.end.arrows; total.sharedArrows += r.report.end.sharedArrows; }
  const made = madePublic(model, results);
  const pub = [...new Set([...model.forcedPublic, ...made.keys()])].sort(byTitle);
  const why = {};
  for (const t of pub) why[t] = model.publicWhy.get(t) || made.get(t);
  // a board too crowded to search (promote.mjs's CROWD) is said, with the way out: the plan holds, and the board reads as a crowd
  const crowded = [...results].filter(([, r]) => r.report.crowded).map(([b, r]) => {
    const c = r.report.crowded;
    const what = c.shapes > c.mostShapes ? `it holds ${c.shapes} shapes, past ${c.mostShapes}` : `${c.container ? `its frame "${c.container}"` : 'it'} holds ${c.children} shapes side by side, past ${c.most}`;
    return `board "${b}" was laid out once and not searched: ${what}, and searching a board that crowded takes hours. Its arrows are drawn as arrows (those to other boards as pills), and it reads as a crowd: split it into subboards`;
  });
  // D11: the tool makes public only shapes it creates, and these are all of them
  return { title: model.title, public: pub, publicWhy: why, promotions: flat, boards, totals: total, timings, warnings: model.warnings.concat(crowded) };
}
