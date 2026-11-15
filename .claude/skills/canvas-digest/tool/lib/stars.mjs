// Stars: a container's children placed from a drawing of its arrows with none crossing, then kept clean.
//   1. Points. The drawn links (a planar graph once the cut has made them one) as points: stress (SMACOF) from a spiral, kept when no two of
//      its links cross; else drawn from the graph's planar embedding (planarity.mjs), which no two links cross by construction, and
//      relaxed toward the stress drawing, each point moved only as far as keeps every link uncrossed. Where the notes were in an earlier
//      round the points start there. A child linked only through pills is a point among them, placed by stress alone.
//   2. Put down. The children one at a time, the most linked first, each at the clean spot nearest its placed neighbours, in the direction
//      the points put it from them, and its pills in the arrangement (strips.mjs) that its arrows leave free. A drawing that is far off
//      the view's shape is also tried stretched to it. A link no spot lets out, or that crosses another in a drawing kept from an earlier
//      round, is excused: left out of what "clean" means here, for the cut to take. Where the notes were, those still clean stay and the
//      rest are put down again; if one lands far off, all are put down afresh, and the fresh drawing is taken when it excuses no more
//      links and is smaller.
//   3. Compact. Each child moved toward where stress wants it, and each note's pills given a smaller arrangement, only where the container
//      stays clean; sweep after sweep until nothing moves much.
//   4. Gather (when asked). Each child drawn toward the middle of the drawing, its neighbours and where stress wants it, whichever keeps
//      the container clean and makes the least of the drawing's area and its links' lengths.
//   5. Shelve. The children with no link in rows beside the rest.
//   Frames (`opts.clusters`): a frame's members are children here like any other, held together (each pair of them near, at a small
//   weight) and put down before the rest, one frame after another, each where it blocks least the ways out its members down need to the
//   shapes they link to; the frame is the box round them (`hullOf`), which no other child, and no arrow that ends at none of its members,
//   may come near. An arrow no spot near lets out is given up sooner than in a container with no frame (`FRAME_FAIL`): every other shape
//   is put down round the frames, and one kept from going far out of their way keeps the board small. The box each frame takes is
//   returned (`hulls`).
// Pure and deterministic: square roots and the four operations.
import { len, arrowBetween, segHitsBox, segCross, cosd, sind, atan2d } from './geom.mjs';
import { planarDrawing, countCrossings } from './planarity.mjs';

const KEEP_WORTH = 0.8;   // a fresh drawing replaces the kept one when its area is under this share of the kept one's
const STRETCH_MAX = 12;   // the most linked children of a container whose drawing is tried stretched
const OFF_SHAPE = 2.2;   // a drawing this much off the view's shape (width over height, either way) is tried again stretched
const GATHER_LEN = 300;  // weight of link length against area in the gather's cost
const GAP = 40;          // between two children's footprints
const TIGHT_GAP = 8;     // the least between two footprints that a put-down inside a frame takes before the frame grows (the check's own margin for a pill)
const MARGIN = 8;        // how near an arrow may pass a shape (health.mjs's)
const BEND = 34;         // how far the app bows each further arrow between one pair (health.mjs's pairBend)
const SPIRAL = 2.39996;
const COHESION = 0.5;    // how near a frame's members are held to each other, as a link's weight
const FRAME_FAIL = 9000; // in a container with frames, what an arrow given up costs a spot, against its distance to its neighbours (else: anything)
const BLOCKED = 1e6;     // what a frame's member costs a spot for each way out of the frame it blocks
const TWO_PI = 6.283185307179586;

/**
 * Places `items` (a box each: {w, h}, or a leaf's {alts, alt}, the arrangements of its pills that strips.mjs gives, each a box `w` by `h`
 * with the note at `nx`, `ny` in it) linked by `edges` ([{a, b, w, n}]: item indexes, a weight, how many lines the app draws between them).
 * `opts.aspect` is the shape the view wants (width over height), `opts.affinity` every link among them, drawn or a pill ([{a, b, w}]),
 * `opts.alt` each leaf's arrangement to start with, `opts.fromNotes` each item's note's middle as an earlier round left it (or null), which
 * the points start from, `opts.gather` whether the children are drawn together after, and `opts.onExcused` is told the pairs of items
 * whose arrows no spot let out clean ([[a, b]]). Returns [{x, y, alt}], the top-left of each item's box in the arrangement it ends with.
 */
export function starsLayout(items, edges, opts = {}) {
  const n = items.length;
  if (!n) return [];
  const aspect = opts.aspect > 0 ? opts.aspect : 1.5;
  const alt = items.map((it, i) => (it.alts ? (opts.alt && opts.alt[i] != null && it.alts[opts.alt[i]] ? opts.alt[i] : it.alt || 0) : 0));
  // the pairs the arrows join, each with how many lines the app draws between them
  const pairMap = new Map();
  for (const e of edges) {
    if (e.a == null || e.b == null || e.a === e.b) continue;
    const a = Math.min(e.a, e.b), b = Math.max(e.a, e.b), k = a * n + b;
    if (!pairMap.has(k)) pairMap.set(k, { a, b, lines: 0, w: 0 });
    const p = pairMap.get(k);
    p.lines += Math.max(1, e.n || 1); p.w += e.w || 1;
  }
  const pairs = [...pairMap.values()].sort((p, q) => p.a - q.a || p.b - q.b);
  const near = items.map(() => new Map());
  for (const e of (opts.affinity || []).concat(edges)) {
    if (e.a == null || e.b == null || e.a === e.b) continue;
    near[e.a].set(e.b, (near[e.a].get(e.b) || 0) + (e.w || 1));
    near[e.b].set(e.a, (near[e.b].get(e.a) || 0) + (e.w || 1));
  }
  // a frame's members: each pair held near
  const cl = opts.clusters ? opts.clusters.of : null, spec = opts.clusters ? opts.clusters.spec : [];
  const members = spec.map(() => []);
  if (cl) cl.forEach((k, i) => { if (k >= 0) members[k].push(i); });
  for (const ms of members) for (const a of ms) for (const b of ms) if (a !== b) near[a].set(b, (near[a].get(b) || 0) + COHESION);
  const linked = [], loose = [];
  for (let i = 0; i < n; i++) (near[i].size ? linked : loose).push(i);
  const C = new Array(n).fill(null);   // note middles
  const geo = new Geometry(items, alt);
  if (linked.length) {
    const fromNotes = opts.fromNotes;
    const D = idealDistances(items, geo, near, linked);
    let P = null;
    if (fromNotes && linked.some((i) => fromNotes[i])) {
      P = linked.map((i) => (fromNotes[i] ? fromNotes[i].slice() : null));
      // one with no place yet: at the middle of its placed neighbours
      linked.forEach((i, k) => {
        if (P[k]) return;
        let sx = 0, sy = 0, c = 0;
        linked.forEach((j, l) => { if (near[i].has(j) && fromNotes[j]) { sx += fromNotes[j][0]; sy += fromNotes[j][1]; c++; } });
        P[k] = c ? [sx / c + 37 * (k % 5), sy / c + 41 * (k % 3)] : [0, 0];
      });
    } else P = points(items, linked, pairs, D, aspect);
    linked.forEach((i, k) => { C[i] = P[k]; });
    const S = new Solver(items, geo, pairs, linked, C, D, near);
    if (cl) S.clusters(cl, members, spec);
    const fresh = !(fromNotes && linked.some((i) => fromNotes[i]));
    if (fresh) {
      // laid down by the planar drawing as it is, and again with the drawing stretched to the view's shape: the one that excuses fewer arrows,
      // then the smaller for its shape
      const C0 = C.map((c) => (c ? c.slice() : null)), alt0 = geo.alt.slice();
      S.incremental(null);
      // a frame counts as one child
      const units = cl ? linked.filter((i) => cl[i] < 0).length + members.filter((ms) => ms.length).length : linked.length;
      const stretch = units <= STRETCH_MAX && S.shapedArea(aspect) > OFF_SHAPE * S.areaM() * 1e5 ? stretched(C0, linked, aspect) : null;
      if (stretch) {
        const mine = { C: C.map((c) => (c ? c.slice() : null)), alt: geo.alt.slice(), excused: S.excused.slice(), ex: S.excused.reduce((a, b) => a + b, 0), area: S.shapedArea(aspect), real: S.areaM() };
        stretch.forEach((c, i) => { C[i] = c; }); geo.alt = alt0.slice(); S.excused.fill(0);
        S.incremental(null);
        const ex = S.excused.reduce((a, b) => a + b, 0), area = S.shapedArea(aspect);
        if (!(ex <= mine.ex && area < mine.area && S.areaM() <= 1.03 * mine.real)) { mine.C.forEach((c, i) => { C[i] = c; }); geo.alt = mine.alt; S.excused.set(mine.excused); }
      }
    }
    else {
      // from where the notes were, the displaced ones put down again; when one lands far from its links (its neighbours' pills grew into
      // the room beside them), every note is put down again from the planar drawing instead, kept only if it excuses no more arrows and is smaller
      const keepList = linked.filter((i) => fromNotes[i]);
      const C0 = C.map((c) => (c ? c.slice() : null)), alt0 = geo.alt.slice(), ex0 = S.excused.slice();
      if (S.incremental(keepList) > 0) {
        const mine = { C: C.map((c) => (c ? c.slice() : null)), alt: geo.alt.slice(), excused: S.excused.slice(), ex: S.excused.reduce((a, b) => a + b, 0), area: S.areaM() };
        C0.forEach((c, i) => { C[i] = c ? c.slice() : null; }); geo.alt = alt0.slice(); S.excused.set(ex0);
        S.incremental(null);
        const ex = S.excused.reduce((a, b) => a + b, 0), area = S.areaM();
        if (!(ex < mine.ex || (ex === mine.ex && area < mine.area * KEEP_WORTH))) { mine.C.forEach((c, i) => { C[i] = c; }); geo.alt = mine.alt; S.excused.set(mine.excused); }
      }
    }
    if (opts.onExcused) opts.onExcused(S.pairs.filter((p, k) => S.excused[k]).map((p) => [p.a, p.b]));
    S.compact(30);
    if (opts.gather) S.gather(30);
  }
  // each item's box's top-left; the loose shelved beside the rest
  const cur = items.map((it, i) => geo.unit(i));
  const pos = items.map((it, i) => (C[i] ? { x: C[i][0] + cur[i].ux, y: C[i][1] + cur[i].uy } : null));
  const boxes = cur.map((u) => ({ w: u.w, h: u.h }));
  // a frame's box, from its members' boxes at `at` (their top-lefts)
  const hullAt = (k, at) => {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const i of members[k]) {
      if (!at[i]) continue;
      const g = cur[i], fx = at[i].x + g.foot.x - g.ux, fy = at[i].y + g.foot.y - g.uy;
      x0 = Math.min(x0, fx); y0 = Math.min(y0, fy); x1 = Math.max(x1, fx + g.foot.w); y1 = Math.max(y1, fy + g.foot.h);
    }
    return x0 === Infinity ? null : frameBox(spec[k], x0, y0, x1, y1);
  };
  const extra = cl ? members.map((ms, k) => hullAt(k, pos)).filter(Boolean).map((H) => H.foot) : [];
  shelve(boxes, pos, linked, loose, aspect, extra);
  let x0 = Infinity, y0 = Infinity;
  for (const p of pos) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); }
  const out = pos.map((p, i) => ({ x: Math.round(p.x - x0), y: Math.round(p.y - y0), alt: geo.alt[i] }));
  if (cl) out.hulls = members.map((ms, k) => { const H = hullAt(k, out); return H ? H.box : null; });
  return out;
}

