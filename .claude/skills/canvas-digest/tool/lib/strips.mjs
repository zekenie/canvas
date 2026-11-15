// Templates searched per note.
//
// A template is a few strips around the note: a row below and a row above (each of one or more staggered layers) and a short column on the
// right and on the left. The pills are dealt to the strips in the order of `sides` (the first side gets the first pills); inside a strip the
// widest pills sit nearest the middle, where a line leaves its neighbours the most room.
//  - A row layer's pills are packed from the middle out. Layers are placed outermost first; each layer inside it is placed in the free
//    stretches between the corridors the outer layers' lines pass through, so an outer pill sits under a gap of the layer inside it and
//    that gap is as wide as its line needs ("staggered rows").
//  - Each strip sits at the least distance from the note at which nothing it adds has a line over a pill, tried from near to far.
//  - A strip is measured alone first (its spec: the distance, its extent), then built beside the strips already placed, moved out a step
//    at a time while it does not clear them.
// The search per note: every split of the pills over the four sides (a profile of layer counts for a row, a count for a column) gets a
// cost from its strips' measured extents (area, charged a little for pills off the first side, and for each extra strip or layer); splits
// are built cheapest first, and the best built wins. For notes with many pills the counts of a side are tried on a coarse grid, and the
// winner is then refined by moving one to three pills between sides while that builds cheaper.
// Everything is measured with the scorer's geometry (geom.mjs's arrowBetween and segHitsBox). Only + - * / and Math.min/max/abs/round/
// floor/ceil are used, and ties are broken by index, so it is deterministic and the same under every engine.
import { arrowBetween, segHitsBox } from './geom.mjs';

const EPS = 0.5;
const FIT_MARGIN = 8;   // the scorer's 8, and room for the whole units a layout rounds pills to
const SORT_BY_WIDTH = true;
const DSTEPS = [];   // distances tried from the note: every 4 near, wider apart farther
for (let d = 16; d <= 416; d += d < 100 ? 4 : d < 200 ? 8 : 24) DSTEPS.push(d);
DSTEPS.push(520, 680, 900, 1200, 1600, 2200);
const DSTEPS_COARSE = [16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 200, 250, 320, 416, 520, 680, 900, 1200, 1600, 2200];   // for layered rows, which cost more to try
const LAMBDA = 0.4;         // charge for the share of pills off the first side
const MAX_ROW = 8, MAX_COL = 8, MAX_LAYERS = 5;
const COARSE_FROM = 4;
const BUILD_CAP = 120, EXTRA = 60;      // splits built per note, at most

// ---- row profiles: layer counts, as even as they can be, the first layers or the last the larger --------------------------------------
const PROFS = [];   // PROFS[sum] = [profile]
function genProfs() {
  for (let m = 1; m <= 8 * MAX_LAYERS; m++) {
    const list = [];
    const l0 = Math.ceil(m / MAX_ROW);
    for (let L = l0; L <= Math.min(MAX_LAYERS, m, l0 + 1); L++) {
      const base = Math.floor(m / L), r = m % L;
      const first = [], last = [];
      for (let j = 0; j < L; j++) { first.push(base + (j < r ? 1 : 0)); last.push(base + (j >= L - r ? 1 : 0)); }
      list.push(first);
      if (r > 0) list.push(last);
    }
    PROFS[m] = list;
  }
}
genProfs();

const sep = (a, b) => Math.max(a.x - (b.x + b.w), b.x - (a.x + a.w), a.y - (b.y + b.h), b.y - (a.y + a.h));

// ---- placing one layer of a row in the stretches the corridors leave ---------------------------------------------------------------
/**
 * x (left edges) of pills of widths `ws`, nearest the middle first, in the stretches the corridors leave. `forb` are corridors [a, b] their
 * lines pass through; `sp` the least gap between pills; `gapC` a half-width kept clear in the middle. Each pill takes the free place
 * nearest the middle (a pill's forbidden stretches are the corridors widened by its width, the pills placed widened by it and `sp`, merged).
 */
