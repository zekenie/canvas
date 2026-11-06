// The plan: every shape's box and every pill's place from each board's layout (`buildBoards`, the layout's own record), and the apply document
// (`buildDrawing`: the graph document as given, each node with the place of its room and its size, each edge through a pill with the pill's
// place). Nothing is shifted: a place is from its frame's top-left, or from its board's origin, and may be negative.
import { byTitle } from './util.mjs';
import { fanTargets } from './moves.mjs';

/** What the plan makes public by its moves: the promoted nodes, and what the fanned-out nodes' pills stand for. */
export function madePublic(model, results) {
  const made = new Map();   // key -> why
  for (const r of results.values()) {
    for (const t of r.report.promoted) if (!made.has(t)) made.set(t, 'promoted: its users reach it through pills');
    for (const v of r.report.fanned || []) for (const t of fanTargets(model, v)) if (!made.has(t)) made.set(t, `${v} uses it, and points at so many shapes that its uses are pills beside it (fanned out)`);
    for (const x of r.report.long || []) if (!made.has(x.to)) made.set(x.to, `an arrow to it would run ${x.length} units, longer than the dial allows, so it is a pill`);
    for (const t of (r.layout && r.layout.plan.spined) || []) if (!made.has(t)) made.set(t, 'cards that point at many of the same shapes reach it through a pill (a spine)');
  }
  return made;
}

/** What is public by the document's own say: the far end of an edge between boards, and a pinned node, the latter only when a pill in the layout stands for it. */
function forcedPublic(model, results) {
  const pilled = new Set();
  for (const r of results.values()) for (const p of r.layout.pills) pilled.add(p.target);
  return [...model.forcedPublic].filter((t) => !model.node(t).pin || pilled.has(t));
}

/** The pill an edge's layout entry has: its host's own, one it shares, or a spine's, with whose pill it is. */
function pillRoles(layout) {
  const roles = new Map();   // pair edge -> {at: pill index} | {share: host key}
  for (const l of layout.plan.byStart.values()) for (const en of l) roles.set(en.e, { at: layout.pills.findIndex((p) => p.start === en.e.from && p.target === en.e.to && !p.free) });
  for (const f of layout.plan.free) roles.set(f.e, { at: f.at });
  for (const m of layout.plan.members) roles.set(m.e, { share: m.host });
  return roles;
}

/** Every board's shapes and pills as the layout has them, in the board's own coordinates, and the moves the loop made: the plan the tests read. */
export function buildBoards(model, results, opts) {
  const publicSet = new Set([...forcedPublic(model, results), ...madePublic(model, results).keys()]);
  const shown = Object.assign({}, opts); delete shown.kinds; delete shown.current; delete shown.progress;
  const plan = { drawing: model.drawing, options: shown, boards: [], promotions: [], stop: {}, cost: {}, public: [...publicSet].sort(byTitle) };
  for (const board of model.boards) {
    const { layout } = results.get(board);
    const shapes = [];
    for (const [t, b] of [...layout.boxes, ...layout.frames].sort((x, y) => byTitle(x[0], y[0]))) {
      const n = model.node(t);
      shapes.push({ key: t, kind: n.kind, in: n.container[0] === 'f' ? n.container.slice(2) : null, x: b.x, y: b.y, w: b.w, h: b.h });
    }
    const pills = layout.pills.map((p) => ({ start: p.start, for: p.target, x: p.x, y: p.y, w: p.w, h: p.h, users: p.users }))
      .sort((a, b) => byTitle(a.start, b.start) || a.y - b.y);
    // an edge through a pill: the host's edge first and every edge of a shared group saying share: true; `host` is whose column the pill is in
    const edges = [];
    const leftOf = new Set(layout.pills.filter((p) => p.left).map((p) => p.start + '\u0000' + p.target));   // pills in a column on their start's left
    for (const l of layout.plan.byStart.values()) for (const en of l) edges.push(Object.assign({ from: en.e.from, to: en.e.to, via: 'pill' }, en.shared ? { share: true, host: en.e.from } : {}, leftOf.has(en.e.from + '\u0000' + en.e.to) ? { side: 'left' } : {}));
    for (const f of layout.plan.free) edges.push({ from: f.e.from, to: f.e.to, via: 'pill', share: true, host: f.e.from });
    for (const m of layout.plan.members) edges.push({ from: m.e.from, to: m.e.to, via: 'pill', share: true, sharedWith: m.host, host: m.host });
    for (const e of layout.plan.direct) edges.push({ from: e.from, to: e.to, via: null });
    edges.sort((a, b) => byTitle(a.from, b.from) || byTitle(a.to, b.to));
    plan.boards.push({ board, shapes, pills, edges });
    const r = results.get(board).report;
    for (const p of r.promotions) plan.promotions.push(p);
    plan.stop[board] = r.stop;
    plan.cost[board] = { start: r.start, end: r.end };
  }
  return plan;
}

