// The cut: which of a board's links become reference pills, so that the rest can be drawn with no arrow crossing another and none over a
// shape (the plan, docs/plans/board-layout). No knob trades crossings for pills: the fewest cuts that make the board clean, as found.
//   1. Planar first. Each container's links among its children (each of the board's links lifted to the container that holds both its
//      ends, between the children that hold them) are made a planar graph: the pairs a link marked `direct` joins (or a link at a frame,
//      or one into a shape no pill may stand for: `layout.pill: false`, or a kind no pill stands for) are kept whatever, the rest added
//      the most wanted first, and a pair that would make the graph non-planar is cut, every link of it a pill beside its start. The most
//      wanted: the heavier (`layout.weight`), then the one whose busier end has more links (a hub keeps its arrows and gives up its
//      weakest users first), then the one whose other end has more, then key order; among ranked children (rows), the pairs between ranks
//      next to each other first, the longest spans cut first.
//   2. A spine's shared pills (layout.mjs's findSpines): the lines into a shared pill are made planar with the links too: each container's
//      shared pills, the most used first, their users' lines added to its links as they are drawn, and a line that would make them not
//      planar gives its user a pill of its own (`unshared`). Every other pill is its note's own.
//   3. Placed (layout.mjs: stars, stars.mjs's, or rows where the links have no cycle or the children are ranked), and measured as the drawing
//      will be (health.mjs, on the layout). The links in a conflict that the stars placement could not draw clean (`excusedPairs`) are cut
//      first. Then every crossing and every arrow over a shape names the plain arrows and the lines into a spine's shared pills in it, and
//      the one named most is mended (ties: a line into a shared pill first, its user given a pill of its own; then the least wanted link,
//      cut), until each conflict is; then laid out again from where it was, until the board is clean or nothing is left to mend (`ROUNDS`
//      at most). A conflict with nothing in it that may be mended (an arrow between frames, say, which is drawn whatever) is mended by the
//      placement instead: a container in rows whose arrow it is is placed as stars from then on (`stuck`).
//   4. Gathered: on a clean board, each stars container laid out once more, drawn together, kept when the board stays clean and is smaller.
//   5. Drawn again in place (`opts.current`, instead of 1 to 4): the cut is the file's, read (`fileCut`): the file's row for each edge says whether it is an
//      arrow or goes through a pill, and which (a pill several edges go into is shared by them, made by the one whose key its row has); only an edge with
//      no row (a new link) is decided here: an arrow where its line is clear, else a share of a pill the file has, else a pill of its own. Every shape stays
//      where the file has it, and what the file lacks is put down beside (layout.mjs's keepFrozen); what a person moved, resized or put elsewhere
//      (`opts.current.person`) stays exactly where they put it, its pills put about it again, and what it covers is put down again; a conflict is mended by
//      cutting the link in most of them (or having it share a pill the file has for that shape), or by putting a note's own pills about it again. The board
//      is laid out afresh, as 1 to 4 say, only where the file holds none of it (or reading it threw); one no mend makes clean is kept, and what is left said
//      (`stop` not clean). Nothing is put back or shared after: a pill stays a pill.
//   6. Put back by the drawing (restore.mjs): on a clean board, each link the cut made a pill whose line, drawn on the finished drawing with no
//      note moved, crosses no line and runs over no shape or pill, is an arrow again and its pill goes; kept only where the board ends clean.
//   7. Shared by the drawing (share.mjs): on a clean board, the notes of a container that use one target share a pill where each of them
//      reaches it by a clear straight line; kept only where the board ends clean.
//   7. A board whose frames were laid out with their containers (layout.mjs's findFlat) that ends not clean is laid out again with every
//      frame one box, and that taken when it is clean.
import { byTitle } from './util.mjs';
import { planarCut } from './planarity.mjs';
import { readLayout, boardHealth, HEALTH } from './health.mjs';
import { holdsShapes } from './model.mjs';
import { CROWD, Layouter } from './layout.mjs';
import { len, segCross, arrowPath } from './geom.mjs';
import { shareByDrawing } from './share.mjs';
import { restoreByDrawing } from './restore.mjs';
import { Scene, Grid } from './scene.mjs';

const SEP = '\u0000';
const AGAIN = '\u0005';   // before a note's key in what frozenCuts picks: the note put down again, its pills' lines still in a conflict after its pills were set about it again
const REPILL = '\u0006';   // before a note's key in what frozenCuts picks: the note whose own pill's line is in a conflict, its pills put about it again
const UNSHARE = '\u0004';   // before a key in what conflictCuts picks: the line into a shared pill to give its user a pill of its own
/** The most rounds of cutting what a placement leaves unclean. */
export const ROUNDS = 8;
/**
 * A board with a container of more children than layout.mjs's CROWD (which it packs as boxes), or of more shapes than this in all, is
 * laid out once, cut to planar and nothing more, and the report says to split it: a board that crowded reads as a crowd however it is cut.
 */
export const CROWDED_BOARD = 1000;

/** The container of the board with the most children (its frames and leaves), the first by id on a tie: {container, children}. */
export function crowdOf(model, board) {
  const count = new Map();
  for (const n of model.nodes.values()) if (n.board === board) count.set(n.container, (count.get(n.container) || 0) + 1);
  let most = { container: 'b:' + board, children: 0 };
  for (const [c, k] of [...count].sort((a, b) => byTitle(a[0], b[0]))) if (k > most.children) most = { container: c, children: k };
  return most;
}
const keyOf = (e) => e.from + SEP + e.to;
/** Whether a link may be a pill: not marked direct (nor at a frame), and into a shape a pill may stand for. */
export const cuttable = (model, e) => !e.direct && !model.node(e.to).never;

/**
 * The links `planarLinks` cuts, by key (`from` and `to`), how many links it looked at, and how many pairs of children they make (a link lifted
 * to the container that holds both its ends); `graphs`, each container's children and the pairs of them drawn as arrows once the cut is
 * made (indexes), which the shared pills are added to (`sharedCut`). `skip(e)`: links that are pills whatever (a spine's), which the cut
 * leaves out.
 */
