// How each board reads, measured on the drawing the app will get (drawing.json read back, with the measured sizes): lines that cross, lines over
// shapes, shapes on top of each other; and beside them the board's links, the links cut into pills, its pills, its size against the view and the
// seconds its layout took. The plan measures every board of every plan, whatever laid it out. A board that isn't clean is drawn all the same: the
// report says what fails, by key.
//   Every edge is a line, as the app draws it: straight, or bent (the app bends the second arrow between two shapes apart from the first, and the
//   rest after it, ArrowPairs.swift; and draws a relationship type's two ends as one arc through it, ArrowThrough, which the measurement names
//   as `lines`). A crossing: two lines that share no end and cross. A line runs over a shape when it passes within `margin` of a
//   shape, or of the room its title takes above it, that is not one of its ends (nor a frame that holds one); a note's lines into pills over
//   pills it uses itself (its own, and those it shares) are counted apart (`overOwnPills`) and fail nothing.
//   On top: two shapes that overlap, neither holding the other, or a shape on the room another's title takes above it (measure's `above`).
import { byTitle } from './util.mjs';
import { holdsShapes } from './model.mjs';
import { pillKey } from './sizes.mjs';
import { arrowPath, segCross, segHitsBox, cellsAlong, cellsOf, isStraightThrough, throughBend } from './geom.mjs';

/**
 * The measures' constants: how near a line may pass a shape (units), how far two shapes may overlap, an arc's samples, the grid's cell, the examples
 * kept, and how far the app bows each further arrow between one pair of shapes (`ArrowStyle.pairBend`).
 */
export const HEALTH = { margin: 8, overlap: 1, samples: 16, cell: 320, examples: 5, pairBend: 34 };

const q = (k) => JSON.stringify(k);
const hit = (a, b, g) => a.x < b.x + b.w - g && b.x < a.x + a.w - g && a.y < b.y + b.h - g && b.y < a.y + a.h - g;
/** The room a shape's title takes above it: as wide as its title, as the measurement says (else as wide as the shape). */
const tabOf = (box, above, width) => (above > 0 ? { x: box.x, y: box.y - above, w: width > 0 ? Math.min(box.w, width) : box.w, h: above } : null);

/**
 * The drawing's boards as the app will draw them, each in its board's coordinates: `shapes` (every node: its box, the frames it is in, the room
 * its title takes above it), `pills` (each where its edge places it, as wide as the measurement says for what it stands for and where it is),
 * `lines` (each edge's: an arrow between two nodes, or from a node into a pill) and `links` (each pair of nodes on the board an edge joins, and
 * whether one of its edges is drawn as an arrow). `bendOf(edge)` is how far an edge of drawing.json is bent (none: the tool draws every line straight),
 * and an edge with none that joins two shapes another edge joins already is bowed apart from it as the app bows it: the lowest slot the pair's lines
 * don't hold, 0, +1, -1, +2, ... times `pairBend`, the way it runs (the app tells it by the shapes' ids, which the tool has none of: by their keys).
 * The two halves of a line through a node (`sizes.lines`) are one arc where the app draws them so (`throughLines`).
 */
