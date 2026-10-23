// A board's layout: each container laid out by the algorithm its shape asks for (a container with arrows among its children is laid
// out layered, down and across, and stress, as it comes and stretched, and the cheapest kept), frames sized inside out, every shape with
// the column of pills it will have beside it reserved on its right. A spine (`findSpines`: cards that don't point at each other and point
// at many of the same shapes) is laid out as one, with no search: two columns of cards facing a column of the pills they share, which are
// boxes of its own (`spine`), and each card's own pills on its outer side, a left card's on its left.
// Every layout aims at a shape: a board at the shape of the view it will be seen in (`view`, the window's, width over height), so that the
// board fills the view when it is fit to it, and a frame at the same, so that a look into it fills the view too. What a container's
// layout costs counts how far off that shape it is (cost.mjs's shapeCost), which is what chooses between arrows running down and across.
import { byTitle } from './util.mjs';
import { layoutFlat, removeOverlaps, pushApart, normalize, pack, stretched, offShapeOf, DEFAULT_VIEW } from './elk.mjs';
import { warmStress } from './stress.mjs';
import { arrowBetween, segLength } from './geom.mjs';
import { ownCost, ownCostParts, shapeCost, FILL_WEIGHT } from './cost.mjs';
import { DEFAULT_CONSTANTS, TITLE_PILL } from './sizes.mjs';
import { fansOut } from './moves.mjs';

// draw's numbers (a pill's height, step and gap, how far `in` puts a shape from a frame's edge, a frame's least size) come from `canvas measure`: sizes.constants
/** What a container's empty room costs against its arrows, when it chooses between packed layouts: more where the dial is looser (the big picture over the tidy arrow). */
export const packFillWeight = (mess) => 24 * mess;
export const PACK_GAP = 64;   // the gap kept between the frames (and loose notes) of a board: ELK's spacing, between draw's tight (40) and normal (80); inside a frame, notes keep 40 x 64
const SEP = '\u0000';
const FREE = '\u0003';        // a shared pill's id among its container's children: this, then its group's key
/** How much wider (or taller) than the shape its container aims at a ranked child's slot may be: a band with little in it would be a strip. */
export const SLOT_MOST = 3;
/** How many rows a spine has at most (two shapes a row): past three it is a strip whatever the view's shape, and a pill all its shapes use
 *  sits beside a middle row that the arrows from the far rows cross other shapes to reach (eight cards: twelve arrows over cards). */
export const SPINE_ROWS = 3;

/**
 * The host of a group: of the users that share a pill, the one whose column puts it nearest the others, so the group's arrows are
 * shortest. The pill is taken to be PILL_GAP right of the host's note and level with its middle. Ties go to the first title.
 */
export function bestHost(boxes, froms, pillW, k = DEFAULT_CONSTANTS) {
  const PILL_GAP = k.pillGap, PILL_H = k.pillHeight;
  let best = null, bestLen = Infinity;
  for (const c of froms.slice().sort(byTitle)) {
    const cb = boxes.get(c);
    const pill = { x: cb.x + cb.w + PILL_GAP, y: cb.y + cb.h / 2 - PILL_H / 2, w: pillW, h: PILL_H };
    let len = 0;
    for (const m of froms) if (m !== c) len += segLength(arrowBetween(boxes.get(m), pill));
    if (len < bestLen - 1e-9) { best = c; bestLen = len; }
  }
  return best;
}

export class Layouter {
  /**
   * model, board title, sizes (sizesFrom's), an ELK instance. Each container is laid out a container at a time, each way it can be, the cheapest kept.
   * The users of one target in one container share one pill, in a host's column. opts.pack is auto (the default), gravity, squeeze or off;
   * opts.view is the room the view has for a board fit to it ({w, h}; elk.mjs's DEFAULT_VIEW when it is left out); opts.ranks is which
   * way ranked children run (auto, the default: whichever the view shows larger; rows; columns); opts.spines false lays out no spine
   * (`--promote off`, and the dial at 1, turn no arrow on a board into a pill).
   */
  constructor(model, board, sizes, opts, elk) {
    this.m = model; this.board = board; this.sizes = sizes; this.opts = Object.assign({ pack: 'auto' }, opts); this.elk = elk;
    if (!this.opts.ranks) this.opts.ranks = 'auto';
    this.k = Object.assign({}, DEFAULT_CONSTANTS, sizes.constants || {});
    const view = this.opts.view;
    this.view = view && view.w > 0 && view.h > 0 ? { w: view.w, h: view.h } : DEFAULT_VIEW;   // the room the view has for a board fit to it
    this.aspect = this.view.w / this.view.h;
    this.cache = new Map();
    this.elkCache = new Map();
    this.way = new Map();       // container id -> rows or columns: which way its ranked children run, once chosen
    this.force = null;          // container id -> the layout it is to have (layered, across, stress, stretched), whatever each costs: how the loop tries a board every way (promote.mjs)
    this.costsSeen = new Map();
    this.squeeze = false;       // the search packs by gravity only (a squeeze changes with every trial); the final layout may squeeze the air out too
    this.hold = false;          // while the too-long arrows are set apart: every shape stays where the layout has it, and only what a grown box now overlaps is pushed off it
    this.warm = false;          // while the loop searches: a container is laid out again from where it is (its anchor), in a millisecond, not afresh by ELK
    this.anchors = new Map();   // container id -> {algo, dir, k, pos: Map(id -> {x, y}), at, sig, ranked}: where the accepted layout has the container's children (setAnchors)
    this.stats = { layouts: 0, elkCalls: 0, hits: 0, elkMs: 0, warm: 0 };
    this.rootCid = 'b:' + board;
    this.out = model.edges.filter((e) => model.node(e.from).board === board);
    this.sameBoard = this.out.filter((e) => !e.cross);
    this.leaves = [...model.nodes.values()].filter((n) => n.board === board && n.kind !== 'frame');
    this.frameTitles = [...model.nodes.values()].filter((n) => n.board === board && n.kind === 'frame').map((n) => n.title);
    this.findSpines(this.opts.spines !== false);
  }

