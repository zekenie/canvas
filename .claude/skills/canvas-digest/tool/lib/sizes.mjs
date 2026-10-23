// What the tool needs measured: the draw script `canvas measure` reads, and the sizes read back from its JSON.
import { q, lit, byTitle, label } from './util.mjs';
import { written, BOARD } from './names.mjs';
import { LEAF_KINDS } from './model.mjs';
import { noteTyping, arrowTyping } from './types.mjs';

export const NOTE_W = 300;
export const TITLE_PILL = (title) => 27 + 10.2 * title.length;   // the title pill above a frame (an estimate; a frame is never narrower than its title)

/** What the tool assumes until a measurement says otherwise: draw's own numbers, which `constants` of the measure JSON replace. */
export const DEFAULT_CONSTANTS = { pillHeight: 32, pillStep: 16, pillGap: 80, frameInset: 40, tightGap: 40, frameMin: { w: 96, h: 64 } };

/** A note's width: 300, or wider for a long title, with room for a Public chip. */
export function noteWidth(title) {
  const need = 27 + 10.2 * title.length + 8 + 75 + 16;
  return Math.max(NOTE_W, Math.ceil(need / 20) * 20);
}

/** The shapes to measure: [{key, title, kind, w, text}] in a fixed order (by key); a note that is a type or is one also says what it is (`typing`, as draw is told it). */
export function toMeasure(model) {
  const items = [];
  for (const n of model.nodes.values()) {
    if (!LEAF_KINDS.has(n.kind)) continue;
    items.push(n.kind === 'subboard' ? { key: n.key, title: n.title, kind: 'subboard' } : { key: n.key, title: n.title, kind: 'sticky-note', w: noteWidth(n.title), text: n.text, typing: noteTyping(n), node: n });
  }
  return items.sort((a, b) => byTitle(a.key, b.key));
}

/** The ends a pill may be drawn for: every shape something points at (an end of a relationship type is never a pill: it is drawn between its two types). */
export function pillTargets(model) {
  return [...model.nodes.values()].filter((n) => LEAF_KINDS.has(n.kind) && !n.never && (model.inn.get(n.key) || []).some((e) => !e.end)).map((n) => n.key).sort(byTitle);
}

/**
 * A draw script for `canvas measure -`, and where each thing in it is: {text, shapeAt, pillAt} (the line of each shape's statement, by key, and the
 * key each edge through a reference is for, by line). It has every note and card (a type with its schema and the types it builds on, a note with
 * the types it is and its values), then the ends of the relationship types and every typed arrow between notes (a type's note grows a row for each
 * end it has and those of what it builds on, and so does a note of it, and `measure` lays the script's notes out against the script's own types and
 * ends, whatever board each is on), then one edge through a reference to each end a pill may be drawn for. Placements are ignored by measure, and so
 * is the container a path leads through; a title that more than one node has is written as the path of the node, which measure keeps as a shape of
 * its own (two statements of one title with different paths are two shapes).
 */
export function measurePlan(model) {
  const items = toMeasure(model);
  const lines = [], shapeAt = new Map(), pillAt = new Map();
  const count = new Map();
  for (const n of model.nodes.values()) count.set(n.title, (count.get(n.title) || 0) + 1);
  const name = (key) => {
    const n = model.node(key);
    return count.get(n.title) === 1 ? q(n.title) : written((n.chain.length ? [] : [BOARD]).concat(n.chain.map((c) => model.node(c).title), [n.title]));
  };
  const stmt = (it, place) => it.kind === 'subboard'
    ? `subboard ${name(it.key)}${place}`
    : `sticky-note ${name(it.key)}${place} size: ${it.w}x` + (it.text ? ` text: ${lit(it.text)}` : '') + (it.typing || '');
  items.forEach((it, i) => { lines.push(stmt(it, i ? ` below ${name(items[0].key)}` : '')); shapeAt.set(it.key, lines.length); });
  const leaves = items.map((it) => it.key);
  const note = (t) => { const n = model.node(t); return n && n.kind === 'sticky-note'; };
  for (const e of model.edges) {
    if (!note(e.from) || !note(e.to)) continue;
    for (const a of e.arrows) if (e.end || a.is.length) lines.push(`edge ${name(e.from)} -> ${name(e.to)}` + (a.text ? ` text: ${lit(a.text)}` : '') + arrowTyping(a));
  }
  for (const t of pillTargets(model)) {
    const from = leaves.find((x) => x !== t);
    if (from) { lines.push(`edge ${name(from)} -> ${name(t)} via: reference`); pillAt.set(lines.length, t); }
  }
  return { text: lines.join('\n') + '\n', shapeAt, pillAt };
}

export const measureScript = (model) => measurePlan(model).text;

/** The sizes the layout uses, from `canvas measure`'s JSON: {shapes: {key: {w, h, above}}, pillWidth: {key}, constants}. Its rows are read by their line (see measurePlan). */
export function sizesFrom(model, measure) {
  const at = measurePlan(model);
  const keyOfLine = new Map([...at.shapeAt].map(([key, line]) => [line, key]));
  const shapes = {};
  for (const r of measure.shapes || []) { const key = keyOfLine.get(r.line); if (key != null) shapes[key] = { w: r.size[0], h: r.size[1], above: r.above || 0 }; }
  const missing = toMeasure(model).filter((it) => !shapes[it.key]).map((it) => label(it.key));
  if (missing.length) throw new Error('the measurement has no size for: ' + missing.slice(0, 10).join(', '));
  const pillWidth = {};
  let pillHeight = null;
  for (const r of measure.references || []) { const key = at.pillAt.get(r.line); if (key == null) continue; pillWidth[key] = r.size[0]; if (pillHeight == null) pillHeight = r.size[1]; }
  const lacking = pillTargets(model).filter((t) => pillWidth[t] == null);
  if (lacking.length && (measure.references || []).length) throw new Error('the measurement has no pill for: ' + lacking.slice(0, 10).map(label).join(', '));
  const c = measure.constants || {};
  const gaps = c.gaps || {};
  const constants = {
    pillHeight: pillHeight == null ? DEFAULT_CONSTANTS.pillHeight : pillHeight,
    pillStep: c.referenceStep == null ? DEFAULT_CONSTANTS.pillStep : c.referenceStep,
    pillGap: c.defaultGap != null ? c.defaultGap : gaps.normal != null ? gaps.normal : DEFAULT_CONSTANTS.pillGap,   // a pill sits a default gap from its start
    frameInset: c.frameInset == null ? DEFAULT_CONSTANTS.frameInset : c.frameInset,
    tightGap: gaps.tight != null ? gaps.tight : DEFAULT_CONSTANTS.tightGap,
    frameMin: c.smallest && c.smallest.frame ? { w: c.smallest.frame[0], h: c.smallest.frame[1] } : DEFAULT_CONSTANTS.frameMin,
  };
  return { shapes, pillWidth, constants };
}
