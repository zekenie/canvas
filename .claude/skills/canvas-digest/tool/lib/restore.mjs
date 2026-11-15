// Links put back as arrows by the drawing, at the end of the cut (cut.mjs), before the pills are shared (share.mjs): the board is clean, and
// a link the cut made a pill is often one whose line would draw clean after all (the cut decided before the notes were placed). Here each such
// link, on the finished drawing and with no note moved, becomes an arrow again where that arrow crosses no line and runs over no note, title
// room, frame or pill (the pills of its own ends too), bowed as the app bows a second arrow between two shapes; its pill goes, and the note's
// other pills are packed smaller where they fit clean (`repack`); where only pills of other notes are in its way, those notes take another
// arrangement of their pills (strips.mjs) if one is clear. The most wanted links first, as the cut ranks them, and again shortest
// first, whichever puts back more; sweeps repeat while a sweep puts one back. Measured as the app draws it (health.mjs); an arrow in a
// conflict is given up, and the result is kept only where the board ends clean. Deterministic: the four operations and square roots, lists in
// key and index order.
import { readLayout, boardHealth, HEALTH } from './health.mjs';
import { arrowPath, segCross, segHitsBox, len } from './geom.mjs';
import { stripAlts } from './strips.mjs';
import { Scene, Grid, LEAF, HOLDS, PILL, MARGIN, GAP, within } from './scene.mjs';
import { repack } from './share.mjs';
import { holdsShapes } from './model.mjs';
import { byTitle } from './util.mjs';

const SEP = '\u0000';
const SWEEPS = 2, MENDS = 6;
const MOST_OWNERS = 3;   // the notes whose pills may be moved for one arrow

/**
 * The board's links put back as arrows: `layout` the board's clean layout, `layouter` its Layouter. Returns {layout, health, restored, restoredCut} (the
 * layout with the arrows, measured, how many it put back, and how many of those were cut between groups: `layout.cut`) when the board ends clean with at least one, else null (the layout stands).
 */
export function restoreByDrawing(model, layouter, layout, moves = true) {
  const sizes = layouter.sizes, view = layouter.view;
  const B0 = readLayout(model, layout, sizes);
  if (boardHealth(B0, view, 0, true).status !== 'clean') return null;
  const wanted = candidates(model, layouter, layout);
  if (!wanted.length) return null;
  // the two orders, each on a scene of its own; the one that puts back more stands (the first on a tie)
  const deg = new Map();
  for (const e of layouter.sameBoard) for (const t of [e.from, e.to]) deg.set(t, (deg.get(t) || 0) + 1);
  const worth = (c) => [-c.e.weight, -Math.max(deg.get(c.e.from), deg.get(c.e.to)), -Math.min(deg.get(c.e.from), deg.get(c.e.to))];
  const byWorth = (p, q) => { const a = worth(p), b = worth(q); return a[0] - b[0] || a[1] - b[1] || a[2] - b[2] || byTitle(p.u + SEP + p.e.to, q.u + SEP + q.e.to); };
  const byLength = (p, q) => p.d - q.d || byWorth(p, q);
  let best = null;
  for (const order of [byWorth, byLength]) {
    const got = sweeps(model, layouter, layout, B0, wanted.slice().sort(order), moves);
    if (got.picks.length && (!best || got.picks.length > best.picks.length)) best = got;
  }
  if (!best) return null;
  let picks = best.picks;
  for (let round = 0; round < MENDS && picks.length; round++) {
    // with the note's other pills packed smaller, else where they were
    const plain = build(layout, picks, best.moved);
    const users = [...new Set(picks.map((c) => c.u))].sort(byTitle);
    const packed = repack(model, layouter, { layout: plain, recs: [{ users }] }).layout;
    for (const lay of [packed, plain]) {
      const health = boardHealth(readLayout(model, lay, sizes), view, 0, true);
      if (health.status === 'clean') return { layout: lay, health, restored: picks.length, restoredCut: picks.filter((c) => c.e.precut).length };
    }
    // an arrow in a conflict is given up
    const B = readLayout(model, plain, sizes), bad = new Set();
    for (const c of boardHealth(B, view, 0, true).conflicts) for (const i of c) if (B.lines[i].key) bad.add(B.lines[i].key);
    const rest = picks.filter((c) => !bad.has(c.u + SEP + c.e.to));
    if (rest.length === picks.length) return moves ? restoreByDrawing(model, layouter, layout, false) : null;
    picks = rest;
  }
  return moves ? restoreByDrawing(model, layouter, layout, false) : null;
}

