// The harness's renderer (proto/harness.mjs renderBoard), copied and extended for quiet arrows:
//   arrow.quiet  — thin, light, no arrowhead; drawn in the quiet layer, beneath every shape (or over notes with opts.quietOver)
//   arrow.lit    — drawn in full ink on top of the shapes, as the app would draw a quiet arrow whose end is hovered or selected
//   opts.focus   — keys/pill ids to ring (the hovered or selected shape)
// Everything else is the harness's look, unchanged.
import fs from 'fs';
import { LOOK, arrowPoints, svgToPng } from '../harness.mjs';

export const QUIET = { color: '#8C8C8C', width: 1.5, opacity: 0.4 };
export const FEEDBACK = '#C2571A';
export const FOCUS = '#2F6FE4';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function roundedPath(pts, r = 14) {
  if (pts.length === 2) return `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}L${pts[1][0].toFixed(1)},${pts[1][1].toFixed(1)}`;
  let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const p = pts[i - 1], q = pts[i], n = pts[i + 1];
    const l1 = Math.hypot(q[0] - p[0], q[1] - p[1]), l2 = Math.hypot(n[0] - q[0], n[1] - q[1]);
    const rr = Math.min(r, l1 / 2, l2 / 2);
    const a = [q[0] - (q[0] - p[0]) / (l1 || 1) * rr, q[1] - (q[1] - p[1]) / (l1 || 1) * rr];
    const b = [q[0] + (n[0] - q[0]) / (l2 || 1) * rr, q[1] + (n[1] - q[1]) / (l2 || 1) * rr];
    d += `L${a[0].toFixed(1)},${a[1].toFixed(1)}Q${q[0].toFixed(1)},${q[1].toFixed(1)} ${b[0].toFixed(1)},${b[1].toFixed(1)}`;
  }
  const z = pts[pts.length - 1];
  return d + `L${z[0].toFixed(1)},${z[1].toFixed(1)}`;
}
function fit(text, width, px) { const per = px * 0.56, most = Math.max(1, Math.floor(width / per)); return text.length <= most ? text : text.slice(0, Math.max(1, most - 1)) + '…'; }

