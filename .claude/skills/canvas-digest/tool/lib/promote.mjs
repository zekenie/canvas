// The promotion loop. Every same-board edge is a plain arrow at first. Make the move that cuts the board's cost most: promote a node
// many arrows point at (every user of it then reaches it through a pill, all of them, whether or not the hub uses them back; the tie
// counts only in the score that picks the candidates to try; the users of it in one container share one pill), or fan out a node that
// points at many (each of its uses becomes a pill beside it, and what they stand for is made public: moves.mjs). First, while the
// board is not good enough as it is and a node is popular (the dial's `popular` arrows or more would turn into pills), the most popular
// one is moved, whatever its trial measures: a measured gain is noisy, and a node that many arrows meet at is the case the loop is for.
// A board that is good enough with every arrow plain is left alone: pills are for a mess. Then the judgment calls: repeat until
//   - the board is good enough, or
//   - the best of the K candidates tried, and of the K after them, cuts the cost C by no more than the margin (an absolute number,
//     a number of pills' prices: what a promotion must beat to be more than the layout's reshuffling), or
//   - a safety cap is reached: the dial's share of the board's leaves moved, 0.5 (1 - mess), promoted and fanned out and the popular
//     ones among them (the report says so if it is hit).
// A shared pill whose arrows are long or cross notes is split into pills for nearer clusters of its users, if that lowers C.
// Then take back each judgment call that does not pay for itself: a popular node's move stays, and so does a pin (`public: true`).
// Last, on the final layout: each arrow longer than the dial's `longest` is set apart as a pill of its own beside its start, and the
// board laid out again from where it is, until none is left.
// While it searches the loop lays containers out again from where they are (Layouter.warm): ELK's layouts are new draws, whose
// differences in C are larger than any gain.
import { byTitle } from './util.mjs';
import { evaluate, ranksOf } from './cost.mjs';
import { segLength } from './geom.mjs';
import { measureNoise } from './noise.mjs';
import { REF_MU } from './dial.mjs';
import { CROWD } from './layout.mjs';
import { ext, withMove, withoutMove, moveGroups, fanTargets, fansOut, mayBeApart } from './moves.mjs';

const SEP = '\u0000';
const r4 = (x) => Math.round(x * 1e4) / 1e4;   // the engines' last digits differ; a plan should not
export const PREFER = 2;
export const TOP = 6;
// A board is searched only while its containers are a size the search can lay out again and again: it lays every container out again
// from where it was hundreds of times, at O(n²) a pass in a container's children (stress.mjs's warmStress, elk.mjs's pushApart), and a
// frame of 532 notes took a minute and a half a layout, and its board hours. A board with a container of more children than CROWD
// (layout.mjs, which packs such a container as boxes), or more shapes than CROWDED_BOARD in all, is laid out once, afresh, every arrow on
// it drawn (but those to other boards, which are pills), and the report says to split it: a board that crowded reads as a crowd whatever
// the search does.
export { CROWD };
export const CROWDED_BOARD = 1000;

/** The container of the board with the most children (its frames and leaves), the first by id on a tie: {container, children}. */
export function crowdOf(model, board) {
  const count = new Map();
  for (const n of model.nodes.values()) if (n.board === board) count.set(n.container, (count.get(n.container) || 0) + 1);
  let most = { container: 'b:' + board, children: 0 };
  for (const [c, k] of [...count].sort((a, b) => byTitle(a[0], b[0]))) if (k > most.children) most = { container: c, children: k };
  return most;
}

/** The sources of arrows into v that promotion would turn into pills: every user, those in v's own container too (D17). */
function usersOf(model, layouter, v) {
  return (model.inn.get(v) || []).filter((e) => !e.cross && !e.via && !e.direct && model.node(e.from).board === layouter.board).map((e) => e.from);
}

export { ext };

