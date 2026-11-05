// A stand-in for `canvas measure`, for tests that run without the app: the JSON it would give, with sizes estimated.
import { toMeasure, measurePlan, DEFAULT_CONSTANTS } from '../lib/sizes.mjs';

/**
 * What a pill keyed by measurePlan says beside its name: for a key that says where it sits (`pillKey`), the titles of the containers its end is in that
 * the pill isn't in too, outermost first, as the app works it out; nothing for a node's key alone.
 */
export function placeOf(model, key) {
  const [t, c] = key.split('\u0000');
  if (c == null) return '';
  const seat = c === 'b:root' ? [] : model.node(c.slice(2)).chain.concat([c.slice(2)]), above = model.node(t).chain;
  let k = 0;
  while (k < seat.length && k < above.length && seat[k] === above[k]) k++;
  return above.slice(k).map((x) => model.node(x).title).join(' › ');
}

/** How wide the app makes a pill that says this, with where its shape is beside it: 64..280. */
export const pillEstimate = (title, place) => Math.min(280, Math.max(64, Math.ceil(10 + 16 + 6 + 7.3 * title.length + (place ? 6 + 7.3 * place.length : 0) + 17 + 14)));

/**
 * A note is as tall as its text needs, at least 200 (the app measures the real height); a pill's width is its label's and its place's, 64..280.
 */
export function estimateMeasure(model) {
  const shapes = [], references = [];
  const at = measurePlan(model);   // the line of each statement in the script `canvas measure` is given: its rows are read by line
  for (const it of toMeasure(model)) {
    const line = at.shapeAt.get(it.key);
    if (it.kind === 'subboard') { shapes.push({ line, title: it.title, kind: 'subboard', size: [240, 160], above: 30 }); continue; }
    const perLine = Math.max(10, Math.floor((it.w - 40) / 7.4));
    const lines = (it.text || '').split('\n').reduce((s, l) => s + Math.max(1, Math.ceil(l.length / perLine)), 0);
    let h = Math.max(200, 40 + lines * 22), w = it.w;
    const n = it.node;
    if (n && n.schema && n.relationship) {
      // a relationship type is drawn as a pill: its name, and how many fields it has after a dot (`fills · 1`), as `canvas measure` answers
      const fields = Object.keys((n.schema && n.schema.properties) || {}).length;
      shapes.push({ line, title: it.title, kind: 'sticky-note', size: [Math.round(28 + 7 * it.title.length + (fields ? 16 : 0)), 24], above: 0 });
      continue;
    }
    if (n && (n.schema || n.is.length)) {
      // a type, or a note of one: as wide as it is drawn (rows never widen a note), a row for each field, and one for each end
      // its types have (the app's rows, roughly)
      const types = n.schema ? (n.relationship ? [] : [n]) : n.is.map((t) => model.types.get(t)).filter(Boolean);
      const fields = new Set(), ends = new Set();
      for (const t of types) {
        Object.keys((t.schema && t.schema.properties) || {}).forEach((k) => fields.add(k));
        model.edges.forEach((e) => { if (e.end && (e.from === t.key || e.to === t.key)) ends.add(e.from + '>' + e.to); });
      }
      h = Math.max(h, 56 + 22 * (fields.size + ends.size) + (ends.size ? 8 : 0));
    }
    shapes.push({ line, title: it.title, kind: 'sticky-note', size: [w, h], above: 30 });
  }
  for (const [line, key] of at.pillAt) {
    const title = model.node(key.split('\u0000')[0]).title;
    references.push({ line, for: title, size: [pillEstimate(title, placeOf(model, key)), DEFAULT_CONSTANTS.pillHeight] });
  }
  return {
    shapes, references,
    constants: { gaps: { none: 0, tight: 40, normal: 80, wide: 160 }, defaultGap: 80, listStep: 16, referenceStep: DEFAULT_CONSTANTS.pillStep, frameInset: DEFAULT_CONSTANTS.frameInset, smallest: { frame: [96, 64] } },
  };
}
