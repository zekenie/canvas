// Ways of ranking links against the two blind judges, on the 459 links they judged, before anything is drawn. Each ranking is a file of
// scores by link ("<a>|<b>", higher keeps), as background.mjs --dump writes them. For each:
//  - AUC, keep over chip: how often a link the judges keep (mean label 1.5 or more) outranks one they both chip; on all five boards, then
//    on each; and keep over split, split over chip (split: the judges' labels sum to 1 or 2);
//  - against one judge at a time: how often a link one judge gave a 2 outranks one that judge gave a 0, for A and for B; the other judge's
//    labels do this too (the ceiling: as well as a second reader agrees);
//  - at the judges' counts: on each board cut as many links as the judges would (every one they wouldn't keep), the lowest first, and count
//    the keep and chip links left (the judges themselves leave all 76 keeps and no chip).
// With --probs=FILE (jev.mjs's answers), its probabilities by the judges' class, and Jev's own verdicts at the app's cutoffs (yes at 0.7
// and above, no at 0.3 and below).
//   node rank-eval.mjs name=out/score-sim.json name=out/score-board.json ... [--probs=data/jev-board.json ...]
import fs from 'fs';
const rows = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8'));
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
const pk = (r) => [r.a, r.b].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)).join('|');
const BOARDS = ['Selection', 'Mentions', 'Draw', 'Canvas/Model', 'References'];
const auc = (xs, pos, neg, f) => { const P = xs.filter(pos), N = xs.filter(neg); let w = 0; for (const p of P) for (const q of N) { const a = f(p), b = f(q); w += a > b ? 1 : a === b ? 0.5 : 0; } return w / P.length / N.length; };
const isKeep = (r) => cls(r) === 'keep', isChip = (r) => cls(r) === 'chip';
const f3 = (x) => x.toFixed(3);
const rankers = [], probs = [];
for (const a of process.argv.slice(2)) {
  if (a.startsWith('--probs=')) { for (const f of a.slice(8).split(',')) probs.push([f.replace(/^.*jev-|\.json$/g, ''), JSON.parse(fs.readFileSync(f, 'utf8'))]); continue; }
  const [name, file] = a.split('=');
  rankers.push([name, JSON.parse(fs.readFileSync(file, 'utf8'))]);
}
console.log(`${rows.length} judged links: ${rows.filter(isKeep).length} keep, ${rows.filter((r) => cls(r) === 'split').length} split, ${rows.filter(isChip).length} chip`);
console.log(`ceiling, one judge ranking the other's 2s over 0s: A ranks B ${f3(auc(rows, (r) => r.jb === 2, (r) => r.jb === 0, (r) => r.ja))}, B ranks A ${f3(auc(rows, (r) => r.ja === 2, (r) => r.ja === 0, (r) => r.jb))}`);
const cutCount = new Map(BOARDS.map((b) => [b, rows.filter((r) => r.board === b && !isKeep(r)).length]));
console.log(`\n${'ranking'.padEnd(30)} keep>chip | ${BOARDS.map((b) => b.slice(0, 9).padEnd(9)).join(' ')} | judge A  judge B | keep>split split>chip | at the judges' counts: keep / chip left`);
for (const [name, S] of rankers) {
  const f = (r) => { const v = S[pk(r)]; if (v == null) throw new Error(`${name}: no score for ${pk(r)}`); return v; };
  const each = BOARDS.map((b) => f3(auc(rows.filter((r) => r.board === b), isKeep, isChip, f)).padEnd(9)).join(' ');
  let keepLeft = 0, chipLeft = 0;
  for (const b of BOARDS) {
    const xs = rows.filter((r) => r.board === b).sort((x, y) => f(x) - f(y) || (pk(x) < pk(y) ? -1 : 1));
    for (const r of xs.slice(cutCount.get(b))) { if (isKeep(r)) keepLeft++; if (isChip(r)) chipLeft++; }
  }
  const isSplit = (r) => cls(r) === 'split';
  console.log(`${name.padEnd(30)} ${f3(auc(rows, isKeep, isChip, f)).padEnd(9)} | ${each} | ${f3(auc(rows, (r) => r.ja === 2, (r) => r.ja === 0, f))}    ${f3(auc(rows, (r) => r.jb === 2, (r) => r.jb === 0, f))}  | ${f3(auc(rows, isKeep, isSplit, f)).padEnd(10)} ${f3(auc(rows, isSplit, isChip, f)).padEnd(10)} | ${keepLeft} / ${chipLeft}`);
}
for (const [name, J] of probs) {
  const p = (r) => J.scores[pk(r)];
  const mean = (xs) => (xs.reduce((s, r) => s + p(r), 0) / xs.length).toFixed(2);
  const by = (c) => rows.filter((r) => cls(r) === c);
  const verdicts = (xs) => `${xs.filter((r) => p(r) >= 0.7).length} yes, ${xs.filter((r) => p(r) > 0.3 && p(r) < 0.7).length} unsure, ${xs.filter((r) => p(r) <= 0.3).length} no`;
  console.log(`\nJev, ${name} (${J.model}): mean probability keep ${mean(by('keep'))}, split ${mean(by('split'))}, chip ${mean(by('chip'))}; at the app's cutoffs keep: ${verdicts(by('keep'))}; split: ${verdicts(by('split'))}; chip: ${verdicts(by('chip'))}`);
  const all = Object.values(J.scores).sort((a, b) => a - b), distinct = new Set(rows.map(p)).size;
  console.log(`  ${distinct} distinct probabilities over the judged links; every link inside a board (${all.length}): under 0.3 ${all.filter((x) => x <= 0.3).length}, under 0.5 ${all.filter((x) => x < 0.5).length}, 0.7 and over ${all.filter((x) => x >= 0.7).length}; deciles ${[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9].map((q) => all[Math.floor(q * all.length)].toFixed(2)).join(' ')}`);
}