export async function runBoard(model, layouter, opts) {
  const now = opts.now || (() => Date.now());
  const t0 = now();
  const mu = opts.mu == null ? REF_MU : opts.mu;   // the search's price of a pill: the same for every mess (see dial.mjs)
  const muD = model.mu;                            // the dial's: what the report's C is at, what a promotion's pills cost it, what it takes back
  const cm = (e) => e.cost + (muD - mu) * e.pillTerm;   // a layout's cost at the dial's price of a pill
  let margin = opts.margin == null ? 2 * mu : opts.margin;   // the search's margin (measured below)
  let marginD = margin;                            // the margin a promotion must beat to be kept: the drop in C, an absolute number (measured below, unless given)
  const K = TOP;
  const prefer = opts.prefer == null ? PREFER : opts.prefer;   // how many mu of C each extra pill in a (frame, hub) must save: one pill is preferred
  const board = layouter.board;
  const report = { board, dial: model.dial, overrides: { cap: opts.cap == null ? null : opts.cap, margin: opts.margin == null ? null : opts.margin, popular: opts.popular == null ? null : opts.popular }, mu: muD, searchMu: mu, margin, k: K, promotions: [], demotions: [], splits: [], hostChanges: 0, stop: null, safetyCap: null };
  let state = { promoted: new Set(), order: [], fanned: new Set(), fans: [], apart: new Set(), hosts: new Map(), splits: new Map() };
  const leaves = layouter.leaves;
  if (opts.promote) for (const n of leaves) if (n.pin) { state.promoted.add(n.title); state.order.push(n.title); }
  const lap = (name) => { report.laps = report.laps || {}; const t = now(); report.laps[name] = (report.laps[name] || 0) + (t - lapT); lapT = t; };
  let lapT = now();

  // accepting a layout: the containers are laid out again from where it has them
  const accept = (cur) => layouter.setAnchors(cur);
  // ... and, once the state is chosen, laid out again until it stops moving, so that the next trials are compared with a settled layout
  const settled = async (st, cur, ev) => { const r = await layouter.converge(st, cur, evaluate, mu); return { st, cur: r.cur, ev: r.ev }; };

  // the hosts of the groups, chosen against the layout, and the layout again with them; kept only if it costs no more
  const settle = async (st, cur, ev, only) => {
    layouter.phase = 'settle';
    const hosts = layouter.assignHosts(st, cur, only);
    let same = hosts.size === st.hosts.size;
    if (same) for (const [k, h] of hosts) if (st.hosts.get(k) !== h) { same = false; break; }
    if (same) return { st, cur, ev };
    const next = ext(st, { hosts });
    const layout = await layouter.layout(next);
    const e2 = evaluate(model, layout, mu);
    if (e2.cost <= ev.cost + 1e-9) { report.hostChanges++; return settled(next, layout, e2); }
    return { st, cur, ev };
  };
  // each shared group of 4 or more users (in one container, for one hub) tried as k clusters of nearby users, k from 2 to ceil(users / 3), a pill and a host
  // each (a cluster of one: a plain pill). One pill is preferred: the k with the lowest C is kept only if every extra pill saves at least mu x PREFER of C.
  const splitMany = async (st, cur, ev, only, trialMode, done) => {   // trialMode: one pass on a trial's layout, nothing settled or reported (the splits go to `done`)
    layouter.phase = 'split';
    for (let pass = 0; pass < (trialMode ? 1 : 3); pass++) {
      const cands = splitCandidates(layouter, st, cur, ev).filter((f) => (!only || only.has(f.group.target)) && !st.splits.has(f.group.base));   // a group already split is not split again
      let improved = false;
      for (const f of cands) {
        let best = null;
        const n = f.group.froms.length;
        for (let k = 2; k <= Math.ceil(n / 3); k++) {
          const clusters = clusterK(cur, f.group.froms, k).sort((a, b) => b.length - a.length || byTitle(a[0], b[0]));
          if (clusters.length < 2 || (best && best.sigs.has(JSON.stringify(clusters)))) continue;
          const sp = new Map(st.splits); const m = new Map(); clusters.forEach((c, i) => c.forEach((u) => m.set(u, i))); sp.set(f.group.base, m);
          const trial = ext(st, { splits: sp });
          const keys = new Set(layouter.pillPlan(trial).groups.filter((g) => g.base === f.group.base).map((g) => g.key));
          trial.hosts = layouter.assignHosts(trial, cur, keys);
          const layout = await layouter.layout(trial);
          const e2 = evaluate(model, layout, mu);
          const need = (clusters.length - 1) * mu * prefer;
          if (opts.debug) opts.debug('split ' + f.group.target + ' in ' + f.group.container + ' k ' + k + ' into ' + clusters.map((c) => c.length) + ': ' + Math.round(e2.cost) + ' vs ' + Math.round(ev.cost) + ' need ' + Math.round(need));
          if (e2.cost <= ev.cost - need - 1e-9 && (!best || e2.cost < best.ev.cost)) best = { trial, layout, ev: e2, clusters, k, need, sigs: new Set() };
        }
        if (best) {
          (trialMode ? done : report.splits).push({ target: f.group.target, container: f.group.container === 'b:' + board ? null : f.group.container.slice(2), users: n, into: best.clusters.map((c) => c.length), k: best.k, prefer, saved: r4(ev.cost - best.ev.cost), needed: r4(best.need), farthest: Math.round(f.farthest), crossing: f.crossing, before: r4(ev.cost), after: r4(best.ev.cost) });
          if (trialMode) { st = best.trial; cur = best.layout; ev = best.ev; improved = true; continue; }
          ({ st, cur, ev } = await settled(best.trial, best.layout, best.ev)); improved = true;
          ({ st, cur, ev } = await settle(st, cur, ev));   // the hosts of the clusters, against the new layout
        }
      }
      if (!improved) break;
    }
    return { st, cur, ev };
  };

  state = ext(state, {});
  layouter.warm = false; layouter.phase = 'start';
  let cur = await layouter.layout(state);
  let ev = evaluate(model, cur, mu);
  report.start = { cost: r4(cm(ev)), X: ev.X, NE: ev.NE, Fx: ev.Fx, aspect: r4(ev.aspect), arrows: ev.arrows, pills: ev.pills, sharedArrows: ev.sharedArrows };
  // what the report says of the layout the board ends with, and the board's result: a crowded board's is its first layout
  const done = () => {
    report.end = { cost: r4(cm(ev)), costSearch: r4(ev.cost), X: ev.X, NE: ev.NE, NEnote: ev.NEnote, NEpill: ev.NEpill, Fx: ev.Fx, aspect: r4(ev.aspect), size: ev.size, arrows: ev.arrows, sharedArrows: ev.sharedArrows, pills: ev.pills, orphans: ev.orphans, len: r4(ev.len), good: ev.good };
    const nArr = Math.max(1, ev.arrows + ev.sharedArrows);
    const gd = model.dial.good;
    report.goodTerms = {   // what "good enough" asks at this mess (per arrow, and the aspect), and where the board is
      n: nArr, NE: { value: ev.NE, perArrow: r4(ev.NE / nArr), need: gd.nePerArrow }, X: { value: ev.X, perArrow: r4(ev.X / nArr), need: gd.xPerArrow }, Fx: { value: ev.Fx, perArrow: r4(ev.Fx / nArr), need: gd.fxPerArrow }, aspect: { value: r4(ev.aspect), need: gd.aspect }, good: ev.good,
    };
    report.promoted = state.order.slice();
    report.fanned = state.fans.slice();
    report.algorithms = cur.containers.map((c) => ({ container: c.container, algorithm: c.algorithm, how: c.how || null, warm: !!c.warm, children: c.children, arrows: c.arrows, costs: c.costs, w: c.w, h: c.h })).sort((a, b) => byTitle(a.container || '', b.container || ''));
    report.fill = cur.fills;
    report.shared = cur.plan.groups.filter((g) => g.shared).map((g) => ({ target: g.target, container: g.container === 'b:' + board ? null : g.container.slice(2), host: g.host, users: g.edges.length, split: g.key !== g.base })).sort((a, b) => byTitle(a.target, b.target) || byTitle(a.container || '', b.container || ''));
    {   // per (frame, hub): the pills and the users of each (a shared group is one pill; a group not shared, a pill a user)
      const m = new Map();
      for (const g of cur.plan.groups) {
        let r = m.get(g.base); if (!r) m.set(g.base, r = { target: g.target, container: g.container === 'b:' + board ? null : g.container.slice(2), users: 0, perPill: [] });
        r.users += g.edges.length;
        if (g.shared) r.perPill.push(g.edges.length); else for (let i = 0; i < g.edges.length; i++) r.perPill.push(1);
      }
      report.pillsPerHub = [...m.values()].map((r) => ({ target: r.target, container: r.container, users: r.users, pills: r.perPill.length, perPill: r.perPill.sort((a, b) => b - a) })).sort((a, b) => byTitle(a.target, b.target) || byTitle(a.container || '', b.container || ''));
      const hist = {}; for (const r of report.pillsPerHub) hist[r.pills] = (hist[r.pills] || 0) + 1;
      report.pillsHistogram = hist;
    }
    report.mode = cur.mode;
    report.layout = Object.assign({ layouts: layouter.stats.layouts, elkCalls: layouter.stats.elkCalls, cacheHits: layouter.stats.hits }, layouter.stats);
    report.ms = now() - t0;
    return { state, layout: cur, ev, report };
  };
  const crowd = crowdOf(model, board);
  if (crowd.children > CROWD || leaves.length > CROWDED_BOARD) {
    report.stop = 'crowded';
    report.crowded = { container: crowd.container === 'b:' + board ? null : crowd.container.slice(2), children: crowd.children, most: CROWD, shapes: leaves.length, mostShapes: CROWDED_BOARD };
    report.long = [];
    lap('final');
    return done();
  }
  layouter.warm = true;
  ({ st: state, cur, ev } = await settled(state, cur, ev));   // the board as the search will see it: ELK's first draw laid out again until it stops moving
  report.startSettled = { cost: r4(ev.cost), X: ev.X, NE: ev.NE, Fx: ev.Fx, aspect: r4(ev.aspect) };
  lap('start');
  if (opts.promote && opts.margin == null) {   // the margin: what the layout's reshuffling moves C by, measured on this board
    const cands0 = candidates(model, layouter, cur, ev, state);
    report.noise = await measureNoise(model, layouter, state, cur, ev, cands0, mu, ext);
    margin = report.noise.margin; marginD = opts.margin == null ? Math.max(margin * (0.5 + model.dial.mess), model.dial.marginPills * mu) : margin;   // the measured noise, half of it at mess 0, one and a half times at 1
    report.margin = margin; report.marginKept = marginD;
    lap('noise');
  }
  ({ st: state, cur, ev } = await settle(state, cur, ev));   // the pills there already are (between boards, pinned): their hosts
  lap('settle');

  if (opts.promote) {
    // the popular nodes first, the most arrows first: each is moved whatever its trial measures
    layouter.phase = 'popular';
    const none = (opts.cap == null ? model.dial.capShare : opts.cap) <= 0;   // the dial all the way to 1: no move at all
    for (;;) {
      if (ev.good || none) break;   // a board that is good enough as it is, or has become so, is left: pills are for a mess
      const c = mostPopular(model, layouter, state);
      if (!c || c.arrows < (opts.popular == null ? model.dial.popular : opts.popular)) break;
      const trial = withMove(state, c);
      trial.hosts = layouter.assignHosts(trial, cur, moveGroups(layouter, trial, c));
      const layout = await layouter.layout(trial);
      const e2 = evaluate(model, layout, mu);
      const users = c.mode === 'out' ? fanTargets(model, c.node) : usersOf(model, layouter, c.node);
      const rec = {
        node: c.node, mode: c.mode, popular: true, arrows: c.arrows, board, before: r4(ev.cost), after: r4(e2.cost), gain: r4(1 - e2.cost / ev.cost), gainC: r4(ev.cost - e2.cost),
        users: users.map((u) => ({ user: u, frame: model.node(u).container === 'b:' + board ? null : model.node(u).container.slice(2) })).sort((a, b) => byTitle(a.user, b.user)),
        frames: [...new Set(users.map((u) => model.node(u).container))].sort().map((x) => (x === 'b:' + board ? null : x.slice(2))),
        was: { X: ev.X, NE: ev.NE, Fx: ev.Fx }, now: { X: e2.X, NE: e2.NE, Fx: e2.Fx },
      };
      ({ st: state, cur, ev } = await settled(trial, layout, e2));
      ({ st: state, cur, ev } = await settle(state, cur, ev));
      if (opts.split !== false && c.mode !== 'out') ({ st: state, cur, ev } = await splitMany(state, cur, ev, new Set([c.node])));
      rec.settled = r4(ev.cost);
      report.promotions.push(rec);
    }
    lap('popular');
    const capShare = opts.cap == null ? model.dial.capShare : opts.cap;
    const cap = capShare <= 0 ? 0 : Math.max(1, Math.floor(capShare * leaves.length));   // at least one, unless the dial is all the way to 1
    report.budget = { cap, leaves: leaves.length };
    report.candidatesTried = 0;
    for (;;) {
      if (ev.good) { report.stop = 'good-enough'; break; }
      const capped = state.order.filter((t) => !model.node(t).pin).length + state.fans.length >= cap;
      layouter.phase = 'trial';
      const cands = candidates(model, layouter, cur, ev, state);
      lap('candidates');
      if (!cands.length) { report.stop = 'no-candidates'; break; }
      // the best of the next K; if it does not beat the margin, the best of the K after that; if that does not either, stop
      let best = null, retried = false;
      const trials = [];
      report.ncands = cands.length;
      for (let round = 0; ; round++) {   // rounds of K candidates, until one clears the margin or the list is out
        const batch = cands.slice(round * K, (round + 1) * K);
        if (!batch.length) break;
        for (const c of batch) {
          report.candidatesTried++;
          const trial = withMove(state, c);
          const groups = moveGroups(layouter, trial, c);
          trial.hosts = layouter.assignHosts(trial, cur, groups);
          let layout = await layouter.layout(trial);
          let e2 = evaluate(model, layout, mu), tst = trial;
          const tsplits = [];
          if (opts.split !== false && c.mode !== 'out') ({ st: tst, cur: layout, ev: e2 } = await splitMany(trial, layout, e2, new Set([c.node]), true, tsplits));   // the promotion as it would stand once its pills are split
          if (opts.debug) opts.debug('trial ' + c.mode + ' ' + c.node + ' ' + Math.round(e2.cost) + ' vs ' + Math.round(ev.cost) + ' (' + c.users + ' users)');
          trials.push({ node: c.node, mode: c.mode, cost: r4(e2.cost), dCost: r4(e2.cost - ev.cost), dPill: r4(e2.pillTerm - ev.pillTerm), users: c.users });
          if (!best || e2.cost < best.ev.cost - 1e-9) best = { c, next: tst, layout, ev: e2, groups, tsplits };
        }
        lap('trials');
        if (best && best.ev.cost <= ev.cost - margin) break;
        if (round === 0) retried = true;
      }
      if (!best) { report.stop = 'no-candidates'; break; }
      // the search's gain, less the price of the pills it adds at the dial's mu instead of the search's
      const gainD = (ev.cost - best.ev.cost) - (muD - mu) * (best.ev.pillTerm - ev.pillTerm);
      if (!(gainD >= marginD - 1e-9)) {
        report.stop = 'little-gain';
        report.lastBest = { node: best.c.node, mode: best.c.mode, gain: r4(gainD), margin: marginD, trials };
        if (capped) report.safetyCap = { hit: false, cap, leaves: leaves.length, note: `reached the safety cap of ${cap} promotions, but the next one would not have paid` };
        break;
      }
      if (capped) {   // it would have paid: the cap, not the board, ended the loop
        report.stop = 'safety-cap';
        report.safetyCap = { hit: true, cap, leaves: leaves.length, wouldHaveGained: r4(1 - best.ev.cost / ev.cost), gainC: r4(ev.cost - best.ev.cost), next: best.c.node, note: `STOPPED BY THE SAFETY CAP of ${cap} promotions (${Math.round(100 * (opts.cap == null ? model.dial.capShare : opts.cap))}% of ${leaves.length} leaves): promoting ${best.c.node} next would still have cut the cost by ${Math.round(ev.cost - best.ev.cost)} (${Math.round(100 * (1 - best.ev.cost / ev.cost))}%)` };
        break;
      }
      // a promotion's users, or the shapes a fanned-out node's pills stand for
      const users = best.c.mode === 'out' ? fanTargets(model, best.c.node) : usersOf(model, layouter, best.c.node);
      const rec = {
        node: best.c.node, mode: best.c.mode, board, before: r4(ev.cost), after: r4(best.ev.cost), gain: r4(1 - best.ev.cost / ev.cost), gainC: r4(ev.cost - best.ev.cost), gainAtDial: r4(gainD), retried,
        users: users.map((u) => ({ user: u, frame: model.node(u).container === 'b:' + board ? null : model.node(u).container.slice(2) })).sort((a, b) => byTitle(a.user, b.user)),
        frames: [...new Set(users.map((u) => model.node(u).container))].sort().map((c) => (c === 'b:' + board ? null : c.slice(2))),
        was: { X: ev.X, NE: ev.NE, Fx: ev.Fx }, now: { X: best.ev.X, NE: best.ev.NE, Fx: best.ev.Fx },
      };
      for (const sp of best.tsplits) report.splits.push(sp);
      ({ st: state, cur, ev } = await settled(best.next, best.layout, best.ev));
      ({ st: state, cur, ev } = await settle(state, cur, ev));
      lap('settle');
      if (opts.split !== false && best.c.mode !== 'out') ({ st: state, cur, ev } = await splitMany(state, cur, ev, new Set([best.c.node])));
      lap('split');
      rec.settled = r4(ev.cost);
      report.promotions.push(rec);
    }
    // take back what does not pay for itself
    layouter.phase = 'demote';
    const popularMoves = new Set(report.promotions.filter((p) => p.popular).map((p) => p.mode + SEP + p.node));   // a popular node's move is not a judgment call: it stays
    const made = state.order.map((v) => ({ v, mode: 'in' })).concat(state.fans.map((v) => ({ v, mode: 'out' })));
    for (const { v, mode } of made.reverse()) {
      if ((mode === 'in' && model.node(v).pin) || popularMoves.has(mode + SEP + v)) continue;
      const next = withoutMove(state, v, mode);
      const layout = await layouter.layout(next);
      const e2 = evaluate(model, layout, mu);
      if (cm(e2) < cm(ev) - 1e-9) {
        report.demotions.push({ node: v, mode, board, before: r4(cm(ev)), after: r4(cm(e2)) });
        ({ st: state, cur, ev } = await settled(next, layout, e2));
      }
    }
    lap('demote');
    ({ st: state, cur, ev } = await settle(state, cur, ev));
    if (opts.split !== false) ({ st: state, cur, ev } = await splitMany(state, cur, ev, null));   // and every pill still far, whichever hub it is for
    lap('finish');
  } else report.stop = 'promote-off';

  // the search is done: the layout it ends on, with every container measured both ways (and from where it is), the whole kept only if it costs no more
  layouter.phase = 'final'; layouter.squeeze = true;
  report.searched = { cost: r4(ev.cost), X: ev.X, NE: ev.NE, Fx: ev.Fx, aspect: r4(ev.aspect) };
  // the layout the search ends on, laid out once more with the air squeezed out where the dial says it is worth it, from where it is (warm) and afresh (cold); the cheaper kept
  layouter.setAnchors(cur); layouter.warm = true;
  const finW = await layouter.layout(state), evW = evaluate(model, finW, mu);
  layouter.warm = false;
  const finC = await layouter.layout(state), evC = evaluate(model, finC, mu);
  report.finalWarm = { cost: r4(evW.cost), X: evW.X, NE: evW.NE, Fx: evW.Fx, aspect: r4(evW.aspect) };
  report.finalCold = { cost: r4(evC.cost), X: evC.X, NE: evC.NE, Fx: evC.Fx, aspect: r4(evC.aspect) };
  // the cheaper of the two, what each one's shape costs counted in (cost.mjs's shapeCost: how far the board is from the view's shape)
  const whole = (e) => e.cost + e.shape;
  if (whole(evC) < whole(evW) - 1e-9) { cur = finC; ev = evC; report.final = 'cold'; } else { cur = finW; ev = evW; report.final = 'warm'; }
  // ... and the board itself laid out each way a container can be (its arrows down and across, stress as it comes and stretched to the view's shape), each measured
  // as the whole board is, arrows over pills and all: what a container's own cost chose between them is a guess at this
  report.finalWays = {};
  // (only a container laid out layered or stress has the four ways: ranked children run the way they run, a tree or boxes with no arrows have one layout)
  const rootWay = (l) => { const r = l.raws.get(layouter.rootCid); return r.algo === 'layered' ? (r.dir === 'RIGHT' ? 'across' : 'layered') : r.algo === 'stress' ? (r.k && r.k !== 1 ? 'stretched' : 'stress') : null; };
  for (const way of rootWay(cur) ? ['layered', 'across', 'stress', 'stretched'] : []) {
    layouter.force = new Map([[layouter.rootCid, way]]);
    const finF = await layouter.layout(state), evF = evaluate(model, finF, mu);
    layouter.force = null;
    if (rootWay(finF) !== way) continue;   // a way there is none of here (a stress layout already the shape has no stretched one)
    report.finalWays[way] = { cost: r4(evF.cost), shape: r4(evF.shape), X: evF.X, NE: evF.NE, aspect: r4(evF.aspect) };
    if (whole(evF) < whole(ev) - 1e-9) { cur = finF; ev = evF; report.final = way; }
  }
  // a board further from the view's shape than the dial's good enough (aspect 2 + 2 mess: that many times too tall for it, or too wide): laid out once more with the air squeezed out and the frames in rows whatever it costs the arrows,
  // and kept if it is within the aspect and costs C no more than 10% more than the tall one (the tidy end is where a pile of frames in a column hides the big picture)
  if (ev.aspect > model.dial.good.aspect && layouter.opts.pack !== 'off') {
    const pack0 = layouter.opts.pack; layouter.opts.pack = 'squeeze';
    let taken = null;
    report.finalSqueeze = { taken: false, tries: [] };
    for (const warm of [false, true]) {   // afresh, then from where the board is (the same packing from the settled positions)
      if (warm) layouter.setAnchors(cur);
      layouter.warm = warm;
      const finS = await layouter.layout(state), evS = evaluate(model, finS, mu);
      report.finalSqueeze.tries.push({ warm, cost: r4(evS.cost), aspect: r4(evS.aspect), hw: r4(evS.hw) });
      if (evS.aspect <= model.dial.good.aspect && evS.cost <= ev.cost * 1.1 && (!taken || evS.cost < taken.ev.cost)) taken = { fin: finS, ev: evS };
    }
    layouter.opts.pack = pack0;
    if (!taken && ev.aspect > model.dial.good.aspect && evC.aspect <= model.dial.good.aspect && evC.cost <= ev.cost * 1.5) { taken = { fin: finC, ev: evC }; report.finalSqueeze.fallback = 'cold'; }   // nothing squeezed fits: ELK's fresh draw, if it does and costs C no more than half again (the dial's aspect is its own good enough)
    if (taken) { cur = taken.fin; ev = taken.ev; report.final = report.finalSqueeze.fallback || 'squeeze'; report.finalSqueeze.taken = true; }
  }
  // no arrow longer than the dial allows: each that is (a plain one, or one into a pill others share) is set apart as a pill of its own
  // beside its start, and the board laid out again from where it is, until none is left (a pill changes its start's box, so a few passes;
  // each pass sets at least one more edge apart, so there are never more passes than edges)
  report.long = [];
  layouter.hold = true;
  if (opts.promote && (opts.cap == null ? model.dial.capShare : opts.cap) > 0) {
    for (let pass = 0; pass <= model.edges.length; pass++) {
      const long = tooLong(model, cur, ev, model.dial.longest).filter((x) => !state.apart.has(x.key));
      if (!long.length) break;
      state = ext(state, { apart: new Set([...state.apart, ...long.map((x) => x.key)]) });
      for (const x of long) report.long.push({ from: x.from, to: x.to, length: x.length, shared: x.shared });
      layouter.setAnchors(cur); layouter.warm = true;
      cur = await layouter.layout(state); ev = evaluate(model, cur, mu);
    }
    report.longLeft = tooLong(model, cur, ev, model.dial.longest).length;
  }
  layouter.hold = false;
  lap('final');
  return done();
}

