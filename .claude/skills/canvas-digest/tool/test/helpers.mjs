// A stand-in for `canvas measure`, for tests that run without the app: the JSON it would give, with sizes estimated.
import { toMeasure, pillTargets, DEFAULT_CONSTANTS } from '../lib/sizes.mjs';

/** A note is as tall as its text needs, at least 200 (the app measures the real height); a pill's width is its label's, 64..280. */
export function estimateMeasure(model) {
  const shapes = [], references = [];
  let line = 0;
  for (const it of toMeasure(model)) {
    line++;
    if (it.kind === 'subboard') { shapes.push({ line, title: it.title, kind: 'subboard', size: [240, 160], above: 30 }); continue; }
    const perLine = Math.max(10, Math.floor((it.w - 40) / 7.4));
    const lines = (it.text || '').split('\n').reduce((s, l) => s + Math.max(1, Math.ceil(l.length / perLine)), 0);
    shapes.push({ line, title: it.title, kind: 'sticky-note', size: [it.w, Math.max(200, 40 + lines * 22)], above: 30 });
  }
  for (const t of pillTargets(model)) { line++; references.push({ line, for: t, size: [Math.min(280, Math.max(64, Math.ceil(10 + 16 + 6 + 7.3 * t.length + 17 + 14))), DEFAULT_CONSTANTS.pillHeight] }); }
  return {
    shapes, references,
    constants: { gaps: { none: 0, tight: 40, normal: 80, wide: 160 }, defaultGap: 80, listStep: 16, referenceStep: DEFAULT_CONSTANTS.pillStep, frameInset: DEFAULT_CONSTANTS.frameInset, smallest: { frame: [96, 64] } },
  };
}