function placeLayer(ws, forb, sp, gapC) {
  const xs = [], dx = [], dw = [];   // the pills placed: left edges and widths
  const nf = forb.length;
  const fa = [], fb = [];
  if (nf > 0) { const cs = forb.slice().sort((p, q) => p[0] - q[0]); for (const c of cs) { fa.push(c[0]); fb.push(c[1]); } }
  for (let i = 0; i < ws.length; i++) {
    const w = ws[i], want = -w / 2;
    // the nearest free place right of the wanted one, and left of it: step over every stretch that holds the candidate until none does
    let hiP = want, loP = want, moved = true;
    while (moved) {
      moved = false;
      for (let f = 0; f < nf; f++) { const lo = fa[f] - w - 8.5, hi = fb[f] + 8.5; if (hiP > lo && hiP < hi) { hiP = hi; moved = true; } }
      if (gapC > 0 && hiP > -w - gapC && hiP < gapC) { hiP = gapC; moved = true; }
      for (let j = 0; j < dx.length; j++) { const lo = dx[j] - w - sp, hi = dx[j] + dw[j] + sp; if (hiP > lo && hiP < hi) { hiP = hi; moved = true; } }
    }
    moved = true;
    while (moved) {
      moved = false;
      for (let f = nf - 1; f >= 0; f--) { const lo = fa[f] - w - 8.5, hi = fb[f] + 8.5; if (loP > lo && loP < hi) { loP = lo; moved = true; } }
      if (gapC > 0 && loP > -w - gapC && loP < gapC) { loP = -w - gapC; moved = true; }
      for (let j = 0; j < dx.length; j++) { const lo = dx[j] - w - sp, hi = dx[j] + dw[j] + sp; if (loP > lo && loP < hi) { loP = lo; moved = true; } }
    }
    const px = (want - loP < hiP - want) ? loP : hiP;
    xs.push(px); dx.push(px); dw.push(w);
  }
  return xs;
}

/** The indices start..start+count-1 of `ws`, widest first (ties by index): the wide pills go nearest the middle, where a line leaves the least room to its neighbours. */
function widthOrder(ws, start, count) {
  const ids = [];
  for (let i = 0; i < count; i++) ids.push(start + i);
  if (SORT_BY_WIDTH) ids.sort((a, b) => (ws[b] - ws[a]) || (a - b));
  return ids;
}

/** What a row side's layers are, worked out once: for each layer, its pills' indices widest first and their widths. */
function rowPlan(prof, ws) {
  const layers = [];
  let a = 0;
  for (const m of prof) {
    const ids = widthOrder(ws, a, m);
    layers.push({ ids, lw: ids.map((i) => ws[i]), outerXs: new Map() });
    a += m;
  }
  return { n: ws.length, layers };
}

/** A row side's pills as rectangles: its layers, the first `d0` from the note's room, layers `dg` apart; `sp` and `off` shape the outermost layer. */
function rowRects(c, side, plan, d0, dg, sp, off) {
  const edge = side === 'below' ? c.hh : c.hh + c.above;
  const layers = plan.layers, L = layers.length;
  const out = new Array(plan.n);
  const outer = [];
  for (let j = L - 1; j >= 0; j--) {
    const T = edge + d0 + j * (40 + dg);
    const { ids, lw } = layers[j];
    const gapC = (j === L - 1 && L > 1 && off) ? Math.max(8, sp / 2) : 0;
    let xs;
    if (j === L - 1) {   // the outermost layer has no corridors: where it sits doesn't depend on the distance
      const key = sp + '|' + gapC;
      xs = layers[j].outerXs.get(key);
      if (!xs) { xs = placeLayer(lw, [], sp, gapC); layers[j].outerXs.set(key, xs); }
    } else {
      const forb = [];
      for (const o of outer) { const lo = o.cx * (T - 8) / o.C, hi = o.cx * (T + 48) / o.C; forb.push(lo < hi ? [lo, hi] : [hi, lo]); }
      xs = placeLayer(lw, forb, 16, 0);
    }
    for (let i = 0; i < lw.length; i++) {
      out[ids[i]] = { x: xs[i], y: side === 'below' ? T : -T - 40, w: lw[i], h: 40 };
      outer.push({ cx: xs[i] + lw[i] / 2, C: T + 20 });
    }
  }
  return out;
}