/** The arrows of a layout longer than `max` that may be set apart: plain ones, and those into a pill others share. [{key, from, to, length, shared}] */
export function tooLong(model, layout, ev, max) {
  const plan = layout.plan, out = [];
  const edges = plan.direct.map((e) => ({ e, shared: false })).concat(plan.members.map((m) => ({ e: m.e, shared: true })));   // evaluate's order
  const wide = Math.sqrt(Math.min(2, Math.max(0.5, layout.shape ? layout.shape.aspect : 1)));
  edges.forEach(({ e, shared }, i) => {
    const seg = ev.segs[i];
    if (!seg || !mayBeApart(model, e)) return;
    // as the view sees it: a view wider than it is tall shows more of an arrow that runs across than of one that runs down
    const length = segLength(seg), seen = Math.hypot((seg.x2 - seg.x1) / wide, (seg.y2 - seg.y1) * wide);
    if (seen > max) out.push({ key: e.from + SEP + e.to, from: e.from, to: e.to, length: Math.round(length), shared });
  });
  return out;
}

/** Shared groups of 4 or more users, biggest first, with how far their arrows to the pill are (longest, and how many cross something). Returns [{group, farthest, crossing}]. */
function splitCandidates(layouter, st, layout, ev) {
  const plan = layout.plan, out = [];
  const byKey = new Map();
  plan.members.forEach((m, i) => {
    const idx = plan.direct.length + i, seg = ev.segs[idx];
    if (!seg) return;
    let r = byKey.get(m.key); if (!r) byKey.set(m.key, r = { farthest: 0, crossing: 0, n: 0 });
    r.n++; r.farthest = Math.max(r.farthest, segLength(seg)); if (ev.per[idx] && ev.per[idx].ne > 0) r.crossing++;
  });
  for (const g of plan.groups) {
    if (!g.shared || g.edges.length < 4) continue;
    const r = byKey.get(g.key) || { farthest: 0, crossing: 0 };
    out.push({ group: g, farthest: r.farthest, crossing: r.crossing });
  }
  return out.sort((a, b) => b.group.edges.length - a.group.edges.length || b.farthest - a.farthest || byTitle(a.group.key, b.group.key));
}