/**
 * Children put down among held ones, nothing held moved (drawing again in place). `init[i]` is {c: the note's middle, alt} for a child that is
 * where it is, null for one to put down; `flex` the held children whose note or pills changed, which take another arrangement of their pills
 * where they stand if one is clear, else are put down again (`opts.weight`: how many shapes each moves with it: a frame that grew puts down the shapes it
 * reaches instead of itself where they are fewer; `opts.grew`: those whose note or frame is larger, which are put down again where it is
 * on another's, and others stay where a person put them; `opts.fixed`: those a person put where they are and the frames that hold one, which nothing moves, and
 * `opts.own` which of them are the person's own: what one of those lies on is `opts.note.covered`, what a frame about one reaches `opts.note.reached`). `edges` and `opts.affinity` are starsLayout's; `opts.bounds` {x, y} the least
 * top-left of a child's footprint (a frame's inset), `opts.grow` {w, h, pad, above, avoid} the frame the children are in, which grows right
 * and down but not into the boxes `avoid` lists. Returns [{x, y, alt}] the top-left of each child's box in its arrangement.
 */
export function putDown(items, edges, init, opts = {}) {
  const n = items.length;
  if (!n) return [];
  const alt = items.map((it, i) => (init[i] ? init[i].alt : it.alts ? it.alt || 0 : 0));
  const pairMap = new Map();
  for (const e of edges) {
    if (e.a == null || e.b == null || e.a === e.b) continue;
    const a = Math.min(e.a, e.b), b = Math.max(e.a, e.b), k = a * n + b;
    if (!pairMap.has(k)) pairMap.set(k, { a, b, lines: 0, w: 0 });
    const p = pairMap.get(k);
    p.lines += Math.max(1, e.n || 1); p.w += e.w || 1;
  }
  const pairs = [...pairMap.values()].sort((p, q) => p.a - q.a || p.b - q.b);
  const near = items.map(() => new Map());
  for (const e of (opts.affinity || []).concat(edges)) {
    if (e.a == null || e.b == null || e.a === e.b) continue;
    near[e.a].set(e.b, (near[e.a].get(e.b) || 0) + (e.w || 1));
    near[e.b].set(e.a, (near[e.b].get(e.a) || 0) + (e.w || 1));
  }
  const geo = new Geometry(items, alt);
  const C = init.map((x) => (x ? x.c.slice() : null));
  // one to put down starts at the middle of the held ones it is linked to (the planar drawing's place for it, which its neighbours' directions go by)
  const first = C.map((c) => (c ? c.slice() : null));
  items.forEach((it, i) => {
    if (C[i]) return;
    let sx = 0, sy = 0, k = 0;
    for (const j of near[i].keys()) if (first[j]) { sx += first[j][0]; sy += first[j][1]; k++; }
    if (!k) for (let j = 0; j < n; j++) if (first[j]) { sx += first[j][0]; sy += first[j][1]; k++; }
    C[i] = k ? [sx / k + 37 * (i % 5), sy / k + 41 * (i % 3)] : [0, 0];
  });
  const S = new Solver(items, geo, pairs, items.map((it, i) => i), C, null, near);
  // each link's own weight, for the weighing (the affinity holds every link once; with none, the edges)
  S.linkW = items.map(() => new Map());
  for (const e of (opts.affinity && opts.affinity.length ? opts.affinity : edges)) {
    if (e.a == null || e.b == null || e.a === e.b) continue;
    S.linkW[e.a].set(e.b, (S.linkW[e.a].get(e.b) || 0) + (e.w || 1));
    S.linkW[e.b].set(e.a, (S.linkW[e.b].get(e.a) || 0) + (e.w || 1));
  }
  S.bounds = opts.bounds || null; S.grow = opts.grow || null; S.byWeight = true;
  S.putDown(init.map((x) => !!x), opts.flex || [], opts.grew || new Set(), opts.weight || null, opts.fixed || new Set(), opts.note || null, opts.own || new Set());
  return items.map((it, i) => { const u = geo.unit(i, geo.alt[i]); return { x: C[i][0] + u.ux, y: C[i][1] + u.uy, alt: geo.alt[i] }; });
}

/** A frame round boxes from x0, y0 to x1, y1: its inset about them, at least its least size and its title's width, its title's room above it. */
function frameBox(s, x0, y0, x1, y1) {
  const x = x0 - s.pad, y = y0 - s.pad, w = Math.max(x1 - x0 + 2 * s.pad, s.minW, s.titleW), h = Math.max(y1 - y0 + 2 * s.pad, s.minH);
  const tab = s.above > 0 ? { x, y: y - s.above, w: s.titleW > 0 ? Math.min(w, s.titleW) : w, h: s.above } : null;
  return { box: { x, y, w, h }, tab, foot: { x, y: y - s.above, w, h: h + s.above } };
}

const nearBox = (F, G, gap) => F.x < G.x + G.w + gap && G.x < F.x + F.w + gap && F.y < G.y + G.h + gap && G.y < F.y + F.h + gap;

/** Each item in each arrangement, about its note's middle: its unit box (`ux`, `uy` its top-left), note, title's room, pills and their lines. */
class Geometry {
  constructor(items, alt) {
    this.items = items; this.alt = alt.slice();
    this.memo = items.map(() => new Map());
  }
  unit(i, a = this.alt[i]) {
    const m = this.memo[i];
    if (m.has(a)) return m.get(a);
    const it = this.items[i], ta = it.titleAbove || 0;
    let g;
    if (it.alts && it.alts[a]) {
      const A = it.alts[a], note = { x: -A.nw / 2, y: -A.nh / 2, w: A.nw, h: A.nh };
      const ux = note.x - A.nx, uy = note.y - A.ny;
      const pills = A.pills.map((p) => ({ x: ux + p.x, y: uy + p.y, w: p.w, h: p.h }));
      const lines = pills.map((p) => arrowBetween(note, p));
      g = { ux, uy, w: A.w, h: A.h, note, pills, lines, column: /^column/.test(A.side || ''), area: A.w * A.h };
    } else {
      const w = it.nw != null ? it.nw : it.w, h = it.nh != null ? it.nh : it.h;
      const note = { x: -w / 2, y: -h / 2, w, h };
      g = { ux: -it.w / 2, uy: -it.h / 2, w: it.w, h: it.h, note, pills: [], lines: [], column: false, area: it.w * it.h };
      if (it.nw != null) { g.ux = note.x - it.nx; g.uy = note.y - it.ny; }
    }
    g.tab = ta > 0 ? { x: g.note.x, y: g.note.y - ta, w: g.note.w, h: ta } : null;
    const fx0 = Math.min(g.ux, g.note.x), fy0 = Math.min(g.uy, g.tab ? g.tab.y : g.note.y);
    const fx1 = Math.max(g.ux + g.w, g.note.x + g.note.w), fy1 = Math.max(g.uy + g.h, g.note.y + g.note.h);
    g.foot = { x: fx0, y: fy0, w: fx1 - fx0, h: fy1 - fy0 };
    g.diag = len(g.foot.w, g.foot.h);
    m.set(a, g);
    return g;
  }
  arrangements(i) { const it = this.items[i]; if (!it.alts) return [0]; const out = []; it.alts.forEach((a, k) => { if (a) out.push(k); }); return out; }
}

const shift = (b, c) => ({ x: b.x + c[0], y: b.y + c[1], w: b.w, h: b.h });
const shiftSeg = (s, c) => ({ x1: s.x1 + c[0], y1: s.y1 + c[1], x2: s.x2 + c[0], y2: s.y2 + c[1] });

/** Ideal distances between the linked children: shortest paths over every link, a link as long as its two footprints need. */
function idealDistances(items, geo, near, linked) {
  const N = linked.length, at = new Map(linked.map((i, k) => [i, k]));
  const r = (i) => { const g = geo.unit(i); return len(g.note.w, g.note.h) * 0.5 + (g.diag - len(g.note.w, g.note.h)) * 0.35; };
  const length = (i, j) => (r(i) + r(j) + GAP + 40) / Math.max(0.5, 1 + 0.25 * lnOf(near[i].get(j)));
  const D = linked.map(() => new Float64Array(N).fill(Infinity));
  for (let s = 0; s < N; s++) {
    const dist = D[s], done = new Uint8Array(N);
    dist[s] = 0;
    for (;;) {
      let u = -1;
      for (let k = 0; k < N; k++) if (!done[k] && dist[k] < Infinity && (u < 0 || dist[k] < dist[u])) u = k;
      if (u < 0) break;
      done[u] = 1;
      for (const [v] of near[linked[u]]) { const kv = at.get(v); if (kv == null) continue; const d = dist[u] + length(linked[u], v); if (d < dist[kv]) dist[kv] = d; }
    }
  }
  let far = 0;
  for (const row of D) for (const x of row) if (x < Infinity) far = Math.max(far, x);
  for (const row of D) for (let k = 0; k < N; k++) if (row[k] === Infinity) row[k] = far * 0.6 + 300;
  return D;
}