  /**
   * The spines of the board: a container of at most `SPINE_ROWS` rows of leaves (and no frames) that don't point at each other, and
   * point at two or more things in common, is laid out as a spine: its leaves in two columns facing a column of the pills they share,
   * each leaf's own pills on its outer side, so no arrow crosses a leaf. Its rows are the leaves that share the most, paired (the first by
   * title with the one it shares most with, and so on; a leaf that points at nothing after the others, so it takes no place a pair that
   * shares would have), the first of each pair on the left.
   */
  findSpines(on) {
    const { m } = this;
    this.spines = new Map();      // container id -> {rows: [[left, right?], ...]}
    this.spineLeaf = new Set();   // the leaves of every spine: everything they point at is a pill
    this.leftSide = new Set();    // the leaves on a spine's left, whose pills are on their left
    if (!on) return;
    for (const cid of [this.rootCid].concat(this.frameTitles.map((f) => 'f:' + f))) {
      const kids = m.kids.get(cid) || [];
      if (kids.length < 2 || kids.length > 2 * SPINE_ROWS || kids.some((t) => m.node(t).kind === 'frame' || m.node(t).rank != null)) continue;
      const set = new Set(kids), uses = new Map(kids.map((t) => [t, new Set()]));
      let inner = false;
      for (const e of this.out) {
        if (!set.has(e.from)) continue;
        if (set.has(e.to)) { inner = true; break; }
        if (!e.direct && !m.node(e.to).never) uses.get(e.from).add(e.to);
      }
      if (inner) continue;
      for (const e of this.out) if (set.has(e.to) && set.has(e.from)) inner = true;
      const count = new Map();
      for (const s of uses.values()) for (const t of s) count.set(t, (count.get(t) || 0) + 1);
      if (inner || [...count.values()].filter((c) => c >= 2).length < 2) continue;
      const common = (a, b) => { let n = 0; for (const t of uses.get(a)) if (uses.get(b).has(t)) n++; return n; };
      const idle = (t) => (uses.get(t).size ? 0 : 1);
      const left = kids.slice().sort((a, b) => idle(a) - idle(b) || byTitle(a, b)), rows = [];
      while (left.length) {
        const a = left.shift();
        let best = -1, at = -1;
        left.forEach((b, i) => { const c = common(a, b); if (c > best) { best = c; at = i; } });
        rows.push(at >= 0 ? [a, left.splice(at, 1)[0]] : [a]);
      }
      const rowOf = new Map();
      rows.forEach((r, i) => r.forEach((t) => rowOf.set(t, i)));
      // `users`: the leaves that point at something, every one of which a pill must be used by to be the one in the middle
      this.spines.set(cid, { rows, rowOf, users: kids.filter((t) => uses.get(t).size).length });
      for (const t of kids) this.spineLeaf.add(t);
      for (const r of rows) this.leftSide.add(r[0]);
    }
  }

  chain(title) {
    const fp = this.free && this.free.get(title);
    if (fp) return fp.container[0] === 'f' ? this.chain(fp.container.slice(2)).concat([fp.container]) : [this.rootCid];
    const n = this.m.node(title); return [this.rootCid].concat(n.frames.map((f) => 'f:' + f));
  }

  /** A container's children as its layout lays them out: its own (frames and leaves), then the shared pills that live in it. */
  kidsOf(cid) {
    const own = this.m.kids.get(cid) || [];
    const pills = this.freeIn && this.freeIn.get(cid);
    return pills && pills.length ? own.concat(pills) : own;
  }

  isFree(id) { return !!this.free && this.free.has(id); }

  isFrame(id) { return !this.isFree(id) && this.m.node(id).kind === 'frame'; }

  /**
   * Which edges are pills and which arrows, and which pills are shared. state: {promoted, fanned, apart, hosts, splits}: an edge into a
   * promoted node, or out of a fanned-out one (moves.mjs), is a pill; one set apart is a pill of its own beside its start, shared with none;
   * every edge of a spine's card is a pill (`spined`: what they point at, made public). A group is the edges of one target from one
   * innermost container; two or more of them share a pill, in the column of the host (state.hosts, else the first title), and the others'
   * arrows run to that pill. In a spine a shared pill is a box of the spine's layout instead (`free`: its id `FREE` and the group's key,
   * its maker the first user by title), split by the spine's rows unless every card uses it; a part with one user is that user's own pill.
   */
  pillPlan(state) {
    const { m } = this;
    const direct = [], pilled = [], groupMap = new Map(), spined = new Set();
    for (const e of this.out) {
      const apart = !!state.apart && state.apart.has(e.from + SEP + e.to);
      let pill = e.cross || !!e.via || apart;
      if (!pill && !e.direct && (state.promoted.has(e.to) || (state.fanned && state.fanned.has(e.from) && fansOut(m, e)))) {
        pill = true;
      }
      if (!pill && !e.direct && this.spineLeaf.has(e.from) && !m.node(e.to).never) { pill = true; spined.add(e.to); }   // a spine's leaf reaches everything through pills
      if (!pill) { direct.push(e); continue; }
      pilled.push(e);
      const key = e.to + SEP + m.node(e.from).container + (apart ? SEP + e.from : '');
      let g = groupMap.get(key);
      if (!g) groupMap.set(key, g = { key, target: e.to, container: m.node(e.from).container, edges: [] });
      g.edges.push(e);
    }
    const byStart = new Map(), members = [], groups = [];
    const add = (start, entry) => { let l = byStart.get(start); if (!l) byStart.set(start, l = []); l.push(entry); };
    // a group is split (state.splits: group key -> {user -> cluster}) into one group a cluster, each with its own pill
    const all = [];
    for (const g of [...groupMap.values()].sort((a, b) => byTitle(a.key, b.key))) {
      const sp = state.splits && state.splits.get(g.key);
      if (!sp) { g.base = g.key; all.push(g); continue; }
      // every cluster shares a pill of its own, beside its host (draw's `share: "<host>"` names whose pill to reuse)
      const parts = new Map();
      for (const e of g.edges) {
        const c = sp.has(e.from) ? sp.get(e.from) : 0;
        let q = parts.get(c); if (!q) parts.set(c, q = { key: g.key + '\u0002' + c, base: g.key, target: g.target, container: g.container, edges: [] });
        q.edges.push(e);
      }
      for (const c of [...parts.keys()].sort((a, b) => a - b)) all.push(parts.get(c));
    }
    // a pill two or more users share is in the column of a host (state.hosts, else the first title), and the others' arrows run to it; in a
    // spine it is an item of the spine's layout instead, `pill` its id there, placed among its users: its host is only the user whose edge
    // makes it in the script (the first by title), and every user's arrow runs to it, the host's too
    const free = [];
    for (const g of all) {
      g.edges.sort((a, b) => byTitle(a.from, b.from));
      g.froms = g.edges.map((e) => e.from);
      g.shared = g.edges.length >= 2;
      const sp = this.spines.get(g.container);
      if (sp && g.shared) {
        // a spine's pill (the owner's mock B): one that every leaf uses (every one that points at something) is one, in the middle of the
        // column; any other is shared by its users in each row, beside that row, and a user alone in its row has a pill of its own on its
        // outer side (a copy)
        const parts = [];
        if (g.edges.length === sp.users) parts.push(g.edges);
        else {
          const byRow = new Map();
          for (const e of g.edges) { const r = sp.rowOf.get(e.from); if (!byRow.has(r)) byRow.set(r, []); byRow.get(r).push(e); }
          for (const r of [...byRow.keys()].sort((a, b) => a - b)) parts.push(byRow.get(r));
        }
        parts.forEach((edges, i) => {
          const q = { key: parts.length > 1 ? g.key + '\u0002r' + i : g.key, base: g.base, target: g.target, container: g.container, edges, froms: edges.map((e) => e.from), shared: edges.length >= 2 };
          groups.push(q);
          if (!q.shared) { add(edges[0].from, { e: edges[0], users: 1, shared: false }); return; }
          q.free = true; q.host = q.froms[0]; q.pill = FREE + q.key;
          for (const e of edges) {
            if (e.from === q.host) free.push({ e, key: q.key, pill: q.pill, users: edges.length });
            else members.push({ e, host: q.host, key: q.key, free: true });
          }
        });
        continue;
      }
      groups.push(g);
      if (!g.shared) { for (const e of g.edges) add(e.from, { e, users: 1, shared: false }); continue; }
      const wanted = state.hosts && state.hosts.get(g.key);
      g.host = g.froms.includes(wanted) ? wanted : g.froms[0];
      for (const e of g.edges) {
        if (e.from === g.host) add(e.from, { e, users: g.edges.length, shared: true });
        else members.push({ e, host: g.host, key: g.key });
      }
    }
    const bi = (e) => m.boardIndex.get(m.node(e.to).board);
    for (const l of byStart.values()) l.sort((a, b) => (b.shared ? 1 : 0) - (a.shared ? 1 : 0) || bi(a.e) - bi(b.e) || byTitle(a.e.to, b.e.to));   // a column: the pills that others share first, so that they are the first made
    // what the layout is to keep near: the plain arrows, each user of a shared pill near its host, and each user of a spine's shared pill near the pill
    const layoutEdges = direct.map((e) => ({ from: e.from, to: e.to, weight: e.weight }))
      .concat(members.map((x) => (x.free ? { from: x.e.from, to: FREE + x.key, weight: x.e.weight } : { from: x.e.from, to: x.host, weight: x.e.weight, pill: true })))
      .concat(free.map((f) => ({ from: f.e.from, to: f.pill, weight: f.e.weight })));
    return { byStart, direct, pilled, members, free, groups, layoutEdges, spined: [...spined].sort(byTitle) };
  }

