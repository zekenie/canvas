// The corpus check's measurement: strategy/measure.json (the reference's own, from the app) with strategy/tightness.json as its `tightness` member.
//   node corpus-measure.mjs <strategy folder> <out measure.json>
import fs from 'fs';
const [dir, out] = process.argv.slice(2);
const rd = (p) => JSON.parse(fs.readFileSync(dir + '/' + p, 'utf8'));
fs.writeFileSync(out, JSON.stringify(Object.assign(rd('measure.json'), { tightness: rd('tightness.json') })));
