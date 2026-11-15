// A board's layout, given which of its links are pills (cut.mjs's `state.cut`): each container laid out by what its links ask for
// (`chooseAlgorithm`: stars, stars.mjs's, where they have a cycle; else rows, ELK's layered down or across, or a tree; a container
// with no links packed as boxes), frames sized inside out, every shape with the strips of pills it will have about it reserved
// (strips.mjs: the arrangement of them the container's layout chooses, a column on one side only where no strips fit). Every pill is its
// note's own but a spine's. A spine (`findSpines`: cards that don't point at each other and point at many of the same shapes) is laid out
// as one, with no search: two columns of cards facing a column of the pills they share, which are boxes of its own (`spine`), and each
// card's own pills on its outer side, a left card's on its left.
// Every layout aims at a shape: a board at the shape of the view it will be seen in (`view`, the window's, width over height), so that the
// board fills the view when it is fit to it, and a frame at the same, so that a look into it fills the view too. What a container's
// layout costs counts how far off that shape it is (cost.mjs's shapeCost), which is what chooses between arrows running down and across.
// A frame of notes in a container placed as stars is laid out with it (`findFlat`, `separateFlat`): its members are children of that
// container's stars layout, held together, and the frame is the box round them, so an arrow from a shape beside the frame is placed to reach
// its member itself. The cut and the layout see such a frame's links at its members (`chain`); laid out on its own (a redraw in place keeps
// it), it is one box again (`liftedBox`).
import { byTitle } from './util.mjs';
import { holdsShapes } from './model.mjs';
import { layoutFlat, removeOverlaps, normalize, pack, offShapeOf, DEFAULT_VIEW } from './elk.mjs';
import { ownCost, ownCostParts, shapeCost, FILL_WEIGHT } from './cost.mjs';
import { DEFAULT_CONSTANTS, pillKey } from './sizes.mjs';
import { starsLayout, clearSpot, putDown } from './stars.mjs';
import { len, arrowBetween, segHitsBox, segCross } from './geom.mjs';
import { stripAlts, sideBoxes } from './strips.mjs';

// draw's numbers (a pill's height, step and gap, how far `in` puts a shape from a frame's edge, a frame's least size) come from `canvas measure`: sizes.constants
export const PACK_GAP = 64;   // the gap kept between the frames (and loose notes) of a board: ELK's spacing, between draw's tight (40) and normal (80); inside a frame, notes keep 40 x 64
const SEP = '\u0000';
const FREE = '\u0003';        // a shared pill's id among its container's children: this, then its group's key
/** How much wider (or taller) than the shape its container aims at a ranked child's slot may be: a band with little in it would be a strip. */
export const SLOT_MOST = 3;
/** How many rows a spine has at most (two shapes a row): past three it is a strip whatever the view's shape, and a pill all its shapes use
 *  sits beside a middle row that the arrows from the far rows cross other shapes to reach (eight cards: twelve arrows over cards). */
export const SPINE_ROWS = 3;

export class Layouter {
  /**
   * model, board title, sizes (sizesFrom's), an ELK instance. Each container is laid out a container at a time. opts.view is the room the
   * view has for a board fit to it ({w, h}; elk.mjs's DEFAULT_VIEW when it is left out); opts.ranks is which way ranked children run (auto,
   * the default: whichever the view shows larger; rows; columns); opts.spines false lays out no spine.
   */
  constructor(model, board, sizes, opts, elk) {
    this.m = model; this.board = board; this.sizes = sizes; this.opts = Object.assign({}, opts); this.elk = elk;
    if (!this.opts.ranks) this.opts.ranks = 'auto';
    this.k = Object.assign({}, DEFAULT_CONSTANTS, sizes.constants || {});
    const view = this.opts.view;
    this.view = view && view.w > 0 && view.h > 0 ? { w: view.w, h: view.h } : DEFAULT_VIEW;   // the room the view has for a board fit to it
    this.aspect = this.view.w / this.view.h;
    this.cache = new Map();
    this.elkCache = new Map();
    this.way = new Map();       // container id -> rows or columns: which way its ranked children run, once chosen
    this.rootCid = 'b:' + board;
    this.current = null;        // where the drawing's shapes are now (plan.mjs's currentFor): a redraw in place keeps every shape of the file where it is (`frozen`)
    this.fileLines = [];        // the lines the file draws, known by cut.mjs's fileCut: {a, b, seg}
    this.orphans = new Map();   // a shape and a container -> the pills the file has there that no edge of the document makes now (cut.mjs): [{box, taken}]
    this.frozen = false;        // drawing again in place: each container keeps its members' places from the file and puts the others down beside them (keepFrozen)
    this.kept = null;           // the containers that kept their members (a set, while frozen)
    this.person = new Set();    // while frozen: the keys of the shapes a person put where they are (held there), and `holdsPerson` the frames that hold one
    this.holdsPerson = new Set();
    this.why = new Map();       // while frozen: why a shape of the file was put somewhere else: key -> a reason
    this.grown = null;          // while frozen: the frames as the last layout had them (a frame that grew is where a pill put about a note must not go)
    this.again = new Set();     // while frozen: the notes the mend puts down again (their pills' lines were in a conflict that setting the pills again did not clear)
    this.repill = new Set();    // while frozen: the notes whose pills are put about them again (cut.mjs's mend: a line into one of their own pills was in a conflict)
    this.conflicts = [];        // while frozen: a person's shapes left in conflict, said
    this.out = model.edges.filter((e) => model.node(e.from).board === board);
    this.sameBoard = this.out.filter((e) => !e.cross);
    this.leaves = [...model.nodes.values()].filter((n) => n.board === board && !holdsShapes(n));
    this.frameTitles = [...model.nodes.values()].filter((n) => n.board === board && holdsShapes(n)).map((n) => n.key);   // keys (a title, unless more than one node has it)
    this.findSpines(this.opts.spines !== false);
    this.starsAt = new Map();                  // container id -> the middles its stars layout last gave its children, by id
    this.altAt = new Map();                    // container id -> the arrangement of each of its leaves' pills, as stars last had them (strips.mjs)
    this.altOf = new Map();                    // leaf -> the arrangement of its pills, as this layout's containers say
    this.starsKeep = false;                    // while the cut loop runs: a stars container starts from where it was (starsAt)
    this.starsNotes = new Map();               // container id -> the middles of the notes its stars layout last placed, by id
    this.starsRound = 0;
    this.asStars = new Set();                  // containers the cut found stuck in rows (cut.mjs): placed as stars whatever they ask
    this.findFlat(this.opts.flatFrames !== false);
  }

  /**
   * How a container's children are placed: stars where the cut found rows stuck (`asStars`), else its node's `layout.placement`, else the
   * document's, else auto (rows when its links have no cycle, else stars).
   */
  placementOf(cid) {
    if (this.asStars.has(cid)) return 'stars';
    return this.askedPlacement(cid) || 'auto';
  }