/** A column side's pills as rectangles: left edges (right side) or right edges (left side) on one line `d` from the note, the nearest the middle first. */
function colRects(c, side, ws, d, sv) {
  const n = ws.length, slots = [];
  for (let m = 0; m < n; m++) slots.push((m - (n - 1) / 2) * (40 + sv));
  const idx = slots.map((_, m) => m);
  idx.sort((p, q) => (Math.abs(slots[p]) - Math.abs(slots[q])) || (slots[q] - slots[p]));
  const out = new Array(n), ids = widthOrder(ws, 0, n);
  for (let r = 0; r < n; r++) {
    const i = ids[r];
    const y = slots[idx[r]] - 20, w = ws[i];
    out[i] = { x: side === 'right' ? c.hw + d : -c.hw - d - w, y, w, h: 40 };
  }
  return out;
}

// ---- checks ------------------------------------------------------------------------------------------------------------------------
/** Whether `news` can join `placed` (rectangles with .seg): spaced, clear of the note's room, no line of one over another pill. Sets .seg on `news`. */
function fits(c, placed, news) {
  for (let i = 0; i < news.length; i++) {
    const p = news[i];
    if (sep(p, c.R) < 16) return false;
    for (const q of placed) if (sep(p, q) < 16) return false;
    for (let j = 0; j < i; j++) if (sep(p, news[j]) < 16) return false;
  }
  for (const p of news) p.seg = arrowBetween(c.N, p);
  for (let i = 0; i < news.length; i++) {
    const p = news[i];
    for (const q of placed) { if (segHitsBox(p.seg, q, -FIT_MARGIN) || segHitsBox(q.seg, p, -FIT_MARGIN)) return false; }
    for (let j = 0; j < news.length; j++) if (j !== i && segHitsBox(p.seg, news[j], -FIT_MARGIN)) return false;
  }
  return true;
}

/** The longest unbroken row (same top) or column (same left or right edge) among rects, as the scorer counts: each next within 2 steps of the last. */
function longestRun(rs) {
  let most = 0;
  const runs = (key, along, size) => {
    const groups = new Map();
    for (const p of rs) { const k = Math.round(key(p) * 2) / 2; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(p); }
    for (const g of groups.values()) {
      g.sort((a, b) => along(a) - along(b));
      let run = 1;
      for (let i = 1; i < g.length; i++) { run = along(g[i]) - (along(g[i - 1]) + size(g[i - 1])) <= 2 * 16 + 0.5 ? run + 1 : 1; most = Math.max(most, run); }
    }
  };
  runs((p) => p.y, (p) => p.x, (p) => p.w);
  runs((p) => p.x, (p) => p.y, (p) => p.h);
  runs((p) => p.x + p.w, (p) => p.y, (p) => p.h);
  return most;
}

const clone = (rs) => rs.map((r) => ({ x: r.x, y: r.y, w: r.w, h: r.h }));

// ---- strips: the standalone best spec, memoised -------------------------------------------------------------------------------------
function rowSpec(c, side, prof, ws) {
  const key = 'r' + side + prof.join(',') + '/' + ws.join(',') + '/' + c.hh + '/' + c.above + '/' + c.hw;
  if (c.memo.has(key)) return c.memo.get(key);
  const L = prof.length, plan = rowPlan(prof, ws);
  const combos = [];
  if (L === 1) combos.push([16, 16, 0]);
  else for (const sp of [16, 64]) for (const off of [0, 1]) combos.push([sp, 16, off]);
  let best = null;
  for (const [sp, dg, off] of combos) {
    for (const d0 of (L === 1 ? DSTEPS : DSTEPS_COARSE)) {
      const rs = rowRects(c, side, plan, d0, dg, sp, off);
      if (!fits(c, [], clone(rs))) continue;
      let x0 = Infinity, x1 = -Infinity;
      for (const r of rs) { x0 = Math.min(x0, r.x); x1 = Math.max(x1, r.x + r.w); }
      const span = Math.max(x1, c.hw) - Math.min(x0, -c.hw);
      const cost = span * (d0 + L * 56);
      if (!best || cost < best.cost) best = { d0, dg, sp, off, cost, x0, x1, depth: d0 + (L - 1) * (40 + dg) + 40 };
      break;
    }
  }
  c.memo.set(key, best);
  return best;
}