function target(X, D, a) {
  let sx = 0, sy = 0, sw = 0;
  for (let b = 0; b < X.length; b++) {
    if (a === b) continue;
    const d = D[a][b], w = 1 / (d * d), dx = X[a][0] - X[b][0], dy = X[a][1] - X[b][1], cur = len(dx, dy) || 1e-3;
    sx += w * (X[b][0] + d * dx / cur); sy += w * (X[b][1] + d * dy / cur); sw += w;
  }
  return [sx / sw, sy / sw];
}

/** The linked children's points (by their place in `linked`): stress if no two drawn links cross in it, else the planar drawing relaxed toward it. */
function points(items, linked, pairs, D, aspect) {
  const N = linked.length, at = new Map(linked.map((i, k) => [i, k]));
  const E = pairs.filter((p) => at.has(p.a) && at.has(p.b)).map((p) => [at.get(p.a), at.get(p.b)]);
  // stress from a spiral, the most linked first
  const deg = new Array(N).fill(0);
  for (let a = 0; a < N; a++) for (let b = 0; b < N; b++) if (a !== b && D[a][b] < Infinity) deg[a] += 1 / D[a][b];
  const order = linked.map((_, k) => k).sort((a, b) => deg[b] - deg[a] || a - b);
  let X = new Array(N);
  order.forEach((k, r) => { const t = r * SPIRAL, rad = 220 * Math.sqrt(r); X[k] = [rad * cosd(t) * 1.4, rad * sind(t)]; });
  for (let it = 0; it < 300; it++) { const Y = X.map((_, a) => target(X, D, a)); X = Y; }
  if (!countCrossings(X, E)) return turned(X, aspect);
  // the planar drawing, scaled to the stress drawing's size, then relaxed toward stress while no link crosses another
  let T = planarDrawing(N, E);
  if (!T) return turned(X, aspect);
  // fit to D: the least-squares scale
  let num = 0, den = 0;
  for (let a = 0; a < N; a++) for (let b = a + 1; b < N; b++) { const d = D[a][b], c = len(T[a][0] - T[b][0], T[a][1] - T[b][1]); num += c / d; den += c * c / (d * d); }
  const s = den > 0 ? num / den : 1;
  T = T.map((p) => [p[0] * s, p[1] * s]);
  relaxPlanar(T, D, E);
  return turned(T, aspect);
}

const orient = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
const crossPts = (p, q, r, s) => { const d1 = orient(p, q, r), d2 = orient(p, q, s), d3 = orient(r, s, p), d4 = orient(r, s, q); return d1 * d2 < 0 && d3 * d4 < 0; };
const ptSeg = (p, a, b) => {
  const dx = b[0] - a[0], dy = b[1] - a[1], L2 = dx * dx + dy * dy;
  let t = L2 > 0 ? ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2 : 0;
  t = Math.max(0, Math.min(1, t));
  return len(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy);
};

/** Stress steps on a drawing with no crossing, each point moved toward its target only as far (halved up to six times) as keeps it so. */
function relaxPlanar(X, D, E) {
  const N = X.length, inc = X.map(() => []);
  E.forEach(([a, b], k) => { inc[a].push(k); inc[b].push(k); });
  let minD = Infinity;
  for (let a = 0; a < N; a++) for (let b = a + 1; b < N; b++) minD = Math.min(minD, D[a][b]);
  const sep = 0.25 * minD;
  // a point's clearance: how near it comes to another point or another's link, and its links to other points
  const clearance = (a) => {
    let m = Infinity;
    for (const k of inc[a]) { const [p, q] = E[k]; for (let v = 0; v < N; v++) if (v !== p && v !== q) m = Math.min(m, ptSeg(X[v], X[p], X[q])); }
    for (const [r, s] of E) if (r !== a && s !== a) m = Math.min(m, ptSeg(X[a], X[r], X[s]));
    for (let v = 0; v < N; v++) if (v !== a) m = Math.min(m, len(X[v][0] - X[a][0], X[v][1] - X[a][1]));
    return m;
  };
  const crossesAt = (a) => {
    for (const k of inc[a]) {
      const [p, q] = E[k];
      for (let l = 0; l < E.length; l++) {
        const [r, s] = E[l];
        if (r === p || r === q || s === p || s === q) continue;
        if (crossPts(X[p], X[q], X[r], X[s])) return true;
      }
    }
    return false;
  };
  // a move keeps every link uncrossed, and the point as clear as `sep` (or as clear as it was, when it wasn't)
  const ok = (a, m0) => !crossesAt(a) && clearance(a) >= Math.min(sep, m0);
  for (let sweep = 0; sweep < 200; sweep++) {
    let moved = 0;
    for (let a = 0; a < N; a++) {
      const t = target(X, D, a), o = X[a], m0 = clearance(a);
      for (let f = 1; f >= 1 / 64; f /= 2) {
        X[a] = [o[0] + f * (t[0] - o[0]), o[1] + f * (t[1] - o[1])];
        if (ok(a, m0)) { moved += f * len(t[0] - o[0], t[1] - o[1]); break; }
        X[a] = o;
      }
    }
    if (moved < 1 * N) break;
  }
}

/** The points (by item, `null` for the unlinked) with x stretched and y squeezed so their box has the view's shape, or null when it has it already. */
function stretched(C, linked, aspect) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const i of linked) { x0 = Math.min(x0, C[i][0]); y0 = Math.min(y0, C[i][1]); x1 = Math.max(x1, C[i][0]); y1 = Math.max(y1, C[i][1]); }
  const w = x1 - x0, h = y1 - y0;
  if (w < 1 || h < 1) return null;
  const r = w / h / aspect;
  if (r > 0.8 && r < 1.25) return null;
  const k = Math.max(0.5, Math.min(2, Math.sqrt(1 / r))), mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
  return C.map((c) => (c ? [mx + (c[0] - mx) * k, my + (c[1] - my) / k] : null));
}

/** The points turned so their long axis runs the way the view's does, about their middle. */
function turned(X, aspect) {
  const N = X.length;
  let mx = 0, my = 0;
  for (const p of X) { mx += p[0]; my += p[1]; }
  mx /= N; my /= N;
  let sxx = 0, syy = 0, sxy = 0;
  for (const p of X) { const dx = p[0] - mx, dy = p[1] - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy; }
  const half = (sxx - syy) / 2, lead = (sxx + syy) / 2 + Math.sqrt(half * half + sxy * sxy);
  let ex = sxy, ey = lead - sxx;
  if (Math.abs(ex) + Math.abs(ey) < 1e-9) { ex = sxx >= syy ? 1 : 0; ey = sxx >= syy ? 0 : 1; }
  const el = len(ex, ey);
  ex /= el; ey /= el;
  return X.map((p) => {
    const dx = p[0] - mx, dy = p[1] - my, along = dx * ex + dy * ey, across = -dx * ey + dy * ex;
    return aspect < 1 ? [-across, along] : [along, across];
  });
}

/** The container's children at their note middles (`C`, by item), their arrangements (`geo.alt`) and the pairs their arrows join, kept clean. */
class Solver {
  constructor(items, geo, pairs, linked, C, D, near) {
    this.items = items; this.geo = geo; this.C = C; this.linked = linked; this.D = D; this.near = near;
    this.pairs = pairs.filter((p) => C[p.a] && C[p.b]);
    this.inc = items.map(() => []);
    this.pairs.forEach((p, k) => { this.inc[p.a].push(k); this.inc[p.b].push(k); });
    this.excused = new Uint8Array(this.pairs.length);
    this.cl = null; this.members = []; this.hc = null; this.placedNow = null; this.byWeight = false;
  }

  /** The frames among the children: `cl` each child's (an index into `members`, or -1), `spec` each frame's inset, least size and title. */
  clusters(cl, members, spec) { this.cl = cl; this.members = members; this.spec = spec; }

  /** What was down has moved: the frames' boxes are drawn again when next asked. */
  dirty() { this.hc = null; }

  isDown(j) { return !!this.C[j] && (!this.placedNow || !!this.placedNow[j]); }

