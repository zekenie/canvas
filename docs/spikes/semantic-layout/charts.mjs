// Charts of how the similarities compare, as SVGs and PNGs at twice their size (Quick Look draws each, sips crops it):
//  - rankings.svg: each ranking's order of the links the judges agree on, least alike on the left, keep links blue and chips red, beside
//    how often a keep link outranks a chip (rank-eval.mjs's keep over chip);
//  - disagree.svg: each of those links' place on its board under Apple's embedding against OpenAI's (emb-diff.mjs's places);
//  - drawn.svg: the keep links each ranking's cut left as arrows, and the share of its judged arrows that are chips, drawn by the layout
//    branch's engine at the background simulation's counts for three thresholds (the comparison's drawings in out/);
//  - boards-head.svg: the header of the board picture reproduce.sh stitches (embeddings.jpg), with the colours of its lines.
//   node charts.mjs [out folder, build/pictures]
import fs from 'fs';
import { execFileSync } from 'child_process';
const here = (p) => new URL(p, import.meta.url);
const rd = (p) => JSON.parse(fs.readFileSync(here(p), 'utf8'));
const outDir = process.argv[2] || 'build/pictures';
const rows = rd('./judge/rows.json'), graph = rd('./data/graph.json');
const cls = (r) => (r.ja + r.jb === 0 ? 'chip' : r.ja + r.jb >= 3 ? 'keep' : 'split');
const pk = (a, b) => [a, b].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0)).join('|');
const agreed = rows.filter((r) => cls(r) !== 'split');
const keeps = agreed.filter((r) => cls(r) === 'keep'), chips = agreed.filter((r) => cls(r) === 'chip');
const title = new Map(graph.nodes.map((n) => [n.key, (n.props?.title || n.key.split(/[:/]/).pop()).replace(/\.swift$/, '')]));

// the look: the dataviz reference palette's light chart surface and inks, keep and chip as its blue and red (validated as a pair)
const C = { surface: '#fcfcfb', ink: '#0b0b0b', ink2: '#52514e', muted: '#898781', grid: '#e1e0d9', axis: '#c3c2b7', band: '#f0efec',
  keep: '#2a78d6', keepTint: '#86b6ef', chip: '#e34948', chipTint: '#f1a4a3' };
