// Shared pills chosen by the drawing, at the end of the cut (cut.mjs): the board is clean with every pill its note's own (but a spine's);
// here the notes of one container that use one target share a pill wherever the drawing has a spot each of them reaches by a straight
// line that crosses no arrow and no other line, and runs over no note, title room, frame or pill (the note's own pills too). No note moves
// and no link is cut: a user's own pill for that target goes, the rest of its pills stay where they were (`repack` then tries smaller
// strips of them where those fit clean). Greedy: the targets with the most users first, each target's users covered by the spot that the
// most of them reach (then the shortest lines), until fewer than two are left; up to `PASSES` times, each on the drawing the last left.
// Measured as the app draws it (health.mjs); a line in a conflict gives its note its own pill back, and the result is kept only where
// the board ends clean. Deterministic: the four operations and square roots, lists in key and index order.
import { readLayout, boardHealth, HEALTH } from './health.mjs';
import { segHitsBox, len } from './geom.mjs';
import { stripAlts } from './strips.mjs';
import { Scene, LEAF, HOLDS, MARGIN, GAP, within, near } from './scene.mjs';
import { byTitle } from './util.mjs';

const SEP = '\u0000';
const GROUP = '\u0002g';   // in a shared pill's group key, before its first user (the host)
const MAXLEN = 1200, ROUNDS = 6, MENDS = 10, SPOTS = 400;
const PASSES = 3;
const RINGS = [0, 120, 260, 450, 700];
const TWELVE = [[1, 0], [0.866, 0.5], [0.5, 0.866], [0, 1], [-0.5, 0.866], [-0.866, 0.5], [-1, 0], [-0.866, -0.5], [-0.5, -0.866], [0, -1], [0.5, -0.866], [0.866, -0.5]];


/**
 * The board's shared pills: `layout` the board's clean layout, `layouter` its Layouter. Returns {layout, health, shared} (the layout with the
 * shared pills, measured, and how many it shares) when the board ends clean with at least one, else null (the layout stands).
 */
export function shareByDrawing(model, layouter, layout) {
  const first = boardHealth(readLayout(model, layout, layouter.sizes), layouter.view, 0, true);
  if (first.status !== 'clean') return null;
  // passes: each on the drawing the last left, its strips packed smaller, so more users reach a spot (or a pill shared already)
  let out = null;
  for (let p = 0; p < PASSES; p++) {
    const r = pass(model, layouter, out ? out.layout : layout);
    if (!r) break;
    out = { layout: r.layout, health: r.health, shared: r.layout.pills.filter((x) => x.free && x.group.includes(GROUP)).length };
  }
  return out;
}

/** One pass of sharing on a clean layout: the layout with more shared, measured clean, or null. */
function pass(model, layouter, layout) {
  const sizes = layouter.sizes, view = layouter.view;
  // the own pills, by user and target, and the groups: one target's own pills from one container's users (not a spine's); the pills shared
  // already (by this pass's earlier runs) that they may join
  const ownIndex = new Map();
  layout.pills.forEach((x, i) => { if (!x.free) ownIndex.set(x.start + SEP + x.target, i); });
  const joinable = new Map();
  layout.pills.forEach((x, i) => {
    if (!x.free || !x.group.includes(GROUP)) return;
    const k = x.target + SEP + model.node(x.start).container;
    if (!joinable.has(k)) joinable.set(k, []);
    joinable.get(k).push(i);
  });
  const byGroup = new Map();
  for (const t of [...layout.plan.byStart.keys()].sort(byTitle)) {
    if (layouter.spineLeaf.has(t) || !layout.boxes.has(t)) continue;
    const cid = model.node(t).container;
    for (const en of layout.plan.byStart.get(t)) {
      const at = ownIndex.get(t + SEP + en.e.to);
      if (at == null) continue;
      const k = en.e.to + SEP + cid;
      if (!byGroup.has(k)) byGroup.set(k, { target: en.e.to, container: cid, users: [], edges: new Map(), w: layout.pills[at].w, join: joinable.get(k) || [] });
      const g = byGroup.get(k);
      g.users.push(t); g.edges.set(t, en.e);
    }
  }
  const groups = [...byGroup.values()].filter((g) => g.users.length >= 2 || (g.users.length && g.join.length))
    .sort((a, b) => b.users.length - a.users.length || byTitle(a.target, b.target) || byTitle(a.container, b.container));
  if (!groups.length) return null;
  const records = place(model, layouter, layout, groups, ownIndex);
  if (!records.length) return null;
  // measured as the app draws it; a line in a conflict, or over another pill its user uses, gives its user its own pill back
  let recs = records, packs = true;
  for (let round = 0; round < MENDS && recs.length; round++) {
    let built = build(model, layouter, layout, recs, ownIndex);
    if (packs) built = repack(model, layouter, built);
    const B = readLayout(model, built.layout, sizes);
    const health = boardHealth(B, view, 0, true);
    const bad = trouble(B, health, built);
    if (!bad.size && health.status === 'clean') return { layout: built.layout, health };
    if (!bad.size && packs) { packs = false; continue; }   // what the strips packed again broke: without them
    if (!bad.size) break;
    recs = recs.map((r) => Object.assign({}, r, { users: r.users.filter((u) => !bad.has(r.id + SEP + u)) }))
      .filter((r) => r.users.length >= (r.join != null ? 1 : 2) && !bad.has(r.id + SEP));
  }
  return null;
}