  /** The placement the document asks of a container (its node's `layout.placement`, else the document's), or null. */
  askedPlacement(cid) {
    const n = cid === this.rootCid && this.board === 'root' ? null : this.m.node(cid.slice(2));
    return (n && n.placement) || this.m.placement || null;
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
      if (kids.length < 2 || kids.length > 2 * SPINE_ROWS || kids.some((t) => holdsShapes(m.node(t)) || m.node(t).rank != null)) continue;
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

  /**
   * The frames laid out with their container (`flatFrames`; `flatIn`, by container): a frame of two or more notes (no frame, rank or spine in it,
   * no link at the frame itself, rows not asked of it), one of whose members links to a shape beside it (a note of its container), in a
   * container placed as stars by its links (no ranks there, not itself a ranked band, no spine, not a crowd).
   */
  findFlat(on) {
    const { m } = this;
    this.flatFrames = new Set(); this.flatIn = new Map();
    if (!on) return;
    const box = this.lift(this.sameBoard.filter((e) => !this.spineLeaf.has(e.from)).map((e) => ({ from: e.from, to: e.to, weight: e.weight })));
    const atFrame = new Set();
    for (const e of this.sameBoard) for (const t of [e.from, e.to]) if (holdsShapes(m.node(t))) atFrame.add(t);
    const count = new Map();
    for (const f of this.frameTitles) {
      const fid = 'f:' + f, kids = m.kids.get(fid) || [], pid = m.node(f).container, pk = m.kids.get(pid) || [];
      if (kids.length < 2 || kids.some((t) => holdsShapes(m.node(t)) || m.node(t).rank != null) || atFrame.has(f)) continue;
      if (this.spines.has(fid) || this.spines.has(pid) || this.askedPlacement(fid) === 'rows' || this.askedPlacement(pid) === 'rows') continue;
      // ranks there, or a band of ranked children (the overview's layers keep their ranks and spines as they are)
      if (pk.some((t) => m.node(t).rank != null) || (pid[0] === 'f' && m.node(pid.slice(2)).rank != null)) continue;
      if (chooseAlgorithm(pk, box.get(pid) || [], this.placementOf(pid)) !== 'stars') continue;
      // only for a link between a member and a shape beside the frame (a note of its container, in no frame there)
      const mine = new Set(kids), beside = (t) => { const n = m.node(t); return n.container === pid && !holdsShapes(n); };
      if (!this.sameBoard.some((e) => (mine.has(e.from) && beside(e.to)) || (mine.has(e.to) && beside(e.from)))) continue;
      const n = (count.has(pid) ? count.get(pid) : pk.length) - 1 + kids.length;
      if (n > CROWD) continue;
      count.set(pid, n);
      this.flatFrames.add(f);
      if (!this.flatIn.has(pid)) this.flatIn.set(pid, []);
      this.flatIn.get(pid).push(f);
    }
  }

  /** A container's children as the cut sees them: each frame laid out with it in place of its members. */
  cutKids(cid) {
    const own = this.m.kids.get(cid) || [];
    if (!this.flatIn.has(cid)) return own;
    const out = [];
    for (const t of own) { if (this.flatFrames.has(t)) out.push(...(this.m.kids.get('f:' + t) || [])); else out.push(t); }
    return out;
  }

  /** The containers a shape is in, the board's top first: a frame laid out with its container left out, unless `box` (the frame as one box). */
  chain(title, box) {
    const fp = this.free && this.free.get(title);
    if (fp) return fp.container[0] === 'f' ? this.chain(fp.container.slice(2), box).concat([fp.container]) : [this.rootCid];
    const n = this.m.node(title), fr = box || !this.flatFrames || !this.flatFrames.size ? n.frames : n.frames.filter((f) => !this.flatFrames.has(f));
    return [this.rootCid].concat(fr.map((f) => 'f:' + f));
  }

  /** A container's children as its layout lays them out: its own (frames and leaves), then the shared pills that live in it. */
  kidsOf(cid) {
    const own = this.m.kids.get(cid) || [];
    const pills = this.freeIn && this.freeIn.get(cid);
    return pills && pills.length ? own.concat(pills) : own;
  }

  isFree(id) { return !!this.free && this.free.has(id); }

  /** Whether a person put shape `t` where it is: it stays there (a frame that holds such a shape stays too). */
  isPerson(t) { return this.person.has(t); }
  /** Whether a person moved note `t` (its pills, which they didn't move, are put about it again). */
  wasMoved(t) { const c = this.current && this.current.changed.get(t); return !!c && this.person.has(t) && c.has('moved'); }
  /** Whether the pill row `key`, a note `from`'s, is the tool's, now far from a note a person moved: it is put about the note again. */
  stale(from, key) { return !!key && (this.wasMoved(from) || this.repill.has(from) || this.again.has(from)) && !this.current.personPills.has(key) && !(this.sharedRows && this.sharedRows.has(key)); }

  isFrame(id) { return !this.isFree(id) && holdsShapes(this.m.node(id)); }

  /**
   * Which edges are pills and which arrows, and which pills are shared (a spine's). state: {cut, unshared}: a link cut.mjs cut (`from` and `to`, by key)
   * is a pill; an edge between boards is a pill too, and so is every edge of a spine's card (`spined`: what they point at, reached through pills). A
   * group is the edges of one target from one innermost container. Every group but a spine's is one edge, a pill of its own beside its
   * start, in a strip (strips.mjs). In a spine the edges of a group share one pill, a box of the container's layout of its own (`free`:
   * its id `FREE` and the group's key), in the spine's middle column, split by the spine's rows unless every card uses it, every user's
   * line running to it; the edge that makes it in the drawing is the first user's by title. An edge in `unshared` (cut.mjs: one whose line
   * to the shared pill a drawing with no crossing can't keep, or one in a crossing or over a shape) has a pill of its own, as a part with
   * one user does.
   */
  pillPlan(state) {
    const { m } = this;
    const direct = [], pilled = [], groupMap = new Map(), spined = new Set();
    for (const e of this.out) {
      const cut = !!state.cut && state.cut.has(e.from + SEP + e.to);   // cut.mjs: a link the board can't draw with no crossing
      let pill = e.cross || cut;
      if (!pill && !e.direct && this.spineLeaf.has(e.from) && !m.node(e.to).never) { pill = true; spined.add(e.to); }   // a spine's leaf reaches everything through pills
      if (!pill) { direct.push(e); continue; }
      pilled.push(e);
      // a pill of its own: an edge given one (cut.mjs: `unshared`), and every edge but a spine's (share.mjs shares them afterwards)
      // a redraw in place says which edges share a pill the file has (`sharing`: an edge's key -> the first user of the pill), off a spine too
      const ek = e.from + SEP + e.to, tag = !this.spineLeaf.has(e.from) && state.sharing ? state.sharing.get(ek) : undefined;
      const own = (!!state.unshared && state.unshared.has(ek)) || (!this.spineLeaf.has(e.from) && tag === undefined);
      const key = e.to + SEP + m.node(e.from).container + (own ? SEP + e.from : tag !== undefined ? '\u0005' + tag : '');
      let g = groupMap.get(key);
      if (!g) groupMap.set(key, g = { key, target: e.to, container: m.node(e.from).container, edges: [], first: tag });
      g.edges.push(e);
    }
    const byStart = new Map(), members = [], groups = [];
    const add = (start, entry) => { let l = byStart.get(start); if (!l) byStart.set(start, l = []); l.push(entry); };
    const all = [...groupMap.values()].sort((a, b) => byTitle(a.key, b.key));
    // a pill two or more users share is an item of its container's layout, `pill` its id there, placed among its users: its host is only the
    // user whose edge makes it in the script (the first by title), and every user's arrow runs to it, the host's too
    const free = [];
    for (const g of all) {
      g.edges.sort((a, b) => (a.from === g.first ? -1 : b.from === g.first ? 1 : 0) || byTitle(a.from, b.from));   // a pill the file has is the maker's it had
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
          const q = { key: parts.length > 1 ? g.key + '\u0002r' + i : g.key, target: g.target, container: g.container, edges, froms: edges.map((e) => e.from), shared: edges.length >= 2 };
          groups.push(q);
          // one user: its own
          if (!q.shared) { for (const e of edges) add(e.from, { e, users: 1, shared: false }); return; }
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
      g.free = true; g.host = g.froms[0]; g.pill = FREE + g.key;
      for (const e of g.edges) {
        if (e.from === g.host) free.push({ e, key: g.key, pill: g.pill, users: g.edges.length });
        else members.push({ e, host: g.host, key: g.key, free: true });
      }
    }
    const bi = (e) => m.boardIndex.get(m.node(e.to).board);
    for (const l of byStart.values()) l.sort((a, b) => (b.shared ? 1 : 0) - (a.shared ? 1 : 0) || bi(a.e) - bi(b.e) || byTitle(a.e.to, b.e.to));   // a column: the pills that others share first, so that they are the first made
    // what the layout is to keep near: the plain arrows, and each user of a shared pill near the pill
    const layoutEdges = direct.map((e) => ({ from: e.from, to: e.to, weight: e.weight }))
      .concat(members.map((x) => ({ from: x.e.from, to: FREE + x.key, weight: x.e.weight })))
      .concat(free.map((f) => ({ from: f.e.from, to: f.pill, weight: f.e.weight })));
    return { byStart, direct, pilled, members, free, groups, layoutEdges, spined: [...spined].sort(byTitle) };
  }

  /** How wide a pill for `target` is beside a start in container `cid`: as measured from there (a pill that says where its shape is), else anywhere. */
  pillW(target, cid) { const w = this.sizes.pillWidth; return w[pillKey(target, cid)] || w[target] || 120; }

  /** A leaf with its pills: the arrangements of them it may take (strips.mjs's), and the one it takes with nothing else to say (`first`). */
  unit(title, pills) {
    const s = this.sizes.shapes[title];
    if (!s) throw new Error(`no size for "${title}"`);
    const k = pills ? pills.length : 0;
    // a copy: what strips.mjs keeps for the next leaf of these sizes isn't this one's to change
    const alts = stripAlts({ w: s.w, h: s.h, above: s.above || 0 }, (pills || []).map((x) => ({ w: this.pillW(x.e.to, this.m.node(x.e.from).container) })), this.k).slice();
    // what it takes with nothing else to say: a column on its right; a spine's left leaf's on its left (its edges leave from its left)
    let first = k ? alts.findIndex((a) => a && a.side === (this.leftSide.has(title) ? 'column left' : 'column right')) : 0;
    if (first < 0) first = Math.max(0, alts.findIndex(Boolean));
    // strips, never a column, where any strips hold its pills: the smallest of them first
    // a spine's leaf: the strips that keep its inner side (the spine's) clear, the smallest
    const inner = this.spineLeaf.has(title) ? (this.leftSide.has(title) ? 'right' : 'left') : null;
    const outer = inner === 'right' ? 'left' : 'right';
    const strip = (a) => a && !/^column/.test(a.side);
    const onlyOuter = (a) => strip(a) && (a.on || []).every((sd) => sd === outer), notInner = (a) => strip(a) && !(a.on || []).includes(inner);
    const fits = !inner ? strip : alts.some(onlyOuter) ? onlyOuter : notInner;
    if (k && alts.some(fits)) {
      for (let i = 0; i < alts.length; i++) if (alts[i] && /^column/.test(alts[i].side)) alts[i] = null;
      first = -1;
      alts.forEach((a, i) => { if (fits(a) && (first < 0 || a.w * a.h < alts[first].w * alts[first].h)) first = i; });
      if (inner) for (let i = 0; i < alts.length; i++) if (i !== first) alts[i] = null;
    }
    return { k, alts, first, noteW: alts[first].nw, noteH: alts[first].nh };
  }

  /**
   * Where the drawing has the pill `host`'s edge to `target` makes now ({x, y, w, h}, the board's coordinates), or null: canvas apply keeps a
   * pill under its maker's edge's key (`pill <key>`), the document's own key, else its ends (`<from> -> <to>`, with what tells a pair's edges
   * apart after it, or a count).
   */
  currentPill(host, target, cid) {
    const key = this.currentPillRow(host, target, cid);
    return key ? this.current.at.get(key) : null;
  }

  /** The key of the row of the pill `currentPill` finds, or null. */
  currentPillRow(host, target, cid) {
    const cur = this.current;
    if (!cur) return null;
    const e = this.out.find((x) => x.from === host && x.to === target);
    const base = 'pill ' + host + ' -> ' + target;
    let key = ((e && e.keys) || []).map((k) => k && 'pill ' + k).find((k) => k && cur.at.has(k)) || (cur.at.has(base) ? base : null);
    if (!key) {
      // a pair's second edge is kept under the pair's name and what tells it apart after it: the first row that begins so (indexed by each beginning that ends before a space)
      if (!cur.byBase) {
        cur.byBase = new Map();
        for (const k of cur.at.keys()) {
          if (!k.startsWith('pill ')) continue;
          for (let at = k.indexOf(' ', 5); at > 0; at = k.indexOf(' ', at + 1)) { const head = k.slice(0, at); if (!cur.byBase.has(head)) cur.byBase.set(head, k); }
        }
      }
      key = cur.byBase.get(base) || null;
    }
    if (!key) return null;
    // where the pill is now must be the container it goes in: its frame, else the board's top (the shape whose board it is on; none for the root)
    const want = cid[0] === 'f' || cid !== 'b:root' ? cid.slice(2) : null, has = cur.pillIn ? cur.pillIn.get(key) : undefined;
    return has === undefined || (has || null) === want ? key : null;
  }

  /**
   * `items` with each leaf in the smallest arrangement of its pills that holds them on the sides `allowed` alone (else as it is): what a
   * container whose arrows run one way gives its leaves, their pills on the sides the arrows don't run to.
   */
  sidedItems(items, allowed) {
    return items.map((it) => {
      if (!it.alts) return it;
      let best = -1;
      it.alts.forEach((a, k) => { if (a && (a.on || []).every((s) => allowed.includes(s)) && (best < 0 || a.w * a.h < it.alts[best].w * it.alts[best].h)) best = k; });
      if (best < 0 || best === it.alt) return it;
      const a = it.alts[best];
      return Object.assign({}, it, { w: a.w, h: a.h, nw: a.nw, nh: a.nh, nx: a.nx, ny: a.ny, strips: a.strips, alt: best });
    });
  }

  /** The arrangement a leaf's pills take: the one its container's layout chose last, else its first. */
  altFor(t, u) {
    const a = this.altOf && this.altOf.has(t) ? this.altOf.get(t) : u.first;
    return a < u.alts.length && u.alts[a] ? a : u.first;
  }

  /** The edges, lifted to the lowest container that holds both ends, between that container's children. n counts the arrows, np those of them that run to a pill beside the shape itself. */
  lift(edges, box) {
    const lifted = new Map();
    for (const e of edges) {
      const ca = this.chain(e.from, box), cb = this.chain(e.to, box);
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
    this.round = (this.round || 0) + 1;   // each layout takes the file's orphan pills afresh (currentGroupPill)
    this.conflicts = [];
    this.excusedPairs = new Set();   // the pairs of children a stars container's placement could not draw clean (stars.mjs)
    const plan = this.pillPlan(state);
    this.unshared = state.unshared;
    // the shared pills, each an item of its container's layout
    this.free = new Map(); this.freeIn = new Map();
    for (const g of plan.groups) {
      if (!g.free) continue;
      this.free.set(g.pill, { container: g.container, target: g.target, host: g.host, users: g.edges.length, froms: g.froms, key: g.key, group: g.key, w: this.pillW(g.target, g.container) });
      let l = this.freeIn.get(g.container); if (!l) this.freeIn.set(g.container, l = []); l.push(g.pill);
    }
    for (const l of this.freeIn.values()) l.sort();
    const units = new Map();
    // each leaf's pills as its container's last stars layout arranged them (a container laid out again now chooses again)
    this.altOf = new Map();
    for (const alts of this.altAt.values()) for (const [id, a] of alts) this.altOf.set(id, a);
    for (const n of this.leaves) {
      // drawing again in place: a note whose pills the file has all of is in the arrangement the file has them in, and takes no other
      const f = this.frozen ? this.fileUnit(n.key, plan) : null;
      let u;
      if (f && f.alt) { u = { k: (plan.byStart.get(n.key) || []).length, alts: [f.alt], first: 0, noteW: f.alt.nw, noteH: f.alt.nh, file: 0 }; this.altOf.set(n.key, 0); }
      else u = this.unit(n.key, plan.byStart.get(n.key));
      if (f) { u.resized = f.resized; u.pillsNew = f.pillsNew; }
      units.set(n.key, u);
    }
    const lifted = this.lift(plan.layoutEdges);
    // every link on the board, drawn or a pill, between the children of the container that holds both ends: what places a stars container (but
    // a spine's)
    const links = this.sameBoard.filter((e) => !this.spineLeaf.has(e.from)).map((e) => ({ from: e.from, to: e.to, weight: e.weight }));
    this.affinity = this.lift(links);
    const arrows = this.lift(plan.direct.map((e) => ({ from: e.from, to: e.to, weight: e.weight })));
    // the same with every frame one box: what a frame laid out on its own, and a container that keeps its frames where they are, go by
    const flat = this.flatFrames.size > 0;
    this.liftedBox = flat ? this.lift(plan.layoutEdges, true) : lifted;
    this.affinityBox = flat ? this.lift(links, true) : this.affinity;
    const arrowsBox = flat ? this.lift(plan.direct.map((e) => ({ from: e.from, to: e.to, weight: e.weight })), true) : arrows;
    // how each container is placed goes by every link among its children, drawn or a pill, so cutting one never turns stars into rows; a
    // container with no arrow left among its children is packed as boxes; one that lays its frames out with it is stars
    const algos = new Map(), info = new Map();
    this.algosBox = new Map();
    for (const cid of [this.rootCid].concat(this.frameTitles.map((f) => 'f:' + f))) {
      // by its links alone, not the lines into a spine's shared pills
      const kids = this.m.kids.get(cid) || [];
      const drawn = (arrows.get(cid) || []).length > 0, drawnBox = (arrowsBox.get(cid) || []).length > 0;
      algos.set(cid, this.flatIn.has(cid) ? 'stars' : chooseAlgorithm(kids, drawn ? this.affinity.get(cid) || [] : [], this.placementOf(cid)));
      this.algosBox.set(cid, chooseAlgorithm(kids, drawnBox ? this.affinityBox.get(cid) || [] : [], this.placementOf(cid)));
    }
    if (this.starsKeep) this.starsRound++;
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
          pills.push({ start: fp.host, target: fp.target, users: fp.users, shared: true, free: true, group: fp.group, x, y, w: fp.w, h: this.k.pillHeight });
          continue;
        }
        if (holdsShapes(this.m.node(t))) { const r = res.get('f:' + t); frames.set(t, { x, y, w: r.w, h: r.h }); walk('f:' + t, x, y); continue; }
        const u = units.get(t), a = u.alts[this.altFor(t, u)];   // a stars layout may arrange the pills otherwise
        boxes.set(t, { x: x + a.nx, y: y + a.ny, w: a.nw, h: a.nh });
        (plan.byStart.get(t) || []).forEach((en, i) => {
          pillAt.set(t + SEP + en.e.to, pills.length);
          const p = a.pills[i];
          pills.push({ start: t, target: en.e.to, users: en.users, shared: en.shared, left: p.x + p.w <= a.nx, x: x + p.x, y: y + p.y, w: p.w, h: p.h });
        });
      }
    };
    walk(this.rootCid, 0, 0);
    for (const x of plan.members) x.pill = x.free ? freeAt.get(x.key) : pillAt.get(x.host + SEP + x.e.to);
    for (const f of plan.free) f.at = freeAt.get(f.key);
    const root = res.get(this.rootCid);
    if (this.frozen) this.exact(boxes, frames, pills);
    const layout = { board: this.board, boxes, frames, pills, w: root.w, h: root.h, algos, plan, ms: Date.now() - t0 };
    layout.shape = this.shapeOf(this.rootCid, this.aspect);
    layout.containers = [...info].map(([cid, i]) => Object.assign({ cid, container: cid.slice(2) || null }, i, { w: res.get(cid).w, h: res.get(cid).h }));
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
  freeItem(t) { return { id: t, w: this.free.get(t).w, h: this.k.pillHeight, satellite: true }; }

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

