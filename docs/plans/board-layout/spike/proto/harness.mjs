// The prototype harness: the real boards (graph.json, measure.json, kinds.json) as a model a layout can read, a renderer that draws any
// layout of a board as an SVG in the app's look (light appearance, colors sampled from the app's own captures), and the measures every
// strategy is judged by. Every prototype uses this, so every render and number is comparable.
//
//   import { load, renderBoard, measure, layoutFromDrawing, svgToPng } from './harness.mjs'
//   const m = load('/path/to/data')                       // the model
//   m.boardOf(key), m.node(key), m.board('root').top, m.kids(frameKey), m.edgesOn('module:Draw'), m.pillSize(target, fromKey)
//
// A layout of one board (absolute board coordinates, y down):
//   { boxes: { [key]: {x, y, w, h} },                     // every frame, note and card on the board
//     pills: [ {id, for: targetKey, x, y, w, h} ],        // reference pills: stand for `for` (a shape on this board or another)
//     arrows: [ {from, to, points?, bend?, color?, label?} ] }
//         from/to: a key in boxes or a pill id. points: a routed path [[x,y], ...] from the start's border to the end's border (drawn
//         with rounded corners); else bend: the app's arc (0 or none: straight), drawn as the app draws it, between the two centers.
import fs from 'fs';
import { execFileSync } from 'child_process';

