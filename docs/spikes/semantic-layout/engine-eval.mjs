// A drawing the layout branch's engine made from a cut given to it (SIM_CUT), against the judges: the corpus's health, then on the five
// judged boards the links drawn as arrows (chip/split/keep), the links the given cut made pills, and the further links the engine cut.
// With EACH=1, a second line: on each judged board, the keep links drawn and the chip arrows.
//   node engine-eval.mjs <label> <drawing.json> [cut.json]
import fs from 'fs';
import { score } from './score-drawing.mjs';
const [label, drawingF, cutF] = process.argv.slice(2);
const d = JSON.parse(fs.readFileSync(drawingF, 'utf8'));
const rows = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8'));
const pk = (a, b) => [a, b].sort().join('|');
const arrow = new Set(); for (const e of d.edges) if (!e.place) arrow.add(pk(e.from, e.to));
const given = new Set(); if (cutF) for (const [a, b] of JSON.parse(fs.readFileSync(cutF, 'utf8'))) given.add(pk(a, b));
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
const t = (xs) => ['chip', 'split', 'keep'].map((c) => xs.filter((r) => cls(r) === c).length).join('/');
const drawn = rows.filter((r) => arrow.has(pk(r.a, r.b))), cutGiven = rows.filter((r) => !arrow.has(pk(r.a, r.b)) && given.has(pk(r.a, r.b)));
const cutMore = rows.filter((r) => !arrow.has(pk(r.a, r.b)) && !given.has(pk(r.a, r.b)));
const pct = (xs, c) => Math.round((100 * xs.filter((r) => cls(r) === c).length) / Math.max(1, xs.length)) + '%';
const s = score(d).summary;
console.log(`${label.padEnd(30)} arrows ${String(s.arrows).padStart(4)}  clean ${s.clean}/${s.of}  crossings ${s.crossings}  area ${s.areaM}M | judged arrows ${drawn.length} (${t(drawn)}): ${pct(drawn, 'keep')} keep, ${pct(drawn, 'chip')} chip | given cut ${cutGiven.length} (${t(cutGiven)})  engine cut ${cutMore.length} (${t(cutMore)})  [chip/split/keep]`);
if (process.env.EACH) console.log(`${''.padEnd(30)} keep links drawn / chip arrows: ${['Selection', 'Mentions', 'Draw', 'Canvas/Model', 'References'].map((b) => { const xs = drawn.filter((r) => r.board === b); return `${b} ${xs.filter((r) => cls(r) === 'keep').length} / ${xs.filter((r) => cls(r) === 'chip').length}`; }).join(', ')}`);