/** The users in exactly k clusters (fewer if there are fewer users): complete linkage, merging the closest pair until k are left. Each cluster sorted, clusters by first title. */
export function clusterK(layout, users, k) {
  const c = users.map((u) => { const b = layout.boxes.get(u); return { u, x: b.x + b.w / 2, y: b.y + b.h / 2 }; });
  const cl = c.map((p) => [p]);
  const dist = (p, q) => Math.hypot(p.x - q.x, p.y - q.y);
  while (cl.length > k) {
    let bi = -1, bj = -1, bd = Infinity;
    for (let i = 0; i < cl.length; i++) for (let j = i + 1; j < cl.length; j++) {
      let d = 0; for (const p of cl[i]) for (const q of cl[j]) d = Math.max(d, dist(p, q));
      if (d < bd - 1e-9) { bd = d; bi = i; bj = j; }
    }
    cl[bi] = cl[bi].concat(cl[bj]); cl.splice(bj, 1);
  }
  return cl.map((g) => g.map((p) => p.u).sort(byTitle)).sort((a, b) => byTitle(a[0], b[0]));
}

/** The arrows a move on v would turn into pills, each way: those pointing at it that are still arrows, and those leaving it. */
export function arrowsAt(model, layouter, state, v) {
  const fanned = state.fanned || new Set();
  const n = model.node(v);
  const into = n.never || state.promoted.has(v) ? 0
    : (model.inn.get(v) || []).filter((e) => !e.cross && !e.via && !e.direct && model.node(e.from).board === layouter.board && !fanned.has(e.from)).length;
  const out = fanned.has(v) ? 0
    : (model.out.get(v) || []).filter((e) => fansOut(model, e) && model.node(e.to).board === layouter.board && !state.promoted.has(e.to)).length;
  return { into, out };
}