  /**
   * A leaf as its container lays it out: its box in the arrangement of its pills it takes, and, when it has pills, where its note is in the
   * box and the boxes its strips take (ownCostParts), with every arrangement it may take (`alts`, stars' choice) and which it takes now (`alt`).
   */
  leafItem(t, units) {
    const u = units.get(t);
    const above = Math.max(0, (this.sizes.shapes[t].above || 0) - (u.k ? u.alts[this.altFor(t, u)].ny : 0));   // its title's room over its box
    const titleAbove = this.sizes.shapes[t].above || 0;
    if (!u.k) return { id: t, w: u.alts[u.first].w, h: u.alts[u.first].h, above, titleAbove };
    const n = this.altFor(t, u), a = u.alts[n];
    return { id: t, w: a.w, h: a.h, nw: a.nw, nh: a.nh, nx: a.nx, ny: a.ny, strips: a.strips, alts: u.alts, alt: n, above, titleAbove };
  }

  /**
   * Where the drawing has the pill that stands for a group of edges now ({x, y, w, h}), or null: the pill of any of them (a shared pill is the
   * first user's by title, which the file may have made another's), else one the file has there that no edge makes now (its maker's note was
   * taken out of the document, and the group that shared it keeps it), the nearest to the users, each taken once in a layout.
   */
  currentGroupPill(froms, target, cid, claim) {
    for (const f of froms) { const b = this.currentPill(f, target, cid); if (b) return b; }
    const list = claim ? this.orphans.get(target + SEP + cid) : null;
    if (!list) return null;
    const mine = froms.map((f) => this.current.at.get(f)).filter(Boolean);
    let best = null, bd = Infinity;
    for (const o of list) {
      if (o.taken === this.round) continue;
      const d = mine.length ? Math.min(...mine.map((c) => len(o.box.x - c.x - c.w / 2, o.box.y - c.y - c.h / 2))) : 0;
      if (d < bd - 1e-9) { best = o; bd = d; }
    }
    if (best) best.taken = this.round;
    return best ? best.box : null;
  }