/**
 * The spots: each group's users covered by the clear spots that the most of them reach, on the drawing as it is so far. Returns the shared
 * pills, each {id, target, container, users (by title), box}.
 */
function place(model, layouter, layout, groups, ownIndex) {
  const S = new Scene(model, layout, readLayout(model, layout, layouter.sizes));
  const noteBox = S.noteBox;
  // each container's room: what its own leaves cover with their titles and pills; a frame's, inside the frame
  const bounds = new Map();
  const grow = (cid, b) => { const r = bounds.get(cid); if (!r) bounds.set(cid, { x0: b.x, y0: b.y, x1: b.x + b.w, y1: b.y + b.h }); else { r.x0 = Math.min(r.x0, b.x); r.y0 = Math.min(r.y0, b.y); r.x1 = Math.max(r.x1, b.x + b.w); r.y1 = Math.max(r.y1, b.y + b.h); } };
  for (const [t, b] of layout.boxes) { const cid = model.node(t).container; grow(cid, b); const z = layouter.sizes.shapes[t]; if (z && z.above > 0) grow(cid, { x: b.x, y: b.y - z.above, w: b.w, h: z.above }); }
  for (const p of layout.pills) grow(model.node(p.start).container, p);
  const frameBox = (cid) => (cid[0] === 'f' ? layout.frames.get(cid.slice(2)) : null);
  const records = [];
  let next = 0;
  const pillH = layouter.k.pillHeight;
  const mid = (b) => [b.x + b.w / 2, b.y + b.h / 2];
  for (const g of groups) {
    let users = g.users.slice().sort(byTitle);
    const holders = new Set(model.node(users[0]).frames), fb = frameBox(g.container), bd = bounds.get(g.container);
    const mine = new Map(users.map((u) => [u, S.at[ownIndex.get(u + SEP + g.target)]]));
    const w = g.w;
    // a pill shared already: the users that reach it join it
    for (const j of g.join) {
      if (!users.length) break;
      const key = S.at[j], box = S.pills[key].box, pid = S.pills[key].id;
      let vis;
      const vacate = (on) => { for (const u of users) S.setPill(mine.get(u), on); };
      vacate(false);
      vis = users.filter((u) => len(mid(noteBox.get(u))[0] - mid(box)[0], mid(noteBox.get(u))[1] - mid(box)[1]) <= MAXLEN + len(noteBox.get(u).w, noteBox.get(u).h) / 2 && S.reaches(u, box, pid, holders, g.edges.get(u)));
      for (let changed = true; changed && vis.length;) {
        changed = false;
        for (const u of users) S.setPill(mine.get(u), !vis.includes(u));
        const keep = vis.filter((u) => S.reaches(u, box, pid, holders, g.edges.get(u)));
        if (keep.length !== vis.length) { vis = keep; changed = true; }
      }
      vacate(true);
      if (!vis.length) continue;
      const us = vis.slice().sort(byTitle);
      for (const u of us) { S.setPill(mine.get(u), false); S.addLine(u, key, S.linePaths(u, box, g.edges.get(u))); }
      records.push({ id: 'g' + next++, join: j, target: g.target, container: g.container, users: us, box });
      users = users.filter((u) => !us.includes(u));
    }
    for (let round = 0; round < ROUNDS && users.length >= 2; round++) {
      const pid = '\u0002' + S.pills.length;   // the key the pill will have
      const NB = users.map((u) => noteBox.get(u));
      const cx = NB.reduce((s, b) => s + mid(b)[0], 0) / NB.length, cy = NB.reduce((s, b) => s + mid(b)[1], 0) / NB.length;
      const order = users.map((u, i) => i).sort((p, q) => len(mid(NB[p])[0] - cx, mid(NB[p])[1] - cy) - len(mid(NB[q])[0] - cx, mid(NB[q])[1] - cy) || p - q);
      // the spots to try: the users' own pills' (the same size), round each note, between pairs, and round the middle
      const cand = [];
      for (const u of users) { const p = S.pills[mine.get(u)].box; cand.push([p.x + p.w / 2, p.y + p.h / 2]); }
      for (const i of order.slice(0, 12)) {
        const b = NB[i], [mx, my] = mid(b);
        for (const k of RINGS) for (const [dx, dy] of TWELVE) {
          // just past the note's edge that way, then further out
          const rx = (b.w / 2 + w / 2 + 40 + k), ry = (b.h / 2 + pillH / 2 + 40 + k);
          cand.push([mx + rx * dx, my + ry * dy]);
        }
      }
      for (let a = 0; a < Math.min(order.length, 8); a++) for (let c = a + 1; c < Math.min(order.length, 8); c++) {
        const [ax, ay] = mid(NB[order[a]]), [bx, by] = mid(NB[order[c]]), d = len(bx - ax, by - ay) || 1, px = -(by - ay) / d, py = (bx - ax) / d;
        for (const t of [0.5, 0.3, 0.7]) for (const o of [0, 120, -120, 260, -260]) cand.push([ax + (bx - ax) * t + px * o, ay + (by - ay) * t + py * o]);
      }
      for (const k of [0, 150, 300, 600, 1000]) for (const [dx, dy] of k ? TWELVE : [[0, 0]]) cand.push([cx + k * dx, cy + k * dy]);
      let best = null, tried = 0;
      // the users' own pills for this target are what sharing takes away: off while a spot is tried, but those of users that don't reach it
      const vacate = (on) => { for (const u of users) S.setPill(mine.get(u), on); };
      for (const [px, py] of cand) {
        const box = { x: px - w / 2, y: py - pillH / 2, w, h: pillH };
        if (box.x < bd.x0 || box.y < bd.y0 || box.x + box.w > bd.x1 || box.y + box.h > bd.y1) continue;
        if (fb && !within(box, fb, GAP)) continue;
        vacate(false);
        if (!S.boxClear(box, holders)) { vacate(true); continue; }
        if (++tried > SPOTS) { vacate(true); break; }
        let vis = users.filter((u, i) => len(mid(NB[i])[0] - px, mid(NB[i])[1] - py) <= MAXLEN + len(NB[i].w, NB[i].h) / 2 && S.reaches(u, box, pid, holders, g.edges.get(u)));
        // a user that doesn't share keeps its own pill: the spot and the others' lines must be clear of it and its line
        for (let changed = true; changed && vis.length >= 2;) {
          changed = false;
          for (const u of users) S.setPill(mine.get(u), !vis.includes(u));
          if (!S.boxClear(box, holders)) { vis = []; break; }
          const keep = vis.filter((u) => S.reaches(u, box, pid, holders, g.edges.get(u)));
          if (keep.length !== vis.length) { vis = keep; changed = true; }
        }
        vacate(true);
        if (vis.length < 2) continue;
        let total = 0;
        for (const u of vis) total += len(mid(noteBox.get(u))[0] - px, mid(noteBox.get(u))[1] - py);
        if (!best || vis.length > best.vis.length || (vis.length === best.vis.length && total < best.total - 1e-9)) best = { box, vis, total };
      }
      if (!best) break;
      const us = best.vis.slice().sort(byTitle);
      for (const u of us) S.setPill(mine.get(u), false);
      const k = S.addPill(best.box);
      for (const u of us) S.addLine(u, k, S.linePaths(u, best.box, g.edges.get(u)));
      records.push({ id: 'g' + next++, target: g.target, container: g.container, users: us, box: best.box });
      users = users.filter((u) => !us.includes(u));
    }
  }
  return records;
}

