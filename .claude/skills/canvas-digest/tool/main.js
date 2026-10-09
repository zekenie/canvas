// Entry point for jsc and node:   jsc main.js -- <command> ...     node main.js <command> ...
// A classic script, because only a script can find its own folder in both engines: import() resolves against it.
var DIGEST_ARGS = typeof arguments !== 'undefined' ? Array.prototype.slice.call(arguments) : [];
(function () {
  var isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
  var io, args;
  if (isNode) {
    var fs = require('fs'), path = require('path');
    args = process.argv.slice(2);
    io = {
      readText: function (p) { return fs.readFileSync(p, 'utf8'); },
      writeText: function (p, s) { fs.writeFileSync(p, s); },
      mkdirp: function (p) { fs.mkdirSync(p, { recursive: true }); },
      print: function (s) { process.stdout.write(s + '\n'); },
      now: function () { return Date.now(); },
      engine: 'node ' + process.version,
    };
  } else {
    args = DIGEST_ARGS;
    io = {
      readText: function (p) { return readFile(p); },
      writeText: function (p, s) { writeFile(p, s); },
      mkdirp: function () {},   // jsc cannot make a folder: the driver makes <outdir>/runs
      print: function (s) { print(s); },
      now: function () { return Date.now(); },
      engine: 'jsc',
    };
  }
  var done = import('./lib/cli.mjs').then(function (m) { return m.run(args, io); });
  done.catch(function (e) {
    var msg = 'digest: ' + (e && e.message ? e.message : e);
    if (isNode) { process.stderr.write(msg + '\n'); process.exitCode = 1; }
    else { if (typeof printErr === 'function') printErr(msg); else print(msg); setTimeout(function () { throw new Error(msg); }, 0); }
  });
})();
