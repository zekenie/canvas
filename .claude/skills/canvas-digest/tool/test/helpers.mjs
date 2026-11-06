// A stand-in for `canvas measure`, for tests that run without the app: the JSON it would answer for a graph document, with sizes estimated.
// (Test code: it reads `props` to guess how big the app would draw a note. The tool never does.)
import { DEFAULT_CONSTANTS } from '../lib/sizes.mjs';

const titleOf = (n) => (n.props && typeof n.props.title === 'string' ? n.props.title : n.key);

/** A note's width: 300, or wider for a long title, with room for a chip. */
export function noteWidth(title) {
  const need = 27 + 10.2 * title.length + 8 + 75 + 16;
  return Math.max(300, Math.ceil(need / 20) * 20);
}

/** How wide the app makes a pill that says this, with where its shape is beside it: 64..280. */
export const pillEstimate = (title, place) => Math.min(280, Math.max(64, Math.ceil(10 + 16 + 6 + 7.3 * title.length + (place ? 6 + 7.3 * place.length : 0) + 17 + 14)));

/**
 * The answer `canvas measure` gives for `graph`, over `model` (buildModel's): a note is as tall as its text needs, at least 200; a card is 240 x 160; a
 * frame's entry is its smallest, with the width of its title; a pill's width is its label's and its place's, 64..280, for each end of each edge a pill can stand
 * for, from the container the other end is in. `refused` is a list of {edge, from, to, refused} to answer as edges the app would not draw.
 */
export function estimateMeasure(model, graph, refused) {
  const nodes = {};
  for (const raw of graph.nodes) {
    const n = model.node(raw.key), title = titleOf(raw);
    if (n.holds === 'shapes') { nodes[n.key] = { size: [96, 64], above: 9, titleWidth: Math.ceil(27 + 10.2 * title.length) }; continue; }
    if (n.holds === 'board') { nodes[n.key] = { size: [240, 160], above: 30, titleWidth: 0 }; continue; }
    const text = (raw.props && typeof raw.props.text === 'string' ? raw.props.text : '') || '';
    const w = noteWidth(title);
    const perLine = Math.max(10, Math.floor((w - 40) / 7.4));
    const lines = text.split('\n').reduce((s, l) => s + Math.max(1, Math.ceil(l.length / perLine)), 0);
    nodes[n.key] = { size: [w, Math.max(200, 40 + lines * 22)], above: 30, titleWidth: 0 };
  }
  const pills = [], seen = new Set();
  for (const e of graph.edges || []) {
    for (const [end, other] of [[e.to, e.from], [e.from, e.to]]) {
      const target = model.node(end), near = model.node(other);
      if (!target || !near || target.holds === 'shapes' || !model.kinds.get(target.kind).via.length) continue;
      const from = near.parent || null, key = end + '\u0000' + from;
      if (seen.has(key)) continue;
      seen.add(key);
      const byTitle = graph.nodes.find((x) => x.key === end);
      pills.push({ for: end, from, size: [pillEstimate(titleOf(byTitle), from ? 'x' : ''), DEFAULT_CONSTANTS.pillHeight] });
    }
  }
  return {
    nodes, pills, edges: refused || [], warnings: [],
    constants: { gaps: { none: 0, tight: 40, normal: 80, wide: 160 }, defaultGap: 80, listStep: 16, referenceStep: DEFAULT_CONSTANTS.pillStep, frameInset: DEFAULT_CONSTANTS.frameInset, smallest: { frame: [96, 64] } },
  };
}
