// For drawings: of the judged links, how many each draws as arrows, by the judges' consensus. node agree.mjs name=drawing.json ...
import fs from 'fs';
const rows = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8'));
for (const arg of process.argv.slice(2)) {
  const [name, file] = arg.split('=');
  const d = JSON.parse(fs.readFileSync(file, 'utf8')); const arrow = new Set();
  for (const e of d.edges) if (!e.place) arrow.add([e.from, e.to].sort().join('|'));
  const is = (r) => arrow.has([r.a, r.b].sort().join('|'));
  const keep = rows.filter((r) => r.ja + r.jb >= 3), chip = rows.filter((r) => r.ja + r.jb === 0), mid = rows.filter((r) => r.ja + r.jb > 0 && r.ja + r.jb < 3);
  const drawn = rows.filter(is), k = keep.filter(is).length, c = chip.filter(is).length, m = mid.filter(is).length;
  console.log(`${name.padEnd(10)} arrows on judged links ${String(drawn.length).padStart(3)}: keep ${k}/${keep.length} (${(100 * k / keep.length).toFixed(0)}%), middle ${m}/${mid.length}, chip ${c}/${chip.length} (${(100 * c / chip.length).toFixed(0)}%); of its arrows, keep ${(100 * k / Math.max(1, drawn.length)).toFixed(0)}% / chip ${(100 * c / Math.max(1, drawn.length)).toFixed(0)}%`);
}