export const LOOK = {
  canvas: '#F6F6F6', dot: '#DCDCDC', frame: '#FFFFFF', frameStroke: '#D4D4D4', tab: '#3A3A3A', tabInk: '#FFFFFF', ink: '#1F1F1F', faint: '#6B6B6B',
  arrow: '#1C1C1C', card: '#FAFAFF', cardStroke: '#6F67D9',
  // a note's fill by its type, the pill standing for it a lighter tint with a deeper border
  types: {
    'type:File': { fill: '#FFD2DB', pill: '#F2DBE3', stroke: '#C9577A' },
    'type:Plugin': { fill: '#CAE2FF', pill: '#DCE8F8', stroke: '#3F7FD1' },
    'type:Extension point': { fill: '#FFD5C5', pill: '#F1DFD5', stroke: '#C8642E' },
    'type:Kind': { fill: '#CFEFD4', pill: '#DDEFE0', stroke: '#3E9A57' },
    'type:Property': { fill: '#E3D5FA', pill: '#E7DFF5', stroke: '#7B52C9' },
    note: { fill: '#FFDE73', pill: '#F5EBC8', stroke: '#B08A16' },
    card: { fill: '#FAFAFF', pill: '#E0E0F2', stroke: '#6F67D9' },
  },
  relations: { 'type:declares': '#4F46C8', 'type:fills': '#0F8B8D', 'type:holds': '#D23C78', 'type:declared in': '#8A8A8A' },
};

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** The real boards as a model. */
export function load(dir) {
  const graph = JSON.parse(fs.readFileSync(dir + '/graph.json', 'utf8'));
  const measure = JSON.parse(fs.readFileSync(dir + '/measure.json', 'utf8'));
  const kinds = new Map(JSON.parse(fs.readFileSync(dir + '/kinds.json', 'utf8')).map((k) => [k.kind, k]));
  const nodes = new Map();
  for (const n of graph.nodes) {
    const k = kinds.get(n.kind) || {};
    const ms = (measure.nodes || {})[n.key] || {};
    const p = n.props || {};
    nodes.set(n.key, {
      key: n.key, kind: n.kind, in: n.in == null ? null : n.in, title: p.title || '', text: p.text || p.description || '', is: (p.is || [])[0] || null,
      isFrame: k.holds === 'shapes', holdsBoard: k.holds === 'board', rank: n.layout && typeof n.layout.rank === 'number' ? n.layout.rank : null,
      w: ms.size ? Math.ceil(ms.size[0]) : 240, h: ms.size ? Math.ceil(ms.size[1]) : 160, titleWidth: ms.titleWidth || 0, layoutHints: n.layout || {},
      fields: p.fieldValues || null,
    });
  }
  const node = (k) => nodes.get(k);
  const boardOfCache = new Map();
  const boardOf = (k) => {
    if (boardOfCache.has(k)) return boardOfCache.get(k);
    let p = node(k).in, b = 'root';
    while (p != null) { if (node(p).holdsBoard) { b = p; break; } p = node(p).in; }
    boardOfCache.set(k, b); return b;
  };
  /** The frames a shape is in, outermost first (on its own board). */
  const framesOf = (k) => { const out = []; let p = node(k).in; while (p != null && node(p).isFrame) { out.unshift(p); p = node(p).in; } return out; };
  const boards = new Map([['root', { key: 'root', title: graph.drawing || 'root', top: [], leaves: [], frames: [] }]]);
  for (const n of nodes.values()) if (n.holdsBoard) boards.set(n.key, { key: n.key, title: n.title, top: [], leaves: [], frames: [] });
  const kidsOf = new Map();
  for (const n of nodes.values()) {
    const b = boards.get(boardOf(n.key));
    (n.isFrame ? b.frames : b.leaves).push(n.key);
    const holder = n.in != null && node(n.in).isFrame ? n.in : null;
    if (holder == null) b.top.push(n.key);
    else { if (!kidsOf.has(holder)) kidsOf.set(holder, []); kidsOf.get(holder).push(n.key); }
  }
  const byKey = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  for (const b of boards.values()) { b.top.sort(byKey); b.leaves.sort(byKey); b.frames.sort(byKey); }
  for (const l of kidsOf.values()) l.sort(byKey);
  const edges = (graph.edges || []).map((e, i) => ({
    i, from: e.from, to: e.to, weight: (e.layout && e.layout.weight) || 1, type: e.props && e.props.is ? e.props.is[0] : null,
    direct: !!(e.layout && e.layout.direct),
  })).filter((e) => nodes.has(e.from) && nodes.has(e.to) && e.from !== e.to);
  for (const e of edges) { e.fromBoard = boardOf(e.from); e.toBoard = boardOf(e.to); e.cross = e.fromBoard !== e.toBoard; }
  const pillSizes = new Map();
  let pillH = 40;
  for (const p of measure.pills || []) { pillSizes.set(p.for + '\u0000' + (p.from == null ? '' : p.from), p.size); pillH = p.size[1]; }
  const holderOf = (k) => { const n = node(k); return n.in == null ? '' : n.in; };
  return {
    graph, measure, kinds, nodes, node, boards, boardOf, framesOf, constants: measure.constants || {},
    board: (b) => boards.get(b),
    /** A frame's children, or (null and a board) the shapes on the board's top. */
    kids: (frame, board) => (frame == null ? boards.get(board).top : kidsOf.get(frame) || []),
    /** Edges that start on a board: `same` both ends on it, `cross` the far end on another board. */
    edgesOn: (b) => { const all = edges.filter((e) => e.fromBoard === b); return { same: all.filter((e) => !e.cross), cross: all.filter((e) => e.cross), into: edges.filter((e) => e.toBoard === b && e.cross) }; },
    edges,
    /** The measured size of a pill for `target` beside `from` (its container decides whether it shows a path), [w, h]. */
    pillSize: (target, from) => pillSizes.get(target + '\u0000' + holderOf(from)) || pillSizes.get(target + '\u0000') || [Math.max(120, 9 * (node(target).title.length + 4)), pillH],
    pillHeight: pillH,
    colorOf: (k) => { const n = node(k); return n.holdsBoard ? LOOK.types.card : LOOK.types[n.is] || LOOK.types.note; },
  };
}

// ---- geometry ------------------------------------------------------------------------------------------------------------------------

const center = (b) => [b.x + b.w / 2, b.y + b.h / 2];
const inside = (p, b, pad = 0) => p[0] > b.x - pad && p[0] < b.x + b.w + pad && p[1] > b.y - pad && p[1] < b.y + b.h + pad;