const FONT = "-apple-system, 'Helvetica Neue', Helvetica, sans-serif";
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
const T = (x, y, s, o = {}) => `<text x="${x}" y="${y}" font-size="${o.size || 22}" fill="${o.fill || C.ink}"${o.weight ? ` font-weight="${o.weight}"` : ''}${o.anchor ? ` text-anchor="${o.anchor}"` : ''}${o.extra || ''}>${esc(s)}</text>`;
const head = (t, subs) => T(40, 62, t, { size: 36, weight: 'bold' }) + subs.map((s, i) => T(40, 102 + i * 32, s, { size: 22, fill: C.ink2 })).join('');
const swatch = (x, y, col, label) => `<rect x="${x}" y="${y - 17}" width="22" height="22" rx="4" fill="${col}"/>` + T(x + 32, y, label, { size: 21 });
// Quick Look fills a square thumbnail, cutting off what doesn't fit, so the SVG is drawn square and the PNG cropped to the chart (sips
// reads an offset of 0 as centred, so the crop starts a pixel down)
const write = (name, W, H, body) => {
  const S = Math.max(W, H), f = `${outDir}/${name}.svg`;
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(f, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${S} ${S}" width="${S}" height="${S}" font-family="${FONT}"><rect width="${S}" height="${S}" fill="${C.surface}"/>${body}</svg>`);
  execFileSync('qlmanage', ['-t', '-s', String(2 * S), '-o', outDir, f], { stdio: 'ignore' });
  execFileSync('sips', ['-c', String(2 * H), String(2 * W), '--cropOffset', '1', '0', f + '.png', '--out', `${outDir}/${name}.png`], { stdio: 'ignore' });
  console.log(`${outDir}/${name}.png`, 2 * W, 'x', 2 * H);
};

const score = (S, r) => { const v = S[pk(r.a, r.b)]; if (v == null) throw new Error(`no score for ${pk(r.a, r.b)}`); return v; };
const auc = (S) => { let w = 0; for (const p of keeps) for (const q of chips) { const a = score(S, p), b = score(S, q); w += a > b ? 1 : a === b ? 0.5 : 0; } return w / keeps.length / chips.length; };
const hash = (s) => { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; };

// 1. rankings: one stripe a link, ordered by the ranking's score; ties in a fixed shuffled order, so a tie favours neither class
{
  const R = [['the judges’ own order', null], ['Apple’s embedding', 'out/score-emb-contextual.json'],
    ['Apple’s + word overlap (earlier rounds)', 'out/score-mix-contextual.json'], ['word overlap alone', 'out/score-words.json'],
    ['OpenAI’s embedding', 'out/score-emb-openai-3-large.json'], ['OpenAI’s + word overlap', 'out/score-mix-openai-3-large.json'],
    ['Jev + word overlap', 'out/score-board+words.json']];
  const W = 1600, X0 = 520, X1 = 1440, top = 250, pitch = 74, bw = (X1 - X0) / agreed.length;
  let b = head('How each similarity orders the links', [
    `The ${agreed.length} links the judges agree on, one stripe each, from least alike (left) to most alike (right). A perfect order puts`,
    'every blue stripe right of every red one, as the judges’ own order does.']);
  b += swatch(40, 192, C.keep, `keep: the judges would draw it as an arrow (${keeps.length})`) + swatch(600, 192, C.chip, `chip: both judges would make it a pill (${chips.length})`);
  b += T(1560, top - 14, 'keep over chip', { size: 18, fill: C.muted, anchor: 'end' });
  R.forEach(([name, file], i) => {
    const y = top + i * pitch, S = file && rd('./' + file);
    const order = [...agreed].sort((p, q) => (S ? score(S, p) - score(S, q) : (cls(p) === 'keep') - (cls(q) === 'keep')) || hash(pk(p.a, p.b)) - hash(pk(q.a, q.b)));
    b += T(40, y + 34, name, { size: 24, fill: S ? C.ink : C.ink2, weight: name.startsWith('Jev') ? 'bold' : null });
    b += order.map((r, k) => `<rect x="${(X0 + k * bw).toFixed(2)}" y="${y + 6}" width="${(bw + 0.4).toFixed(2)}" height="44" fill="${cls(r) === 'keep' ? C.keep : C.chip}"/>`).join('');
    b += T(1560, y + 38, S ? auc(S).toFixed(2) : '1.00', { size: 28, weight: 'bold', anchor: 'end', fill: S ? C.ink : C.ink2, extra: ' font-variant-numeric="tabular-nums"' });
  });
  const ya = top + R.length * pitch + 8;
  b += T(X0, ya, '← least alike', { size: 20, fill: C.muted }) + T(X1, ya, 'most alike →', { size: 20, fill: C.muted, anchor: 'end' });
  write('rankings', W, ya + 30, b);
}

// 2. where the two embeddings disagree: each agreed link's place among its board's judged links, Apple's across and OpenAI's up
{
  const A = rd('./out/score-emb-contextual.json'), O = rd('./out/score-emb-openai-3-large.json');
  const ranks = (v) => { const o = v.map((x, i) => [x, i]).sort((a, b) => a[0] - b[0]); const r = new Array(v.length); for (let i = 0; i < o.length; ) { let j = i; while (j + 1 < o.length && o[j + 1][0] === o[i][0]) j++; for (let k = i; k <= j; k++) r[o[k][1]] = (i + j) / 2; i = j + 1; } return r; };
  const place = new Map();
  for (const bd of new Set(rows.map((r) => r.board))) {
    const xs = rows.filter((r) => r.board === bd), ra = ranks(xs.map((r) => score(A, r))), ro = ranks(xs.map((r) => score(O, r)));
    xs.forEach((r, i) => place.set(r, { a: ra[i] / (xs.length - 1), o: ro[i] / (xs.length - 1) }));
  }
  const W = 1600, px = 150, py = 214, S = 900, X = (v) => px + v * S, Y = (v) => py + (1 - v) * S;
  let b = head('Where Apple’s and OpenAI’s embeddings disagree', [
    `Each dot is one of the ${agreed.length} links the judges agree on, placed by its rank among its board’s judged links: 0 the least alike`,
    'on its board, 1 the most. A keep link belongs at the top right, a chip at the bottom left.']);
  const tri = (pts) => `<polygon points="${pts.map(([u, v]) => `${X(u)},${Y(v)}`).join(' ')}" fill="${C.band}"/>`;
  b += tri([[0, 1 / 3], [0, 1], [2 / 3, 1]]) + tri([[1 / 3, 0], [1, 0], [1, 2 / 3]]);
  for (const v of [0, 0.25, 0.5, 0.75, 1]) {
    b += `<line x1="${X(v)}" y1="${Y(0)}" x2="${X(v)}" y2="${Y(1)}" stroke="${C.grid}" stroke-width="1.5"/><line x1="${X(0)}" y1="${Y(v)}" x2="${X(1)}" y2="${Y(v)}" stroke="${C.grid}" stroke-width="1.5"/>`;
    b += T(X(v), Y(0) + 32, String(v), { size: 19, fill: C.muted, anchor: 'middle' }) + T(X(0) - 14, Y(v) + 7, String(v), { size: 19, fill: C.muted, anchor: 'end' });
  }
  b += `<line x1="${X(0)}" y1="${Y(0)}" x2="${X(1)}" y2="${Y(1)}" stroke="${C.axis}" stroke-width="2"/>`;
  b += T(X(0.5), Y(0) + 70, 'Apple’s embedding: place on its board', { size: 22, anchor: 'middle', weight: 'bold' });
  b += T(0, 0, 'OpenAI’s embedding: place on its board', { size: 22, anchor: 'middle', weight: 'bold', extra: ` transform="translate(${px - 62},${Y(0.5)}) rotate(-90)"` });
  const dot = (r, rad) => { const p = place.get(r); return `<circle cx="${X(p.a).toFixed(1)}" cy="${Y(p.o).toFixed(1)}" r="${rad}" fill="${cls(r) === 'keep' ? C.keep : C.chip}" stroke="${C.surface}" stroke-width="2"/>`; };
  b += chips.map((r) => dot(r, 8)).join('') + keeps.map((r) => dot(r, 9)).join('');
  // the examples the README names
  const find = (t1, t2) => agreed.find((r) => { const s = [title.get(r.a), title.get(r.b)]; return s.includes(t1) && s.includes(t2); });
  const ex = [['ReferenceDefinition', 'ReferenceStyle'], ['DrawTexts', 'Draw'], ['SelectionPlugin', 'SelectionObservers'], ['ReferenceEditing', 'ReferenceEdits']].map(([p, q]) => {
    const r = find(p, q); if (!r) throw new Error(`no agreed link ${p} – ${q}`); return { r, p, q };
  });
  ex.forEach(({ r }, i) => { const p = place.get(r); b += `<circle cx="${X(p.a)}" cy="${Y(p.o)}" r="17" fill="none" stroke="${C.ink}" stroke-width="2.5"/>` + T(X(p.a) + (p.a > 0.85 ? -24 : 22), Y(p.o) - 16, String(i + 1), { size: 24, weight: 'bold', anchor: p.a > 0.85 ? 'end' : 'start' }); });
  // the right column: the bands' counts, then the examples
  const wide = agreed.filter((r) => Math.abs(place.get(r).o - place.get(r).a) > 1 / 3), up = wide.filter((r) => place.get(r).o > place.get(r).a), dn = wide.filter((r) => place.get(r).o < place.get(r).a);
  const n = (xs, c) => xs.filter((r) => cls(r) === c).length, withO = n(up, 'keep') + n(dn, 'chip');
  let y = 250; const RX = 1110, line = (s, o = {}) => { b += T(RX, y, s, { size: 21, ...o }); y += o.gap || 32; };
  b += swatch(RX, y, C.keep, `keep (${keeps.length})`) + swatch(RX + 200, y, C.chip, `chip (${chips.length})`); y += 56;
  b += `<rect x="${RX}" y="${y - 20}" width="22" height="22" fill="${C.band}" stroke="${C.axis}" stroke-width="1"/>`; b += T(RX + 32, y, 'more than a third of the board apart', { size: 21 }); y += 34;
  line(`Upper left, OpenAI’s higher: ${n(up, 'keep')} keep, ${n(up, 'chip')} chip`); line(`Lower right, Apple’s higher: ${n(dn, 'keep')} keep, ${n(dn, 'chip')} chip`);
  line(`The judges side with OpenAI on ${withO}`, { weight: 'bold', gap: 26 }); line(`of these ${wide.length}, with Apple on ${wide.length - withO}.`, { weight: 'bold', gap: 60 });
  const kind = ['Apple fooled by a style file', 'Apple fooled by a central file', 'OpenAI fooled by registration', 'OpenAI right'];
  ex.forEach(({ r, p, q }, i) => {
    const pl = place.get(r);
    line(`${i + 1}  ${p} – ${q}`, { weight: 'bold', gap: 30 });
    line(`${cls(r)}: Apple ${pl.a.toFixed(2)}, OpenAI ${pl.o.toFixed(2)}`, { size: 20, fill: C.ink2, gap: 28 });
    line(kind[i], { size: 20, fill: C.ink2, gap: 46 });
  });
  write('disagree', W, py + S + 100, b);
}

// 3. what each ranking's cut drew, at the simulation's counts for three thresholds
{
  const D = [['Apple’s + word overlap (earlier rounds)', ['sens-aw-0.4', 'same05', 'sens-aw-0.6']], ['word overlap alone', ['sens-w-0.4', 'words-same05', 'sens-w-0.6']],
    ['OpenAI’s embedding', ['sens-o-0.4', 'oaemb-same05', 'sens-o-0.6']], ['OpenAI’s + word overlap', ['sens-ow-0.4', 'oa-same05', 'sens-ow-0.6']],
    ['Jev + Apple’s + word overlap', ['sens-ja-0.4', 'jbs-sim05', 'sens-ja-0.6']], ['Jev + OpenAI’s + word overlap', ['sens-jo-0.4', 'jbo-sim05', 'sens-jo-0.6']],
    ['Jev + word overlap', ['sens-jw-0.4', 'sens-jw-0.5', 'sens-jw-0.6']]];
  const res = D.map(([name, ns]) => [name, ns.map((n) => {
    const d = rd(`./out/e-${n}/drawing.json`), arrow = new Set();
    for (const e of d.edges) if (!e.place) arrow.add(pk(e.from, e.to));
    const drawn = rows.filter((r) => arrow.has(pk(r.a, r.b)));
    return { keep: drawn.filter((r) => cls(r) === 'keep').length, chip: (100 * drawn.filter((r) => cls(r) === 'chip').length) / drawn.length };
  })]);
  const W = 1600, top = 268, pitch = 70, gapJev = 46, L = [500, 1000, 20, 50], Rp = [1110, 1520, 0, 35];
  const yRow = (i) => top + i * pitch + (i >= 4 ? gapJev : 0);
  const sx = ([x0, x1, v0, v1], v) => x0 + ((v - v0) / (v1 - v0)) * (x1 - x0);
  let b = head('What each ranking’s cut drew', [
    'Every board drawn by the layout branch’s engine, each ranking choosing which links become pills, at the background simulation’s counts',
    'for thresholds 0.4, 0.5 and 0.6. Small dots: each count. Large dot: their mean.']);
  const yEnd = yRow(D.length - 1) + 40;
  const panel = (P, ticks, fmt, label, sub) => {
    let s = T(P[0], top - 62, label, { size: 22, weight: 'bold' }) + T(P[0], top - 34, sub, { size: 19, fill: C.muted });
    for (const t of ticks) s += `<line x1="${sx(P, t)}" y1="${top - 16}" x2="${sx(P, t)}" y2="${yEnd}" stroke="${C.grid}" stroke-width="1.5"/>` + T(sx(P, t), yEnd + 30, fmt(t), { size: 19, fill: C.muted, anchor: 'middle' });
    return s;
  };
  b += panel(L, [20, 25, 30, 35, 40, 45, 50], String, 'Keep links drawn as arrows, of 76', 'more is better');
  b += panel(Rp, [0, 5, 10, 15, 20, 25, 30, 35], (t) => t + '%', 'Arrows that are chips', 'share of judged arrows; less is better');
  b += T(40, top - 14, 'similarity alone', { size: 19, fill: C.muted }) + T(40, yRow(4) - 22, 'with Jev', { size: 19, fill: C.muted });
  b += `<line x1="40" y1="${yRow(4) - 48}" x2="1560" y2="${yRow(4) - 48}" stroke="${C.grid}" stroke-width="1.5"/>`;
  res.forEach(([name, xs], i) => {
    const y = yRow(i) + 16;
    b += T(40, y + 8, name, { size: 22, weight: name === 'Jev + word overlap' ? 'bold' : null });
    for (const [P, key, col, tint, fmt] of [[L, 'keep', C.keep, C.keepTint, (v) => v.toFixed(0)], [Rp, 'chip', C.chip, C.chipTint, (v) => v.toFixed(0) + '%']]) {
      const vs = xs.map((x) => x[key]), lo = Math.min(...vs), hi = Math.max(...vs), mean = vs.reduce((s, v) => s + v, 0) / vs.length;
      b += `<line x1="${sx(P, lo)}" y1="${y}" x2="${sx(P, hi)}" y2="${y}" stroke="${tint}" stroke-width="4" stroke-linecap="round"/>`;
      b += vs.map((v) => `<circle cx="${sx(P, v).toFixed(1)}" cy="${y}" r="7" fill="${tint}" stroke="${C.surface}" stroke-width="2"/>`).join('');
      b += `<circle cx="${sx(P, mean).toFixed(1)}" cy="${y}" r="11" fill="${col}" stroke="${C.surface}" stroke-width="2"/>`;
      b += T(sx(P, hi) + 18, y + 8, fmt(mean), { size: 22, weight: 'bold', extra: ' font-variant-numeric="tabular-nums"' });
    }
  });
  const sw = res.map(([name, xs]) => [name, Math.max(...xs.map((x) => x.keep)) - Math.min(...xs.map((x) => x.keep))]).sort((p, q) => q[1] - p[1])[0];
  const mean = (i) => res[i][1].reduce((s, x) => s + x.keep, 0) / 3;
  b += T(40, yEnd + 84, `One ranking’s drawing moves by as many as ${sw[1]} keep links between nearby counts (${sw[0]}); OpenAI’s embedding and word overlap`, { size: 20, fill: C.ink2 });
  b += T(40, yEnd + 114, `differ by ${Math.abs(mean(2) - mean(1)).toFixed(0)} on average, Apple’s with word overlap trails both by ${(Math.min(mean(1), mean(2)) - mean(0)).toFixed(0)}.`, { size: 20, fill: C.ink2 });
  write('drawn', W, yEnd + 146, b);
  for (const [name, xs] of res) console.log(name.padEnd(42), xs.map((x) => `${x.keep} ${x.chip.toFixed(0)}%`).join(' | '));
}

// 4. the header of the board picture (embeddings.jpg): what its panels are, and the colours of their lines
{
  const W = 1412;
  let b = head('Selection and Mentions, drawn four ways', [
    'Each row is one ranking choosing which links become pills, at the background simulation’s counts for threshold 0.5; the layout',
    'branch’s engine draws the rest. Selection on the left, Mentions on the right. Lines are coloured by the judges.']);
  const y = 196, seg = (x, col, w, label) => `<line x1="${x}" y1="${y - 7}" x2="${x + 46}" y2="${y - 7}" stroke="${col}" stroke-width="${w}" stroke-linecap="round"/>` + T(x + 58, y, label, { size: 21 });
  b += seg(40, C.keep, 8, 'keep') + seg(190, C.chip, 8, 'chip') + seg(340, '#a19d92', 5, 'between: the judges split') + seg(700, '#d6d3ca', 3, 'line into a pill');
  b += `<rect x="960" y="${y - 22}" width="90" height="30" rx="15" fill="#dfeaf5" stroke="#7d9bb8" stroke-width="2"/>` + T(1062, y, 'pill', { size: 21 });
  b += `<rect x="1140" y="${y - 24}" width="34" height="34" rx="4" fill="#fff4b8" stroke="#a89b5c" stroke-width="2"/>` + T(1186, y, 'note', { size: 21 });
  write('boards-head', W, 224, b);
}
