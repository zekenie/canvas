// Several board SVGs side by side, each with a caption, in one SVG. node compose.mjs <out.svg> "<caption>=<file.svg>" ...
import fs from 'fs';
const [out, ...panels] = process.argv.slice(2);
const W = 1400, CAP = 120;
let x = 0, H = 0; const parts = [];
for (const p of panels) {
  const i = p.lastIndexOf('='), cap = p.slice(0, i), file = p.slice(i + 1);
  const src = fs.readFileSync(file, 'utf8');
  const vb = /viewBox="([^"]+)"/.exec(src)[1].split(' ').map(Number);
  const h = Math.round(W * vb[3] / vb[2]);
  const inner = src.replace(/^<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '');
  const lines = cap.split('|');
  parts.push(`<g transform="translate(${x},0)"><rect width="${W}" height="${CAP + h}" fill="#ffffff"/>` + lines.map((l, k) => `<text x="20" y="${44 + k * 38}" font-family="Helvetica" font-size="${k ? 26 : 34}" font-weight="${k ? 'normal' : 'bold'}" fill="#222">${l.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</text>`).join('') + `<svg x="0" y="${CAP}" width="${W}" height="${h}" viewBox="${vb.join(' ')}">${inner}</svg></g>`);
  x += W + 30; H = Math.max(H, CAP + h);
}
fs.writeFileSync(out, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${x - 30} ${H}" width="${x - 30}" height="${H}"><rect width="${x - 30}" height="${H}" fill="#e9e7e2"/>${parts.join('')}</svg>`);
console.log(out, x - 30, 'x', H);
