// The render layer names no kind, attribute or channel of the app: it reads `canvas kinds` for what a kind holds and which pills stand for it, and passes
// everything else through. This collects every kind name, attribute name and channel name from test/fixtures/kinds.answer.json (`canvas kinds` whole) and fails (printing file:line of
// each, and exiting with status 1 under node; jsc can only end with an uncaught error, which is status 3) if one is a quoted string literal in lib/*.mjs.
//   node test/names.js          jsc test/names.js      (from anywhere under node; jsc reads test/ relative to where it is run: the tool's folder)
// run.js holds the same check as a test, with a case for each kind of quote.
var isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
var readText = function (p) { return isNode ? require('fs').readFileSync(p, 'utf8') : readFile(p); };
var say = function (s) { if (isNode) console.log(s); else print(s); };
import('./names-lib.mjs').then(function (m) {
  var r = m.scan(readText);
  if (r.bad.length) {
    r.bad.forEach(function (o) { say(m.say(o)); });
    if (isNode) process.exit(1); else throw new Error('names: ' + r.bad.length + ' offence(s)');
  }
  say('names ok: ' + Object.keys(r.names).length + ' kind, attribute and channel names, none a string literal in lib/*.mjs');
}).catch(function (e) { say('names: ' + (e && e.message ? e.message : e)); if (isNode) process.exit(1); else setTimeout(function () { throw e; }, 0); });