/**
 * The layout with the shared pills `recs`: each user's own pill for the target gone (the rest of its pills where they were), each shared
 * pill made by its first user's edge (the host) and the others' edges into it. Returns {layout, shared: pill index -> record, users}.
 */
function build(model, layouter, layout, recs, ownIndex) {
  const gone = new Set(), plan = layout.plan;
  for (const r of recs) for (const u of r.users) gone.add(ownIndex.get(u + SEP + r.target));
  const at = new Map(), pills = [];
  layout.pills.forEach((p, i) => { if (!gone.has(i)) { at.set(i, pills.length); pills.push(p); } });
  const byStart = new Map();
  for (const [t, list] of plan.byStart) byStart.set(t, list.filter((en) => !gone.has(ownIndex.get(t + SEP + en.e.to))));
  const free = plan.free.map((f) => Object.assign({}, f, { at: at.get(f.at) }));
  const members = plan.members.map((x) => Object.assign({}, x, { pill: at.get(x.pill) }));
  const shared = new Map(), edgeOf = (u, t) => plan.byStart.get(u).find((en) => en.e.to === t).e;
  for (const r of recs) {
    if (r.join != null) {
      // users joining a pill shared already: their edges into it, its count of users grown
      const i = at.get(r.join), old = pills[i], f = free.find((x) => x.at === i);
      pills[i] = Object.assign({}, old, { users: old.users + r.users.length });
      f.users = pills[i].users;
      for (const u of r.users) members.push({ e: edgeOf(u, r.target), host: f.e.from, key: f.key, free: true, pill: i });
      shared.set(i, r);
      continue;
    }
    const host = r.users[0], key = r.target + SEP + r.container + GROUP + host, i = pills.length;
    pills.push({ start: host, target: r.target, users: r.users.length, shared: true, free: true, group: key, x: r.box.x, y: r.box.y, w: r.box.w, h: r.box.h });
    shared.set(i, r);
    free.push({ e: edgeOf(host, r.target), key, pill: '\u0003' + key, users: r.users.length, at: i });
    for (const u of r.users.slice(1)) members.push({ e: edgeOf(u, r.target), host, key, free: true, pill: i });
  }
  const out = Object.assign({}, layout, { pills, plan: Object.assign({}, plan, { byStart, free, members }) });
  return { layout: out, shared, recs };
}