  /** Frame k's box round its members that are down, with member `who` at `c` in arrangement `a` (else as they stand): null with none down. */
  hullOf(k, who, c, a) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const m of this.members[k]) {
      let F;
      if (m === who) F = shift(this.geo.unit(m, a).foot, c);
      else if (this.isDown(m)) F = shift(this.geo.unit(m).foot, this.C[m]);
      else continue;
      x0 = Math.min(x0, F.x); y0 = Math.min(y0, F.y); x1 = Math.max(x1, F.x + F.w); y1 = Math.max(y1, F.y + F.h);
    }
    return x0 === Infinity ? null : frameBox(this.spec[k], x0, y0, x1, y1);
  }

  /** The room frame k's members take, about the first of them put down (its footprint F): a square, as wide as roomOf says. */
  roomAt(k, F) {
    const side = this.roomOf(k), cx = F.x + F.w / 2, cy = F.y + F.h / 2;
    return [Math.min(F.x, cx - side / 2), Math.min(F.y, cy - side / 2), Math.max(F.x + F.w, cx + side / 2), Math.max(F.y + F.h, cy + side / 2)];
  }

  /** The side of a square that holds frame k's members, each with the gap kept about it. */
  roomOf(k) {
    if (!this.rooms) this.rooms = new Map();
    if (!this.rooms.has(k)) {
      let a = 0;
      for (const m of this.members[k]) { const f = this.geo.unit(m).foot; a += (f.w + GAP) * (f.h + GAP); }
      this.rooms.set(k, Math.sqrt(a));
    }
    return this.rooms.get(k);
  }

  hull(k) {
    if (!this.hc) this.hc = this.members.map(() => undefined);
    if (this.hc[k] === undefined) this.hc[k] = this.hullOf(k, -1);
    return this.hc[k];
  }

  /** Whether segment `s` of pair p runs over a frame that holds neither of its ends. */
  overFrames(s, p) {
    if (!this.cl) return false;
    const ka = this.cl[p.a], kb = this.cl[p.b];
    for (let k = 0; k < this.members.length; k++) {
      if (k === ka || k === kb) continue;
      const H = this.hull(k);
      if (H && (segHitsBox(s, H.box, -MARGIN) || (H.tab && segHitsBox(s, H.tab, -MARGIN)))) return true;
    }
    return false;
  }

  /**
   * Whether child v at `c` in `a` keeps the frames clear: v off every frame it isn't in; and, a member, its frame's box (grown to hold it)
   * on no other child or frame, and under no arrow that ends at none of its members.
   */
  framesOk(v, c, a, reserve) {
    if (!this.cl) return true;
    const F = shift(this.geo.unit(v, a).foot, c), kv = this.cl[v];
    for (let k = 0; k < this.members.length; k++) { if (k === kv) continue; const H = this.hull(k); if (H && nearBox(F, H.foot, GAP)) return false; }
    if (kv < 0) return true;
    let H;
    if (reserve && !this.members[kv].some((m) => m !== v && this.isDown(m))) {
      // the first of its frame's members put down: room about it for them all
      const R = this.roomAt(kv, F);
      H = frameBox(this.spec[kv], R[0], R[1], R[2], R[3]);
    } else H = this.hullOf(kv, v, c, a);
    for (const j of this.linked) {
      if (j === v || this.cl[j] === kv || !this.isDown(j)) continue;
      if (nearBox(shift(this.geo.unit(j).foot, this.C[j]), H.foot, GAP)) return false;
    }
    for (let k = 0; k < this.members.length; k++) { if (k === kv) continue; const G = this.hull(k); if (G && nearBox(G.foot, H.foot, GAP)) return false; }
    for (let q = 0; q < this.pairs.length; q++) {
      const p = this.pairs[q];
      if (this.excused[q] || this.cl[p.a] === kv || this.cl[p.b] === kv || !this.isDown(p.a) || !this.isDown(p.b)) continue;
      for (const path of this.paths(p, this.C[p.a], this.C[p.b])) for (const s of path) {
        if (segHitsBox(s, H.box, -MARGIN) || (H.tab && segHitsBox(s, H.tab, -MARGIN))) return false;
      }
    }
    return true;
  }

  /** The polylines the app draws a pair's lines as (a bowed one through the point its bend puts off the middle), at middles `ca`, `cb`. */
  paths(p, ca, cb) {
    const out = [];
    const dx = cb[0] - ca[0], dy = cb[1] - ca[1], L = len(dx, dy) || 1;
    for (let k = 0; k < p.lines; k++) {
      const steps = k % 2 ? (k + 1) / 2 : -(k / 2);
      if (!steps) { out.push([{ x1: ca[0], y1: ca[1], x2: cb[0], y2: cb[1] }]); continue; }
      const mx = (ca[0] + cb[0]) / 2 - (dy / L) * steps * BEND, my = (ca[1] + cb[1]) / 2 + (dx / L) * steps * BEND;
      out.push([{ x1: ca[0], y1: ca[1], x2: mx, y2: my }, { x1: mx, y1: my, x2: cb[0], y2: cb[1] }]);
    }
    return out;
  }

  /** Whether segment `s` runs over child j as it stands (centre c, arrangement a): its note, title's room, pills, or across a pill's line. */
  segOver(s, j, c, a) {
    const g = this.geo.unit(j, a);
    if (!segHitsBox(s, shift(g.foot, c), -MARGIN)) return false;
    if (segHitsBox(s, shift(g.note, c), -MARGIN)) return true;
    if (g.tab && segHitsBox(s, shift(g.tab, c), -MARGIN)) return true;
    for (const p of g.pills) if (segHitsBox(s, shift(p, c), -MARGIN)) return true;
    for (const l of g.lines) if (segCross(s, shiftSeg(l, c))) return true;
    return false;
  }

  /** Whether segment `s` (a line of child i's) runs over one of i's own pills. */
  overOwn(s, i, c, a) {
    const g = this.geo.unit(i, a);
    for (const p of g.pills) if (segHitsBox(s, shift(p, c), -MARGIN)) return true;
    return false;
  }

  /** Pair k's paths with child `who` at `c` in arrangement `a` (else as it stands). */
  pathsOf(k, who, c) {
    const p = this.pairs[k];
    return this.paths(p, p.a === who ? c : this.C[p.a], p.b === who ? c : this.C[p.b]);
  }

  /** Whether pair k, drawn with child `who` at `c` in arrangement `a`, is clean: over no child but its ends, over neither end's pills, crossing no other pair. */
  pairClean(k, who, c, a) {
    const p = this.pairs[k];
    const ca = p.a === who ? c : this.C[p.a], cb = p.b === who ? c : this.C[p.b];
    const aa = p.a === who ? a : this.geo.alt[p.a], ab = p.b === who ? a : this.geo.alt[p.b];
    const ps = this.paths(p, ca, cb);
    for (const path of ps) for (const s of path) {
      if (this.overOwn(s, p.a, ca, aa) || this.overOwn(s, p.b, cb, ab) || this.overFrames(s, p)) return false;
      for (const j of this.linked) {
        if (j === p.a || j === p.b) continue;
        if (this.segOver(s, j, j === who ? c : this.C[j], j === who ? a : this.geo.alt[j])) return false;
      }
    }
    for (let l = 0; l < this.pairs.length; l++) {
      if (l === k || this.excused[l]) continue;
      const q = this.pairs[l];
      if (q.a === p.a || q.a === p.b || q.b === p.a || q.b === p.b) continue;
      const qs = this.pathsOf(l, who, c);
      for (const path of ps) for (const s of path) for (const qp of qs) for (const t of qp) if (segCross(s, t)) return false;
    }
    return true;
  }

  /** Whether child i at `c` in arrangement `a` keeps the container clean (the rest as they stand, clean among themselves). */
  clean(i, c, a) {
    if (!this.framesOk(i, c, a)) return false;
    const g = this.geo.unit(i, a), F = shift(g.foot, c);
    for (const j of this.linked) {
      if (j === i) continue;
      const h = this.geo.unit(j), G = shift(h.foot, this.C[j]);
      if (F.x < G.x + G.w + GAP && G.x < F.x + F.w + GAP && F.y < G.y + G.h + GAP && G.y < F.y + F.h + GAP) return false;
    }
    for (const k of this.inc[i]) if (!this.excused[k] && !this.pairClean(k, i, c, a)) return false;
    for (let k = 0; k < this.pairs.length; k++) {
      const p = this.pairs[k];
      if (this.excused[k] || p.a === i || p.b === i) continue;
      for (const path of this.paths(p, this.C[p.a], this.C[p.b])) for (const s of path) if (this.segOver(s, i, c, a)) return false;
    }
    return true;
  }

  /**
   * The children put down one at a time, each where it keeps the container clean nearest its placed neighbours, in the direction the planar
   * drawing (`C` as it comes in) puts it from them: the most linked first, then always the one with the most neighbours down already. A
   * child's arrows to placed neighbours that no spot lets out clean are excused. `keep`: children that stay where they are (an earlier
   * round's), unless they are not clean there, when they are put down again.
   */
  incremental(keep) {
    const L = this.linked, n = this.items.length, P = this.C.map((c) => (c ? c.slice() : null));
    const C = this.C;
    const placed = new Uint8Array(n);
    this.placedNow = placed; this.dirty();
    const drawnNb = this.items.map(() => []);
    this.pairs.forEach((p, k) => { drawnNb[p.a].push([p.b, k]); drawnNb[p.b].push([p.a, k]); });
    const wantOf = (i, j) => {
      const dx = P[j][0] - P[i][0], dy = P[j][1] - P[i][1], d = len(dx, dy), ux = d ? dx / d : 1, uy = d ? dy / d : 0;   // two at one point: side by side
      return this.exitT(i, ux, uy) + this.exitT(j, -ux, -uy) + GAP + 40;
    };
    if (keep) {
      for (const i of L) C[i] = null;
      for (const i of keep) { C[i] = P[i]; placed[i] = 1; }
      // what isn't clean as it is goes down again
      for (;;) {
        let worst = -1, wv = 0;
        for (const i of keep) { if (!placed[i]) continue; const v = this.badPlaced(i, C[i], this.geo.alt[i], placed); if (v > wv) { wv = v; worst = i; } }
        if (worst < 0) break;
        placed[worst] = 0; C[worst] = null; this.dirty();
      }
    }
    const remaining = new Set(L.filter((i) => !placed[i]));
    let down = 0;
    while (remaining.size) {
      // the next: a frame's member, then most drawn neighbours down, then most links, then index (a frame's members after one another:
      // each of them is linked to the rest)
      let v = -1, vs = -1;
      for (const i of remaining) {
        let s = this.cl && this.cl[i] >= 0 ? 1e8 : 0;
        for (const [j] of drawnNb[i]) if (placed[j]) s += 1000;
        for (const [j, w] of this.near[i]) if (placed[j]) s += 10 * Math.min(w, 3);
        s += drawnNb[i].length + 0.01 * this.near[i].size;
        if (s > vs) { vs = s; v = i; }
      }
      remaining.delete(v);
      this.placeOne(v, placed, drawnNb, P, wantOf);
      placed[v] = 1; this.dirty();
      down++;
    }
    this.placedNow = null; this.dirty();
    return down;
  }

  exitT(i, ux, uy) {
    const f = this.geo.unit(i).foot;
    const tx = ux > 1e-12 ? (f.x + f.w) / ux : ux < -1e-12 ? f.x / ux : Infinity, ty = uy > 1e-12 ? (f.y + f.h) / uy : uy < -1e-12 ? f.y / uy : Infinity;
    return Math.min(tx, ty);
  }

  /** How far from clean child i at `c` in `a` is among the placed (the pairs both of whose ends are down). */
  badPlaced(i, c, a, placed) {
    const save = this.C;
    let v = this.framesOk(i, c, a) ? 0 : 1;
    const g = this.geo.unit(i, a), F = shift(g.foot, c);
    for (const j of this.linked) {
      if (j === i || !placed[j]) continue;
      const G = shift(this.geo.unit(j).foot, this.C[j]);
      if (F.x < G.x + G.w + GAP && G.x < F.x + F.w + GAP && F.y < G.y + G.h + GAP && G.y < F.y + F.h + GAP) v += 2;
    }
    for (let k = 0; k < this.pairs.length; k++) {
      const p = this.pairs[k];
      if (this.excused[k] || !placed[p.a] || !placed[p.b]) continue;
      if (p.a === i || p.b === i) { if (!this.edgeOk(k, i, c, a, placed)) v++; continue; }
      for (const path of this.paths(p, this.C[p.a], this.C[p.b])) for (const s of path) if (this.segOver(s, i, c, a)) { v++; break; }
    }
    return v;
  }

  /** Whether pair k is clean with child `who` at `c` in `a`, among the placed: over neither end's pills, no placed child, crossing no placed pair. */
  edgeOk(k, who, c, a, placed) {
    const p = this.pairs[k];
    const ca = p.a === who ? c : this.C[p.a], cb = p.b === who ? c : this.C[p.b];
    const aa = p.a === who ? a : this.geo.alt[p.a], ab = p.b === who ? a : this.geo.alt[p.b];
    const ps = this.paths(p, ca, cb);
    for (const path of ps) for (const s of path) {
      if (this.overOwn(s, p.a, ca, aa) || this.overOwn(s, p.b, cb, ab) || this.overFrames(s, p)) return false;
      for (const j of this.linked) {
        if (j === p.a || j === p.b || !placed[j] || j === who) continue;
        if (this.segOver(s, j, this.C[j], this.geo.alt[j])) return false;
      }
    }
    for (let l = 0; l < this.pairs.length; l++) {
      if (l === k || this.excused[l]) continue;
      const q = this.pairs[l];
      if (!placed[q.a] || !placed[q.b] || q.a === who || q.b === who) continue;
      if (q.a === p.a || q.a === p.b || q.b === p.a || q.b === p.b) continue;
      const qs = this.paths(q, this.C[q.a], this.C[q.b]);
      for (const path of ps) for (const s of path) for (const qp of qs) for (const t of qp) if (segCross(s, t)) return false;
    }
    return true;
  }

  /** Child v put down: the spot, and arrangement of its pills, that lets the most of its arrows to placed neighbours out clean, nearest them. */
  placeOne(v, placed, drawnNb, P, wantOf) {
    const C = this.C;
    const nb = drawnNb[v].filter(([j]) => placed[j]);
    const aff = [...this.near[v]].filter(([j]) => placed[j]);
    let anyPlaced = false;
    for (const j of this.linked) if (placed[j]) { anyPlaced = true; break; }
    if (!anyPlaced) { C[v] = [0, 0]; this.geo.alt[v] = this.pickFor(v, [], drawnNb[v].length); return; }
    // where the planar drawing wants it: from each placed neighbour, its direction there, at the length the two footprints need
    const ref = nb.length ? nb.map(([j]) => j) : aff.map(([j]) => j);
    // a redraw's put-down (`byWeight`): each placed neighbour pulls by its link's weight against the weights of the note's own links, so the note lands beside the
    // ones it is most tightly linked to; `pull.rel` is a neighbour's weight over the mean, `pull.cap` what the cap of 3 on a link's pull comes to for the note's links
    // as a whole (the mean's, kept in proportion). Where the weights are all alike nothing is weighed: each neighbour pulls as it did, by min(weight, 3).
    let pull = null;
    if (this.byWeight && aff.length > 1) {
      let lo = Infinity, hi = -Infinity, sum = 0;
      // the weights are the links' own (an arrow's link counts in `near` as much again as a pill's, which weighs nothing)
      const own = this.linkW ? this.linkW[v] : null;
      const waff = aff.map(([j, w]) => [j, own && own.has(j) ? own.get(j) : w]);
      for (const [, w] of waff) { lo = Math.min(lo, w); hi = Math.max(hi, w); sum += w; }
      if (hi > lo) { const mean = sum / aff.length; pull = { rel: new Map(waff.map(([j, w]) => [j, w / mean])), cap: Math.min(1, 3 / mean) }; }
    }
    const rel = (j) => (pull && pull.rel.has(j) ? pull.rel.get(j) : 1);
    let gx = 0, gy = 0, wsum = 0;
    for (const j of ref) {
      const dx = P[v][0] - P[j][0], dy = P[v][1] - P[j][1], d = len(dx, dy) || 1, want = wantOf(j, v), r = rel(j);
      gx += (C[j][0] + dx / d * want) * r; gy += (C[j][1] + dy / d * want) * r; wsum += r;
    }
    if (!wsum) {   // nothing of its own down: beside the middle of what is
      let mx = 0, my = 0, k = 0;
      for (const j of this.linked) if (placed[j]) { mx += C[j][0]; my += C[j][1]; k++; }
      gx = mx; gy = my; wsum = k;
    }
    const g = [gx / wsum, gy / wsum];
    const unit = ref.length ? ref.reduce((s, j) => s + wantOf(j, v), 0) / ref.length : 600;
    const cands = [g];
    if (nb.length > 1) {   // the middle of its placed neighbours, and round it
      let mx = 0, my = 0;
      for (const [j] of nb) { mx += C[j][0]; my += C[j][1]; }
      mx /= nb.length; my /= nb.length;
      cands.push([mx, my]);
      if (pull) {   // and the middle the weights give
        let wx = 0, wy = 0, ws = 0;
        for (const [j] of nb) { wx += C[j][0] * rel(j); wy += C[j][1] * rel(j); ws += rel(j); }
        cands.push([wx / ws, wy / ws]);
      }
      for (let r = 1; r <= 6; r++) for (let t = 0; t < 24; t++) { const th = t * TWO_PI / 24; cands.push([mx + r * 0.2 * unit * cosd(th), my + r * 0.2 * unit * sind(th)]); }
    }
    for (let r = 1; r <= 14; r++) for (let t = 0; t < 24; t++) { const th = t * TWO_PI / 24; cands.push([g[0] + r * 0.2 * unit * cosd(th), g[1] + r * 0.2 * unit * sind(th)]); }
    for (const [j] of nb) for (const f of [1, 1.3, 1.7, 2.2, 3, 4]) for (let t = 0; t < 24; t++) { const th = t * TWO_PI / 24, w = wantOf(j, v) * f; cands.push([C[j][0] + w * cosd(th), C[j][1] + w * sind(th)]); }
    // a frame's member: beside each of its frame's members down, which it may not leave
    const mates = this.cl && this.cl[v] >= 0 ? this.members[this.cl[v]].filter((j) => j !== v && placed[j]) : [];
    for (const j of mates) for (const f of [1, 1.4, 2]) for (let t = 0; t < 24; t++) { const th = t * TWO_PI / 24, w = wantOf(j, v) * f; cands.push([C[j][0] + w * cosd(th), C[j][1] + w * sind(th)]); }
    const score = (c) => {
      let s = 0.5 * len(c[0] - g[0], c[1] - g[1]);
      for (const [j] of nb) s += rel(j) * len(c[0] - C[j][0], c[1] - C[j][1]);
      for (const [j, w] of aff) s += 0.3 * (pull ? w * pull.cap : Math.min(w, 3)) * len(c[0] - C[j][0], c[1] - C[j][1]);
      return s;
    };
    const scored = cands.map((c) => [score(c), c]).sort((x, y) => x[0] - y[0] || x[1][0] - y[1][0] || x[1][1] - y[1][1]);
    let best = null;
    const unplacedDeg = drawnNb[v].length - nb.length;
    // a frame's member: the ways out its frame's members down need to the shapes outside it not yet down (each from its note toward where
    // the points put the other), and its own, which it is not to block, nor have blocked
    const ways = [], own = [];
    let blocking = null;
    if (mates.length) {
      const kv = this.cl[v], reach = this.roomOf(kv);
      const toward = (m, o, from) => { const dx = P[o][0] - P[m][0], dy = P[o][1] - P[m][1], d = len(dx, dy) || 1; return { x1: from[0], y1: from[1], x2: from[0] + dx / d * reach, y2: from[1] + dy / d * reach }; };
      for (const m of mates) for (const [o] of drawnNb[m]) if (!placed[o] && this.cl[o] !== kv) ways.push(toward(m, o, C[m]));
      for (const [o] of drawnNb[v]) if (!placed[o] && this.cl[o] !== kv) own.push(o);
      blocking = (c, a) => {
        let b = 0;
        const F = shift(this.geo.unit(v, a).foot, c);
        for (const s of ways) if (segHitsBox(s, F, -MARGIN)) b++;
        for (const o of own) {
          const s = toward(v, o, c);
          for (const m of mates) if (segHitsBox(s, shift(this.geo.unit(m).foot, C[m]), -MARGIN)) { b++; break; }
        }
        return b;
      };
    }
    let tries = 0;
    const arrowed = new Set(drawnNb[v].map(([j]) => j));
    // `only`: a spot is taken only where it passes (a frame's own box, for a put-down that is not to make it grow)
    const consider = (list, only, gap) => {
      for (const [sc, c] of list) {
        if (best && sc >= best.total) break;
        if (best && !best.failed && ++tries > 200) break;
        const dirs = nb.map(([j]) => atan2d(C[j][1] - c[1], C[j][0] - c[0]));
        const a = this.pickFor(v, dirs, unplacedDeg);
        if (only && !only(c, a)) continue;
        if (!this.hardOk(v, c, a, placed, gap, gap < GAP ? arrowed : null)) continue;
        let failed = 0;
        for (const [, k] of nb) if (!this.excused[k] && !this.edgeOk(k, v, c, a, placed)) failed++;
        const blocks = blocking ? blocking(c, a) : 0;
        const total = failed * (this.cl ? FRAME_FAIL : 1e9) + blocks * BLOCKED + sc;
        if (!best || total < best.total) best = { c, a, total, failed };
        if (!failed && !blocks) break;
      }
    };
    // the spots that touch a placed child, each side of it, at three alignments: the free ground left in a pocket the rings' steps skip over
    // `byNote`: for a child the note has an arrow to, the spot is GAP from its note (the arrow's room), whatever `near` is from the others' footprints
    const touching = (near = GAP + 1, byNote = false) => {
      const u = this.geo.unit(v, this.pickFor(v, [], unplacedDeg)), touch = [];
      for (const j of this.linked) {
        if (!placed[j] || j === v) continue;
        const noted = byNote && arrowed.has(j), f = noted ? u.note : u.foot, hold = this.geo.unit(j), F = shift(noted ? hold.note : hold.foot, C[j]), near_ = noted ? GAP : near;
        for (const y of [F.y - f.y, F.y + F.h / 2 - f.y - f.h / 2, F.y + F.h - f.y - f.h]) { touch.push([F.x + F.w + near_ - f.x, y]); touch.push([F.x - near_ - (f.x + f.w), y]); }
        for (const x of [F.x - f.x, F.x + F.w / 2 - f.x - f.w / 2, F.x + F.w - f.x - f.w]) { touch.push([x, F.y + F.h + near_ - f.y]); touch.push([x, F.y - near_ - (f.y + f.h)]); }
      }
      return touch.map((c) => [score(c), c]).sort((x, y) => x[0] - y[0] || x[1][0] - y[1][0] || x[1][1] - y[1][1]);
    };
    // a child put down in a frame that grows (`grow`): the frame's own box first, where the room a person's shape left is (the rings and the
    // touching spots both), clean; the frame grows only where nothing there fits
    if (this.grow) {
      const g = this.grow, inside = (c, a) => { const F = shift(this.geo.unit(v, a).foot, c); return F.x + F.w + g.pad <= g.w && F.y + F.h + g.pad <= g.h; };
      // the room a person's shape left is as tight as the shape was: spots at exactly the gap from a placed child, and the frame's own top-left corner
      const f0 = this.geo.unit(v, this.pickFor(v, [], unplacedDeg)).foot, bx = this.bounds ? this.bounds.x : 0, by = this.bounds ? this.bounds.y : 0;
      const exact = touching(GAP).concat([[bx - f0.x, by - f0.y]].map((c) => [score(c), c]));
      const own = scored.concat(touching(), exact).sort((x, y) => x[0] - y[0] || x[1][0] - y[1][0] || x[1][1] - y[1][1]);
      consider(own, inside);
      if (best && (best.failed || (blocking && blocking(best.c, best.a)))) best = null;
      tries = 0;
      // no spot with the gap between children that stars keeps: a room the file had drawn tighter (rows packed by their own spacing, which a title's row takes part of) is still room,
      // so the spots in the frame's box at the least gap come before the frame grows
      if (!best) {
        const tight = scored.concat(touching(TIGHT_GAP + 1, true), touching(TIGHT_GAP, true), [[bx - f0.x, by - f0.y]].map((c) => [score(c), c])).sort((x, y) => x[0] - y[0] || x[1][0] - y[1][0] || x[1][1] - y[1][1]);
        consider(tight, inside, TIGHT_GAP);
        if (best && (best.failed || (blocking && blocking(best.c, best.a)))) best = null;
        tries = 0;
      }
    }
    if (!best) consider(scored);
    // a child put down among held ones, with no spot among those tried (the free ground is in pockets narrower than the rings' steps): the spots
    // that touch a placed child, before it goes outside everything
    if (!best && this.dense) consider(touching());
    if (!best && mates.length) {
      // a frame's member with nowhere near: its frame's members down moved together past everything else, and it put beside them; their
      // arrows to the rest that this leaves unclean are excused
      const kv = this.cl[v];
      let x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
      for (const j of this.linked) if (placed[j] && this.cl[j] !== kv) { const F = shift(this.geo.unit(j).foot, C[j]); x1 = Math.max(x1, F.x + F.w); y0 = Math.min(y0, F.y); y1 = Math.max(y1, F.y + F.h); }
      for (let k = 0; k < this.members.length; k++) { const G = k === kv ? null : this.hull(k); if (G) { x1 = Math.max(x1, G.foot.x + G.foot.w); y0 = Math.min(y0, G.foot.y); y1 = Math.max(y1, G.foot.y + G.foot.h); } }
      const H0 = this.hullOf(kv, -1);
      if (x1 > -Infinity) {
        const dx = x1 + GAP * 4 - H0.foot.x, dy = (y0 + y1) / 2 - (H0.foot.y + H0.foot.h / 2);
        for (const j of mates) C[j] = [C[j][0] + dx, C[j][1] + dy];
        this.dirty();
      }
      let mx = -Infinity, my = Infinity;
      for (const j of mates) { const F = shift(this.geo.unit(j).foot, C[j]); mx = Math.max(mx, F.x + F.w); my = Math.min(my, F.y); }
      const a = this.pickFor(v, [], unplacedDeg), f = this.geo.unit(v, a).foot;
      best = { c: [mx + GAP - f.x, my - f.y], a, failed: nb.length };
      for (const j of mates) for (const [o, k] of drawnNb[j]) if (placed[o] && this.cl[o] !== kv && !this.excused[k] && !this.edgeOk(k, j, C[j], this.geo.alt[j], placed)) this.excused[k] = 1;
    }
    if (!best) {
      if (this.note) this.note.fellBack = true;
      // nowhere near: outside everything placed, on the side nearest where it is wanted
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const j of this.linked) if (placed[j]) { const F = shift(this.geo.unit(j).foot, C[j]); x0 = Math.min(x0, F.x); y0 = Math.min(y0, F.y); x1 = Math.max(x1, F.x + F.w); y1 = Math.max(y1, F.y + F.h); }
      const a = this.pickFor(v, [], unplacedDeg), f = this.geo.unit(v, a).foot;
      const c = [x1 + GAP * 4 - f.x, (y0 + y1) / 2];
      best = { c, a, failed: nb.length };
    }
    C[v] = best.c; this.geo.alt[v] = best.a;
    for (const [, k] of nb) if (!this.excused[k] && !this.edgeOk(k, v, best.c, best.a, placed)) this.excused[k] = 1;
  }

  /** Child v's arrangement for arrows leaving it in `dirs` (and `more` to come): the fewest blocked, then the most room left free for those to come, then the smallest. */
  pickFor(v, dirs, more) {
    if (!this.items[v].alts) return this.geo.alt[v];
    let best = -1, bestCost = Infinity;
    for (const a of this.geo.arrangements(v)) {
      const g = this.geo.unit(v, a);
      let nb = 0;
      for (const t of dirs) if (this.blockedDir(v, a, t)) nb++;
      const blockedAngle = this.blockedShare(v, a) * TWO_PI;
      const cost = nb * 1e12 + (g.column ? 1e10 : 0) + (more ? blockedAngle * 1e7 * more : 0) + g.area;
      if (cost < bestCost) { bestCost = cost; best = a; }
    }
    return best;
  }

  /** What may never be: child v at `c` in `a` on a placed footprint, or a placed pair's arrow over it. */
  hardOk(v, c, a, placed, gap = GAP, arrowed = null) {
    if (!this.framesOk(v, c, a, true)) return false;
    const F = shift(this.geo.unit(v, a).foot, c);
    if (this.bounds && (F.x < this.bounds.x || F.y < this.bounds.y)) return false;
    if (this.grow && this.growsOver(F)) return false;
    for (const j of this.linked) {
      if (j === v || !placed[j]) continue;
      const G = shift(this.geo.unit(j).foot, this.C[j]);
      if (F.x < G.x + G.w + gap && G.x < F.x + F.w + gap && F.y < G.y + G.h + gap && G.y < F.y + F.h + gap) return false;
      if (arrowed && arrowed.has(j)) {   // an arrow's two ends keep the gap the arrow needs between their notes, whatever the least gap between footprints is
        const N = shift(this.geo.unit(v, a).note, c), M = shift(this.geo.unit(j).note, this.C[j]);
        if (N.x < M.x + M.w + GAP && M.x < N.x + N.w + GAP && N.y < M.y + M.h + GAP && M.y < N.y + N.h + GAP) return false;
      }
    }
    for (let k = 0; k < this.pairs.length; k++) {
      const p = this.pairs[k];
      if (this.excused[k] || !placed[p.a] || !placed[p.b] || p.a === v || p.b === v) continue;
      for (const path of this.paths(p, this.C[p.a], this.C[p.b])) for (const s of path) if (this.segOver(s, v, c, a)) return false;
    }
    return true;
  }

  /**
   * Whether a member's footprint `F`, in a frame that may grow right and down to hold it (`grow`: its size inside, its inset, the room its title
   * takes above it, and `avoid`, the boxes of the shapes beside it), makes the frame reach one of them.
   */
  growsOver(F) {
    const g = this.grow, w = Math.max(g.w, F.x + F.w + g.pad), h = Math.max(g.h, F.y + F.h + g.pad);
    if (w === g.w && h === g.h) return false;
    const R = { x: 0, y: -g.above, w, h: h + g.above }, R0 = { x: 0, y: -g.above, w: g.w, h: g.h + g.above };
    const hit = (A, B) => A.x < B.x + B.w && B.x < A.x + A.w && A.y < B.y + B.h && B.y < A.y + A.h;
    for (const o of g.avoid) if (!hit(R0, o) && hit(R, o)) return true;
    return false;
  }

  /**
   * Whether child i at `c` in arrangement `a` is clear of the placed ones as they stand: its note, title's room and pills on none of theirs, no
   * line of a pair between two placed over it, and its own pairs' lines to placed neighbours clear (`edgeOk`).
   */
  partsOk(i, c, a, placed) {
    const parts = (g, at) => [shift(g.note, at)].concat(g.tab ? [shift(g.tab, at)] : [], g.pills.map((p) => shift(p, at)));
    const mine = parts(this.geo.unit(i, a), c);
    for (const j of this.linked) {
      if (j === i || !placed[j]) continue;
      for (const B of parts(this.geo.unit(j), this.C[j])) for (const A of mine) if (nearBox(A, B, 4)) return false;
    }
    for (let k = 0; k < this.pairs.length; k++) {
      const p = this.pairs[k];
      if (this.excused[k] || !placed[p.a] || !placed[p.b]) continue;
      if (p.a === i || p.b === i) { if (!this.edgeOk(k, i, c, a, placed)) return false; continue; }
      for (const path of this.paths(p, this.C[p.a], this.C[p.b])) for (const s of path) if (this.segOver(s, i, c, a)) return false;
    }
    return true;
  }

  /** The placed children (but i) whose notes, titles or pills are on child i's, or whose footprint it reaches (a frame that grew). */
  reached(i, placed) {
    const parts = (g, at) => [shift(g.note, at)].concat(g.tab ? [shift(g.tab, at)] : [], g.pills.map((p) => shift(p, at)));
    const mine = parts(this.geo.unit(i), this.C[i]), out = [];
    for (const j of this.linked) {
      if (j === i || !placed[j]) continue;
      if (parts(this.geo.unit(j), this.C[j]).some((B) => mine.some((A) => nearBox(A, B, 4)))) out.push(j);
    }
    return out;
  }

  /** Whether child i's note and the room its title takes are on none of the placed ones' notes, titles or pills. */
  noteClear(i, c, a, placed) {
    const g = this.geo.unit(i, a), mine = [shift(g.note, c)].concat(g.tab ? [shift(g.tab, c)] : []);
    for (const j of this.linked) {
      if (j === i || !placed[j]) continue;
      const h = this.geo.unit(j), others = [shift(h.note, this.C[j])].concat(h.tab ? [shift(h.tab, this.C[j])] : [], h.pills.map((p) => shift(p, this.C[j])));
      for (const B of others) for (const A of mine) if (nearBox(A, B, 0)) return false;
    }
    return true;
  }

  /**
   * Children put down among held ones (`held[i]`: stays where it is): `flex`, the held children whose pills or note changed, take another
   * arrangement of their pills where they are if one is clear, else are put down again; then every child not held, the one with the most
   * neighbours down first, each where it keeps the container clean nearest them (`placeOne`). Nothing held moves.
   */
  putDown(held, flex, grew, weight, fixed, note, own) {
    this.note = note;
    this.dense = true;
    const n = this.items.length, P = this.C.map((c) => (c ? c.slice() : null)), C = this.C;
    const placed = new Uint8Array(n);
    this.placedNow = placed; this.dirty();
    const drawnNb = this.items.map(() => []);
    this.pairs.forEach((p, k) => { drawnNb[p.a].push([p.b, k]); drawnNb[p.b].push([p.a, k]); });
    const wantOf = (i, j) => {
      const dx = P[j][0] - P[i][0], dy = P[j][1] - P[i][1], d = len(dx, dy), ux = d ? dx / d : 1, uy = d ? dy / d : 0;
      return this.exitT(i, ux, uy) + this.exitT(j, -ux, -uy) + GAP + 40;
    };
    for (let i = 0; i < n; i++) { if (held[i]) placed[i] = 1; else C[i] = null; }
    // what a person put where they are (and a frame that holds it, grown about it) stays, and what it covers is put down again
    for (const i of [...fixed].sort((a, b) => a - b)) {
      if (!placed[i]) continue;
      // covered where it is a person's own shape that lies on it; reached where it is a frame, grown about a person's shape, that does
      for (const j of this.reached(i, placed)) if (!fixed.has(j)) { placed[j] = 0; C[j] = null; if (note) (own.has(i) ? note.covered : note.reached).add(j); this.dirty(); }
    }
    for (const i of flex) {
      if (!placed[i] || fixed.has(i)) continue;
      // a note that is on another's room, or another's on it, with no change of its own to blame (one a person put there) stays where it was put
      if (!grew.has(i) && !this.noteClear(i, C[i], this.geo.alt[i], placed)) continue;
      const cost = (a) => { const g = this.geo.unit(i, a); return (g.column ? 1e10 : 0) + g.area; };
      // a frame that grew is in the way of shapes beside it or not (the lines to it are the check's)
      let ok = this.items[i].alts ? this.partsOk(i, C[i], this.geo.alt[i], placed) : weight ? this.reached(i, placed).length === 0 : this.partsOk(i, C[i], this.geo.alt[i], placed);
      if (!ok && this.items[i].alts) {
        for (const a of this.geo.arrangements(i).sort((x, y) => cost(x) - cost(y) || x - y)) {
          if (a === this.geo.alt[i] || !this.partsOk(i, C[i], a, placed)) continue;
          this.geo.alt[i] = a; ok = true; this.dirty();
          break;
        }
      }
      // a frame that grew, on shapes beside it: they are put down again where they are fewer than the shapes it holds, else it is
      if (!ok && !this.items[i].alts && weight) {
        const hit = this.reached(i, placed), moved = hit.reduce((sum, j) => sum + (weight[j] || 1), 0);
        if (hit.length && moved < (weight[i] || 1)) { for (const j of hit) { placed[j] = 0; C[j] = null; if (note) note.reached.add(j); } ok = true; this.dirty(); }
      }
      if (!ok) { placed[i] = 0; C[i] = null; this.dirty(); }
    }
    const remaining = new Set(this.linked.filter((i) => !placed[i]));
    while (remaining.size) {
      let v = -1, vs = -1;
      for (const i of remaining) {
        let s = 0;
        for (const [j] of drawnNb[i]) if (placed[j]) s += 1000;
        for (const [j, w] of this.near[i]) if (placed[j]) s += 10 * Math.min(w, 3);
        s += drawnNb[i].length + 0.01 * this.near[i].size;
        if (s > vs) { vs = s; v = i; }
      }
      remaining.delete(v);
      this.placeOne(v, placed, drawnNb, P, wantOf);
      placed[v] = 1; this.dirty();
    }
    this.placedNow = null; this.dirty();
  }

  /** The drawing's area, more the further its shape is from `aspect` (width over height). */
  shapedArea(aspect) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const i of this.linked) { const F = shift(this.geo.unit(i).foot, this.C[i]); x0 = Math.min(x0, F.x); y0 = Math.min(y0, F.y); x1 = Math.max(x1, F.x + F.w); y1 = Math.max(y1, F.y + F.h); }
    const w = x1 - x0, h = y1 - y0, r = w / h / aspect;
    return w * h * Math.max(r, 1 / r);
  }

  areaM() {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const i of this.linked) { const F = shift(this.geo.unit(i).foot, this.C[i]); x0 = Math.min(x0, F.x); y0 = Math.min(y0, F.y); x1 = Math.max(x1, F.x + F.w); y1 = Math.max(y1, F.y + F.h); }
    return Math.round((x1 - x0) * (y1 - y0) / 1e5) / 10;
  }

  /** The directions (angular intervals [start, width], radians) in which a ray from child i's note middle runs over one of its pills, in arrangement a. */
  sectors(i, a) {
    if (!this.sectorMemo) this.sectorMemo = new Map();
    const key = i * 64 + a;
    if (this.sectorMemo.has(key)) return this.sectorMemo.get(key);
    const g = this.geo.unit(i, a), out = [];
    for (const p of g.pills) {
      const xs = [p.x - MARGIN, p.x + p.w + MARGIN], ys = [p.y - MARGIN, p.y + p.h + MARGIN];
      const angs = [];
      for (const x of xs) for (const y of ys) angs.push(atan2d(y, x));
      angs.sort((u, v) => u - v);
      // the interval is the circle less its largest gap between corners
      let gapAt = 3, gap = angs[0] + TWO_PI - angs[3];
      for (let k = 0; k < 3; k++) if (angs[k + 1] - angs[k] > gap) { gap = angs[k + 1] - angs[k]; gapAt = k; }
      const start = angs[(gapAt + 1) % 4];
      out.push([start, TWO_PI - gap]);
    }
    this.sectorMemo.set(key, out);
    return out;
  }

  /** The share of directions (of 180, every two degrees) in which child i's arrows would run over its own pills in arrangement a. */
  blockedShare(i, a) {
    if (!this.shareMemo) this.shareMemo = new Map();
    const key = i * 64 + a;
    if (this.shareMemo.has(key)) return this.shareMemo.get(key);
    let b = 0;
    for (let t = 0; t < 180; t++) if (this.blockedDir(i, a, -Math.PI + t * TWO_PI / 180)) b++;
    this.shareMemo.set(key, b / 180);
    return b / 180;
  }

  /** Whether direction t (radians) from child i's note middle runs over its own pills in arrangement a. */
  blockedDir(i, a, t) {
    for (const [s, w] of this.sectors(i, a)) { let d = t - s; while (d < 0) d += TWO_PI; while (d >= TWO_PI) d -= TWO_PI; if (d < w) return true; }
    return false;
  }

  /** Stress steps at the boxes' scale, and other arrangements of each note's pills, each taken only where the container stays clean. */
  compact(sweeps) {
    this.dirty();
    const L = this.linked, X = L.map((i) => this.C[i]);
    for (let sweep = 0; sweep < sweeps; sweep++) {
      let moved = 0;
      for (let k = 0; k < L.length; k++) {
        const i = L[k], o = this.C[i];
        X[k] = o;
        const t = target(X, this.D, k);
        for (let f = 1; f >= 1 / 32; f /= 2) {
          const c = [o[0] + f * (t[0] - o[0]), o[1] + f * (t[1] - o[1])];
          if (this.clean(i, c, this.geo.alt[i])) { this.C[i] = c; X[k] = c; this.dirty(); moved += f * len(t[0] - o[0], t[1] - o[1]); break; }
        }
        // another arrangement of its pills where it is: a smaller one that keeps the container clean
        if (this.items[i].alts) {
          const cur = this.geo.unit(i);
          let best = this.geo.alt[i], area = cur.area + (cur.column ? 1e10 : 0);
          for (const a of this.geo.arrangements(i)) {
            const g = this.geo.unit(i, a), cost = g.area + (g.column ? 1e10 : 0);
            if (a === best || cost >= area) continue;
            if (this.clean(i, this.C[i], a)) { best = a; area = cost; }
          }
          if (this.geo.alt[i] !== best) { this.geo.alt[i] = best; this.dirty(); }
        }
      }
      if (moved < 2 * L.length) return sweep;
    }
    return sweeps;
  }

  /**
   * Drawn together: each child moved toward the middle of the drawing, toward each of its neighbours or where stress wants it, whichever
   * keeps the container clean and makes the least of the drawing's area and its arrows' lengths; sweep after sweep until none moves.
   */
  gather(sweeps) {
    this.dirty();
    const L = this.linked, C = this.C;
    if (L.length < 2) return 0;
    const X = L.map((i) => C[i]);
    const nbOf = L.map((i) => this.inc[i].map((k) => { const p = this.pairs[k]; return p.a === i ? p.b : p.a; }));
    const affOf = L.map((i) => [...this.near[i]].filter(([j]) => C[j]).map(([j, w]) => [j, Math.min(w, 3)]));
    const box = (skip) => {
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const j of L) { if (j === skip) continue; const F = shift(this.geo.unit(j).foot, C[j]); x0 = Math.min(x0, F.x); y0 = Math.min(y0, F.y); x1 = Math.max(x1, F.x + F.w); y1 = Math.max(y1, F.y + F.h); }
      return [x0, y0, x1, y1];
    };
    const J = (k, c, a, rest) => {
      const i = L[k], F = shift(this.geo.unit(i, a).foot, c);
      const w = Math.max(rest[2], F.x + F.w) - Math.min(rest[0], F.x), h = Math.max(rest[3], F.y + F.h) - Math.min(rest[1], F.y);
      let l = 0;
      for (const j of nbOf[k]) l += len(C[j][0] - c[0], C[j][1] - c[1]);
      for (const [j, wt] of affOf[k]) l += 0.3 * wt * len(C[j][0] - c[0], C[j][1] - c[1]);
      return w * h + GATHER_LEN * l;
    };
    let sweep = 0;
    for (; sweep < sweeps; sweep++) {
      let better = 0;
      let mx = 0, my = 0;
      for (const i of L) { mx += C[i][0]; my += C[i][1]; }
      mx /= L.length; my /= L.length;
      for (let k = 0; k < L.length; k++) {
        const i = L[k], o = C[i], a0 = this.geo.alt[i];
        const rest = box(i);
        let best = null, bestJ = J(k, o, a0, rest) - 1;
        const cands = [];
        for (const f of [0.6, 0.35, 0.18, 0.08, 0.03]) cands.push([o[0] + f * (mx - o[0]), o[1] + f * (my - o[1])]);
        for (const j of nbOf[k]) for (const f of [0.3, 0.12, 0.04]) cands.push([o[0] + f * (C[j][0] - o[0]), o[1] + f * (C[j][1] - o[1])]);
        X[k] = o;
        const t = target(X, this.D, k);
        for (const f of [1, 0.5, 0.25, 0.1]) cands.push([o[0] + f * (t[0] - o[0]), o[1] + f * (t[1] - o[1])]);
        for (const c of cands) {
          const v = J(k, c, a0, rest);
          if (v >= bestJ) continue;
          if (this.clean(i, c, a0)) { best = c; bestJ = v; }
        }
        if (this.items[i].alts) for (const a of this.geo.arrangements(i)) {
          if (a === a0 || this.geo.unit(i, a).column) continue;
          const c = best || o, v = J(k, c, a, rest);
          if (v >= bestJ) continue;
          if (this.clean(i, c, a)) { best = c; bestJ = v; this.geo.alt[i] = a; this.dirty(); }
        }
        if (best) { C[i] = best; X[k] = best; this.dirty(); better++; }
      }
      if (!better) break;
    }
    return sweep;
  }
}

