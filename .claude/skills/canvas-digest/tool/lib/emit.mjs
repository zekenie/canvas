// plan.json and the draw scripts. Every shape at an exact offset from its container's top-left (the header note
// for the board itself), frames at their final size, shapes made public one run before the edges through them. Typed shapes change the order of
// the runs (below): every type, relationship type and end of a board in one run, every note that is of a type after every such run.
import { q, lit, byTitle, slug, pad2, fold } from './util.mjs';
import { headerText, HEADER_W, HEADER_GAP } from './sizes.mjs';
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

export function buildPlan(model, sizes, results, opts) {
  const publicSet = new Set([...model.forcedPublic, ...madePublic(model, results).keys()]);
  const into = opts.into ? fold(opts.into) : null;   // the subboard the whole digest goes in: its card is the first run, and the root board's shapes are `in` it
  const plan = { title: model.title, options: opts, into, boards: [], promotions: [], stop: {}, cost: {}, public: [...publicSet].sort(byTitle) };
  const runs = [];
  let seq = 0;
  if (into) runs.push({ name: '00-into.draw', text: `subboard ${q(into)}\n` });
  const addRun = (board, step, lines) => { seq++; runs.push({ name: `${pad2(seq)}-${slug(board)}-${step}.draw`, text: lines.join('\n') + '\n' }); };

  const drawn = new Map();   // board -> {shapes, hdr}
  for (const board of model.boards) {
    const { layout } = results.get(board);
    const hdrTitle = model.headers.get(board);
    const hs = sizes.shapes[hdrTitle];
    const hh = Math.ceil(hs.h), hw = Math.ceil(hs.w);
    const dy = hh + HEADER_GAP;
    const shapes = [{ title: hdrTitle, kind: 'sticky-note', in: null, x: 0, y: 0, w: hw, h: hh }];
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
    plan.boards.push({ board, origin: hdrTitle, shapes, pills, edges });
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
  const stmts = new Map();
  for (const board of model.boards) {
    const { boxOf, hdrTitle } = drawn.get(board);
    const holder = board === 'root' ? into : board;
    const inClause = (h) => (h ? ` in ${q(h)}` : '');
    const stmt = (t) => {
      const n = model.node(t), b = boxOf.get(t);
      const parent = n.container[0] === 'f' ? n.container.slice(2) : null;
      const pb = parent ? boxOf.get(parent) : null;
      const x = b.x - (pb ? pb.x : 0), y = b.y - (pb ? pb.y : 0);
      const place = at(parent || hdrTitle, x, y);
      const pub = publicSet.has(t) ? ' public: true' : '';
      if (n.kind === 'frame') return `frame ${q(t)}${inClause(parent || holder)} ${place} size: ${b.w}x${b.h}`;
      if (n.kind === 'subboard') return `subboard ${q(t)}${inClause(parent || holder)} ${place} size: ${b.w}x${b.h}${pub}`;
      return `sticky-note ${q(t)}${inClause(parent || holder)} ${place} size: ${b.w}x${b.h}${pub}` + (n.text ? ` text: ${lit(n.text)}` : '') + noteTyping(n);
    };
    stmts.set(board, stmt);
    const titles = [...boxOf.keys()].sort(byTitle).filter((t) => !isInstance(model.node(t)));
    const hs = sizes.shapes[hdrTitle];
    const header = `sticky-note ${q(hdrTitle)}${inClause(holder)} size: ${Math.ceil(hs.w)}x${Math.ceil(hs.h)} text: ${lit(headerText(model, board))}`;
    // the ends of this board's relationship types, after the shapes of the run that draws the types
    const ends = model.edges.filter((e) => e.end && model.node(e.from).board === board).sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to));
    const endLines = (d) => (typedDepth.get(board) === d
      ? ends.flatMap((e) => e.arrows.map((a) => `edge ${q(e.from)} -> ${q(e.to)}` + (a.text ? ` text: ${lit(a.text)}` : '') + arrowTyping(a)))
      : []);
    addRun(board, 'top', [header].concat(titles.filter((t) => depthOf(board, t) === 0).map(stmt), endLines(0)));
    const maxDepth = Math.max(0, ...titles.map((t) => depthOf(board, t)));
    for (let d = 1; d <= maxDepth; d++) {
      const lines = titles.filter((t) => depthOf(board, t) === d).map(stmt).concat(endLines(d));
      if (lines.length) addRun(board, 'in-' + d, lines);
    }
  }
  for (const board of model.boards) {
    const { boxOf } = drawn.get(board);
    const lines = [...boxOf.keys()].sort(byTitle).filter((t) => isInstance(model.node(t))).map(stmts.get(board));
    if (lines.length) addRun(board, 'notes', lines);
  }
  // edge runs, after every shape that is to be public is. In a run, a start's pills in the order of its column come first (the host's
  // edge of a shared group is among them, so the pill exists), then the edges of the users of a shared pill, then the plain arrows.
  for (const board of model.boards) {
    const { layout } = results.get(board);
    const { boxOf, hdrTitle, dy } = drawn.get(board);
    // a spine's shared pill is where its maker's edge says: at its offset from the top-left of the spine's frame, and in it, or, for a spine
    // that is the board itself, from the board's header note, as the shapes are placed
    const placed = (f) => {
      const p = layout.pills[f.at], cid = model.node(f.e.from).container;
      const frame = cid[0] === 'f' ? cid.slice(2) : null, fb = frame ? boxOf.get(frame) : { x: 0, y: 0 };
      return (frame ? ` in ${q(frame)}` : '') + ' ' + at(frame || hdrTitle, p.x - fb.x, p.y + dy - fb.y);
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