function colSpec(c, side, ws) {
  const key = 'c' + side + ws.join(',') + '/' + c.hh + '/' + c.above + '/' + c.hw;
  if (c.memo.has(key)) return c.memo.get(key);
  let best = null, mw = 0;
  for (const w of ws) mw = Math.max(mw, w);
  for (const sv of [16, 32]) {
    for (const d of DSTEPS) {
      if (!fits(c, [], colRects(c, side, ws, d, sv))) continue;
      const height = 40 * ws.length + sv * (ws.length - 1), cost = (d + mw) * height;
      if (!best || cost < best.cost) best = { d, sv, cost, width: d + mw, height };
      break;
    }
  }
  c.memo.set(key, best);
  return best;
}

// ---- a split of the pills: build it, measure it ---------------------------------------------------------------------------------------
/** strips: [{ side, prof (a row's layer counts; a column's [n]), start, count }] in placement order. Returns { rects (by pill index), cost, area } or null. */
function build(c, strips, k, widths, sides) {
  const placed = [];
  const byIndex = new Array(k);
  for (const st of strips) {
    const ws = widths.slice(st.start, st.start + st.count);
    const horizontal = st.side === 'below' || st.side === 'above';
    let spec = horizontal ? rowSpec(c, st.side, st.prof, ws) : colSpec(c, st.side, ws);
    if (!spec) return null;
    let rs = null;
    const plan = horizontal ? rowPlan(st.prof, ws) : null;
    for (let step = 0; step < 60; step++) {
      const cand = horizontal ? rowRects(c, st.side, plan, spec.d0 + step * 8, spec.dg, spec.sp, spec.off) : colRects(c, st.side, ws, spec.d + step * 8, spec.sv);
      if (fits(c, placed, cand)) { rs = cand; break; }
    }
    if (!rs) return null;
    for (let i = 0; i < rs.length; i++) { byIndex[st.start + i] = rs[i]; placed.push(rs[i]); }
  }
  if (placed.length > 8 && longestRun(placed) > 8) return null;   // no unbroken run of more than 8
  // the unit
  let x0 = c.R.x, y0 = c.R.y, x1 = c.R.x + c.R.w, y1 = c.R.y + c.R.h;
  for (const r of placed) { x0 = Math.min(x0, r.x); y0 = Math.min(y0, r.y); x1 = Math.max(x1, r.x + r.w); y1 = Math.max(y1, r.y + r.h); }
  const area = (x1 - x0) * (y1 - y0);
  // pills on the first side (the scorer's sideOf)
  let first = 0;
  const N = c.N, top = N.y - c.above;
  for (const p of placed) {
    const right = p.x >= N.x + N.w, left = p.x + p.w <= N.x, below = p.y >= N.y + N.h, above = p.y + p.h <= top;
    let s = 'corner';
    if ((right || left) && !(below || above)) s = right ? 'right' : 'left';
    else if ((below || above) && !(right || left)) s = below ? 'below' : 'above';
    if (s === sides[0]) first++;
  }
  const cost = area * (1 + LAMBDA * (k - first) / k) * (1 + 0.01 * penalty(strips));
  return { byIndex, cost, area, x0, y0, x1, y1, strips };
}

const penalty = (strips) => { let p = strips.length - 1; for (const s of strips) p += s.prof.length - 1; return p; };