/** Where the ray from a box's center toward p leaves the box. */
function exitPoint(b, p) {
  const [cx, cy] = center(b), dx = p[0] - cx, dy = p[1] - cy;
  if (dx === 0 && dy === 0) return [cx, cy];
  const tx = dx === 0 ? Infinity : (b.w / 2) / Math.abs(dx), ty = dy === 0 ? Infinity : (b.h / 2) / Math.abs(dy);
  const t = Math.min(tx, ty);
  return [cx + dx * t, cy + dy * t];
}

/** The circle through three points: [ux, uy, r], or null when they are in a line. */
function circle3(a, c, b) {
  const d = 2 * (a[0] * (c[1] - b[1]) + c[0] * (b[1] - a[1]) + b[0] * (a[1] - c[1]));
  if (Math.abs(d) < 1e-9) return null;
  const s = (p) => p[0] * p[0] + p[1] * p[1];
  const ux = (s(a) * (c[1] - b[1]) + s(c) * (b[1] - a[1]) + s(b) * (a[1] - c[1])) / d;
  const uy = (s(a) * (b[0] - c[0]) + s(c) * (a[0] - b[0]) + s(b) * (c[0] - a[0])) / d;
  return [ux, uy, Math.hypot(a[0] - ux, a[1] - uy)];
}

/** An arrow's path as points, as the app draws it: a given route; else straight or the arc through the bend point, between the centers, clipped at both outlines. */
export function arrowPoints(A, B, arrow, samples = 40) {
  if (arrow.points && arrow.points.length >= 2) return arrow.points.map((p) => [p[0], p[1]]);
  const a = center(A), b = center(B), bend = arrow.bend || 0;
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1;
  let pts = [];
  if (Math.abs(bend) < 8) pts = [exitPoint(A, b), exitPoint(B, a)];
  else {
    const c = [(a[0] + b[0]) / 2 + (-dy / L) * bend, (a[1] + b[1]) / 2 + (dx / L) * bend];
    const circ = circle3(a, c, b);
    if (!circ) pts = [exitPoint(A, b), exitPoint(B, a)];
    else {
      const [ux, uy, r] = circ, t0 = Math.atan2(a[1] - uy, a[0] - ux);
      const norm = (t) => { while (t < t0) t += 2 * Math.PI; while (t >= t0 + 2 * Math.PI) t -= 2 * Math.PI; return t; };
      let t1 = norm(Math.atan2(b[1] - uy, b[0] - ux));
      const tc = norm(Math.atan2(c[1] - uy, c[0] - ux));
      if (!(tc > t0 && tc < t1)) t1 -= 2 * Math.PI;
      for (let i = 0; i <= samples; i++) { const t = t0 + (t1 - t0) * i / samples; pts.push([ux + r * Math.cos(t), uy + r * Math.sin(t)]); }
      pts = pts.filter((p) => !inside(p, A) && !inside(p, B));
      if (pts.length < 2) pts = [exitPoint(A, b), exitPoint(B, a)];
    }
  }
  return pts;
}

function segHitsBox(p, q, b, inset = 1) {
  const xmin = b.x + inset, xmax = b.x + b.w - inset, ymin = b.y + inset, ymax = b.y + b.h - inset;
  if (xmin >= xmax || ymin >= ymax) return false;
  let t0 = 0, t1 = 1;
  const dx = q[0] - p[0], dy = q[1] - p[1];
  const clip = (pp, qq) => { if (pp === 0) return qq >= 0; const r = qq / pp; if (pp < 0) { if (r > t1) return false; if (r > t0) t0 = r; } else { if (r < t0) return false; if (r < t1) t1 = r; } return true; };
  return clip(-dx, p[0] - xmin) && clip(dx, xmax - p[0]) && clip(-dy, p[1] - ymin) && clip(dy, ymax - p[1]) && t1 - t0 > 1e-9;
}
const segsCross = (p1, p2, p3, p4) => {
  const o = (a, b, c) => { const v = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]); return v > 1e-9 ? 1 : v < -1e-9 ? -1 : 0; };
  return o(p1, p2, p3) * o(p1, p2, p4) < 0 && o(p3, p4, p1) * o(p3, p4, p2) < 0;
};