/**
 * (restore.mjs packs a note's pills this way too.) Each user that shares: its own pills left (fewer now) in the smallest strips that hold them (strips.mjs) where they fit clean, smaller than
 * what they took, the note where it is; else where they were.
 */
export function repack(model, layouter, built) {
  const layout = built.layout, B = readLayout(model, layout, layouter.sizes), S = new Scene(model, layout, B);
  // the board's extent, which no pill packed again goes past: what it holds, titles' room and lines too
  const ext = { x: Infinity, y: Infinity, x1: -Infinity, y1: -Infinity };
  const take = (x0, y0, x1, y1) => { ext.x = Math.min(ext.x, x0); ext.y = Math.min(ext.y, y0); ext.x1 = Math.max(ext.x1, x1); ext.y1 = Math.max(ext.y1, y1); };
  for (const sh of B.shapes) { const b = sh.box, t = sh.tab ? sh.tab.h : 0; take(b.x, b.y - t, b.x + b.w, b.y + b.h); }
  for (const p of B.pills) take(p.box.x, p.box.y, p.box.x + p.box.w, p.box.y + p.box.h);
  for (const l of B.lines) for (const q of l.path) take(q[0], q[1], q[0], q[1]);
  const inside = (b) => b.x >= ext.x && b.y >= ext.y && b.x + b.w <= ext.x1 && b.y + b.h <= ext.y1;
  const users = [...new Set(built.recs.flatMap((r) => r.users))].sort(byTitle);
  const ownAt = new Map();
  layout.pills.forEach((p, i) => { if (!p.free) ownAt.set(p.start + SEP + p.target, i); });
  let moved = 0;
  for (const u of users) {
    const list = layout.plan.byStart.get(u) || [], idx = list.map((en) => ownAt.get(u + SEP + en.e.to));
    if (!list.length || idx.some((i) => i == null)) continue;
    const box = layout.boxes.get(u), z = layouter.sizes.shapes[u], above = (z && z.above) || 0;
    const ps = idx.map((i) => layout.pills[i]);
    let x0 = box.x, y0 = box.y - above, x1 = box.x + box.w, y1 = box.y + box.h;
    for (const p of ps) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x + p.w); y1 = Math.max(y1, p.y + p.h); }
    const now = (x1 - x0) * (y1 - y0);
    const alts = stripAlts({ w: z.w, h: z.h, above }, ps.map((p) => ({ w: p.w })), layouter.k)
      .map((a, i) => [a, i]).filter(([a]) => a && !/^column/.test(a.side) && !a.own && a.w * a.h < now - 1)
      .sort((p, q) => p[0].w * p[0].h - q[0].w * q[0].h || p[1] - q[1]);
    if (!alts.length) continue;
    const holders = new Set(model.node(u).frames), cid = model.node(u).container, fb = cid[0] === 'f' ? layout.frames.get(cid.slice(2)) : null;
    const keys = idx.map((i) => S.at[i]);
    for (const k of keys) S.setPill(k, false);
    let took = null;
    for (const [a] of alts) {
      const ox = box.x - a.nx, oy = box.y - a.ny;
      const nb = a.pills.map((p) => ({ x: ox + p.x, y: oy + p.y, w: p.w, h: p.h }));
      if (nb.every((b, i) => inside(b) && S.boxClear(b, holders, u) && (!fb || within(b, fb, GAP)) && S.reaches(u, b, null, holders, list[i].e))) { took = nb; break; }
    }
    if (!took) { for (const k of keys) S.setPill(k, true); continue; }
    took.forEach((b, i) => {
      const k = S.addPill(b);
      S.addLine(u, k, S.linePaths(u, b, list[i].e));
      layout.pills[idx[i]] = Object.assign({}, ps[i], { x: b.x, y: b.y, left: b.x + b.w <= box.x });
    });
    moved++;
  }
  return Object.assign({}, built, { moved });
}