// ---- the search ------------------------------------------------------------------------------------------------------------------------
/** `use`: only the first `use` of `sides` hold pills (4, every side, unless told), so the rest are left clear for the note's arrows. */
export function packStrips(note, pills, sides, k, use = 4) {
  const n = pills.length;
  const hw = note.w / 2, hh = note.h / 2, above = note.above;
  const c = {
    hw, hh, above, memo: MEMO,
    N: { x: -hw, y: -hh, w: note.w, h: note.h },
    R: { x: -hw, y: -hh - above, w: note.w, h: note.h + above },
  };
  if (MEMO.size > 30000) MEMO.clear();
  const widths = pills.map((p) => p.w);
  if (n === 0) return { w: note.w, h: note.h + above, note: { x: 0, y: above }, pills: [] };
  // placement order: rows (in the order of `sides`) before columns
  const isRow = (s) => s === 'below' || s === 'above';
  const order = [...sides.filter(isRow), ...sides.filter((s) => !isRow(s))];
  const rank = {}; sides.forEach((s, i) => { rank[s] = i; });

  // pill ranges are taken in the order of `sides`
  const maxLen = (s) => (sides.indexOf(s) >= use ? 0 : isRow(s) ? MAX_LAYERS * MAX_ROW : MAX_COL);
  const suffixCap = [0, 0, 0, 0, 0];
  for (let i = 3; i >= 0; i--) suffixCap[i] = suffixCap[i + 1] + maxLen(sides[i]);
  if (n > suffixCap[0]) throw new Error('no template fits');

  // a part's measured strip (memoised), null where no distance makes it clean
  const specOf = (p) => {
    const ws = widths.slice(p.start, p.start + p.count);
    return isRow(p.side) ? rowSpec(c, p.side, p.prof, ws) : colSpec(c, p.side, ws);
  };
  // a part's size from its pills alone (no distances yet), to drop splits before measuring them
  const lbOf = (p) => {
    if (isRow(p.side)) {
      let a = p.start, rowW = 0;
      for (const m of p.prof) { let t = 16 * (m - 1); for (let q = 0; q < m; q++) t += widths[a + q]; a += m; rowW = Math.max(rowW, t); }
      return { x0: -rowW / 2, x1: rowW / 2, depth: 56 * p.prof.length - 16 };
    }
    let mw = 0; for (let q = 0; q < p.count; q++) mw = Math.max(mw, widths[p.start + q]);
    return { width: 16 + mw, height: 40 * p.count + 16 * (p.count - 1) };
  };
  // what the unit costs at least, from the strips measured alone: the note and its room, each strip beside it at its own distance
  const bound = (parts) => {
    let X0 = -hw, X1 = hw, Y0 = -hh - above, Y1 = hh, cnt = 0, extra = 0, firstN = 0;
    for (const p of parts) {
      if (p.count === 0) continue;
      cnt++;
      if (p.side === sides[0]) firstN = p.count;
      const sp = p.spec;
      if (isRow(p.side)) {
        extra += p.prof.length - 1;
        X0 = Math.min(X0, sp.x0); X1 = Math.max(X1, sp.x1);
        if (p.side === 'below') Y1 = Math.max(Y1, hh + sp.depth); else Y0 = Math.min(Y0, -hh - above - sp.depth);
      } else {
        if (p.side === 'right') X1 = Math.max(X1, hw + sp.width); else X0 = Math.min(X0, -hw - sp.width);
        Y0 = Math.min(Y0, -sp.height / 2); Y1 = Math.max(Y1, sp.height / 2);
      }
    }
    return (X1 - X0) * (Y1 - Y0) * (1 + LAMBDA * (n - firstN) / n) * (1 + 0.01 * (cnt - 1 + extra));
  };

  // enumerate splits that may cost less than `theta`
  const found = [];
  const enumerate = (theta) => {
    found.length = 0;
    const parts = [];
    const rec = (i, start) => {
      const remaining = n - start;
      if (i === 4) { if (remaining === 0) found.push({ parts: parts.slice(), est: bound(parts) }); return; }
      if (remaining > suffixCap[i]) return;
      const s = sides[i];
      const profiles = [];
      const upTo = Math.min(remaining, maxLen(s));
      if (i === 3) { // the last side takes whatever is left
        if (remaining === 0) profiles.push({ prof: [], count: 0 });
        else if (isRow(s)) { for (const p of PROFS[remaining] || []) profiles.push({ prof: p, count: remaining }); }
        else if (remaining <= MAX_COL) profiles.push({ prof: [remaining], count: remaining });
      } else {
        profiles.push({ prof: [], count: 0 });
        for (let m = 1; m <= upTo; m++) {
          if (n > COARSE_FROM && m > 4 && (m % 4) && use > 2 && m !== remaining) continue;   // big notes: the counts of a side in a coarser grid (but a side that may take what is left, and every count where one or two sides hold them all)
          if (isRow(s)) { for (const p of PROFS[m] || []) profiles.push({ prof: p, count: m }); } else profiles.push({ prof: [m], count: m });
        }
      }
      for (const pf of profiles) {
        const part = { side: s, prof: pf.prof, start, count: pf.count, spec: null };
        parts.push(part);
        if (pf.count > 0) {
          part.spec = lbOf(part);
          if (!(bound(parts) < theta)) { parts.pop(); continue; }
          part.spec = specOf(part);
          if (!part.spec) { parts.pop(); continue; }
        }
        if (bound(parts) < theta) rec(i + 1, start + pf.count);
        parts.pop();
      }
    };
    rec(0, 0);
    found.sort((a, b) => (a.est - b.est) || cmpParts(a.parts, b.parts));
  };

  let best = null, builds = 0, firstAt = -1;
  const tryAll = (theta) => {
    enumerate(theta);
    for (const f of found) {
      if (best && f.est >= best.cost) break;
      if (builds >= BUILD_CAP || (best && builds >= firstAt + EXTRA)) break;
      builds++;
      // placement order: rows first
      const strips = [];
      for (const s of order) { const p = f.parts.find((q) => q.side === s); if (p && p.count > 0) strips.push(p); }
      const r = build(c, strips, n, widths, sides);
      if (r && firstAt < 0) firstAt = builds;
      if (r && (!best || r.cost < best.cost)) best = r;
    }
  };
  // the column beside the note is the yardstick: look at splits cheaper than it first, then wider
  let colMax = 0; for (const w of widths) colMax = Math.max(colMax, w);
  const yard = (note.w + 80 + colMax) * Math.max(note.h + above, 56 * n);
  for (const f of [1.5, 2.2, 3.5, Infinity]) {
    tryAll(yard * f);
    if (best && best.cost <= yard * f) break;
  }
  if (!best) throw new Error('no template fits');
  // refine: move one pill (or two) from one side to another while that builds cheaper (the grid of counts above is coarse for big notes)
  if (n > COARSE_FROM) {
    for (let round = 0; round < 16; round++) {
      const cur = sides.map((sd) => { const p = best.strips.find((q) => q.side === sd); return p ? p.prof : []; });
      const nbrs = [];
      for (let a = 0; a < 4; a++) for (let b = 0; b < 4; b++) {
        if (a === b) continue;
        for (const mv of [1, 2, 3]) {
          const ca = cur[a].reduce((x, y) => x + y, 0) - mv, cb = cur[b].reduce((x, y) => x + y, 0) + mv;
          if (ca < 0 || cb > maxLen(sides[b])) continue;
          const va = ca === 0 ? [[]] : isRow(sides[a]) ? (PROFS[ca] || []) : [[ca]];
          const vb = isRow(sides[b]) ? (PROFS[cb] || []) : (cb <= MAX_COL ? [[cb]] : []);
          for (const pa of va) for (const pb of vb) { const pr = cur.slice(); pr[a] = pa; pr[b] = pb; nbrs.push(pr); }
        }
      }
      const cands = [];
      for (const pr of nbrs) {
        const parts = []; let start = 0, ok = true;
        for (let i = 0; i < 4 && ok; i++) {
          const cnt = pr[i].reduce((x, y) => x + y, 0);
          const part = { side: sides[i], prof: pr[i], start, count: cnt, spec: null };
          if (cnt > 0) { part.spec = lbOf(part); if (!(bound(parts.concat([part])) < best.cost)) { ok = false; break; } part.spec = specOf(part); if (!part.spec) { ok = false; break; } }
          parts.push(part); start += cnt;
        }
        if (!ok) continue;
        const est = bound(parts);
        if (est < best.cost) cands.push({ parts, est });
      }
      cands.sort((x, y) => (x.est - y.est) || cmpParts(x.parts, y.parts));
      let improved = false;
      for (let q = 0; q < Math.min(cands.length, 30); q++) {
        if (cands[q].est >= best.cost) break;
        const strips = [];
        for (const sd of order) { const p = cands[q].parts.find((z) => z.side === sd); if (p && p.count > 0) strips.push(p); }
        const r = build(c, strips, n, widths, sides);
        if (r && r.cost < best.cost) { best = r; improved = true; }
      }
      if (!improved) break;
    }
  }
  const rs = best.byIndex;
  return {
    w: best.x1 - best.x0, h: best.y1 - best.y0,
    note: { x: -hw - best.x0, y: -hh - best.y0 },
    pills: rs.map((r) => ({ x: r.x - best.x0, y: r.y - best.y0 })),
  };
}

