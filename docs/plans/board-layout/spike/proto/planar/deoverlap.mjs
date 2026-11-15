// Pills on top of something, moved: each pill that overlaps another pill, a note or its title tab, or a frame it isn't in, goes to the
// nearest spot by its note where it overlaps nothing, its line passes over nothing and crosses no line, and no line passes over it (the fan
// search, fan.mjs, for just those pills). One that has no such spot stays where it was. -> { layout, moved, left }
import { fanPills } from './fan.mjs';
import { overlaps, TAB } from './overlaps.mjs';
const hit = (a, b) => a.x < b.x + b.w - 1 && b.x < a.x + a.w - 1 && a.y < b.y + b.h - 1 && b.y < a.y + a.h - 1;
export function deoverlap(m, board, layout) {
  const notes = Object.entries(layout.boxes).filter(([k]) => !m.node(k).isFrame);
  const bad = new Set();
  const P = layout.pills;
  for (let i = 0; i < P.length; i++) {
    for (let j = i + 1; j < P.length; j++) if (hit(P[i], P[j])) { bad.add(P[i].id); bad.add(P[j].id); }
    for (const [, b] of notes) if (hit(P[i], { x: b.x, y: b.y - TAB, w: b.w, h: b.h + TAB })) bad.add(P[i].id);
  }
  if (!bad.size) return { layout, moved: 0, left: 0 };
  // both pills of a pair are lifted, so either may find the clean spot; a wider reach than the fan's
  const f = fanPills(m, board, layout, { only: bad, maxRadius: 1800 });
  const left = overlaps(m, board, f.layout);
  return { layout: f.layout, moved: f.fanned, left: left.pillPill + left.pillNote + left.pillTab };
}
