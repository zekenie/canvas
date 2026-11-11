// Two rankings of the links side by side, against the judges: how alike their orders are, where each puts the judges' classes on their
// boards, and the judged links they disagree on most, with what the judges said. A ranking is a file of scores by link, "<a>|<b>"
// (background.mjs --dump). A link's place is its rank among the judged links of its board, from 0 (least alike) to 1 (most).
//   node emb-diff.mjs NAME=FILE NAME=FILE [--top=10]
import fs from 'fs';
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, import.meta.url), 'utf8'));
const args = process.argv.slice(2), top = +(args.find((a) => a.startsWith('--top='))?.slice(6) || 10);
const [[nA, A], [nB, B]] = args.filter((a) => !a.startsWith('--')).map((a) => { const [n, f] = a.split('='); return [n, JSON.parse(fs.readFileSync(f, 'utf8'))]; });
const rows = rd('./judge/rows.json'), g = rd('./data/graph.json');
const title = new Map(g.nodes.map((n) => [n.key, n.props?.title || n.key.split(/[:/]/).pop()]));
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
const pk = (r) => [r.a, r.b].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)).join('|');
const score = (S, r) => { const v = S[pk(r)]; if (v == null) throw new Error(`no score for ${pk(r)}`); return v; };
// ranks with ties averaged, then Pearson's correlation of the ranks
function ranks(v) { const o = v.map((x, i) => [x, i]).sort((a, b) => a[0] - b[0]); const r = new Array(v.length); for (let i = 0; i < o.length; ) { let j = i; while (j + 1 < o.length && o[j + 1][0] === o[i][0]) j++; for (let k = i; k <= j; k++) r[o[k][1]] = (i + j) / 2; i = j + 1; } return r; }
function spearman(x, y) { const a = ranks(x), b = ranks(y), n = a.length, ma = a.reduce((s, v) => s + v, 0) / n, mb = b.reduce((s, v) => s + v, 0) / n; let c = 0, va = 0, vb = 0; for (let i = 0; i < n; i++) { c += (a[i] - ma) * (b[i] - mb); va += (a[i] - ma) ** 2; vb += (b[i] - mb) ** 2; } return c / Math.sqrt(va * vb); }
const keys = Object.keys(A).filter((k) => k in B);
console.log(`${nA} against ${nB}: rank correlation ${spearman(keys.map((k) => A[k]), keys.map((k) => B[k])).toFixed(2)} over the ${keys.length} links inside boards, ${spearman(rows.map((r) => score(A, r)), rows.map((r) => score(B, r))).toFixed(2)} over the ${rows.length} judged`);
// each judged link's place on its board under each ranking
const place = new Map();
for (const b of new Set(rows.map((r) => r.board))) {
  const xs = rows.filter((r) => r.board === b);
  for (const [n, S] of [[nA, A], [nB, B]]) { const rk = ranks(xs.map((r) => score(S, r))); xs.forEach((r, i) => { if (!place.has(r)) place.set(r, {}); place.get(r)[n] = xs.length > 1 ? rk[i] / (xs.length - 1) : 0.5; }); }
}
const mean = (xs, n) => (xs.reduce((s, r) => s + place.get(r)[n], 0) / xs.length).toFixed(2);
for (const c of ['keep', 'split', 'chip']) {
  const xs = rows.filter((r) => cls(r) === c);
  const third = (n) => `top third ${xs.filter((r) => place.get(r)[n] >= 2 / 3).length}, bottom third ${xs.filter((r) => place.get(r)[n] < 1 / 3).length}`;
  console.log(`  ${c.padEnd(5)} (${String(xs.length).padStart(3)}): mean place ${nA} ${mean(xs, nA)}, ${nB} ${mean(xs, nB)} | ${nA}: ${third(nA)}; ${nB}: ${third(nB)}`);
}
// where they disagree by more than a third of the board, on a link the judges agree on: which one the judges side with
const wide = rows.filter((r) => cls(r) !== 'split' && Math.abs(place.get(r)[nB] - place.get(r)[nA]) > 1 / 3);
const sideB = wide.filter((r) => (place.get(r)[nB] > place.get(r)[nA]) === (cls(r) === 'keep')).length;
console.log(`  ${wide.length} keep or chip links placed more than a third of their board apart: the judges side with ${nB} on ${sideB}, with ${nA} on ${wide.length - sideB}`);
const line = (r) => `    ${cls(r).padEnd(5)} ${r.board.padEnd(12)} ${nA} ${place.get(r)[nA].toFixed(2)}  ${nB} ${place.get(r)[nB].toFixed(2)}  ${title.get(r.a)} — ${title.get(r.b)}`;
const by = (f) => rows.filter((r) => cls(r) !== 'split').sort((x, y) => f(y) - f(x) || (pk(x) < pk(y) ? -1 : 1)).slice(0, top);
console.log(`  the keep and chip links ${nB} places highest above ${nA}:`); for (const r of by((r) => place.get(r)[nB] - place.get(r)[nA])) console.log(line(r));
console.log(`  the keep and chip links ${nA} places highest above ${nB}:`); for (const r of by((r) => place.get(r)[nA] - place.get(r)[nB])) console.log(line(r));