const MEMO = new Map();
function cmpParts(a, b) {
  for (let i = 0; i < a.length; i++) { if (a[i].count !== b[i].count) return b[i].count - a[i].count; const x = a[i].prof.join(), y = b[i].prof.join(); if (x !== y) return x < y ? -1 : 1; }
  return 0;
}


// ---- what the layout takes: a leaf's arrangements, one for each side its pills may favour ------------------------------------------------

/**
 * The arrangements a leaf may take, always in this order (so a layout's choice, an index, names the same one whatever its pills): the sides
 * each fills, in order, and how many of them it may use. One side alone, each way (the rest of the note clear for its arrows); two
 * opposite sides; all four, the most compact. The first, the right alone, is what a layout takes with nothing else to say, as a column did.
 */
const ARRANGEMENTS = [
  { side: 'right', sides: ['right', 'left', 'below', 'above'], use: 1 },
  { side: 'left', sides: ['left', 'right', 'above', 'below'], use: 1 },
  { side: 'below', sides: ['below', 'above', 'right', 'left'], use: 1 },
  { side: 'above', sides: ['above', 'below', 'left', 'right'], use: 1 },
  { side: 'below+above', sides: ['below', 'above', 'right', 'left'], use: 2 },
  { side: 'right+left', sides: ['right', 'left', 'below', 'above'], use: 2 },
  { side: 'around', sides: ['below', 'above', 'right', 'left'], use: 4 },
  { side: 'column right' },
  { side: 'column left' },
  // two sides that meet at a corner, and three (a U open on one side): what leaves a quarter or a half of the note's directions free in less room
  { side: 'below+right', sides: ['below', 'right', 'above', 'left'], use: 2 },
  { side: 'below+left', sides: ['below', 'left', 'above', 'right'], use: 2 },
  { side: 'above+right', sides: ['above', 'right', 'below', 'left'], use: 2 },
  { side: 'above+left', sides: ['above', 'left', 'below', 'right'], use: 2 },
  { side: 'open above', sides: ['below', 'right', 'left', 'above'], use: 3 },
  { side: 'open below', sides: ['above', 'right', 'left', 'below'], use: 3 },
  { side: 'open right', sides: ['below', 'above', 'left', 'right'], use: 3 },
  { side: 'open left', sides: ['below', 'above', 'right', 'left'], use: 3 },
];
const ALTS = new Map();   // a leaf's arrangements, by its note's size, its title's room, its pills' widths and the constants