export function readDrawing(model, drawing, sizes, bendOf) {
  const place = new Map((drawing.nodes || []).map((n) => [n.key, n.place]));
  const abs = new Map();
  const boxOf = (key) => {
    if (abs.has(key)) return abs.get(key);
    const n = model.node(key), pl = place.get(key);
    let b = null;
    if (n && pl && Array.isArray(pl.at) && Array.isArray(pl.size)) {
      const f = n.container[0] === 'f' ? boxOf(n.container.slice(2)) : { x: 0, y: 0 };
      if (f) b = { x: f.x + pl.at[0], y: f.y + pl.at[1], w: pl.size[0], h: pl.size[1] };
    }
    abs.set(key, b);
    return b;
  };
  const boards = new Map(model.boards.map((b) => [b, { board: b, shapes: [], pills: [], lines: [], links: new Map() }]));
  for (const raw of drawing.nodes || []) {
    const n = model.node(raw.key), box = boxOf(raw.key);
    if (!n || !box) continue;
    const frame = holdsShapes(n), s = frame ? sizes.frames[n.key] : sizes.shapes[n.key];
    boards.get(n.board).shapes.push({ id: n.key, frame, box, tab: tabOf(box, (s && s.above) || 0, (s && s.titleWidth) || 0), frames: n.frames, name: q(n.key) });
  }
  // the pills, by their host's own edge (the one that places the pill), keyed by host and what the pill stands for
  const pills = new Map();
  for (const e of drawing.edges || []) {
    const p = e.place && e.place.pill, host = model.node(e.from);
    if (!p || !Array.isArray(p.at) || !host || !model.node(e.to)) continue;
    const f = p.in != null ? boxOf(p.in) : { x: 0, y: 0 };
    if (!f) continue;
    const w = sizes.pillWidth[pillKey(e.to, p.in != null ? 'f:' + p.in : 'b:' + host.board)] || sizes.pillWidth[e.to] || 120;
    const pill = {
      id: '\u0001' + e.from + '\u0000' + e.to, host: e.from, target: e.to, users: new Set(), box: { x: f.x + p.at[0], y: f.y + p.at[1], w, h: sizes.constants.pillHeight },
      frames: p.in != null ? model.node(p.in).frames.concat([p.in]) : [], name: `the pill for ${q(e.to)} beside ${q(e.from)}`,
    };
    pills.set(e.from + '\u0000' + e.to, pill);
    boards.get(host.board).pills.push(pill);
  }
  const addLine = lineAdder();
  for (const e of drawing.edges || []) {
    const a = model.node(e.from), b = model.node(e.to);
    if (!a || !b || a === b) continue;
    const p = e.place && e.place.pill, bend = (bendOf && +bendOf(e)) || 0, board = boards.get(a.board), A = boxOf(a.key);
    if (a.board === b.board) {
      const k = [a.key, b.key].sort(byTitle).join('\u0000');
      if (!board.links.has(k)) board.links.set(k, { arrow: false });
      if (!p) board.links.get(k).arrow = true;
    }
    if (!A) continue;
    if (!p) {
      const B = boxOf(b.key);
      if (a.board !== b.board || !B) continue;
      addLine(board, { a: a.key, b: b.key, A, B, edge: [e.from, e.to], intoPill: false, holders: new Set(framesOf(a).concat(framesOf(b))), name: `${q(a.key)} -> ${q(b.key)}` }, bend);
      continue;
    }
    const pill = pills.get((p.share != null ? p.share : e.from) + '\u0000' + e.to);
    if (!pill) continue;
    pill.users.add(a.key);
    addLine(board, { a: a.key, b: pill.id, A, B: pill.box, edge: [e.from, e.to], intoPill: true, holders: new Set(framesOf(a).concat(pill.frames)), name: `${q(a.key)} -> ${pill.host === a.key ? `its pill for ${q(e.to)}` : pill.name}` }, bend);
  }
  throughLines(boards, sizes.lines || []);
  return boards;
}

const framesOf = (n) => (holdsShapes(n) ? n.frames.concat([n.key]) : n.frames);

/**
 * What adds a line to a board as the app draws it: an edge bent its own way keeps its bend; one with none that joins two shapes another
 * line joins already takes the lowest slot the pair's lines don't hold (0, +1, -1, +2, ... times `pairBend`, the way it runs: by key).
 */