/**
 * What a layout of a board draws, measured the same way for every strategy: shapes and pills, arrows (and how many are routed or bent),
 * arrows over notes or cards, over pills, through frames they aren't in, crossings between arrows, the longest arrow, and the board's size.
 */
export function measure(m, board, layout) {
  const boxOf = (id) => layout.boxes[id] || (layout.pillById || (layout.pillById = Object.fromEntries(layout.pills.map((p) => [p.id, p]))))[id];
  const leaves = Object.keys(layout.boxes).filter((k) => !m.node(k).isFrame), frames = Object.keys(layout.boxes).filter((k) => m.node(k).isFrame);
  const paths = layout.arrows.map((a) => { const A = boxOf(a.from), B = boxOf(a.to); return A && B ? arrowPoints(A, B, a, 16) : []; });
  let overNotes = 0, overPills = 0, throughFrames = 0, longest = 0, total = 0;
  layout.arrows.forEach((a, i) => {
    const pts = paths[i];
    if (pts.length < 2) return;
    let len = 0; for (let j = 1; j < pts.length; j++) len += Math.hypot(pts[j][0] - pts[j - 1][0], pts[j][1] - pts[j - 1][1]);
    longest = Math.max(longest, len); total += len;
    const hits = (b) => { for (let j = 1; j < pts.length; j++) if (segHitsBox(pts[j - 1], pts[j], b)) return true; return false; };
    for (const k of leaves) if (k !== a.from && k !== a.to && hits(layout.boxes[k])) overNotes++;
    for (const p of layout.pills) if (p.id !== a.from && p.id !== a.to && hits(p)) overPills++;
    const own = new Set([...(m.nodes.has(a.from) ? m.framesOf(a.from) : []), ...(m.nodes.has(a.to) ? m.framesOf(a.to) : []), a.from, a.to]);
    for (const f of frames) if (!own.has(f) && hits(layout.boxes[f])) throughFrames++;
  });
  let crossings = 0;
  const bb = paths.map((p) => p.length ? p.reduce((r, q) => [Math.min(r[0], q[0]), Math.min(r[1], q[1]), Math.max(r[2], q[0]), Math.max(r[3], q[1])], [Infinity, Infinity, -Infinity, -Infinity]) : null);
  for (let i = 0; i < paths.length; i++) for (let j = i + 1; j < paths.length; j++) {
    const a = layout.arrows[i], c = layout.arrows[j];
    if (!bb[i] || !bb[j] || a.from === c.from || a.from === c.to || a.to === c.from || a.to === c.to) continue;
    if (bb[i][0] > bb[j][2] || bb[j][0] > bb[i][2] || bb[i][1] > bb[j][3] || bb[j][1] > bb[i][3]) continue;
    let hit = false;
    for (let s = 1; s < paths[i].length && !hit; s++) for (let t = 1; t < paths[j].length && !hit; t++) if (segsCross(paths[i][s - 1], paths[i][s], paths[j][t - 1], paths[j][t])) hit = true;
    if (hit) crossings++;
  }
  // shared line: the length of axis-aligned segments that lie on top of a segment of another arrow (different from-to), where a bus or a
  // trunk hides which arrow goes where; crossings don't count these
  let overlap = 0;
  const segs = [];
  layout.arrows.forEach((a, i) => { const p = paths[i]; for (let j = 1; j < p.length; j++) segs.push({ i, a: p[j - 1], b: p[j] }); });
  const hz = segs.filter((s) => Math.abs(s.a[1] - s.b[1]) < 0.5 && Math.abs(s.a[0] - s.b[0]) > 0.5), vt = segs.filter((s) => Math.abs(s.a[0] - s.b[0]) < 0.5 && Math.abs(s.a[1] - s.b[1]) > 0.5);
  const lap = (list, along, across) => {
    const by = new Map();
    for (const s of list) { const k = Math.round(s.a[across]); if (!by.has(k)) by.set(k, []); by.get(k).push(s); }
    for (const l of by.values()) for (let x = 0; x < l.length; x++) for (let y = x + 1; y < l.length; y++) {
      const s = l[x], t = l[y];
      if (s.i === t.i) continue;
      const A = layout.arrows[s.i], B = layout.arrows[t.i];
      if (A.from === B.from && A.to === B.to) continue;
      const lo = Math.max(Math.min(s.a[along], s.b[along]), Math.min(t.a[along], t.b[along])), hi = Math.min(Math.max(s.a[along], s.b[along]), Math.max(t.a[along], t.b[along]));
      if (hi > lo) overlap += hi - lo;
    }
  };
  lap(hz, 0, 1); lap(vt, 1, 0);
  const all = Object.values(layout.boxes).concat(layout.pills);
  const x0 = Math.min(...all.map((b) => b.x)), y0 = Math.min(...all.map((b) => b.y)), x1 = Math.max(...all.map((b) => b.x + b.w)), y1 = Math.max(...all.map((b) => b.y + b.h));
  return {
    shapes: leaves.length, frames: frames.length, pills: layout.pills.length, arrows: layout.arrows.length,
    routed: layout.arrows.filter((a) => a.points && a.points.length > 2).length, bent: layout.arrows.filter((a) => !a.points && Math.abs(a.bend || 0) >= 8).length,
    overNotes, overPills, throughFrames, crossings, sharedLine: Math.round(overlap), longest: Math.round(longest), meanLength: Math.round(total / Math.max(1, layout.arrows.length)),
    size: [Math.round(x1 - x0), Math.round(y1 - y0)],
  };
}