/**
 * The arrangements of a note's pills, by ARRANGEMENTS (null where it can't hold them all with no line over another pill): [{w, h, nx, ny,
 * nw, nh, pills: [{x, y, w, h}], strips: [{x, y, w, h}], side}], each in its own box's coordinates (`nx`, `ny` the note's top-left in it,
 * the room its title takes above it inside the box too). `note` {w, h, above}, `pills` [{w}] in the order they want to be nearest, `k` the
 * layout's constants (pillHeight, pillStep). `strips` are the boxes the pills take on each side of the note (another shape's arrow must
 * stay off them). Where none fits, one column on the right, centred on the note (its lines may cross its own pills). A note with no pills
 * has one arrangement: itself.
 */
export function stripAlts(note, pills, k) {
  const w = Math.ceil(note.w), h = Math.ceil(note.h), above = Math.ceil(note.above || 0);
  if (!pills.length) return [{ w, h, nx: 0, ny: 0, nw: w, nh: h, pills: [], strips: [], side: null }];
  const key = w + 'x' + h + '^' + above + ':' + pills.map((p) => p.w).join(',') + ':' + k.pillHeight + ',' + k.pillStep;
  if (ALTS.has(key)) return ALTS.get(key);
  if (ALTS.size > 20000) ALTS.clear();
  const K = { pillHeight: k.pillHeight, step: k.pillStep, gap: k.pillStep, margin: 8, most: 8 };
  const as = (r, side) => {
    // not rounded: a strip's lines clear its pills by the margin and little more, and a unit's rounding would close that
    const nx = r.note.x, ny = r.note.y;
    const ps = r.pills.map((p, i) => ({ x: p.x, y: p.y, w: pills[i].w, h: k.pillHeight }));
    const sb = sideBoxes(ps, { x: nx, y: ny, w, h });
    return { w: Math.ceil(r.w), h: Math.ceil(r.h), nx, ny, nw: w, nh: h, pills: ps, strips: sb.map((b) => b.box), on: sb.map((b) => b.side), side };
  };
  // the strips, each with no line over another of its pills; and a column on either side, whose lines may cross its own
  // pills (`own`: how many lines run over another of its pills, which a layout weighs against what its other arrangements cost)
  const alts = ARRANGEMENTS.map((a) => {
    if (!a.sides) { const c = as(column({ w, h, above }, pills, a.side === 'column left', k), a.side); c.own = ownHits(c); return c; }
    try {
      const c = as(packStrips({ w, h, above }, pills.map((p) => ({ w: p.w, h: k.pillHeight })), a.sides, K, a.use), a.side);
      c.own = ownHits(c);   // rounded to whole units, a line may come within the margin of a pill it cleared before
      return c;
    } catch (e) { return null; }
  });

  ALTS.set(key, alts);
  return alts;
}