function lineAdder() {
  const held = new Map();   // a pair of ends -> the slots its lines hold
  return (board, line, bent) => {
    const pair = [line.a, line.b].sort(byTitle).join('\u0000'), forward = line.a <= line.b;
    if (!held.has(pair)) held.set(pair, new Set());
    const slots = held.get(pair);
    if (bent) {
      const ratio = bent / HEALTH.pairBend, steps = ratio * (forward ? 1 : -1);
      if (ratio === Math.round(ratio)) slots.add(steps > 0 ? 2 * steps - 1 : -2 * steps);
      line.bend = bent;
    } else {
      let k = 0;
      while (slots.has(k)) k++;
      slots.add(k);
      const steps = k % 2 ? (k + 1) / 2 : -(k / 2);
      line.bend = (forward ? steps : -steps) * HEALTH.pairBend;
    }
    line.path = arrowPath(line.A, line.B, line.bend, HEALTH.samples);
    line.board = board.board;
    board.lines.push(line);
  };
}

/**
 * One board as a layout of the Layouter's has it (layout.mjs: its boxes, frames, pills and plan), read as `readDrawing` reads drawing.json,
 * for a loop that measures a layout before it is a drawing (cut.mjs). Every document edge is a line, as in the drawing; each keeps `key`,
 * the link it draws (its ends), and `cuttable`, whether making that link a pill takes the line away (a plain arrow not marked direct,
 * into a shape a pill may stand for: cut.mjs's `cuttable`).
 */
export function readLayout(model, layout, sizes) {
  const B = { board: layout.board, shapes: [], pills: [], lines: [], links: new Map() };
  const boxOf = (k) => layout.boxes.get(k) || layout.frames.get(k);
  for (const [k, box] of layout.boxes) { const s = sizes.shapes[k]; B.shapes.push({ id: k, frame: false, box, tab: tabOf(box, (s && s.above) || 0, (s && s.titleWidth) || 0), frames: model.node(k).frames, name: q(k) }); }
  for (const [k, box] of layout.frames) { const s = sizes.frames[k]; B.shapes.push({ id: k, frame: true, box, tab: tabOf(box, (s && s.above) || 0, (s && s.titleWidth) || 0), frames: model.node(k).frames, name: q(k) }); }
  B.pills = layout.pills.map((p, i) => ({ id: '\u0001' + i, host: p.start, target: p.target, users: new Set(), group: p.free ? p.group : null, box: { x: p.x, y: p.y, w: p.w, h: p.h }, frames: model.node(p.start).frames, name: `the pill for ${q(p.target)} beside ${q(p.start)}` }));
  const own = new Map();
  layout.pills.forEach((p, i) => { if (!p.free) own.set(p.start + '\u0000' + p.target, i); });
  const add = lineAdder();
  const link = (e, arrow) => {
    if (model.node(e.to).board !== layout.board) return;
    const k = [e.from, e.to].sort(byTitle).join('\u0000');
    if (!B.links.has(k)) B.links.set(k, { arrow: false });
    if (arrow) B.links.get(k).arrow = true;
  };
  for (const e of layout.plan.direct) {
    const A = boxOf(e.from), Bx = boxOf(e.to);
    link(e, true);
    if (!A || !Bx || e.from === e.to) continue;
    const holders = new Set(framesOf(model.node(e.from)).concat(framesOf(model.node(e.to))));
    for (let i = 0; i < Math.max(1, e.items.length); i++) {
      add(B, { a: e.from, b: e.to, A, B: Bx, edge: [e.from, e.to], key: e.from + '\u0000' + e.to, cuttable: !e.direct && !model.node(e.to).never, intoPill: false, holders, name: `${q(e.from)} -> ${q(e.to)}` }, 0);
    }
  }
  // a line into a pill; one into a shared pill is `unsharable`: its user may be given a pill of its own instead (cut.mjs)
  const into = (e, at, shared) => {
    link(e, false);
    const pill = B.pills[at], A = boxOf(e.from);
    if (!pill || !A) return;
    pill.users.add(e.from);
    for (let i = 0; i < Math.max(1, e.items.length); i++) {
      add(B, { a: e.from, b: pill.id, A, B: pill.box, edge: [e.from, e.to], key: e.from + '\u0000' + e.to, cuttable: false, unsharable: shared, intoPill: true, holders: new Set(framesOf(model.node(e.from)).concat(pill.frames)), name: `${q(e.from)} -> ${pill.host === e.from ? `its pill for ${q(e.to)}` : pill.name}` }, 0);
    }
  };
  for (const list of layout.plan.byStart.values()) for (const en of list) into(en.e, own.get(en.e.from + '\u0000' + en.e.to), false);
  for (const x of layout.plan.members) into(x.e, x.pill, true);
  for (const f of layout.plan.free) into(f.e, f.at, true);
  throughLines(new Map([[B.board, B]]), sizes.lines || []);
  return B;
}

