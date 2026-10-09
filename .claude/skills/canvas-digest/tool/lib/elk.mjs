// elkjs, unmodified (vendor/elk.bundled.js), run as a global script: it needs `window` and a console.
import { median } from './util.mjs';

let elkPromise = null;

/** `io.readText(path)` reads a file; `base` is the tool's folder. */
export function loadElk(io, base) {
  if (elkPromise) return elkPromise;
  const g = globalThis;
  if (typeof g.console === 'undefined') g.console = { log: io.print, error: io.print, warn: io.print };
  if (typeof g.window === 'undefined') g.window = g;
  const src = io.readText(base + '/vendor/elk.bundled.js');
  (0, eval)(src);
  elkPromise = Promise.resolve(new g.ELK());
  return elkPromise;
}

const SPACING = 64;   // between boxes: 64 below another keeps the row above clear for a title pill, and is over the 40 draw keeps beside

export const ALGORITHMS = {
  rectpacking: { 'elk.algorithm': 'rectpacking', 'elk.aspectRatio': '1.5', 'elk.spacing.nodeNode': String(SPACING), 'elk.padding': '[top=0,left=0,bottom=0,right=0]' },
  mrtree: { 'elk.algorithm': 'mrtree', 'elk.direction': 'DOWN', 'elk.spacing.nodeNode': String(SPACING), 'elk.padding': '[top=0,left=0,bottom=0,right=0]' },
  layered: {
    'elk.algorithm': 'layered', 'elk.direction': 'DOWN', 'elk.edgeRouting': 'POLYLINE', 'elk.spacing.nodeNode': String(SPACING),
    'elk.layered.spacing.nodeNodeBetweenLayers': '96', 'elk.layered.nodePlacement.strategy': 'LINEAR_SEGMENTS', 'elk.layered.crossingMinimization.greedySwitch.type': 'OFF', 'elk.padding': '[top=0,left=0,bottom=0,right=0]',
  },
  stress: { 'elk.algorithm': 'stress', 'elk.stress.desiredEdgeLength': '460', 'elk.padding': '[top=0,left=0,bottom=0,right=0]' },
};

/**
 * Lays out boxes with one of the algorithms. items: [{w, h}], edges: [{a, b, w}] (indexes). Returns positions
 * (top-lefts, rounded, the least corner at 0,0) and the size of the whole.
 */
export async function layoutFlat(elk, algo, items, edges, seed) {
  let pos;
  if (items.length === 1) pos = [{ x: 0, y: 0 }];
  else {
    const base = Object.assign({}, ALGORITHMS[algo]);
    const graph = {
      id: 'root', layoutOptions: seed ? Object.assign(base, { 'elk.randomSeed': String(seed) }) : base,
      children: items.map((it, i) => ({ id: 'n' + i, width: it.w, height: it.h })),
      edges: edges.map((e, i) => ({ id: 'e' + i, sources: ['n' + e.a], targets: ['n' + e.b] })),
    };
    const r = await elk.layout(graph);
    pos = items.map((_, i) => { const c = r.children[i]; return { x: c.x, y: c.y }; });
    if (algo === 'stress') { const raw = pos; pos = removeOverlaps(items, pos); return Object.assign(normalize(items, pos), { raw }); }
  }
  return normalize(items, pos);
}

export function normalize(items, pos) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  pos.forEach((p, i) => { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x + items[i].w); y1 = Math.max(y1, p.y + items[i].h); });
  const out = pos.map((p) => ({ x: Math.round(p.x - x0), y: Math.round(p.y - y0) }));
  return { pos: out, w: Math.round(x1 - x0), h: Math.round(y1 - y0) };
}

/** Pushes boxes apart (stress ignores sizes) until 64 clear, then snaps to a 16 grid. Deterministic. */
export function removeOverlaps(items, start, gx = 40, gy = 64) {
  const pos = start.map((p) => ({ x: p.x, y: p.y }));
  for (let pass = 0; pass < 400; pass++) {
    let moved = false;
    for (let i = 0; i < items.length; i++) {
      for (let j = i + 1; j < items.length; j++) {
        const a = pos[i], b = pos[j], A = items[i], B = items[j];
        const ox = Math.min(a.x + A.w + gx - b.x, b.x + B.w + gx - a.x), oy = Math.min(a.y + A.h + gy - b.y, b.y + B.h + gy - a.y);
        if (ox <= 0 || oy <= 0) continue;
        moved = true;
        if (ox / 1 < oy * 1.5) { const d = ox / 2 + 0.5; if (a.x + A.w / 2 <= b.x + B.w / 2) { a.x -= d; b.x += d; } else { a.x += d; b.x -= d; } }
        else { const d = oy / 2 + 0.5; if (a.y + A.h / 2 <= b.y + B.h / 2) { a.y -= d; b.y += d; } else { a.y += d; b.y -= d; } }
      }
    }
    if (!moved) break;
  }
  return compact(items, pos, gx, gy).map((p) => ({ x: Math.round(p.x / 16) * 16, y: Math.round(p.y / 16) * 16 }));
}

/**
 * Slides every box toward the top-left as far as it goes (keeping gx / gy clear of the others), a few passes, left then up. A
 * stress layout comes out airy, because it ignores the boxes' sizes; this keeps its order and takes the air out.
 */