/** The links this board's pills stand for that an arrow may replace: {u, e, pill, d}, `d` the distance between the ends' middles. */
function candidates(model, layouter, layout) {
  const own = new Map();
  layout.pills.forEach((p, i) => { if (!p.free) own.set(p.start + SEP + p.target, i); });
  const through = new Set();
  for (const l of layouter.sizes.lines || []) { through.add(l.first.join(SEP)); through.add(l.second.join(SEP)); }
  const out = [];
  for (const u of [...layout.plan.byStart.keys()].sort(byTitle)) {
    if (layouter.spineLeaf.has(u) || !layout.boxes.has(u)) continue;
    for (const en of layout.plan.byStart.get(u)) {
      const e = en.e, node = model.node(e.to), pill = own.get(u + SEP + e.to);
      if (e.cross || e.direct || node.never || holdsShapes(node) || pill == null || !layout.boxes.has(e.to) || through.has(u + SEP + e.to)) continue;
      const a = layout.boxes.get(u), b = layout.boxes.get(e.to);
      out.push({ u, e, pill, d: len(a.x + a.w / 2 - b.x - b.w / 2, a.y + a.h / 2 - b.y - b.h / 2) });
    }
  }
  return out;
}

/**
 * Sweeps over the candidates in an order, each arrow kept where it is clear on the drawing as the earlier ones left it (`moves`: where only
 * pills of other notes are in the way, those notes' pills may take another arrangement): {picks, moved}, the links put back and the pills
 * that moved (layout pill index -> box).
 */
