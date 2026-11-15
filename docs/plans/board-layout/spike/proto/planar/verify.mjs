// A build's drawing checked as the app will get it: every module board clean (the build's metrics) and nothing on top of anything
// (overlaps.mjs over the drawing read back), with the boards that fail named. node verify.mjs <scratch> <build dir>
import fs from 'fs';
import { load, layoutFromDrawing } from '../harness.mjs';
import { overlaps } from './overlaps.mjs';
const [S, dir] = process.argv.slice(2);
const m = load(S + '/data');
const d = JSON.parse(fs.readFileSync(dir + '/drawing.json', 'utf8')), met = JSON.parse(fs.readFileSync(dir + '/metrics.json', 'utf8'));
const tot = { pillPill: 0, pillNote: 0, pillTab: 0, noteNote: 0, onFrame: 0 }, bad = [], unclean = [];
for (const b of m.boards.keys()) {
  if (b === 'root') continue;
  if (met[b] && !met[b].clean) unclean.push(b);
  const r = overlaps(m, b, layoutFromDrawing(m, d, b));
  let n = 0; for (const k in tot) { tot[k] += r[k]; n += r[k]; }
  if (n) bad.push(`${b.replace('module:', '')}: ${n} (${r.examples.slice(0, 2).join('; ')})`);
}
console.log(JSON.stringify({ clean: Object.values(met).filter((r) => r.clean).length, of: Object.keys(met).length, overlaps: tot, boardsWithOverlaps: bad.length }));
if (unclean.length) console.log('not clean: ' + unclean.join(', '));
if (bad.length) console.log(bad.slice(0, 12).join('\n'));