// the children shelved, and a pill put in a clear spot (`clearSpot`, which layout.mjs uses for a redraw in place)
const SHELF_GAP = 56;    // between two boxes
const SAT_GAP = 24;      // between a satellite (a shared pill) and another child: near its users, as a pill sits by its note
const gapOf = (a, b) => (a.satellite || b.satellite ? SAT_GAP : SHELF_GAP);
/** Whether two boxes (top-left `A`, `B`, sizes `a`, `b`) come nearer than the gap kept between them; a satellite also keeps off the room a note's title takes above it (`above`). */
const closeTo = (A, a, B, b) => {
  const g = gapOf(a, b), ta = b.satellite ? a.above || 0 : 0, tb = a.satellite ? b.above || 0 : 0;
  return A.x < B.x + b.w + g && B.x < A.x + a.w + g && A.y - ta < B.y + b.h + g && B.y - tb < A.y + a.h + g;
};
const H3 = Math.sqrt(3) / 2;
const TWELVE = [[1, 0], [H3, 0.5], [0.5, H3], [0, 1], [-0.5, H3], [-H3, 0.5], [-1, 0], [-H3, -0.5], [-0.5, -H3], [0, -1], [0.5, -H3], [H3, -0.5]];

/**
 * ln w for a link's weight (above 0: check.mjs refuses any other), with the four operations alone: w halved or doubled into [1, 2), each
 * time ln 2, then 2 atanh((w - 1) / (w + 1)) to its eleventh power, which is past the last bit a layout reads.
 */