const centre = (b) => [b.x + b.w / 2, b.y + b.h / 2];

/**
 * The halves of a line through a node, drawn as the app draws them (Arrows' ArrowEndLine, ArrowThrough): where both are arrows into the node
 * itself (the first's end there, the second's start; one through a pill that stands for the node is no half), on one board, and their far ends
 * are two shapes, each is its part of the circle through the far ends' middles and the node's, the arc away from the other's far end; straight
 * where the three are on a line. `lines` are `sizes.lines`: each half by the ends of its edge.
 */
function throughLines(boards, lines) {
  if (!lines.length) return;
  const byEdge = new Map();
  for (const B of boards.values()) for (const l of B.lines) { const k = l.edge.join('\u0000'); if (!byEdge.has(k)) byEdge.set(k, l); }
  for (const line of lines) {
    const first = byEdge.get(line.first.join('\u0000')), second = byEdge.get(line.second.join('\u0000'));
    if (!first || !second || first.b !== line.through || second.a !== line.through || first.board !== second.board || first.a === second.b) continue;
    const here = centre(first.A), hub = centre(first.B), there = centre(second.B);
    const straight = isStraightThrough(here, hub, there);
    first.bend = straight ? 0 : throughBend(here, hub, there);
    second.bend = straight ? 0 : throughBend(hub, there, here);
    first.path = arrowPath(first.A, first.B, first.bend, HEALTH.samples);
    second.path = arrowPath(second.A, second.B, second.bend, HEALTH.samples);
  }
}

/** Index items by the cells their boxes cover: cell key -> item indexes, in order. */
function gridOf(boxes, cell) {
  const grid = new Map();
  boxes.forEach((b, i) => cellsOf(b.x, b.y, b.x + b.w, b.y + b.h, cell, (k) => { let l = grid.get(k); if (!l) grid.set(k, l = []); l.push(i); }));
  return grid;
}

/**
 * One board's health: what fails (crossings, lines over shapes, shapes on top), the rest of what the report says of it, and a few examples
 * by key. With `collect`, also `conflicts`: for each crossing the two lines' indexes, for each line over a shape that line's (what cutting
 * a link can mend; shapes on top it can't).
 */
