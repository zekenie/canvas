// plan.json and the draw scripts. Every shape at an exact offset from its container's top-left (a frame's, or the board's origin, its point
// (0, 0), for the board itself), frames at their final size, shapes made public one run before the edges through them.
// Typed shapes change the order of the runs (below): every type, relationship type and end of a board in one run, but for a type that waits for a
// type of another board, drawn in a later round, every note that is of a type after every such run. A subboard's `text` is its description, written
// in a run of its own once everything it may mention is drawn.
import { q, lit, byTitle, slug, pad2, fold, label } from './util.mjs';
import { Spelling } from './names.mjs';
import { fanTargets } from './moves.mjs';
import { noteTyping, arrowTyping, typeRounds, isType, isInstance, isTypedContainer } from './types.mjs';

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

const at = (anchor, x, y) => `right of ${anchor} left (gap: ${x}) below ${anchor} top (gap: ${y})`;   // anchor: a name as the script writes it

/** What an edge line says of itself, for matching a result's rows to it: its ends (keys), the relationship types it is of, and whether it goes through a pill. */
const edgeSays = (e, a, via) => Object.assign({ from: e.from, to: e.to }, a.is && a.is.length ? { is: a.is } : {}, via ? { via: true } : {});

/** A box on the board itself, placed at its offset from the board's origin (language.md, "An exact offset"): never left of it or above it. */
export const fromOrigin = (b) => `right of origin (gap: ${b.x}) below origin (gap: ${b.y})`;

/**
 * How far a board's layout is moved right and down so that nothing on it is left of its origin or above it: a gap is never negative, and a
 * shape across the origin can't be placed against it. {x: 0, y: 0} for a layout that starts at its origin, as every container's does.
 */
export function shiftOf(layout) {
  let x = 0, y = 0;
  for (const b of [...layout.boxes.values(), ...layout.frames.values(), ...layout.pills]) { x = Math.min(x, b.x); y = Math.min(y, b.y); }
  return { x: -x, y: -y };
}