export function planarLinks(layouter, skip) {
  const { m } = layouter;
  const { byContainer, links } = pairsOf(layouter, skip);
  const cut = new Set(), precut = new Set(), graphs = new Map();
  let looked = 0;
  for (const cid of [...byContainer.keys()].sort(byTitle)) {
    let pairs = [...byContainer.get(cid).values()];
    const kids = layouter.cutKids(cid);
    // a link cluster cut (`layout.cut`: between two groups) is a pill before anything is placed or counted (restore.mjs may make it an arrow again once everything
    // is placed): a pair keeps the rest of its links and goes when none is left; a pair some link of which may not be a pill (`kept`) stays a kept pair of those
    // links alone: a cut link is not an arrow because it was lifted into the same pair of groups as a link that has to be
    pairs = pairs.filter((p) => {
      const out = p.edges.filter((e) => e.precut);
      if (!out.length) return true;
      for (const e of out) { cut.add(keyOf(e)); precut.add(keyOf(e)); }
      p.edges = p.edges.filter((e) => !e.precut);
      p.w = p.edges.reduce((s, e) => s + e.weight, 0);
      return p.edges.length > 0;
    });
    const index = new Map(kids.map((t, i) => [t, i]));
    const degree = new Map();
    for (const p of pairs) for (const t of [p.a, p.b]) degree.set(t, (degree.get(t) || 0) + 1);
    const rank = (t) => m.node(t).rank;
    const ranked = kids.some((t) => rank(t) != null);
    const span = (p) => (rank(p.a) != null && rank(p.b) != null ? Math.abs(rank(p.a) - rank(p.b)) : 0);
    const busy = (p) => Math.max(degree.get(p.a), degree.get(p.b)), quiet = (p) => Math.min(degree.get(p.a), degree.get(p.b));
    const wanted = pairs.filter((p) => !p.kept).sort((p, q) => (ranked ? Math.min(span(p), 99) - Math.min(span(q), 99) : 0)
      || q.w - p.w || busy(q) - busy(p) || quiet(q) - quiet(p) || byTitle(p.a, q.a) || byTitle(p.b, q.b));
    const pair = (p) => [index.get(p.a), index.get(p.b)];
    looked += pairs.length;
    const kept = pairs.filter((p) => p.kept).map(pair), gone = new Set(planarCut(kids.length, kept, wanted.map(pair)));
    for (const i of gone) for (const e of wanted[i].edges) cut.add(keyOf(e));
    graphs.set(cid, { kids, drawn: kept.concat(wanted.filter((p, i) => !gone.has(i)).map(pair)) });
  }
  return { cut, precut, links, pairs: looked, graphs };
}

/** The board's links (but those `skip` takes), each lifted to the container that holds both its ends: pairs of its children, by container. */
function pairsOf(layouter, skip) {
  const { m } = layouter;
  const byContainer = new Map();   // container id -> Map(pair key -> {a, b, edges, kept, w})
  let links = 0;
  for (const e of layouter.sameBoard) {
    if (skip && skip(e)) continue;
    links++;
    const ca = layouter.chain(e.from), cb = layouter.chain(e.to);
    let k = 0;
    while (k < ca.length && k < cb.length && ca[k] === cb[k]) k++;
    const cid = ca[k - 1];
    const a = k < ca.length ? ca[k].slice(2) : e.from, b = k < cb.length ? cb[k].slice(2) : e.to;
    if (a === b) continue;
    const [x, y] = a < b ? [a, b] : [b, a];
    let pairs = byContainer.get(cid);
    if (!pairs) byContainer.set(cid, pairs = new Map());
    const pk = x + SEP + y;
    let p = pairs.get(pk);
    if (!p) pairs.set(pk, p = { a: x, b: y, edges: [], kept: false, w: 0 });
    p.edges.push(e);
    p.w += e.weight;
    if (!cuttable(m, e)) p.kept = true;
  }
  return { byContainer, links };
}

/**
 * The lines into shared pills a drawing with no crossing can't keep, by the key of their edge (`from` and `to`): in each container, its
 * links drawn as arrows once the cut is made (`graphs`, planarLinks') and each of its shared pills a node, the most used first (then by
 * key), each user's line to it added in turn (users by title), and one that would make the graph not planar given to its user as a pill
 * of its own. The first line into a pill never can (a pill one line reaches hangs off its user), so every shared pill keeps one user at least.
 */
export function sharedCut(layouter, state, graphs) {
  const { m } = layouter;
  const byContainer = new Map();
  for (const g of layouter.pillPlan(state).groups) {
    if (!g.free) continue;
    if (!byContainer.has(g.container)) byContainer.set(g.container, []);
    byContainer.get(g.container).push(g);
  }
  const unshared = new Set();
  for (const cid of [...byContainer.keys()].sort(byTitle)) {
    const groups = byContainer.get(cid).sort((a, b) => b.edges.length - a.edges.length || byTitle(a.key, b.key));
    const base = graphs.get(cid) || { kids: layouter.cutKids(cid), drawn: [] };
    const index = new Map(base.kids.map((t, i) => [t, i]));
    let n = base.kids.length;
    const wanted = [], lineOf = [];
    for (const g of groups) {
      const pill = n++;
      for (const e of g.edges) { const u = index.get(e.from); if (u == null) continue; wanted.push([u, pill]); lineOf.push(e); }
    }
    for (const i of planarCut(n, base.drawn, wanted)) unshared.add(keyOf(lineOf[i]));
  }
  return unshared;
}

/** a < b, for numbers or for lists of numbers compared member by member */
const less = (a, b) => {
  if (!Array.isArray(a)) return a < b;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i];
  return false;
};

/**
 * What to mend so a layout's conflicts are (`conflicts`: boardHealth's, line indexes). A conflict with a line into a shared pill in it is
 * mended by giving that line's user a pill of its own (`UNSHARE` and the edge's key), never by cutting a link: sharing a pill is never paid
 * for with an arrow. The rest by cutting a plain arrow that may be cut (its link's key). Each the way `pickMost` picks (`leastFirst`: see there).
 */
export function conflictCuts(conflicts, lines, worth, leastFirst = false) {
  const of = (c, f) => [...new Set(c.map((i) => lines[i]).filter(f).map((l) => (l.unsharable ? UNSHARE : '') + l.key))];
  const shared = conflicts.map((c) => of(c, (l) => l.unsharable)).filter((ks) => ks.length);
  const plain = conflicts.filter((c) => !c.some((i) => lines[i].unsharable)).map((c) => of(c, (l) => l.cuttable)).filter((ks) => ks.length);
  return pickMost(shared, worth, leastFirst).concat(pickMost(plain, worth, leastFirst));
}