function sweeps(model, layouter, layout, B0, order, moves) {
  const S = new Scene(model, layout, B0), sizes = layouter.sizes;
  const tabs = new Grid();
  for (const s of B0.shapes) if (s.frame && s.tab) tabs.addBox({ id: s.id, box: s.tab, on: () => true });
  const held = new Map();   // a pair of ends -> how many lines join it
  for (const l of B0.lines) if (!l.intoPill) { const k = [l.a, l.b].sort(byTitle).join(SEP); held.set(k, (held.get(k) || 0) + 1); }
  // the board's extent, which no pill moved goes past
  const ext = { x: Infinity, y: Infinity, x1: -Infinity, y1: -Infinity };
  const take = (x0, y0, x1, y1) => { ext.x = Math.min(ext.x, x0); ext.y = Math.min(ext.y, y0); ext.x1 = Math.max(ext.x1, x1); ext.y1 = Math.max(ext.y1, y1); };
  for (const sh of B0.shapes) { const b = sh.box, t = sh.tab ? sh.tab.h : 0; take(b.x, b.y - t, b.x + b.w, b.y + b.h); }
  for (const p of B0.pills) take(p.box.x, p.box.y, p.box.x + p.box.w, p.box.y + p.box.h);
  for (const l of B0.lines) for (const q of l.path) take(q[0], q[1], q[0], q[1]);
  // each note's own pills still there (layout pill index, key in the scene, edge) in the order of its strip, and whose a pill in the scene is
  const live = new Map(), owner = new Map(), moved = new Map();
  const ownAt = new Map();
  layout.pills.forEach((p, i) => { if (!p.free) { ownAt.set(p.start + SEP + p.target, i); owner.set(S.at[i], p.start); } });
  for (const [u, list] of layout.plan.byStart) live.set(u, list.map((en) => ({ i: ownAt.get(u + SEP + en.e.to), key: S.at[ownAt.get(u + SEP + en.e.to)], e: en.e })));
  const flag = (segs, u, t) => {   // a line that can be taken off again
    const on = { v: true }, line = { a: u, b: t, on: () => on.v };
    for (const p of segs) for (const seg of p) S.lines.addSeg({ seg, line, on: line.on });
    return on;
  };
  /** Another arrangement of `w`'s pills (but `except`, the one being replaced) that is clear of everything, else null: what to undo it by. */
  const rearrange = (w, except) => {
    const ents = live.get(w).filter((x) => x.i !== except);
    if (!ents.length) return null;
    const box = layout.boxes.get(w), z = sizes.shapes[w], above = (z && z.above) || 0;
    const ps = ents.map((x) => moved.get(x.i) || layout.pills[x.i]);
    const alts = stripAlts({ w: z.w, h: z.h, above }, ents.map((x) => ({ w: layout.pills[x.i].w })), layouter.k)
      .map((a, i) => [a, i]).filter(([a]) => a && !/^column/.test(a.side) && !a.own)
      .sort((p, q) => p[0].w * p[0].h - q[0].w * q[0].h || p[1] - q[1]);
    const holders = new Set(model.node(w).frames), cid = model.node(w).container, fb = cid[0] === 'f' ? layout.frames.get(cid.slice(2)) : null;
    for (const x of ents) S.setPill(x.key, false);
    for (const [a] of alts) {
      const ox = box.x - a.nx, oy = box.y - a.ny;
      const nb = a.pills.map((p) => ({ x: ox + p.x, y: oy + p.y, w: p.w, h: p.h }));
      if (nb.every((b, i) => b.x >= ext.x && b.y >= ext.y && b.x + b.w <= ext.x1 && b.y + b.h <= ext.y1 && S.boxClear(b, holders, w) && (!fb || within(b, fb, GAP)) && S.reaches(w, b, null, holders, ents[i].e))) {
        const undo = { w, was: live.get(w), moved: ents.map((x) => [x.i, moved.get(x.i)]), keys: [] };
        const now = ents.map((x, i) => {
          const k = S.addPill(nb[i]);
          S.addLine(w, k, S.linePaths(w, nb[i], x.e));
          owner.set(k, w); undo.keys.push(k);
          moved.set(x.i, Object.assign({}, ps[i], { x: nb[i].x, y: nb[i].y, left: nb[i].x + nb[i].w <= box.x }));
          return { i: x.i, key: k, e: x.e };
        });
        live.set(w, live.get(w).map((x) => now.find((y) => y.i === x.i) || x));
        undo.was = ents;
        return undo;
      }
    }
    for (const x of ents) S.setPill(x.key, true);
    return null;
  };
  const rollback = (undos) => {
    for (const un of undos.reverse()) {
      for (const k of un.keys) S.setPill(k, false);
      const now = live.get(un.w);
      un.was.forEach((x) => S.setPill(x.key, true));
      live.set(un.w, now.map((x) => un.was.find((y) => y.i === x.i) || x));
      for (const [i, m] of un.moved) { if (m) moved.set(i, m); else moved.delete(i); }
    }
  };
  const kept = [];
  let todo = order;
  for (let sweep = 0; sweep < SWEEPS && todo.length; sweep++) {
    const left = [];
    for (const c of todo) {
      const paths = arrowPaths(layout, c, held), on = flag(paths, c.u, c.e.to);
      S.setPill(S.at[c.pill], false);
      let r = probe(model, S, tabs, c, paths), undos = [];
      if (moves && !r.other && r.pills.size) {
        // only pills in the way: the notes they belong to take another arrangement, if each has one that is clear
        const ws = [...new Set([...r.pills].map((k) => owner.get(k)))];
        if (ws.length <= MOST_OWNERS && ws.every((w) => w != null)) {
          ws.sort(byTitle);
          for (const w of ws) { const un = rearrange(w, c.pill); if (!un) break; undos.push(un); }
          if (undos.length === ws.length) r = probe(model, S, tabs, c, paths);
          else r = { other: true, pills: new Set() };
        }
      }
      if (!r.other && !r.pills.size) {
        kept.push(c);
        const t = c.e.to, k = [c.u, t].sort(byTitle).join(SEP);
        held.set(k, (held.get(k) || 0) + paths.length);
        live.set(c.u, live.get(c.u).filter((x) => x.i !== c.pill));
      } else { rollback(undos); on.v = false; S.setPill(S.at[c.pill], true); left.push(c); }
    }
    if (left.length === todo.length) break;
    todo = left;
  }
  return { picks: kept, moved };
}