/** The most popular node left and its move: the most arrows a move would turn into pills; on a tie the first node by title, and for one node pointing at it before leaving it. Null when no arrow is left. */
export function mostPopular(model, layouter, state) {
  let best = null;
  for (const n of layouter.leaves) {
    const a = arrowsAt(model, layouter, state, n.title);
    for (const c of [{ node: n.title, mode: 'in', arrows: a.into }, { node: n.title, mode: 'out', arrows: a.out }]) {
      if (c.arrows > 0 && (!best || c.arrows > best.arrows)) best = c;
    }
  }
  return best;
}

/**
 * Eligible moves, best first: a node many point at to promote ('in'), a node that points at many to fan out ('out'), each scored
 * the same way round: its arrows x spread x (1 - tie), scaled by how badly those arrows do. The tie is only here.
 */
export function candidates(model, layouter, layout, ev, state) {
  const ranks = ranksOf(layout);
  const out = [];
  const edgeIndex = new Map(layout.plan.direct.map((e, i) => [e.from + SEP + e.to, i]));
  const badOf = (edges) => { let bad = 0; for (const e of edges) { const i = edgeIndex.get(e.from + SEP + e.to); if (i != null && ev.per[i]) bad += ev.per[i].x + ev.per[i].ne + ev.per[i].fx; } return bad; };
  const fanned = state.fanned || new Set();
  for (const n of layouter.leaves) {
    const v = n.title;
    if (fanned.has(v)) continue;
    // its uses that are still arrows, each to become a pill beside it
    const outgoing = (model.out.get(v) || []).filter((e) => !e.cross && model.node(e.to).board === layouter.board);
    const uses = outgoing.filter((e) => fansOut(model, e) && !state.promoted.has(e.to));
    if (uses.length >= 2) {
      const tie = outgoing.filter((e) => model.hasEdge(e.to, v)).length / Math.max(1, outgoing.length);
      const frames = new Set(uses.map((e) => model.node(e.to).container)).size;
      const rs = new Set(uses.map((e) => ranks.get(e.to))).size;
      const spread = (frames + rs) / (2 * uses.length);
      out.push({ node: v, mode: 'out', score: outgoing.length * spread * (1 - tie) * (1 + badOf(uses)), users: uses.length });
    }
  }
  for (const n of layouter.leaves) {
    const v = n.title;
    if (state.promoted.has(v) || n.never) continue;
    const incoming = (model.inn.get(v) || []).filter((e) => !e.cross && model.node(e.from).board === layouter.board);
    const users = usersOf(model, layouter, v);
    if (users.length < 2 && !(users.length === 1 && model.node(users[0]).container !== n.container)) continue;   // two users, or one in another container
    const tie = incoming.filter((e) => model.hasEdge(v, e.from)).length / Math.max(1, incoming.length);
    const frames = new Set(users.map((u) => model.node(u).container)).size;
    const rs = new Set(users.map((u) => ranks.get(u))).size;
    const spread = (frames + rs) / (2 * users.length);
    out.push({ node: v, mode: 'in', score: incoming.length * spread * (1 - tie) * (1 + badOf(incoming)), users: users.length });
  }
  return out.sort((a, b) => b.score - a.score || byTitle(a.node, b.node) || byTitle(a.mode, b.mode));
}