  /**
   * Drawing again in place: what the file says of a note's arrangement. {resized, pillsNew, alt}: `alt` is the arrangement the file has its pills in, as
   * an arrangement of its own (`side: 'file'`), its note and each pill exactly where they are, for a note whose pills the file has all of, or where
   * the pills it lacks (a link that is new, or one the cut made a pill) fit beside those it has (`addPills`); none for a note that is longer or
   * taller, or whose new pills have no room, which takes its arrangements as any note does. A pill the file has under its note or on another
   * shape (a note moved onto it) is placed again as a new one is. Null for a note the file does not hold in its container.
   * A note a person put where it is is at the size they gave it, and where they moved it its pills (which they didn't move) are put about it again,
   * in the arrangement of strips that is clear of everything the file has, else beside it as a new pill goes; none clear: the first arrangement, and the conflict said.
   */
  fileUnit(t, plan) {
    const cur = this.current, n = this.m.node(t), c = cur.at.get(t), held = cur.members.get(n.container);
    if (!c || !held || !held.has(t)) return null;
    // a note a person resized has the size they gave it; one they only moved has the size its text has now (longer text grows it where it stands, and what it covers is put down)
    const person = this.isPerson(t), z = this.sizes.shapes[t], entries = plan.byStart.get(t) || [];
    const sized = person && !!this.current.changed.get(t) && this.current.changed.get(t).has('resized');
    const nw = sized ? c.w : Math.ceil(z.w), nh = sized ? c.h : Math.ceil(z.h);
    const out = { resized: !person && (Math.abs(c.w - nw) > 0.5 || Math.abs(c.h - nh) > 0.5), pillsNew: false, alt: null };
    if (this.again.has(t) && !person) { out.resized = true; return out; }
    if (!entries.length) return out;
    // a pill the mend gave a note of its own that the file has shared is not that pill's place: the others keep it
    const gave = (en, key) => this.sharedRows && this.sharedRows.has(key) && this.unshared && this.unshared.has(en.e.from + SEP + en.e.to);
    const rows = entries.map((en) => { const key = this.currentPillRow(t, en.e.to, n.container); return key && !this.stale(t, key) && !gave(en, key) ? cur.at.get(key) : null; });
    const above = z.above || 0, N = { x: c.x, y: c.y, w: nw, h: nh };
    const ps = entries.map((en, i) => ({ x: rows[i] ? rows[i].x : null, y: rows[i] ? rows[i].y : null, w: this.pillW(en.e.to, n.container), h: this.k.pillHeight }));
    const solids = this.fileSolids(), under = { x: N.x, y: N.y - above, w: N.w, h: N.h + above };
    const on = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
    ps.forEach((q) => {
      if (q.x == null) return;
      if (on(q, under) || solids.some((o) => !o.frame && o.id !== t && !(o.pill && o.id === t) && on(q, o.box) && !on(under, o.box) && !(o.box.x === q.x && o.box.y === q.y && o.box.w === q.w))) { q.x = null; q.y = null; }
    });
    const fresh = ps.map((q) => q.x == null);
    out.pillsNew = fresh.some(Boolean);
    if (out.pillsNew && person) {
      if (!this.armPills(t, N, above, ps) && !this.addPills(t, N, above, ps)) this.armPills(t, N, above, ps, true);
    } else if (out.resized || (out.pillsNew && !this.addPills(t, N, above, ps))) return out;
    if (out.resized) return out;
    // the pills set about the note now are the file's from here on: another note's new pills keep off them and their lines
    ps.forEach((q, i) => {
      if (!fresh[i] || q.x == null) return;
      solids.push({ id: t, pill: true, box: { x: q.x, y: q.y, w: q.w, h: q.h } });
      this.fileLines.push({ a: t, b: t, pill: true, seg: arrowBetween({ x: N.x, y: N.y, w: N.w, h: N.h }, { x: q.x, y: q.y, w: q.w, h: q.h }) });
    });
    let x0 = N.x, y0 = N.y - above, x1 = N.x + N.w, y1 = N.y + N.h;
    for (const p of ps) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x + p.w); y1 = Math.max(y1, p.y + p.h); }
    const rel = (b) => ({ x: b.x - x0, y: b.y - y0, w: b.w, h: b.h });
    const sb = sideBoxes(ps.map(rel), rel(N));
    out.alt = { w: x1 - x0, h: y1 - y0, nx: N.x - x0, ny: N.y - y0, nw: N.w, nh: N.h, pills: ps.map(rel), strips: sb.map((b) => b.box), on: sb.map((b) => b.side), side: 'file', own: 0 };
    out.pillsNew = false;
    return out;
  }

  /**
   * The boxes the file has on the board that a note's new pill keeps off: every note and frame with its title's room, every pill of another
   * note, by the note's id (null for a frame: it is no obstacle but as a container, which a pill stays inside). A pill the tool put about a note
   * a person moved is no obstacle (it is put about that note again).
   */
  fileSolids() {
    if (this.solidsRound === this.round) return this.solids;
    const cur = this.current, out = [];
    for (const n of this.m.nodes.values()) {
      const c = n.board === this.board ? cur.at.get(n.key) : null;
      if (!c) continue;
      const z = holdsShapes(n) ? this.sizes.frames && this.sizes.frames[n.key] : this.sizes.shapes[n.key], above = (z && z.above) || 0;
      const g = holdsShapes(n) && this.grown ? this.grown.get(n.key) : null;
      if (g) out.push({ id: n.key, frame: true, box: g, tab: above ? { x: g.x, y: g.y - above, w: g.w, h: above } : null });
      else if (holdsShapes(n)) out.push({ id: n.key, frame: true, box: c, tab: above ? { x: c.x, y: c.y - above, w: c.w, h: above } : null });
      else out.push({ id: n.key, box: { x: c.x, y: c.y - above, w: c.w, h: c.h + above } });
    }
    for (const e of this.out) {
      const key = this.currentPillRow(e.from, e.to, this.m.node(e.from).container), b = key ? cur.at.get(key) : null;
      if (b && !this.stale(e.from, key)) out.push({ id: e.from, pill: true, box: { x: b.x, y: b.y, w: this.pillW(e.to, this.m.node(e.from).container), h: this.k.pillHeight } });
    }
    this.solids = out; this.solidsRound = this.round;
    return out;
  }

  /** Whether a pill at `box` of note `t` (at `N`, its title's room `above` it) is clear of what the file has: `others`, the note's other pills, and `ctx` (addPills'). */
  pillFits(t, N, above, box, others, ctx) {
    const G = 6, hit = (a, b, g) => a.x < b.x + b.w + g && b.x < a.x + a.w + g && a.y < b.y + b.h + g && b.y < a.y + a.h + g;
    if (hit(box, ctx.noteBox, G) || others.some((p) => hit(box, p, G))) return false;
    const frame = ctx.frame;
    if (frame && !(box.x >= frame.x + G && box.y >= frame.y + G && box.x + box.w <= frame.x + frame.w - G && box.y + box.h <= frame.y + frame.h - G)) return false;
    if (ctx.solids.some((o) => !(o.id === t && !o.pill) && !o.frame && hit(box, o.box, G))) return false;
    if (ctx.solids.some((o) => o.frame && !ctx.holders.has(o.id) && hit(box, o.box, G))) return false;   // a frame that holds not the note
    if (ctx.solids.some((o) => o.frame && o.tab && hit(box, o.tab, G))) return false;
    const line = arrowBetween({ x: N.x, y: N.y, w: N.w, h: N.h }, box);
    if (others.some((p) => segHitsBox(line, p, -8))) return false;
    // no other note's line runs over it or across the line to it
    return !this.fileLines.some((l) => !(l.pill && l.a === t) && !ctx.covered.has(l.a) && !ctx.covered.has(l.b) && (segHitsBox(l.seg, box, -8) || (l.a !== t && l.b !== t && segCross(line, l.seg))));
  }

  /** What `pillFits` is asked with for note `t`: its frame, the frames that hold it, the file's boxes (for a note a person put where it is, but those its own box covers, which are put down again), its note and title's room. */
  pillContext(t, N, above) {
    const frame = this.m.node(t).container[0] === 'f' ? this.current.at.get(this.m.node(t).container.slice(2)) : null;
    const noteBox = { x: N.x, y: N.y - above, w: N.w, h: N.h + above };
    const hits = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
    const all = this.fileSolids();
    // a person's note lies on others: they are put down again, each with its pills and the lines to them, so none of those is in the way of the pills set about the note
    const covered = new Set(this.isPerson(t) ? all.filter((o) => !o.pill && !o.frame && o.id !== t && hits(o.box, noteBox)).map((o) => o.id) : []);
    const solids = all.filter((o) => !covered.has(o.id) && (!this.isPerson(t) || o.id === t || o.frame || !hits(o.box, noteBox)));
    return { frame, noteBox, solids, holders: new Set(this.m.node(t).frames), covered };
  }

  /**
   * The pills of note `t` that the file has no place for (`ps` entries with no x), each put in the nearest spot to the note beside the pills it has
   * or about it, clear of every note, title and pill the file has and of the note's own, inside its frame, with the line from the note to it
   * over none of the note's other pills: true when each has one.
   */
  addPills(t, N, above, ps) {
    const ctx = this.pillContext(t, N, above), gap = this.k.pillStep, mine = (p) => (p.x != null ? [p] : []);
    const middle = [N.x + N.w / 2, N.y + N.h / 2];
    for (const q of ps) {
      if (q.x != null) continue;
      const placed = ps.filter((p) => p !== q).flatMap(mine);
      const cands = [];
      for (const p of placed) for (const [dx, dy] of [[p.w + gap, 0], [-q.w - gap, 0], [0, p.h + gap], [0, -q.h - gap]]) cands.push({ x: p.x + dx, y: p.y + dy });
      for (const d of [24, 40, 64, 96, 144]) {
        for (const x of [N.x, N.x + N.w - q.w, N.x + (N.w - q.w) / 2]) { cands.push({ x, y: N.y + N.h + d }); cands.push({ x, y: N.y - above - d - q.h }); }
        for (const y of [N.y, N.y + N.h - q.h, N.y + (N.h - q.h) / 2]) { cands.push({ x: N.x + N.w + d, y }); cands.push({ x: N.x - d - q.w, y }); }
      }
      const away = (c) => len(c.x + q.w / 2 - middle[0], c.y + q.h / 2 - middle[1]);
      cands.sort((a, b) => away(a) - away(b) || a.y - b.y || a.x - b.x);
      let got = null;
      for (const c of cands) {
        const box = { x: c.x, y: c.y, w: q.w, h: q.h };
        if (this.pillFits(t, N, above, box, placed, ctx)) { got = box; break; }
      }
      if (!got) return false;
      q.x = got.x; q.y = got.y;
    }
    return true;
  }

  /**
   * All the pills of note `t` (a person's, put where they put it) set in one of the arrangements of strips a note may take, the smallest that is clear
   * of what the file has: true when one is; `force`: the smallest whether it is clear or not (the conflict is said).
   */
  armPills(t, N, above, ps, force) {
    const ctx = this.pillContext(t, N, above);
    const all = stripAlts({ w: N.w, h: N.h, above }, ps.map((q) => ({ w: q.w })), this.k);
    const alts = all.map((a, k) => [a, k]).filter(([a]) => a && !/^column/.test(a.side)).sort((p, q) => p[0].w * p[0].h - q[0].w * q[0].h || p[1] - q[1]);
    const colAlts = all.filter((a) => a);
    const boxes = (a) => a.pills.map((p) => ({ x: N.x - a.nx + p.x, y: N.y - a.ny + p.y, w: p.w, h: p.h }));
    let pick = null;
    for (const [a] of alts.concat(colAlts.filter((a) => /^column/.test(a.side)).map((a) => [a, 0]))) {
      const bs = boxes(a);
      if (bs.every((b, i) => this.pillFits(t, N, above, b, bs.filter((_, j) => j !== i), ctx))) { pick = bs; break; }
    }
    if (!pick && force && colAlts.length) {
      this.conflicts.push(t);
      pick = boxes(alts.length ? alts[0][0] : colAlts[0]);
    }
    if (!pick) return false;
    ps.forEach((q, i) => { q.x = pick[i].x; q.y = pick[i].y; });
    return true;
  }

  /** Where the file has the pill `p` of a layout (layout.pills' entry) now ({x, y, w, h}), or null: its own, or the pill that stands for the group of notes that share it. */
  filePill(p) {
    if (!this.current) return null;
    if (!p.free) return this.currentPill(p.start, p.target, this.m.node(p.start).container);
    const group = [...this.free.values()].find((f) => f.group === p.group);
    return group ? this.currentGroupPill(group.froms, p.target, group.container) : null;
  }

  /** The layout's boxes and pills where they are the file's to a rounding error, exactly the file's (a sum and its difference is not always the number it began as). */
  exact(boxes, frames, pills) {
    const cur = this.current, near = (a, b) => Math.abs(a - b) < 1e-6;
    for (const [t, b] of [...boxes, ...frames]) {
      const c = cur.at.get(t);
      if (c && near(b.x, c.x) && near(b.y, c.y)) { b.x = c.x; b.y = c.y; if (near(b.w, c.w) && near(b.h, c.h)) { b.w = c.w; b.h = c.h; } }
    }
    for (const p of pills) {
      const group = p.free ? [...this.free.values()].find((f) => f.group === p.group) : null;
      const b = p.free ? (group ? this.currentGroupPill(group.froms, p.target, group.container) : null) : this.currentPill(p.start, p.target, this.m.node(p.start).container);
      if (b && near(p.x, b.x) && near(p.y, b.y)) { p.x = b.x; p.y = b.y; }
    }
  }

  /**
   * Drawing again in place: a container with members the file holds keeps each where the file has it (the row's box, made relative to the
   * container's top-left; a frame at its current place and at least its current size), and what the file lacks is put down beside them: a
   * member new to the container (or moved to it), a note that is longer, a note with a pill the file lacks, a frame that grew, each at the nearest
   * free spot by its links (stars.mjs's putDown: nothing held moves). A note whose pills grew takes another arrangement of them where it stands
   * if one is clear; a frame's members stay inside it, and it grows only where nothing beside it is, else as little as it must, over the shapes the tool
   * put beside it (which are put down again). A shape a person put where they are (`fixed`: it, and the frames that hold one) is never moved, flexed or
   * put down: what it covers is put down again, a frame grows left or up to hold it. False (the container is laid out afresh, as any is) where the file
   * holds none of its members. Not kept: a thing put on another's title or pill with no person's change to say whose (`changed` not given), which the
   * board's check then says (cut.mjs lays the board out afresh when no cut mends it).
   */
  async keepFrozen(cid, units, lifted, algos, res, info, target, slot) {
    const cur = this.current, m = this.m, kids = this.kidsOf(cid);
    if (!kids.length) return false;
    const holder = cid.slice(2), isFrame = cid[0] === 'f', pad = isFrame ? this.k.frameInset : 0;
    const held = cur.members.get(cid) || new Set();
    // ranked children are rows or columns by their ranks: kept where they are when the file has them running the way --ranks says (the way the
    // view shows larger, where it says none), else laid out by their ranks, which turns them; what each holds is kept
    if (kids.some((t) => !this.isFree(t) && m.node(t).rank != null) && !kids.some((t) => this.isPerson(t) || this.holdsPerson.has(t))) {
      const way = this.rankedWay(kids, held, cur);
      if (way && way !== 'any' && this.opts.ranks !== 'auto' && way !== this.opts.ranks) return false;   // turned only where the file's way is plain and is not the one asked for
    }
    const origin = isFrame ? cur.at.get(holder) : { x: 0, y: 0 };
    if (!origin || !kids.some((t) => !this.isFree(t) && held.has(t) && cur.at.has(t))) return false;
    const items = [], pos = [], flex = [], grew = new Set(), fixed = new Set(), own = new Set();   // `fixed`: items a person put where they are, and frames that hold one; `own`: the person's own
    const shared = [];   // the shared pills the file has no place for
    for (const t of kids) {
      const i = items.length;
      if (this.isFree(t)) {
        const fp = this.free.get(t), box = this.currentGroupPill(fp.froms, fp.target, cid, true);
        items.push(this.freeItem(t));
        if (box) pos.push({ x: box.x - origin.x, y: box.y - origin.y }); else { pos.push(null); shared.push(i); }
        continue;
      }
      const c = held.has(t) ? cur.at.get(t) : null, rel = c ? { x: c.x - origin.x, y: c.y - origin.y } : null;
      if (holdsShapes(m.node(t))) {
        await this.separate('f:' + t, units, lifted, algos, res, info, this.aspect);
        const r = res.get('f:' + t);
        const mine = this.isPerson(t);
        if (c && r.shift) { rel.x += r.shift.x; rel.y += r.shift.y; r.w -= r.shift.x; r.h -= r.shift.y; }   // it grew to the left or up, to hold what a person put there
        if (c) {
          if (r.w > c.w + 0.5 || r.h > c.h + 0.5) { flex.push(i); grew.add(i); }
          r.w = mine ? c.w : Math.max(r.w, c.w); r.h = mine ? c.h : Math.max(r.h, c.h);   // the size a person gave a frame is the one it has
          if (mine || this.holdsPerson.has(t)) fixed.add(i);
          if (mine) own.add(i);
        }
        items.push({ id: t, w: r.w, h: r.h, titleAbove: ((this.sizes.frames && this.sizes.frames[t]) || {}).above || 0 });
        pos.push(rel);
        continue;
      }
      const it = this.leafItem(t, units), u = units.get(t);
      items.push(it);
      pos.push(rel ? { x: rel.x - (it.nx || 0), y: rel.y - (it.ny || 0) } : null);
      if (c && this.isPerson(t)) { fixed.add(i); own.add(i); }
      else if (c && (u.resized || u.pillsNew)) { flex.push(i); if (u.resized) grew.add(i); }
    }
    const was = pos.map((p) => (p ? { x: p.x, y: p.y } : null));   // where the file has each, before anything is put down
    // the kept ones each where they are, the rest put down beside them
    const index = new Map(items.map((it, i) => [it.id, i]));
    const edgesOf = (lists) => (lists.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w, n: e.n, np: e.np })).filter((e) => e.a != null && e.b != null && e.a !== e.b);
    const edges = edgesOf(this.liftedBox), affinity = edgesOf(this.affinityBox);
    const down = items.map((it, i) => i).filter((i) => !pos[i] && !shared.includes(i));
    if (down.length || flex.length || fixed.size) {
      const mid = (it, p) => [p.x + (it.nx || 0) + (it.nw != null ? it.nw : it.w) / 2, p.y + (it.ny || 0) + (it.nh != null ? it.nh : it.h) / 2];
      const init = items.map((it, i) => (pos[i] && !shared.includes(i) ? { c: mid(it, pos[i]), alt: it.alts ? it.alt : 0 } : null));
      const grow = isFrame ? { w: cur.at.get(holder).w, h: cur.at.get(holder).h, pad, above: ((this.sizes.frames && this.sizes.frames[holder]) || {}).above || 0, avoid: this.besideFrame(holder, origin) } : null;
      const note = { covered: new Set(), reached: new Set(), fellBack: false };
      const weight = items.map((it) => (holdsShapes(m.node(it.id) || {}) ? 1 + [...m.nodes.values()].filter((n) => n.frames.includes(it.id)).length : 1));
      let got = putDown(items, edges, init, { affinity, flex, grew, weight, bounds: isFrame ? { x: pad, y: pad } : null, grow, fixed, own, note });
      // a frame with no room for what is put down in it grows as little as it must, over the shapes the tool put beside it (put down again below), not a person's
      if (isFrame && note.fellBack) {
        const again = { covered: new Set(), reached: new Set(), fellBack: false };
        got = putDown(items, edges, init, { affinity, flex, grew, weight, bounds: { x: pad, y: pad }, grow: Object.assign({}, grow, { avoid: this.besideFrame(holder, origin, true) }), fixed, own, note: again });
        note.covered = again.covered; note.reached = again.reached;
      }
      const moved = new Set();
      items.forEach((it, i) => {
        if (shared.includes(i) || fixed.has(i)) return;
        const away = !pos[i] || Math.abs(pos[i].x - got[i].x) > 0.5 || Math.abs(pos[i].y - got[i].y) > 0.5;
        if (init[i] && !flex.includes(i) && !away) return;
        if (it.alts && got[i].alt !== it.alt) { this.altOf.set(it.id, got[i].alt); items[i] = this.leafItem(it.id, units); }
        if (away) {
          moved.add(it.id);
          const u = units.get(it.id), file = cur.at.has(it.id);
          this.why.set(it.id, !file || !held.has(it.id) ? 'new' : note.covered.has(i) ? 'a person\'s shape covered it' : note.reached.has(i) ? 'a frame grew' : this.again.has(it.id) ? 'put down again to clear a line' : u && u.resized ? 'longer' : u && u.pillsNew ? 'new pills' : grew.has(i) ? 'a frame grew' : 'put down again');
        }
        pos[i] = { x: got[i].x, y: got[i].y };
      });
      // a pill that notes share goes with them when one of them moved, or when it is on another shape now (the put-down saw it as held)
      if (moved.size) {
        const parts = (it, p) => { const a = it.alts ? it.alts[it.alt] : null, ta = it.titleAbove || 0; return a ? [{ x: p.x + a.nx, y: p.y + a.ny - ta, w: a.nw, h: a.nh + ta }].concat(a.pills.map((q) => ({ x: p.x + q.x, y: p.y + q.y, w: q.w, h: q.h }))) : [{ x: p.x, y: p.y - ta, w: it.w, h: it.h + ta }]; };
        const on = (A, B) => A.x < B.x + B.w && B.x < A.x + A.w && A.y < B.y + B.h && B.y < A.y + A.h;
        items.forEach((it, i) => {
          if (!this.isFree(it.id) || shared.includes(i)) return;
          const fp = this.free.get(it.id);
          const away = fp.froms.some((u) => moved.has(u)) || items.some((o, j) => j !== i && !this.isFree(o.id) && moved.has(o.id) && parts(o, pos[j]).some((B) => parts(it, pos[i]).some((A) => on(A, B))));
          if (away) { pos[i] = null; shared.push(i); }
        });
      }
    }
    // the shared pills the file has no place for: the clear spot nearest the middle of their users
    if (shared.length) {
      const at = new Map(items.map((it, i) => [it.id, i])), placed = pos.map((p, i) => i).filter((i) => pos[i]);
      for (const i of shared) {
        const fp = this.free.get(items[i].id);
        const mids = fp.froms.map((u) => at.get(u)).filter((k) => k != null && pos[k]).map((k) => [pos[k].x + (items[k].nx || 0) + (items[k].nw || items[k].w) / 2, pos[k].y + (items[k].ny || 0) + (items[k].nh || items[k].h) / 2]);
        const c = mids.length ? [mids.reduce((s, q) => s + q[0], 0) / mids.length, mids.reduce((s, q) => s + q[1], 0) / mids.length] : [0, 0];
        pos[i] = clearSpot(items, pos, i, c, placed, isFrame ? pad : false);
        placed.push(i);
      }
    }
    const stays = items.map((it, i) => !!was[i] && !shared.includes(i) && !flex.includes(i) && !fixed.has(i) && Math.abs(pos[i].x - was[i].x) < 0.5 && Math.abs(pos[i].y - was[i].y) < 0.5);
    // a frame holds what a person put where they are: it grows left or up where a member of it is put past its edge, its place there moving with it
    let sx = 0, sy = 0;
    if (isFrame) items.forEach((it, i) => { if (fixed.has(i)) { sx = Math.min(sx, pos[i].x); sy = Math.min(sy, pos[i].y); } });
    if (sx < 0 || sy < 0) pos.forEach((p, i) => { pos[i] = { x: p.x - sx, y: p.y - sy }; });
    // a frame grows to hold what was put down, flexed or held, never over a member that stays where the file has it (one that sticks out of a frame a person made smaller stays so)
    let maxX = 0, maxY = 0;
    items.forEach((it, i) => {
      if (isFrame && stays[i]) return;
      maxX = Math.max(maxX, pos[i].x + it.w); maxY = Math.max(maxY, pos[i].y + it.h);
    });
    const shape = this.shapeOf(cid, target, slot);
    const eIndex = new Map(items.map((it, i) => [it.id, i]));
    const pedges = (this.liftedBox.get(cid) || []).map((e) => ({ a: eIndex.get(e.a), b: eIndex.get(e.b), w: e.w, n: e.n, np: e.np }));
    const cw = isFrame ? cur.at.get(holder).w - sx : 0, ch = isFrame ? cur.at.get(holder).h - sy : 0;
    const r = { pos: pos.map((p) => ({ x: p.x - pad, y: p.y - pad })), w: Math.max(cw, maxX + pad) - 2 * pad, h: Math.max(ch, maxY + pad) - 2 * pad, algo: 'kept', shift: sx < 0 || sy < 0 ? { x: sx, y: sy } : null };
    if (!isFrame) { r.w = maxX; r.h = maxY; }
    r.parts = ownCostParts(items, r.pos, pedges, FILL_WEIGHT, shape);
    this.settle(cid, items, r, pedges, res, info);
    if (this.kept) this.kept.add(cid);
    return true;
  }

  /**
   * Which way the file has a container's ranked children running: 'rows' (each rank below the one before), 'columns' (each to the right of the
   * one before), 'any' (a rank or none to tell by), or null (neither: a person moved them, or the file lacks one).
   */
  rankedWay(kids, held, cur) {
    const by = new Map();
    for (const t of kids) {
      if (this.isFree(t) || this.m.node(t).rank == null) continue;
      const c = held.has(t) ? cur.at.get(t) : null;
      if (!c) return null;
      const r = this.m.node(t).rank;
      if (!by.has(r)) by.set(r, []);
      by.get(r).push(c);
    }
    const ranks = [...by.keys()].sort((a, b) => a - b);
    let rows = true, cols = true;
    for (let i = 1; i < ranks.length; i++) {
      const before = by.get(ranks[i - 1]), after = by.get(ranks[i]);
      const low = Math.max(...before.map((c) => c.y + c.h)), right = Math.max(...before.map((c) => c.x + c.w));
      if (after.some((c) => c.y < low - 0.5)) rows = false;
      if (after.some((c) => c.x < right - 0.5)) cols = false;
    }
    return rows && cols ? 'any' : rows ? 'rows' : cols ? 'columns' : null;
  }

  /**
   * The boxes of everything on the board that is not in frame `holder`, where the file has it, in the frame's coordinates (`origin` its top-left):
   * each note and frame with the room its title takes, and each pill, which a frame that grows keeps off; `held`: only what a person put there
   * (and the frames that hold such a shape), which a frame never grows over, whatever it must do for the shapes it holds.
   */
  besideFrame(holder, origin, held) {
    const cur = this.current, out = [], inside = (n) => n.key === holder || n.frames.includes(holder);
    const box = (b, above = 0) => ({ x: b.x - origin.x, y: b.y - origin.y - above, w: b.w, h: b.h + above });
    for (const n of this.m.nodes.values()) {
      if (n.board !== this.board || inside(n) || !cur.at.has(n.key)) continue;
      if (held && !this.isPerson(n.key) && !this.holdsPerson.has(n.key)) continue;
      const z = holdsShapes(n) ? this.sizes.frames && this.sizes.frames[n.key] : this.sizes.shapes[n.key];
      out.push(box(cur.at.get(n.key), (z && z.above) || 0));
    }
    for (const e of this.out) {
      const n = this.m.node(e.from);
      if (inside(n) || held) continue;
      const b = this.currentPill(e.from, e.to, n.container);
      if (b) out.push(box({ x: b.x, y: b.y, w: this.pillW(e.to, n.container), h: this.k.pillHeight }));
    }
    return out;
  }

  /** `target` is the shape the container aims at; the frames in it aim at the view's (a ranked container's children at their slots': separateRanked). */
  async separate(cid, units, lifted, algos, res, info, target, slot) {
    if (this.frozen && await this.keepFrozen(cid, units, lifted, algos, res, info, target, slot)) return;
    if (this.flatIn.has(cid)) return this.separateFlat(cid, units, lifted, algos, res, info, target, slot);
    const kids = this.kidsOf(cid);
    const isFrame = cid[0] === 'f';
    // a frame laid out with its container, laid out on its own (its container kept where it is): as one box, its own links
    const alone = isFrame && this.flatFrames.has(cid.slice(2));
    if (alone) { lifted = this.liftedBox; algos = this.algosBox; }
    const affinityOf = alone ? this.affinityBox : this.affinity;
    const ranks = kids.map((t) => (this.isFree(t) ? null : this.m.node(t).rank));
    if (ranks.some((x) => x != null)) return this.separateRanked(cid, kids, ranks, units, lifted, algos, res, info, target);   // ranked children are rows or columns, whatever their arrows ask
    const items = [];
    for (const t of kids) {
      if (this.isFree(t)) items.push(this.freeItem(t));
      else if (holdsShapes(this.m.node(t))) { await this.separate('f:' + t, units, lifted, algos, res, info, this.aspect); const r = res.get('f:' + t); items.push({ id: t, w: r.w, h: r.h, titleAbove: ((this.sizes.frames && this.sizes.frames[t]) || {}).above || 0 }); }
      else items.push(this.leafItem(t, units));
    }
    const shape = this.shapeOf(cid, target, slot);
    // a frame laid out with its container, laid out on its own: as stars, as it is in its container, where its links would have it in rows
    const algo = alone && (algos.get(cid) === 'rows' || algos.get(cid) === 'mrtree') ? 'stars' : algos.get(cid);
    const index = new Map(items.map((it, i) => [it.id, i]));
    const edges = (lifted.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w, n: e.n, np: e.np }));
    const spine = this.spines.get(cid);
    if (spine) {
      const r = this.spine(spine, items);
      r.parts = ownCostParts(items, r.pos, edges, FILL_WEIGHT, shape);
      this.settle(cid, items, r, edges, res, info);
      return;
    }
    let r;
    if (!items.length) r = { pos: [], w: 0, h: 0, algo };
    else {
      const sizeKey = items.map((i) => i.id + '\u0001' + i.w + 'x' + i.h + (i.nw == null ? '' : '/' + i.nw + ',' + i.ny + ',' + (i.nx || 0) + (i.alts ? '@' + i.alt + ':' + i.alts.map((a) => (a ? a.w + 'x' + a.h + ',' + a.nx + ',' + a.ny : '-')).join(';') : ''))).join('\u0002');
      const shapeKey = Math.round(target * 1000) + (slot ? 's' : '');
      const kept = algo === 'stars' && this.starsKeep && this.starsAt.has(cid) ? 'k' + this.starsRound : '';   // from where it was: never an earlier round's
      const affinity = algo === 'stars' ? (affinityOf.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w })).filter((e) => e.a != null && e.b != null) : [];
      const shape0 = affinity.map((e) => e.a + '~' + e.b + ':' + e.w).join(',') + algo + SEP + shapeKey + SEP;
      const rest = SEP + edges.map((e) => e.a + '>' + e.b + ':' + e.w + ':' + e.n + ':' + e.np).join(',');
      // what a stars layout was made from, without which arrangement each leaf was in when it began (the layout chooses it): a redraw's afresh container is the fresh plan's
      const full = shape0 + sizeKey + rest;
      const key = kept + full;
      r = this.cache.get(key);
      if (!r) {
        const cost = (pos) => ownCost(items, pos, edges, FILL_WEIGHT, shape);
        if (algo === 'stars') {
          let excusedHere = [];
          // stars.mjs; while the cut loop runs, each child starts from where it was (the cut only grows boxes)
          const chose = kept ? this.altAt.get(cid) : null;
          const altChosen = chose ? items.map((it) => (chose.has(it.id) ? chose.get(it.id) : null)) : null;
          const notesWere = kept ? this.starsNotes.get(cid) : null;
          const pos = starsLayout(items, edges, { aspect: target, affinity, fromNotes: notesWere ? items.map((it) => notesWere.get(it.id) || null) : null, alt: altChosen, gather: !!this.gatherNow, onExcused: (ps) => { excusedHere = ps.map(([a, b]) => [items[a].id, items[b].id]); } });
          // each leaf as the arrangement of its pills stars chose: its box's size, where it is laid out
          const laid = items.map((it, i) => (it.alts && pos[i].alt !== it.alt ? { id: it.id, w: it.alts[pos[i].alt].w, h: it.alts[pos[i].alt].h } : it));
          r = Object.assign(normalize(laid, pos), { algo: 'stars', alts: new Map(items.map((it, i) => [it.id, pos[i].alt])), excused: excusedHere });
          r.mids = new Map(laid.map((it, i) => [it.id, [r.pos[i].x + it.w / 2, r.pos[i].y + it.h / 2]]));
          // each child's middle, a leaf's its note's, from the container's own origin: where the next round starts it
          r.notes = new Map(items.map((it, i) => {
            const a = it.alts ? it.alts[pos[i].alt] : null;
            return [it.id, a ? [r.pos[i].x + a.nx + a.nw / 2, r.pos[i].y + a.ny + a.nh / 2] : [r.pos[i].x + laid[i].w / 2, r.pos[i].y + laid[i].h / 2]];
          }));
        } else if (algo === 'rows' || algo === 'mrtree') {
          // links with no cycle: ELK's layered (or a tree), its arrows running down and across, the cheaper kept (down on a tie); each leaf's
          // pills on the sides its arrows don't run to: beside it when they run down, under or over it when they run across
          const round = (x) => Math.round(x * 100) / 100, name = algo === 'rows' ? 'layered' : 'mrtree';
          const tall = this.sidedItems(items, ['right', 'left']), wide = this.sidedItems(items, ['below', 'above']);
          const down = Object.assign(await this.flat(name, tall, edges, undefined, { dir: 'DOWN' }), { algo: name, dir: 'DOWN', items: tall });
          const across = Object.assign(await this.flat(name, wide, edges, undefined, { dir: 'RIGHT' }), { algo: name, dir: 'RIGHT', items: wide });
          const cd = ownCost(tall, down.pos, edges, FILL_WEIGHT, shape), ca = ownCost(wide, across.pos, edges, FILL_WEIGHT, shape);
          r = Object.assign({}, ca < cd - 1e-9 ? across : down, algo === 'rows' ? { costs: { layered: round(cd), across: round(ca) } } : {});
        } else {
          // boxes with no arrow among them: each leaf's pills in their most compact arrangement
          const packed = this.sidedItems(items, ['right', 'left', 'below', 'above']);
          r = Object.assign(await this.flat('rectpacking', packed, edges, undefined, { aspect: target }), { algo, items: packed });
        }
        // the leaves as their pills are arranged in the layout chosen (a container in rows or packed gives each its own)
        const its = r.items || items;
        if (r.items) { r.alts = new Map(r.items.filter((it) => it.alts).map((it) => [it.id, it.alt])); delete r.items; }
        if (items.length > 1 && algo !== 'stars') {   // packed: nothing stranded from its mates, the frames of a board near each other (stars keeps its own room)
          const gx = isFrame ? this.k.tightGap : PACK_GAP, gy = isFrame ? 64 : PACK_GAP;
          // gravity: every box slides toward its place
          const start = isFrame ? r.pos : removeOverlaps(its, r.pos, gx + 16, gy + 16);   // the board's frames at least PACK_GAP apart (16 more: the grid snap takes up to that)
          const pk = pack(its, start, edges, gx, gy);
          r = Object.assign({}, r, { pos: pk.pos, w: pk.w, h: pk.h });
        }
        r.parts = ownCostParts(its, r.pos, edges, FILL_WEIGHT, shape);
        this.cache.set(key, r);
      }
    }
    // what a stars layout leaves for the next (where its children were, which side each leaf's pills are on), from the result whether it was
    // just made or found in the cache
    if (r.alts) {
      this.altAt.set(cid, r.alts);
      for (const [id, a] of r.alts) this.altOf.set(id, a);
      // each leaf as stars arranged its pills, so its box is the size the container's own is made of
      items.forEach((it, i) => { if (it.alts && r.alts.get(it.id) !== it.alt) items[i] = this.leafItem(it.id, units); });
    }
    if (r.excused && this.excusedPairs) for (const [a, b] of r.excused) this.excusedPairs.add(cid + SEP + (a < b ? a + SEP + b : b + SEP + a));
    if (r.mids) this.starsAt.set(cid, r.mids);
    if (r.notes) this.starsNotes.set(cid, r.notes);
    this.settle(cid, items, r, edges, res, info);
  }

  /**
   * A container whose frames are laid out with it (`flatIn`): every member of such a frame a child of its stars layout beside the
   * container's own, the frame the box stars.mjs draws round them (`hulls`). Then each frame is settled as a container of its own (its
   * members where stars put them) and the container as one of its frames and its other children, so the drawing reads them as any other.
   */
  async separateFlat(cid, units, lifted, algos, res, info, target, slot) {
    const kids = this.kidsOf(cid);
    const items = [], of = [], spec = [], frames = [];
    for (const t of kids) {
      if (this.flatFrames.has(t)) {
        const fs = (this.sizes.frames && this.sizes.frames[t]) || {}, min = fs.min || this.k.frameMin;
        spec.push({ pad: this.k.frameInset, minW: min.w, minH: min.h, titleW: Math.ceil(fs.titleWidth || 0), above: fs.above || 0 });
        for (const u of this.m.kids.get('f:' + t) || []) { items.push(this.leafItem(u, units)); of.push(frames.length); }
        frames.push(t);
        continue;
      }
      if (this.isFree(t)) items.push(this.freeItem(t));
      else if (holdsShapes(this.m.node(t))) { await this.separate('f:' + t, units, lifted, algos, res, info, this.aspect); const r = res.get('f:' + t); items.push({ id: t, w: r.w, h: r.h, titleAbove: ((this.sizes.frames && this.sizes.frames[t]) || {}).above || 0 }); }
      else items.push(this.leafItem(t, units));
      of.push(-1);
    }
    const shape = this.shapeOf(cid, target, slot);
    const index = new Map(items.map((it, i) => [it.id, i]));
    const edges = (lifted.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w, n: e.n, np: e.np })).filter((e) => e.a != null && e.b != null && e.a !== e.b);
    const sizeKey = items.map((i) => i.id + '\u0001' + i.w + 'x' + i.h + (i.nw == null ? '' : '/' + i.nw + ',' + i.ny + ',' + (i.nx || 0) + (i.alts ? '@' + i.alt + ':' + i.alts.map((a) => (a ? a.w + 'x' + a.h + ',' + a.nx + ',' + a.ny : '-')).join(';') : ''))).join('\u0002');
    const shapeKey = Math.round(target * 1000) + (slot ? 's' : '');
    const kept = this.starsKeep && this.starsAt.has(cid) ? 'k' + this.starsRound : '';
    const affinity = (this.affinity.get(cid) || []).map((e) => ({ a: index.get(e.a), b: index.get(e.b), w: e.w })).filter((e) => e.a != null && e.b != null && e.a !== e.b);
    const shape0 = 'flat' + of.join(',') + JSON.stringify(spec) + SEP + affinity.map((e) => e.a + '~' + e.b + ':' + e.w).join(',') + SEP + shapeKey + SEP;
    const rest = SEP + edges.map((e) => e.a + '>' + e.b + ':' + e.w + ':' + e.n + ':' + e.np).join(',');
    const key = kept + shape0 + sizeKey + rest;
    let r = this.cache.get(key);
    if (!r) {
      let excusedHere = [];
      const chose = kept ? this.altAt.get(cid) : null;
      const altChosen = chose ? items.map((it) => (chose.has(it.id) ? chose.get(it.id) : null)) : null;
      const notesWere = kept ? this.starsNotes.get(cid) : null;
      const from = notesWere ? items.map((it) => notesWere.get(it.id) || null) : null;
      const pos = starsLayout(items, edges, { aspect: target, affinity, fromNotes: from, alt: altChosen, gather: !!this.gatherNow, clusters: { of, spec }, onExcused: (ps) => { excusedHere = ps.map(([a, b]) => [items[a].id, items[b].id]); } });
      const laid = items.map((it, i) => (it.alts && pos[i].alt !== it.alt ? { id: it.id, w: it.alts[pos[i].alt].w, h: it.alts[pos[i].alt].h } : it));
      r = { algo: 'stars', alts: new Map(items.map((it, i) => [it.id, pos[i].alt])), excused: excusedHere, flatPos: pos.map((p) => ({ x: p.x, y: p.y })), hulls: pos.hulls };
      r.mids = new Map(laid.map((it, i) => [it.id, [pos[i].x + it.w / 2, pos[i].y + it.h / 2]]));
      r.notes = new Map(items.map((it, i) => {
        const a = it.alts ? it.alts[pos[i].alt] : null;
        return [it.id, a ? [pos[i].x + a.nx + a.nw / 2, pos[i].y + a.ny + a.nh / 2] : [pos[i].x + laid[i].w / 2, pos[i].y + laid[i].h / 2]];
      }));
      r.parts = ownCostParts(laid, r.flatPos, edges, FILL_WEIGHT, shape);
      this.cache.set(key, r);
    }
    if (r.alts) {
      this.altAt.set(cid, r.alts);
      for (const [id, a] of r.alts) this.altOf.set(id, a);
      items.forEach((it, i) => { if (it.alts && r.alts.get(it.id) !== it.alt) items[i] = this.leafItem(it.id, units); });
    }
    if (r.excused && this.excusedPairs) for (const [a, b] of r.excused) this.excusedPairs.add(cid + SEP + (a < b ? a + SEP + b : b + SEP + a));
    this.starsAt.set(cid, r.mids);
    this.starsNotes.set(cid, r.notes);
    // each frame a container of its own, its members where stars put them; the container, its frames as boxes and its other children
    const outItems = [], outPos = [];
    frames.forEach((t, k) => {
      const H = r.hulls[k], pad = spec[k].pad, mine = [], at = [];
      items.forEach((it, i) => { if (of[i] === k) { mine.push(it); at.push({ x: r.flatPos[i].x - H.x - pad, y: r.flatPos[i].y - H.y - pad }); } });
      this.settle('f:' + t, mine, { pos: at, w: H.w - 2 * pad, h: H.h - 2 * pad, algo: 'group', parts: { arrows: 0, n: 0 } }, [], res, info);
      outItems.push({ id: t, w: H.w, h: H.h }); outPos.push({ x: H.x, y: H.y });
    });
    items.forEach((it, i) => { if (of[i] < 0) { outItems.push(it); outPos.push(r.flatPos[i]); } });
    const nr = normalize(outItems, outPos);
    this.settle(cid, outItems, { pos: nr.pos, w: nr.w, h: nr.h, algo: 'stars', parts: r.parts }, edges, res, info);
  }

  /**
   * A container's laid-out children, kept: its size (a frame's with its inset, never under the least frame or its title) and their places in it;
   * and `sub`, what is under it: what its arrows and its frames' cost (their shapes aside), how many there are, and its leaves' area.
   */
  settle(cid, items, r, edges, res, info) {
    const isFrame = cid[0] === 'f';
    const how = r.ranked ? r.ranked.orient : r.dir === 'RIGHT' ? 'across' : null;   // what the report says of it, beside its algorithm
    info.set(cid, { algorithm: r.algo, how, children: items.length, arrows: edges.reduce((s, e) => s + e.n, 0), costs: r.costs || null });
    const pad = isFrame ? this.k.frameInset : 0;
    const fs = isFrame ? (this.sizes.frames && this.sizes.frames[cid.slice(2)]) || {} : {};   // the app's smallest for this frame, and the width of the title over it
    const min = fs.min || this.k.frameMin;
    const w = isFrame ? Math.max(r.w + 2 * pad, min.w, Math.ceil(fs.titleWidth || 0)) : r.w;
    const h = isFrame ? Math.max(r.h + 2 * pad, min.h) : r.h;
    const pos = new Map(items.map((it, i) => [it.id, { x: r.pos[i].x + pad, y: r.pos[i].y + pad }]));
    const sub = { arrows: r.parts ? r.parts.arrows : 0, n: r.parts ? r.parts.n : 0, area: 0 };
    for (const it of items) {
      const f = res.get('f:' + it.id);
      if (f && this.isFrame(it.id)) { sub.arrows += f.sub.arrows; sub.n += f.sub.n; sub.area += f.sub.area; } else sub.area += it.w * it.h;
    }
    res.set(cid, { w, h, pos, algo: r.algo, dir: r.dir, ranked: r.ranked, sub, shift: r.shift || null });
  }

  /** Roughly the room a child takes, before it is laid out: a leaf's box and the gaps kept about it, and a frame's leaves' with a fifth more. */
  roomOf(t, units) {
    if (this.isFree(t)) return (this.free.get(t).w + this.k.tightGap) * (this.k.pillHeight + 64);
    if (!holdsShapes(this.m.node(t))) { const u = units.get(t), a = u.alts[u.first]; return (a.w + this.k.tightGap) * (a.h + 64); }
    return 1.2 * this.kidsOf('f:' + t).reduce((s, c) => s + this.roomOf(c, units), 0) + 1;
  }

  /**
   * A container whose children have ranks: they run as rows, the lowest rank on top, or as columns, the lowest at the left, whichever the view
   * shows larger when the container is fit to it (opts.ranks says one or the other outright). A child is laid out to the shape of its
   * slot: a row of a board that is to be wide is wide and short, a column narrow and tall. How wide the slots are taken to be is tried a few
   * ways (`m`), since a child laid out is not the size it was guessed at.
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
    // each attempt lays the children out again, and a stars child leaves its state (starsAt, altAt, altOf) as it goes: kept apart for each
    // attempt, and the chosen one's left behind, so the next round starts from the layout chosen, not the last one tried
    const stars = () => ({ starsAt: new Map(this.starsAt), altAt: new Map(this.altAt), altOf: new Map(this.altOf), starsNotes: new Map(this.starsNotes) });
    const before = stars();
    const attempt = async (orient, m) => {
      Object.assign(this, { starsAt: new Map(before.starsAt), altAt: new Map(before.altAt), altOf: new Map(before.altOf), starsNotes: new Map(before.starsNotes) });
      const sub = new Map(), subInfo = new Map(), items = [];
      for (let i = 0; i < kids.length; i++) {
        const t = kids[i];
        if (this.isFree(t)) { items.push(this.freeItem(t)); continue; }
        if (!holdsShapes(this.m.node(t))) { items.push(this.leafItem(t, units)); continue; }
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
      return { orient, m, items, r, sub, subInfo, cost: arrows + shapeCost(off, n) + (1 + 0.25 * n) * FILL_WEIGHT * empty, off, shown, stars: stars() };
    };
    // which way they run is chosen once a board, on its first layout (the cut's rounds are made for that way): the way that shows larger when the
    // board is fit to the view (rows when it is the same). How wide the slots are taken to be is found afresh each time, by what the whole costs.
    let best = null;
    const ways = this.way.has(cid) ? [this.way.get(cid)] : this.opts.ranks === 'auto' ? ['rows', 'columns'] : [this.opts.ranks];
    for (const orient of ways) {
      let at = null;
      for (const m of [1, 0.5, 2]) { const x = await attempt(orient, m); if (!at || x.cost < at.cost - 1e-9) at = x; }
      for (const f of [Math.SQRT1_2, Math.SQRT2]) { const x = await attempt(orient, at.m * f); if (x.cost < at.cost - 1e-9) at = x; }
      if (!best || at.shown > best.shown * 1.02) best = at;
    }
    this.way.set(cid, best.orient);
    Object.assign(this, best.stars);
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

  /** ELK's layout of boxes, asked once: the same boxes, arrows and options give the same layout. */
  async flat(algo, items, edges, seed, shape) {
    const key = algo + SEP + (seed || 0) + SEP + (shape ? (shape.dir || '') + (shape.aspect ? Math.round(shape.aspect * 1000) : '') : '') + SEP + items.map((i) => i.w + 'x' + i.h).join(',') + SEP + edges.map((e) => e.a + '>' + e.b).join(',');
    const had = this.elkCache.get(key);
    if (had) return Object.assign({}, had);
    const r = await layoutFlat(this.elk, algo, items, edges, seed, shape);
    this.elkCache.set(key, r);
    return Object.assign({}, r);
  }
}