export function renderBoard(m, board, layout, opts = {}) {
  const margin = opts.margin == null ? 80 : opts.margin, cap = opts.title ? 90 : 0;
  const all = Object.values(layout.boxes).concat(layout.pills);
  { // arcs that bow past the shapes count too, as the app's fit counts them
    const pi = Object.fromEntries(layout.pills.map((q) => [q.id, q]));
    for (const a of layout.arrows) { const A = layout.boxes[a.from] || pi[a.from], B = layout.boxes[a.to] || pi[a.to]; if (A && B && Math.abs(a.bend || 0) >= 8) for (const q of arrowPoints(A, B, a, 12)) all.push({ x: q[0], y: q[1], w: 0, h: 0 }); }
  }
  const x0 = Math.min(...all.map((b) => b.x)) - margin, y0 = Math.min(...all.map((b) => b.y)) - margin - 40 - cap;
  const x1 = Math.max(...all.map((b) => b.x + b.w)) + margin, y1 = Math.max(...all.map((b) => b.y + b.h)) + margin;
  const W = Math.ceil(x1 - x0), H = Math.ceil(y1 - y0);
  const out = [];
  out.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" font-family="-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif">`);
  out.push(`<defs><pattern id="dots" width="24" height="24" patternUnits="userSpaceOnUse"><circle cx="2" cy="2" r="1.6" fill="${LOOK.dot}"/></pattern>`);
  const heads = new Set([LOOK.arrow, FEEDBACK, FOCUS].concat(Object.values(LOOK.relations)).concat((layout.arrows || []).map((a) => a.color).filter(Boolean)));
  [...heads].forEach((c, i) => out.push(`<marker id="h${i}" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="5.5" markerHeight="5.5" orient="auto-start-reverse"><path d="M1,1 L11,6 L1,11" fill="none" stroke="${c}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></marker>`));
  const headOf = new Map([...heads].map((c, i) => [c, `h${i}`]));
  out.push('</defs>');
  out.push(`<rect width="${W}" height="${H}" fill="${LOOK.canvas}"/><rect width="${W}" height="${H}" fill="url(#dots)"/>`);
  if (opts.title) out.push(`<text x="${margin}" y="${margin + 30}" font-size="44" font-weight="700" fill="${LOOK.ink}">${esc(opts.title)}</text>`);
  const frameKeys = Object.keys(layout.boxes).filter((k) => m.node(k).isFrame).sort((a, b) => m.framesOf(a).length - m.framesOf(b).length);
  for (const k of frameKeys) {
    const b = layout.boxes[k], n = m.node(k);
    out.push(`<rect x="${(b.x - x0).toFixed(1)}" y="${(b.y - y0).toFixed(1)}" width="${b.w}" height="${b.h}" rx="10" fill="${LOOK.frame}" stroke="${LOOK.frameStroke}" stroke-width="2"/>`);
    const t = fit(n.title, Math.max(80, b.w - 40), 22), tw = Math.min(b.w - 20, 22 * 0.56 * t.length + 28);
    out.push(`<rect x="${(b.x - x0 + 18).toFixed(1)}" y="${(b.y - y0 - 17).toFixed(1)}" width="${tw.toFixed(1)}" height="34" rx="17" fill="#FFFFFF" stroke="${LOOK.frameStroke}" stroke-width="2"/>`);
    out.push(`<text x="${(b.x - x0 + 32).toFixed(1)}" y="${(b.y - y0 + 7).toFixed(1)}" font-size="22" font-weight="600" fill="#333">${esc(t)}</text>`);
  }
  const pillIndex = Object.fromEntries(layout.pills.map((p) => [p.id, p]));
  const labels = [];
  const drawArrow = (a, mode) => {
    const A = layout.boxes[a.from] || pillIndex[a.from], B = layout.boxes[a.to] || pillIndex[a.to];
    if (!A || !B) return '';
    const pts = arrowPoints(A, B, a, 40);
    if (pts.length < 2) return '';
    const d = roundedPath(pts.map((p) => [p[0] - x0, p[1] - y0]));
    if (mode === 'quiet') {
      const w = opts.quietWidth || QUIET.width, c = a.quietColor || QUIET.color;
      return `<path d="${d}" fill="none" stroke="${c}" stroke-width="${w}" stroke-linecap="round" opacity="${opts.quietOpacity || QUIET.opacity}"/>`;
    }
    const color = mode === 'lit' ? (a.color || FOCUS) : (a.color || LOOK.arrow);
    if (a.label && opts.labels !== false) labels.push({ at: pts[Math.floor(pts.length / 2)], text: a.label, color });
    return `<path d="${d}" fill="none" stroke="${color}" stroke-width="${a.width || 3.5}" stroke-linecap="round" stroke-linejoin="round" marker-end="url(#${headOf.get(color)})"${a.dashed ? ' stroke-dasharray="10 8"' : ''}/>`;
  };
  const quiet = layout.arrows.filter((a) => a.quiet && !a.lit), inked = layout.arrows.filter((a) => !a.quiet && !a.lit), lit = layout.arrows.filter((a) => a.lit);
  if (!opts.quietOver) for (const a of quiet) out.push(drawArrow(a, 'quiet'));
  for (const a of inked) out.push(drawArrow(a, 'ink'));
  // shapes
  const focus = new Set(opts.focus || []);
  for (const [k, b] of Object.entries(layout.boxes)) {
    const n = m.node(k);
    if (n.isFrame) continue;
    const c = m.colorOf(k), X = b.x - x0, Y = b.y - y0;
    if (n.holdsBoard) {
      out.push(`<rect x="${X.toFixed(1)}" y="${Y.toFixed(1)}" width="${b.w}" height="${b.h}" rx="12" fill="${LOOK.card}" stroke="${LOOK.cardStroke}" stroke-width="2.5"/>`);
      const t = fit(n.title, b.w - 24, 26);
      out.push(`<text x="${(X + b.w / 2).toFixed(1)}" y="${(Y + b.h / 2 + 9).toFixed(1)}" font-size="26" font-weight="700" text-anchor="middle" fill="${LOOK.ink}">${esc(t)}</text>`);
      continue;
    }
    out.push(`<rect x="${X.toFixed(1)}" y="${(Y + 3).toFixed(1)}" width="${b.w}" height="${b.h}" rx="5" fill="#000" opacity="0.06"/>`);
    out.push(`<rect x="${X.toFixed(1)}" y="${Y.toFixed(1)}" width="${b.w}" height="${b.h}" rx="5" fill="${c.fill}"/>`);
    const tt = fit(n.title, Math.max(60, b.w - 10), 18), tw = Math.min(b.w + 60, 18 * 0.58 * tt.length + 22);
    out.push(`<rect x="${X.toFixed(1)}" y="${(Y - 36).toFixed(1)}" width="${tw.toFixed(1)}" height="28" rx="14" fill="${LOOK.tab}"/>`);
    out.push(`<text x="${(X + 11).toFixed(1)}" y="${(Y - 16).toFixed(1)}" font-size="18" font-weight="700" fill="${LOOK.tabInk}">${esc(tt)}</text>`);
    if (opts.text !== false) {
      const lines = String(n.text || '').split('\n').filter((l) => l.trim()).slice(0, Math.max(1, Math.floor((b.h - 30) / 24)));
      lines.forEach((l, i) => out.push(`<text x="${(X + 16).toFixed(1)}" y="${(Y + 34 + i * 24).toFixed(1)}" font-size="18" fill="#333">${esc(fit(l, b.w - 30, 18))}</text>`));
    }
  }
  if (opts.quietOver) for (const a of quiet) out.push(drawArrow(a, 'quiet'));
  for (const p of layout.pills) {
    const n = m.node(p.for), c = n ? m.colorOf(p.for) : LOOK.types.note, X = p.x - x0, Y = p.y - y0;
    out.push(`<rect x="${X.toFixed(1)}" y="${Y.toFixed(1)}" width="${p.w}" height="${p.h}" rx="${(p.h / 2).toFixed(1)}" fill="${c.pill}" stroke="${c.stroke}" stroke-width="1.6"/>`);
    out.push(`<text x="${(X + 16).toFixed(1)}" y="${(Y + p.h / 2 + 6).toFixed(1)}" font-size="17" font-weight="600" fill="${LOOK.ink}">${esc(fit(n ? n.title : p.for, p.w - 24, 17))}</text>`);
  }
  for (const a of lit) out.push(drawArrow(a, 'lit'));
  for (const k of focus) {
    const b = layout.boxes[k] || pillIndex[k]; if (!b) continue;
    const r = b.h <= 50 ? b.h / 2 + 8 : 12;
    out.push(`<rect x="${(b.x - x0 - 8).toFixed(1)}" y="${(b.y - y0 - 8).toFixed(1)}" width="${b.w + 16}" height="${b.h + 16}" rx="${r}" fill="none" stroke="${FOCUS}" stroke-width="6"/>`);
  }
  for (const l of labels) {
    const t = l.text, w = 15 * 0.56 * t.length + 18;
    out.push(`<rect x="${(l.at[0] - x0 - w / 2).toFixed(1)}" y="${(l.at[1] - y0 - 13).toFixed(1)}" width="${w.toFixed(1)}" height="26" rx="13" fill="#FFFFFF" stroke="${l.color}" stroke-width="1.5"/>`);
    out.push(`<text x="${(l.at[0] - x0).toFixed(1)}" y="${(l.at[1] - y0 + 5).toFixed(1)}" font-size="15" text-anchor="middle" fill="${l.color}">${esc(t)}</text>`);
  }
  out.push('</svg>');
  return { svg: out.join('\n'), width: W, height: H };
}

/** As the harness's renderBoth: <base>.png readable at opts.scale, <base>-fit.png fitted into 1600 x 1000 with no words. */
export function renderBoth(m, board, layout, base, opts = {}) {
  const read = renderBoard(m, board, layout, opts);
  fs.writeFileSync(base + '.svg', read.svg);
  const a = svgToPng(base + '.svg', base + '.png', opts.scale || 0.3);
  // fit: the app draws skeletons here; a quiet arrow is a hairline (one view point) at its alpha, an inked one keeps its world width
  const probe = renderBoard(m, board, layout, Object.assign({}, opts, { text: false, labels: false }));
  const s = Math.min(1600 / probe.width, 1000 / probe.height);
  const fitSvg = renderBoard(m, board, layout, Object.assign({}, opts, { text: false, labels: false, quietWidth: Math.max(QUIET.width, 0.75 / s), quietOpacity: 0.3 }));
  fs.writeFileSync(base + '-fit.svg', fitSvg.svg);
  const b = svgToPng(base + '-fit.svg', base + '-fit.png', s);
  return { readable: a, fit: b, fitScale: Math.round(s * 1000) / 1000 };
}
