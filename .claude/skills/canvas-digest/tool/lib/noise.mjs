// How far C moves when containers are laid out again and nothing that matters has changed: the margin a gain has to beat.
// For each of the best candidates, the containers its promotion would touch are laid out again, `draws` times, from where they are
// with their boxes' widths nudged by 4 to 20 units (a promotion's pill column changes a box's width by 100 to 300, so this is a
// small change); the rest of the board is as it was. The spread of the change in C is the layout's reshuffling noise.
import { evaluate } from './cost.mjs';

export const NOISE_SIGMAS = 3, MIN_MARGIN_PILLS = 2;   // the floor at mess 0.5; the dial sets it (model.dial.marginPills)

/**
 * state, cur (its layout), ev: the settled board. cands: the candidates in order (prefilter score). Returns
 * {n, mean, sd, dropP95, max, margin, pills, candidates, draws}; margin = NOISE_SIGMAS sd, up to a whole number of pills (at least two).
 */
export async function measureNoise(model, layouter, state, cur, ev, cands, mu, ext, nC = 8, draws = 4) {
  const ds = [];
  const was = { warm: layouter.warm, phase: layouter.phase };
  layouter.warm = true; layouter.phase = 'noise';
  for (const c of cands.slice(0, nC)) {
    const trial = ext(state, { promoted: new Set(state.promoted).add(c.node), order: state.order.concat([c.node]) });
    const keys = new Set(layouter.pillPlan(trial).groups.filter((g) => g.target === c.node).map((g) => g.key));
    trial.hosts = layouter.assignHosts(trial, cur, keys);
    layouter.missLog = [];
    await layouter.layout(trial);
    const touched = layouter.missLog.slice(); layouter.missLog = null;
    for (let s = 1; s <= draws; s++) {
      layouter.seedMap = new Map(touched.map((t) => [t, s]));
      layouter.nudge = (cid) => (layouter.seedMap && layouter.seedMap.has(cid) ? 4 : 0);
      const l = await layouter.layout(state);
      ds.push(evaluate(model, l, mu).cost - ev.cost);
    }
    layouter.seedMap = null; layouter.nudge = null;
  }
  layouter.warm = was.warm; layouter.phase = was.phase;
  const n = ds.length;
  if (!n) return { n: 0, mean: 0, sd: 0, dropP95: 0, max: 0, margin: MIN_MARGIN_PILLS * mu, pills: MIN_MARGIN_PILLS, candidates: 0, draws };
  const mean = ds.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(ds.reduce((a, b) => a + (b - mean) * (b - mean), 0) / n);
  const drops = ds.map((x) => -x).sort((a, b) => a - b);
  const minPills = MIN_MARGIN_PILLS;   // measured at the reference price of a pill, whatever the dial says: the loop's candidates do not depend on mess
  const pills = Math.max(minPills, Math.ceil(NOISE_SIGMAS * sd / mu));
  return { n, mean: Math.round(mean * 10) / 10, sd: Math.round(sd * 10) / 10, dropP95: Math.round(drops[Math.min(n - 1, Math.floor(0.95 * n))]), max: Math.round(Math.max.apply(null, ds.map(Math.abs))), margin: pills * mu, pills, candidates: Math.min(nC, cands.length), draws };
}