/**
 * What to mend so a kept layout's conflicts are: the plain arrows are guesses (the file says nothing of an arrow), the pills and what shares them
 * are the file's, so a conflict with a plain arrow in it is mended by that arrow (cut, or shared), and one with none by giving a line into a
 * shared pill its user's own pill. Each the way `pickMost` picks. A line into a note's own pill is put about it again (the note's pills set once more)
 * only for a conflict in `mine` (the conflicts that something this redraw changed is in): setting pills about a note again is no mend that ends, so a
 * conflict the file has already is left as it is, which is what keeps a board drawn again from being drawn differently.
 */
export function frozenCuts(conflicts, lines, worth, mine, ops) {
  const plainOf = (c) => [...new Set(c.map((i) => lines[i]).filter((l) => l.cuttable).map((l) => l.key))];
  const sharedOf = (c) => [...new Set(c.map((i) => lines[i]).filter((l) => l.unsharable).map((l) => UNSHARE + l.key))];
  // a line into a note's own pill in a conflict with nothing else to mend: the note's pills are put about it again
  const ownOf = (c) => {
    const mine = c.map((i) => lines[i]).filter((l) => l.intoPill && !l.unsharable).map((l) => l.edge[0]);
    // or the note whose pill the line runs over; a note whose pills were set again once is put down again, as a note is that has no room
    const over = conflicts.solid && conflicts.solid.get(conflicts.indexOf(c)), host = over != null && ops && ops.hostOf ? ops.hostOf(over) : null;
    return [...new Set(mine.concat(mine.length && host ? [host] : []).filter((t) => !(ops && ops.tried(t) && ops.held(t))).map((t) => (ops && ops.tried(t) ? AGAIN : REPILL) + t))];
  };
  const plain = conflicts.map(plainOf).filter((ks) => ks.length), rest = conflicts.filter((c) => !plainOf(c).length).map(sharedOf).filter((ks) => ks.length);
  const own = (mine || conflicts).filter((c) => !plainOf(c).length && !sharedOf(c).length).map(ownOf).filter((ks) => ks.length);
  return pickMost(plain, worth).concat(pickMost(rest, worth), pickMost(own, worth));
}

/**
 * Of what each open conflict could be mended by (keys), the one in the most conflicts, the least wanted on a tie (`worth`: a smaller number, or list of
 * numbers, first), until every conflict has one picked. `leastFirst` (a plan with no file to keep, `conflictCuts`): the least wanted first, the one in more
 * conflicts only on a tie, so what a cut costs the board counts before how many conflicts it mends (the engine's weights are how alike two notes are).
 */
function pickMost(open, worth, leastFirst) {
  const out = [];
  while (open.length) {
    const count = new Map();
    for (const ks of open) for (const k of ks) count.set(k, (count.get(k) || 0) + 1);
    let best = null;
    for (const [k, c] of count) {
      if (best == null) { best = k; continue; }
      const cb = count.get(best);
      if (leastFirst) { if (less(worth(k), worth(best)) || (!less(worth(best), worth(k)) && (c > cb || (c === cb && k < best)))) best = k; }
      else if (c > cb || (c === cb && (less(worth(k), worth(best)) || (!less(worth(best), worth(k)) && k < best)))) best = k;
    }
    out.push(best);
    open = open.filter((ks) => !ks.includes(best));
  }
  return out;
}

/**
 * The containers in rows (layered, or a tree) whose arrows are in a conflict that has no arrow the cut may take: each such arrow's container,
 * the one that holds both its ends, unless the document asks for rows there (its node's `layout.placement`, or the document's).
 */
function stuck(conflicts, lines, layouter, layout) {
  const rows = new Set(layout.containers.filter((c) => c.algorithm === 'layered' || c.algorithm === 'mrtree').map((c) => c.cid));
  const out = new Set();
  for (const c of conflicts) {
    const ls = c.map((i) => lines[i]);
    if (ls.some((l) => l.cuttable || l.unsharable)) continue;
    for (const l of ls) {
      if (l.intoPill) continue;
      const ca = layouter.chain(l.edge[0]), cb = layouter.chain(l.edge[1]);
      let k = 0;
      while (k < ca.length && k < cb.length && ca[k] === cb[k]) k++;
      const cid = ca[k - 1];
      if (rows.has(cid) && layouter.askedPlacement(cid) !== 'rows') out.add(cid);
    }
  }
  return [...out].sort(byTitle);
}

/**
 * A board laid out with its links cut, planar first and then until it is clean (or nothing is left to cut): {state, layout, report}, the
 * state and layout as layout.mjs takes and makes them, the report as the plan's summary reads it (`cut`, `cutFurther`, `rounds`, `stop`:
 * clean, or not clean with no plain arrow left that would mend it). With `opts.current` (plan.mjs's
 * currentFor: where the drawing's shapes are now) it is drawn again in place (`redrawBoard`): the cut is the file's and every shape stays where the
 * file has it; the report says `kept` (the containers that kept their members), and `afresh` where the file holds none of the board (or reading
 * it threw), so the board is laid out as a plan with no file would. A kept layout no mend makes clean stays, `stop` not clean.
 */
