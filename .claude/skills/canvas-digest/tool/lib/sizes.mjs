// What the layout reads of `canvas measure`'s answer for a document (measure.json): every node's size by key, the width of the title over a
// frame, the pills by (the end it stands for, the container its start is in) and the constants.
import { holdsShapes } from './model.mjs';

/** What the tool assumes until a measurement says otherwise: draw's own numbers, which `constants` of the measure JSON replace. */
export const DEFAULT_CONSTANTS = { pillHeight: 40, pillStep: 16, pillGap: 80, frameInset: 40, tightGap: 40, frameMin: { w: 96, h: 64 } };

/** The id of a container as the layout has it: `f:<frame key>`, `b:<subboard key>`, `b:root`. A pill's `from` is the key of its container, null for the top of the board. */
export const containerId = (model, key) => (key == null ? 'b:root' : (model.node(key) && holdsShapes(model.node(key)) ? 'f:' : 'b:') + key);

/** The key of the width of a pill for `target` beside a start in `container` (a node's `container`: 'f:<frame>' or 'b:<board>'). */
export const pillKey = (target, container) => target + '\u0000' + container;

/** The smallest a shape that holds shapes is drawn, by kind (measure's `smallest`): the first kind by name that holds shapes; null for none said. */
function smallestHolder(model, smallest) {
  const kind = [...model.kinds.values()].filter((k) => k.holds === 'shapes').map((k) => k.kind).sort()[0];
  const s = kind && smallest && smallest[kind];
  return s ? { w: s[0], h: s[1] } : null;
}

/**
 * The sizes the layout uses, from `canvas measure`'s JSON for the document: {shapes: {key: {w, h, above}} for every node that holds no shapes,
 * frames: {key: {min: {w, h}|null, titleWidth}} for the rest, pillWidth: {pillKey: w}, constants}.
 */
export function sizesFrom(model, measure) {
  const nodes = (measure && measure.nodes) || {};
  const shapes = {}, frames = {};
  const missing = [];
  for (const n of model.nodes.values()) {
    const m = nodes[n.key];
    if (holdsShapes(n)) {
      frames[n.key] = { min: m && m.size ? { w: m.size[0], h: m.size[1] } : null, titleWidth: (m && m.titleWidth) || 0 };
      continue;
    }
    if (!m || !m.size) { missing.push(n.key); continue; }
    shapes[n.key] = { w: m.size[0], h: m.size[1], above: m.above || 0 };
  }
  if (missing.length) throw new Error('the measurement has no size for: ' + missing.slice(0, 10).join(', ') + (missing.length > 10 ? ` and ${missing.length - 10} more` : '') + '; measure again');
  const pillWidth = {};
  let pillHeight = null;
  for (const p of (measure && measure.pills) || []) {
    if (!model.node(p.for) || (p.from != null && !model.node(p.from))) continue;
    pillWidth[pillKey(p.for, containerId(model, p.from))] = p.size[0];
    if (pillHeight == null) pillHeight = p.size[1];
  }
  const c = (measure && measure.constants) || {};
  const gaps = c.gaps || {};
  const constants = {
    pillHeight: pillHeight == null ? DEFAULT_CONSTANTS.pillHeight : pillHeight,
    pillStep: c.referenceStep == null ? DEFAULT_CONSTANTS.pillStep : c.referenceStep,
    pillGap: c.defaultGap != null ? c.defaultGap : gaps.normal != null ? gaps.normal : DEFAULT_CONSTANTS.pillGap,   // a pill sits a default gap from its start
    frameInset: c.frameInset == null ? DEFAULT_CONSTANTS.frameInset : c.frameInset,
    tightGap: gaps.tight != null ? gaps.tight : DEFAULT_CONSTANTS.tightGap,
    frameMin: smallestHolder(model, c.smallest) || DEFAULT_CONSTANTS.frameMin,
  };
  return { shapes, frames, pillWidth, constants };
}

/** The edges the app would refuse to draw between their ends, from measure's answer: a Map from an edge's place in the document's list to {reason, message, hint}. */
export function refusedEdges(measure) {
  const out = new Map();
  for (const e of (measure && measure.edges) || []) if (e && e.refused && Number.isInteger(e.edge)) out.set(e.edge, e.refused);
  return out;
}