/** The segments of each of a link's lines as the app draws them: as many as its edge draws, each bowed the next slot the pair of ends holds. */
function arrowPaths(layout, c, held) {
  const A = layout.boxes.get(c.u), Bx = layout.boxes.get(c.e.to), forward = c.u <= c.e.to;
  let k = held.get([c.u, c.e.to].sort(byTitle).join(SEP)) || 0;
  const out = [];
  for (let i = 0; i < Math.max(1, c.e.items.length); i++, k++) {
    const steps = k % 2 ? (k + 1) / 2 : -(k / 2), path = arrowPath(A, Bx, (forward ? steps : -steps) * HEALTH.pairBend, HEALTH.samples), segs = [];
    for (let j = 1; j < path.length; j++) segs.push({ x1: path[j - 1][0], y1: path[j - 1][1], x2: path[j][0], y2: path[j][1] });
    out.push(segs);
  }
  return out;
}

/**
 * What is in the way of a link's lines: `other` where one crosses a line but those at either end, or runs over a note, title room or frame
 * (but the frames that hold its ends), `pills` the pills (by their key in the scene) it runs over.
 */
function probe(model, S, tabs, c, paths) {
  const u = c.u, t = c.e.to, mine = new Set(model.node(u).frames.concat(model.node(t).frames)), out = { other: false, pills: new Set() };
  for (const segs of paths) for (const seg of segs) {
    const box = { x: Math.min(seg.x1, seg.x2), y: Math.min(seg.y1, seg.y2), w: Math.abs(seg.x2 - seg.x1), h: Math.abs(seg.y2 - seg.y1) };
    for (const it of S.solids.inBox(box, MARGIN)) {
      if (it.kind === LEAF && (it.id === u || it.id === t)) continue;
      if (it.kind === HOLDS && mine.has(it.id)) continue;
      if (!segHitsBox(seg, it.box, -MARGIN)) continue;
      if (it.kind === PILL) out.pills.add(+it.id.slice(1)); else out.other = true;
    }
    for (const it of tabs.inBox(box, MARGIN)) if (!mine.has(it.id) && segHitsBox(seg, it.box, -MARGIN)) out.other = true;
    for (const it of S.lines.along(seg)) {
      const l = it.line;
      if (l.a === u || l.b === u || l.a === t || l.b === t) continue;
      if (segCross(seg, it.seg)) out.other = true;
    }
  }
  return out;
}

/** The layout with `picks` drawn as arrows: their own pills gone (every pill after them moved up), the arrows after the plan's others. */
function build(layout, picks, moved) {
  const plan = layout.plan, gone = new Set(picks.map((c) => c.pill)), at = new Map(), pills = [];
  layout.pills.forEach((p, i) => { if (!gone.has(i)) { at.set(i, pills.length); pills.push(moved && moved.has(i) ? moved.get(i) : p); } });
  const drop = new Set(picks.map((c) => c.u + SEP + c.e.to));
  const byStart = new Map();
  for (const [t, list] of plan.byStart) byStart.set(t, list.filter((en) => !drop.has(t + SEP + en.e.to)));
  const free = plan.free.map((f) => Object.assign({}, f, { at: at.get(f.at) }));
  const members = plan.members.map((x) => Object.assign({}, x, { pill: at.get(x.pill) }));
  return Object.assign({}, layout, { pills, plan: Object.assign({}, plan, { byStart, free, members, direct: plan.direct.concat(picks.map((c) => c.e)) }) });
}