export async function cutBoard(model, layouter, opts = {}) {
  const now = opts.now || (() => Date.now());
  const t0 = now();
  const board = layouter.board;
  if (opts.current) {
    let kept = null, failed = null;
    try { kept = await redrawBoard(model, layouter, opts); } catch (e) { failed = e && e.message ? e.message : String(e); }
    if (kept) return kept;
    // the file holds none of the board, or reading it failed (said): laid out afresh, as a plan with no file is
    const fresh = await cutBoard(model, new Layouter(model, board, layouter.sizes, layouter.opts, layouter.elk), Object.assign({}, opts, { current: null }));
    fresh.report.kept = []; fresh.report.afresh = true; fresh.report.ms = now() - t0;
    if (failed) fresh.report.redrawFailed = failed;
    return fresh;
  }
  const spined = (e) => layouter.spineLeaf.has(e.from);   // a spine's links are pills already
  const planar = planarLinks(layouter, spined);
  const state = { cut: new Set(planar.cut), unshared: new Set() };
  const unsharedPlanar = sharedCut(layouter, state, planar.graphs);
  state.unshared = new Set(unsharedPlanar);
  const degree = new Map();
  for (const e of layouter.sameBoard) for (const t of [e.from, e.to]) degree.set(t, (degree.get(t) || 0) + 1);
  const weight = new Map(layouter.sameBoard.map((e) => [keyOf(e), e.weight]));
  const worth = (k) => {
    if (k[0] === UNSHARE) return [0, 0, 0];   // a pill of its own for a line into a shared pill, before cutting any link
    const [a, b] = k.split(SEP);
    return [weight.get(k) || 1, Math.max(degree.get(a) || 0, degree.get(b) || 0), Math.min(degree.get(a) || 0, degree.get(b) || 0)];
  };
  // a document clustered by tightness weighs each link by how alike its notes are (cluster.mjs): the mend cuts the least wanted first. Any other
  // document's weights are the lens's, which the mend has always read only after the conflicts a link is in
  const byTightness = !!(model.layout.clustered && model.layout.clustered.by);
  layouter.starsKeep = false; layouter.starsAt = new Map(); layouter.altAt = new Map();
  let layout = await layouter.layout(state);
  const crowd = crowdOf(model, board);
  const crowded = crowd.children > CROWD || layouter.leaves.length > CROWDED_BOARD
    ? { container: crowd.container === 'b:' + board ? null : crowd.container.slice(2), children: crowd.children, most: CROWD, shapes: layouter.leaves.length, mostShapes: CROWDED_BOARD }
    : null;
  const further = [], unsharedFurther = [];
  let rounds = 0, health = null;
  // measured and mended until clean, at most ROUNDS more layouts; `again` lays the board out once more after each mend
  const mend = async (again) => {
    for (let r = 0; ; r++) {
      const B = readLayout(model, layout, layouter.sizes);
      health = boardHealth(B, layouter.view, 0, true);
      if (crowded || r >= ROUNDS) break;
      // first the links whose pairs the planar placement could not draw clean (it says so): cut, and laid out again
      if (layouter.excusedPairs && layouter.excusedPairs.size) {
        const ex = [], inConflict = new Set();
        for (const c of health.conflicts) for (const i of c) if (B.lines[i] && B.lines[i].key) inConflict.add(B.lines[i].key);
        for (const e of layouter.sameBoard) {
          const k = keyOf(e);
          if (state.cut.has(k) || !cuttable(model, e) || spined(e) || !inConflict.has(k)) continue;
          const ca = layouter.chain(e.from), cb = layouter.chain(e.to);
          let i = 0;
          while (i < ca.length && i < cb.length && ca[i] === cb[i]) i++;
          const a = i < ca.length ? ca[i].slice(2) : e.from, b = i < cb.length ? cb[i].slice(2) : e.to;
          if (layouter.excusedPairs.has(ca[i - 1] + SEP + (a < b ? a + SEP + b : b + SEP + a))) ex.push(k);
        }
        if (ex.length && health.status !== 'clean') {
          for (const k of [...new Set(ex)].sort()) { state.cut.add(k); further.push(k); }
          layouter.starsKeep = true;
          layout = await again();
          rounds++;
          continue;
        }
      }
      const pick = conflictCuts(health.conflicts, B.lines, worth, byTightness)
        .filter((k) => (k[0] === UNSHARE ? !state.unshared.has(k.slice(1)) : !state.cut.has(k)));
      const turned = stuck(health.conflicts, B.lines, layouter, layout).filter((cid) => !layouter.asStars.has(cid));
      if (!pick.length && !turned.length) break;
      for (const k of pick) {
        if (k[0] === UNSHARE) { state.unshared.add(k.slice(1)); unsharedFurther.push(k.slice(1)); }
        else { state.cut.add(k); further.push(k); }
      }
      for (const cid of turned) layouter.asStars.add(cid);
      layouter.starsKeep = true;
      layout = await again();
      rounds++;
    }
  };
  await mend(() => layouter.layout(state));
  // drawn together: each stars container laid out once more from where it is, its children gathered toward its middle while it stays clean
  // as far as it knows; kept when the board is clean and smaller, else the layout before stands
  if (!crowded && health.status === 'clean' && layout.containers.some((c) => c.algorithm === 'stars')) {
    const snap = { starsAt: new Map(layouter.starsAt), altAt: new Map(layouter.altAt), altOf: new Map(layouter.altOf), starsNotes: new Map(layouter.starsNotes) };
    layouter.gatherNow = true; layouter.starsKeep = true;
    const tighter = await layouter.layout(state);
    layouter.gatherNow = false;
    const h2 = boardHealth(readLayout(model, tighter, layouter.sizes), layouter.view, 0, true);
    if (h2.status === 'clean' && h2.size[0] * h2.size[1] < 0.99 * health.size[0] * health.size[1]) { layout = tighter; health = h2; }
    else Object.assign(layouter, snap);
  }
  // links put back as arrows by the drawing (restore.mjs): each link the cut made a pill that has a clear line on the finished drawing; kept only
  // where the board ends clean
  let restored = 0, restoredCut = 0;
  if (!crowded && health.status === 'clean') {
    const r = restoreByDrawing(model, layouter, layout);
    if (r) { layout = r.layout; health = r.health; restored = r.restored; restoredCut = r.restoredCut; }
  }
  // shared pills by the drawing (share.mjs): every note where it is, a target's users in one container sharing a pill where the
  // drawing has a spot each of them reaches clean; kept only where the board ends clean
  let geoShared = 0;
  if (!crowded && health.status === 'clean') {
    const r = shareByDrawing(model, layouter, layout);
    if (r) { layout = r.layout; health = r.health; geoShared = r.shared; }
  }
  layouter.starsKeep = false;
  if (!crowded && health.status !== 'clean' && layouter.flatFrames.size) {
    const boxed = new Layouter(model, board, layouter.sizes, Object.assign({}, layouter.opts, { flatFrames: false }), layouter.elk);
    const r = await cutBoard(model, boxed, opts);
    if (r.report.stop === 'clean') { r.report.ms = now() - t0; r.report.framesBoxed = true; return r; }
  }
  const pills = layout.pills.length, arrows = layout.plan.direct.length;
  const sharedPills = layout.pills.filter((p) => p.free).length, sharedLines = layout.plan.free.length + layout.plan.members.length;
  const report = {
    board, placement: [...new Set(layout.containers.map((c) => c.algorithm))].sort(byTitle), asStars: [...layouter.asStars].sort(byTitle),
    links: planar.links, pairs: planar.pairs, cut: planar.cut.size - planar.precut.size, precut: planar.precut.size, cutFurther: further.length, unshared: unsharedPlanar.size, unsharedFurther: unsharedFurther.length, rounds,
    restored, restoredCut, sharedByDrawing: geoShared,
    stop: health.status === 'clean' ? 'clean' : crowded ? 'crowded' : 'not clean',
    end: { pills, arrows, sharedPills, sharedLines },
    algorithms: layout.containers.map((c) => ({ container: c.container, algorithm: c.algorithm, how: c.how || null, children: c.children, arrows: c.arrows })),
    crowded, ms: now() - t0,
  };
  return { state, layout, report };
}