/**
 * The apply document: the graph document as given, each node with `place` ({at: [x, y] from its frame's top-left, or from its board's origin;
 * size: [w, h]}), each edge the layout draws through a pill with `place.pill` ({at, in}: where the pill is, from its frame's top-left or the
 * board's origin; {share: the host node's key}: into the pill that node's own edge goes into). Edges the model left out are not in it. An edge
 * with no place is drawn as an arrow between its ends. What `props` and `layout` hold passes through as parsed.
 */
export function buildDrawing(model, graph, results) {
  const boxOf = new Map();   // key -> {x, y, w, h} in its board's coordinates
  for (const { layout } of results.values()) { for (const [t, b] of layout.boxes) boxOf.set(t, b); for (const [t, b] of layout.frames) boxOf.set(t, b); }
  const rel = (n, b) => {
    if (n.container[0] !== 'f') return [b.x, b.y];
    const f = boxOf.get(n.container.slice(2));
    return [b.x - f.x, b.y - f.y];
  };
  const nodes = (graph.nodes || []).map((raw) => {
    const n = model.node(raw.key), b = boxOf.get(n.key);
    return Object.assign({}, raw, { place: { at: rel(n, b), size: [b.w, b.h] } });
  });
  // each edge of the document by its place in the list: the pill it goes through, or none
  const roles = new Map();   // document edge index -> place.pill
  for (const board of model.boards) {
    const { layout } = results.get(board);
    for (const [e, role] of pillRoles(layout)) {
      e.items.forEach((index, k) => {
        if (role.share != null) { roles.set(index, { share: role.share }); return; }
        if (k > 0) { roles.set(index, { share: e.from }); return; }
        const p = layout.pills[role.at], start = model.node(e.from);
        const pill = { at: null };
        if (start.container[0] === 'f') { const f = boxOf.get(start.container.slice(2)); pill.at = [p.x - f.x, p.y - f.y]; pill.in = start.container.slice(2); }
        else pill.at = [p.x, p.y];
        roles.set(index, pill);
      });
    }
  }
  const hosts = [], users = [];
  (graph.edges || []).forEach((raw, index) => {
    if (model.dropped.has(index)) return;
    const pill = roles.get(index);
    const edge = pill ? Object.assign({}, raw, { place: { pill } }) : Object.assign({}, raw);
    (pill && pill.share != null ? users : hosts).push(edge);
  });
  const out = { drawing: graph.drawing };
  if (graph.layout) out.layout = graph.layout;
  out.nodes = nodes;
  out.edges = hosts.concat(users);
  return out;
}

export function buildReport(model, results, timings) {
  const boards = {};
  for (const [b, r] of results) boards[b] = r.report;
  const flat = [];
  for (const r of results.values()) for (const p of r.report.promotions) flat.push(p);
  const total = { pills: 0, arrows: 0, sharedArrows: 0 };
  for (const r of results.values()) { total.pills += r.report.end.pills; total.arrows += r.report.end.arrows; total.sharedArrows += r.report.end.sharedArrows; }
  const made = madePublic(model, results);
  const pub = [...new Set([...forcedPublic(model, results), ...made.keys()])].sort(byTitle);
  const why = {};
  for (const t of pub) why[t] = model.publicWhy.get(t) || made.get(t);
  // a board too crowded to search (promote.mjs's CROWD) is said, with the way out: the plan holds, and the board reads as a crowd
  const crowded = [...results].filter(([, r]) => r.report.crowded).map(([b, r]) => {
    const c = r.report.crowded;
    const what = c.shapes > c.mostShapes ? `it holds ${c.shapes} shapes, past ${c.mostShapes}` : `${c.container ? `its frame "${c.container}"` : 'it'} holds ${c.children} shapes side by side, past ${c.most}`;
    return `board "${b}" was laid out once and not searched: ${what}, and searching a board that crowded takes hours. Its arrows are drawn as arrows (those to other boards as pills), and it reads as a crowd: split it into subboards`;
  });
  return { drawing: model.drawing, public: pub, publicWhy: why, promotions: flat, boards, totals: total, timings, warnings: model.warnings.concat(crowded) };
}