/**
 * Two pictures of a board: as a window first shows it (the whole board fitted into 1600 x 1000 points, words left out, as the app draws
 * shapes as skeletons below 35% zoom), and readable (`scale` pixels to a unit, words in). Writes <base>-fit.png and <base>.png (and the SVGs).
 */
export function renderBoth(m, board, layout, base, opts = {}) {
  const fs2 = fs;
  const read = renderBoard(m, board, layout, opts);
  fs2.writeFileSync(base + '.svg', read.svg);
  const a = svgToPng(base + '.svg', base + '.png', opts.scale || 0.3);
  const fitSvg = renderBoard(m, board, layout, Object.assign({}, opts, { text: false, labels: false }));
  fs2.writeFileSync(base + '-fit.svg', fitSvg.svg);
  const s = Math.min(1600 / fitSvg.width, 1000 / fitSvg.height);
  const b = svgToPng(base + '-fit.svg', base + '-fit.png', s);
  return { readable: a, fit: b, fitScale: Math.round(s * 1000) / 1000 };
}

// ---- drawing -------------------------------------------------------------------------------------------------------------------------

function roundedPath(pts, r = 14) {
  if (pts.length === 2) return `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}L${pts[1][0].toFixed(1)},${pts[1][1].toFixed(1)}`;
  let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const p = pts[i - 1], q = pts[i], n = pts[i + 1];
    const l1 = Math.hypot(q[0] - p[0], q[1] - p[1]), l2 = Math.hypot(n[0] - q[0], n[1] - q[1]);
    const rr = Math.min(r, l1 / 2, l2 / 2);
    const a = [q[0] - (q[0] - p[0]) / (l1 || 1) * rr, q[1] - (q[1] - p[1]) / (l1 || 1) * rr];
    const b = [q[0] + (n[0] - q[0]) / (l2 || 1) * rr, q[1] + (n[1] - q[1]) / (l2 || 1) * rr];
    d += `L${a[0].toFixed(1)},${a[1].toFixed(1)}Q${q[0].toFixed(1)},${q[1].toFixed(1)} ${b[0].toFixed(1)},${b[1].toFixed(1)}`;
  }
  const z = pts[pts.length - 1];
  return d + `L${z[0].toFixed(1)},${z[1].toFixed(1)}`;
}

function fit(text, width, px) {
  const per = px * 0.56, most = Math.max(1, Math.floor(width / per));
  return text.length <= most ? text : text.slice(0, Math.max(1, most - 1)) + '…';
}