  /** The hosts of the groups (all, or those whose keys are in `only`), chosen against a layout. Returns a new map. */
  assignHosts(state, layout, only) {
    const hosts = new Map(state.hosts);
    for (const g of this.pillPlan(state).groups) {
      if (!g.shared || g.free || (only && !only.has(g.key))) continue;
      hosts.set(g.key, bestHost(layout.boxes, g.froms, this.pillW(g.target), this.k));
    }
    return hosts;
  }

  pillW(target) { return this.sizes.pillWidth[target] || 120; }

  unit(title, pills) {
    const s = this.sizes.shapes[title];
    if (!s) throw new Error(`no size for "${title}"`);
    const { pillHeight, pillStep, pillGap } = this.k;
    const w = Math.ceil(s.w), h = Math.ceil(s.h);
    const k = pills ? pills.length : 0;
    if (!k) return { w, h, noteW: w, noteH: h, ny: 0, colTop: 0, k: 0, nx: 0 };
    const colW = pillGap + Math.max(...pills.map((x) => this.pillW(x.e.to)));
    const colH = k * pillHeight + (k - 1) * pillStep;
    const top = h / 2 - colH / 2;   // draw centres a column of pills as a whole on its start
    const minY = Math.floor(Math.min(0, top)), maxY = Math.ceil(Math.max(h, top + colH));   // whole units: the note lands on an integer
    // a spine's left leaf has its column on its left (its edges leave from its left), its note at the right of its box
    const nx = this.leftSide.has(title) ? colW : 0;
    return { w: w + colW, h: maxY - minY, noteW: w, noteH: h, ny: -minY, colTop: top, k, nx };
  }

  /** The edges, lifted to the lowest container that holds both ends, between that container's children. n counts the arrows, np those of them that run to a pill beside the shape itself. */
  lift(edges) {
    const lifted = new Map();
    for (const e of edges) {
      const ca = this.chain(e.from), cb = this.chain(e.to);
      let k = 0;
      while (k < ca.length && k < cb.length && ca[k] === cb[k]) k++;
      const lca = ca[k - 1];
      const a = k < ca.length ? ca[k].slice(2) : e.from, b = k < cb.length ? cb[k].slice(2) : e.to;
      if (a === b) continue;
      let m = lifted.get(lca); if (!m) lifted.set(lca, m = new Map());
      const key = a + SEP + b, old = m.get(key);
      const np = e.pill && k >= cb.length ? 1 : 0;
      if (old) { old.w += e.weight; old.n++; old.np += np; } else m.set(key, { a, b, w: e.weight, n: 1, np });
    }
    const out = new Map();
    for (const [cid, m] of lifted) out.set(cid, [...m.values()].sort((x, y) => byTitle(x.a, y.a) || byTitle(x.b, y.b)));
    return out;
  }