const LN2 = 0.6931471805599453;
function lnOf(w) {
  if (!(w > 0)) return 0;
  if (w > 1e300) w = 1e300;   // a sum past what a weight may be (check.mjs bounds each), never Infinity, which halves forever
  let k = 0;
  while (w >= 2) { w /= 2; k++; }
  while (w < 1) { w *= 2; k--; }
  const z = (w - 1) / (w + 1), z2 = z * z;
  let p = z, s = z;
  for (let j = 1; j <= 5; j++) { p *= z2; s += p / (2 * j + 1); }
  return k * LN2 + 2 * s;
}

/**
 * The top-left of the spot nearest `centre` where item `i` clears every other placed box by the gap: rings of twelve ways 24 apart, out
 * to 4,000 (with `inside`, none left of or above the origin); where there is none, at `centre`.
 */
export function clearSpot(items, pos, i, centre, placed, inside) {
  const it = items[i];
  const clearAt = (x, y) => {
    for (const j of placed) {
      if (j === i || !pos[j]) continue;
      const B = pos[j], b = items[j];
      if (closeTo({ x, y }, it, B, b)) return false;
    }
    return true;
  };
  for (let r = 0; r <= 4000; r += 24) {
    for (const [c, s] of r === 0 ? [[0, 0]] : TWELVE) {
      const x = centre[0] + r * c - it.w / 2, y = centre[1] + r * s - it.h / 2;
      const least = inside === true ? 0 : inside || 0;   // `inside`: true, or the least x and y a spot may have (a frame's inset)
      if (inside && (x < least || y < least)) continue;
      if (clearAt(x, y)) return { x, y };
    }
  }
  return { x: centre[0] - it.w / 2, y: centre[1] - it.h / 2 };
}