/** Whether a note (with its title's room) or pill of one item at these places is on a note or pill of another (an item without pills: its box). */
function partsOverlap(items, pos) {
  const parts = items.map((it, i) => {
    const p = pos[i], a = it.alts ? it.alts[it.alt] : null;
    const ta = it.titleAbove || 0;   // a note with the room its title takes above it
    if (!a) return [{ x: p.x, y: p.y - ta, w: it.w, h: it.h + ta }];
    return [{ x: p.x + a.nx, y: p.y + a.ny - ta, w: a.nw, h: a.nh + ta }].concat(a.pills.map((q) => ({ x: p.x + q.x, y: p.y + q.y, w: q.w, h: q.h })));
  });
  const hit = (A, B) => A.x < B.x + B.w && B.x < A.x + A.w && A.y < B.y + B.h && B.y < A.y + A.h;
  for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) {
    for (const A of parts[i]) for (const B of parts[j]) if (hit(A, B)) return true;
  }
  return false;
}

/** Whether any two boxes at these places overlap. */
function overlapping(items, pos) {
  for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) {
    if (pos[i].x < pos[j].x + items[j].w && pos[j].x < pos[i].x + items[i].w && pos[i].y < pos[j].y + items[j].h && pos[j].y < pos[i].y + items[i].h) return true;
  }
  return false;
}

