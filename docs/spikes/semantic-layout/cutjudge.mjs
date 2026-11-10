// Of the links a drawing cut on the judged boards it covers, how many the judges would cut (both 0) and how many they would keep.
import fs from 'fs';
const rows = JSON.parse(fs.readFileSync(new URL('./judge/rows.json', import.meta.url), 'utf8'));
for (const arg of process.argv.slice(2)) {
  const [name, file, board] = arg.split('=');
  const d = JSON.parse(fs.readFileSync(file, 'utf8')); const arrow = new Set();
  for (const e of d.edges) if (!e.place) arrow.add([e.from, e.to].sort().join('|'));
  const rs = rows.filter((r) => r.board === board), cut = rs.filter((r) => !arrow.has([r.a, r.b].sort().join('|')));
  const chip = cut.filter((r) => r.ja + r.jb === 0).length, keep = cut.filter((r) => r.ja + r.jb >= 3).length;
  console.log(`${name.padEnd(22)} ${board}: cut ${cut.length} of ${rs.length}; of the cut, ${chip} the judges chip, ${keep} they keep`);
}