/**
 * The children with no link, in rows along the short side of what is placed: below it when it is wider than the shape wanted, else to its
 * right; hung from the shape that reaches furthest that way (the lowest, or the rightmost), so the shelf is beside a shape, not in an empty
 * corner of what is placed, and no arrow among the placed can run over it.
 */
function shelve(items0, pos0, linked0, loose, aspect, extra = []) {
  if (!loose.length) return;
  // the frames' boxes are placed too: the shelf clears them
  const items = items0.concat(extra.map((b) => ({ w: b.w, h: b.h }))), pos = pos0.concat(extra.map((b) => ({ x: b.x, y: b.y })));
  const linked = linked0.concat(extra.map((b, k) => items0.length + k));
  let x0 = 0, y0 = 0, x1 = 0, y1 = 0, far = -1;
  if (linked.length) {
    x0 = Infinity; y0 = Infinity; x1 = -Infinity; y1 = -Infinity;
    for (const i of linked) { x0 = Math.min(x0, pos[i].x); y0 = Math.min(y0, pos[i].y); x1 = Math.max(x1, pos[i].x + items[i].w); y1 = Math.max(y1, pos[i].y + items[i].h); }
  }
  const below = !linked.length || (x1 - x0) / Math.max(1, y1 - y0) >= aspect;
  for (const i of linked) {
    const reach = below ? pos[i].y + items[i].h : pos[i].x + items[i].w, best = far < 0 ? -Infinity : below ? pos[far].y + items[far].h : pos[far].x + items[far].w;
    if (reach > best + 1e-9) far = i;
  }
  // rows as wide as what is placed (or a square of them, with nothing placed), or columns as tall
  const area = loose.reduce((s, i) => s + (items[i].w + SHELF_GAP) * (items[i].h + SHELF_GAP), 0);
  const span = linked.length ? (below ? x1 - x0 : y1 - y0) : Math.sqrt(area * aspect);
  const sx = far < 0 ? 0 : below ? pos[far].x : x1 + SHELF_GAP, sy = far < 0 ? 0 : below ? y1 + SHELF_GAP : pos[far].y;
  let cx = sx, cy = sy, line = 0;
  for (const i of loose) {
    const it = items[i];
    if (below) {
      if (cx > sx && cx + it.w > sx + Math.max(span, it.w)) { cx = sx; cy += line + SHELF_GAP; line = 0; }
      pos[i] = { x: cx, y: cy }; cx += it.w + SHELF_GAP; line = Math.max(line, it.h);
    } else {
      if (cy > sy && cy + it.h > sy + Math.max(span, it.h)) { cy = sy; cx += line + SHELF_GAP; line = 0; }
      pos[i] = { x: cx, y: cy }; cy += it.h + SHELF_GAP; line = Math.max(line, it.w);
    }
  }
  for (const i of loose) pos0[i] = pos[i];
}