/**
 * An SVG of one board as the layout has it, in the app's look. opts: {title (a caption above), margin, text (draw notes' words; default
 * true), labels (draw relationship arrows' labels; default true)}. Returns {svg, width, height}.
 */
export function renderBoard(m, board, layout, opts = {}) {
  const margin = opts.margin == null ? 80 : opts.margin, cap = opts.title ? 90 : 0;
  const all = Object.values(layout.boxes).concat(layout.pills);
  const x0 = Math.min(...all.map((b) => b.x)) - margin, y0 = Math.min(...all.map((b) => b.y)) - margin - 40 - cap;
  const x1 = Math.max(...all.map((b) => b.x + b.w)) + margin, y1 = Math.max(...all.map((b) => b.y + b.h)) + margin;
  const W = Math.ceil(x1 - x0), H = Math.ceil(y1 - y0);
  const T = (x, y) => `${(x - x0).toFixed(1)},${(y - y0).toFixed(1)}`;
  const out = [];
  out.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif">`);
  out.push(`<defs><pattern id="dots" width="24" height="24" patternUnits="userSpaceOnUse"><circle cx="2" cy="2" r="1.6" fill="${LOOK.dot}"/></pattern>`);
  const heads = new Set([LOOK.arrow].concat(Object.values(LOOK.relations)).concat((layout.arrows || []).map((a) => a.color).filter(Boolean)));
  [...heads].forEach((c, i) => out.push(`<marker id="h${i}" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse"><path d="M1,1 L11,6 L1,11" fill="none" stroke="${c}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></marker>`));
  const headOf = new Map([...heads].map((c, i) => [c, `h${i}`]));
  out.push('</defs>');
  out.push(`<rect width="${W}" height="${H}" fill="${LOOK.canvas}"/><rect width="${W}" height="${H}" fill="url(#dots)"/>`);
  if (opts.title) out.push(`<text x="${margin}" y="${margin + 30}" font-size="44" font-weight="700" fill="${LOOK.ink}">${esc(opts.title)}</text>`);
  // frames, outermost first
  const frameKeys = Object.keys(layout.boxes).filter((k) => m.node(k).isFrame).sort((a, b) => m.framesOf(a).length - m.framesOf(b).length);
  for (const k of frameKeys) {
    const b = layout.boxes[k], n = m.node(k);
    out.push(`<rect x="${(b.x - x0).toFixed(1)}" y="${(b.y - y0).toFixed(1)}" width="${b.w}" height="${b.h}" rx="10" fill="${LOOK.frame}" stroke="${LOOK.frameStroke}" stroke-width="2"/>`);
    const t = fit(n.title, Math.max(80, b.w - 40), 22), tw = Math.min(b.w - 20, 22 * 0.56 * t.length + 28);
    out.push(`<rect x="${(b.x - x0 + 18).toFixed(1)}" y="${(b.y - y0 - 17).toFixed(1)}" width="${tw.toFixed(1)}" height="34" rx="17" fill="#FFFFFF" stroke="${LOOK.frameStroke}" stroke-width="2"/>`);
    out.push(`<text x="${(b.x - x0 + 32).toFixed(1)}" y="${(b.y - y0 + 7).toFixed(1)}" font-size="22" font-weight="600" fill="#333">${esc(t)}</text>`);
  }
  // arrows under the shapes they join (as on the canvas, where shapes cover the arrows' ends)
  const boxOf = (id) => layout.boxes[id] || Object.fromEntries(layout.pills.map((p) => [p.id, p]))[id];
  const pillIndex = Object.fromEntries(layout.pills.map((p) => [p.id, p]));
  const labels = [];
  for (const a of layout.arrows) {
    const A = layout.boxes[a.from] || pillIndex[a.from], B = layout.boxes[a.to] || pillIndex[a.to];
    if (!A || !B) continue;
    const pts = arrowPoints(A, B, a, 40);
    if (pts.length < 2) continue;
    const color = a.color || LOOK.arrow, d = roundedPath(pts.map((p) => [p[0] - x0, p[1] - y0]));
    out.push(`<path d="${d}" fill="none" stroke="${color}" stroke-width="${a.width || 3.5}" stroke-linecap="round" stroke-linejoin="round" marker-end="url(#${headOf.get(color)})"${a.dashed ? ' stroke-dasharray="10 8"' : ''} opacity="${a.opacity || 1}"/>`);
    if (a.label && opts.labels !== false) labels.push({ at: pts[Math.floor(pts.length / 2)], text: a.label, color });
  }
  // shapes
  for (const [k, b] of Object.entries(layout.boxes)) {
    const n = m.node(k);
    if (n.isFrame) continue;
    const c = m.colorOf(k), X = b.x - x0, Y = b.y - y0;
    if (n.holdsBoard) {
      out.push(`<rect x="${X.toFixed(1)}" y="${Y.toFixed(1)}" width="${b.w}" height="${b.h}" rx="12" fill="${LOOK.card}" stroke="${LOOK.cardStroke}" stroke-width="2.5"/>`);
      const t = fit(n.title, b.w - 24, 26);
      out.push(`<text x="${(X + b.w / 2).toFixed(1)}" y="${(Y + b.h / 2 + 9).toFixed(1)}" font-size="26" font-weight="700" text-anchor="middle" fill="${LOOK.ink}">${esc(t)}</text>`);
      continue;
    }
    out.push(`<rect x="${X.toFixed(1)}" y="${(Y + 3).toFixed(1)}" width="${b.w}" height="${b.h}" rx="5" fill="#000" opacity="0.06"/>`);
    out.push(`<rect x="${X.toFixed(1)}" y="${Y.toFixed(1)}" width="${b.w}" height="${b.h}" rx="5" fill="${c.fill}"/>`);
    const tt = fit(n.title, Math.max(60, b.w - 10), 18), tw = Math.min(b.w + 60, 18 * 0.58 * tt.length + 22);
    out.push(`<rect x="${X.toFixed(1)}" y="${(Y - 36).toFixed(1)}" width="${tw.toFixed(1)}" height="28" rx="14" fill="${LOOK.tab}"/>`);
    out.push(`<text x="${(X + 11).toFixed(1)}" y="${(Y - 16).toFixed(1)}" font-size="18" font-weight="700" fill="${LOOK.tabInk}">${esc(tt)}</text>`);
    if (opts.text !== false) {
      const lines = String(n.text || '').split('\n').filter((l) => l.trim()).slice(0, Math.max(1, Math.floor((b.h - 30) / 24)));
      lines.forEach((l, i) => out.push(`<text x="${(X + 16).toFixed(1)}" y="${(Y + 34 + i * 24).toFixed(1)}" font-size="18" fill="#333">${esc(fit(l, b.w - 30, 18))}</text>`));
    }
  }
  for (const p of layout.pills) {
    const n = m.node(p.for), c = n ? m.colorOf(p.for) : LOOK.types.note, X = p.x - x0, Y = p.y - y0;
    out.push(`<rect x="${X.toFixed(1)}" y="${Y.toFixed(1)}" width="${p.w}" height="${p.h}" rx="${(p.h / 2).toFixed(1)}" fill="${c.pill}" stroke="${c.stroke}" stroke-width="1.6"/>`);
    out.push(`<text x="${(X + 16).toFixed(1)}" y="${(Y + p.h / 2 + 6).toFixed(1)}" font-size="17" font-weight="600" fill="${LOOK.ink}">${esc(fit(n ? n.title : p.for, p.w - 24, 17))}</text>`);
  }
  for (const l of labels) {
    const t = l.text, w = 15 * 0.56 * t.length + 18;
    out.push(`<rect x="${(l.at[0] - x0 - w / 2).toFixed(1)}" y="${(l.at[1] - y0 - 13).toFixed(1)}" width="${w.toFixed(1)}" height="26" rx="13" fill="#FFFFFF" stroke="${l.color}" stroke-width="1.5"/>`);
    out.push(`<text x="${(l.at[0] - x0).toFixed(1)}" y="${(l.at[1] - y0 + 5).toFixed(1)}" font-size="15" text-anchor="middle" fill="${l.color}">${esc(t)}</text>`);
  }
  out.push('</svg>');
  return { svg: out.join('\n'), width: W, height: H };
}

