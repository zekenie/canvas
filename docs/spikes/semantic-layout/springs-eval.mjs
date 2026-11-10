// Boards of a springs.mjs drawing against the judges: each board's health, and the judges' labels (chip/split/keep) of the links that
// were references from the start (they cross a frame), of the links the threshold broke, and of the arrows left; then the boards' total.
//   node springs-eval.mjs <drawing with nothing broken> <drawing> <board,board,... e.g. module:Selection> [label]
import fs from 'fs';
import { score } from './score-drawing.mjs';
const [baseF, runF, boardList, label = ''] = process.argv.slice(2);
const all = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8'));
const read = (f) => { const d = JSON.parse(fs.readFileSync(f, 'utf8')), s = new Set(); for (const e of d.edges) if (!e.place) s.add([e.from, e.to].sort().join('|')); return [d, s]; };
const [, A0] = read(baseF), [d, A] = read(runF);
const health = score(d).boards;
const key = (r) => [r.a, r.b].sort().join('|');
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
const c = (xs) => ['chip', 'split', 'keep'].map((t) => xs.filter((r) => cls(r) === t).length).join('/');
const T = { arrows: 0, crossings: 0, overShapes: 0, up: [], broke: [], kept: [] };
const boards = boardList.split(',');
for (const board of boards) {
  const rows = all.filter((r) => 'module:' + r.board === board);
  const up = rows.filter((r) => !A0.has(key(r))), broke = rows.filter((r) => A0.has(key(r)) && !A.has(key(r))), kept = rows.filter((r) => A.has(key(r)));
  const h = health[board];
  T.arrows += h.links - h.cut; T.crossings += h.crossings; T.overShapes += h.overShapes; T.up.push(...up); T.broke.push(...broke); T.kept.push(...kept);
  if (boards.length === 1 || process.env.EACH) console.log(`${(label + ' ' + board.replace(/^module:/, '')).trim().padEnd(34)} arrows ${String(h.links - h.cut).padStart(3)}  crossings ${String(h.crossings).padStart(4)}  over shapes ${String(h.overShapes).padStart(4)} | from the start ${up.length} (${c(up)})  broken ${broke.length} (${c(broke)})  left ${kept.length} (${c(kept)})`);
}
if (boards.length > 1) {
  const pct = (t) => Math.round((100 * T.kept.filter((r) => cls(r) === t).length) / Math.max(1, T.kept.length)) + '%';
  console.log(`${(label + ' (' + boards.length + ' boards)').padEnd(34)} arrows ${T.arrows}  crossings ${T.crossings}  over shapes ${T.overShapes} | from the start ${T.up.length} (${c(T.up)})  broken ${T.broke.length} (${c(T.broke)})  left ${T.kept.length} (${c(T.kept)}): of its arrows ${pct('chip')} chip, ${pct('keep')} keep  [chip/split/keep]`);
}
