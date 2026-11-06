// A stand-in for the `canvas` command, for driver.sh: answers kinds, measure (estimated sizes), boards, help, query and apply the way the app does, from files.
// FAKE_DIR holds what it keeps: apply.log (each apply's arguments), applied.json (the last document), rows.json (what the query answers, when there is a file),
// query-fails (when it exists, query fails as the app does when it is too slow), measure.log (each measure's arguments),
// refuse (when it exists, apply refuses the document with the contents of the file as its refusals).
import fs from 'fs';
import { buildModel } from '../lib/model.mjs';
import { estimateMeasure } from './helpers.mjs';

const dir = process.env.FAKE_DIR, args = process.argv.slice(2), cmd = args[0];
const kinds = JSON.parse(fs.readFileSync(new URL('./fixtures/kinds.json', import.meta.url), 'utf8'));
const stdin = () => fs.readFileSync(0, 'utf8');
const out = (v) => process.stdout.write(JSON.stringify(v) + '\n');
if (cmd === 'kinds') out(kinds);
else if (cmd === 'boards') out([{ id: 'board-1', name: 'Untitled' }]);
else if (cmd === 'status') process.stdout.write('build: fake\n');
else if (cmd === 'help') process.stdout.write('help ' + args[1] + '\n');
else if (cmd === 'measure') { fs.appendFileSync(dir + '/measure.log', args.filter((a, i) => a !== '--timeout' && args[i - 1] !== '--timeout').join(' ') + '\n');
  const g = JSON.parse(stdin()); out(estimateMeasure(buildModel(g, null, kinds), g)); }
else if (cmd === 'query') {
  fs.appendFileSync(dir + '/query.log', args.join(' ') + '\n');
  // a failure the app has (too slow, timed out), else the rows of the drawing, else what the app answers for a drawing the file lacks: no rows
  if (fs.existsSync(dir + '/query-fails')) { process.stderr.write('{"error":{"reason":"too_slow","message":"the query is too slow for a file this big"}}\n'); process.exit(1); }
  process.stdout.write(fs.existsSync(dir + '/rows.json') ? fs.readFileSync(dir + '/rows.json', 'utf8') : '{"rows":[]}\n');
} else if (cmd === 'apply') {
  const doc = stdin();
  fs.appendFileSync(dir + '/apply.log', args.filter((a, i) => a !== '--timeout' && args[i - 1] !== '--timeout').join(' ') + '\n');
  fs.writeFileSync(dir + '/applied.json', doc);
  if (fs.existsSync(dir + '/timeout')) { process.stderr.write('{"error":{"reason":"timed_out","message":"no answer in time","hint":"the app may still do it"}}\n'); process.exit(1); }
  if (fs.existsSync(dir + '/refuse')) { process.stderr.write(JSON.stringify({ error: { reason: 'refused', message: 'refused', refusals: JSON.parse(fs.readFileSync(dir + '/refuse', 'utf8')) } }) + '\n'); process.exit(1); }
  const g = JSON.parse(doc);
  out({ drawing: g.drawing, dryRun: args.includes('--dry-run'), nodes: g.nodes.map((n) => ({ key: n.key, did: 'created' })), edges: g.edges.map((e, i) => ({ edge: i, did: 'created' })), deleted: [], warnings: [{ key: g.nodes[0].key, message: 'a fake warning' }] });
} else { process.stderr.write('fake canvas: ' + cmd + '\n'); process.exit(2); }
