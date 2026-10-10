// plan.json and the draw scripts. Every shape at an exact offset from its container's top-left (the header note
// for the board itself), frames at their final size, shapes made public one run before the edges through them.
import { q, lit, byTitle, slug, pad2, fold } from './util.mjs';
import { headerText, HEADER_W } from './sizes.mjs';
import { fanTargets } from './moves.mjs';

/** What the plan makes public by its moves: the promoted nodes, and what the fanned-out nodes' pills stand for. */
export function madePublic(model, results) {
  const made = new Map();   // title -> why
  for (const r of results.values()) {
    for (const t of r.report.promoted) if (!made.has(t)) made.set(t, 'promoted: its users reach it through pills');
    for (const v of r.report.fanned || []) for (const t of fanTargets(model, v)) if (!made.has(t)) made.set(t, `${v} uses it, and points at so many shapes that its uses are pills beside it (fanned out)`);
    for (const x of r.report.long || []) if (!made.has(x.to)) made.set(x.to, `an arrow to it would run ${x.length} units, longer than the dial allows, so it is a pill`);
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
    const dy = hh + 80;
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
    const edges = [];
    for (const l of layout.plan.byStart.values()) for (const en of l) edges.push(Object.assign({ from: en.e.from, to: en.e.to, via: 'reference' }, en.shared ? { share: true, host: en.e.from } : {}));
    for (const m of layout.plan.members) edges.push({ from: m.e.from, to: m.e.to, via: 'reference', share: true, sharedWith: m.host, host: m.host });
    for (const e of layout.plan.direct) edges.push({ from: e.from, to: e.to, via: null });
    edges.sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to));
    plan.boards.push({ board, origin: hdrTitle, shapes, pills, edges });
    drawn.set(board, { boxOf, hdrTitle });
    const r = results.get(board).report;
    for (const p of r.promotions) plan.promotions.push(p);
    plan.stop[board] = r.stop;
    plan.cost[board] = { start: r.start, end: r.end };
  }

  // shape runs, board by board: the header and what is on the board itself, then what is in the frames, a depth at a time
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
      return `sticky-note ${q(t)}${inClause(parent || holder)} ${place} size: ${b.w}x${b.h}${pub}` + (n.text ? ` text: ${lit(n.text)}` : '');
    };
    const titles = [...boxOf.keys()].sort(byTitle);
    const hs = sizes.shapes[hdrTitle];
    const header = `sticky-note ${q(hdrTitle)}${inClause(holder)} size: ${Math.ceil(hs.w)}x${Math.ceil(hs.h)} text: ${lit(headerText(model, board))}`;
    addRun(board, 'top', [header].concat(titles.filter((t) => model.node(t).frames.length === 0).map(stmt)));
    const maxDepth = Math.max(0, ...titles.map((t) => model.node(t).frames.length));
    for (let d = 1; d <= maxDepth; d++) addRun(board, 'in-' + d, titles.filter((t) => model.node(t).frames.length === d).map(stmt));
  }
  // edge runs, after every shape that is to be public is. In a run, a start's pills in the order of its column come first (the host's
  // edge of a shared group is among them, so the pill exists), then the edges of the users of a shared pill, then the plain arrows.
  for (const board of model.boards) {
    const { layout } = results.get(board);
    const lines = [];
    const text = (e) => (e.text ? ` text: ${lit(e.text)}` : '');
    const starts = [...layout.plan.byStart.keys()].sort(byTitle);
    // the pills others share first (draw reuses the first pill made for an end in a container, so that has to be the host's), then the other
    // pills (a column's pills keep their order: the shared ones are first in it), then the users of a shared pill, each saying `share: "<host>"`
    for (const s of starts) for (const en of layout.plan.byStart.get(s)) if (en.shared) lines.push(`edge ${q(en.e.from)} -> ${q(en.e.to)} via: reference` + text(en.e));   // the host's own: a pill beside it (no share, so it is never another cluster's)
    for (const s of starts) for (const en of layout.plan.byStart.get(s)) if (!en.shared) lines.push(`edge ${q(en.e.from)} -> ${q(en.e.to)} via: reference` + text(en.e));
    for (const m of layout.plan.members.slice().sort((a, b) => byTitle(a.e.from, b.e.from) || byTitle(a.e.to, b.e.to))) lines.push(`edge ${q(m.e.from)} -> ${q(m.e.to)} via: reference share: ${q(m.host)}` + text(m.e));
    for (const e of layout.plan.direct.slice().sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to))) lines.push(`edge ${q(e.from)} -> ${q(e.to)}` + text(e));
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
  // D11: the tool makes public only shapes it creates, and these are all of them
  return { title: model.title, public: pub, publicWhy: why, promotions: flat, boards, totals: total, timings, warnings: model.warnings };
}