/**
 * What to give back after a measure, by shared pill and user (`id SEP user`), or a whole pill (`id SEP`): a line into a shared pill in a
 * conflict, or over another pill its user uses; a pill a line runs over, or on another shape.
 */
function trouble(B, health, built) {
  const bad = new Set();
  const recOf = (pillId) => (pillId && pillId[0] === '\u0001' ? built.shared.get(+pillId.slice(1)) : null);
  const conflicts = health.conflicts || [];
  conflicts.forEach((c, j) => {
    let any = false;
    for (const i of c) { const l = B.lines[i], r = recOf(l.b); if (r) { bad.add(r.id + SEP + l.a); any = true; } }
    if (!any && conflicts.over && conflicts.over.has(j)) {
      const g = conflicts.over.get(j);
      for (const [, r] of built.shared) if (g.endsWith(GROUP + r.users[0]) && g.startsWith(r.target + SEP)) bad.add(r.id + SEP);
    }
  });
  // lines over pills their users use (the owner's rule), where a shared pill is the line's end or what it runs over
  const uses = new Map();
  for (const p of B.pills) for (const u of p.users) { if (!uses.has(u)) uses.set(u, []); uses.get(u).push(p); }
  for (const l of B.lines) {
    if (!l.intoPill) continue;
    const into = recOf(l.b);
    for (const p of uses.get(l.a) || []) {
      if (p.id === l.b) continue;
      const over = recOf(p.id);
      if (!into && !over) continue;
      let hit = false;
      for (let j = 1; j < l.path.length && !hit; j++) hit = segHitsBox({ x1: l.path[j - 1][0], y1: l.path[j - 1][1], x2: l.path[j][0], y2: l.path[j][1] }, p.box, -MARGIN);
      if (hit) bad.add((into || over).id + SEP + l.a);
    }
  }
  // a shared pill on another shape
  if (health.onTop) {
    const all = B.shapes.map((s) => (s.tab ? [s.box, s.tab] : [s.box])).flat().concat(B.pills.map((p) => p.box));
    for (const [i, r] of built.shared) {
      const box = B.pills[i].box;
      const holders = new Set(B.pills[i].frames);
      for (const b of all) if (b !== box && near(box, b, -HEALTH.overlap) && !B.shapes.some((s) => s.box === b && s.frame && holders.has(s.id))) bad.add(r.id + SEP);
    }
  }
  return bad;
}