/**
 * What the file says of a board's links: its rows for the edges (`cur.edges`, from the `edge …` rows) say which are arrows and which go through which
 * pill: `cut`, the links through a pill (the pill's row, `pill …`, is its maker's), `sharing`, the edges that share a pill (each by the edge that made it),
 * `unshared`, the edges of a spine's group that have a pill of their own. A link the file has no row for is new: an arrow where its line is clear (as
 * the cut puts links back), else a share of a pill the file has that it reaches, else a pill of its own, in order. Where the file has no edge rows at all
 * (an app that gives none), every link is decided so, a pill the file has for it taken as its own. `hostFor` finds the pill an edge could share, for the mend.
 */
function fileCut(model, layouter, cur) {
  const state = { cut: new Set(), unshared: new Set(), sharing: new Map() };
  const spined = (e) => layouter.spineLeaf.has(e.from);
  const rowKeyOf = (e) => layouter.currentPillRow(e.from, e.to, model.node(e.from).container);
  const rowOf = (e) => { const k = rowKeyOf(e); return k ? cur.at.get(k) : null; };
  const pillsAt = new Map();   // a shape and a container -> the pills the file has for it there: {e, box, at}
  const rowed = [];            // every pill the file has, and the scene's index of it
  for (const e of layouter.out) {
    const box = rowOf(e);
    if (!box) continue;
    const k = e.to + SEP + model.node(e.from).container, pill = { e, rowKey: rowKeyOf(e), box: { x: box.x, y: box.y, w: layouter.pillW(e.to, model.node(e.from).container), h: layouter.k.pillHeight }, at: rowed.length };
    if (!pillsAt.has(k)) pillsAt.set(k, []);
    pillsAt.get(k).push(pill);
    rowed.push(pill);
    if (!e.cross && !spined(e) && cuttable(model, e)) state.cut.add(keyOf(e));
  }
  // the pills the file has that no edge of the document makes now (the note that made one is gone): a shared pill's users keep it
  const known = new Set(), parse = (row) => {
    const text = row.slice(5), at = text.lastIndexOf(' -> ');
    if (at < 0) return null;
    for (const to of [text.slice(at + 4), text.slice(at + 4, text.lastIndexOf(' '))]) if (to && model.node(to)) return { from: text.slice(0, at), to };
    return null;
  };
  for (const e of model.edges) { const base = 'pill ' + e.from + ' -> ' + e.to; known.add(base); for (const k of e.keys) if (k) known.add('pill ' + k); }
  layouter.orphans = new Map();
  for (const row of cur.at.keys()) {
    if (!row.startsWith('pill ') || known.has(row) || known.has(row.slice(0, Math.max(0, row.lastIndexOf(' '))))) continue;
    const x = parse(row), holder = cur.pillIn ? cur.pillIn.get(row) : null;
    if (!x || (holder != null && !model.node(holder))) continue;
    const cid = holder == null ? 'b:root' : holdsShapes(model.node(holder)) ? 'f:' + holder : 'b:' + holder;
    if ((cid[0] === 'f' ? model.node(holder).board : cid.slice(2)) !== layouter.board) continue;
    const c = cur.at.get(row), k = x.to + SEP + cid;
    const o = { box: { x: c.x, y: c.y, w: layouter.pillW(x.to, cid), h: layouter.k.pillHeight }, taken: 0 };
    if (!layouter.orphans.has(k)) layouter.orphans.set(k, []);
    layouter.orphans.get(k).push(o);
    if (!pillsAt.has(k)) pillsAt.set(k, []);
    const pill = { e: { from: x.from, to: x.to }, rowKey: row, box: o.box, at: rowed.length, orphan: true, cid };
    pillsAt.get(k).push(pill);
    rowed.push(pill);
  }
  // what the file's edge rows say of a link (`cur.edges`): drawn through no pill, an arrow; through a pill, the maker of it (the pill's row has its place) or one
  // of the notes that share it, all of them the pill's, by its id. A link with no row is new: decided below, as it is where the file says nothing of edges
  const said = new Set(), fixedArrows = [], groups = new Map();
  const byRow = new Map(rowed.map((p) => [p.rowKey, p]));
  if (cur.edges && cur.edges.size) {
    for (const e of layouter.out) {
      const v = spined(e) ? null : cur.edges.get(keyOf(e));
      if (!v || rowOf(e) || (e.cross && v.via == null)) continue;
      if (v.via == null) { said.add(keyOf(e)); fixedArrows.push(e); continue; }
      const host = byRow.get(cur.pillKeyOfId && cur.pillKeyOfId.get(v.via));
      if (!host || (e.cross ? false : !cuttable(model, e))) continue;
      said.add(keyOf(e));
      if (!groups.has(v.via)) groups.set(v.via, { host, users: [] });
      groups.get(v.via).users.push(e);
    }
    // a pill several links go into is shared by them, made by the first of them (the maker's, the one the file has made it): its users each a line into it
    for (const [, g] of [...groups].sort((p, q) => byTitle(p[1].host.rowKey, q[1].host.rowKey))) {
      const maker = g.host.orphan || !model.hasEdge(g.host.e.from, g.host.e.to) ? null : g.host.e;
      const count = g.users.length + (maker ? 1 : 0), tag = g.host.e.from;
      for (const e of g.users) {
        if (!e.cross) state.cut.add(keyOf(e));
        if (count >= 2) state.sharing.set(keyOf(e), tag);
      }
      if (maker && count >= 2) state.sharing.set(keyOf(maker), tag);
    }
  }
  layouter.sharedRows = new Set([...groups.values()].filter((g) => g.users.length + (!g.host.orphan && model.hasEdge(g.host.e.from, g.host.e.to) ? 1 : 0) >= 2).map((g) => g.host.rowKey));
  rowed.forEach((p) => { p.stale = !p.orphan && layouter.stale(p.e.from, p.rowKey); });
  // the file as a scene: its notes and frames with their titles' room, its pills, and the line from each note to a pill of its own
  const B = { board: layouter.board, shapes: [], lines: [], pills: [] }, tabOf = (b, z) => (z && z.above > 0 ? { x: b.x, y: b.y - z.above, w: z.titleWidth > 0 ? Math.min(b.w, z.titleWidth) : b.w, h: z.above } : null);
  const boxes = new Map();
  for (const n of model.nodes.values()) {
    const c = n.board === layouter.board ? cur.at.get(n.key) : null;
    if (!c) continue;
    boxes.set(n.key, c);
    const frame = holdsShapes(n);
    B.shapes.push({ id: n.key, frame, box: c, tab: tabOf(c, frame ? layouter.sizes.frames && layouter.sizes.frames[n.key] : layouter.sizes.shapes[n.key]), frames: n.frames });
  }
  const scene = new Scene(model, { pills: rowed.map((p) => p.box) }, B);
  rowed.forEach((p) => { if (p.stale) scene.setPill(p.at, false); });   // the pills of a note a person moved are put about it again: nothing of the file
  // every line the file draws that is known so far (a note's pills' addPills keeps its new pills off them)
  const lines = [], pilled = new Set(rowed.map((p) => p.e.from + SEP + p.e.to));
  layouter.fileLines = lines;
  const drawn = (from, to, segs, pill) => {
    for (const seg of segs) lines.push({ a: from, b: to, seg, pill: !!pill });
    // the other arrow between two shapes is bowed apart from the first (the way is the app's, not the order here): both ways kept off
    const A = boxes.get(from), Z = boxes.get(to);
    if (A && Z && model.hasEdge(to, from) && !pilled.has(from + SEP + to)) {
      for (const bend of [-HEALTH.pairBend, HEALTH.pairBend]) { const path = arrowPath(A, Z, bend, HEALTH.samples); for (let j = 1; j < path.length; j++) lines.push({ a: from, b: to, seg: { x1: path[j - 1][0], y1: path[j - 1][1], x2: path[j][0], y2: path[j][1] } }); }
    }
  };
  for (const p of rowed) { const A = p.orphan || p.stale ? null : boxes.get(p.e.from); if (A) { const segs = scene.linePaths(p.e.from, p.box, p.e); scene.addLine(p.e.from, p.at, segs, p.box); drawn(p.e.from, p.e.to, segs, true); } }
  const holdersOf = (e, extra) => new Set(model.node(e.from).frames.concat(extra || []));
  const centre = (t) => { const c = cur.at.get(t); return c ? [c.x + c.w / 2, c.y + c.h / 2] : null; };
  /** The pills the file has for the shape an edge goes to, in its note's container, that are a first user's by title (a shared pill is), nearest its note first. */
  const hosts = (e) => {
    const list = (pillsAt.get(e.to + SEP + model.node(e.from).container) || []).filter((h) => !spined(h.e) && !h.stale);
    const at = centre(e.from), far = (h) => (at ? len(h.box.x + h.box.w / 2 - at[0], h.box.y + h.box.h / 2 - at[1]) : 0);
    // a pill is made by its first user by title, unless users joined it later: those of a smaller title first
    const before = (h) => (byTitle(h.e.from, e.from) < 0 ? 0 : 1);
    return list.sort((p, q) => before(p) - before(q) || far(p) - far(q) || byTitle(p.e.from, q.e.from));
  };
  const holdersFor = (e, h) => {
    const n = h.orphan ? null : model.node(h.e.from);
    return holdersOf(e, n ? n.frames.concat(n.container[0] === 'f' ? [n.container.slice(2)] : []) : (h.cid && h.cid[0] === 'f' ? model.node(h.cid.slice(2)).frames.concat([h.cid.slice(2)]) : []));
  };
  const take = (e) => !scene.noteBox.get(e.from) ? null : hosts(e).find((h) => scene.reaches(e.from, h.box, scene.pills[h.at].id, holdersFor(e, h), e)) || null;
  const hostFor = (e) => { const h = take(e); return h ? h.e : null; };
  const share = (e, host) => {
    const tag = state.sharing.get(keyOf(host)) != null ? state.sharing.get(keyOf(host)) : host.from;
    if (model.hasEdge(host.from, host.to)) state.sharing.set(keyOf(host), tag);
    state.sharing.set(keyOf(e), tag);
    if (!e.cross) state.cut.add(keyOf(e));
  };
  const unknown = layouter.out.filter((e) => !rowOf(e) && !spined(e) && !said.has(keyOf(e))).sort((p, q) => byTitle(p.from, q.from) || byTitle(p.to, q.to));
  // a link of one board the file has no pill for: an arrow where its line is clear (as the cut puts links back); of two arrows that cross, the one
  // that could share a pill the file has is the one the file shared; the rest each a pill, shared where a pill the file has is reached
  const arrows = [], later = [];
  /** The segments of an edge's lines between two boxes: as many as it draws, bowed apart as the app bows them (a frame is an end too, which scene.linePaths knows not). */
  const pathsOf = (e, A, B) => {
    const out = [], n = Math.max(1, e.items.length);
    for (let k = 0; k < n; k++) {
      const steps = k % 2 ? (k + 1) / 2 : -(k / 2), path = arrowPath(A, B, -steps * HEALTH.pairBend, HEALTH.samples);
      for (let j = 1; j < path.length; j++) out.push({ x1: path[j - 1][0], y1: path[j - 1][1], x2: path[j][0], y2: path[j][1] });
    }
    return out;
  };
  // the file's own links, their lines known: an arrow where the file draws one, a line into the pill a link shares
  for (const e of fixedArrows) {
    const to = boxes.get(e.to), from = boxes.get(e.from);
    if (!to || !from) continue;
    const path = pathsOf(e, from, to);
    for (const s of path) scene.lines.addSeg({ seg: s, line: { a: e.from, b: e.to, on: () => true }, on: () => true });
    drawn(e.from, e.to, path);
  }
  for (const g of groups.values()) for (const e of g.users) {
    if (!scene.noteBox.get(e.from)) continue;
    const segs = scene.linePaths(e.from, g.host.box, e);
    scene.addLine(e.from, g.host.at, segs, g.host.box); drawn(e.from, e.to, segs, true);
  }
  for (const e of unknown) {
    if (e.cross) continue;
    const to = boxes.get(e.to), from = boxes.get(e.from);
    if (!to || !from) continue;
    if (!cuttable(model, e)) arrows.push({ e, forced: true, path: pathsOf(e, from, to) });
    else if (scene.reaches(e.from, to, e.to, holdersOf(e, model.node(e.to).frames), e)) arrows.push({ e, forced: false, path: pathsOf(e, from, to), alt: !!take(e) });
    else later.push(e);
  }
  const dropped = new Set();
  const crosses = (p, q) => p.path.some((s) => q.path.some((t) => segCross(s, t)));
  const near = new Grid();
  arrows.forEach((a, i) => { for (const seg of a.path) near.addSeg({ seg, owner: i, on: () => true }); });
  arrows.forEach((x, i) => {
    const others = new Set();
    for (const seg of x.path) for (const it of near.along(seg)) if (it.owner > i) others.add(it.owner);
    for (const j of [...others].sort((p, q) => p - q)) {
      const y = arrows[j];
      if (dropped.has(x) || dropped.has(y) || x.e.from === y.e.from || x.e.from === y.e.to || x.e.to === y.e.from || x.e.to === y.e.to || !crosses(x, y)) continue;
      const pick = x.forced || (!y.forced && y.alt && !x.alt) ? y : y.forced || (x.alt && !y.alt) ? x : x.alt && y.alt ? (byTitle(keyOf(x.e), keyOf(y.e)) > 0 ? x : y) : null;
      if (pick && !pick.forced) dropped.add(pick);
    }
  });
  for (const a of arrows) {
    if (dropped.has(a)) { later.push(a.e); continue; }
    for (const s of a.path) scene.lines.addSeg({ seg: s, line: { a: a.e.from, b: a.e.to, on: () => true }, on: () => true });
    drawn(a.e.from, a.e.to, a.path);
  }
  // a user with no pill of its own shares the pill the file has that is nearest it of those its line reaches (a first user by title's, before any
  // of a greater title); a user of one board that reaches none has a pill of its own (its link cut)
  for (const e of later.concat(unknown.filter((x) => x.cross)).sort((p, q) => byTitle(p.from, q.from) || byTitle(p.to, q.to))) {
    const h = take(e);
    if (h) { share(e, h.e); const segs = scene.linePaths(e.from, h.box, e); scene.addLine(e.from, h.at, segs, h.box); drawn(e.from, e.to, segs, true); } else if (!e.cross) state.cut.add(keyOf(e));
  }
  // a spine's groups: the pills each spine's cards share are made by the first of their users, and a card the cut or the mend gave a pill of its own
  // has a row though it is no first user (`unshared`): the fewest edges that make the groups agree with the file, each the one that agrees most
  if (layouter.spines.size) {
    const spine = (e) => spined(e);
    const plan = (U) => layouter.pillPlan({ cut: state.cut, unshared: U, sharing: state.sharing });
    const wrong = (p) => {
      let n = 0;
      for (const x of p.members) if (spine(x.e) && rowOf(x.e)) n++;
      for (const f of p.free) if (spine(f.e) && !rowOf(f.e)) n++;
      for (const l of p.byStart.values()) for (const en of l) if (spine(en.e) && !rowOf(en.e)) n++;
      return n;
    };
    let now = wrong(plan(state.unshared));
    for (let guard = 0; now > 0 && guard < 200; guard++) {
      const cands = plan(state.unshared).members.filter((x) => spine(x.e) && rowOf(x.e)).map((x) => keyOf(x.e)).sort();
      let best = null, bn = now;
      for (const k of cands) {
        const U = new Set(state.unshared); U.add(k);
        const n = wrong(plan(U));
        if (n < bn) { best = k; bn = n; }
      }
      if (!best) break;
      state.unshared.add(best); now = bn;
    }
  }
  return { state, hostFor, share, rowOf };
}

