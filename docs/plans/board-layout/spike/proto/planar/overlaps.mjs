// Shapes on top of each other in a layout: pill on pill, pill on a note or its title tab, note on note, a loose note or pill on a frame.
//   overlaps(m, board, layout) -> { pillPill, pillNote, pillTab, noteNote, onFrame, examples }
export const TAB = 28;
const hit = (a, b, g = 0) => a.x < b.x + b.w - g && b.x < a.x + a.w - g && a.y < b.y + b.h - g && b.y < a.y + a.h - g;
export function overlaps(m, board, L) {
  const userOf = new Map(); for (const a of L.arrows) if (!userOf.has(a.to)) userOf.set(a.to, a.from);
  const notes = Object.entries(L.boxes).filter(([k]) => !m.node(k).isFrame), frames = Object.entries(L.boxes).filter(([k]) => m.node(k).isFrame);
  const holder = (k) => { const n = m.node(k); return n.in != null && m.node(n.in).isFrame ? n.in : null; };
  const r = { pillPill: 0, pillNote: 0, pillTab: 0, noteNote: 0, onFrame: 0, examples: [] };
  const ex = (s) => { if (r.examples.length < 6) r.examples.push(s); };
  const P = L.pills;
  for (let i = 0; i < P.length; i++) for (let j = i + 1; j < P.length; j++) if (hit(P[i], P[j], 1)) { r.pillPill++; ex(`pill ${P[i].for.split('/').pop()} on pill ${P[j].for.split('/').pop()}`); }
  for (const p of P) for (const [k, b] of notes) {
    if (hit(p, b, 1)) { r.pillNote++; ex(`pill ${p.for.split('/').pop()} on note ${m.node(k).title}`); }
    else if (hit(p, { x: b.x, y: b.y - TAB, w: Math.min(b.w, 260), h: TAB }, 1)) { r.pillTab++; ex(`pill ${p.for.split('/').pop()} on the tab of ${m.node(k).title}`); }
  }
  for (let i = 0; i < notes.length; i++) for (let j = i + 1; j < notes.length; j++) if (hit(notes[i][1], notes[j][1], 1)) { r.noteNote++; ex(`note ${m.node(notes[i][0]).title} on note ${m.node(notes[j][0]).title}`); }
  for (const [f, fb] of frames) {
    for (const [k, b] of notes) if (holder(k) !== f && hit(b, fb, 1)) { r.onFrame++; ex(`note ${m.node(k).title} on frame ${m.node(f).title}`); }
    for (const p of P) { const u = p.user || userOf.get(p.id); const owner = u ? holder(u) : null; if (owner !== f && hit(p, fb, 1)) { r.onFrame++; ex(`pill ${p.for.split('/').pop()} on frame ${m.node(f).title}`); } }
  }
  return r;
}
