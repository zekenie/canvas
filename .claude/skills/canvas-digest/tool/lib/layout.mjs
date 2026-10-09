// A board's layout: each container laid out by the algorithm its shape asks for (a container with arrows among its children is laid
// out both layered and stress, and the cheaper kept), frames sized inside out, every shape with the column of pills it will have
// beside it reserved on its right.
import { byTitle } from './util.mjs';
import { layoutFlat, removeOverlaps, normalize, pack } from './elk.mjs';
import { warmStress } from './stress.mjs';
import { arrowBetween, segLength } from './geom.mjs';
import { ownCost } from './cost.mjs';
import { DEFAULT_CONSTANTS, TITLE_PILL } from './sizes.mjs';

// draw's numbers (a pill's height, step and gap, how far `in` puts a shape from a frame's edge, a frame's least size) come from `canvas measure`: sizes.constants
/** What a container's empty room costs against its arrows, when it chooses between packed layouts: more where the dial is looser (the big picture over the tidy arrow). */
export const packFillWeight = (mess) => 8 * mess;
export const PACK_GAP = 64;   // the gap kept between the frames (and loose notes) of a board: ELK's spacing, between draw's tight (40) and normal (80); inside a frame, notes keep 40 x 64
const SEP = '\u0000';

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
   * model, board title, sizes (sizesFrom's), an ELK instance. Each container is laid out a container at a time, both ways (layered and stress), the cheaper kept.
   * The users of one target in one container share one pill, in a host's column. opts.pack is auto (the default), gravity, squeeze or off.
   */
  constructor(model, board, sizes, opts, elk) {
    this.m = model; this.board = board; this.sizes = sizes; this.opts = Object.assign({ pack: 'auto' }, opts); this.elk = elk;
    this.k = Object.assign({}, DEFAULT_CONSTANTS, sizes.constants || {});
    this.cache = new Map();
    this.costsSeen = new Map();
    this.squeeze = false;       // the search packs by gravity only (a squeeze changes with every trial); the final layout may squeeze the air out too
    this.warm = false;          // while the loop searches: a container is laid out again from where it is (its anchor), in a millisecond, not afresh by ELK
    this.anchors = new Map();   // container id -> {algo, pos: Map(id -> {x, y}), sig}: where the accepted layout has the container's children
    this.stats = { layouts: 0, elkCalls: 0, hits: 0, elkMs: 0, warm: 0 };
    this.rootCid = 'b:' + board;
    this.out = model.edges.filter((e) => model.node(e.from).board === board);
    this.sameBoard = this.out.filter((e) => !e.cross);
    this.leaves = [...model.nodes.values()].filter((n) => n.board === board && n.kind !== 'frame');
    this.frameTitles = [...model.nodes.values()].filter((n) => n.board === board && n.kind === 'frame').map((n) => n.title);
  }

  chain(title) { const n = this.m.node(title); return [this.rootCid].concat(n.frames.map((f) => 'f:' + f)); }

  /**
   * Which edges are pills and which arrows, and which pills are shared. state: {promoted, hosts, splits}.
   * A group is the edges of one target from one innermost container; two or more of them share a pill , in the column of the host (state.hosts, else the first title); the others' arrows run to that pill.
   */
  pillPlan(state) {
    const { m } = this;
    const direct = [], pilled = [], groupMap = new Map();
    for (const e of this.out) {
      let pill = e.cross || !!e.via;
      if (!pill && !e.direct && state.promoted.has(e.to)) {
        pill = true;
      }
      if (!pill) { direct.push(e); continue; }
      pilled.push(e);
      const key = e.to + SEP + m.node(e.from).container;
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
    for (const g of all) {
      g.edges.sort((a, b) => byTitle(a.from, b.from));
      g.froms = g.edges.map((e) => e.from);
      g.shared = g.edges.length >= 2;
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
    // what the layout is to keep near: the plain arrows, and each user of a shared pill near its host
    const layoutEdges = direct.map((e) => ({ from: e.from, to: e.to, weight: e.weight })).concat(members.map((x) => ({ from: x.e.from, to: x.host, weight: x.e.weight })));
    return { byStart, direct, pilled, members, groups, layoutEdges };
  }

  /** The hosts of the groups (all, or those whose keys are in `only`), chosen against a layout. Returns a new map. */
  assignHosts(state, layout, only) {
    const hosts = new Map(state.hosts);
    for (const g of this.pillPlan(state).groups) {
      if (!g.shared || (only && !only.has(g.key))) continue;
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
    if (!k) return { w, h, noteW: w, noteH: h, ny: 0, colTop: 0, k: 0 };
    const colW = pillGap + Math.max(...pills.map((x) => this.pillW(x.e.to)));
    const colH = k * pillHeight + (k - 1) * pillStep;
    const top = h / 2 - colH / 2;   // draw centres a column of pills as a whole on its start
    const minY = Math.floor(Math.min(0, top)), maxY = Math.ceil(Math.max(h, top + colH));   // whole units: the note lands on an integer
    return { w: w + colW, h: maxY - minY, noteW: w, noteH: h, ny: -minY, colTop: top, k };
  }

  /** The edges, lifted to the lowest container that holds both ends, between that container's children. n counts the arrows. */
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
      if (old) { old.w += e.weight; old.n++; } else m.set(key, { a, b, w: e.weight, n: 1 });
    }
    const out = new Map();
    for (const [cid, m] of lifted) out.set(cid, [...m.values()].sort((x, y) => byTitle(x.a, y.a) || byTitle(x.b, y.b)));
    return out;
  }

  async layout(state) {
    const t0 = Date.now();
    const plan = this.pillPlan(state);
    const units = new Map();
    for (const n of this.leaves) units.set(n.title, this.unit(n.title, plan.byStart.get(n.title)));
    const lifted = this.lift(plan.layoutEdges);
    const algos = new Map(), info = new Map();
    for (const cid of [this.rootCid].concat(this.frameTitles.map((f) => 'f:' + f))) algos.set(cid, chooseAlgorithm(this.m.kids.get(cid), lifted.get(cid) || []));
    const res = new Map();
    await this.separate(this.rootCid, units, lifted, algos, res, info);
    // assemble absolute boxes
    const boxes = new Map(), frames = new Map(), pills = [], pillAt = new Map();
    const walk = (cid, ox, oy) => {
      for (const [t, p] of res.get(cid).pos) {
        const x = ox + p.x, y = oy + p.y;
        if (this.m.node(t).kind === 'frame') { const r = res.get('f:' + t); frames.set(t, { x, y, w: r.w, h: r.h }); walk('f:' + t, x, y); continue; }
        const u = units.get(t);
        boxes.set(t, { x, y: y + u.ny, w: u.noteW, h: u.noteH });
        (plan.byStart.get(t) || []).forEach((en, i) => {
          pillAt.set(t + SEP + en.e.to, pills.length);
          pills.push({ start: t, target: en.e.to, users: en.users, shared: en.shared, x: x + u.noteW + this.k.pillGap, y: y + u.ny + u.colTop + i * (this.k.pillHeight + this.k.pillStep), w: this.pillW(en.e.to), h: this.k.pillHeight });
        });
      }
    };
    walk(this.rootCid, 0, 0);
    for (const x of plan.members) x.pill = pillAt.get(x.host + SEP + x.e.to);
    this.stats.layouts++;
    const root = res.get(this.rootCid);
    const layout = { board: this.board, boxes, frames, pills, w: root.w, h: root.h, algos, mode: 'separate', plan, ms: Date.now() - t0 };
    layout.raws = new Map([...res].map(([cid, r]) => [cid, { algo: r.algo, pos: r.raw }]));
    layout.containers = [...info].map(([cid, i]) => Object.assign({ container: cid.slice(2) || null }, i, { w: res.get(cid).w, h: res.get(cid).h }));
    layout.fills = fillsOf(layout, this.m);
    return layout;
  }

  async separate(cid, units, lifted, algos, res, info) {
    const kids = this.m.kids.get(cid);
    const isFrame = cid[0] === 'f';
    const items = [];
    for (const t of kids) {
      if (this.m.node(t).kind === 'frame') { await this.separate('f:' + t, units, lifted, algos, res, info); const r = res.get('f:' + t); items.push({ id: t, w: r.w, h: r.h }); }
      else { const u = units.get(t); items.push({ id: t, w: u.w, h: u.h }); }
    }
    const algo = algos.get(cid);
    const index = new Map(items.map((it, i) => [it.id, i]));
    const edges = (lifted.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w, n: e.n }));
    const anchor = this.anchors.get(cid);
    const canWarm = !!anchor && items.every((it) => anchor.pos.has(it.id));
    const warm = this.warm && canWarm && (algo === 'layered' || algo === 'stress');
    let r;
    if (!items.length) r = { pos: [], w: 0, h: 0, algo };
    else {
      const sd = this.seedMap ? (this.seedMap.get(cid) || 0) : 0;   // a perturbation: this container is laid out with another seed (noise.js)
      const nudge = this.nudge ? this.nudge(cid, items) : null;    // and one with its boxes' sizes changed a little
      const sizeKey = items.map((i) => i.id + '\u0001' + i.w + 'x' + i.h).join('\u0002');
      const packMode = this.squeeze ? this.opts.pack : (this.opts.pack === 'off' ? 'off' : 'gravity');
      const key = packMode + (warm ? 'w' + anchor.sig : 'c' + sd) + (nudge ? 'n' + nudge : '') + algo + SEP + sizeKey + SEP + edges.map((e) => e.a + '>' + e.b + ':' + e.w + ':' + e.n).join(',');
      r = this.cache.get(key);
      if (r) this.stats.hits++;
      else {
        if (this.missLog) this.missLog.push(cid);
        const items2 = nudge ? items.map((it, i) => Object.assign({}, it, { w: it.w + nudge * (1 + ((i * 7 + sd) % 5)) })) : items;
        if (warm) r = Object.assign(this.relax(anchor, items2, edges), { algo: anchor.algo, costs: this.costsSeen.get(cid) || null, warm: true });
        else if (algo === 'layered' || algo === 'stress') {
          // both ways, the cheaper kept (layered on a tie); and, when the container has a place already, from there too
          const best = async (a) => { const x = await this.flat(a, items2, edges, sd || undefined); x.cost = ownCost(items2, x.pos, edges); return x; };
          const L = await best('layered'), S = await best('stress');
          const cl = L.cost, cs = S.cost;
          r = cs < cl - 1e-9 ? Object.assign({}, S, { algo: 'stress' }) : Object.assign({}, L, { algo: 'layered' });
          r.costs = { layered: Math.round(cl * 100) / 100, stress: Math.round(cs * 100) / 100 };
          if (canWarm) {   // the container as it is, laid out again from its place: kept if it is cheaper than both fresh layouts
            const W = this.relax(anchor, items2, edges); W.cost = ownCost(items2, W.pos, edges);
            r.costs.warm = Math.round(W.cost * 100) / 100;
            if (W.cost < r.cost - 1e-9) r = Object.assign({}, W, { algo: anchor.algo, costs: r.costs, warm: true });
          }
          this.costsSeen.set(cid, r.costs);
        } else r = Object.assign(await this.flat(algo === 'trivial' ? 'rectpacking' : algo, items2, edges), { algo });
        if (packMode !== 'off' && items.length > 1) {   // packed: nothing stranded from its mates, the frames of a board near each other
          const raw = r.raw || r.pos;
          const gx = isFrame ? this.k.tightGap : PACK_GAP, gy = isFrame ? 64 : PACK_GAP;
          // gravity (every box slides toward its place) always; squeezing the air out too, where the dial says the crossings it costs are worth the room
          const start = isFrame ? r.pos : removeOverlaps(items2, r.pos, gx + 16, gy + 16);   // the board's frames at least PACK_GAP apart (16 more: the grid snap takes up to that)
          let pk = pack(items2, start, edges, gx, gy, false);
          if (packMode !== 'gravity') {
            const sq = pack(items2, start, edges, gx, gy, true);
            const fw = packFillWeight(this.m.dial.mess);
            if (packMode === 'squeeze' || ownCost(items2, sq.pos, edges, fw) < ownCost(items2, pk.pos, edges, fw)) pk = sq;
          }
          if (packMode !== 'gravity' && !isFrame && algo !== 'rectpacking' && algo !== 'trivial') {
            // the board's frames as rows (ELK's rectpacking, ignoring the arrows) is a third way to lay the board out: kept if its arrows, crossings and room cost less (the aspect included)
            const fw = packFillWeight(this.m.dial.mess);
            const rp = await this.flat('rectpacking', items2, edges);
            const rpk = pack(items2, removeOverlaps(items2, rp.pos, gx + 16, gy + 16), edges, gx, gy, true);
            if (ownCost(items2, rpk.pos, edges, fw) < ownCost(items2, pk.pos, edges, fw)) { pk = rpk; r = Object.assign({}, r, { rows: true }); }
          }
          r = Object.assign({}, r, { pos: pk.pos, w: pk.w, h: pk.h, raw });
        }
        this.cache.set(key, r);
      }
    }
    info.set(cid, { algorithm: r.algo, warm: !!r.warm, children: items.length, arrows: edges.reduce((s, e) => s + e.n, 0), costs: r.costs || null });
    const pad = isFrame ? this.k.frameInset : 0;
    const title = isFrame ? cid.slice(2) : '';
    const w = isFrame ? Math.max(r.w + 2 * pad, this.k.frameMin.w, Math.ceil(TITLE_PILL(title))) : r.w;
    const h = isFrame ? Math.max(r.h + 2 * pad, this.k.frameMin.h) : r.h;
    const pos = new Map(items.map((it, i) => [it.id, { x: r.pos[i].x + pad, y: r.pos[i].y + pad }]));
    res.set(cid, { w, h, pos, algo: r.algo, raw: new Map(items.map((it, i) => [it.id, (r.raw || r.pos)[i]])), warm: !!r.warm });
  }

  /** A container laid out again from its anchor: a stress layout is relaxed from there, any other is kept and only pushed apart where boxes now overlap. */
  relax(anchor, items, edges) {
    const init = items.map((it) => anchor.pos.get(it.id));
    this.stats.warm++;
    if (anchor.algo === 'stress') { const w = warmStress(items, edges, init); return Object.assign(normalize(items, w.pos), { raw: w.raw }); }
    return normalize(items, removeOverlaps(items, init));
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

  /** The accepted layout becomes the place the containers are laid out again from. */
  setAnchors(layout) {
    for (const [cid, info] of layout.raws) {
      if (!['layered', 'stress'].includes(info.algo)) continue;
      const sig = [...info.pos].map(([id, p]) => id + '@' + p.x + ',' + p.y).join(';');
      const old = this.anchors.get(cid);
      if (old && old.sig === sig && old.algo === info.algo) continue;
      this.anchors.set(cid, { algo: info.algo, pos: info.pos, sig });
    }
  }

  async flat(algo, items, edges, seed) {
    this.stats.elkCalls++;
    const t0 = Date.now();
    const r = await layoutFlat(this.elk, algo, items, edges, seed);
    const dt = Date.now() - t0;
    this.stats.elkMs += dt; { const k = 'phase_' + (this.phase || '-'); this.stats[k] = (this.stats[k] || 0) + dt; const c = 'n' + k; this.stats[c] = (this.stats[c] || 0) + 1; } { const sz = 'size_' + algo + '_' + Math.min(40, 5 * Math.ceil(items.length / 5)); this.stats[sz] = (this.stats[sz] || 0) + dt; const sc = 'n' + sz; this.stats[sc] = (this.stats[sc] || 0) + 1; } this.stats['elkMs_' + algo] = (this.stats['elkMs_' + algo] || 0) + dt;
    return r;
  }
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
export function chooseAlgorithm(kids, edges) {
  if (kids.length <= 1) return 'trivial';
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