/** How many of an arrangement's lines (each from its note's middle to a pill's, clipped at both) pass within 8 of another of its pills. */
function ownHits(a) {
  const N = { x: a.nx, y: a.ny, w: a.nw, h: a.nh };
  let hits = 0;
  for (const p of a.pills) {
    const s = arrowBetween(N, p);
    for (const q of a.pills) if (q !== p && segHitsBox(s, q, -8)) hits++;
  }
  return hits;
}

/** One column of the pills beside the note, centred on it where no strips fit, a column whose lines may cross its own pills. */
function column(note, pills, left, k) {
  const colW = 80 + Math.max(...pills.map((p) => p.w)), colH = pills.length * k.pillHeight + (pills.length - 1) * k.pillStep;
  const top = Math.min(-note.above, note.h / 2 - colH / 2), bottom = Math.max(note.h, note.h / 2 + colH / 2);
  const nx = left ? colW : 0, ny = -top;
  let y = ny + note.h / 2 - colH / 2;
  const out = pills.map((p) => { const r = { x: left ? colW - 80 - p.w : nx + note.w + 80, y }; y += k.pillHeight + k.pillStep; return r; });
  return { w: note.w + colW, h: bottom - top, note: { x: nx, y: ny }, pills: out };
}

/** The sides of the note that hold pills, each with the box its pills take (a pill is on the side its middle is furthest past the note's edge). */
export function sideBoxes(pills, n) {
  const boxes = new Map();
  for (const p of pills) {
    const cx = p.x + p.w / 2, cy = p.y + p.h / 2;
    const out = [['right', cx - (n.x + n.w)], ['left', n.x - cx], ['below', cy - (n.y + n.h)], ['above', n.y - cy]];
    let side = out[0];
    for (const o of out) if (o[1] > side[1]) side = o;
    const b = boxes.get(side[0]);
    if (!b) boxes.set(side[0], { x: p.x, y: p.y, x1: p.x + p.w, y1: p.y + p.h });
    else { b.x = Math.min(b.x, p.x); b.y = Math.min(b.y, p.y); b.x1 = Math.max(b.x1, p.x + p.w); b.y1 = Math.max(b.y1, p.y + p.h); }
  }
  return ['right', 'left', 'below', 'above'].filter((s) => boxes.has(s)).map((s) => { const b = boxes.get(s); return { side: s, box: { x: b.x, y: b.y, w: b.x1 - b.x, h: b.y1 - b.y } }; });
}