// A container of more children than this is packed as boxes, its arrows drawn over them, whatever they are: laid out by its arrows, a
// star of hundreds (an index file that imports every icon) is a tree a row or a column long (465 notes, 122,512 units, past what draw
// takes), and a crowd of them is a layout that takes minutes. A board with one is laid out once and cut no further (cut.mjs).
export const CROWD = 150;

/**
 * Which algorithm a container's children ask for, by the links among them (`edges`, {a, b}) and how it is to be placed (`placement`:
 * stars, rows, or auto): none for one child, packed as boxes with no links or past the crowd, stars where the links have a cycle (or
 * stars is asked for), a tree where they are a forest, else rows.
 */
export function chooseAlgorithm(kids, edges, placement = 'auto') {
  if (kids.length <= 1) return 'trivial';
  if (kids.length > CROWD) return 'rectpacking';
  if (!edges.length) return 'rectpacking';
  if (placement === 'stars' || (placement === 'auto' && !isAcyclic(kids, edges))) return 'stars';
  if (isForest(kids, edges)) return 'mrtree';
  return 'rows';   // layered, its arrows running down or across, whichever costs less
}

/** Whether the links among a container's children, each from its `a` to its `b`, have no cycle. */
function isAcyclic(kids, edges) {
  const out = new Map(kids.map((k) => [k, []]));
  for (const e of edges) if (e.a !== e.b && out.has(e.a)) out.get(e.a).push(e.b);
  const state = new Map();
  const visit = (u) => {
    state.set(u, 1);
    for (const v of out.get(u) || []) { if (state.get(v) === 1) return false; if (!state.has(v) && !visit(v)) return false; }
    state.set(u, 2);
    return true;
  };
  for (const k of kids) if (!state.has(k) && !visit(k)) return false;
  return true;
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