export function buildPlan(model, results, opts) {
  const publicSet = new Set([...model.forcedPublic, ...madePublic(model, results).keys()]);
  const into = opts.into ? fold(opts.into) : null;   // the subboard the whole digest goes in: its card is the first run, and the root board's shapes are `in` it
  const shown = Object.assign({}, opts); delete shown.existing;   // the file's titles are the plan's input, and not part of what it says
  const plan = { title: model.title, options: shown, into, boards: [], promotions: [], stop: {}, cost: {}, public: [...publicSet].sort(byTitle) };
  const runs = [];
  let seq = 0;
  // every name a script writes goes through one Spelling: bare where only the shape can be meant, else a path (names.mjs)
  const sp = new Spelling(model, into, opts.existing);
  if (into) for (const t of model.types.keys()) sp.absent.add(t);   // `is:` finds a type by its title anywhere in the file
  if (into) runs.push({ name: '00-into.draw', text: `subboard ${q(into)}\n`, board: 'root', lines: [{ into: true }] });
  // a line is its text and what it says, for matching the rows of a result to the statements by their line: {shape: key}, {edge: {from, to, is}} or {describe: key}
  const addRun = (board, step, lines) => { seq++; runs.push({ name: `${pad2(seq)}-${slug(board)}-${step}.draw`, text: lines.map((l) => l.text).join('\n') + '\n', board, lines: lines.map((l) => l.says) }); };
  const said = (text, says) => ({ text, says });

  const drawn = new Map();   // board -> {boxOf, dx, dy}
  for (const board of model.boards) {
    const { layout } = results.get(board);
    // every board is laid out where it is, the plan's (0, 0) its origin, which its shapes are placed from (a subboard's `text` is the subboard's
    // description, and no board has a note for what it is)
    const { x: dx, y: dy } = shiftOf(layout);
    const shapes = [];
    const boxOf = new Map();
    for (const [t, b] of layout.boxes) boxOf.set(t, { x: b.x + dx, y: b.y + dy, w: b.w, h: b.h });
    for (const [t, b] of layout.frames) boxOf.set(t, { x: b.x + dx, y: b.y + dy, w: b.w, h: b.h });
    for (const t of [...boxOf.keys()].sort(byTitle)) {
      const n = model.node(t), b = boxOf.get(t);
      // a shape says its title, its id when it has one, and its key when more than one shape has the title (then `title` alone does not tell it)
      shapes.push(Object.assign({ title: n.title }, n.id != null ? { id: n.id } : n.key !== n.title ? { key: n.key } : {}, { kind: n.kind, in: n.container[0] === 'f' ? n.container.slice(2) : null, x: b.x, y: b.y, w: b.w, h: b.h }));
    }
    const pills = layout.pills.map((p) => ({ start: p.start, for: p.target, x: p.x + dx, y: p.y + dy, w: p.w, h: p.h, users: p.users }))
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
    plan.boards.push({ board, shapes, pills, edges });
    drawn.set(board, { boxOf, dx, dy });
    const r = results.get(board).report;
    for (const p of r.promotions) plan.promotions.push(p);
    plan.stop[board] = r.stop;
    plan.cost[board] = { start: r.start, end: r.end };
  }

  // shape runs, board by board: what is on the board itself, then what is in the frames, a depth at a time.
  // A type's note, a relationship type's and the ends between them are one script on one board (an end gives each note of its types a row, and a
  // type's note grows by the rows its ends give it, and has the rows and fields of the types it builds on; a run lays a note out against everything
  // it draws itself): a board's types of the first round (`typeRounds`: those that wait for no type of another board) go in the run of the deepest
  // frame any of them is in, whatever depth each is at. A type of a later round waits for that round, after every board's shapes: a run for each
  // board with types in it. A note that is of a type waits for every such run (`is:` finds a type anywhere in the file, drawn before it), in a run of
  // its own for its board after the last of them; an arrow that is of a relationship type is in the edge runs, after them.
  const rounds = typeRounds(model);
  const typedDepth = new Map();   // board -> the depth of the run that draws its first round's types (none: the board has none)
  for (const board of model.boards) {
    const { boxOf } = drawn.get(board);
    const first = [...boxOf.keys()].map((t) => model.node(t)).filter((n) => isType(n) && rounds.get(n.key) === 0);
    if (first.length) typedDepth.set(board, Math.max(...first.map((n) => n.frames.length)));
  }
  // the run a shape is drawn in, by order: its depth for a shape, its board's types' depth for a type of the first round, after every board's shapes
  // for a later round's, and last for a note of a type
  const runOf = (t) => {
    const n = model.node(t);
    if (isInstance(n)) return Infinity;
    if (!isType(n)) return n.frames.length;
    return rounds.get(t) ? 1e6 + rounds.get(t) : typedDepth.get(n.board);
  };
  // the ends of a board's types of a round, in the run that draws them (an end's type is never in a round before its relationship type's)
  const ends = model.edges.filter((e) => e.end).sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to));
  const typeOfEnd = (e) => (model.node(e.from).relationship ? e.to : e.from);
  const endLines = (board, r, here) => (!here ? [] : ends.filter((e) => model.node(typeOfEnd(e)).board === board && rounds.get(typeOfEnd(e)) === r)
    .flatMap((e) => e.arrows.map((a) => said(`edge ${sp.name(e.from, board)} -> ${sp.name(e.to, board)}` + (a.text ? ` text: ${lit(a.text)}` : '') + arrowTyping(a), { edge: edgeSays(e, a, false) }))));
  const sortedOf = new Map(); // board -> its shapes' titles in the order they are drawn: by title
  for (const board of model.boards) sortedOf.set(board, [...drawn.get(board).boxOf.keys()].sort(byTitle));
  const stmts = new Map();
  for (const board of model.boards) {
    const { boxOf } = drawn.get(board);
    const stmt = (t) => {
      const n = model.node(t), b = boxOf.get(t);
      const parent = n.container[0] === 'f' ? n.container.slice(2) : null;
      const own = sp.own(t);
      let place;
      if (parent) { const pb = boxOf.get(parent); place = at(sp.name(parent, board, 'container'), b.x - pb.x, b.y - pb.y); }
      else place = fromOrigin(b);
      const head = `${own.name}${own.in ? ` in ${own.in}` : ''} ${place} size: ${b.w}x${b.h}`;
      const pub = publicSet.has(t) ? ' public: true' : '';
      const text = n.kind === 'frame' ? `frame ${head}`
        : n.kind === 'subboard' ? `subboard ${head}${pub}`
        : `sticky-note ${head}${pub}` + (n.text ? ` text: ${lit(n.text)}` : '') + noteTyping(n);
      return said(text, { shape: t });
    };
    stmts.set(board, stmt);
    const titles = sortedOf.get(board).filter((t) => runOf(t) < 1e6);
    // the ends of this board's types of the first round, after the shapes of the run that draws them
    const top = titles.filter((t) => runOf(t) === 0).map(stmt).concat(endLines(board, 0, typedDepth.get(board) === 0));
    if (top.length) addRun(board, 'top', top);
    const maxDepth = Math.max(0, ...titles.map(runOf));
    for (let d = 1; d <= maxDepth; d++) {
      const lines = titles.filter((t) => runOf(t) === d).map(stmt).concat(endLines(board, 0, typedDepth.get(board) === d));
      if (lines.length) addRun(board, 'in-' + d, lines);
    }
  }
  // the later rounds, after every board's shapes: a run for each board with types in the round, of them and the ends of its types of the round
  const lastRound = Math.max(0, ...rounds.values());
  for (let r = 1; r <= lastRound; r++) {
    for (const board of model.boards) {
      const lines = sortedOf.get(board).filter((t) => runOf(t) === 1e6 + r).map(stmts.get(board)).concat(endLines(board, r, true));
      if (lines.length) addRun(board, 'types-' + r, lines);
    }
  }
  for (const board of model.boards) {
    const lines = sortedOf.get(board).filter((t) => isInstance(model.node(t))).map(stmts.get(board));
    if (lines.length) addRun(board, 'notes', lines);
  }
  // a subboard's `text` is its description, and a frame or a subboard may be of types: each is written once every shape it may mention is drawn (a
  // mention names a shape of any board, in a run after its own) and every type it is has been (a type is found anywhere in the file), by a statement of
  // the shape with nothing else in it, which restates it as it is
  const subsOn = new Map();   // board -> its subboards that have a description and its frames and subboards of a type, by key (two shapes of one title are two)
  for (const n of model.nodes.values()) if ((n.kind === 'subboard' && n.text) || isTypedContainer(n)) subsOn.set(n.board, (subsOn.get(n.board) || []).concat([n.key]));
  const described = {};       // run -> the keys of the shapes it restates
  for (const board of model.boards) {
    const subs = (subsOn.get(board) || []).sort(byTitle);
    if (!subs.length) continue;
    addRun(board, 'describe', subs.map((t) => {
      const n = model.node(t);
      return said(`${n.kind} ${sp.name(t, board)}` + (n.kind === 'subboard' && n.text ? ` description: ${lit(n.text)}` : '') + (isTypedContainer(n) ? noteTyping(n) : ''), { describe: t });
    }));
    described[runs[runs.length - 1].name] = subs;
  }
  if (Object.keys(described).length) plan.described = described;
  // edge runs, after every shape that is to be public is. In a run, a start's pills in the order of its column come first (the host's
  // edge of a shared group is among them, so the pill exists), then the edges of the users of a shared pill, then the plain arrows.
  for (const board of model.boards) {
    const { layout } = results.get(board);
    const { boxOf, dx, dy } = drawn.get(board);
    // a spine's shared pill is where its maker's edge says: at its offset from the top-left of the spine's frame, and in it, or, for a spine
    // that is the board itself, from the board's origin, as the shapes are placed
    const placed = (f) => {
      const p = layout.pills[f.at], cid = model.node(f.e.from).container;
      if (cid[0] === 'f') { const frame = cid.slice(2), fb = boxOf.get(frame), name = sp.name(frame, board, 'container'); return ` in ${name} ` + at(name, p.x + dx - fb.x, p.y + dy - fb.y); }
      return ' ' + fromOrigin({ x: p.x + dx, y: p.y + dy });
    };
    const lines = [];
    // an edge of a pair with typed arrows is a line for each arrow, saying what it is (draw reuses the pill the first made for the pair)
    const ends = (e) => {
      const from = sp.name(e.from, board), to = sp.name(e.to, board);
      // draw claims the far end's board hard when the start is named from the top of the board (`board >`), so such an edge can't leave its board
      if (from.startsWith('board >') && model.node(e.to).board !== board) throw new Error(`cannot name "${model.node(e.from).title}" (${label(e.from)}) as the start of an edge to another board: nothing but a path from the top of the first board tells it from the shapes with its title, and draw can't put an edge that leaves its board through one: give the shapes that hold it, or it, titles that tell them apart`);
      return `edge ${from} -> ${to}`;
    };
    const line = (e, head) => e.arrows.map((a) => said(`${ends(e)}${head}` + (a.text ? ` text: ${lit(a.text)}` : '') + arrowTyping(a), { edge: edgeSays(e, a, / via: reference/.test(head)) }));
    const starts = [...layout.plan.byStart.keys()].sort(byTitle);
    // the pills others share first (draw reuses the first pill made for an end in a container, so that has to be the host's), and a spine's,
    // then the other pills (a column's pills keep their order: the shared ones are first in it; a spine's left leaf's column is on its left,
    // `from: left`), then the users of a shared pill, each saying `share: "<host>"`
    for (const s of starts) for (const en of layout.plan.byStart.get(s)) if (en.shared) lines.push(...line(en.e, ' via: reference'));   // the host's own: a pill beside it (no share, so it is never another cluster's)
    for (const f of layout.plan.free.slice().sort((a, b) => byTitle(a.e.from, b.e.from) || byTitle(a.e.to, b.e.to))) lines.push(...line(f.e, ' via: reference' + placed(f)));   // a spine's shared pill, made where it goes
    const leftOf = new Set(layout.pills.filter((p) => p.left).map((p) => p.start + '\u0000' + p.target));
    for (const s of starts) for (const en of layout.plan.byStart.get(s)) if (!en.shared) lines.push(...line(en.e, ' via: reference' + (leftOf.has(en.e.from + '\u0000' + en.e.to) ? ' from: left' : '')));
    for (const m of layout.plan.members.slice().sort((a, b) => byTitle(a.e.from, b.e.from) || byTitle(a.e.to, b.e.to))) lines.push(...line(m.e, ` via: reference share: ${sp.name(m.host, board)}`));
    for (const e of layout.plan.direct.slice().sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to))) if (!e.end) lines.push(...line(e, ''));
    if (lines.length) addRun(board, 'edges', lines);
  }
  plan.runs = runs.map((r) => r.name);
  // what each run says, line by line, and the titles the scripts rely on the file not having: beside the plan (the plan is the same as before for a digest
  // whose titles are all unique and that has no ids), for matching a result's rows to the statements by their line
  const statements = { runs: {}, absent: [...sp.absent].sort(byTitle) };
  for (const r of runs) statements.runs[r.name] = { board: r.board, lines: r.lines };
  return { plan, runs, statements };
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
    return `board "${label(b)}" was laid out once and not searched: ${what}, and searching a board that crowded takes hours. Its arrows are drawn as arrows (those to other boards as pills), and it reads as a crowd: split it into subboards`;
  });
  // D11: the tool makes public only shapes it creates, and these are all of them
  return { title: model.title, public: pub, publicWhy: why, promotions: flat, boards, totals: total, timings, warnings: model.warnings.concat(crowded) };
}