export function boardHealth(B, view, seconds, collect) {
  const conflicts = collect ? [] : null;
  if (conflicts) { conflicts.over = new Map(); conflicts.solid = new Map(); }   // a conflict's index -> the shared pill it runs over (its group); -> the shape or pill (its id) a line runs over
  const { margin, overlap, cell } = HEALTH;
  const examples = [];
  // crossings: every segment of every line on a grid, each pair of lines that share no end counted once
  const segs = [];
  B.lines.forEach((l, i) => { for (let j = 1; j < l.path.length; j++) segs.push({ x1: l.path[j - 1][0], y1: l.path[j - 1][1], x2: l.path[j][0], y2: l.path[j][1], line: i }); });
  const sgrid = new Map();
  segs.forEach((s, i) => cellsAlong(s, cell, (k) => { let l = sgrid.get(k); if (!l) sgrid.set(k, l = []); l.push(i); }));
  const crossed = new Set(), n = B.lines.length;
  for (const list of sgrid.values()) {
    for (let x = 0; x < list.length; x++) for (let y = x + 1; y < list.length; y++) {
      const s = segs[list[x]], t = segs[list[y]];
      if (s.line === t.line) continue;
      const i = Math.min(s.line, t.line), j = Math.max(s.line, t.line), key = i * n + j;
      if (crossed.has(key)) continue;
      const L = B.lines[i], M = B.lines[j];
      if (L.a === M.a || L.a === M.b || L.b === M.a || L.b === M.b) continue;
      if (segCross(s, t)) { crossed.add(key); examples.push([0, `${L.name} crosses ${M.name}`]); if (conflicts) conflicts.push([i, j]); }
    }
  }
  // lines over shapes: notes, cards, frames (each with the room its title takes above it) and pills, each grown by the margin
  const solids = B.shapes.map((s) => ({ id: s.id, box: s.box, tab: s.tab, frame: s.frame, name: s.name })).concat(B.pills.map((p) => ({ id: p.id, box: p.box, users: p.users, group: p.group, name: p.name })));
  const ogrid = gridOf(solids.map((s) => { const t = s.tab ? s.tab.h : 0; return { x: s.box.x - margin, y: s.box.y - t - margin, w: s.box.w + 2 * margin, h: s.box.h + t + 2 * margin }; }), cell);
  let overShapes = 0, overOwnPills = 0;
  B.lines.forEach((l, i) => {
    const near = new Set();
    for (let j = 1; j < l.path.length; j++) cellsAlong({ x1: l.path[j - 1][0], y1: l.path[j - 1][1], x2: l.path[j][0], y2: l.path[j][1] }, cell, (k) => { for (const s of ogrid.get(k) || []) near.add(s); });
    for (const si of [...near].sort((x, y) => x - y)) {
      const s = solids[si];
      if (s.id === l.a || s.id === l.b || (s.frame && l.holders.has(s.id))) continue;
      let over = false;
      for (let j = 1; j < l.path.length && !over; j++) {
        const seg = { x1: l.path[j - 1][0], y1: l.path[j - 1][1], x2: l.path[j][0], y2: l.path[j][1] };
        over = segHitsBox(seg, s.box, -margin) || (!!s.tab && segHitsBox(seg, s.tab, -margin));
      }
      if (!over) continue;
      if (l.intoPill && s.users && s.users.has(l.a)) { overOwnPills++; continue; }
      overShapes++;
      examples.push([1, `${l.name} runs over ${s.name}`]);
      // a line over a pill several notes share (`group`, its target and container): share.mjs gives that pill up
      if (conflicts) { if (s.group) conflicts.over.set(conflicts.length, s.group); conflicts.solid.set(conflicts.length, s.id); conflicts.push([i]); }
    }
  });
  // shapes on top: two that overlap, neither holding the other, or one on the room another's title takes above it
  const all = B.shapes.concat(B.pills);
  const foot = all.map((s) => (s.tab ? { x: s.box.x, y: s.tab.y, w: s.box.w, h: s.box.h + s.tab.h } : s.box));
  const fgrid = gridOf(foot, cell);
  const holds = (f, s) => f.frame === true && s.frames.indexOf(f.id) >= 0;
  const seen = new Set();
  let onTop = 0;
  for (const list of fgrid.values()) {
    for (let x = 0; x < list.length; x++) for (let y = x + 1; y < list.length; y++) {
      const i = Math.min(list[x], list[y]), j = Math.max(list[x], list[y]), key = i * all.length + j;
      if (seen.has(key)) continue;
      seen.add(key);
      const a = all[i], b = all[j];
      if (holds(a, b) || holds(b, a)) continue;
      if (hit(a.box, b.box, overlap)) { onTop++; examples.push([2, `${a.name} is on ${b.name}`]); }
      else if (b.tab && hit(a.box, b.tab, overlap)) { onTop++; examples.push([2, `${a.name} is on the title of ${b.name}`]); }
      else if (a.tab && hit(b.box, a.tab, overlap)) { onTop++; examples.push([2, `${b.name} is on the title of ${a.name}`]); }
    }
  }
  // the board's size, every shape with its title's room, every pill and every line (an arc may loop past them all), against the view: the
  // zoom a window fit to it shows it at
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const b of foot) { x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); }
  for (const l of B.lines) for (const p of l.path) { x0 = Math.min(x0, p[0]); y0 = Math.min(y0, p[1]); x1 = Math.max(x1, p[0]); y1 = Math.max(y1, p[1]); }
  const w = all.length ? Math.round(x1 - x0) : 0, h = all.length ? Math.round(y1 - y0) : 0;
  const fit = w > 0 && h > 0 ? Math.round(100 * Math.min(1, view.w / w, view.h / h)) / 100 : 1;
  let cut = 0;
  for (const link of B.links.values()) if (!link.arrow) cut++;
  examples.sort((p, r) => p[0] - r[0] || byTitle(p[1], r[1]));
  const health = {
    status: crossed.size + overShapes + onTop === 0 ? 'clean' : 'not clean',
    crossings: crossed.size, overShapes, onTop, overOwnPills,
    links: B.links.size, cut, pills: B.pills.length,
    size: [w, h], fit, seconds: Math.round((seconds || 0) / 100) / 10,
    examples: examples.slice(0, HEALTH.examples).map((x) => x[1]),
  };
  if (conflicts) Object.defineProperty(health, 'conflicts', { value: conflicts, enumerable: false });
  return health;
}