/** Today's (or any) drawing.json's layout of one board, in the harness's form, so the same renderer and measures apply to it. */
export function layoutFromDrawing(m, drawing, board) {
  const place = new Map(drawing.nodes.map((n) => [n.key, n.place]));
  const absCache = new Map();
  const abs = (k) => {
    if (absCache.has(k)) return absCache.get(k);
    const n = m.node(k), pl = place.get(k);
    let x = pl.at[0], y = pl.at[1];
    if (n.in != null && m.node(n.in).isFrame) { const f = abs(n.in); x += f.x; y += f.y; }
    const b = { x, y, w: pl.size[0], h: pl.size[1] }; absCache.set(k, b); return b;
  };
  const boxes = {};
  for (const n of drawing.nodes) if (m.boardOf(n.key) === board) boxes[n.key] = abs(n.key);
  const pills = [], pillOf = new Map(), arrows = [];
  for (const e of drawing.edges) {
    if (m.boardOf(e.from) !== board) continue;
    const p = e.place && e.place.pill;
    if (p && p.at) {
      let ox = 0, oy = 0;
      if (p.in != null) { const f = abs(p.in); ox = f.x; oy = f.y; }
      const [w, h] = m.pillSize(e.to, e.from);
      const id = 'pill ' + e.from + ' > ' + e.to;
      pills.push({ id, for: e.to, x: p.at[0] + ox, y: p.at[1] + oy, w, h });
      pillOf.set(e.from + '\u0000' + e.to, id);
    }
  }
  for (const e of drawing.edges) {
    if (m.boardOf(e.from) !== board) continue;
    const p = e.place && e.place.pill, type = e.props && e.props.is ? e.props.is[0] : null;
    const color = type ? LOOK.relations[type] : null, label = type ? type.slice(5) : null;
    const bend = (e.props && e.props.bend) || (e.place && e.place.bend) || 0;
    if (!p) arrows.push({ from: e.from, to: e.to, bend, color, label });
    else { const host = p.share != null ? p.share : e.from, id = pillOf.get(host + '\u0000' + e.to); if (id) arrows.push({ from: e.from, to: id, bend, color, label }); }
  }
  return { boxes, pills, arrows };
}