  async layout(state) {
    const t0 = Date.now();
    const plan = this.pillPlan(state);
    // the shared pills, each an item of its container's layout
    this.free = new Map(); this.freeIn = new Map();
    for (const g of plan.groups) {
      if (!g.free) continue;
      this.free.set(g.pill, { container: g.container, target: g.target, host: g.host, users: g.edges.length, froms: g.froms, key: g.key, w: this.pillW(g.target) });
      let l = this.freeIn.get(g.container); if (!l) this.freeIn.set(g.container, l = []); l.push(g.pill);
    }
    for (const l of this.freeIn.values()) l.sort();
    const units = new Map();
    for (const n of this.leaves) units.set(n.title, this.unit(n.title, plan.byStart.get(n.title)));
    const lifted = this.lift(plan.layoutEdges);
    const algos = new Map(), info = new Map();
    for (const cid of [this.rootCid].concat(this.frameTitles.map((f) => 'f:' + f))) algos.set(cid, chooseAlgorithm(this.kidsOf(cid), lifted.get(cid) || []));
    const res = new Map();
    await this.separate(this.rootCid, units, lifted, algos, res, info, this.aspect);
    // assemble absolute boxes
    const boxes = new Map(), frames = new Map(), pills = [], pillAt = new Map(), freeAt = new Map();
    const walk = (cid, ox, oy) => {
      for (const [t, p] of res.get(cid).pos) {
        const x = ox + p.x, y = oy + p.y;
        if (this.isFree(t)) {
          const fp = this.free.get(t);
          freeAt.set(fp.key, pills.length);
          pills.push({ start: fp.host, target: fp.target, users: fp.users, shared: true, free: true, x, y, w: fp.w, h: this.k.pillHeight });
          continue;
        }
        if (this.m.node(t).kind === 'frame') { const r = res.get('f:' + t); frames.set(t, { x, y, w: r.w, h: r.h }); walk('f:' + t, x, y); continue; }
        const u = units.get(t);
        boxes.set(t, { x: x + (u.nx || 0), y: y + u.ny, w: u.noteW, h: u.noteH });
        (plan.byStart.get(t) || []).forEach((en, i) => {
          pillAt.set(t + SEP + en.e.to, pills.length);
          const pw = this.pillW(en.e.to);
          const px = u.nx ? x + u.nx - this.k.pillGap - pw : x + u.noteW + this.k.pillGap;   // a column on the left: each pill its gap left of the note
          pills.push({ start: t, target: en.e.to, users: en.users, shared: en.shared, left: !!u.nx, x: px, y: y + u.ny + u.colTop + i * (this.k.pillHeight + this.k.pillStep), w: pw, h: this.k.pillHeight });
        });
      }
    };
    walk(this.rootCid, 0, 0);
    for (const x of plan.members) x.pill = x.free ? freeAt.get(x.key) : pillAt.get(x.host + SEP + x.e.to);
    for (const f of plan.free) f.at = freeAt.get(f.key);
    this.stats.layouts++;
    const root = res.get(this.rootCid);
    const layout = { board: this.board, boxes, frames, pills, w: root.w, h: root.h, algos, mode: 'separate', plan, ms: Date.now() - t0 };
    layout.shape = this.shapeOf(this.rootCid, this.aspect);
    layout.raws = new Map([...res].map(([cid, r]) => [cid, { algo: r.algo, pos: r.raw, dir: r.dir, k: r.k, ranked: r.ranked, at: r.at }]));
    layout.containers = [...info].map(([cid, i]) => Object.assign({ container: cid.slice(2) || null }, i, { w: res.get(cid).w, h: res.get(cid).h }));
    layout.fills = fillsOf(layout, this.m);
    return layout;
  }

  /**
   * The shape a container is to be: `target` (width over height), and the view's size, unless the shape is a slot's (`slot`: a ranked
   * child's is its share of the container, whatever the view could show of it).
   */
  shapeOf(cid, target, slot) {
    return { aspect: target, viewW: slot ? 0 : this.view.w, viewH: slot ? 0 : this.view.h };
  }

  /** A shared pill as its container lays it out: a box of its own. */
  freeItem(t) { return { id: t, w: this.free.get(t).w, h: this.k.pillHeight }; }

  /**
   * A spine laid out: its rows top to bottom, each row's first leaf on the left (its column of pills on its outer side, its note's right
   * edge on the spine) and its second on the right, and between them a column of the pills they share, each beside the rows its users are
   * in (a pill whose users are in rows 0 and 1 between those rows), the narrower spans first, then by title. Nothing is searched: the
   * arrows run from each leaf's inner side to the column, and none crosses a leaf.
   */
  spine(sp, items) {
    const at = new Map(items.map((it, i) => [it.id, i]));
    const GAP = 160, ROWGAP = 64, step = this.k.pillHeight + this.k.pillStep, col = (n) => n * step - this.k.pillStep;
    const W = (t) => items[at.get(t)].w, H = (t) => items[at.get(t)].h;
    const rowOf = new Map();
    sp.rows.forEach((r, i) => r.forEach((t) => rowOf.set(t, i)));
    // each shared pill at the mean of its users' rows: beside a row when that is within a quarter of it, else between two rows
    const shared = items.filter((it) => this.isFree(it.id)).map((it) => {
      const rows = this.free.get(it.id).froms.map((u) => rowOf.get(u));
      const lo = Math.min(...rows), hi = Math.max(...rows), mean = rows.reduce((s, r) => s + r, 0) / rows.length;
      return { it, mean, span: hi - lo, mid: Math.abs(mean - Math.round(mean)) <= 0.25 ? Math.round(mean) : Math.floor(mean) + 0.5 };
    }).sort((a, b) => a.mean - b.mean || a.span - b.span || byTitle(a.it.id, b.it.id));
    const L = Math.max(0, ...sp.rows.map((r) => W(r[0])));
    const M = Math.max(0, ...shared.map((p) => p.it.w));
    const midX = L + GAP, rightX = midX + M + GAP;
    const pos = new Array(items.length);
    const putColumn = (ps, top) => ps.forEach((p, i) => { pos[at.get(p.it.id)] = { x: Math.round(midX + (M - p.it.w) / 2), y: Math.round(top + i * step) }; });
    let y = 0, right = midX + M;
    sp.rows.forEach((row, r) => {
      const here = shared.filter((p) => p.mid === r), after = shared.filter((p) => p.mid === r + 0.5);
      const h = Math.max(...row.map(H), here.length ? col(here.length) : 0);
      const [a, b] = row;
      pos[at.get(a)] = { x: L - W(a), y: Math.round(y + (h - H(a)) / 2) };
      if (b) { pos[at.get(b)] = { x: rightX, y: Math.round(y + (h - H(b)) / 2) }; right = Math.max(right, rightX + W(b)); }
      putColumn(here, y + (h - (here.length ? col(here.length) : 0)) / 2);
      y += h + ROWGAP;
      if (after.length) { putColumn(after, y); y += col(after.length) + ROWGAP; }
    });
    // what lies past the last row (a pill whose users' middle is past it can't be): kept, below
    for (let i = 0; i < items.length; i++) if (!pos[i]) { pos[i] = { x: midX, y }; y += step; }
    return { pos, w: Math.max(L, right), h: Math.max(0, y - ROWGAP), algo: 'spine' };
  }