/**
 * Every board's health on a drawing (buildDrawing's, or drawing.json as read): {boards: {board: health}, totals}. `opts.view` is the view the
 * boards were laid out for ({w, h}), `opts.ms` each board's layout time (a Map, milliseconds), `opts.bendOf` how far an edge is bent (none: straight).
 */
export function healthOf(model, drawing, sizes, opts = {}) {
  const view = opts.view || { w: 1440, h: 960 };
  const boards = readDrawing(model, drawing, sizes, opts.bendOf);
  const out = {};
  const totals = { boards: 0, clean: 0, crossings: 0, overShapes: 0, onTop: 0, overOwnPills: 0, links: 0, cut: 0, pills: 0, margin: HEALTH.margin };
  for (const b of model.boards) {
    const h = boardHealth(boards.get(b), view, opts.ms ? opts.ms.get(b) : 0);
    out[b] = h;
    totals.boards++;
    if (h.status === 'clean') totals.clean++;
    for (const k of ['crossings', 'overShapes', 'onTop', 'overOwnPills', 'links', 'cut', 'pills']) totals[k] += h[k];
  }
  return { boards: out, totals };
}

/** What fails on a board, in a few words ("3 crossings, 1 over shapes"), the most first in `healthLines`. */
const fails = (h) => h.crossings + h.overShapes + h.onTop;
const failText = (h) => [[h.crossings, 'crossings'], [h.overShapes, 'over shapes'], [h.onTop, 'on top']].filter((x) => x[0]).map((x) => `${x[0]} ${x[1]}`).join(', ');

/** The summary's lines: how many boards are clean and what fails in all, then the least clean boards (five, and how many more). */
export function healthLines(report) {
  const t = report.health;
  if (!t) return [];
  const lines = [`health: ${t.clean} of ${t.boards} board(s) clean; ${t.crossings} crossings, ${t.overShapes} lines over shapes, ${t.onTop} shapes on top of others`];
  const bad = Object.entries(report.boards).filter(([, x]) => x.health && x.health.status !== 'clean')
    .sort(([a, x], [b, y]) => fails(y.health) - fails(x.health) || byTitle(a, b));
  if (bad.length) lines.push('not clean: ' + bad.slice(0, 5).map(([b, x]) => `${b} (${failText(x.health)})`).join('; ') + (bad.length > 5 ? `; and ${bad.length - 5} more (report.json's boards)` : ''));
  return lines;
}