export function compact(items, start, gx, gy) {
  const pos = start.map((p) => ({ x: p.x, y: p.y }));
  const n = items.length;
  const order = (key) => [...Array(n).keys()].sort((i, j) => pos[i][key] - pos[j][key] || i - j);
  for (let pass = 0; pass < 4; pass++) {
    let moved = false;
    for (const i of order('x')) {   // left
      let x = -Infinity;
      for (let j = 0; j < n; j++) {
        if (j === i || pos[j].x >= pos[i].x) continue;
        if (pos[i].y < pos[j].y + items[j].h + gy && pos[j].y < pos[i].y + items[i].h + gy) x = Math.max(x, pos[j].x + items[j].w + gx);
      }
      const nx = x === -Infinity ? Math.min(pos[i].x, 0) : x;
      if (nx < pos[i].x - 1e-9) { pos[i].x = nx; moved = true; }
    }
    for (const i of order('y')) {   // up
      let y = -Infinity;
      for (let j = 0; j < n; j++) {
        if (j === i || pos[j].y >= pos[i].y) continue;
        if (pos[i].x < pos[j].x + items[j].w + gx && pos[j].x < pos[i].x + items[i].w + gx) y = Math.max(y, pos[j].y + items[j].h + gy);
      }
      const ny = y === -Infinity ? Math.min(pos[i].y, 0) : y;
      if (ny < pos[i].y - 1e-9) { pos[i].y = ny; moved = true; }
    }
    if (!moved) break;
  }
  return pos;
}

/**
 * Packs a container: every box slides toward where it belongs, the farthest from the middle first, until it touches (gx / gy clear
 * of) another box. A box with arrows among the others goes toward the middle of those it is joined to (blended with the middle of
 * all); one with none goes toward the middle of all, so a hub whose arrows became pills does not sit alone a board away from its
 * frame mates. Nothing moves apart, boxes never overlap (given they started clear), and the result is the same on every run.
 * items: [{w, h}], start: [{x, y}] top-lefts, edges: [{a, b, n}] (indexes). Returns {pos, w, h} (the least corner at 0, 0).
 */
export function pack(items, start, edges, gx, gy, squeeze = true) {
  const n = items.length;
  if (n < 2) return normalize(items, start);
  const pos = start.map((p) => ({ x: p.x, y: p.y }));
  const nb = Array.from({ length: n }, () => new Map());
  for (const e of edges || []) { if (e.a === e.b) continue; nb[e.a].set(e.b, (nb[e.a].get(e.b) || 0) + (e.n || 1)); nb[e.b].set(e.a, (nb[e.b].get(e.a) || 0) + (e.n || 1)); }
  const cx = (i) => pos[i].x + items[i].w / 2, cy = (i) => pos[i].y + items[i].h / 2;
  const blocked = (i, x, y) => {
    for (let j = 0; j < n; j++) {
      if (j === i) continue;
      if (x < pos[j].x + items[j].w + gx && pos[j].x < x + items[i].w + gx && y < pos[j].y + items[j].h + gy && pos[j].y < y + items[i].h + gy) return true;
    }
    return false;
  };
  const STEP = 8;
  for (let round = 0; round < 3; round++) {
  for (let pass = 0; pass < 60; pass++) {
    let mx = 0, my = 0;
    for (let i = 0; i < n; i++) { mx += cx(i); my += cy(i); }
    mx /= n; my /= n;
    const order = [...Array(n).keys()].sort((p, q) => Math.hypot(cx(q) - mx, cy(q) - my) - Math.hypot(cx(p) - mx, cy(p) - my) || p - q);
    let moved = false;
    for (const i of order) {
      let tx = mx, ty = my;
      if (nb[i].size) {
        let sw = 0, sx = 0, sy = 0;
        for (const [j, w] of nb[i]) { sw += w; sx += w * cx(j); sy += w * cy(j); }
        tx = 0.5 * mx + 0.5 * sx / sw; ty = 0.5 * my + 0.5 * sy / sw;
      }
      for (let k = 0; k < 400; k++) {
        const dx = tx - cx(i), dy = ty - cy(i), d = Math.hypot(dx, dy);
        if (d < STEP) break;
        const sx = dx / d * STEP, sy = dy / d * STEP;
        const x = pos[i].x + sx, y = pos[i].y + sy;
        if (!blocked(i, x, y)) { pos[i].x = x; pos[i].y = y; moved = true; continue; }
        // blocked on the diagonal: slide along the free axis
        if (Math.abs(dx) >= Math.abs(dy)) {
          if (!blocked(i, pos[i].x + Math.sign(dx) * STEP, pos[i].y) && Math.abs(dx) > STEP) { pos[i].x += Math.sign(dx) * STEP; moved = true; continue; }
          if (!blocked(i, pos[i].x, pos[i].y + Math.sign(dy) * STEP) && Math.abs(dy) > STEP) { pos[i].y += Math.sign(dy) * STEP; moved = true; continue; }
        } else {
          if (!blocked(i, pos[i].x, pos[i].y + Math.sign(dy) * STEP) && Math.abs(dy) > STEP) { pos[i].y += Math.sign(dy) * STEP; moved = true; continue; }
          if (!blocked(i, pos[i].x + Math.sign(dx) * STEP, pos[i].y) && Math.abs(dx) > STEP) { pos[i].x += Math.sign(dx) * STEP; moved = true; continue; }
        }
        break;
      }
    }
    if (!moved) break;
  }
  if (!squeeze) break;
  const sq = compact(items, pos, gx, gy);   // the air the slides left, taken out along the axes; then slide again
  let any = false; sq.forEach((p, i) => { if (Math.abs(p.x - pos[i].x) + Math.abs(p.y - pos[i].y) > 1e-9) any = true; pos[i] = p; });
  if (!any) break;
  }
  return normalize(items, pos);
}