  /** A leaf as its container lays it out: its box, and, when a column of pills is beside it, where its note is in the box (ownCostParts). */
  leafItem(t, units) {
    const u = units.get(t);
    return u.k ? { id: t, w: u.w, h: u.h, nw: u.noteW, nh: u.noteH, ny: u.ny, nx: u.nx } : { id: t, w: u.w, h: u.h };
  }

  /** `target` is the shape the container aims at; the frames in it aim at the view's (a ranked container's children at their slots': separateRanked). */
  async separate(cid, units, lifted, algos, res, info, target, slot) {
    const kids = this.kidsOf(cid);
    const isFrame = cid[0] === 'f';
    const ranks = kids.map((t) => (this.isFree(t) ? null : this.m.node(t).rank));
    if (ranks.some((x) => x != null)) return this.separateRanked(cid, kids, ranks, units, lifted, algos, res, info, target);   // ranked children are rows or columns, whatever their arrows ask
    const items = [];
    for (const t of kids) {
      if (this.isFree(t)) items.push(this.freeItem(t));
      else if (this.m.node(t).kind === 'frame') { await this.separate('f:' + t, units, lifted, algos, res, info, this.aspect); const r = res.get('f:' + t); items.push({ id: t, w: r.w, h: r.h }); }
      else items.push(this.leafItem(t, units));
    }
    const shape = this.shapeOf(cid, target, slot);
    const algo = algos.get(cid);
    const index = new Map(items.map((it, i) => [it.id, i]));
    const edges = (lifted.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w, n: e.n, np: e.np }));
    const spine = this.spines.get(cid);
    if (spine) {
      const r = this.spine(spine, items);
      r.parts = ownCostParts(items, r.pos, edges, FILL_WEIGHT, shape);
      this.settle(cid, items, r, edges, res, info);
      return;
    }
    const anchor = this.anchors.get(cid);
    const canWarm = !!anchor && !!anchor.pos && items.every((it) => anchor.pos.has(it.id));
    const warm = this.warm && canWarm && (algo === 'layered' || algo === 'stress');
    const pinned = this.warm && anchor && anchor.algo === algo ? anchor.dir : null;   // while the loop searches, a tree keeps the way it runs
    const held = this.hold && anchor && anchor.at && items.every((it) => anchor.at.has(it.id)) ? anchor : null;
    let r;
    if (!items.length) r = { pos: [], w: 0, h: 0, algo };
    else if (held) {
      // held: the children where the layout has them (a note where it was, as its box grows about it), and only what a grown box now overlaps pushed
      // off it, and what that overlaps in turn (a pill put beside a note widens its box, and a taller column of them reaches above and below it)
      const gx = isFrame ? this.k.tightGap : PACK_GAP, gy = isFrame ? 64 : PACK_GAP;
      const was = items.map((it) => held.at.get(it.id));
      const grown = items.map((it, i) => was[i].w !== it.w || was[i].h !== it.h);
      const from = items.map((it, i) => ({ x: was[i].x, y: was[i].y + was[i].ny - (it.ny || 0) }));
      let at = pushApart(items, from, gx, gy, grown).map((p) => ({ x: Math.round(p.x), y: Math.round(p.y) }));
      if (overlapping(items, at)) at = removeOverlaps(items, at, gx, gy);   // a crowd that would not settle: every box pushed clear, whatever moves
      r = Object.assign(normalize(items, at), { algo: held.algo, dir: held.dir, k: held.k, raw: items.map((it) => (held.pos ? held.pos.get(it.id) : held.at.get(it.id))), costs: this.costsSeen.get(cid) || null, warm: true });
      r.parts = ownCostParts(items, r.pos, edges, FILL_WEIGHT, shape);
    } else {
      const sd = this.seedMap ? (this.seedMap.get(cid) || 0) : 0;   // a perturbation: this container is laid out with another seed (noise.js)
      const nudge = this.nudge ? this.nudge(cid, items) : null;    // and one with its boxes' sizes changed a little
      const sizeKey = items.map((i) => i.id + '\u0001' + i.w + 'x' + i.h + (i.nw == null ? '' : '/' + i.nw + ',' + i.ny + ',' + (i.nx || 0))).join('\u0002');
      const packMode = this.squeeze ? this.opts.pack : (this.opts.pack === 'off' ? 'off' : 'gravity');
      const shapeKey = Math.round(target * 1000) + (slot ? 's' : '');
      const forced = this.force && !warm ? this.force.get(cid) : null;
      const key = packMode + (forced ? 'F' + forced : '') + (warm ? 'w' + anchor.sig : 'c' + sd + (pinned || '')) + (nudge ? 'n' + nudge : '') + algo + SEP + shapeKey + SEP + sizeKey + SEP + edges.map((e) => e.a + '>' + e.b + ':' + e.w + ':' + e.n + ':' + e.np).join(',');
      r = this.cache.get(key);
      if (r) this.stats.hits++;
      else {
        if (this.missLog) this.missLog.push(cid);
        const items2 = nudge ? items.map((it, i) => Object.assign({}, it, { w: it.w + nudge * (1 + ((i * 7 + sd) % 5)) })) : items;
        const cost = (pos, fw) => ownCost(items2, pos, edges, fw == null ? FILL_WEIGHT : fw, shape);
        const round = (x) => Math.round(x * 100) / 100;
        if (warm) r = Object.assign(this.relax(anchor, items2, edges, shape, cost), { algo: anchor.algo, dir: anchor.dir, costs: this.costsSeen.get(cid) || null, warm: true });
        else if (algo === 'layered' || algo === 'stress') {
          // layered with its arrows running down and across, and stress as it comes and stretched to the shape: the cheapest kept (the first on a
          // tie: layered, down); and, when the container has a place already, from there too
          const tries = [];
          const tried = (name, x, more) => { x.cost = cost(x.pos); tries.push(Object.assign({}, x, more, { name })); };
          tried('layered', await this.flat('layered', items2, edges, sd || undefined, { dir: 'DOWN' }), { algo: 'layered', dir: 'DOWN' });
          tried('across', await this.flat('layered', items2, edges, sd || undefined, { dir: 'RIGHT' }), { algo: 'layered', dir: 'RIGHT' });
          const S = await this.flat('stress', items2, edges, sd || undefined);
          tried('stress', S, { algo: 'stress', k: 1 });
          const st = stretched(items2, S.raw || S.pos, shape);
          if (st.k !== 1) tried('stretched', Object.assign(normalize(items2, st.pos), { raw: st.raw }), { algo: 'stress', k: st.k });
          r = tries[0];
          for (const t of tries) if (t.cost < r.cost - 1e-9) r = t;
          const asked = forced ? tries.find((t) => t.name === forced) : null;
          if (asked) r = asked;
          r = Object.assign({}, r);
          r.costs = {}; for (const t of tries) r.costs[t.name] = round(t.cost);
          if (canWarm && !asked) {   // the container as it is, laid out again from its place: kept if it is cheaper than every fresh layout
            const W = this.relax(anchor, items2, edges, shape, cost); W.cost = cost(W.pos);
            r.costs.warm = round(W.cost);
            if (W.cost < r.cost - 1e-9) r = Object.assign({}, W, { algo: anchor.algo, dir: anchor.dir, costs: r.costs, warm: true });
          }
          this.costsSeen.set(cid, r.costs);
        } else if (algo === 'mrtree') {
          // a tree runs down or across, whichever costs less, its shape counted in (down on a tie)
          const down = pinned === 'RIGHT' ? null : Object.assign(await this.flat('mrtree', items2, edges, undefined, { dir: 'DOWN' }), { algo, dir: 'DOWN' });
          const across = pinned === 'DOWN' ? null : Object.assign(await this.flat('mrtree', items2, edges, undefined, { dir: 'RIGHT' }), { algo, dir: 'RIGHT' });
          r = down && across ? (cost(across.pos) < cost(down.pos) - 1e-9 ? across : down) : (down || across);
        } else r = Object.assign(await this.flat('rectpacking', items2, edges, undefined, { aspect: target }), { algo });
        if (packMode !== 'off' && items.length > 1) {   // packed: nothing stranded from its mates, the frames of a board near each other
          const raw = r.raw || r.pos;
          const gx = isFrame ? this.k.tightGap : PACK_GAP, gy = isFrame ? 64 : PACK_GAP;
          // gravity (every box slides toward its place) always; squeezing the air out too, where the dial says the crossings it costs are worth the room
          const start = isFrame ? r.pos : removeOverlaps(items2, r.pos, gx + 16, gy + 16);   // the board's frames at least PACK_GAP apart (16 more: the grid snap takes up to that)
          let pk = pack(items2, start, edges, gx, gy, false);
          const fw = packFillWeight(this.m.dial.mess);
          if (packMode !== 'gravity') {
            const sq = pack(items2, start, edges, gx, gy, true);
            if (packMode === 'squeeze' || cost(sq.pos, fw) < cost(pk.pos, fw)) pk = sq;
          }
          if (packMode !== 'gravity' && !isFrame && algo !== 'rectpacking' && algo !== 'trivial') {
            // the board's frames as rows (ELK's rectpacking, ignoring the arrows) is a third way to lay the board out: kept if its arrows, crossings and room cost less (its shape included)
            const rp = await this.flat('rectpacking', items2, edges, undefined, { aspect: target });
            const rpk = pack(items2, removeOverlaps(items2, rp.pos, gx + 16, gy + 16), edges, gx, gy, true);
            if (cost(rpk.pos, fw) < cost(pk.pos, fw)) { pk = rpk; r = Object.assign({}, r, { rows: true }); }
          }
          r = Object.assign({}, r, { pos: pk.pos, w: pk.w, h: pk.h, raw });
        }
        r.parts = ownCostParts(items2, r.pos, edges, FILL_WEIGHT, shape);
        this.cache.set(key, r);
      }
    }
    this.settle(cid, items, r, edges, res, info);
  }

  /**
   * A container's laid-out children, kept: its size (a frame's with its inset, never under the least frame or its title) and their places in it;
   * and `sub`, what is under it: what its arrows and its frames' cost (their shapes aside), how many there are, and its leaves' area.
   */
  settle(cid, items, r, edges, res, info) {
    const isFrame = cid[0] === 'f';
    const how = r.ranked ? r.ranked.orient : r.dir === 'RIGHT' ? 'across' : r.algo === 'stress' && r.k && r.k !== 1 ? 'stretched' : null;   // what the report says of it, beside its algorithm
    info.set(cid, { algorithm: r.algo, how, warm: !!r.warm, children: items.length, arrows: edges.reduce((s, e) => s + e.n, 0), costs: r.costs || null });
    const pad = isFrame ? this.k.frameInset : 0;
    const title = isFrame ? cid.slice(2) : '';
    const w = isFrame ? Math.max(r.w + 2 * pad, this.k.frameMin.w, Math.ceil(TITLE_PILL(title))) : r.w;
    const h = isFrame ? Math.max(r.h + 2 * pad, this.k.frameMin.h) : r.h;
    const pos = new Map(items.map((it, i) => [it.id, { x: r.pos[i].x + pad, y: r.pos[i].y + pad }]));
    const sub = { arrows: r.parts ? r.parts.arrows : 0, n: r.parts ? r.parts.n : 0, area: 0 };
    for (const it of items) {
      const f = res.get('f:' + it.id);
      if (f && this.isFrame(it.id)) { sub.arrows += f.sub.arrows; sub.n += f.sub.n; sub.area += f.sub.area; } else sub.area += it.w * it.h;
    }
    res.set(cid, { w, h, pos, algo: r.algo, dir: r.dir, k: r.k, ranked: r.ranked, raw: new Map(items.map((it, i) => [it.id, (r.raw || r.pos)[i]])), at: new Map(items.map((it, i) => [it.id, { x: r.pos[i].x, y: r.pos[i].y, w: it.w, h: it.h, ny: it.ny || 0 }])), warm: !!r.warm, sub });
  }

  /** Roughly the room a child takes, before it is laid out: a leaf's box and the gaps kept about it, and a frame's leaves' with a fifth more. */
  roomOf(t, units) {
    if (this.isFree(t)) return (this.free.get(t).w + this.k.tightGap) * (this.k.pillHeight + 64);
    if (this.m.node(t).kind !== 'frame') { const u = units.get(t); return (u.w + this.k.tightGap) * (u.h + 64); }
    return 1.2 * this.kidsOf('f:' + t).reduce((s, c) => s + this.roomOf(c, units), 0) + 1;
  }

  /**
   * A container whose children have ranks: they run as rows, the lowest rank on top, or as columns, the lowest at the left, whichever the view
   * shows larger when the container is fit to it (opts.ranks says one or the other outright). A child is laid out to the shape of its
   * slot: a row of a board that is to be wide is wide and short, a column narrow and tall. How wide the slots are taken to be is tried a few
   * ways (`m`), since a child laid out is not the size it was guessed at. While the loop searches, the way the layout it started from went is kept.
   */
  async separateRanked(cid, kids, ranks, units, lifted, algos, res, info, target) {
    const shape = this.shapeOf(cid, target);
    const index = new Map(kids.map((t, i) => [t, i]));
    const edges = (lifted.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w, n: e.n, np: e.np }));
    // the rows (or columns), each a rank's children; one with no rank goes after them all
    const known = ranks.filter((x) => x != null), last = Math.max(...known) + 1;
    const slots = new Map();
    kids.forEach((t, i) => { const k = ranks[i] == null ? last : ranks[i]; if (!slots.has(k)) slots.set(k, []); slots.get(k).push(i); });
    const order = [...slots.keys()].sort((a, b) => a - b).map((k) => slots.get(k));
    const room = kids.map((t) => this.roomOf(t, units));
    const slotOf = new Array(kids.length), slotRoom = order.map((s) => s.reduce((a, i) => a + room[i], 0));
    order.forEach((s, k) => s.forEach((i) => { slotOf[i] = k; }));
    const all = slotRoom.reduce((a, b) => a + b, 0);
    const attempt = async (orient, m) => {
      const sub = new Map(), subInfo = new Map(), items = [];
      for (let i = 0; i < kids.length; i++) {
        const t = kids[i];
        if (this.isFree(t)) { items.push(this.freeItem(t)); continue; }
        if (this.m.node(t).kind !== 'frame') { items.push(this.leafItem(t, units)); continue; }
        // the shape of the child's slot: its share of a row of a board `target` wide for its height, or of a column of one, but never more than
        // SLOT_MOST times wider (or taller) than `target`: a band with little in it would be a strip, and its children a line
        const s = slotRoom[slotOf[i]];
        const want = orient === 'rows' ? m * target * all * room[i] / (s * s) : m * target * s * s / (all * room[i]);
        const aim = Math.min(SLOT_MOST * target, Math.max(target / SLOT_MOST, want));
        await this.separate('f:' + t, units, lifted, algos, sub, subInfo, Math.min(64, Math.max(1 / 64, aim)), true);
        const r = sub.get('f:' + t); items.push({ id: t, w: r.w, h: r.h });
      }
      const r = this.ranked(items, order, sub, orient);
      r.parts = ownCostParts(items, r.pos, edges, FILL_WEIGHT, shape);
      r.ranked = { orient, m };
      // what the whole costs: its arrows and its children's, its shape, and the room it leaves empty
      let arrows = r.parts.arrows, n = r.parts.n, area = 0;
      items.forEach((it) => { const f = sub.get('f:' + it.id); if (f) { arrows += f.sub.arrows; n += f.sub.n; area += f.sub.area; } else area += it.w * it.h; });
      const off = offShapeOf(r.w, r.h, shape);
      const shown = Math.min(1, shape.viewW / Math.max(r.w, 1), shape.viewH / Math.max(r.h, 1));   // how large the view shows it, fit to it
      const empty = area > 0 ? (r.w * r.h) / area - 1 : 0;
      return { orient, m, items, r, sub, subInfo, cost: arrows + shapeCost(off, n) + (1 + 0.25 * n) * FILL_WEIGHT * empty, off, shown };
    };
    const anchor = this.anchors.get(cid);
    let best = null;
    if (this.warm && anchor && anchor.ranked) best = await attempt(anchor.ranked.orient, anchor.ranked.m);
    else {
      // which way they run is chosen once a board, on its first layout (the loop's moves are made for that way): the way that shows larger when the
      // board is fit to the view (rows when it is the same). How wide the slots are taken to be is found afresh each time, by what the whole costs.
      const ways = this.way.has(cid) ? [this.way.get(cid)] : this.opts.ranks === 'auto' ? ['rows', 'columns'] : [this.opts.ranks];
      for (const orient of ways) {
        let at = null;
        for (const m of [1, 0.5, 2]) { const x = await attempt(orient, m); if (!at || x.cost < at.cost - 1e-9) at = x; }
        for (const f of [Math.SQRT1_2, Math.SQRT2]) { const x = await attempt(orient, at.m * f); if (x.cost < at.cost - 1e-9) at = x; }
        if (!best || at.shown > best.shown * 1.02) best = at;
      }
      this.way.set(cid, best.orient);
    }
    for (const [k, v] of best.sub) res.set(k, v);
    for (const [k, v] of best.subInfo) info.set(k, v);
    this.settle(cid, best.items, best.r, edges, res, info);
  }

  /**
   * Children with ranks, as rows (the lowest rank on top, each row's children left to right in title order) or as columns (the lowest at the
   * left, each column's children top to bottom), PACK_GAP between them. A frame alone in its row is as wide as the widest row, what it holds
   * centred in it: bands. One alone in its column is as tall as the tallest, what it holds at its top. `order` is the rows, each its children's indexes.
   */
  ranked(items, order, res, orient = 'rows') {
    const across = orient !== 'columns';
    const along = (i) => (across ? items[i].w : items[i].h), over = (i) => (across ? items[i].h : items[i].w);
    const length = (slot) => slot.reduce((s, i) => s + along(i), 0) + PACK_GAP * (slot.length - 1);
    const L = Math.max(...order.map(length));
    for (const slot of order) {
      if (slot.length !== 1 || !this.isFrame(items[slot[0]].id)) continue;
      const fr = res.get('f:' + items[slot[0]].id), extra = L - (across ? fr.w : fr.h);
      if (extra <= 0) continue;
      if (across) {
        const dx = Math.floor(extra / 2);
        fr.pos = new Map([...fr.pos].map(([id, p]) => [id, { x: p.x + dx, y: p.y }]));
        fr.w = L; items[slot[0]].w = L;
      } else { fr.h = L; items[slot[0]].h = L; }
    }
    const pos = new Array(items.length);
    let far = 0;
    for (const slot of order) {
      let near = 0;
      for (const i of slot) { pos[i] = across ? { x: near, y: far } : { x: far, y: near }; near += along(i) + PACK_GAP; }
      far += Math.max(...slot.map(over)) + PACK_GAP;
    }
    return across ? { pos, w: L, h: far - PACK_GAP, algo: 'ranked' } : { pos, w: far - PACK_GAP, h: L, algo: 'ranked' };
  }

  /**
   * A container laid out again from its anchor: a stress layout is relaxed from there, keeping its stretch, and stretched further toward its
   * shape when that costs less (a container whose boxes grew, as pills were put beside them, is no longer the shape it was laid out to); any
   * other is kept and only pushed apart where boxes now overlap.
   */
  relax(anchor, items, edges, shape, cost) {
    const init = items.map((it) => anchor.pos.get(it.id));
    this.stats.warm++;
    if (anchor.algo !== 'stress') return Object.assign(normalize(items, removeOverlaps(items, init)), { k: anchor.k });
    const k = anchor.k || 1;
    const w = warmStress(items, edges, init, 300, k);
    const plain = Object.assign(normalize(items, w.pos), { raw: w.raw, k });
    const st = stretched(items, w.raw, shape);
    if (st.k === 1) return plain;
    const aimed = Object.assign(normalize(items, st.pos), { raw: st.raw, k: k * st.k });
    return cost(aimed.pos) < cost(plain.pos) - 1e-9 ? aimed : plain;
  }

  /** The state laid out again from its own layout until it stops moving (a few passes at most): the layout a search compares trials against. */
  async converge(state, layout, evaluate, mu, max = 16) {
    let cur = layout, ev = evaluate(this.m, cur, mu);
    for (let i = 0; i < max; i++) {
      this.setAnchors(cur);
      const next = await this.layout(state), e2 = evaluate(this.m, next, mu);
      const moved = Math.abs(e2.cost - ev.cost);
      cur = next; ev = e2;
      if (moved < 0.5) break;
    }
    this.setAnchors(cur);
    return { cur, ev };
  }

  /** The accepted layout becomes the place the containers are laid out again from: where a layered or a stress layout has its children (and which way it runs, how far it is stretched), which way a tree runs, and how ranked children run. */
  setAnchors(layout) {
    for (const [cid, info] of layout.raws) {
      if (info.algo === 'ranked') { this.anchors.set(cid, { algo: info.algo, ranked: info.ranked }); continue; }
      if (!['layered', 'stress'].includes(info.algo)) { this.anchors.set(cid, { algo: info.algo, dir: info.dir, at: info.at }); continue; }
      const sig = (info.dir || '') + (info.k || 1) + [...info.pos].map(([id, p]) => id + '@' + p.x + ',' + p.y).join(';');
      const old = this.anchors.get(cid);
      if (old && old.sig === sig && old.algo === info.algo) { old.at = info.at; continue; }
      this.anchors.set(cid, { algo: info.algo, dir: info.dir, k: info.k, pos: info.pos, at: info.at, sig });
    }
  }

  /** ELK's layout of boxes, asked once: the same boxes, arrows and options give the same layout. */
  async flat(algo, items, edges, seed, shape) {
    const key = algo + SEP + (seed || 0) + SEP + (shape ? (shape.dir || '') + (shape.aspect ? Math.round(shape.aspect * 1000) : '') : '') + SEP + items.map((i) => i.w + 'x' + i.h).join(',') + SEP + edges.map((e) => e.a + '>' + e.b).join(',');
    const had = this.elkCache.get(key);
    if (had) return Object.assign({}, had);
    this.stats.elkCalls++;
    const t0 = Date.now();
    const r = await layoutFlat(this.elk, algo, items, edges, seed, shape);
    this.elkCache.set(key, r);
    const dt = Date.now() - t0;
    this.stats.elkMs += dt; { const k = 'phase_' + (this.phase || '-'); this.stats[k] = (this.stats[k] || 0) + dt; const c = 'n' + k; this.stats[c] = (this.stats[c] || 0) + 1; } { const sz = 'size_' + algo + '_' + Math.min(40, 5 * Math.ceil(items.length / 5)); this.stats[sz] = (this.stats[sz] || 0) + dt; const sc = 'n' + sz; this.stats[sc] = (this.stats[sc] || 0) + 1; } this.stats['elkMs_' + algo] = (this.stats['elkMs_' + algo] || 0) + dt;
    return Object.assign({}, r);
  }
}