/**
 * A board drawn again in place: every shape stays where the file has it, and what the file lacks (a note it has no place for, a note that
 * grew or has a pill it lacked, a frame that grew) is put down beside them, nearest the shapes it links to (layout.mjs's keepFrozen); the
 * cut is the file's (`fileCut`), a link no pill of the file's stands for an arrow, and only the board's conflicts are mended: the link in most of
 * them is cut (or, where the file has a pill for the shape it links to, shares it), a line into a shared pill given a pill of its own, until
 * the board is clean (at most ROUNDS). Nothing is put back as an arrow or shared by the drawing after: a pill stays a pill and an arrow an arrow
 * unless its own conflict says otherwise. Null only where the file holds none of the board
 * (cutBoard then lays the board out afresh); a layout no mend makes clean, a crowded board's included, is kept, `stop` not clean. The report is the last layout's, with `kept`.
 */
async function redrawBoard(model, layouter, opts) {
  const now = opts.now || (() => Date.now());
  const t0 = now(), cur = opts.current, board = layouter.board;
  const heldHere = (n) => { const h = cur.members.get(n.container); return !!h && h.has(n.key) && cur.at.has(n.key); };
  if (!layouter.leaves.some(heldHere)) return null;
  layouter.current = cur; layouter.frozen = true; layouter.kept = new Set();
  // the shapes a person put where they are stay there, and the frames that hold one (a shape in another container than the document says is put down in its own)
  for (const n of model.nodes.values()) {
    if (n.board !== board || !cur.person || !cur.person.has(n.key) || !heldHere(n)) continue;
    layouter.person.add(n.key);
    for (const f of n.frames) layouter.holdsPerson.add(f);
  }
  const { state, hostFor, share } = fileCut(model, layouter, cur);
  const cutAtFirst = state.cut.size, unsharedAtFirst = state.unshared.size;
  const further = [], unsharedFurther = [], shared = [];
  const edgeOf = new Map(layouter.sameBoard.map((e) => [keyOf(e), e]));
  const degree = new Map();
  for (const e of layouter.sameBoard) for (const t of [e.from, e.to]) degree.set(t, (degree.get(t) || 0) + 1);
  const weight = new Map(layouter.sameBoard.map((e) => [keyOf(e), e.weight]));
  const byId = new Map(layouter.leaves.map((n) => [n.key, n]));
  // a link whose end the file has no place for is the one to cut first, then as the cut ranks them
  const fresh = (t) => !byId.has(t) || !heldHere(byId.get(t));
  const worth = (k) => {
    if (k[0] === UNSHARE || k[0] === REPILL || k[0] === AGAIN) return [0, 0, 0, 0];
    const [a, b] = k.split(SEP);
    return [fresh(a) || fresh(b) ? 0 : 1, weight.get(k) || 1, Math.max(degree.get(a) || 0, degree.get(b) || 0), Math.min(degree.get(a) || 0, degree.get(b) || 0)];
  };
  const crowd = crowdOf(model, board);
  const crowded = crowd.children > CROWD || layouter.leaves.length > CROWDED_BOARD
    ? { container: crowd.container === 'b:' + board ? null : crowd.container.slice(2), children: crowd.children, most: CROWD, shapes: layouter.leaves.length, mostShapes: CROWDED_BOARD }
    : null;
  let layout = await layouter.layout(state), health = null, rounds = 0;
  layouter.grown = layout.frames;
  // a conflict the file has already, among shapes and lines this redraw changed none of: the notes' pills are not set about them again for it
  const inheritable = !!(cur.edges && cur.edges.size);
  const same = (a, b) => !!a && !!b && Math.abs(a.x - b.x) < 0.5 && Math.abs(a.y - b.y) < 0.5 && (a.w == null || b.w == null || (Math.abs(a.w - b.w) < 0.5 && Math.abs(a.h - b.h) < 0.5));
  const openOf = (conflicts, B) => {
    if (!inheritable) return conflicts;
    const noteTouched = (t) => layouter.person.has(t) || layouter.why.has(t) || layouter.repill.has(t) || !same(cur.at.get(t), layout.boxes.get(t) || layout.frames.get(t));
    const pillTouched = (i) => { const p = layout.pills[i], f = p && layouter.filePill(p); return !p || noteTouched(p.start) || !f || Math.abs(f.x - p.x) > 0.5 || Math.abs(f.y - p.y) > 0.5; };
    const idTouched = (id) => (typeof id === 'string' && id[0] === '\u0001' ? pillTouched(+id.slice(1)) : noteTouched(id));
    const lineTouched = (l) => idTouched(l.a) || idTouched(l.b) || !cur.edges.has(l.edge[0] + SEP + l.edge[1]) || changedLinks.has(l.key);
    return conflicts.filter((c, k) => c.some((i) => lineTouched(B.lines[i])) || (conflicts.solid && conflicts.solid.has(k) && idTouched(conflicts.solid.get(k))));
  };
  const changedLinks = new Set();
  // the notes the file has on another note or its title's room: somebody put them there
  let covering = null;
  const onOthers = () => {
    if (covering) return covering;
    covering = new Set();
    const boxes = [];
    for (const n of model.nodes.values()) {
      const c = n.board === board && !holdsShapes(n) ? cur.at.get(n.key) : null;
      if (c) boxes.push({ k: n.key, x: c.x, y: c.y - ((layouter.sizes.shapes[n.key] || {}).above || 0), w: c.w, h: c.h + ((layouter.sizes.shapes[n.key] || {}).above || 0) });
    }
    boxes.sort((a, b) => a.x - b.x || byTitle(a.k, b.k));
    for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length && boxes[j].x < boxes[i].x + boxes[i].w - 0.5; j++) {
      const a = boxes[i], b = boxes[j];
      if (a.y < b.y + b.h - 0.5 && b.y < a.y + a.h - 0.5) { covering.add(a.k); covering.add(b.k); }
    }
    return covering;
  };
  for (let r = 0; ; r++) {
    const B = readLayout(model, layout, layouter.sizes);
    health = boardHealth(B, layouter.view, 0, true);
    if (health.status === 'clean' || crowded || r >= ROUNDS) break;
    const pick = frozenCuts(health.conflicts, B.lines, worth, openOf(health.conflicts, B), {
      tried: (t) => layouter.repill.has(t),
      held: (t) => layouter.person.has(t) || onOthers().has(t),   // a person's note is never put down again, nor one the file has on another (the tool puts none there)
      hostOf: (id) => { const p = typeof id === 'string' && id[0] === '\u0001' ? layout.pills[+id.slice(1)] : null; return p && !p.free ? p.start : null; },
    }).filter((k) => (k[0] === UNSHARE ? !state.unshared.has(k.slice(1)) : k[0] === REPILL ? !layouter.repill.has(k.slice(1)) : k[0] === AGAIN ? !layouter.again.has(k.slice(1)) : !state.cut.has(k)));
    if (!pick.length) break;
    for (const k of pick) {
      changedLinks.add(k[0] === UNSHARE || k[0] === REPILL || k[0] === AGAIN ? k.slice(1) : k);
      if (k[0] === REPILL) { layouter.repill.add(k.slice(1)); continue; }
      if (k[0] === AGAIN) { layouter.again.add(k.slice(1)); continue; }
      if (k[0] === UNSHARE) { state.unshared.add(k.slice(1)); unsharedFurther.push(k.slice(1)); continue; }
      const host = hostFor(edgeOf.get(k));
      if (host) { share(edgeOf.get(k), host); shared.push(k); } else { state.cut.add(k); further.push(k); }
    }
    layout = await layouter.layout(state);
    layouter.grown = layout.frames;
    rounds++;
  }
  // never undo a person's move: where a person's shapes are held, what the mend could not clear is kept and said
  const kept = [...layouter.kept].sort(byTitle);
  const moved = [];
  for (const n of [...model.nodes.values()].sort((a, b) => byTitle(a.key, b.key))) {
    const was = n.board === board ? cur.at.get(n.key) : null, now = layout.boxes.get(n.key) || layout.frames.get(n.key);
    if (!was || !now) continue;
    const by = len(now.x - was.x, now.y - was.y);
    if (by > 0.5) moved.push({ key: n.key, by: Math.round(by), why: layouter.why.get(n.key) || 'it is in a container that moved' });
  }
  const held = [...layouter.person].sort(byTitle);
  const named = health.status === 'clean' ? [] : health.examples.filter((x) => held.some((k) => x.includes(JSON.stringify(k))));
  const pills = layout.pills.length, arrows = layout.plan.direct.length;
  const sharedPills = layout.pills.filter((p) => p.free).length, sharedLines = layout.plan.free.length + layout.plan.members.length;
  const report = {
    board, placement: [...new Set(layout.containers.map((c) => c.algorithm))].sort(byTitle), asStars: [],
    links: layouter.sameBoard.filter((e) => !layouter.spineLeaf.has(e.from)).length, pairs: 0, cut: cutAtFirst, cutFurther: further.length + shared.length, unshared: unsharedAtFirst, unsharedFurther: unsharedFurther.length, rounds,
    precut: 0, restored: 0, restoredCut: 0, sharedByDrawing: 0,
    stop: health.status === 'clean' ? 'clean' : crowded ? 'crowded' : 'not clean',
    end: { pills, arrows, sharedPills, sharedLines },
    algorithms: layout.containers.map((c) => ({ container: c.container, algorithm: c.algorithm, how: c.how || null, children: c.children, arrows: c.arrows })),
    crowded, ms: now() - t0, kept, afresh: false, moved, held, putDown: layouter.why.size, conflicts: named.concat((health.status === 'clean' ? [] : layouter.conflicts).map((k) => `no arrangement of the pills of ${JSON.stringify(k)} is clear of what is about it`)),
  };
  return { state, layout, report };
}