// ---- ELK ------------------------------------------------------------------------------------------------------------------------------

import { createRequire } from 'module';
const require = createRequire(import.meta.url);
/** The repository's vendored elkjs (0.12.0). Lay a compound graph out with 'elk.json.shapeCoords': 'ROOT' and 'elk.json.edgeCoords': 'ROOT' to get board coordinates. */
export function newElk() {
  const ELK = require(new URL('../../../../../.claude/skills/canvas-digest/tool/vendor/elk.bundled.js', import.meta.url).pathname);
  return new ELK();
}

/** ELK's answer flattened: every node's box by id, and every edge's route (start, bend points, end) by id. Coordinates as ELK gave them (use ROOT coordinates). */
export function flattenElk(r) {
  const boxes = {}, routes = {};
  const walk = (n) => {
    for (const c of n.children || []) { boxes[c.id] = { x: c.x, y: c.y, w: c.width, h: c.height }; walk(c); }
    for (const e of n.edges || []) {
      const s = (e.sections || [])[0];
      if (s) routes[e.id] = [[s.startPoint.x, s.startPoint.y]].concat((s.bendPoints || []).map((p) => [p.x, p.y])).concat([[s.endPoint.x, s.endPoint.y]]);
    }
  };
  walk(r);
  return { boxes, routes };
}

/** An SVG file drawn to a PNG by AppKit (proto/svg2png; Quick Look's renderer clips large drawings): `scale` pixels to a unit of the drawing. */
export function svgToPng(svgPath, pngPath, scale) {
  const tool = new URL('./svg2png', import.meta.url).pathname;
  return execFileSync(tool, [svgPath, pngPath, String(scale)], { encoding: 'utf8' }).trim();
}