/** Whether any two boxes at these places overlap. */
function overlapping(items, pos) {
  for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) {
    if (pos[i].x < pos[j].x + items[j].w && pos[j].x < pos[i].x + items[i].w && pos[i].y < pos[j].y + items[j].h && pos[j].y < pos[i].y + items[i].h) return true;
  }
  return false;
}

/** How full each frame is: the area of the notes and pills in it over its own area; and the board's, over its bounding box. */
export function fillsOf(layout, model) {
  const frames = {};
  const area = (b) => b.w * b.h;
  for (const [t, f] of layout.frames) {
    let used = 0;
    for (const [n, b] of layout.boxes) if (model.node(n).frames.includes(t)) used += area(b);
    for (const p of layout.pills) if (model.node(p.start).frames.includes(t)) used += area(p);
    frames[t] = { fill: Math.round(used / area(f) * 1000) / 1000, w: f.w, h: f.h };
  }
  let used = 0;
  for (const b of layout.boxes.values()) used += area(b);
  for (const p of layout.pills) used += area(p);
  const board = layout.w > 0 && layout.h > 0 ? Math.round(used / (layout.w * layout.h) * 1000) / 1000 : 1;
  return { frames, board };
}

/** Which algorithm a container's children ask for: by the shape of the arrows among them. Layered and stress are both tried. */
// A container of more children than this is packed as boxes, its arrows drawn over them, whatever they are: laid out by its arrows, a
// star of hundreds (an index file that imports every icon) is a tree a row or a column long (465 notes, 122,512 units, past what draw
// takes), and a crowd of them is a layout that takes minutes. Only a board promote.mjs doesn't search has one (its CROWD).
export const CROWD = 150;

export function chooseAlgorithm(kids, edges) {
  if (kids.length <= 1) return 'trivial';
  if (kids.length > CROWD) return 'rectpacking';
  if (!edges.length) return 'rectpacking';
  if (isForest(kids, edges)) return 'mrtree';
  return 'layered';   // `separate` lays it out both ways and keeps the one that costs less
}

function isForest(kids, edges) {
  const parent = new Map(kids.map((k) => [k, k]));
  const find = (x) => { while (parent.get(x) !== x) { parent.set(x, parent.get(parent.get(x))); x = parent.get(x); } return x; };
  const indeg = new Map();
  for (const e of edges) {
    indeg.set(e.b, (indeg.get(e.b) || 0) + 1);
    if (indeg.get(e.b) > 1) return false;
    const ra = find(e.a), rb = find(e.b);
    if (ra === rb) return false;
    parent.set(ra, rb);
  }
  return true;
}
