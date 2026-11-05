// Unit tests:  jsc test/run.js     or     node test/run.js
// Classic script (import() finds ../lib from here in both engines). No app, no sockets, no pasteboard, no network.
var isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
var RUN_ARGS = typeof arguments !== 'undefined' ? Array.prototype.slice.call(arguments) : [];   // jsc's, after `--`
var fsr = isNode ? require('fs') : null;
var io = {
  readText: function (p) { return isNode ? fsr.readFileSync(p, 'utf8') : readFile(p); },
  print: function (s) { isNode ? console.log(s) : print(s); },
};
Promise.all([import('../lib/dial.mjs'), import('../lib/model.mjs'), import('../lib/sizes.mjs'), import('../lib/elk.mjs'), import('../lib/plan.mjs'), import('../lib/cli.mjs'), import('../lib/util.mjs'), import('../lib/layout.mjs'), import('../lib/promote.mjs'), import('../lib/cost.mjs'), import('../lib/noise.mjs'), import('../lib/check.mjs'), import('./helpers.mjs'), import('../lib/compare.mjs'), import('../lib/types.mjs'), import('../lib/verify.mjs'), import('../lib/places.mjs'), import('../lib/names.mjs'), import('../lib/replay.mjs'), import('../lib/redraw.mjs'), import('../lib/emit.mjs')]).then(async function (mods) {
  var dialm = mods[0], model = mods[1], sizes = mods[2], elkm = mods[3], planm = mods[4], clim = mods[5], util = mods[6], layoutm = mods[7], promm = mods[8], costm = mods[9], noisem = mods[10], checkm = mods[11], helpers = mods[12], compareRun0 = mods[13].compareRun, typesm = mods[14], verifym = mods[15], placesm = mods[16], namesm = mods[17], replaym = mods[18], redrawm = mods[19], emitm0 = mods[20];
  var base = util.TOOL_DIR;
  var elk = await elkm.loadElk(io, base);
  var results = [], failed = 0;
  // `jsc test/run.js -- K/N` runs the tests dealt to part K of N (the Kth, the K+Nth, ... of them in order, counting from 0), so a caller can run the parts side by side;
  // the part's last line says how many of how many it ran. Without it, every test runs.
  var partArg = isNode ? process.argv[2] : RUN_ARGS[0];
  var part = partArg ? { k: Number(partArg.split('/')[0]), n: Number(partArg.split('/')[1]) } : null;
  var defined = 0;
  async function test(name, fn) {
    var mine = !part || defined % part.n === part.k;
    defined++;
    if (!mine) return;
    try { await fn(); io.print('ok   ' + name); results.push(name); }
    catch (e) { failed++; io.print('FAIL ' + name + ': ' + (e && e.message ? e.message : e)); }
  }
  function assert(c, m) { if (!c) throw new Error(m || 'assertion failed'); }
  function eq(a, b, m) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((m || 'not equal') + ': ' + JSON.stringify(a) + ' vs ' + JSON.stringify(b)); }

  function note(t, f, text) { var n = { title: t, kind: 'sticky-note', text: text || '' }; if (f) n.in = f; return n; }
  function digest(nodes, edges, extra) { return Object.assign({ title: 'T', nodes: nodes, edges: edges }, extra || {}); }
  var fixture = function (name) { return JSON.parse(io.readText(base + '/test/fixtures/' + name + '.digest.json')); };
  // a hand-made result's rows get the line of the statement that draws their shape (run `runIndex` of the plan), as the app's rows say it, and are compared to the plan
  var lineRows = function (r, name, changes) {
    var run = r.statements.runs[name];
    changes.forEach(function (c) { if (c.line == null && c.title != null) { var i = run.lines.findIndex(function (l) { return l.shape === c.title || l.describe === c.title; }); if (i >= 0) c.line = i + 1; } });
    return changes;
  };
  // results for every run of a plan: each shape's row in the run that draws it (with the line of its statement), the rows of `first` (pills, say) in the first run, those of `last` in the last
  var distribute = function (r, shapeRows, first, last) {
    var res = {};
    r.plan.runs.forEach(function (n) { res[n] = { changes: [], warnings: [], on: null }; });
    shapeRows.forEach(function (c) {
      for (var n in res) { var i = r.statements.runs[n].lines.findIndex(function (l) { return l.shape === c.title; }); if (i >= 0) { c.line = i + 1; res[n].changes.push(c); return; } }
    });
    (first || []).forEach(function (c) { res[r.plan.runs[0]].changes.push(c); });
    (last || []).forEach(function (c) { res[r.plan.runs[r.plan.runs.length - 1]].changes.push(c); });
    return res;
  };
  // an arrow's row in the run whose statement draws it (the edge's ends, and its types), with that statement's line
  var arrowRow = function (r, res, e, is) {
    for (var n in res) {
      var i = r.statements.runs[n].lines.findIndex(function (l) { return l.edge && l.edge.from === e.from && l.edge.to === e.to && (l.edge.is || []).join() === (e.is || []).join(); });
      if (i >= 0) { res[n].changes.push(Object.assign({ line: i + 1, did: 'connected', kind: 'arrow', from: e.from, to: e.to }, is && is.length ? { is: is } : {})); return; }
    }
    throw new Error('no statement draws ' + JSON.stringify(e));
  };
  var cmpRows = function (r, result, runIndex) {
    var name = r.plan.runs[runIndex || 0];
    lineRows(r, name, result.changes);
    return compareRun0(r.plan, result, name, r.statements);
  };
  // what the file holds once a plan is drawn, as a query says it (a title and the containers it is in), and the plan's results with their rows' lines
  var inFile = function (plan) { var w = placesm.placesOf(plan); return [...w.byKey.keys()].map(function (k) { return { title: w.byKey.get(k).title, inside: w.containers(k) }; }); };
  var sizesOf = function (d) { var m = model.buildModel(d); return sizes.sizesFrom(m, helpers.estimateMeasure(m)); };
  var planOf = async function (d, opts) { return planm.planDigest(d, sizesOf(d), opts || {}, elk); };
  // a plan must be self-consistent: nothing overlaps, shapes inside their frames 40 clear, pills inside their start's frame
  function checkPlan(plan) {
    plan.boards.forEach(function (b) {
      var by = {}; b.shapes.forEach(function (s) { by[s.title] = s; });
      var boxes = b.shapes.map(function (s) { return { id: s.title, x: s.x, y: s.y, w: s.w, h: s.h, kind: s.kind }; })
        .concat(b.pills.map(function (p, i) { return { id: 'pill' + i + p.start, x: p.x, y: p.y, w: p.w, h: p.h, kind: 'pill', start: p.start }; }));
      var anc = function (t) { var out = new Set(); var s = by[t]; while (s && s.in) { out.add(s.in); s = by[s.in]; } return out; };
      for (var i = 0; i < boxes.length; i++) for (var j = i + 1; j < boxes.length; j++) {
        var a = boxes[i], c = boxes[j];
        if (a.kind === 'frame' && (anc(c.id).has(a.id) || (c.kind === 'pill' && anc(c.start).has(a.id)))) continue;
        if (c.kind === 'frame' && (anc(a.id).has(c.id) || (a.kind === 'pill' && anc(a.start).has(c.id)))) continue;
        var ov = a.x < c.x + c.w && c.x < a.x + a.w && a.y < c.y + c.h && c.y < a.y + a.h;
        assert(!ov, 'overlap on ' + b.board + ': ' + a.id + ' and ' + c.id);
      }
      b.shapes.forEach(function (s) {
        assert(s.x >= 0 && s.y >= 0, 'negative offset ' + s.title);
        if (s.in) { var f = by[s.in]; assert(s.x >= f.x + 40 && s.y >= f.y + 40 && s.x + s.w <= f.x + f.w - 40 && s.y + s.h <= f.y + f.h - 40, s.title + ' is not 40 inside ' + s.in); }
      });
      b.pills.forEach(function (p) { var st = by[p.start]; if (st.in) { var f = by[st.in]; assert(p.x + p.w <= f.x + f.w - 40 && p.y >= f.y + 40 && p.y + p.h <= f.y + f.h - 40, 'pill of ' + p.start + ' leaves ' + st.in); } });
    });
  }
  var pillSet = function (plan) { var s = []; plan.boards.forEach(function (b) { b.edges.forEach(function (e) { if (e.via) s.push(b.board + '|' + e.from + '>' + e.to); }); }); return s.sort(); };

  await test('no edges: the notes are packed, nothing promoted, nothing overlaps', async function () {
    var nodes = [{ title: 'F', kind: 'frame' }];
    for (var i = 0; i < 12; i++) nodes.push(note('Note ' + (i < 10 ? '0' : '') + i, i < 8 ? 'F' : null, 'Text ' + i));
    var r = await planOf(digest(nodes, []));
    eq(r.report.promotions.length, 0, 'promotions');
    var rep = r.report.boards.root;
    assert(rep.algorithms.every(function (a) { return a.algorithm === 'rectpacking'; }), 'algorithms ' + JSON.stringify(rep.algorithms));
    eq(rep.end.arrows + rep.end.pills, 0, 'arrows and pills');
    assert(rep.end.aspect <= 3, 'aspect ' + rep.end.aspect);
    checkPlan(r.plan);
  });

  function ring(prefix, n, nodes, edges) { var t = []; for (var i = 1; i <= n; i++) { t.push(prefix + i); nodes.push(note(prefix + i)); } for (var j = 0; j < n; j++) edges.push({ from: t[j], to: t[(j + 1) % n] }); return t; }

  // a run's edge lines, in order, for a board
  var edgeLines = function (r, board) { var run = r.runs.find(function (x) { return new RegExp('-' + board + '-edges\\.draw$').test(x.name); }); return run ? run.text.split('\n').filter(Boolean) : []; };
  var viaTo = function (plan, target) { var out = []; plan.boards.forEach(function (b) { b.edges.forEach(function (e) { if (e.via && e.to === target) out.push(e); }); }); return out; };

  // frames of users in a ring, each user using the hub, which is in a frame of its own
  function hubFixture(nFrames, per, back) {
    var nodes = [{ title: 'Hub frame', kind: 'frame' }, note('Hub', 'Hub frame')], edges = [], users = [];
    for (var f = 1; f <= nFrames; f++) {
      var ft = 'Team ' + f; nodes.push({ title: ft, kind: 'frame' });
      var t = []; for (var i = 1; i <= per; i++) { var u = 'u' + f + '-' + i; t.push(u); users.push(u); nodes.push(note(u, ft)); edges.push({ from: u, to: 'Hub' }); }
      for (var j = 0; j < per; j++) edges.push({ from: t[j], to: t[(j + 1) % per] });
    }
    if (back) edges.push({ from: 'Hub', to: back });
    return { nodes: nodes, edges: edges, users: users };
  }

  await test('a hub of four frames: promoted first; each frame\'s users share one pill, whose host\'s edge is drawn first', async function () {
    var fx = hubFixture(4, 5);
    var r = await planOf(digest(fx.nodes, fx.edges));
    var p = r.report.promotions;
    assert(p.length >= 1 && p[0].node === 'Hub', 'first promotion ' + (p[0] && p[0].node));
    assert(p[0].after < p[0].before, 'cost fell');
    var via = viaTo(r.plan, 'Hub');
    eq(via.length, 20, 'twenty users convert');
    var pills = r.plan.boards[0].pills.filter(function (x) { return x.for === 'Hub'; });
    eq(pills.length, 4, 'a pill per frame: sharing makes one pill per container');
    assert(pills.every(function (x) { return x.users === 5; }), 'each pill is for the 5 users of its frame');
    assert(via.every(function (e) { return e.share === true; }), 'every edge of a group says share: true');
    var lines = edgeLines(r, 'root');
    pills.forEach(function (pl) {
      var frame = 'Team ' + pl.start.charAt(1);
      var mine = lines.filter(function (l) { return /"Hub" via: reference/.test(l) && l.indexOf('"u' + pl.start.charAt(1) + '-') === 5; });
      eq(mine.length, 5, 'five lines for ' + frame);
      assert(lines.indexOf(mine[0]) < lines.indexOf(mine[1]) && mine[0].indexOf('edge "' + pl.start + '"') === 0, 'the host\'s edge comes first in ' + frame + ': ' + mine[0] + ' (host ' + pl.start + ')');
    });
    checkPlan(r.plan);
  });

  await test('a user its hub uses back converts like the rest (the tie is only in the order candidates are tried)', async function () {
    var fx = hubFixture(3, 6, 'u1-1');
    var r = await planOf(digest(fx.nodes, fx.edges), { marginPills: 2 });   // the margin given: this test is about the tie, not about the layout's noise
    assert(r.report.promotions.length >= 1 && r.report.promotions[0].node === 'Hub', 'hub promoted: ' + JSON.stringify(r.report.promotions.map(function (x) { return x.node; })) + ' ' + r.report.boards.root.stop + ' ' + JSON.stringify(r.report.boards.root.lastBest) + ' cap ' + JSON.stringify(r.report.boards.root.budget));
    var ps = pillSet(r.plan);
    assert(ps.indexOf('root|u1-1>Hub') >= 0, 'u1-1 has a pill edge');
    eq(r.plan.boards[0].edges.filter(function (e) { return !e.via && e.from === 'u1-1' && e.to === 'Hub'; }).length, 0, 'u1-1 -> Hub is not a plain arrow');
    eq(viaTo(r.plan, 'Hub').length, 18, 'all eighteen users convert');
    eq(r.plan.boards[0].edges.filter(function (e) { return !e.via && e.from === 'Hub' && e.to === 'u1-1'; }).length, 1, 'the hub\'s own arrow to u1-1 stays plain');
  });

  await test('sharing: one pill per container, and a lone user a plain pill', async function () {
    var nodes = [{ title: 'Sub', kind: 'subboard' }, note('Hub', 'Sub'), { title: 'F', kind: 'frame' }, { title: 'G', kind: 'frame' }, note('F1', 'F'), note('F2', 'F'), note('F3', 'F'), note('G1', 'G'), note('G2', 'G'), note('Loose')];
    var edges = ['F1', 'F2', 'F3', 'G1', 'G2', 'Loose'].map(function (t) { return { from: t, to: 'Hub' }; });
    var r = await planOf(digest(nodes, edges), { promote: false });
    var root = r.plan.boards.find(function (b) { return b.board === 'root'; });
    var pills = root.pills.filter(function (x) { return x.for === 'Hub'; });
    eq(pills.map(function (x) { return x.users; }).sort(), [1, 2, 3], 'a pill for F\'s three, one for G\'s two, one for Loose');
    var byContainer = {}; pills.forEach(function (x) { byContainer[x.users] = x.start; });
    assert(['F1', 'F2', 'F3'].indexOf(byContainer[3]) >= 0, 'F\'s pill is beside one of F\'s users: ' + byContainer[3]);
    assert(['G1', 'G2'].indexOf(byContainer[2]) >= 0, 'G\'s pill is beside one of G\'s users');
    eq(byContainer[1], 'Loose', 'a lone user has a plain pill');
    var shared = viaTo(r.plan, 'Hub').filter(function (e) { return e.share; });
    eq(shared.length, 5, 'five edges say share: true, and Loose\'s does not');
    assert(edgeLines(r, 'root').filter(function (l) { return /"Loose" -> "Hub"/.test(l); }).every(function (l) { return !/share/.test(l); }), 'Loose\'s line has no share');
    eq(r.report.boards.root.end.pills, 3, 'three pills in the cost');
    checkPlan(r.plan);
  });

  await test('the host is the user that keeps the group\'s arrows shortest', async function () {
    var box = function (x, y) { return { x: x, y: y, w: 300, h: 200 }; };
    var boxes = new Map([['a', box(0, 0)], ['b', box(0, 400)], ['c', box(0, 800)], ['d', box(0, 1200)], ['e', box(0, 1600)]]);
    eq(layoutm.bestHost(boxes, ['a', 'b', 'c', 'd', 'e'], 150), 'c', 'the middle of a column');
    eq(layoutm.bestHost(boxes, ['d', 'e'], 150), 'd', 'a tie goes to the first title');
    // beside a cluster: the host is the one nearest the others, not the first title
    var b2 = new Map([['a', box(2000, 0)], ['b', box(0, 0)], ['c', box(0, 300)], ['d', box(400, 150)]]);
    var h = layoutm.bestHost(b2, ['a', 'b', 'c', 'd'], 150);
    assert(h !== 'a', 'not the outlier: ' + h);
    // and in a plan: the host named by the group is the one whose pill is nearest the others
    var nodes = [{ title: 'Sub', kind: 'subboard' }, note('Hub', 'Sub'), { title: 'F', kind: 'frame' }], edges = [];
    ['U1', 'U2', 'U3', 'U4', 'U5'].forEach(function (t, i) { nodes.push(note(t, 'F')); edges.push({ from: t, to: 'Hub' }); if (i) edges.push({ from: 'U' + i, to: t }); });
    var r = await planOf(digest(nodes, edges), { promote: false });
    var root = r.plan.boards.find(function (b) { return b.board === 'root'; });
    var pill = root.pills.find(function (x) { return x.for === 'Hub'; });
    var shapes = {}; root.shapes.forEach(function (s) { shapes[s.title] = s; });
    var len = function (host) { var p = { x: shapes[host].x + shapes[host].w + 80, y: shapes[host].y + shapes[host].h / 2 - 16, w: pill.w, h: 32 }; var t = 0; ['U1', 'U2', 'U3', 'U4', 'U5'].forEach(function (u) { if (u !== host) { var a = shapes[u]; t += Math.hypot(a.x + a.w / 2 - (p.x + p.w / 2), a.y + a.h / 2 - (p.y + 16)); } }); return t; };
    var best = Math.min.apply(null, ['U1', 'U2', 'U3', 'U4', 'U5'].map(len));
    assert(len(pill.start) <= best * 1.15, 'the host ' + pill.start + ' is within 15% of the best: ' + len(pill.start) + ' vs ' + best);
    var lines = edgeLines(r, 'root').filter(function (l) { return /"Hub" via: reference/.test(l); });
    assert(lines[0].indexOf('edge "' + pill.start + '"') === 0, 'the host\'s edge is drawn first');
  });

  await test('every user of a promoted hub converts to a pill: those in the hub\'s own frame too, and those the hub uses back (D17)', async function () {
    var nodes = [{ title: 'F', kind: 'frame' }, { title: 'G', kind: 'frame' }, note('Hub', 'F')], edges = [];
    var inF = ['f1', 'f2', 'f3'], inG = [];
    inF.forEach(function (t) { nodes.push(note(t, 'F')); edges.push({ from: t, to: 'Hub' }); });
    for (var i = 1; i <= 12; i++) { var t = 'g' + (i < 10 ? '0' : '') + i; inG.push(t); nodes.push(note(t, 'G')); edges.push({ from: t, to: 'Hub' }); }
    for (var j = 0; j < 12; j++) edges.push({ from: inG[j], to: inG[(j + 5) % 12] });
    edges.push({ from: 'Hub', to: 'f1' });
    var r = await planOf(digest(nodes, edges), { marginPills: 2 });
    assert(r.report.promotions.length >= 1 && r.report.promotions[0].node === 'Hub', 'the hub is promoted: ' + JSON.stringify(r.report.promotions.map(function (x) { return x.node; })));
    var plain = r.plan.boards[0].edges.filter(function (e) { return !e.via && e.to === 'Hub'; });
    eq(plain.length, 0, 'no plain arrow into the hub is left');
    eq(viaTo(r.plan, 'Hub').map(function (e) { return e.from; }).sort(), inF.concat(inG), 'F\'s users and G\'s have pill edges');
    eq(r.plan.boards[0].edges.filter(function (e) { return !e.via && e.from === 'Hub' && e.to === 'f1'; }).length, 1, 'the hub\'s own arrow out stays plain');
    checkPlan(r.plan);
  });

  // the board laid out the way the loop does: a Layouter, the state with nothing promoted, and its first layout
  async function layouterOf(d, opts) {
    var m = model.buildModel(d), sz = sizesOf(d);
    var L = new layoutm.Layouter(m, 'root', sz, opts || {}, elk);
    var state = { promoted: new Set(), order: [], fanned: new Set(), fans: [], apart: new Set(), hosts: new Map(), splits: new Map() };
    var layout = await L.layout(state);
    return { m: m, L: L, state: state, layout: layout, ev: costm.evaluate(m, layout, m.mu) };
  }

  await test('the gain rule is absolute: a node that is not popular is promoted when that cuts C by more than the margin, and not otherwise', async function () {
    var fx = hubFixture(4, 5);
    var d = digest(fx.nodes, fx.edges, { policy: { mess: 0.5 } });   // a pill costs 4 at 0.5, as the arithmetic below assumes
    var planOf0 = planOf;
    // no node is popular here: every move is a judgment call; and the view is square, where the hub's twenty arrows cross enough for promoting it to pay (in a wide view the frames go around the hub, and it does not)
    planOf = function (dd, opts) { return planOf0(dd, Object.assign({ popular: 100000, view: { w: 1000, h: 1000 } }, opts || {})); };
    try {
    var r = await planOf(d);
    var rep = r.report.boards.root, mu = 4;
    assert(rep.noise && rep.noise.n > 0, 'the margin was measured: ' + JSON.stringify(rep.noise));
    eq(rep.margin, rep.noise.margin, 'the margin is the measured one');
    assert(rep.margin >= 2 * mu && rep.margin % mu === 0, 'a whole number of pills, at least two: ' + rep.margin);
    assert(r.report.promotions.length >= 1, 'something is promoted');
    r.report.promotions.forEach(function (p) { assert(!p.popular, p.node + ' is under the dial\'s popular'); assert(p.gainC > rep.margin, p.node + ' gained ' + p.gainC + ', not over the margin ' + rep.margin); });
    var g1 = r.report.promotions[0].gainC;
    // a margin over the best gain: nothing is promoted, and the report says what the best candidate gained
    var tight = await planOf(d, { marginPills: Math.ceil(g1 / mu) + 1 });
    eq(tight.report.promotions.length, 0, 'no promotion');
    eq(tight.report.boards.root.stop, 'little-gain', 'stop');
    assert(tight.report.boards.root.lastBest && tight.report.boards.root.lastBest.gain <= tight.report.boards.root.margin, 'lastBest ' + JSON.stringify(tight.report.boards.root.lastBest));
    eq(tight.report.boards.root.margin, (Math.ceil(g1 / mu) + 1) * mu, 'the margin given is the margin used');
    // no margin: every promotion that cuts C at all
    var loose = await planOf(d, { marginPills: 0 });
    assert(loose.report.promotions.length >= r.report.promotions.length, 'a margin of 0 promotes at least as much');
    loose.report.promotions.forEach(function (p) { assert(p.gainC > 0, p.node + ' gained ' + p.gainC); });
    } finally { planOf = planOf0; }
  });

  await test('candidates: a node with two users, or one user in another container; not one user beside it, nor none', async function () {
    var nodes = [{ title: 'F', kind: 'frame' }, { title: 'G', kind: 'frame' }, note('Two', 'F'), note('One far', 'F'), note('One near', 'F'), note('None', 'F'),
      note('t1', 'F'), note('t2', 'F'), note('f1', 'G'), note('n1', 'F')];
    var edges = [{ from: 't1', to: 'Two' }, { from: 't2', to: 'Two' }, { from: 'f1', to: 'One far' }, { from: 'n1', to: 'One near' }];
    var x = await layouterOf(digest(nodes, edges));
    var names = promm.candidates(x.m, x.L, x.layout, x.ev, x.state).map(function (c) { return c.node; });
    assert(names.indexOf('Two') >= 0, 'two users, both beside it: ' + names);
    assert(names.indexOf('One far') >= 0, 'one user in another container: ' + names);
    eq(names.indexOf('One near'), -1, 'one user beside it is not');
    eq(names.indexOf('None'), -1, 'no users is not');
  });

  await test('a shared pill far from some of its users is split between nearer clusters, only if C drops, and the plan has a pill for each', async function () {
    // two rings of users at the two ends of a long chain, inside one frame, all using a hub in another frame
    var nodes = [{ title: 'Hub frame', kind: 'frame' }, note('Hub', 'Hub frame'), { title: 'Wide', kind: 'frame' }], edges = [], users = [];
    var ringOf = function (p, n) { var t = []; for (var i = 1; i <= n; i++) { t.push(p + i); users.push(p + i); nodes.push(note(p + i, 'Wide')); edges.push({ from: p + i, to: 'Hub' }); } for (var j = 0; j < n; j++) edges.push({ from: t[j], to: t[(j + 1) % n] }); return t; };
    var A = ringOf('a', 4), B = ringOf('b', 4), prev = A[0];
    for (var c = 1; c <= 8; c++) { nodes.push(note('c' + c, 'Wide')); edges.push({ from: prev, to: 'c' + c }); prev = 'c' + c; }
    edges.push({ from: prev, to: B[0] });
    var d = digest(nodes, edges);
    var on = await planOf(d), off = await planOf(d, { split: false });
    var rep = on.report.boards.root;
    assert(rep.promoted.indexOf('Hub') >= 0, 'the hub is promoted: ' + rep.promoted);
    assert(rep.splits.length >= 1, 'the far group is split: ' + JSON.stringify(rep.splits));
    rep.splits.forEach(function (sp) { assert(sp.after < sp.before, 'a split is kept only if C drops: ' + JSON.stringify(sp)); assert(sp.into.length >= 2, 'into clusters'); });
    var pillsIn = function (r) { return r.plan.boards[0].pills.filter(function (x) { return x.for === 'Hub' && users.indexOf(x.start) >= 0; }).length; };
    var sp0 = rep.splits[0];
    assert(pillsIn(on) > pillsIn(off), 'more pills with the split: ' + pillsIn(on) + ' against ' + pillsIn(off));
    eq(off.report.boards.root.splits.length, 0, 'split off: none');
    assert(rep.end.cost < off.report.boards.root.end.cost, 'C is lower with the split: ' + rep.end.cost + ' against ' + off.report.boards.root.end.cost);
    // every edge of a cluster says share: true, with a host among the cluster's own users
    var viaHub = viaTo(on.plan, 'Hub').filter(function (e) { return users.indexOf(e.from) >= 0; });
    viaHub.filter(function (e) { return e.share; }).forEach(function (e) { assert(users.indexOf(e.host) >= 0, 'the host is a user: ' + e.host); });
    checkPlan(on.plan);
  });

  // a frame "Wide" of users of a hub in another frame: groups of `n` users in rings, joined by chains of `gap` notes (none: one ring of n users)
  function wideFixture(rings, n, gap) {
    var nodes = [{ title: 'Hub frame', kind: 'frame' }, note('Hub', 'Hub frame'), { title: 'Wide', kind: 'frame' }], edges = [], users = [], rs = [];
    for (var r = 0; r < rings; r++) {
      var t = [], p = String.fromCharCode(97 + r);
      for (var i = 1; i <= n; i++) { t.push(p + i); users.push(p + i); nodes.push(note(p + i, 'Wide')); edges.push({ from: p + i, to: 'Hub' }); }
      for (var j = 0; j < n; j++) edges.push({ from: t[j], to: t[(j + 1) % n] });
      rs.push(t);
    }
    for (var q = 1; q < rings; q++) {
      var prev = rs[q - 1][0];
      for (var c = 1; c <= gap; c++) { var cn = 'c' + q + '-' + c; nodes.push(note(cn, 'Wide')); edges.push({ from: prev, to: cn }); prev = cn; }
      edges.push({ from: prev, to: rs[q][0] });
    }
    return { nodes: nodes, edges: edges, users: users };
  }
  var hubPills = function (r, users) { return r.plan.boards[0].pills.filter(function (x) { return x.for === 'Hub' && users.indexOf(x.start) >= 0; }); };

  await test('two far-apart groups of users in a frame get a shared pill each: the host\'s edge plain and first, the others saying share: "<host>"', async function () {
    var fx = wideFixture(2, 4, 8);
    var r2 = await planOf(digest(fx.nodes, fx.edges), { view: { w: 800, h: 4000 } });   // a view five times as tall as wide: the frame runs down it, its two rings at its ends
    var pills = hubPills(r2, fx.users);
    eq(pills.map(function (x) { return x.users; }).sort(), [4, 4], 'two shared pills of four users: ' + JSON.stringify(pills));
    var lines = edgeLines(r2, 'root');
    pills.forEach(function (pl) {
      var mine = lines.filter(function (l) { return / -> "Hub" via: reference/.test(l) && /^edge "[ab]\d"/.test(l) && l.indexOf('edge "' + pl.start.charAt(0)) === 0; });
      eq(mine.length, 4, 'four lines for the cluster of ' + pl.start);
      var iHost = lines.findIndex(function (l) { return l.indexOf('edge "' + pl.start + '" -> "Hub" via: reference') === 0; });
      assert(iHost >= 0 && !/share/.test(lines[iHost]), 'the host\'s edge is a plain pill: ' + lines[iHost]);
      mine.filter(function (l) { return l !== lines[iHost]; }).forEach(function (l) { assert(l.indexOf('share: "' + pl.start + '"') > 0, 'a member says share: "' + pl.start + '": ' + l); assert(lines.indexOf(l) > iHost, 'after the host\'s'); });
    });
    var rep = r2.report.boards.root;
    eq(rep.pillsPerHub.filter(function (x) { return x.target === 'Hub' && x.container === 'Wide'; })[0].perPill, [4, 4], 'the report: pills and users per pill for (Wide, Hub)');
    checkPlan(r2.plan);
  });

  await test('a tight group of the same size keeps one pill', async function () {
    var fx = wideFixture(1, 8, 0);
    for (var f = 1; f <= 3; f++) {   // three other frames of users make the hub worth promoting
      fx.nodes.push({ title: 'Team ' + f, kind: 'frame' });
      var t = []; for (var i = 1; i <= 5; i++) { var u = 't' + f + '-' + i; t.push(u); fx.nodes.push(note(u, 'Team ' + f)); fx.edges.push({ from: u, to: 'Hub' }); }
      for (var j = 0; j < 5; j++) fx.edges.push({ from: t[j], to: t[(j + 1) % 5] });
    }
    var r = await planOf(digest(fx.nodes, fx.edges));
    assert(r.report.promotions.length >= 1 && r.report.promotions[0].node === 'Hub', 'the hub is promoted');
    var pills = hubPills(r, fx.users);
    eq(pills.length, 1, 'one pill: ' + JSON.stringify(pills.map(function (x) { return x.users; })));
    eq(pills[0].users, 8, 'for the eight');
    var lines = edgeLines(r, 'root').filter(function (l) { return / -> "Hub"/.test(l) && /^edge "[a-z]\d"/.test(l); });
    assert(lines.filter(function (l) { return /share: "/.test(l); }).length === 7 && lines.filter(function (l) { return /share: true/.test(l); }).length === 0, 'seven say share: "<host>", none share: true');
  });

  await test('a higher --prefer never makes more pills', async function () {
    var fx = wideFixture(2, 4, 8), d = digest(fx.nodes, fx.edges);
    var counts = [];
    for (var pf of [0, 2, 8, 1000]) counts.push(hubPills(await planOf(d, { prefer: pf }), fx.users).length);
    for (var i = 1; i < counts.length; i++) assert(counts[i] <= counts[i - 1], 'pills by prefer 0, 2, 8, 1000: ' + counts);
    eq(counts[counts.length - 1], 1, 'a huge preference: one pill');
    assert(counts[0] >= 2, 'no preference: more than one: ' + counts);
  });

  await test('the split is never more than ceil(users / 3) pills, and a cluster of one is a plain pill', async function () {
    var fx = wideFixture(3, 4, 8), d = digest(fx.nodes, fx.edges);
    var r = await planOf(d, { prefer: 0 });
    assert(hubPills(r, fx.users).length <= Math.ceil(12 / 3), 'at most four pills for twelve users: ' + hubPills(r, fx.users).length);
    var lines = edgeLines(r, 'root');
    hubPills(r, fx.users).filter(function (x) { return x.users === 1; }).forEach(function (x) { assert(!/share/.test(lines.filter(function (l) { return l.indexOf('edge "' + x.start + '" -> "Hub"') === 0; })[0]), 'a lone user\'s line has no share'); });
  });

  await test('laid out again from where it is, a settled board stays: the same layout, the same C', async function () {
    var fx = hubFixture(3, 5);
    var x = await layouterOf(digest(fx.nodes, fx.edges));
    x.state.promoted.add('Hub'); x.state.order.push('Hub');
    var l1 = await x.L.layout(x.state);
    x.L.warm = true;
    var cv = await x.L.converge(x.state, l1, costm.evaluate, x.m.mu);
    var again = await x.L.layout(x.state), e2 = costm.evaluate(x.m, again, x.m.mu);
    assert(Math.abs(e2.cost - cv.ev.cost) < 0.5, 'C ' + e2.cost + ' against ' + cv.ev.cost);
    var boxes = function (l) { return JSON.stringify([...l.boxes].sort().map(function (e) { return [e[0], e[1].x, e[1].y]; })); };
    eq(boxes(again), boxes(cv.cur), 'the boxes');
    // and a nudge of a few units in some widths moves C by a small part of it
    x.L.nudge = function (cid) { return 4; };
    var nudged = costm.evaluate(x.m, await x.L.layout(x.state), x.m.mu);
    assert(Math.abs(nudged.cost - cv.ev.cost) < 0.25 * cv.ev.cost, 'a nudge moved C from ' + cv.ev.cost + ' to ' + nudged.cost);
    x.L.nudge = null;
  });

  await test('the noise: a measured spread, and a margin that is a whole number of pills, at least two', async function () {
    var fx = hubFixture(4, 5);
    var x = await layouterOf(digest(fx.nodes, fx.edges, { policy: { mess: 0.5 } })); x.L.warm = true;
    var cv = await x.L.converge(x.state, x.layout, costm.evaluate, x.m.mu);
    var cands = promm.candidates(x.m, x.L, cv.cur, cv.ev, x.state);
    var nz = await noisem.measureNoise(x.m, x.L, x.state, cv.cur, cv.ev, cands, x.m.mu, promm.ext, 4, 3);
    assert(nz.candidates >= 1 && nz.n === nz.candidates * 3 && nz.sd >= 0 && nz.margin >= 8 && nz.margin % 4 === 0, JSON.stringify(nz));
    assert(nz.margin >= noisem.NOISE_SIGMAS * nz.sd - 1e-9, 'the margin covers ' + noisem.NOISE_SIGMAS + ' sd: ' + JSON.stringify(nz));
    var none = await noisem.measureNoise(x.m, x.L, x.state, cv.cur, cv.ev, [], x.m.mu, promm.ext);
    eq(none.margin, 8, 'no candidates: the floor of two pills');
  });

  await test('the safety cap: 25% of the leaves, and the report calls it out when it, not the board, ends the loop', async function () {
    // seven hubs of eight users each, and users of eight uses each: none popular at mess 0.5 (9 arrows), so each move is a judgment call
    var nodes = [{ title: 'Hubs', kind: 'frame' }], edges = [], hubs = ['H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'H7'];
    hubs.forEach(function (h) { nodes.push(note(h, 'Hubs')); });
    for (var f = 1; f <= 2; f++) {
      nodes.push({ title: 'Team ' + f, kind: 'frame' });
      var t = []; for (var i = 1; i <= 4; i++) { t.push('u' + f + i); nodes.push(note('u' + f + i, 'Team ' + f)); }
      t.forEach(function (u, j) { edges.push({ from: u, to: t[(j + 1) % 4] }); hubs.forEach(function (h) { edges.push({ from: u, to: h }); }); });
    }
    var r = await planOf(digest(nodes, edges), { marginPills: 2, mess: 0.5 });   // the margin given, so the layout's noise does not stop the loop before the cap
    var b = r.report.boards.root;
    eq(b.budget.cap, 3, '25% of 15 leaves, rounded down (the dial at 0.5)');
    assert(r.report.promotions.every(function (p) { return !p.popular; }), 'no node here is popular');
    var capped = await planOf(digest(nodes, edges), { marginPills: 2, mess: 0.5, cap: 0.1 });   // the cap given: one move, which still pays
    b = capped.report.boards.root;
    eq(b.budget.cap, 1, '10% of 15 leaves');
    eq(capped.report.promotions.length, 1, 'one promotion, the cap');
    eq(b.stop, 'safety-cap', 'stopped by the cap');
    assert(b.safetyCap.hit === true && /SAFETY CAP/.test(b.safetyCap.note) && b.safetyCap.wouldHaveGained >= 0.02, 'the report calls it out: ' + JSON.stringify(b.safetyCap));
    var small = await planOf(digest([note('A'), note('B')], [{ from: 'A', to: 'B' }]));
    assert(small.report.boards.root.safetyCap === null, 'a board that stops of itself does not claim the cap');
  });

  await test('the same input gives byte-identical output, and the same in another order of nodes and edges', async function () {
    var d = fixture('acme'), s0 = sizesOf(d);
    var a = await planm.planDigest(d, s0, {}, elk), b = await planm.planDigest(JSON.parse(JSON.stringify(d)), JSON.parse(JSON.stringify(s0)), {}, elk);
    eq(JSON.stringify(a.plan), JSON.stringify(b.plan), 'plan.json');
    eq(a.runs.map(function (r) { return r.name + '\n' + r.text; }).join('\n'), b.runs.map(function (r) { return r.name + '\n' + r.text; }).join('\n'), 'runs');
    var d2 = JSON.parse(JSON.stringify(d)); d2.nodes.reverse(); d2.edges.reverse();
    var c = await planm.planDigest(d2, s0, {}, elk);
    eq(JSON.stringify(a.plan), JSON.stringify(c.plan), 'plan.json with the input reversed');
  });

  // ---- spines ----
  // the spine fixture: Band's cards A, B, C and D point at Base's notes and not at each other: X every card, Y A and B, Z C and D, V A and
  // C, W A alone. A pairs with B (two in common), C with D: rows [A, B] and [C, D], A and C on the left. (DigestTests draws it too.)
  function spineFixture(more) { var d = fixture('spine'); d.edges = d.edges.concat(more || []); return d; }
  var algorithmOf = function (r, container) { var a = r.report.boards.root.algorithms.find(function (x) { return x.container === container; }); return a && a.algorithm; };
  // the offset a maker's line places its pill at, from the shape it names: [x, y]
  var offsetIn = function (l, anchor) {
    var m = new RegExp('right of "' + anchor + '" left \\(gap: (\\d+)\\) below "' + anchor + '" top \\(gap: (\\d+)\\)').exec(l);
    return m ? [Number(m[1]), Number(m[2])] : null;
  };
  // where the exact placement a line gives (`right of origin (gap: x) below origin (gap: y)`, from the board's (0, 0); or `right of "A" left (gap: x)
  // below "B" top (gap: y)`, or `left of "A" right (gap: x)` and `above "B" bottom (gap: y)`, each axis against its own shape) puts a box of w x h, given
  // the boxes of the shapes it names by title: [x, y], or null when the line says none
  var placedAt = function (l, boxes, w, h) {
    var o = /right of origin \(gap: ([\d.]+)\) below origin \(gap: ([\d.]+)\)/.exec(l);
    if (o) return [Number(o[1]), Number(o[2])];
    var m = /(right of|left of) "([^"]+)" (left|right) \(gap: ([\d.]+)\) (below|above) "([^"]+)" (top|bottom) \(gap: ([\d.]+)\)/.exec(l);
    if (!m) return null;
    var P = boxes[m[2]], Q = boxes[m[6]], gx = Number(m[4]), gy = Number(m[8]);
    var px = m[3] === 'left' ? P.x : P.x + P.w, qy = m[7] === 'top' ? Q.y : Q.y + Q.h;
    return [m[1] === 'right of' ? px + gx : px - gx - w, m[5] === 'below' ? qy + gy : qy - gy - h];
  };

  await test('a frame of cards that point at many of the same shapes, and not at each other, is a spine: its shared pills between its two columns', async function () {
    var r = await planOf(spineFixture());
    eq(algorithmOf(r, 'Band'), 'spine', 'Band is a spine');
    assert(algorithmOf(r, 'Base') !== 'spine', 'Base, which points at nothing, is not');
    var root = rootOf(r.plan), by = {};
    root.shapes.forEach(function (s) { by[s.title] = s; });
    var pillsFor = function (t) { return root.pills.filter(function (p) { return p.for === t; }); };
    // the columns: A and C on the left, B and D on the right, each row's two level
    assert(by.A.x + by.A.w < by.B.x && by.C.x + by.C.w < by.D.x, 'A and C left of B and D');
    assert(by.A.y + by.A.h <= by.C.y, 'row [A, B] above row [C, D]');
    // a pill every card uses is one, between the columns, between the rows
    eq(pillsFor('X').map(function (p) { return p.users; }), [4], 'one pill for X, its four users');
    var x = pillsFor('X')[0];
    assert(by.A.x + by.A.w < x.x && x.x + x.w < by.B.x, 'X between the columns');
    assert(Math.max(by.A.y + by.A.h, by.B.y + by.B.h) <= x.y && x.y + x.h <= Math.min(by.C.y, by.D.y), 'and between the rows');
    // one a row's cards share is beside that row
    eq(pillsFor('Y').map(function (p) { return p.users; }), [2]); eq(pillsFor('Z').map(function (p) { return p.users; }), [2]);
    var y = pillsFor('Y')[0], z = pillsFor('Z')[0];
    assert(y.x > by.A.x + by.A.w && y.y < by.A.y + by.A.h && y.y + y.h > by.A.y, 'Y beside row [A, B]');
    assert(z.x > by.C.x + by.C.w && z.y < by.C.y + by.C.h && z.y + z.h > by.C.y, 'Z beside row [C, D]');
    // users in two rows: each alone in its row has a copy of its own, a left card's on its left, as is a pill one card uses
    eq(pillsFor('V').map(function (p) { return p.start; }).sort(), ['A', 'C'], 'V twice, a copy each for A and C');
    pillsFor('V').concat(pillsFor('W')).forEach(function (p) { assert(p.x + p.w < by[p.start].x, 'the pill of ' + p.start + ' for ' + p.for + ' is on its left'); });
    // the script: each shared pill made by its first card's edge, where the plan has it, in Band; the others share it
    var lines = edgeLines(r, 'root');
    var band = by.Band;
    [['A', 'X', x], ['A', 'Y', y], ['C', 'Z', z]].forEach(function (k) {
      var l = lines.find(function (l) { return l.indexOf('edge "' + k[0] + '" -> "' + k[1] + '" via: reference in "Band" ') === 0; });
      assert(l, 'the maker of ' + k[1] + "'s pill: " + lines.join('\n'));
      eq(offsetIn(l, 'Band'), [k[2].x - band.x, k[2].y - band.y], 'its place in Band');
    });
    ['edge "B" -> "X" via: reference share: "A"', 'edge "C" -> "X" via: reference share: "A"', 'edge "D" -> "X" via: reference share: "A"',
      'edge "B" -> "Y" via: reference share: "A"', 'edge "D" -> "Z" via: reference share: "C"',
      'edge "A" -> "V" via: reference from: left', 'edge "A" -> "W" via: reference from: left', 'edge "C" -> "V" via: reference from: left'].forEach(function (l) {
      assert(lines.indexOf(l) >= 0, l + ' in ' + lines.join('\n'));
    });
    var maker = lines.findIndex(function (l) { return /^edge "A" -> "X"/.test(l); });
    assert(maker < lines.indexOf('edge "B" -> "X" via: reference share: "A"'), 'the maker before the edges that share its pill');
    eq(r.report.public.filter(function (t) { return 'VWXYZ'.indexOf(t) >= 0; }), ['V', 'W', 'X', 'Y', 'Z'], 'what a spine points at is public');
    checkPlan(r.plan);
    // byte for byte the same, and the same in another order
    var again = await planOf(spineFixture());
    eq(JSON.stringify(again.plan), JSON.stringify(r.plan), 'plan.json');
    eq(edgeLines(again, 'root'), lines, 'the edge run');
    var d2 = spineFixture(); d2.nodes.reverse(); d2.edges.reverse();
    var reversed = await planOf(d2);
    eq(JSON.stringify(reversed.plan), JSON.stringify(r.plan), 'plan.json with the input reversed');
  });

  await test('a frame whose cards point at each other is no spine, and its shared pills are in a host\'s column as ever; nor is any with promote off or at mess 1', async function () {
    var r = await planOf(spineFixture([{ from: 'A', to: 'B' }]));
    assert(algorithmOf(r, 'Band') !== 'spine', 'Band is laid out as any frame is: ' + algorithmOf(r, 'Band'));
    var lines = edgeLines(r, 'root');
    assert(lines.every(function (l) { return l.indexOf(' in "Band"') < 0 && l.indexOf('from: left') < 0; }), 'no pill placed by its edge, none on a left: ' + lines.join('\n'));
    assert(rootOf(r.plan).pills.every(function (p) { return !p.free; }), 'none free');
    checkPlan(r.plan);
    // nor is one where no arrow on a board is to be a pill: --promote off, and the dial at 1
    var off = await planOf(spineFixture(), { promote: false }), loose = await planOf(spineFixture(), { mess: 1 });
    [off, loose].forEach(function (x) {
      assert(algorithmOf(x, 'Band') !== 'spine', 'no spine: ' + algorithmOf(x, 'Band'));
      eq(rootOf(x.plan).pills.length, 0, 'every arrow plain');
    });
  });

  await test('a spine is three rows at most, and a shape that points at nothing pairs last, so the pill every other uses is still one', async function () {
    // n cards in a frame, each pointing at X and Y in another
    var cards = function (n) {
      var nodes = [{ title: 'Band', kind: 'frame' }, { title: 'Base', kind: 'frame' }, note('X', 'Base'), note('Y', 'Base')], edges = [];
      for (var i = 1; i <= n; i++) { var t = 'Card ' + i; nodes.push(note(t, 'Band')); edges.push({ from: t, to: 'X' }, { from: t, to: 'Y' }); }
      return digest(nodes, edges);
    };
    var six = await planOf(cards(6)), seven = await planOf(cards(7));
    eq(algorithmOf(six, 'Band'), 'spine', 'six cards, three rows: a spine');
    eq(rootOf(six.plan).pills.filter(function (p) { return p.for === 'X'; }).map(function (p) { return p.users; }), [6], "one pill for X, in the middle");
    assert(algorithmOf(seven, 'Band') !== 'spine', 'seven would be four rows: laid out as any frame is (' + algorithmOf(seven, 'Band') + ')');
    checkPlan(six.plan); checkPlan(seven.plan);
    // the spine fixture with a card in Band that points at nothing: it pairs after the others, and X, which every other card uses, is one pill
    var d = spineFixture(); d.nodes.push(note('Idle', 'Band'));
    var idle = await planOf(d);
    eq(algorithmOf(idle, 'Band'), 'spine');
    var root = rootOf(idle.plan), by = {};
    root.shapes.forEach(function (sh) { by[sh.title] = sh; });
    eq(root.pills.filter(function (p) { return p.for === 'X'; }).map(function (p) { return p.users; }), [4], 'one pill for X, its four users');
    assert(by.Idle.y > Math.max(by.C.y, by.D.y), 'Idle in a row of its own, under the others: ' + JSON.stringify([by.Idle, by.C, by.D]));
    checkPlan(idle.plan);
  });

  await test('a spine that is the board itself places its shared pills from the board\'s origin, as its shapes are', async function () {
    // Lib's board holds A, B and C, which point at X and Y on the root
    var nodes = [{ title: 'Lib', kind: 'subboard' }];
    ['A', 'B', 'C'].forEach(function (t) { nodes.push(note(t, 'Lib')); });
    ['X', 'Y'].forEach(function (t) { nodes.push(note(t)); });
    var edges = [{ from: 'A', to: 'X' }, { from: 'B', to: 'X' }, { from: 'C', to: 'X' }, { from: 'A', to: 'Y' }, { from: 'B', to: 'Y' }];
    var r = await planOf(digest(nodes, edges));
    eq(r.report.boards.Lib.algorithms.find(function (a) { return a.container === 'Lib'; }).algorithm, 'spine', "Lib's board is a spine");
    var lib = r.plan.boards.find(function (b) { return b.board === 'Lib'; }), x = lib.pills.find(function (p) { return p.for === 'X'; });
    eq(lib.pills.filter(function (p) { return p.for === 'X'; }).map(function (p) { return p.users; }), [3], 'one pill for X, its three users');
    var l = edgeLines(r, 'lib').find(function (l) { return l.indexOf('edge "A" -> "X" via: reference ') === 0; });
    assert(l && l.indexOf(' in "') < 0, 'in nothing: ' + l);
    var libBoxes = {}; lib.shapes.forEach(function (s) { libBoxes[s.title] = s; });
    assert(/ right of origin \(gap: [\d.]+\) below origin \(gap: [\d.]+\)/.test(l), 'from the board\'s origin: ' + l);
    eq(placedAt(l, libBoxes, x.w, x.h), [x.x, x.y], 'where the plan has it');
    eq(lib.shapes.map(function (s) { return s.title; }).sort(), ['A', 'B', 'C'], 'the board holds its shapes and nothing else');
    checkPlan(r.plan);
  });

  await test('promote off: every arrow plain, only the pills between boards; edges between boards are pills, public first', async function () {
    var nodes = [{ title: 'Sub', kind: 'subboard' }, note('Inner A', 'Sub'), note('Inner B', 'Sub'), note('Top A'), note('Top B')];
    var edges = [{ from: 'Top A', to: 'Top B' }, { from: 'Top A', to: 'Inner B' }, { from: 'Inner A', to: 'Top B' }, { from: 'Inner A', to: 'Inner B' }];
    var r = await planOf(digest(nodes, edges), { promote: false });
    eq(r.report.promotions.length, 0);
    var ps = pillSet(r.plan);
    eq(ps, ['Sub|Inner A>Top B', 'root|Top A>Inner B'], 'pills');
    assert(r.report.public.indexOf('Top B') >= 0 && r.report.public.indexOf('Inner B') >= 0, 'public: ' + r.report.public);
    var names = r.runs.map(function (x) { return x.name; });
    var firstEdge = names.findIndex(function (n) { return /-edges\.draw$/.test(n); });
    var lastShape = Math.max.apply(null, names.map(function (n, i) { return /-edges\.draw$/.test(n) ? -1 : i; }));
    assert(lastShape < firstEdge, 'every shape run precedes the edge runs: ' + names.join(' '));
    var rootTop = r.runs.find(function (x) { return /root-top/.test(x.name); }).text;
    assert(/"Top B".*public: true/.test(rootTop), 'Top B is made public in its shape run');
    checkPlan(r.plan);
  });


  // ---- the dial and the packing ----
  function gapOf(a, b) { var dx = Math.max(b.x - (a.x + a.w), a.x - (b.x + b.w), 0), dy = Math.max(b.y - (a.y + a.h), a.y - (b.y + b.h), 0); return Math.hypot(dx, dy); }
  function rootOf(plan) { return plan.boards.find(function (b) { return b.board === 'root'; }); }

  await test('the dial: every setting moves one way with mess (mu up, cap down, margin up, thresholds looser), 0.5 is the middle', async function () {
    var ds = [0, 0.1, 0.2, 0.3, 0.5, 0.7, 0.8, 0.9, 1].map(dialm.dial);
    for (var i = 1; i < ds.length; i++) {
      var a = ds[i - 1], b = ds[i];
      assert(b.mu >= a.mu && b.capShare <= a.capShare && b.marginPills >= a.marginPills, 'mu, cap, margin at ' + b.mess);
      assert(b.good.xPerArrow >= a.good.xPerArrow && b.good.fxPerArrow >= a.good.fxPerArrow && b.good.nePerArrow >= a.good.nePerArrow && b.good.aspect >= a.good.aspect, 'thresholds at ' + b.mess);
    }
    var m = dialm.dial(0.5);
    eq([m.mu, m.capShare, m.marginPills, m.good.xPerArrow, m.good.fxPerArrow, m.good.nePerArrow, m.good.aspect], [4, 0.25, 2, 0.1, 0.05, 0, 3], 'the middle');
    eq(dialm.dial(-3).mess, 0, 'clamped'); eq(dialm.dial(7).mess, 1, 'clamped'); eq(dialm.dial(null).mess, 0.1, 'the default is 0.1');
    // good enough is looser as mess grows: the same terms may pass at a higher mess and never the other way
    var terms = { NE: 2, X: 5, Fx: 1, aspect: 2.5 }, was = false;
    ds.forEach(function (d) { var g = dialm.isGood(d, terms, 50); assert(g || !was, 'good enough turned off as mess grew'); was = g; });
  });

  await test('the dial and the model: the flag wins over the digest policy; mu comes from mess; policy.references is ignored', async function () {
    var d = digest([note('A'), note('B')], [{ from: 'A', to: 'B' }], { policy: { mess: 0.2, references: 'fewer' } });
    eq(model.buildModel(d).dial.mess, 0.2, 'policy.mess');
    eq(model.buildModel(d, 0.9).dial.mess, 0.9, 'the flag wins');
    eq(model.buildModel(d).mu, dialm.dial(0.2).mu, 'mu is the dial\'s');
    eq(model.buildModel(digest([note('A')], [])).dial.mess, 0.1, 'no policy: 0.1');
  });

  await test('the dial is monotone: a lower mess never promotes fewer, on the same input', async function () {
    var inputs = [];
    var fx = hubFixture(4, 5); inputs.push(['hub of four frames', digest(fx.nodes, fx.edges)]);
    var fx2 = hubFixture(3, 6, 'u1-1'); inputs.push(['hub with a back edge', digest(fx2.nodes, fx2.edges)]);
    inputs.push(['acme', fixture('acme')]);
    inputs.push(['tree', fixture('tree')]);
    for (var k = 0; k < inputs.length; k++) {
      var counts = [];
      for (var mess of [0, 0.2, 0.4, 0.5, 0.6, 0.8, 1]) {
        var r = await planOf(inputs[k][1], { mess: mess });
        counts.push(r.report.promotions.length);
        checkPlan(r.plan);
      }
      for (var i = 1; i < counts.length; i++) assert(counts[i] <= counts[i - 1], inputs[k][0] + ': promotions by mess 0..1 ' + JSON.stringify(counts));
      assert(counts[counts.length - 1] === 0 || inputs[k][0] === 'x', inputs[k][0] + ': at mess 1 nothing is promoted: ' + JSON.stringify(counts));
      if (inputs[k][0] !== 'hub with a back edge') assert(counts[0] >= 1, inputs[k][0] + ': at mess 0 something is: ' + JSON.stringify(counts));
    }
  });

  await test('the dial says how far down the loop goes: the popular moves at a higher mess are the first of a lower mess\'s, a judgment call beats the margin, and Acme at 0.1 goes further than at 0.5, and at 0.5 further than at 0.8', async function () {
    var inputs = [['acme', fixture('acme')]], by = {};
    for (var k = 0; k < inputs.length; k++) {
      var orders = [];
      for (var mess of [0, 0.1, 0.2, 0.5, 0.8, 1]) {
        var r = await planOf(inputs[k][1], { mess: mess });
        // the popular moves, in the order they were made: the same list at every mess, cut where the dial's `popular` says
        orders.push(r.report.promotions.filter(function (p) { return p.popular; }).map(function (p) { return p.mode + ' ' + p.node; }));
        by[inputs[k][0] + mess] = r;
        assert(r.report.boards.root.end.aspect <= dialm.dial(mess).good.aspect, inputs[k][0] + ' ' + mess + ': the board is ' + r.report.boards.root.end.aspect + ' times as long as it is wide');
        r.report.promotions.forEach(function (p) {
          if (p.popular) assert(p.arrows >= dialm.dial(mess).popular, inputs[k][0] + ' ' + mess + ': ' + p.node + ' was moved as popular with ' + p.arrows + ' arrows');
          else assert(p.gainAtDial >= r.report.boards.root.marginKept - 1e-6, inputs[k][0] + ' ' + mess + ': ' + p.node + ' was accepted at ' + p.gainAtDial + ' against ' + r.report.boards.root.marginKept);
        });
      }
      for (var i = 1; i < orders.length; i++) eq(orders[i], orders[i - 1].slice(0, orders[i].length), inputs[k][0] + ': the popular moves at a higher mess are the first of a lower mess\'s');
    }
    var n = function (key) { return by[key].report.promotions.length; };
    assert(n('acme0.1') > n('acme0.5'), 'acme: 0.1 promotes ' + n('acme0.1') + ', 0.5 promotes ' + n('acme0.5'));
    assert(n('acme0.5') > n('acme0.8'), 'acme: 0.5 promotes ' + n('acme0.5') + ', 0.8 promotes ' + n('acme0.8'));
    // more pills at the tidy end, fewer plain arrows
    var plain = function (key) { return by[key].report.totals.arrows; };
    assert(plain('acme0.1') < plain('acme0.5') && plain('acme0.5') < plain('acme0.8'), 'plain arrows rise with mess: ' + [plain('acme0.1'), plain('acme0.5'), plain('acme0.8')]);
  });

  await test('without the safety cap the gain alone ends the loop, and a lower mess never stops earlier (Acme)', async function () {
    var canvas = fixture('acme'), counts = [];
    for (var mess of [0, 0.1, 0.2, 0.5, 0.8]) {
      var r = await planOf(canvas, { mess: mess, cap: 1 });
      eq(r.report.boards.root.stop, 'little-gain', 'stop at ' + mess);
      counts.push(r.report.promotions.length);
    }
    for (var i = 1; i < counts.length; i++) assert(counts[i] <= counts[i - 1], 'uncapped counts by mess ' + JSON.stringify(counts));
    assert(counts[1] > counts[3], 'uncapped: 0.1 goes further than 0.5: ' + JSON.stringify(counts));
  });

  await test('the dial moves the cap, and --cap / --margin override it', async function () {
    var fx = hubFixture(3, 6); var d = digest(fx.nodes, fx.edges);
    var lo = await planOf(d, { mess: 0 }), hi = await planOf(d, { mess: 1 });
    eq(lo.report.boards.root.budget.cap, Math.floor(0.5 * 19), 'cap at mess 0');
    eq(hi.report.boards.root.budget.cap, 0, 'cap at mess 1');
    eq(hi.report.promotions.length, 0, 'mess 1 promotes nothing');
    var ov = await planOf(d, { mess: 1, cap: 0.25 });
    eq(ov.report.boards.root.budget.cap, 4, 'an explicit cap wins');
    eq(ov.report.boards.root.overrides.cap, 0.25, 'and the report says so');
  });

  await test('pack: no box stranded from its nearest mate, boxes never overlap, the same input gives the same positions', async function () {
    var seed = 7; var rnd = function () { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    for (var trial = 0; trial < 12; trial++) {
      var n = 8 + Math.floor(rnd() * 10), items = [], pos = [];
      for (var i = 0; i < n; i++) { items.push({ w: 100 + Math.floor(rnd() * 250), h: 60 + Math.floor(rnd() * 120) }); }
      // scattered on a wide board, some far away (the stranded kind), made clear of each other first
      for (var i = 0; i < n; i++) pos.push({ x: Math.floor(rnd() * 6000), y: Math.floor(rnd() * 6000) });
      pos = elkm.removeOverlaps(items, pos, 64, 64);
      var edges = []; for (var i = 1; i < n; i += 2) edges.push({ a: i, b: Math.floor(rnd() * i), n: 1 });
      [false, true].forEach(function (squeeze) {
        var r = elkm.pack(items, pos, edges, 64, 64, squeeze), r2 = elkm.pack(items, pos, edges, 64, 64, squeeze);
        eq(r.pos, r2.pos, 'deterministic');
        var boxes = items.map(function (it, i) { return { x: r.pos[i].x, y: r.pos[i].y, w: it.w, h: it.h }; });
        for (var i = 0; i < n; i++) {
          var near = Infinity;
          for (var j = 0; j < n; j++) { if (i === j) continue; assert(!(boxes[i].x < boxes[j].x + boxes[j].w && boxes[j].x < boxes[i].x + boxes[i].w && boxes[i].y < boxes[j].y + boxes[j].h && boxes[j].y < boxes[i].y + boxes[i].h), 'overlap'); near = Math.min(near, gapOf(boxes[i], boxes[j])); }
          assert(near <= 160, 'trial ' + trial + ' squeeze ' + squeeze + ': box ' + i + ' is ' + Math.round(near) + ' from its nearest mate');
        }
      });
    }
  });

  await test('packing in a plan: no frame member far from its nearest frame mate, frames close together, at every mess', async function () {
    var d = fixture('acme');
    var fx = hubFixture(4, 5); var hub = digest(fx.nodes, fx.edges);
    for (var input of [d, hub]) {
      for (var mess of [0.2, 0.5, 0.8]) {
        var r = await planOf(input, { mess: mess });
        checkPlan(r.plan);
        var b = rootOf(r.plan);
        var units = b.shapes.filter(function (s) { return s.kind !== 'frame' && s.in; }).map(function (s) {
          var ps = b.pills.filter(function (p) { return p.start === s.title; });
          var x1 = Math.max.apply(null, [s.x + s.w].concat(ps.map(function (p) { return p.x + p.w; })));
          var y0 = Math.min.apply(null, [s.y].concat(ps.map(function (p) { return p.y; }))), y1 = Math.max.apply(null, [s.y + s.h].concat(ps.map(function (p) { return p.y + p.h; })));
          return { t: s.title, in: s.in, x: s.x, y: y0, w: x1 - s.x, h: y1 - y0 };
        });
        units.forEach(function (u) {
          var mates = units.filter(function (v) { return v.in === u.in && v !== u; });
          if (!mates.length) return;
          var near = Math.min.apply(null, mates.map(function (v) { return gapOf(u, v); }));
          assert(near <= 200, 'mess ' + mess + ': ' + u.t + ' is ' + Math.round(near) + ' from its nearest mate in ' + u.in);
        });
        var frames = b.shapes.filter(function (s) { return s.kind === 'frame' && !s.in; });
        frames.forEach(function (f) {
          var others = frames.filter(function (g) { return g !== f; });
          if (!others.length) return;
          var near = Math.min.apply(null, others.map(function (g) { return gapOf(f, g); }));
          assert(near >= 60 && near <= 160, 'mess ' + mess + ': ' + f.title + ' is ' + Math.round(near) + ' from the nearest frame (draw\'s gaps: 40, 80)');
        });
      }
    }
  });

  await test('packing: a hub whose arrows all became pills sits with its frame mates, not a board away', async function () {
    // Hub is promoted (it has pills for every user), so it has no plain arrow left in its own frame
    var fx = hubFixture(3, 6); var r = await planOf(digest(fx.nodes, fx.edges), { mess: 0.2 });
    assert(r.report.promotions.length >= 1, 'hub promoted');
    var b = rootOf(r.plan), hubS = b.shapes.find(function (s) { return s.title === 'Hub'; });
    var frame = b.shapes.find(function (s) { return s.title === 'Hub frame'; });
    assert(hubS.x >= frame.x + 40 && hubS.y >= frame.y + 40, 'the hub is inside its frame');
    assert(frame.w * frame.h <= 4 * hubS.w * hubS.h + 1, 'the hub\'s frame is not a mostly-empty field around a lone note: ' + frame.w + 'x' + frame.h);
  });

  // ---- the build: the digest checks, the measure script and JSON, the fixtures, the commands ----
  await test('check: duplicate titles (folded, case aside), long titles, titles in the file, unknown kinds', async function () {
    var ok = checkm.checkDigest(digest([note('A'), note('B', null, 'x')], [{ from: 'A', to: 'B' }]));
    eq(ok.errors, [], 'a clean digest');
    var dup = checkm.checkDigest(digest([note('Auth  service'), note('auth service')], []));
    assert(dup.errors.length === 1 && /duplicate title "auth service"/.test(dup.errors[0]), JSON.stringify(dup));
    var long = checkm.checkDigest(digest([note(new Array(82).join('x'))], []));
    assert(/over 80 characters/.test(long.errors[0]), JSON.stringify(long));
    // a title in the file is no error for a node: the scripts name every shape so that nothing outside the drawing can be meant. The --into title and a type's are the file's alone
    var inFile = checkm.checkDigest(digest([note('A'), note('B')], []), { existing: ['b', 'Other'] });
    eq(inFile.errors, [], 'a node may have a title that the file has: ' + JSON.stringify(inFile));
    var typeInFile = checkm.checkDigest(digest([{ title: 'Kind', kind: 'sticky-note', schema: { type: 'object' }, text: 'x' }, note('B')], []), { existing: ['kind'] });
    assert(typeInFile.errors.length === 1 && /"Kind" is a type, and the file already has a shape of that title/.test(typeInFile.errors[0]), JSON.stringify(typeInFile));
    var kinds = checkm.checkDigest(digest([{ title: 'A', kind: 'schema-card' }, { title: 'B', kind: 'sticky-note' }, { title: 'C', kind: 'frame' }], []), { kinds: ['sticky-note', 'frame', 'subboard'] });
    assert(kinds.errors.length === 1 && /"A"/.test(kinds.errors[0]), 'a kind the tool does not lay out: ' + JSON.stringify(kinds));
    var gone = checkm.checkDigest(digest([note('A'), { title: 'B', kind: 'subboard' }], []), { kinds: ['sticky-note', 'frame'] });
    assert(/the app has no kind subboard/.test(gone.errors[0]), JSON.stringify(gone));
    assert(checkm.checkDigest(digest([note('A', 'Nowhere')], [])).errors[0].indexOf('not a node') > 0, 'an unknown in');
    assert(checkm.checkDigest(digest([note('A')], [{ from: 'A', to: 'B' }])).errors[0].indexOf('unknown title') > 0, 'an edge to nothing');
  });

  await test('a node\'s source (what it was made from) is accepted, and changes nothing', async function () {
    var plain = digest([note('A'), note('B', null, 'x')], [{ from: 'A', to: 'B' }]);
    var sourced = digest([Object.assign(note('A'), { source: 'src/a.js' }), Object.assign(note('B', null, 'x'), { source: { path: 'src/b.js', line: 3 } })], [{ from: 'A', to: 'B' }]);
    eq(checkm.checkDigest(sourced).errors, [], 'check accepts it');
    eq((await planOf(sourced)).plan.boards, (await planOf(plain)).plan.boards, 'and the plan is the same');
  });

  await test('check: warns past 15 shapes in a frame and 150 on a board, and for an edge between a note and a frame', async function () {
    var nodes = [{ title: 'F', kind: 'frame' }];
    for (var i = 0; i < 16; i++) nodes.push(note('n' + i, 'F'));
    var r = checkm.checkDigest(digest(nodes, []));
    eq(r.errors, [], 'no error'); assert(r.warnings.length === 1 && /frame "F" holds 16/.test(r.warnings[0]), JSON.stringify(r.warnings));
    var big = []; for (var j = 0; j < 151; j++) big.push(note('b' + j));
    var rb = checkm.checkDigest(digest(big, []));
    assert(rb.warnings.length === 1 && /board "root" has 151/.test(rb.warnings[0]), JSON.stringify(rb.warnings));
    var re = checkm.checkDigest(digest([{ title: 'F', kind: 'frame' }, note('A')], [{ from: 'A', to: 'F' }]));
    eq(re.warnings, ['edge "A" -> "F" dropped: a note and a frame share no channel'], 'the warning');
  });

  // frames F and G on the first board, H in F, a subboard S holding a frame K, and edges at frames of every sort
  function frameEdges() {
    var nodes = [{ title: 'F', kind: 'frame' }, note('a1', 'F'), note('a2', 'F'), { title: 'H', kind: 'frame', in: 'F' }, note('h1', 'H'),
      { title: 'G', kind: 'frame' }, note('b1', 'G'), { title: 'S', kind: 'subboard' }, { title: 'K', kind: 'frame', in: 'S' }, note('k1', 'K')];
    var edges = [{ from: 'F', to: 'G' }, { from: 'G', to: 'S' }, { from: 'S', to: 'F' }, { from: 'H', to: 'G' }, { from: 'a1', to: 'a2' },
      { from: 'a1', to: 'F' }, { from: 'F', to: 'H' }, { from: 'S', to: 'K' }, { from: 'b1', to: 'F' }, { from: 'K', to: 'G' }, { from: 'G', to: 'F', via: 'reference' }];
    return digest(nodes, edges);
  }

  await test('edges at frames: two frames, and a frame and a subboard, on one board are arrows; a frame and what it holds, a note, another board and via: reference are dropped, each saying why', async function () {
    var d = frameEdges();
    eq(checkm.checkDigest(d).warnings, [
      'edge "a1" -> "F" dropped: a frame and what it holds are never connected',
      'edge "F" -> "H" dropped: a frame and what it holds are never connected',
      'edge "S" -> "K" dropped: a frame and what it holds are never connected',
      'edge "b1" -> "F" dropped: a note and a frame share no channel',
      'edge "K" -> "G" dropped: an edge at a frame is an arrow on one board, never a pill (none stands for a frame, which is never public, nor sits beside one)',
      'edge "G" -> "F" dropped: an edge at a frame is an arrow on one board, never a pill (none stands for a frame, which is never public, nor sits beside one)',
    ], 'what is dropped, and why');
    var r = await planOf(d);
    checkPlan(r.plan);
    var root = r.plan.boards.find(function (b) { return b.board === 'root'; });
    eq(root.edges.map(function (e) { return e.from + '>' + e.to + (e.via ? ' via' : ''); }), ['F>G', 'G>S', 'H>G', 'S>F', 'a1>a2'], 'the arrows on the first board');
    eq(root.pills, [], 'no pill'); eq(r.report.public, [], 'nothing public');
    eq(edgeLines(r, 'root'), ['edge "F" -> "G"', 'edge "G" -> "S"', 'edge "H" -> "G"', 'edge "S" -> "F"', 'edge "a1" -> "a2"'], 'the edge script');
    var ms = sizes.measureScript(model.buildModel(d));
    eq(ms.split('\n').filter(function (l) { return /via: reference/.test(l); }), ['edge "S" -> "a2" via: reference'], 'a pill measured for the note pointed at, and none for an edge at a frame');
    // the arrows between the frames are the board's own: laid out by them, and none crosses a frame's border to reach its own end
    var rep = r.report.boards.root;
    var top = rep.algorithms.find(function (a) { return a.container === 'root'; });
    assert(top && top.algorithm !== 'rectpacking' && top.arrows === 4, 'the board is laid out by its arrows: ' + JSON.stringify(rep.algorithms));
    eq(rep.end.Fx, 0, 'no arrow crosses a frame border');
  });

  await test('edges at frames, the rest: a subboard and a frame on another board dropped as a pill would be, a frame and a subboard it holds as nesting, and is on an arrow at a frame refused', async function () {
    var d = digest([{ title: 'F', kind: 'frame' }, { title: 'Sub', kind: 'subboard', in: 'F' }, { title: 'Far', kind: 'subboard' }, { title: 'K', kind: 'frame', in: 'Far' }, note('k1', 'K'),
      { title: 'G', kind: 'frame' }, { title: 'R', kind: 'sticky-note', schema: { type: 'object' }, relationship: true, text: 'r' }],
      [{ from: 'Sub', to: 'F' }, { from: 'G', to: 'K' }, { from: 'F', to: 'G', is: 'R' }]);
    var r = checkm.checkDigest(d);
    eq(r.warnings.filter(function (w) { return / dropped: /.test(w); }), [
      'edge "Sub" -> "F" dropped: a frame and what it holds are never connected',
      'edge "G" -> "K" dropped: an edge at a frame is an arrow on one board, never a pill (none stands for a frame, which is never public, nor sits beside one)',
    ], 'what is dropped');
    assert(r.errors.some(function (e) { return e === 'edge "F" -> "G": is on an arrow at a frame; a relationship joins two notes'; }), JSON.stringify(r.errors));
  });

  await test('a subboard many frames point at stays where their arrows are: an edge at a frame is never a pill, so it is never promoted through them', async function () {
    var nodes = [{ title: 'Hub', kind: 'subboard' }], edges = [];
    for (var i = 1; i <= 7; i++) { nodes.push({ title: 'F' + i, kind: 'frame' }, note('n' + i, 'F' + i)); edges.push({ from: 'F' + i, to: 'Hub' }); }
    var r = await planOf(digest(nodes, edges));
    checkPlan(r.plan);
    eq(r.report.promotions, [], 'nothing promoted'); eq(r.report.public, [], 'nothing public');
    eq(pillSet(r.plan), [], 'no pill');
    eq(r.plan.boards[0].edges.length, 7, 'seven arrows');
  });

  await test('the measure script: every note and card once, then one edge through a reference to each end that is pointed at', async function () {
    var d = fixture('tree'), m = model.buildModel(d);
    var lines = sizes.measureScript(m).split('\n').filter(Boolean);
    var shapes = lines.filter(function (l) { return !/^edge /.test(l); }), edges = lines.filter(function (l) { return /^edge /.test(l); });
    var leaves = d.nodes.filter(function (n) { return n.kind !== 'frame'; }).length;
    eq(shapes.length, leaves, 'every note and subboard, and nothing else: no board has a note for what it is');
    assert(shapes.every(function (l) { return /^(sticky-note|subboard) "/.test(l); }), 'no frame is measured');
    assert(edges.every(function (l) { return / via: reference$/.test(l); }), 'every edge asks for a reference');
    eq(edges.length, sizes.pillTargets(m).length, 'one a target');
    assert(edges.every(function (l) { var p = /^edge "(.*)" -> "(.*)" via/.exec(l); return p[1] !== p[2]; }), 'no edge from a shape to itself');
    assert(shapes[0].indexOf(' below ') < 0 && shapes[1].indexOf(' below "') > 0, 'the first stands alone, the rest below it');
    assert(/size: 300x/.test(shapes.filter(function (l) { return /^sticky-note "Login"/.test(l); })[0]), 'a note asks for its width, not its height');
    // a text with quotes and a newline is escaped as draw reads it
    var q = sizes.measureScript(model.buildModel(digest([note('A', null, 'say "hi"\nthen go')], [])));
    assert(q.indexOf('text: "say \\"hi\\"\\nthen go"') > 0, q);
  });

  await test('the sizes read from canvas measure\'s JSON: shapes, pill widths, and the constants layout uses', async function () {
    var d = digest([note('A'), note('B'), { title: 'F', kind: 'frame' }, note('C', 'F')], [{ from: 'A', to: 'B', via: 'reference' }, { from: 'C', to: 'B' }]);
    var m = model.buildModel(d), me = helpers.estimateMeasure(m);
    me.shapes.find(function (s) { return s.title === 'A'; }).size = [300, 321];
    me.references.find(function (r) { return r.for === 'B'; }).size = [111, 30];
    me.constants = { gaps: { tight: 24, normal: 72 }, defaultGap: 72, referenceStep: 12, frameInset: 32, smallest: { frame: [100, 70] } };
    var sz = sizes.sizesFrom(m, me);
    eq(sz.shapes.A, { w: 300, h: 321, above: 30 }, 'a shape');
    eq(sz.pillWidth.B, 111, 'a pill\'s width'); eq(sz.constants.pillHeight, 30, 'and its height');
    eq([sz.constants.pillStep, sz.constants.frameInset, sz.constants.pillGap, sz.constants.tightGap], [12, 32, 72, 24], 'constants');
    eq(sz.constants.frameMin, { w: 100, h: 70 }, 'the smallest frame');
    var lost = JSON.parse(JSON.stringify(me)); lost.shapes = lost.shapes.filter(function (s) { return s.title !== 'C'; });
    var threw = ''; try { sizes.sizesFrom(m, lost); } catch (e) { threw = e.message; }
    assert(/no size for: C/.test(threw), 'a missing shape is refused: ' + threw);
    // the layout goes by them: frames are inset by 32, a pill column is 12 apart
    var r = await planm.planDigest(d, sz, { promote: false }, elk), root = r.plan.boards[0];
    var c = root.shapes.find(function (s) { return s.title === 'C'; }), f = root.shapes.find(function (s) { return s.title === 'F'; });
    assert(c.x >= f.x + 32 && c.y >= f.y + 32 && f.w >= 100 + 0 && f.h >= 70, 'the frame inset is the measured one: ' + JSON.stringify([c, f]));
    assert(c.x - f.x === 32 || c.y - f.y === 32, 'and the note is exactly that far in');
    var p = root.pills.find(function (x) { return x.for === 'B'; });
    eq(p.h, 30, 'a pill is as tall as measured'); eq(p.w, 111, 'and as wide');
  });

  await test('Acme: a plan the draw scripts can carry out: shapes in runs before every edge run, the pinned and promoted shapes public, only shapes it makes', async function () {
    var d = fixture('acme'), r = await planOf(d);
    var names = r.runs.map(function (x) { return x.name; });
    eq(names.slice().sort(), names.slice(), 'runs are numbered in order');
    var firstEdge = names.findIndex(function (n) { return /-edges\.draw$/.test(n); });
    names.forEach(function (n, i) { if (!/-edges\.draw$/.test(n)) assert(firstEdge < 0 || i < firstEdge, 'a shape run after an edge run: ' + n); });
    var pub = r.report.public;
    assert(pub.length >= r.report.promotions.length, 'public: ' + pub);
    var titles = d.nodes.map(function (n) { return n.title; });
    pub.forEach(function (t) { assert(titles.indexOf(t) >= 0, t + ' is public but is not a shape the digest makes'); assert(r.report.publicWhy[t], t + ' has no reason'); });
    var text = r.runs.filter(function (x) { return !/-edges\.draw$/.test(x.name); }).map(function (x) { return x.text; }).join('');
    var made = (text.match(/ public: true/g) || []).length;
    eq(made, pub.length, 'every public shape is made public in a shape run, and nothing else is');
    r.report.promotions.forEach(function (p) { assert(p.popular || p.before > p.after, p.node + ' cut the cost, or was popular'); });
    checkPlan(r.plan);
  });

  await test('a 3-level tree: a subboard holding a frame holding a frame; boards inner first, cross-board edges are pills, public first', async function () {
    var d = fixture('tree'), r = await planOf(d);
    eq(r.plan.boards.map(function (b) { return b.board; }), ['root', 'Backend'], 'boards: root first');
    var back = r.plan.boards[1], auth = back.shapes.find(function (s) { return s.title === 'Auth'; });
    eq(auth.in, 'Services', 'Auth is in Services'); eq(back.shapes.find(function (s) { return s.title === 'Services'; }).in, null, 'Services is on the board itself');
    assert(back.shapes.find(function (s) { return s.title === 'Login'; }).in === 'Auth', 'Login is two frames deep');
    var shapeRuns = r.runs.map(function (x) { return x.name; }).filter(function (n) { return /root-top|Backend|backend/.test(n); });
    assert(r.runs.some(function (x) { return /backend-in-2/.test(x.name); }), 'a run a depth of frames: ' + r.runs.map(function (x) { return x.name; }));
    // the gateway on the root board reaches Login on Backend through a pill, so Login is public
    var fromRoot = viaTo(r.plan, 'Login').filter(function (e) { return e.from === 'Gateway'; });
    eq(fromRoot.length, 1, 'Gateway -> Login is an edge through a reference');
    assert(r.report.public.indexOf('Login') >= 0, 'Login is public: ' + r.report.public);
    assert(r.report.promotions.length >= 1 && r.report.promotions.every(function (p) { return p.board === 'Backend'; }), 'promotions on the board where the hub is: ' + JSON.stringify(r.report.promotions.map(function (p) { return p.node + '@' + p.board; })));
    checkPlan(r.plan);
  });

  await test('a flat graph of 60 notes with no container: packed into a board of the dial\'s aspect, nothing overlaps, hubs promoted, every pill beside its start', async function () {
    var d = fixture('flat60'), r = await planOf(d);
    var root = r.plan.boards[0];
    eq(root.shapes.filter(function (s) { return s.kind === 'frame'; }).length, 0, 'no frame');
    assert(r.report.promotions.length >= 3, 'hubs promoted: ' + r.report.promotions.length);
    var w = 0, h = 0; root.shapes.concat(root.pills).forEach(function (s) { w = Math.max(w, s.x + s.w); h = Math.max(h, s.y + s.h); });
    assert(Math.max(w / h, h / w) <= dialm.dial(0.1).good.aspect * 1.25, 'a board ' + w + ' x ' + h);
    root.pills.forEach(function (p) { var st = root.shapes.find(function (s) { return s.title === p.start; }); assert(p.x === st.x + st.w + 80, 'a pill is 80 right of its start: ' + p.start); });
    checkPlan(r.plan);
  });

  await test('the commands: plan writes plan.json, report.json and the runs, prints a summary an agent can relay; unknown options are refused', async function () {
    var files = {}, out = [];
    var mio = { readText: function (p) { if (files[p] != null) return files[p]; return io.readText(p); }, writeText: function (p, t) { files[p] = t; }, mkdirp: function () {}, print: function (t) { out.push(t); }, now: function () { return 0; }, engine: 'test' };
    var d = fixture('acme'), m = model.buildModel(d);
    files['/d.json'] = JSON.stringify(d); files['/m.json'] = JSON.stringify(helpers.estimateMeasure(m));
    await clim.run(['plan', '/d.json', '/m.json', '/out'], mio);
    assert(files['/out/plan.json'] && files['/out/report.json'], 'files written');
    var runNames = Object.keys(files).filter(function (k) { return /^\/out\/runs\//.test(k); });
    assert(runNames.length >= 2, 'runs: ' + runNames);
    var summary = out.join('\n');
    assert(/^plan: 1 board\(s\), \d+ shapes, \d+ pills/.test(summary) && /public \(\d+\), all made by this run/.test(summary) && /\nstop: root /.test(summary), summary);
    out.length = 0;
    await clim.run(['measure-script', '/d.json'], mio);
    assert(/^sticky-note "/.test(out[0]), 'measure-script prints the script');
    out.length = 0;
    await clim.run(['check', '/d.json'], mio);
    eq(JSON.parse(out[0]).errors, [], 'check prints JSON');
    var threw = ''; try { await clim.run(['plan', '/d.json', '/m.json', '/out2', '--own-frame', 'keep'], mio); } catch (e) { threw = e.message; }
    assert(/unknown option --own-frame/.test(threw), 'a removed flag is refused: ' + threw.slice(0, 80));
    var off = ''; out.length = 0; await clim.run(['plan', '/d.json', '/m.json', '/out3', '--promote', 'off', '--mess', '0.8'], mio);
    assert(/mess 0.8/.test(out[0]) && JSON.parse(files['/out3/report.json']).promotions.length === 0, 'promote off promotes nothing');
  });

  await test('compare: a dry run\'s rows against the plan; an off box is a mismatch, a push or an order warning fails', async function () {
    var r = await planOf(digest([note('A'), note('B')], [{ from: 'A', to: 'B' }])), b = r.plan.boards[0];
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, at: [[s.x, s.y], [s.w, s.h]] }; });
    var good = cmpRows(r, { changes: rows, on: null, warnings: [] });
    eq(good.ok, true, JSON.stringify(good)); eq(good.shapesWithin1, b.shapes.length, 'all within 1');
    rows[1].at[0][0] += 5;
    var bad = cmpRows(r, { changes: rows, warnings: [] });
    eq(bad.ok, false, 'a box 5 off'); assert(bad.mismatches.length === 1, JSON.stringify(bad.mismatches));
    rows[1].at[0][0] -= 5;
    var pushed = cmpRows(r, { changes: rows, warnings: [{ line: 3, message: 'B was pushed 40 right' }] });
    eq(pushed.ok, false, 'a push fails'); eq(pushed.warnings.push, 1, 'and is counted');
    var view = cmpRows(r, { changes: rows, warnings: [{ line: 1, message: '2 shapes landed outside the view — --reveal brings them into view' }] });
    eq(view.ok, true, 'a shape outside the window is not the plan\'s business'); eq(view.warnings.view, 1, 'and is counted apart');
  });

  await test('--into: the whole digest goes in a subboard of that title, made by the first run; compare maps its board back to root', async function () {
    var d = fixture('acme');
    var r = await planOf(d, { into: 'Acme map' });
    eq(r.plan.into, 'Acme map');
    eq(r.plan.runs[0], '00-into.draw'); eq(r.runs[0].text, 'subboard "Acme map"\n');
    var top = r.runs[1].text.split('\n').filter(Boolean);
    r.runs.slice(1).forEach(function (run) { run.text.split('\n').filter(function (l) { return /^(sticky-note|frame|subboard) /.test(l); }).forEach(function (l) { assert(/ in "/.test(l), 'every shape is in something: ' + l); }); });
    assert(top.length && top.every(function (l) { return / in "Acme map" right of origin \(gap: \d+\) below origin \(gap: \d+\)/.test(l); }), 'shapes on the top board are in the subboard, placed from its board\'s origin: ' + top[0]);
    var plain = await planOf(d, {});
    assert(plain.plan.into === null && plain.plan.runs[0] !== '00-into.draw' && !/ in "Acme map"/.test(plain.runs[0].text), 'without --into nothing changes');
    var b = r.plan.boards[0];
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, at: [[s.x, s.y], [s.w, s.h]] }; });
    b.pills.forEach(function (p) { rows.push({ kind: 'reference', at: [[p.x, p.y], [p.w, p.h]] }); });
    var res = cmpRows(r, { changes: rows, on: { board: 'x', title: 'Acme map' }, warnings: [] });
    eq(res.ok, true, JSON.stringify(res));
    eq(res.pillRows, b.pills.length, 'pills counted'); eq(res.pillsWithin1, b.pills.length, 'and found against the root board: ' + JSON.stringify(res.pillDeltas.slice(0, 2)));
  });

  await test('check --into: the subboard\'s title may not be a node\'s or one in the file', async function () {
    var d = digest([note('A'), note('B')], []);
    eq(checkm.checkDigest(d, { into: 'Map' }).errors, []);
    assert(/also the --into title/.test(checkm.checkDigest(d, { into: 'a' }).errors.join()), 'a node\'s title, case aside');
    assert(/already on a board in the file/.test(checkm.checkDigest(d, { into: 'Map', existing: ['map'] }).errors.join()), 'a title of the file');
    assert(/over 80/.test(checkm.checkDigest(d, { into: new Array(90).join('x') }).errors.join()), 'too long');
  });

  await test('replay: the real runs\' results against the plan, every shape, pill and arrow; a missing run, a box off, a restated shape, a missing title fail', async function () {
    var replayRun = replaym.replay;
    var d = fixture('acme'), r = await planOf(d, {}), b = r.plan.boards[0];
    var names = r.plan.runs.map(function (n) { return n.replace(/\.draw$/, ''); });
    var mk = function () {
      return distribute(r, b.shapes.map(function (s) { return { did: 'created', title: s.title, kind: s.kind, at: [[s.x, s.y], [s.w, s.h]] }; }),
        b.pills.map(function (p) { return { did: 'created', kind: 'reference', at: [[p.x, p.y], [p.w, p.h]] }; }),
        b.edges.map(function (e) { return { did: 'connected', kind: 'arrow', from: e.from, to: e.to }; }));
    };
    var titles = inFile(r.plan);
    var ok = replayRun(r.plan, mk(), titles, r.statements);
    eq(ok.ok, true, ok.lines.join('\n')); eq(ok.lines[0], 'verify ok');
    eq([ok.shapesWithin1, ok.shapes, ok.pillsWithin1, ok.pills, ok.arrows, ok.arrowsPlanned], [b.shapes.length, b.shapes.length, b.pills.length, b.pills.length, b.edges.length, b.edges.length]);
    var gone = mk(); delete gone[r.plan.runs[r.plan.runs.length - 1]];
    assert(!replayRun(r.plan, gone, titles, r.statements).ok, 'a run that did not happen');
    var off = mk(); off[r.plan.runs[0]].changes[0].at[0][0] += 7;
    assert(/delta/.test(replayRun(r.plan, off, titles, r.statements).lines.join('\n')), 'a box 7 off names the shape');
    var restated = mk(); restated[r.plan.runs[0]].changes[0].did = 'updated';
    assert(/not created/.test(replayRun(r.plan, restated, titles, r.statements).lines.join('\n')), 'a restated shape');
    var lacking = replayRun(r.plan, mk(), titles.slice(1), r.statements);
    assert(!lacking.ok && /not in the file/.test(lacking.lines.join('\n')), 'a title the file lacks');
    var fewer = mk(); fewer[r.plan.runs[r.plan.runs.length - 1]].changes.pop();
    assert(/arrows landed/.test(replayRun(r.plan, fewer, titles, r.statements).lines.join('\n')), 'an arrow that did not land');
    eq(names.length, r.plan.runs.length);
  });

  await test('extract: what the driver reads out of canvas\'s JSON', async function () {
    var ex = (await import('../lib/replay.mjs')).extract;
    eq(ex('titles', { rows: [{ title: 'A' }, { kind: 'arrow' }, { title: 'B' }] }), ['A', 'B']);
    eq(ex('kinds', [{ kind: 'sticky-note' }, { kind: 'frame' }]), ['sticky-note', 'frame']);
    eq(ex('id', { id: 4, name: 'Plans' }), 4);
    eq(ex('count', { count: 7, rows: [] }), 7);
    var threw = ''; try { ex('nope', {}); } catch (e) { threw = e.message; }
    assert(/not titles, root-titles, places, root-places, kinds, id, count or errors/.test(threw), threw);
  });

  // ---- what reviewing 9716c09f and 4840572f found ----------------------------------------------------------------

  await test('a pill 400 units off the plan fails compare and replay, as a shape does; a pill on the plan passes', async function () {
    var replayRun = replaym.replay;
    var r = await planOf(fixture('acme'), {}), b = r.plan.boards[0];
    assert(b.pills.length >= 2, 'the plan has pills: ' + b.pills.length);
    var mk = function (shift) {
      var changes = [];
      b.shapes.forEach(function (s) { changes.push({ did: 'created', title: s.title, kind: s.kind, at: [[s.x, s.y], [s.w, s.h]] }); });
      b.pills.forEach(function (p, i) { changes.push({ did: 'created', kind: 'reference', at: [[p.x + (i === 0 ? shift : 0), p.y], [p.w, p.h]] }); });
      return changes;
    };
    var good = cmpRows(r, { changes: mk(0), on: null, warnings: [] });
    eq(good.ok, true, JSON.stringify(good.mismatches)); eq(good.pillsWithin1, b.pills.length, 'every pill within 1');
    var bad = cmpRows(r, { changes: mk(400), on: null, warnings: [] });
    eq(bad.ok, false, 'a pill 400 off fails compare'); assert(bad.worstPill > 1 && bad.pillsWithin1 < b.pills.length, 'and is counted: ' + bad.worstPill);
    assert(bad.mismatches.some(function (m) { return /^pill of .* for .*: delta -?\d+,-?\d+$/.test(m); }), 'and names the pill: ' + JSON.stringify(bad.mismatches));
    assert(/MISMATCH[\s\S]*pill of/.test(clim.compareText(bad)), 'the text says so');
    var titles = inFile(r.plan);
    var drawn = function (shift) {
      var all = mk(shift), results = distribute(r, all.filter(function (c) { return c.kind !== 'reference'; }), all.filter(function (c) { return c.kind === 'reference'; }), b.edges.map(function (e) { return { did: 'connected', kind: 'arrow', from: e.from, to: e.to }; }));
      return results;
    };
    var results = drawn(0);
    eq(replayRun(r.plan, results, titles, r.statements).ok, true, 'on the plan: verify ok');
    results = drawn(400);
    var failed = replayRun(r.plan, results, titles, r.statements);
    eq(failed.ok, false, 'replay fails'); eq(failed.lines[0], 'verify FAILED');
    assert(/pill of .* delta /.test(failed.lines.join('\n')), failed.lines.join('\n'));
  });

  await test('a shape the plan creates must be created: found unchanged (or updated) on the board fails compare and replay, naming it', async function () {
    var r = await planOf(digest([note('A'), note('B')], [{ from: 'A', to: 'B' }])), b = r.plan.boards[0];
    var rows = b.shapes.map(function (s) { return { did: 'created', title: s.title, kind: s.kind, at: [[s.x, s.y], [s.w, s.h]] }; });
    eq(cmpRows(r, { changes: rows, warnings: [] }).ok, true, 'created passes');
    rows[1].did = 'unchanged';
    var res = cmpRows(r, { changes: rows, warnings: [] });
    eq(res.ok, false, 'unchanged fails'); assert(res.mismatches.join().indexOf('"' + rows[1].title + '" was unchanged, not created') >= 0, JSON.stringify(res.mismatches));
    assert(/drawn before/.test(res.mismatches.join()), 'and says the plan was drawn before');
    // an arrow row, or a reference row, with a did of its own is not a shape
    rows[1].did = 'created'; rows.push({ did: 'unchanged', kind: 'arrow', title: 'A', from: 'A', to: 'B' });
    eq(cmpRows(r, { changes: rows, warnings: [] }).ok, true, 'an arrow that was already there is not a shape');
  });

  await test('a cycle in `in` (A in B and B in A, A in A, or a tail leading into one) is refused by check and by the model, naming the titles, never a stack overflow', async function () {
    var cyc = function (pairs, extra) { return digest(pairs.map(function (p) { return { title: p[0], kind: 'frame', in: p[1] }; }).concat(extra || []), []); };
    var two = checkm.checkDigest(cyc([['A', 'B'], ['B', 'A']]));
    eq(two.errors.length, 1, JSON.stringify(two));
    assert(/"A" is in "B" is in "A"|"B" is in "A" is in "B"/.test(two.errors[0]) && /circle/.test(two.errors[0]), two.errors[0]);
    var self = checkm.checkDigest(cyc([['A', 'A']]));
    assert(/^"A" is in itself/.test(self.errors[0]), JSON.stringify(self));
    var tail = checkm.checkDigest(cyc([['A', 'B'], ['B', 'C'], ['C', 'B']], [note('N', 'A')]));
    assert(/circle/.test(tail.errors[0]) && /"B"/.test(tail.errors[0]) && /"C"/.test(tail.errors[0]) && !/"N"|"A" is in "B" is/.test(tail.errors[0]), tail.errors[0]);
    var thrown = ''; try { model.buildModel(cyc([['A', 'B'], ['B', 'A']])); } catch (e) { thrown = e.message; }
    assert(/circle/.test(thrown), 'the model refuses it: ' + thrown);
    var planned = ''; try { await planOf(cyc([['A', 'B'], ['B', 'A']])); } catch (e) { planned = e.message; }
    assert(/circle/.test(planned), 'and so does plan');
    eq(checkm.checkDigest(cyc([['A', null], ['B', 'A']])).errors, [], 'a chain that ends is fine');
  });

  await test('the driver\'s helpers: check-text and extract errors read check\'s JSON (a title with "error: " in it is no error); a file with more titles than one query lists is refused; clashes, into', async function () {
    var files = {}, out = [];
    var mio = { readText: function (p) { return files[p] != null ? files[p] : io.readText(p); }, writeText: function (p, t) { files[p] = t; }, mkdirp: function () {}, print: function (t) { out.push(t); }, now: function () { return 0; }, engine: 'test' };
    var d = digest([note('Parse error: unexpected token'), note('B')], [{ from: 'B', to: 'Parse error: unexpected token' }]);
    files['/d.json'] = JSON.stringify(d);
    await clim.run(['check', '/d.json'], mio);
    var res = JSON.parse(out[0]); eq(res.errors, [], 'no error'); out.length = 0;
    files['/c.json'] = JSON.stringify(res);
    await clim.run(['check-text', '/c.json'], mio); eq(out[0], 'ok'); out.length = 0;
    var ex = (await import('../lib/replay.mjs')).extract;
    eq(ex('errors', res), 0, 'no errors counted');
    var bad = checkm.checkDigest(digest([note('A'), note('a')], []));
    eq(ex('errors', bad), 1, 'one error counted');
    files['/e.json'] = JSON.stringify(bad);
    await clim.run(['check-text', '/e.json'], mio); assert(/^error: duplicate title/.test(out[0]), out[0]); out.length = 0;
    // more titles in the file than the query lists
    var threw = ''; try { ex('titles', { count: 10001, rows: new Array(10000).fill({ title: 'x' }) }); } catch (e) { threw = e.message; }
    assert(/10001 titled shapes and one query lists only 10000/.test(threw), 'refused, said: ' + threw);
    eq(ex('titles', { count: 2, rows: [{ title: 'A' }, { title: 'B' }] }), ['A', 'B'], 'all listed is fine');
    // the titles the file holds that the plan can't be drawn beside: the subboard's, and each a script names bare (the file didn't have it when the plan was made)
    var r = await planOf(fixture('acme'), { into: 'Acme map' });
    files['/plan.json'] = JSON.stringify(r.plan); files['/st.json'] = JSON.stringify(r.statements); files['/t.json'] = JSON.stringify(['CTO', 'Unrelated']);
    assert(r.statements.absent.indexOf('CTO') >= 0, 'a bare title is one the plan relies on the file not having');
    await clim.run(['clashes', '/plan.json', '/t.json', '/st.json'], mio);
    eq(out, ['error: "CTO" is on a board in the file now, and the scripts name shapes on the understanding that it is not (plan again, which reads the file\'s titles afresh)'], 'a clash'); out.length = 0;
    await clim.run(['clashes', '/plan.json', '/t.json'], mio); eq(out, [], 'with no statements, only the subboard it goes into is looked for: the file may have any other title'); out.length = 0;
    files['/t.json'] = JSON.stringify(['cto']);
    await clim.run(['clashes', '/plan.json', '/t.json', '/st.json'], mio); eq(out, [], 'draw tells "cto" from "CTO"'); out.length = 0;
    files['/t.json'] = JSON.stringify(['acme map']);
    await clim.run(['clashes', '/plan.json', '/t.json', '/st.json'], mio); assert(/"Acme map" is already/.test(out[0]), 'the subboard it goes into is a title too, folded for case as check does'); out.length = 0;
    files['/t.json'] = JSON.stringify(['Unrelated']);
    await clim.run(['clashes', '/plan.json', '/t.json', '/st.json'], mio); eq(out, [], 'none: nothing printed');
    await clim.run(['into', '/plan.json'], mio); eq(out, ['Acme map']); out.length = 0;
    files['/plan2.json'] = JSON.stringify((await planOf(fixture('acme'), {})).plan);
    await clim.run(['into', '/plan2.json'], mio); eq(out, [], 'a new file has none');
  });

  // ---- popular nodes, fanning out, and the longest arrow ----
  await test('a popular node is promoted whatever the layout measures: the most arrows first, by the dial\'s count, never at mess 1', async function () {
    var fx = hubFixture(4, 5);   // 20 users point at Hub
    var d = digest(fx.nodes, fx.edges);
    eq([dialm.dial(0).popular, dialm.dial(0.1).popular, dialm.dial(0.5).popular, dialm.dial(1).popular], [4, 5, 9, 14], 'the dial\'s popular');
    var r = await planOf(d, { marginPills: 100000 });   // a margin no measured gain beats
    eq(r.report.promotions.map(function (p) { return [p.mode, p.node, !!p.popular, p.arrows]; }), [['in', 'Hub', true, 20]], 'the hub, as popular, with its 20 arrows');
    eq(r.plan.boards[0].edges.filter(function (e) { return !e.via && e.to === 'Hub'; }).length, 0, 'no plain arrow into it is left');
    assert(r.report.public.indexOf('Hub') >= 0, 'and it is public');
    // under the count, it is a judgment call again: with that margin, nothing
    var few = hubFixture(1, 4);   // 4 users, under the 5 of mess 0.1, on a board that isn't good enough as it is (two arrows over notes)
    eq((await planOf(digest(few.nodes, few.edges), { marginPills: 100000 })).report.promotions.length, 0, 'four arrows are not popular at 0.1');
    eq((await planOf(digest(few.nodes, few.edges), { marginPills: 100000, mess: 0 })).report.promotions.map(function (p) { return p.node; }), ['Hub'], 'and are at mess 0');
    eq((await planOf(d, { mess: 1 })).report.promotions.length, 0, 'at mess 1 nothing moves');
    eq((await planOf(d, { promote: false })).report.promotions.length, 0, 'nor with promotion off');
    // the most arrows first
    var two = digest([note('Big'), note('Small')].concat(['a', 'b', 'c', 'd', 'e', 'f', 'g'].map(function (t) { return note(t); })),
      ['a', 'b', 'c', 'd', 'e', 'f', 'g'].map(function (t) { return { from: t, to: 'Big' }; }).concat(['a', 'b', 'c', 'd', 'e'].map(function (t) { return { from: t, to: 'Small' }; })));
    eq((await planOf(two, { marginPills: 100000 })).report.promotions.map(function (p) { return p.node + ' ' + p.arrows; }), ['Big 7', 'Small 5'], 'by arrows');
    // pills are for a mess: a star of eight lays out with nothing crossing, good enough as it is, and is left with its arrows, popular hub or not
    var star = digest([note('Hub')].concat(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map(function (x) { return note(x); })), ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map(function (x) { return { from: x, to: 'Hub' }; }));
    var left = await planOf(star, {});
    eq([left.report.promotions.length, left.report.boards.root.stop, left.report.boards.root.end.good], [0, 'good-enough', true], 'a board good enough as it is: ' + JSON.stringify(left.report.boards.root.goodTerms));
    eq(left.plan.boards[0].edges.filter(function (e) { return !e.via; }).length, 8, 'its eight arrows stay arrows');
    // on a tie, the first node by title, whichever way its move goes: A (or Z) points at B and four more in a frame, and four more in another point
    // at B (the frames make it a mess: arrows run over notes)
    var ties = [];
    for (var k = 0; k < 2; k++) {
      var src = ['A', 'Z'][k];
      var tie = digest([{ title: 'F', kind: 'frame' }, { title: 'G', kind: 'frame' }, note(src), note('B')].concat(['t1', 't2', 't3', 't4'].map(function (x) { return note(x, 'F'); })).concat(['u1', 'u2', 'u3', 'u4'].map(function (x) { return note(x, 'G'); })),
        [{ from: src, to: 'B' }].concat(['t1', 't2', 't3', 't4'].map(function (x) { return { from: src, to: x }; })).concat(['u1', 'u2', 'u3', 'u4'].map(function (x) { return { from: x, to: 'B' }; })));
      var first = (await planOf(tie, { marginPills: 100000 })).report.promotions[0];
      ties.push([first.mode, first.node, first.arrows]);
    }
    eq(ties, [['out', 'A', 5], ['in', 'B', 5]], 'five point at B and five leave the other: the first by title is moved first');
    checkPlan(r.plan);
  });

  await test('the summary names the moves the plan keeps: one the loop took back is not said to be promoted or fanned out', async function () {
    var rep = { totals: { pills: 0, sharedArrows: 0, arrows: 0 }, public: [], publicWhy: {}, warnings: [],
      promotions: [{ board: 'root', mode: 'in', node: 'Kept' }, { board: 'root', mode: 'in', node: 'Back' }, { board: 'Part', mode: 'out', node: 'Fan' }, { board: 'Part', mode: 'out', node: 'Fan back' }, { board: 'Part', mode: 'in', node: 'Back' }],
      boards: { root: { stop: 'little-gain', demotions: [{ board: 'root', mode: 'in', node: 'Back' }] }, Part: { stop: 'good-enough', demotions: [{ board: 'Part', mode: 'out', node: 'Fan back' }] } } };
    var text = clim.summarize({ report: rep, plan: { boards: [] }, runs: [], model: { dial: { mess: 0.1, longest: 1300 } } });
    assert(/promoted 2: Kept, Back;/.test(text), 'the promotion taken back on the root is left out; the one of that name on another board stays: ' + text);
    assert(/fanned out 1: Fan$/m.test(text), 'and so is the fan-out taken back: ' + text);
  });

  await test('a node that points at many is fanned out: each of its uses a pill beside it, what they stand for public; never to a shape that is never public, nor an edge that is never a pill', async function () {
    var targets = ['t1', 't2', 't3', 't4', 't5', 't6', 't7', 't8'];
    var nodes = [note('Joiner')].concat(targets.map(function (t) { return note(t); })).concat([{ title: 'Private', kind: 'sticky-note', text: 'x', public: false }, note('Plain')]);
    var edges = targets.map(function (t) { return { from: 'Joiner', to: t }; }).concat([{ from: 'Joiner', to: 'Private' }, { from: 'Joiner', to: 'Plain', direct: true }]);
    var r = await planOf(digest(nodes, edges), { marginPills: 100000 });
    eq(r.report.promotions.map(function (p) { return [p.mode, p.node, !!p.popular, p.arrows]; }), [['out', 'Joiner', true, 8]], 'the joiner, fanned out, for its 8 uses that may be pills');
    eq(r.report.boards.root.fanned, ['Joiner']); eq(r.report.boards.root.promoted, [], 'nothing is promoted');
    var out = r.plan.boards[0].edges.filter(function (e) { return e.from === 'Joiner'; });
    eq(out.filter(function (e) { return e.via; }).map(function (e) { return e.to; }).sort(), targets, 'each use is an edge through a reference');
    eq(out.filter(function (e) { return !e.via; }).map(function (e) { return e.to; }).sort(), ['Plain', 'Private'], 'the direct edge and the one to a shape that is never public stay arrows');
    eq(r.plan.boards[0].pills.filter(function (p) { return p.start === 'Joiner'; }).length, 8, 'eight pills beside it');
    eq(r.report.public.slice().sort(), targets, 'what the pills stand for is public, and the joiner is not');
    assert(/fanned out/.test(r.report.publicWhy.t1), 'and the report says why: ' + r.report.publicWhy.t1);
    var text = r.runs.map(function (x) { return x.text; }).join('\n');
    assert(/edge "Joiner" -> "t1" via: reference/.test(text) && /sticky-note "t1".*public: true/.test(text), 'drawn that way');
    assert(/fanned out 1: Joiner/.test(clim.summarize(r)), 'the summary says so');
    // the same node, pointed at by many, is promoted instead: the two ways round are counted apart
    var both = digest(nodes, targets.map(function (t) { return { from: t, to: 'Joiner' }; }));
    eq((await planOf(both, { marginPills: 100000 })).report.promotions.map(function (p) { return p.mode + ' ' + p.node; }), ['in Joiner']);
    checkPlan(r.plan);
  });

  await test('no arrow runs longer than the dial allows: it becomes a pill of its own beside its start, unless the digest says it never is one', async function () {
    eq([dialm.dial(0).longest, dialm.dial(0.1).longest, dialm.dial(0.5).longest, dialm.dial(1).longest], [1000, 1300, 2500, 4000], 'the dial\'s longest');
    // seven bands, a note in each: the top one points at the bottom one, six bands away
    var nodes = [], bands = [0, 1, 2, 3, 4, 5, 6];
    bands.forEach(function (i) { nodes.push({ title: 'Band ' + i, kind: 'frame', rank: i }); nodes.push(note('n' + i, 'Band ' + i, 'a note\nof three\nlines')); });
    var d = digest(nodes, [{ from: 'n0', to: 'n6' }, { from: 'n0', to: 'n1' }]);
    var r = await planOf(d, { marginPills: 100000 });
    var b = r.report.boards.root;
    eq(b.long.map(function (x) { return x.from + '>' + x.to; }), ['n0>n6'], 'the long one');
    assert(b.long[0].length > 1300 && b.longLeft === 0, JSON.stringify(b.long));
    eq(r.plan.boards[0].edges.map(function (e) { return e.from + '>' + e.to + (e.via ? ' via' : ''); }).sort(), ['n0>n1', 'n0>n6 via'], 'the long arrow is a pill, the short one an arrow');
    assert(r.report.public.indexOf('n6') >= 0 && /longer than the dial allows/.test(r.report.publicWhy.n6), 'n6 is public, and the report says why');
    assert(/long arrows: 1 made pills/.test(clim.summarize(r)), 'the summary says so');
    // an edge the digest says is never a pill stays an arrow, however long
    var keep = digest(nodes, [{ from: 'n0', to: 'n6', direct: true }]);
    var k = await planOf(keep, { marginPills: 100000 });
    eq(k.report.boards.root.long, []); eq(k.plan.boards[0].edges.map(function (e) { return !!e.via; }), [false], 'direct stays');
    // loose enough, and it is an arrow again
    eq((await planOf(d, { marginPills: 100000, mess: 0.8 })).report.boards.root.long, [], 'at 0.8 an arrow may run 3400');
    checkPlan(r.plan);
  });

  await test('an edge set apart is a pill of its own: it leaves the pill its container shares', async function () {
    var fx = hubFixture(1, 4);
    var m = model.buildModel(digest(fx.nodes, fx.edges)), sz = sizesOf(digest(fx.nodes, fx.edges));
    var L = new layoutm.Layouter(m, 'root', sz, {}, elk);
    var state = { promoted: new Set(['Hub']), order: ['Hub'], fanned: new Set(), fans: [], apart: new Set(), hosts: new Map(), splits: new Map() };
    var shared = L.pillPlan(state);
    eq(shared.groups.filter(function (g) { return g.target === 'Hub'; }).map(function (g) { return g.edges.length; }), [4], 'four users, one pill');
    state.apart = new Set(['u1-2' + '\u0000' + 'Hub']);
    var apart = L.pillPlan(state);
    eq(apart.groups.filter(function (g) { return g.target === 'Hub'; }).map(function (g) { return g.edges.length; }).sort(), [1, 3], 'one of its own, three still sharing');
    eq(apart.members.filter(function (x) { return x.e.from === 'u1-2'; }).length, 0, 'and its arrow runs to no one else\'s pill');
    assert((apart.byStart.get('u1-2') || []).some(function (en) { return en.e.to === 'Hub' && !en.shared; }), 'its pill is in its own column');
  });

  await test('no board has a note for what it is: each holds the digest\'s shapes alone, placed from its origin, and the digest\'s own text is drawn nowhere', async function () {
    var d = digest([{ title: 'T', kind: 'subboard' }, note('In T', 'T', 'x'), note('About T', null, 'taken')], [], { text: 'The whole, said once.' });
    var r = await planOf(d, { promote: false });
    eq(r.plan.boards.map(function (b) { return b.shapes.map(function (x) { return x.title; }).sort(); }), [['About T', 'T'], ['In T']], 'each board its own shapes: a note called "About T" is a note like any');
    eq(r.plan.boards.map(function (b) { return Object.keys(b).sort(); }), [['board', 'edges', 'pills', 'shapes'], ['board', 'edges', 'pills', 'shapes']], 'and nothing a board is placed from: its origin is the plan\'s (0, 0)');
    var all = r.runs.map(function (x) { return x.text; }).join('\n');
    assert(all.indexOf('The whole, said once.') < 0 && sizes.measureScript(model.buildModel(d)).indexOf('The whole, said once.') < 0, 'not drawn, not measured');
    var top = all.split('\n').filter(function (l) { return /^(sticky-note|subboard|frame) /.test(l) && !/ in "/.test(l); });
    assert(top.length === 2 && top.every(function (l) { return / right of origin \(gap: \d+\) below origin \(gap: \d+\)/.test(l); }), 'the root\'s shapes from its origin: ' + top.join(' | '));
  });

  // ---- ranks, descriptions, and drawing again in place ----
  // three ranked frames (Top 0, Mid 1, Low 2) and a note with no rank, with arrows that point up the ranks: a layered layout would put Low first; the ranks win
  function rankedDigest() {
    var nodes = [{ title: 'Low', kind: 'frame', rank: 2 }, { title: 'Top', kind: 'frame', rank: 0 }, { title: 'Mid', kind: 'frame', rank: 1 }, note('Loose', null, 'no rank')];
    ['A', 'B', 'C', 'D'].forEach(function (x) { nodes.push(note('Top ' + x, 'Top', 'x')); });
    nodes.push(note('Mid A', 'Mid', 'x'), note('Low A', 'Low', 'x'), note('Low B', 'Low', 'x'));
    return digest(nodes, [{ from: 'Low A', to: 'Top A' }, { from: 'Low B', to: 'Mid A' }, { from: 'Mid A', to: 'Top B' }]);
  }
  function shapesOf(r) { var by = {}; rootOf(r.plan).shapes.forEach(function (s) { by[s.title] = s; }); return by; }
  var isRows = function (by) { return by.Top.y + by.Top.h < by.Mid.y && by.Mid.y + by.Mid.h < by.Low.y; };
  var isColumns = function (by) { return by.Top.x + by.Top.w < by.Mid.x && by.Mid.x + by.Mid.w < by.Low.x; };

  await test('ranked frames as rows are in rank order, each as wide as the widest, what they hold centred; an unranked shape goes below them', async function () {
    var r = await planOf(rankedDigest(), { promote: false, ranks: 'rows' });
    var by = shapesOf(r);
    assert(isRows(by), 'top, mid, low: ' + [by.Top.y, by.Mid.y, by.Low.y]);
    assert(by.Low.y + by.Low.h < by.Loose.y, 'the unranked note is below the bands');
    eq([by.Mid.w, by.Low.w], [by.Top.w, by.Top.w], 'every band as wide as the widest');
    eq([by.Mid.x, by.Low.x], [by.Top.x, by.Top.x], 'the bands are flush');
    var mid = by['Mid A'];
    assert(Math.abs((mid.x + mid.w / 2) - (by.Mid.x + by.Mid.w / 2)) <= 1, 'a narrow band\'s note is centred in it');
    eq(r.report.boards.root.algorithms.find(function (a) { return a.container === 'root'; }).how, 'rows', 'the report says which way');
    checkPlan(r.plan);
  });

  await test('ranked frames as columns are in rank order left to right, each as tall as the tallest, what they hold at the top; an unranked shape goes after them', async function () {
    var r = await planOf(rankedDigest(), { promote: false, ranks: 'columns' });
    var by = shapesOf(r);
    assert(isColumns(by), 'top, mid, low: ' + [by.Top.x, by.Mid.x, by.Low.x]);
    assert(by.Low.x + by.Low.w < by.Loose.x, 'the unranked note is right of the bands');
    eq([by.Mid.h, by.Low.h], [by.Top.h, by.Top.h], 'every band as tall as the tallest');
    eq([by.Mid.y, by.Low.y], [by.Top.y, by.Top.y], 'the bands are flush');
    eq(by['Mid A'].y - by.Mid.y, 40, 'a short band\'s note is at its top');
    eq(r.report.boards.root.algorithms.find(function (a) { return a.container === 'root'; }).how, 'columns', 'the report says which way');
    checkPlan(r.plan);
  });

  await test('ranked frames run whichever way the view shows larger: columns in a wide view, rows in a tall one, and a band is laid out to its slot', async function () {
    var wide = await planOf(rankedDigest(), { promote: false, view: { w: 2400, h: 800 } }), tall = await planOf(rankedDigest(), { promote: false, view: { w: 800, h: 2400 } });
    var w = shapesOf(wide), t = shapesOf(tall);
    assert(isColumns(w), 'a wide view: columns');
    assert(isRows(t), 'a tall view: rows');
    // the band of four notes is laid out to its slot: narrower as a column of the wide view than as a row of it would be
    var rowsOfWide = shapesOf(await planOf(rankedDigest(), { promote: false, view: { w: 2400, h: 800 }, ranks: 'rows' }));
    assert(w.Top.w < rowsOfWide.Top.w, 'a column is narrower than the row: ' + w.Top.w + ' against ' + rowsOfWide.Top.w);
    eq([wide.report.view.from, wide.report.view.w], ['given', 2400], 'the report says the view the plan is for');
    checkPlan(wide.plan); checkPlan(tall.plan);
  });

  await test('a subboard\'s text is its description, written once what it may mention is drawn', async function () {
    var d = digest([{ title: 'Part', kind: 'subboard', text: 'What the part is, with @[Root note].' }, note('In part', 'Part', 'x'), note('Root note', null, 'y'), { title: 'Bare', kind: 'subboard' }, note('In bare', 'Bare', 'y')], []);
    var m = model.buildModel(d);
    var r = await planOf(d, { promote: false });
    var all = r.runs.map(function (x) { return x.text; }).join('\n');
    assert(all.indexOf('About') < 0, 'no board has a note for what it is');
    assert(!all.split('\n').some(function (l) { return /^subboard /.test(l) && /size:/.test(l) && /description:/.test(l); }), 'a subboard\'s card is drawn with no description: it is written after');
    var names = r.runs.map(function (x) { return x.name; });
    var describe = r.runs.filter(function (x) { return /-describe\.draw$/.test(x.name); });
    eq(describe.map(function (x) { return x.text; }), ['subboard "Part" description: "What the part is, with @[Root note]."\n'], 'one statement a card with a description, restating nothing else; Bare has none');
    eq(r.plan.described, (function () { var o = {}; o[describe[0].name] = ['Part']; return o; })(), 'the plan says which run describes which card');
    var lastShape = Math.max.apply(null, names.map(function (n, i) { return /-(top|in-\d+|types(-\d+)?|notes)\.draw$/.test(n) ? i : -1; }));
    assert(names.indexOf(describe[0].name) > lastShape, 'after every run that draws a shape: ' + names.join(' '));
    var mm = sizes.measureScript(m);
    assert(mm.indexOf('What the part is') < 0, 'a description is not measured');
    var none = await planOf(digest([note('A', null, 'x')], []), { promote: false });
    eq(none.plan.described, undefined, 'a digest with no description has none in its plan');
  });

  await test('two cards of one title in two frames, each with a description: each is described by the name that means it, and the plan names each by its key', async function () {
    var d = digest([{ title: 'A', kind: 'frame' }, { title: 'B', kind: 'frame' }, { title: 'Docs', kind: 'subboard', in: 'A', text: 'What A keeps.' },
      { title: 'Docs', kind: 'subboard', in: 'B', text: 'What B keeps.' }], []);
    var r = await planOf(d, { promote: false });
    var describe = r.runs.filter(function (x) { return /-describe\.draw$/.test(x.name); });
    eq(describe.length, 1, 'one run describes the first board\'s cards');
    eq(describe[0].text, 'subboard "A" > "Docs" description: "What A keeps."\nsubboard "B" > "Docs" description: "What B keeps."\n', 'each card by its path, with its own words');
    eq(r.plan.described[describe[0].name], ['Docs  in A', 'Docs  in B'], 'the plan names the cards it describes by their keys');
    eq(r.statements.runs[describe[0].name].lines.filter(function (l) { return l && l.describe != null; }).map(function (l) { return l.describe; }), ['Docs  in A', 'Docs  in B'], 'and so do the statements the results are matched to');
  });

  await test('a shape on the board itself is placed at its offset from the board\'s origin; a layout that reaches left of it or above it is moved right and down', async function () {
    var emitm = await import('../lib/emit.mjs');
    eq(emitm.fromOrigin({ x: 120, y: 0, w: 300, h: 200 }), 'right of origin (gap: 120) below origin (gap: 0)');
    var layout = function (boxes, frames, pills) { return { boxes: new Map(boxes), frames: new Map(frames || []), pills: pills || [] }; };
    eq(emitm.shiftOf(layout([['A', { x: 0, y: 0, w: 10, h: 10 }], ['B', { x: 40, y: 300, w: 10, h: 10 }]])), { x: 0, y: 0 }, 'a layout from its origin stays where it is');
    eq(emitm.shiftOf(layout([['A', { x: -40, y: 10, w: 10, h: 10 }]], [['F', { x: 0, y: -25, w: 100, h: 100 }]])), { x: 40, y: 25 }, 'a shape left of it, a frame above it');
    eq(emitm.shiftOf(layout([['A', { x: 0, y: 0, w: 10, h: 10 }]], [], [{ x: -16, y: -32, w: 80, h: 32 }])), { x: 16, y: 32 }, 'and a pill');
  });

  // draws the plan's shape runs as an app would, exactly: every shape where its placement puts it (each says where it goes: from its board's origin, or
  // from its frame's top-left), and the result is every title's box
  function simulate(r) {
    var boxesOf = {};
    r.runs.filter(function (x) { return /-(top|in-\d+|types(-\d+)?|notes)\.draw$/.test(x.name); }).forEach(function (run) {
      run.text.split('\n').filter(Boolean).forEach(function (l) {
        var m = /^(sticky-note|frame|subboard) "([^"]+)".* size: (\d+)x(\d+)/.exec(l);
        if (!m) return;
        var w = Number(m[3]), h = Number(m[4]), at = placedAt(l, boxesOf, w, h);
        assert(!/gap: -/.test(l), 'no negative gap: ' + l);
        assert(at, 'every shape says where it goes: ' + l);
        boxesOf[m[2]] = { x: at[0], y: at[1], w: w, h: h };
      });
    });
    return boxesOf;
  }
  // every shape lands where the plan has it: the plan's (0, 0) is its board's origin
  function landsAsPlanned(r, boxesOf) {
    r.plan.boards.forEach(function (b) {
      b.shapes.forEach(function (s) {
        var g = boxesOf[s.title];
        assert(g, b.board + ': ' + s.title + ' was not drawn');
        assert(Math.abs(g.x - s.x) < 1e-6 && Math.abs(g.y - s.y) < 1e-6 && g.w === s.w && g.h === s.h, b.board + ': ' + s.title + ' planned ' + JSON.stringify([s.x, s.y, s.w, s.h]) + ', placed ' + JSON.stringify([g.x, g.y, g.w, g.h]));
      });
    });
  }

  await test('every board\'s shapes land where the plan has them when placed as their runs say: from the board\'s origin, or from their frame\'s top-left', async function () {
    var names = ['acme', 'tree', 'flat60', 'spine', 'typed', 'inherit'];
    for (var i = 0; i < names.length; i++) {
      var r = await planOf(fixture(names[i]), { into: i % 2 ? 'Map' : null });
      landsAsPlanned(r, simulate(r));
      checkPlan(r.plan);
    }
    // subboards' boards of notes with no arrows, packed, beside a frame and a loose note on the root
    var nodes = [{ title: 'Part', kind: 'subboard', text: 'Part.' }, { title: 'Other', kind: 'subboard', text: 'Other.' }, { title: 'Frame', kind: 'frame' }];
    var words = ['Short', 'A rather longer note title here', 'Mid title', 'Tiny', 'The longest title of all, which makes its note the widest of them', 'Another one', 'And one more', 'Last'];
    words.forEach(function (w) { nodes.push(note(w, 'Part', 'x'), note(w + ' two', 'Other', 'y')); });
    nodes.push(note('In frame A', 'Frame', 'z'), note('In frame B', 'Frame', 'z'), note('Loose'));
    var many = await planOf(digest(nodes, []), { promote: false });
    landsAsPlanned(many, simulate(many));
    var lines = many.runs.filter(function (x) { return /-part-top\.draw$/.test(x.name); }).map(function (x) { return x.text; }).join('').split('\n').filter(Boolean);
    eq(lines.length, words.length, 'Part\'s board in one run');
    assert(lines.every(function (l) { return / in "Part" right of origin \(gap: \d+\) below origin \(gap: \d+\) /.test(l); }), 'each from its board\'s origin: ' + lines[0]);
  });

  await test('what the runs do on the app is compared to the plan as it is, and a description is checked as written, not as created', async function () {
    var rpl = await import('../lib/replay.mjs');
    var d = digest([{ title: 'Part', kind: 'subboard', text: 'The part, with @[Loose].' }, note('One', 'Part', 'x'), note('A longer second note', 'Part', 'y'), note('Third', 'Part', 'z'), note('Loose', null, 'w')], []);
    var r = await planOf(d, { promote: false });
    var boxesOf = {};
    var results = {};
    r.runs.forEach(function (run) {
      var changes = [], line = 0;
      run.text.split('\n').filter(Boolean).forEach(function (l) {
        var m = /^(sticky-note|frame|subboard) "([^"]+)"/.exec(l), sz = /size: (\d+)x(\d+)/.exec(l);
        line++;
        if (/-describe\.draw$/.test(run.name)) { var b = boxesOf[m[2]]; changes.push({ line: line, did: 'updated', kind: m[1], title: m[2], at: [[b.x, b.y], [b.w, b.h]] }); return; }
        var w = Number(sz[1]), h = Number(sz[2]), at = placedAt(l, boxesOf, w, h);
        boxesOf[m[2]] = { x: at[0], y: at[1], w: w, h: h };
        changes.push({ line: line, did: 'created', kind: m[1], title: m[2], at: [[boxesOf[m[2]].x, boxesOf[m[2]].y], [w, h]] });
      });
      results[run.name] = { changes: changes, warnings: [] };
    });
    var plm = await import('../lib/places.mjs');
    var inFile = function (plan) { var w = plm.placesOf(plan); return [...w.byKey.keys()].map(function (k) { return { title: w.byKey.get(k).title, inside: w.containers(k) }; }); };
    var ok = rpl.replay(r.plan, results, inFile(r.plan), r.statements);
    eq([ok.described, ok.describedPlanned, ok.restated], [1, 1, 0], 'one description, written once, and no shape restated: ' + ok.lines.join(' | '));
    assert(/descriptions 1\/1/.test(ok.lines[1]), 'the summary says it: ' + ok.lines[1]);
    // a description that changed nothing was not written
    var bad = JSON.parse(JSON.stringify(results)), name = r.runs.find(function (x) { return /-describe\.draw$/.test(x.name); }).name;
    bad[name].changes[0].did = 'unchanged';
    var fail = rpl.replay(r.plan, bad, null, r.statements);
    assert(!fail.ok && /was unchanged: its description or types were not written/.test(fail.problems.join()), 'said: ' + fail.problems.join(' | '));
    // the driver names a run as the plan does less `.draw`, and a dry run too: the same run, the same description
    var cmpm = await import('../lib/compare.mjs');
    eq([cmpm.compareRun(r.plan, results[name], name.replace(/\.draw$/, '') + ' (dry run)', r.statements).described, cmpm.compareRun(r.plan, results[name], name.replace(/\.draw$/, ''), r.statements).described], [1, 1], 'a description is a description under either name');
    // and a run that never happened is said
    var gone = JSON.parse(JSON.stringify(results)); delete gone[name];
    assert(/was planned/.test(rpl.replay(r.plan, gone, null, r.statements).problems.join()) || /no result was saved/.test(rpl.replay(r.plan, gone, null, r.statements).problems.join()), 'a description run that did not happen is said');
  });

  await test('drawing again in place: what a drawing makes, whether it is in a board\'s file, what is clear of it, and the script that takes it back', async function () {
    var rd = await import('../lib/redraw.mjs');
    var P = function (list) { return list.map(function (x) { return typeof x === 'string' ? { title: x, inside: [] } : x; }); };   // what the file holds, as a query says it: a title and the containers it is in
    var names = function (list) { return list.map(function (t) { return t.name; }).sort(); };
    var r = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('In part', 'Part', 'x'), note('Root note', null, 'y')], []), { promote: false });
    var d = rd.drawnRecord(r.plan, '/f.canvasboard', 7, 12);
    eq(d.into, null); eq(d.path, '/f.canvasboard'); eq(d.board, '7'); eq(d.name, 'T'); eq(d.shapes, 12);
    eq(rd.drawnRecord(r.plan, '/f.canvasboard', 7).shapes, null, 'while it is drawn, the count is not known');
    eq(names(d.root), ['"Part"', '"Root note"'], 'the root board\'s shapes, and the names a take-back gives them: bare, since their titles are their alone');
    eq(d.places.map(function (p) { return p.join(' > '); }).sort(), ['In part', 'Part', 'Part > In part', 'Root note'].filter(function (x) { return x !== 'In part'; }), 'and where every shape is');
    eq(d.titles.slice().sort(), ['In part', 'Part', 'Root note'], 'every title');
    assert(rd.sameFile(d, '/f.canvasboard', 9) && !rd.sameFile(d, '/g.canvasboard', 7) && !rd.sameFile(d, '', 7), 'by path, when there is one');
    var unsaved = rd.drawnRecord(r.plan, '', 4);
    assert(rd.sameFile(unsaved, '', 4, P(['Part', 'Mine'])) && !rd.sameFile(unsaved, '', 5, P(['Part'])), 'by id, for a board with no file');
    assert(!rd.sameFile(unsaved, '', 4, P(['In part', 'Mine'])) && !rd.sameFile(unsaved, '', 4), 'and only while a shape it put on the root is in it: a later board may get the id');
    assert(rd.sameFile(unsaved, '/f.canvasboard', 4, P(['Root note'])) && !rd.sameFile(unsaved, '/f.canvasboard', 4, P(['Mine'])) && !rd.sameFile(unsaved, '/f.canvasboard', 5, P(['Root note'])), 'a board saved since it was drawn on is still told by its id and the drawing\'s shapes');
    assert(rd.sameFile(rd.drawnRecord(r.plan, '/private/tmp/f.canvasboard', 7), '/tmp/f.canvasboard', 7) && !rd.sameFile(d, '/g.canvasboard', 7, P(['Part'])), 'a path is the file\'s own (/tmp is /private/tmp); two paths that differ are two files, whatever the id');
    eq(rd.minus(P(['Root note', 'Mine', 'root note', { title: 'Part', inside: ['Elsewhere'] }]), d), ['Mine', 'root note', 'Part'], 'the file less the drawing, by place: "root note" is another shape, and so is a Part somewhere else');
    eq([rd.beyond(d, 12), rd.beyond(d, 13), rd.beyond(d, 9), rd.beyond(rd.drawnRecord(r.plan, '/f', 7), 40)], [0, 1, 0, 0], 'shapes beyond the drawing: one added; fewer is fine; unknown counts none');
    eq(rd.foreign(P(['Part', 'Root note']), d), [], 'nothing foreign');
    // a folder of records, one a target file: the one told by the file's path, else by the board's id and the drawing's shapes; never another's
    var recs = [{ name: 'b.json', record: unsaved }, { name: 'a.json', record: d }];
    eq([rd.pickRecord(recs, '/f.canvasboard', 7, P(['Part'])), rd.pickRecord(recs, '/g.canvasboard', 7, P(['Part'])), rd.pickRecord(recs, '', 4, P(['Part'])), rd.pickRecord(recs, '', 4, P(['Mine'])), rd.pickRecord([], '/f.canvasboard', 7, [])], ['a.json', '', 'b.json', '', ''], 'the record of a file');
    var pn = rd.recordName('/tmp/f.canvasboard', 7, 'T');
    assert(pn === rd.recordName('/private/tmp/f.canvasboard', 9, 'x') && pn !== rd.recordName('/tmp/g.canvasboard', 7, 'T') && /^file-[0-9a-f]{16}\.json$/.test(pn), 'a file has one record name; two files two');
    assert(rd.recordName('', 4, 'T') !== rd.recordName('', 4, 'U') && /^board-4-[0-9a-f]{16}\.json$/.test(rd.recordName('', 4, 'T')), 'a board with no file: its id and the digest\'s title');
    eq(rd.replaceScript(d, P(['Part', 'In part'])), 'delete "Part"', 'the root\'s shapes the file still holds; a subboard takes what is on its board');
    eq(rd.replaceScript(d, P([])), '', 'nothing left to take back');
    var into = await planOf(digest([note('A', null, 'x')], []), { promote: false, into: 'Map' });
    var di = rd.drawnRecord(into.plan, '/f.canvasboard', 7);
    eq(rd.replaceScript(di, P(['Map', 'A', 'Part'])), 'delete "Map"', 'into a subboard: the subboard alone');
    eq(di.name, 'Map', 'and named by it, not by the digest\'s title: a subboard\'s title is the file\'s alone');
    // a drawing made in place of the last one, until it is whole: the record is of both, since an undo or two may bring the last one back
    var next = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('New note', null, 'z')], []), { promote: false });
    var both = rd.drawnRecord(next.plan, '/f.canvasboard', 7, 3, d, 12);   // it stopped with 3 shapes in the file, which held 12 before the take-back
    eq([both.shapes, both.was], [3, 12], 'how many shapes the file holds as it stopped, and held before the last drawing was taken back');
    eq(names(both.takes), ['"New note"', '"Part"', '"Root note"'], 'what takes either back');
    eq(both.names, ['T'], 'the name both are told by');
    assert(both.titles.indexOf('In part') >= 0 && both.titles.indexOf('New note') >= 0, 'the titles of both');
    eq(rd.foreign(P(['Part', { title: 'In part', inside: ['Part'] }, 'Root note']), both), [], 'the last drawing, undone back, is not foreign');
    eq([rd.beyond(both, 3), rd.beyond(both, 0), rd.beyond(both, 12)], [0, 0, 0], 'part of the new drawing, none of it, or the last one whole: nothing added');
    eq([rd.beyond(both, 14), rd.beyond(both, 5), rd.beyond(both, 11)], [2, 2, 8], 'an arrow and a note added to either are counted, so the take-back is refused; a count that is neither drawing\'s is too');
    var early = rd.drawnRecord(next.plan, '/f.canvasboard', 7, null, d, 12);   // stopped before a count was taken
    eq([early.shapes, rd.beyond(early, 9), rd.beyond(early, 12), rd.beyond(early, 13)], [null, 0, 0, 1], 'with no count of its own, up to the last drawing\'s may be part of this one');
    eq(rd.replaceScript(both, P(['Part', 'Root note', 'In part']), P(['Part', 'Root note'])), 'delete "Part"\ndelete "Root note"', 'the last drawing is taken back by its own shapes');
    eq(rd.replaceScript(both, P(['New note']), P(['New note'])), 'delete "New note"', 'and as much of the new one as was drawn by its');
    eq(rd.replaceScript({ into: null, root: [{ place: ['A'], name: '"A"' }, { place: ['B'], name: '"B"' }] }, P(['B'])), 'delete "B"', 'a record made before `takes` reads the same');
    // a shape the last drawing had on the root that this one holds inside a subboard goes with its subboard: one `delete` of it there
    // would put the script on two boards, which draw refuses
    var movedIn = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('Root note', 'Part', 'y')], []), { promote: false });
    var mv = rd.drawnRecord(movedIn.plan, '/f.canvasboard', 7, 2, d, 12);
    eq(rd.replaceScript(mv, P(['Part', 'Root note', 'In part']), P(['Part'])), 'delete "Part"', 'only what is on the root board');
    eq(rd.replaceScript(mv, P(['Part', 'Root note', 'In part']), P(['Part', 'Root note'])), 'delete "Part"\ndelete "Root note"', 'and the last drawing, undone back, by both');
    // the last one drawn as the board, this one into a subboard of it (or the other way round): the subboard where the file holds it, the root's shapes where they are on the root
    var intoB = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('In part', 'Part', 'x'), note('Root note', null, 'y')], []), { promote: false, into: 'B' });
    var mixed = rd.drawnRecord(intoB.plan, '/f.canvasboard', 7, 5, d, 12);
    eq([mixed.was, rd.beyond(mixed, 99)], [null, 0], 'a drawing into a subboard counts nothing of the file');
    eq(rd.replaceScript(mixed, P(['B', 'Part', 'Root note', 'In part']), P(['B'])), 'delete "B"', 'the new subboard, with the same titles inside it');
    eq(rd.replaceScript(mixed, P(['Part', 'Root note', 'In part']), P(['Part', 'Root note'])), 'delete "Part"\ndelete "Root note"', 'the last drawing, back on the root');
    // the other way round: the last one into a subboard, this one as the board, which is drawn only on a file the take-back left empty,
    // so the count before it is the last drawing's own
    var back = rd.drawnRecord(next.plan, '/f.canvasboard', 7, 2, rd.drawnRecord(intoB.plan, '/f.canvasboard', 7, 9), 9);
    eq([back.was, rd.beyond(back, 9), rd.beyond(back, 10), rd.beyond(back, 2)], [9, 0, 1, 0], 'the subboard\'s drawing, undone back, is not counted as shapes added');
    eq(rd.replaceScript(back, P(['B', 'Part', 'Root note', 'In part']), P(['B'])), 'delete "B"', 'and is taken back by its subboard');
    var intoUnsaved = rd.drawnRecord(intoB.plan, '', 4);
    assert(rd.sameFile(intoUnsaved, '', 4, P(['B', 'Mine'])) && !rd.sameFile(intoUnsaved, '', 4, P(['Mine'])), 'a drawing into a subboard that stopped after its first script is told by the subboard: nothing else is drawn yet');
    var rp = await import('../lib/replay.mjs');
    eq(rp.extract('root-titles', { rows: [{ board: 'root', title: 'A' }, { board: 'X', title: 'B' }, { board: 'root' }] }), ['A'], 'the titles on the root board');
    var renamed = rd.drawnRecord((await planOf(Object.assign(digest([note('A', null, 'x')], []), { title: 'U' }), { promote: false })).plan, '', 4, null, unsaved);
    assert(rd.sameFile(renamed, '', 4, P(['Part'])) && rd.sameFile(renamed, '', 4, P(['A'])), 'either drawing\'s shapes tell the board');
    eq(renamed.names, ['U', 'T'], 'and the record has both drawings\' names');
    eq([rd.hasTitle(['Root  note'], 'root note'), rd.hasTitle(['Root note'], 'Root')], [true, false], 'a title the file holds, spaces folded and case aside');
    var boards = [{ id: 2, path: '/a', fileShapes: 5, frontmost: false }, { id: 3, path: null, fileShapes: 0, frontmost: true }];
    boards[0].name = 'Plans'; boards[1].shows = 'root';
    eq([rd.boardField(boards, 'front', 'id'), rd.boardField(boards, '2', 'path'), rd.boardField(boards, 'front', 'path'), rd.boardField(boards, 'front', 'fileShapes'), rd.boardField(boards, 'Plans', 'id'), rd.boardField(boards, '/a', 'id'), rd.boardField(boards, 'front', 'shows')], [3, '/a', '', 0, 2, 2, 'root'], 'by id, file or name');
    var threw = ''; try { rd.boardField([], 'front', 'id'); } catch (e) { threw = e.message; }
    assert(/no board is open/.test(threw), threw);
    var twins = [{ id: 1, name: 'Plans', path: '/private/tmp/a/Plans.canvasboard' }, { id: 2, name: 'Plans', path: '/b/Plans.canvasboard' }];
    threw = ''; try { rd.boardField(twins, 'Plans', 'id'); } catch (e) { threw = e.message; }
    assert(/2 open boards are Plans \(boards 1, 2\)/.test(threw), 'a name two boards have is refused, with their ids: ' + threw);
    eq([rd.boardField(twins, '/tmp/a/Plans.canvasboard', 'id'), rd.boardField(twins, '/b/Plans.canvasboard', 'id'), rd.boardField(twins, '2', 'id')], [1, 2, 2], 'a file by its own path (/tmp is /private/tmp), and an id before a name');
    eq([rd.boardField(twins, '/link/Plans.canvasboard', 'id', '/b/Plans.canvasboard'), rd.boardField(twins, '/b/Plans.canvasboard', 'id', '/Volumes/D/Plans.canvasboard')], [2, 2], 'by the path as given or with its links resolved: the app lists the one the board was saved by');
  });

  await test('the tool\'s usage lists what is used: no svg, no --split, no verify; the svg command is gone', async function () {
    assert(!/svg/i.test(clim.USAGE) && !/--split/.test(clim.USAGE) && !/\bverify </.test(clim.USAGE), 'usage');
    var threw = ''; try { await clim.run(['svg', '/p.json', '/o'], { readText: io.readText, print: function () {} }); } catch (e) { threw = e.message; }
    assert(/^digest tool/.test(threw), 'svg is not a command');
    threw = ''; try { await clim.run(['plan', '/d.json', '/m.json', '/o', '--split', 'off'], { readText: io.readText, print: function () {} }); } catch (e) { threw = e.message; }
    assert(/unknown option --split/.test(threw), 'nor is --split a flag: ' + threw.slice(0, 60));
  });

  await test('a board is laid out to the shape of the view: wider than tall for a wide view, taller than wide for a tall one, and the report says how far off it is', async function () {
    var d = fixture('acme');
    var wide = await planOf(d, { view: { w: 1600, h: 800 } }), tall = await planOf(d, { view: { w: 800, h: 1600 } });
    var sizeOf = function (r) { return r.report.boards.root.end.size; };
    assert(sizeOf(wide)[0] > sizeOf(wide)[1], 'a wide view: ' + sizeOf(wide));
    assert(sizeOf(tall)[1] > sizeOf(tall)[0], 'a tall view: ' + sizeOf(tall));
    [wide, tall].forEach(function (r) { assert(r.report.boards.root.end.aspect <= 1.5, 'within half again of the view\'s shape: ' + r.report.boards.root.end.aspect); checkPlan(r.plan); });
    // the same digest, the same view: the same plan
    var again = await planOf(d, { view: { w: 1600, h: 800 } });
    eq(JSON.stringify(again.plan), JSON.stringify(wide.plan), 'the same again');
  });

  await test('the view is the one given, else one assumed, and the summary says which; --view and --ranks are read, and a window\'s room from canvas boards', async function () {
    var d = fixture('tree');
    var b = await planOf(d, { view: { w: 500, h: 900 } }), c = await planOf(d);
    eq([b.report.view.from, b.report.view.w, b.report.view.h], ['given', 500, 900], 'given');
    eq([c.report.view.from, c.report.view.w, c.report.view.h], ['assumed', elkm.DEFAULT_VIEW.w, elkm.DEFAULT_VIEW.h], 'assumed');
    assert(/laid out for a view of 500 x 900$/.test(clim.summarize(b).split('\n')[0]), clim.summarize(b).split('\n')[0]);
    assert(/laid out for a view of 1440 x 960 \(assumed: no view was given\)$/.test(clim.summarize(c).split('\n')[0]), clim.summarize(c).split('\n')[0]);
    var refusal = async function (flag, value) { try { await clim.run(['plan', '/d.json', '/m.json', '/o', flag, value], { readText: function () { return JSON.stringify(d); }, print: function () {} }); } catch (e) { return e.message; } return ''; };
    assert(/--view takes a width and a height/.test(await refusal('--view', 'wide')), '--view wide is refused');
    assert(/--ranks is auto, rows or columns/.test(await refusal('--ranks', 'diagonal')), '--ranks diagonal is refused');
    // a window's room, from `canvas boards`: the board in front, or one by its id; nothing when there is none, or its window has no size
    var redrawm = await import('../lib/redraw.mjs');
    var boards = [{ id: 1, frontmost: false, view: [1312.5, 771.4] }, { id: 2, frontmost: true }];
    eq(redrawm.boardView(boards, '1'), '1313x771', 'by id, in whole points');
    eq(redrawm.boardView(boards, 'front'), '', 'the board in front has no size');
    eq(redrawm.boardView(boards, '7'), '', 'no such board');
    eq(redrawm.boardView([], 'front'), '', 'no board at all');
    var out = []; await clim.run(['view', '/b.json', '1'], { readText: function () { return JSON.stringify(boards); }, print: function (x) { out.push(x); } });
    eq(out, ['1313x771'], 'the command prints it as --view takes it');
  });

  await test('policy.ranks says which way ranked children run, and --ranks says it over the digest', async function () {
    var d = Object.assign(rankedDigest(), { policy: { ranks: 'rows' } }), wide = { w: 2400, h: 800 };
    assert(isRows(shapesOf(await planOf(d, { promote: false, view: wide }))), 'the digest says rows, in a view that would have columns');
    assert(isColumns(shapesOf(await planOf(d, { promote: false, view: wide, ranks: 'columns' }))), 'the option says columns over it');
    assert(isColumns(shapesOf(await planOf(d, { promote: false, view: wide, ranks: 'auto' }))), 'and auto leaves it to the view');
    var threw = ''; try { model.buildModel(Object.assign(rankedDigest(), { policy: { ranks: 'sideways' } })); } catch (e) { threw = e.message; }
    assert(/policy\.ranks is "rows" or "columns"/.test(threw), 'another word is refused: ' + threw);
    eq(checkm.checkDigest(Object.assign(rankedDigest(), { policy: { ranks: 'sideways' } })).errors.length, 1, 'and check says so');
  });

  await test('how far off its shape a container is: the ratio of the two shapes; nothing for a board the view shows whole', async function () {
    eq(elkm.offShape(300, 100, 1.5), 2, 'twice too wide');
    eq(elkm.offShape(100, 300, 1.5), 4.5, 'four and a half times too tall');
    eq(elkm.offShape(150, 100, 1.5), 1, 'the shape itself');
    eq(elkm.offShapeOf(300, 100, { aspect: 1.5 }), 2, 'a shape with no view: the ratio');
    var view = { aspect: 1.5, viewW: 1500, viewH: 1000 };
    eq(elkm.offShapeOf(900, 950, view), 1, 'a board the view shows whole, at its own size: any shape');
    assert(Math.abs(elkm.offShapeOf(6000, 2000, view) - 2) < 1e-9, 'a board that outgrows the view: the ratio');
    var part = elkm.offShapeOf(900, 1200, view);   // shown at 5/6 of its size, where the same room in the view's shape would be shown whole
    assert(Math.abs(part - 1.44) < 1e-9 && part < elkm.offShape(900, 1200, 1.5), 'less than the ratio for a board a little too tall for the view: ' + part);
  });

  await test('a stress layout stretched to a shape keeps its order and comes out the shape; boxes pushed apart move only where they overlap', async function () {
    var items = [], pos = [];
    for (var i = 0; i < 9; i++) { items.push({ w: 200, h: 100 }); pos.push({ x: (i % 3) * 260, y: Math.floor(i / 3) * 200 }); }
    var plain = elkm.stretched(items, pos, { aspect: 780 / 500 });
    eq(plain.k, 1, 'already the shape: left alone');
    var wide = elkm.stretched(items, pos, { aspect: 6 });
    var box = elkm.normalize(items, wide.pos);
    assert(wide.k > 1 && box.w / box.h > 3, 'stretched wide: ' + box.w + ' x ' + box.h + ', k ' + wide.k);
    for (var a = 0; a < 9; a++) for (var b = 0; b < 9; b++) if (pos[a].x < pos[b].x) assert(wide.raw[a].x < wide.raw[b].x, 'left of stays left of');
    for (var p = 0; p < 9; p++) for (var q = p + 1; q < 9; q++) {
      var A = wide.pos[p], B = wide.pos[q];
      assert(!(A.x < B.x + 200 && B.x < A.x + 200 && A.y < B.y + 100 && B.y < A.y + 100), 'nothing overlaps');
    }
    eq(elkm.stretch(items, elkm.stretch(items, pos, 4), 1 / 4).map(function (z) { return [Math.round(z.x), Math.round(z.y)]; }), pos.map(function (z) { return [z.x, z.y]; }), 'a stretch undone is where it was');
    // pushApart: two boxes too near are pushed apart along the way they overlap least; a third, clear of both, stays
    var three = [{ w: 200, h: 100 }, { w: 200, h: 100 }, { w: 200, h: 100 }], at = [{ x: 0, y: 0 }, { x: 150, y: 10 }, { x: 0, y: 600 }];
    var out = elkm.pushApart(three, at, 40, 64);
    eq(out[2], at[2], 'the box clear of the others has not moved');
    assert(out[1].x - (out[0].x + 200) >= 40 - 1e-6, 'the two are 40 apart across: ' + JSON.stringify(out));
    eq(elkm.pushApart(three, [{ x: 0, y: 0 }, { x: 240, y: 0 }, { x: 0, y: 164 }], 40, 64), [{ x: 0, y: 0 }, { x: 240, y: 0 }, { x: 0, y: 164 }], 'boxes already clear stay where they are');
  });

  await test('too long is as the view sees it: an arrow may run further across a wide view than down it', async function () {
    var m = { node: function () { return { never: false }; } };
    var across = { x1: 0, y1: 0, x2: 1200, y2: 0 }, down = { x1: 0, y1: 0, x2: 0, y2: 1200 };
    var layout = function (aspect) { return { plan: { direct: [{ from: 'a', to: 'b' }, { from: 'c', to: 'd' }], members: [] }, shape: { aspect: aspect } }; };
    var names = function (aspect) { return promm.tooLong(m, layout(aspect), { segs: [across, down] }, 1000).map(function (x) { return x.from; }); };
    eq(names(1), ['a', 'c'], 'a square view: both are over 1000');
    eq(names(2), ['c'], 'a view twice as wide as tall: the arrow across fits, the one down does not');
    eq(names(0.5), ['a'], 'a view twice as tall as wide: the other way round');
    eq(promm.tooLong(m, layout(2), { segs: [across, down] }, 1000)[0].length, 1200, 'the length said is the arrow\'s own');
  });

  await test('while too-long arrows are set apart every shape stays where it is: only what a grown box overlaps is pushed off it', async function () {
    var x = await layouterOf(fixture('acme'));
    x.L.setAnchors(x.layout);
    x.L.hold = true; x.L.warm = true;
    var same = await x.L.layout(x.state);
    x.layout.boxes.forEach(function (b, t) { eq(same.boxes.get(t), b, t + ' has not moved'); });
    // one arrow set apart: its start has a pill beside it now, and no shape has moved further than that pill is wide
    var e = x.layout.plan.direct[0];
    var st = Object.assign({}, x.state, { apart: new Set([e.from + '\u0000' + e.to]) });
    var held = await x.L.layout(st);
    var pill = held.pills.find(function (p) { return p.start === e.from && p.target === e.to; });
    assert(pill, 'the arrow is a pill beside its start');
    var reach = pill.w + 80 + 64 + 32;
    held.boxes.forEach(function (b, t) { var was = x.layout.boxes.get(t); assert(Math.abs(b.x - was.x) <= reach && Math.abs(b.y - was.y) <= reach, t + ' moved ' + (b.x - was.x) + ', ' + (b.y - was.y)); });
    x.L.hold = false;
  });


  // ---- types ------------------------------------------------------------------------------------------------------------------------------
  var WF = { type: 'object', properties: { name: { type: 'string' }, retries: { type: 'integer' }, mode: { enum: ['a', 'b'] }, tags: { type: 'array', items: { type: 'string' } }, owner: { type: 'object', properties: { id: { type: 'integer' } }, required: ['id'] } }, required: ['name'] };
  var typed = function (nodes, edges) {
    var base = [
      { title: 'Workflow', schema: WF, text: 'A workflow' }, { title: 'Table', schema: { type: 'object', properties: { name: { type: 'string' } } }, text: 'A table' },
      { title: 'writes', relationship: true, schema: { type: 'object', properties: { mode: { type: 'string', enum: ['insert', 'upsert'] } } }, text: 'writes' },
      { title: 'reads', relationship: true, schema: { type: 'object' }, text: 'reads' }];
    var ends = [{ from: 'Workflow', to: 'writes', text: 'tables', endRule: { needed: true } }, { from: 'writes', to: 'Table', text: 'writers' }, { from: 'Workflow', to: 'reads' }, { from: 'reads', to: 'Table' }];
    return digest(base.concat(nodes || []), ends.concat(edges || []));
  };
  var errorsOf = function (d) { return checkm.checkDigest(d).errors; };
  var said = function (list, re, m) { assert(list.some(function (e) { return re.test(e); }), (m || 'no error says ' + re) + ': ' + JSON.stringify(list)); };

  await test('a typed digest checks: types, relationship types, their ends, notes of a type and arrows of a relationship type are fine', async function () {
    var d = typed([note('w1'), note('t1')], [{ from: 'w1', to: 't1' }]);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1', retries: 3, tags: ['x'], owner: { id: 1 }, extra: 'a member no field names' };
    d.nodes[5].is = ['Table']; d.edges[4].is = 'writes'; d.edges[4].fieldValues = { mode: 'insert' };
    var r = checkm.checkDigest(d);
    eq(r.errors, [], 'no error'); eq(r.warnings, [], 'no warning');
    var m = model.buildModel(d);
    eq(m.edges.filter(function (e) { return e.end; }).map(function (e) { return e.from + '>' + e.to; }), ['Workflow>reads', 'Workflow>writes', 'reads>Table', 'writes>Table'], 'the four ends');
    assert(m.edges.filter(function (e) { return e.end; }).every(function (e) { return e.direct; }), 'an end is never a pill');
    // a type with no words is a warning, never an error; a $ref inside the schema is fine
    var plain = typed([]); delete plain.nodes[1].text; plain.nodes[1].schema = { type: 'object', properties: { a: { $ref: '#/$defs/x' } }, $defs: { x: { type: 'string' } } };
    var rp = checkm.checkDigest(plain); eq(rp.errors, []); said(rp.warnings, /"Table": a type has words and a schema that agree; this one has no text/);
  });

  await test('check refuses, naming the shape: an is with no type, is on a frame or a subboard, relationship without a schema, endRule on an edge that is no end, a $ref to an id', async function () {
    var d = typed([{ title: 'Ghost', is: 'Nobody' }, { title: 'Region', kind: 'frame', is: 'Workflow' }, { title: 'Card', kind: 'subboard', is: 'Workflow' }, { title: 'Orphan', relationship: true },
      { title: 'Rel note', is: 'writes' }, { title: 'Typed type', schema: { type: 'object' }, is: 'Workflow' }, { title: 'Refd', schema: { type: 'object', properties: { x: { $ref: 'urn:uuid:7c1e2a04-4b9e-4e0c-9d8c-5b0e7f3a2c11' } } } },
      { title: 'Frame type', kind: 'frame', schema: { type: 'object' } }, { title: 'No schema object', schema: 'text' }, { title: 'A' }, { title: 'B' }, { title: 'C' }, { title: 'D' }, { title: 'Bad rel', relationship: 'yes', schema: {} }],
    [{ from: 'A', to: 'B', endRule: { needed: true } }, { from: 'C', to: 'D', is: 'Workflow' }, { from: 'C', to: 'D', is: 'Nobody' }, { from: 'Workflow', to: 'writes', is: 'writes' }, { from: 'Workflow', to: 'reads', endRule: { needed: 'yes' } }, { from: 'Workflow', to: 'reads', endRule: { many: true } }]);
    var e = errorsOf(d);
    said(e, /^"Ghost": is "Nobody", which names no type in the digest/, 'is naming no type');
    assert(!e.some(function (x) { return /^"(Region|Card)"/.test(x); }), 'a frame or a subboard may be of a type: ' + JSON.stringify(e));
    said(e, /^"Orphan": relationship: true needs a schema/, 'relationship without schema');
    said(e, /^"Rel note": is "writes", a relationship type: only an arrow is one/, 'a note of a relationship type');
    assert(!e.some(function (x) { return /^"Typed type"/.test(x); }), 'a type that is of a type builds on it: ' + JSON.stringify(e));
    said(e, /^"Refd": the schema has a \$ref to urn:uuid:7c1e2a04-4b9e-4e0c-9d8c-5b0e7f3a2c11/, 'a $ref to an id');
    said(e, /^"Frame type": a frame can't be a type/, 'a schema on a frame');
    said(errorsOf(typed([{ title: 'Card type', kind: 'subboard', schema: { type: 'object' } }])), /^"Card type": a subboard can't be a type/, 'a schema on a subboard');
    said(e, /^"No schema object": schema is a JSON object/, 'a schema that is text');
    said(e, /^"Bad rel": relationship is true or false/, 'relationship that is not boolean');
    said(e, /^edge "A" -> "B": endRule is only for an end of a relationship type/, 'endRule on an edge that is no end');
    said(e, /^edge "C" -> "D": is "Workflow", a type that isn't a relationship type/, 'an arrow of a plain type');
    said(e, /^edge "C" -> "D": is "Nobody", which names no type in the digest/, 'an arrow of no type');
    said(e, /^edge "Workflow" -> "writes": an end of a relationship type joins a type and a relationship type; it is not itself a relationship/, 'an end that is a relationship');
    said(e, /^edge "Workflow" -> "reads": endRule is \{"needed": true\|false, "onlyOne": true\|false\}/, 'an endRule that is not the rule');
    // the digest's ids stay in the schema and nowhere else: a $ref inside it is fine (above), and an ordinary digest is never refused for any of this
    eq(errorsOf(fixture('acme')), []);
  });

  await test('check refuses the ends of a relationship type that sit on another board than it', async function () {
    var d = typed([{ title: 'Far', kind: 'subboard' }, { title: 'Remote', in: 'Far', schema: { type: 'object' }, text: 'Remote type' }], [{ from: 'Remote', to: 'writes' }]);
    var e = errorsOf(d);
    said(e, /^edge "Remote" -> "writes": an end of the relationship type "writes", but "Remote" is on the board of "Far" and "writes" on the first board/, 'an end across boards');
    // types on a board of their own, the relationship type and its ends there too, are fine
    var ok = digest([{ title: 'Model', kind: 'subboard' }, { title: 'T1', in: 'Model', schema: { type: 'object' }, text: 't' }, { title: 'R', in: 'Model', relationship: true, schema: { type: 'object' }, text: 'r' }, note('n1'), note('n2')].map(function (n, i) { if (i === 3) n.is = 'T1'; if (i === 4) n.is = 'T1'; return n; }),
      [{ from: 'T1', to: 'R' }, { from: 'R', to: 'T1' }, { from: 'n1', to: 'n2', is: 'R' }]);
    eq(errorsOf(ok), [], 'types on one board, notes of them on another');
  });

  await test('the validator: type, properties, required, enum and items, nested; a null is no value; what it does not check is not an error', async function () {
    var v = typesm.validateValue;
    eq(v({ name: 'a', retries: 2, mode: 'a', tags: ['x'], owner: { id: 1 } }, WF, 'fieldValues'), [], 'a value that fits');
    eq(v({ name: 'a', retries: 2.5 }, WF, 'v'), ['v.retries is 2.5, and the schema wants integer']);
    eq(v({ name: 7 }, WF, 'v'), ['v.name is 7, and the schema wants string']);
    eq(v({ retries: 1 }, WF, 'v'), ['v.name is required, and has no value'], 'required');
    eq(v({ name: null }, WF, 'v'), ['v.name is required, and has no value'], 'a null is no value');
    eq(v({ name: 'a', retries: null }, WF, 'v'), [], 'an optional null is fine');
    eq(v({ name: 'a', mode: 'c' }, WF, 'v'), ['v.mode is "c", and the schema allows only "a", "b"'], 'enum');
    eq(v({ name: 'a', tags: ['x', 3] }, WF, 'v'), ['v.tags[1] is 3, and the schema wants string'], 'items');
    eq(v({ name: 'a', tags: 'x' }, WF, 'v'), ['v.tags is "x", and the schema wants array']);
    eq(v({ name: 'a', owner: {} }, WF, 'v'), ['v.owner.id is required, and has no value'], 'nested required');
    eq(v({ name: 'a', owner: { id: 'x' } }, WF, 'v'), ['v.owner.id is "x", and the schema wants integer'], 'nested type');
    eq(v({ name: 'a', other: 1 }, WF, 'v'), [], 'a member no field names is the app\'s to warn of');
    eq(v(3, { type: ['string', 'integer'] }, 'v'), [], 'a list of types');
    eq(v(true, { type: ['string', 'integer'] }, 'v'), ['v is true, and the schema wants string or integer']);
    eq(v('abc', { type: 'string', minLength: 5, pattern: '^z', format: 'date', const: 'q', anyOf: [{ type: 'integer' }], $ref: '#/x' }, 'v'), [], 'not checked: bounds, pattern, format, const, anyOf, $ref');
    eq(typesm.idRefs({ a: [{ $ref: 'urn:uuid:AB' }, { $ref: '#/$defs/x' }], b: { $ref: 'urn:UUID:cd' } }), ['urn:uuid:AB', 'urn:UUID:cd'], 'only the refs to ids');
    // fieldValues are held to the types of the note, and the relationship type of an arrow
    var d = typed([note('w1')], [{ from: 'w1', to: 'w1' }]);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1', retries: 'many' };
    var e = errorsOf(d);
    said(e, /^"w1": fieldValues\.retries is "many", and the schema wants integer \(the type "Workflow"\)/, 'a note\'s values against its type');
    var a = typed([note('w2'), note('t2')], [{ from: 'w2', to: 't2', is: 'writes', fieldValues: { mode: 'delete' } }]);
    a.nodes[4].is = 'Workflow'; a.nodes[4].fieldValues = { name: 'w2' }; a.nodes[5].is = 'Table';
    said(errorsOf(a), /^edge "w2" -> "t2": fieldValues\.mode is "delete", and the schema allows only "insert", "upsert" \(the relationship type "writes"\)/, 'an arrow\'s values against its relationship type');
    var n = typed([note('w3')]); n.nodes[4].fieldValues = { name: 'x' };
    said(errorsOf(n), /^"w3": fieldValues needs an is/, 'values with no type');
  });

  await test('the measure script carries the types, the relationship types, the ends and every typed arrow, so canvas measure sizes a typed note as it will be drawn', async function () {
    var d = typed([note('w1'), note('t1'), { title: 'Svc', kind: 'subboard' }], [{ from: 'w1', to: 't1', is: 'writes', fieldValues: { mode: 'insert' } }, { from: 'w1', to: 'Svc', is: 'reads' }]);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1', tags: ['a', 'b'] }; d.nodes[5].is = 'Table';
    var lines = sizes.measureScript(model.buildModel(d)).split('\n').filter(Boolean);
    var by = function (re) { return lines.filter(function (l) { return re.test(l); }); };
    var wf = by(/^sticky-note "Workflow"/)[0];
    assert(wf.indexOf('schema: "{\\"type\\":\\"object\\",\\"properties\\":{\\"name\\"') > 0 && / text: "A workflow"/.test(wf), 'a type with its schema, as the quoted string draw reads: ' + wf);
    assert(/ schema: ".*" relationship: true$/.test(by(/^sticky-note "writes"/)[0]), 'a relationship type is marked');
    assert(/ is: "Workflow" fieldValues: \{"name":"w1","tags":\["a","b"\]\}$/.test(by(/^sticky-note "w1"/)[0]), 'a note says what it is and holds: ' + by(/^sticky-note "w1"/)[0]);
    eq(by(/^edge "(Workflow|writes|reads)" -> "(writes|reads|Table)"/).map(function (l) { return l.replace(/^edge /, ''); }),
      ['"Workflow" -> "reads"', '"Workflow" -> "writes" text: "tables" endRule: {"needed":true}', '"reads" -> "Table"', '"writes" -> "Table" text: "writers"'], 'the ends, with the row names and the rules');
    eq(by(/ is: "writes"/).filter(function (l) { return /^edge/.test(l); }), ['edge "w1" -> "t1" is: "writes" fieldValues: {"mode":"insert"}'], 'a typed arrow between notes');
    assert(by(/^edge "w1" -> "Svc"/).length === 0, 'a typed arrow to a card is not measured: a note and a card share no channel');
    eq(by(/ via: reference$/).filter(function (l) { return /-> "(writes|reads|Table)" via/.test(l); }), [], 'no pill is measured for an end');
    // the stand-in the tests use grows a type by its ends: a note of the type has the rows too
    var est = helpers.estimateMeasure(model.buildModel(d));
    var h = function (t) { return est.shapes.filter(function (x) { return x.title === t; })[0]; };
    assert(h('Workflow').size[0] === sizes.noteWidth('Workflow') && h('w1').size[0] === sizes.noteWidth('w1'), 'a typed note keeps the width it is drawn at');
    assert(h('Workflow').size[1] > 200, 'a type with fields and ends grows');
    // an untyped digest has the script it always had
    var plain = sizes.measureScript(model.buildModel(fixture('tree')));
    assert(!/schema|relationship|is: |fieldValues|endRule/.test(plain), 'nothing typed in an untyped digest');
  });

  await test('a frame or a subboard of a type is drawn as ever, then restated with its types and values in the script that describes cards, once the types are drawn; a note is not the only instance', async function () {
    var d = typed([{ title: 'Region', kind: 'frame', is: 'Workflow', fieldValues: { name: 'r' } }, { title: 'Card', kind: 'subboard', is: ['Table'] }, { title: 'inner', in: 'Region' }]);
    eq(errorsOf(d), [], 'a typed frame and subboard check');
    var r = await planOf(d, { into: 'Map' });
    var all = r.runs.map(function (x) { return x.text; }).join('\n');
    var withTyping = all.split('\n').filter(function (l) { return /^(frame|subboard) /.test(l) && / is: /.test(l); });
    eq(withTyping.length, 2, 'each is typed once: ' + withTyping.join(' | '));
    assert(withTyping.some(function (l) { return /^frame "Region".* is: "Workflow" fieldValues: \{"name":"r"\}$/.test(l); }), 'the frame: ' + withTyping.join(' | '));
    assert(withTyping.some(function (l) { return /^subboard "Card".* is: "Table"$/.test(l); }), 'the subboard: ' + withTyping.join(' | '));
    var last = r.runs.filter(function (x) { return /-describe\.draw$/.test(x.name); })[0];
    assert(last && /frame "Region"/.test(last.text) && /subboard "Card"/.test(last.text), 'in the script drawn after the types');
    eq(Object.values(r.plan.described)[0].length, 2, 'both are counted as restated');
  });

  await test('the order of runs: a board\'s types, relationship types and ends are one script; the notes of a type come after every such script, in a script of their board; the arrows of relationships last', async function () {
    var d = typed([{ title: 'Svc', kind: 'subboard' }, { title: 'w1', in: 'Svc', is: 'Workflow' }, { title: 't1', in: 'Svc', is: 'Table' }, { title: 'Spare', kind: 'frame' }, { title: 'x', in: 'Spare', is: 'Table' }],
      [{ from: 'w1', to: 't1', is: 'writes' }]);
    var r = await planOf(d, { into: 'Map' });
    var names = r.runs.map(function (x) { return x.name; });
    var text = function (re) { return r.runs.filter(function (x) { return re.test(x.name); })[0].text; };
    var typesRun = text(/-root-top/);
    ['Workflow', 'Table', 'writes', 'reads'].forEach(function (t) { assert(typesRun.indexOf('sticky-note "' + t + '"') >= 0, t + ' is in the types script'); });
    assert(/\nedge "Workflow" -> "writes" text: "tables" endRule: \{"needed":true\}\n/.test(typesRun) && /\nedge "writes" -> "Table" text: "writers"\n/.test(typesRun), 'and its ends');
    assert(typesRun.indexOf(' is: ') < 0, 'no note of a type in it');
    eq(r.runs.filter(function (x) { return /\.draw$/.test(x.name) && /sticky-note "(Workflow|Table|writes|reads)" /.test(x.text); }).length, 1, 'the types are in one script and no other');
    var notes = names.filter(function (n) { return /-notes\.draw$/.test(n); });
    eq(notes.length, 2, 'a script of notes for each board that has notes of a type (the first board and Svc)');
    var typesAt = names.indexOf(r.runs.filter(function (x) { return /sticky-note "Workflow" /.test(x.text); })[0].name);
    notes.forEach(function (n) { assert(names.indexOf(n) > typesAt, n + ' after the types'); });
    assert(names.indexOf(notes[0]) > names.indexOf(names.filter(function (n) { return /-svc-top/.test(n); })[0]), 'and after every board\'s shapes');
    assert(/sticky-note "x" in "Spare"/.test(text(/-root-notes/)) && /is: "Table"/.test(text(/-root-notes/)), 'a note of a type in a frame is drawn in the notes script, the frame already there');
    var edgeRuns = names.filter(function (n) { return /-edges\.draw$/.test(n); });
    edgeRuns.forEach(function (n) { assert(names.indexOf(n) > names.indexOf(notes[notes.length - 1]), n + ' after the notes'); });
    assert(/edge "w1" -> "t1" is: "writes"/.test(text(/-svc-edges/)), 'the relationship is an arrow with its type');
    assert(r.runs.every(function (x) { return !/^edge "(Workflow|writes|reads)"/m.test(x.text) || x.name === r.runs.filter(function (y) { return /sticky-note "Workflow" /.test(y.text); })[0].name; }), 'an end is drawn nowhere else');
    // the types in a frame, deeper than a shape of the same board: the script of the deepest frame, whatever depth each is at
    var f = typed([{ title: 'Models', kind: 'frame' }, { title: 'Nested', kind: 'frame', in: 'Models' }]);
    f.nodes[0].in = 'Models'; f.nodes[1].in = 'Models'; f.nodes[2].in = 'Nested'; f.nodes[3].in = 'Models';
    var rf = await planOf(f);
    var inRuns = rf.runs.filter(function (x) { return /sticky-note "(Workflow|Table|writes|reads)" /.test(x.text); });
    eq(inRuns.length, 1, 'one script for the four, though Models holds three and Nested one'); assert(/-in-2\.draw$/.test(inRuns[0].name), inRuns[0].name);
    assert(/^edge "Workflow" -> "writes"/m.test(inRuns[0].text), 'the ends in it');
    // a board with no type has no notes script, and an untyped digest has the runs it always had
    assert(rf.runs.every(function (x) { return !/-notes\.draw$/.test(x.name); }), 'no notes of a type, no notes script');
    var acme = await planOf(fixture('acme'));
    assert(acme.runs.every(function (x) { return !/-notes\.draw$/.test(x.name); }), 'an untyped digest has none');
    // the plan's sizes are the measure's, so a typed note is drawn at the size it has with its ends
    var sh = function (t) { return r.plan.boards[0].shapes.concat(r.plan.boards[1].shapes).filter(function (x) { return x.title === t; })[0]; };
    assert(sh('Workflow').w === sizes.noteWidth('Workflow') && sh('Workflow').h > 200, 'the type is stated at its measured size');
    assert(new RegExp('sticky-note "Workflow".* size: ' + sh('Workflow').w + 'x' + sh('Workflow').h + ' ').test(typesRun), 'and drawn at it');
  });

  await test('the types of a digest may be on a board of their own: its types script is drawn before the notes of the first board, the card first', async function () {
    var d = digest([{ title: 'Model', kind: 'subboard' }, { title: 'T1', in: 'Model', schema: { type: 'object', properties: { a: { type: 'string' } } }, text: 't' },
      { title: 'R', in: 'Model', relationship: true, schema: { type: 'object' }, text: 'r' }, { title: 'n1', is: 'T1', fieldValues: { a: 'x' } }, { title: 'n2', is: 'T1' }],
      [{ from: 'T1', to: 'R' }, { from: 'R', to: 'T1' }, { from: 'n1', to: 'n2', is: 'R' }]);
    eq(errorsOf(d), []);
    var r = await planOf(d);
    var names = r.runs.map(function (x) { return x.name; });
    var at = function (re) { return names.indexOf(r.runs.filter(function (x) { return re.test(x.name); })[0].name); };
    assert(at(/-root-top/) < at(/-model-top/), 'the card is drawn first');
    assert(at(/-model-top/) < at(/-root-notes/), 'then the types, then the notes');
    assert(at(/-root-notes/) < at(/-root-edges/), 'then the arrows');
    assert(/edge "T1" -> "R"/.test(r.runs[at(/-model-top/)].text) && /edge "R" -> "T1"/.test(r.runs[at(/-model-top/)].text), 'the ends are in the types\' script');
    assert(!/edge "T1" -> "R"/.test(r.runs[at(/-root-edges/)].text), 'and not in the arrows\'');
  });

  await test('the order a chain of types is read in is the app\'s (TypeOrder): a type before what it builds on, C3 where it has an order, and the walk where it has none', async function () {
    // as the app's OrderTests: each list as `heads` reads it, latest first
    var graph = function (lists) { return function (t) { return lists[t] || []; }; };
    var lin = typesm.linearized;
    eq(lin([], graph({ 1: ['2'] })), []);
    eq(lin(['2'], graph({ 1: ['2'] })), ['2']);
    eq(lin(['1', '1'], graph({ 1: ['2'] })), ['1', '2'], 'repeats are once');
    eq(lin(['9'], graph({ 1: ['2'] })), ['9'], 'nothing knows 9');
    eq(lin(['1'], graph({ 1: ['9', '2'] })), ['1', '9', '2']);
    eq(lin(['2', '1'], graph({})), ['2', '1'], 'unrelated types in the order the heads name them');
    eq(lin(['2', '1'], graph({ 1: ['3'], 2: ['4'] })), ['2', '4', '1', '3'], 'a type\'s own types before the next head\'s');
    eq(lin(['3', '2'], graph({ 2: ['1'], 3: ['1'] })), ['3', '2', '1'], 'a diamond is read once');
    eq(lin(['2', '1'], graph({ 2: ['1'] })), ['2', '1'], 'added Person, then Employee');
    eq(lin(['1', '2'], graph({ 2: ['1'] })), ['2', '1'], 'added Employee, then Person: C3 has no order, and Employee is still first');
    eq(lin(['4', '3'], graph({ 3: ['2', '1'], 4: ['1', '2'] })), ['4', '3', '1', '2'], 'two lists that disagree: the walk breaks the tie');
    eq(lin(['2'], graph({ 1: ['2'], 2: ['3'], 3: ['1'] }), '1'), ['2', '3'], 'a ring ends where it comes back');
    eq(lin(['1'], graph({ 1: ['2'], 2: ['3'], 3: ['1'] })), ['1', '2', '3']);
    eq(lin(['2', '1'], graph({ 1: ['1', '2'] }), '1'), ['2'], 'the shape asked about is never listed');
    // a digest's chain: the types of the list, later first, and what they build on
    var m = model.buildModel(fixture('inherit'));
    eq(typesm.chainOf(m, ['Hybrid']), ['Hybrid', 'Electric', 'Rechargeable', 'Vehicle'], 'Electric is a Vehicle, then a Rechargeable: the later first');
    eq(typesm.chainOf(m, ['Truck']), ['Truck', 'Vehicle']);
    eq(typesm.chainOf(m, ['Person', 'Truck']), ['Truck', 'Vehicle', 'Person'], 'a list is read latest first');
  });

  await test('a type may build on types: is on a type names them, of its own sort; check refuses a ring, a type of the other sort and values on a type, and warns of an arrow between two types', async function () {
    var r = checkm.checkDigest(fixture('inherit'));
    eq(r.errors, [], 'types on three boards built on each other, relationship types built on one, notes of them with values their types build on');
    eq(r.warnings, []);
    var obj = { type: 'object' };
    var d = digest([{ title: 'A', schema: obj, text: 'a', is: 'B' }, { title: 'B', schema: obj, text: 'b', is: ['C', 'A'] }, { title: 'C', schema: obj, text: 'c' },
      { title: 'Self', schema: obj, text: 's', is: 'Self' }, { title: 'R', relationship: true, schema: obj, text: 'r' },
      { title: 'On a relationship', schema: obj, text: 'x', is: 'R' }, { title: 'On a type', relationship: true, schema: obj, text: 'y', is: 'C' },
      { title: 'Valued', schema: obj, text: 'v', is: 'C', fieldValues: { a: 1 } }, { title: 'D', schema: obj, text: 'd' }],
    [{ from: 'C', to: 'D' }, { from: 'R', to: 'On a type' }]);
    var e = errorsOf(d);
    said(e, /^"A": builds on "B", which builds on "A": a type can't build on itself, however far$/, 'a ring');
    eq(e.filter(function (x) { return /^"B": builds on "A"/.test(x); }), [], 'said once, by its first title');
    said(e, /^"Self": is "Self", itself: a type can't build on itself$/, 'a type that is itself');
    said(e, /^"On a relationship": builds on "R", a relationship type: a type builds only on types that aren't$/, 'a type on a relationship type');
    said(e, /^"On a type": builds on "C", which isn't a relationship type: a relationship type builds only on relationship types$/, 'a relationship type on a type');
    said(e, /^"Valued": fieldValues on a type: a type's note shows its fields and never values, which are for its notes$/, 'values on a type');
    eq(e.filter(function (x) { return /^"(C|D)"|^edge "C"/.test(x); }), [], 'the rest are fine');
    said(checkm.checkDigest(d).warnings, /^edge "C" -> "D": both ends are types, so the arrow says nothing; a type that builds on another says is \("is": "D" on "C"\)$/, 'an arrow between two types');
  });

  await test('the values of a note are held to its types and what they build on: a field by the type that names it first in the chain, alone, and required as that type says', async function () {
    var chained = function (values) {
      return digest([{ title: 'Vehicle', schema: { type: 'object', properties: { wheels: { type: 'integer' }, maker: { type: 'string', pattern: '^[A-Z]' } }, required: ['wheels', 'maker'] }, text: 'v' },
        { title: 'Truck', schema: { type: 'object', properties: { wheels: { type: 'string' }, axles: { type: 'integer' } } }, text: 't', is: 'Vehicle' },
        { title: 'uses', relationship: true, schema: { type: 'object', properties: { how: { type: 'string' } } }, text: 'u' },
        { title: 'tows', relationship: true, schema: { type: 'object', properties: { load: { type: 'string' } } }, text: 't', is: 'uses' },
        { title: 'Rig', is: 'Truck', fieldValues: values }, { title: 'Van', is: 'Truck' }],
      [{ from: 'Truck', to: 'tows' }, { from: 'tows', to: 'Truck' }, { from: 'Rig', to: 'Van', is: 'tows', fieldValues: { load: 'timber', how: 7 } }]);
    };
    eq(errorsOf(chained({ wheels: '6x4', maker: 'Volvo', axles: 3 })).filter(function (x) { return /^"Rig"/.test(x); }), [], 'wheels as text: Truck restates it, and its definition is the one');
    eq(errorsOf(chained({ maker: 'Volvo' })).filter(function (x) { return /^"Rig"/.test(x); }), [], 'and Truck doesn\'t require it, though Vehicle did');
    said(errorsOf(chained({ wheels: 6, maker: 'Volvo' })), /^"Rig": fieldValues\.wheels is 6, and the schema wants string \(the type "Truck"\)$/, 'the restated field, by its own definition alone');
    said(errorsOf(chained({ wheels: '6x4' })), /^"Rig": fieldValues\.maker is required, and has no value \(the type "Vehicle", which "Truck" builds on\)$/, 'a field the type builds on is required as its type says');
    said(errorsOf(chained({ wheels: '6x4', maker: 7 })), /^"Rig": fieldValues\.maker is 7, and the schema wants string \(the type "Vehicle", which "Truck" builds on\)$/);
    said(errorsOf(chained({ maker: 'Volvo' })), /^edge "Rig" -> "Van": fieldValues\.how is 7, and the schema wants string \(the relationship type "uses", which "tows" builds on\)$/, 'an arrow\'s, through its relationship type\'s');
    said(checkm.checkDigest(chained({ maker: 'Volvo' })).warnings, /^"Rig": fieldValues\.maker uses "pattern" in the type "Vehicle"/, 'a keyword passed over is said of the type that has it');
    // one type, with nothing to build on, is checked as checkValue checks it, but for a required name no property has, which names no field (the app's
    // rule), in a chain too: Vehicle's stray `vin` refuses no Truck
    var T = { type: 'object', properties: { a: { type: 'integer' }, b: { type: 'string' } }, required: ['b'] };
    eq(typesm.checkChain({ a: 'x' }, [{ title: 'T', schema: T }], 'v'), [{ type: 'T', errors: ['v.b is required, and has no value', 'v.a is "x", and the schema wants integer'], unchecked: [] }]);
    eq(typesm.checkChain({ a: 'x' }, [{ title: 'T', schema: T }], 'v')[0].errors.slice().sort(), typesm.validateValue({ a: 'x' }, T, 'v').slice().sort());
    eq(typesm.checkChain({}, [{ title: 'T', schema: { type: 'object', properties: {}, required: ['vin'] } }], 'v')[0].errors, [], 'a required name no property has');
    var stray = chained({ wheels: '6x4', maker: 'Volvo' });
    stray.nodes[0].schema.required = ['maker', 'vin'];
    eq(errorsOf(stray).filter(function (x) { return /^"Rig"/.test(x); }), [], 'Vehicle requires a vin it has no field for: no Truck is refused for it');
  });

  await test('types built on types are drawn in rounds: a type after the types it builds on, a round later for one of another board, with the ends of its type; a board\'s first round in its shapes\' scripts, as ever, and a later round after every board\'s shapes', async function () {
    var d = fixture('inherit'), m = model.buildModel(d);
    var rounds = typesm.typeRounds(m), got = {};
    [...rounds.keys()].sort().forEach(function (t) { got[t] = rounds.get(t); });
    eq(got, { Cell: 1, Electric: 2, Hybrid: 2, Person: 0, Rechargeable: 1, Truck: 1, Vehicle: 0, owns: 0, powers: 1, tows: 1, uses: 0 },
      'Truck (Fleet) on Vehicle (the first board); Rechargeable and Cell (Parts) ends of powers, which is built on uses (the first board); Electric (the first board) on Rechargeable, and Hybrid on Electric');
    var r = await planOf(d, { into: 'Map' });
    var names = r.runs.map(function (x) { return x.name.replace(/^\d+-/, '').replace(/\.draw$/, ''); });
    eq(names.filter(function (n) { return /types/.test(n); }), ['fleet-types-1', 'parts-types-1', 'root-types-2'], 'a script a board a later round, the boards in their order');
    assert(names.indexOf('root-in-1') < names.indexOf('fleet-types-1') && names.indexOf('parts-types-1') > names.indexOf(names.filter(function (n) { return /-(top|in-\d+)$/.test(n); }).pop()), 'the first round in the first board\'s frame\'s script, the later after every board\'s shapes: ' + names.join(' '));
    var text = function (n) { return r.runs[names.indexOf(n)].text; };
    ['Vehicle', 'Person', 'owns', 'uses'].forEach(function (t) { assert(text('root-in-1').indexOf('sticky-note "' + t + '"') >= 0, t + ' in the first round'); });
    assert(!/^sticky-note "(Electric|Hybrid)"/m.test(text('root-in-1')), 'and not what waits for another board');
    assert(/^edge "Person" -> "owns"/m.test(text('root-in-1')) && /^edge "owns" -> "Vehicle"/m.test(text('root-in-1')), 'with its ends');
    assert(/^sticky-note "Truck" .*is: "Vehicle"$/m.test(text('fleet-types-1')) && /^sticky-note "tows" .*relationship: true is: "uses"$/m.test(text('fleet-types-1')), 'Truck and tows in the second, built on what the first drew');
    assert(/^edge "Truck" -> "tows"/m.test(text('fleet-types-1')) && /^edge "tows" -> "Truck"/m.test(text('fleet-types-1')), 'with their ends');
    ['Rechargeable', 'Cell', 'powers'].forEach(function (t) { assert(text('parts-types-1').indexOf('sticky-note "' + t + '"') >= 0, t + ' in the second round'); });
    assert(/^sticky-note "Electric" .*is: \["Vehicle","Rechargeable"\]$/m.test(text('root-types-2')) && /^sticky-note "Hybrid" .*is: "Electric"$/m.test(text('root-types-2')), 'Electric waits for Rechargeable, Hybrid is with it');
    eq(r.runs.filter(function (x) { return /^sticky-note "(Vehicle|Truck|Electric|Hybrid|Rechargeable)" /m.test(x.text); }).length, 4, 'each type in one script');
    var at = function (n) { return names.indexOf(n); };
    assert(at('root-types-2') < at('root-notes') && at('fleet-types-1') < at('fleet-notes'), 'the notes after every type');
    assert(at('fleet-notes') < at('fleet-edges'), 'the arrows after the notes');
    assert(!/^sticky-note "(Vehicle|Truck|tows)"/m.test(text('root-notes') + text('fleet-notes')), 'a type built on another is no note of one');
    landsAsPlanned(r, simulate(r));
    checkPlan(r.plan);
  });

  await test('typed arrows: two between one pair are one edge to the layout (weights added) and an arrow each when drawn; an untyped one beside them is dropped, warned of', async function () {
    var d = typed([note('w1'), note('t1')], [{ from: 'w1', to: 't1', is: 'writes', fieldValues: { mode: 'insert' }, weight: 2 }, { from: 'w1', to: 't1', is: 'reads', weight: 3 }, { from: 'w1', to: 't1', weight: 10, text: 'plain' }]);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1' }; d.nodes[5].is = 'Table';
    var m = model.buildModel(d);
    var pair = m.edges.filter(function (e) { return e.from === 'w1' && e.to === 't1'; });
    eq(pair.length, 1, 'one edge to the layout'); eq(pair[0].weight, 5, 'the weights of the typed ones, the untyped one dropped');
    eq(pair[0].arrows.map(function (a) { return a.is.join(); }), ['reads', 'writes'], 'an arrow each, in order of their types');
    assert(m.warnings.some(function (w) { return /^edge "w1" -> "t1" without is dropped: the pair has typed arrows, and draw answers ambiguous_edge/.test(w); }), 'warned: ' + JSON.stringify(m.warnings));
    var r = await planOf(d);
    var lines = r.runs.filter(function (x) { return /-edges\.draw$/.test(x.name); })[0].text.split('\n').filter(Boolean);
    eq(lines, ['edge "w1" -> "t1" is: "reads"', 'edge "w1" -> "t1" is: "writes" fieldValues: {"mode":"insert"}'], 'each written with its is, none plain');
    eq(r.plan.boards[0].edges.filter(function (e) { return e.from === 'w1'; }).map(function (e) { return e.is.join(); }), ['reads', 'writes'], 'and each planned with its is');
    eq(r.report.totals.arrows, 5, 'the layout counts one arrow for the pair, and the four ends');
    // the same pair twice with the same type is one arrow, its values joined and its weight added
    var twice = typed([note('a1'), note('b1')], [{ from: 'a1', to: 'b1', is: 'writes', fieldValues: { mode: 'insert' } }, { from: 'a1', to: 'b1', is: ['writes'], fieldValues: { mode: 'upsert' }, weight: 4 }]);
    twice.nodes[4].is = 'Workflow'; twice.nodes[4].fieldValues = { name: 'a1' }; twice.nodes[5].is = 'Table';
    var e2 = model.buildModel(twice).edges.filter(function (e) { return e.from === 'a1'; })[0];
    eq(e2.arrows.length, 1); eq(e2.weight, 5); eq(e2.arrows[0].fieldValues, { mode: 'upsert' }, 'the later in the canonical order, a clash check refuses');
    // two typed arrows between boards share one pill: a line each, the second reusing the pill
    var far = typed([{ title: 'Svc', kind: 'subboard' }, { title: 'Out', kind: 'subboard' }, { title: 'w1', in: 'Svc', is: 'Workflow', fieldValues: { name: 'w1' } }, { title: 't1', in: 'Out', is: 'Table' }],
      [{ from: 'w1', to: 't1', is: 'writes' }, { from: 'w1', to: 't1', is: 'reads' }]);
    eq(errorsOf(far), []);
    var rf = await planOf(far);
    var svc = rf.plan.boards.filter(function (b) { return b.board === 'Svc'; })[0];
    eq(svc.pills.length, 1, 'one pill'); eq(svc.edges.map(function (e) { return e.via + ':' + e.is.join(); }), ['reference:reads', 'reference:writes'], 'two arrows into it');
    eq(rf.runs.filter(function (x) { return /-svc-edges\.draw$/.test(x.name); })[0].text.trim().split('\n'), ['edge "w1" -> "t1" via: reference is: "reads"', 'edge "w1" -> "t1" via: reference is: "writes"']);
    assert(rf.plan.public.indexOf('t1') >= 0, 'the note the pill stands for is public');
  });

  await test('verify and replay tell typed arrows apart by is, and a plan\'s arrows are the relationships it says', async function () {
    var d = typed([note('w1'), note('t1')], [{ from: 'w1', to: 't1', is: 'writes' }, { from: 'w1', to: 't1', is: 'reads' }]);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1' }; d.nodes[5].is = 'Table';
    var r = await planOf(d), b = r.plan.boards[0];
    var rows = function (mutate) {
      var out = [];
      var origin = { x: 500, y: 600 };
      b.shapes.forEach(function (s) { out.push({ board: [], in: [], title: s.title, kind: s.kind, x: origin.x + s.x, y: origin.y + s.y, w: s.w, h: s.h }); });
      b.edges.forEach(function (e) { out.push({ board: [], kind: 'arrow', from: [e.from], to: [e.to], is: e.is }); });
      if (mutate) mutate(out);
      return out;
    };
    var ok = verifym.verify(r.plan, rows());
    eq(ok.summary.edgesMissing, [], 'every arrow found: ' + JSON.stringify(ok.summary.edgesMissing));
    var swapped = verifym.verify(r.plan, rows(function (out) { out.forEach(function (x) { if (x.kind === 'arrow' && x.from[0] === 'w1') x.is = ['writes']; }); }));
    eq(swapped.summary.edgesMissing, ['root: w1 -> t1 is reads'], 'two arrows of one type are not one of each');
    var plainArrow = verifym.verify(r.plan, rows(function (out) { out.forEach(function (x) { if (x.kind === 'arrow' && x.from[0] === 'w1' && x.is[0] === 'reads') delete x.is; }); }));
    eq(plainArrow.summary.edgesMissing, ['root: w1 -> t1 is reads'], 'a plain arrow is not a relationship');
    var replayRun = replaym.replay;
    var res = distribute(r, b.shapes.map(function (s) { return { did: 'created', title: s.title, kind: s.kind, at: [[s.x, s.y], [s.w, s.h]] }; }));
    b.edges.forEach(function (e) { arrowRow(r, res, e, e.is); });
    var last = res[r.plan.runs[r.plan.runs.length - 1]];
    var titles = inFile(r.plan);
    var good = replayRun(r.plan, res, titles, r.statements);
    eq(good.ok, true, good.lines.join('\n'));
    last.changes.forEach(function (c) { if (c.from === 'w1' && c.is && c.is[0] === 'reads') c.is = ['writes']; });
    var bad = replayRun(r.plan, res, titles, r.statements);
    assert(!bad.ok && /not drawn as the relationship the plan says: w1 -> t1 is reads/.test(bad.lines.join('\n')), 'two arrows of the same type, the second type missing: ' + bad.lines.join('\n'));
  });

  await test('compare reports what a typed drawing says by design without failing the run, and still fails on a push, an order warning or a shape off its box', async function () {
    var d = typed([note('w1'), note('t1')], []);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1' }; d.nodes[5].is = 'Table';
    var r = await planOf(d), b = r.plan.boards[0];
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, did: 'created', at: [[s.x, s.y], [s.w, s.h]] }; });
    var warnings = [
      { line: 6, severity: 'incomplete', attribute: 'tables', message: '"w1": tables is needed' },
      { line: 7, severity: 'error', attribute: 'to', message: 'edge "w1" -> "t1": reads runs to a Table. “w1” is a Workflow.' },
      { line: 8, severity: 'error', attribute: 'jobs', message: '"Ann": jobs has 2 notes, and should have at most 1' },
      { line: 9, message: '2 shapes landed outside the view' }];
    var res = cmpRows(r, { changes: rows, warnings: warnings });
    eq(res.ok, true, JSON.stringify(res)); eq(res.warnings.typed, 3, 'the three typed ones are counted'); eq(res.warnings.view, 1);
    eq(res.warningMessages, [], 'and are no failure to name'); assert(res.typedMessages.length === 3 && /tables is needed/.test(res.typedMessages[0]), res.typedMessages.join());
    var withProblems = rows.map(function (x, i) { return i === 2 ? Object.assign({ problems: [{ field: 'tables', class: 'needed', message: 'tables is needed' }] }, x) : x; });
    var viaRows = cmpRows(r, { changes: withProblems, warnings: [] });
    eq(viaRows.ok, true); eq(viaRows.warnings.typed, 1, 'a row\'s problems are counted too'); assert(/^[^:]+: tables is needed$/.test(viaRows.typedMessages[0]), viaRows.typedMessages[0]);
    var pushed = cmpRows(r, { changes: rows, warnings: warnings.concat([{ line: 3, message: 'B was pushed 40 right' }]) });
    eq(pushed.ok, false, 'a push still fails'); eq(pushed.warnings.push, 1);
    var ordered = cmpRows(r, { changes: rows, warnings: warnings.concat([{ line: 3, code: 'unordered', message: 'these two cannot be ordered' }]) });
    eq(ordered.ok, false, 'an order warning still fails');
    var off = rows.map(function (x, i) { return i === 1 ? Object.assign({}, x, { at: [[x.at[0][0] + 9, x.at[0][1]], x.at[1]] }) : x; });
    eq(cmpRows(r, { changes: off, warnings: warnings }).ok, false, 'a shape off its box still fails');
    var text = clim.compareText(res);
    assert(/^ok .*; 3 warning\(s\) a typed drawing gives by design: /.test(text), text);
    // any other warning fails nothing and is said, never only counted: a title near one the board has, in the run's line and in verify's
    var near = { line: 4, code: 'near_title', message: 'created "worker (x)"; the board has "Workers (x)": to change that one, write its title exactly' };
    var withNear = cmpRows(r, { changes: rows, warnings: warnings.concat([near]) });
    eq(withNear.ok, true, 'another warning fails nothing'); eq(withNear.warnings.other, 1); eq(withNear.warningMessages, [], 'and is no failure to name');
    assert(/; 1 other warning\(s\): line 4: created "worker \(x\)"; the board has "Workers \(x\)"/.test(clim.compareText(withNear)), clim.compareText(withNear));
    var said = (await import('../lib/replay.mjs')).replay(r.plan, { [r.plan.runs[0]]: { changes: rows, warnings: [near] } }, null);
    assert(said.lines.some(function (l) { return /^  warning: .*line 4: created "worker \(x\)"/.test(l); }), said.lines.join('\n'));
  });

  await test('a relationship type the app draws as one arc through its pill is planned between its two types, where Straighten puts it, so the arc never loops', async function () {
    // where the app draws one arc (one end on each side, at two different types), the circle through the two types' middles and the pill's: the pill's
    // middle must lie between theirs (along the line from one to the other, and near it), or the arc is a loop round the board
    var between = function (d, r, what) {
      var m = model.buildModel(d), arcs = layoutm.arcsOf(m, m.edges), seen = 0;
      arcs.forEach(function (pair, rel) {
        var b = r.plan.boards.find(function (x) { return x.shapes.some(function (s) { return (s.key || s.id || s.title) === rel; }); });
        var at = function (k) { var s = b.shapes.find(function (x) { return (x.key || x.id || x.title) === k; }); return { x: s.x + s.w / 2, y: s.y + s.h / 2, s: s }; };
        var A = at(pair[0]), P = at(rel), B = at(pair[1]);
        if (A.s.in !== P.s.in || B.s.in !== P.s.in) return;   // only one whose types are in its container is placed
        var dx = B.x - A.x, dy = B.y - A.y, len = Math.hypot(dx, dy);
        var t = ((P.x - A.x) * dx + (P.y - A.y) * dy) / (len * len), off = Math.abs((P.x - A.x) * dy - (P.y - A.y) * dx) / len;
        assert(t > 0.1 && t < 0.9 && off < 0.25 * len, what + ': ' + rel + ' is not between ' + pair[0] + ' and ' + pair[1] + ' (along ' + t.toFixed(2) + ', off the line ' + Math.round(off) + ' of ' + Math.round(len) + ')');
        seen++;
      });
      return seen;
    };
    // a board's bands, the last its types (the band this repository's lens draws at the bottom of its root): laid out as a band is, wide and short,
    // the pills of fills and holds came out beside one of their types, and each drew a loop through the bands above
    var types = [{ title: 'Plugin', in: 'Types', text: 'A plugin', schema: { type: 'object', properties: { id: { type: 'string' } } } },
      { title: 'Extension point', in: 'Types', text: 'A point', schema: { type: 'object', properties: { keyed: { type: 'boolean' } } } },
      { title: 'Kind', in: 'Types', text: 'A kind', schema: { type: 'object', properties: { props: { type: 'string' } } } },
      { title: 'Property', in: 'Types', text: 'A property', schema: { type: 'object', properties: { type: { type: 'string' } } } },
      { title: 'declares', in: 'Types', text: 'declares', relationship: true, schema: { type: 'object' } },
      { title: 'fills', in: 'Types', text: 'fills', relationship: true, schema: { type: 'object', properties: { adds: { type: 'array', items: { type: 'string' } } } } },
      { title: 'holds', in: 'Types', text: 'holds', relationship: true, schema: { type: 'object', properties: { by: { type: 'string' } } } }];
    var band = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'].map(function (t) { return note(t, 'Band'); });
    var d = digest([{ title: 'Band', kind: 'frame', rank: 0 }, { title: 'Types', kind: 'frame', rank: 1 }].concat(band, types),
      [{ from: 'A', to: 'B' }, { from: 'C', to: 'D' }, { from: 'E', to: 'F' }, { from: 'G', to: 'H' },
        { from: 'Plugin', to: 'declares', text: 'declares' }, { from: 'declares', to: 'Extension point', text: 'declared by' }, { from: 'declares', to: 'Kind', text: 'declared by' },
        { from: 'declares', to: 'Property', text: 'declared by' }, { from: 'Plugin', to: 'fills', text: 'fills' }, { from: 'fills', to: 'Extension point', text: 'filled by' },
        { from: 'Kind', to: 'holds', text: 'holds' }, { from: 'holds', to: 'Property', text: 'held by' }], { policy: { ranks: 'rows' } });
    var m = model.buildModel(d), arcs = layoutm.arcsOf(m, m.edges);
    eq([...arcs.keys()].sort(), ['fills', 'holds'], 'fills and holds are one arc each; declares, with three ends on a side, draws its halves as they are');
    eq(arcs.get('holds'), ['Kind', 'Property'], 'its from type, then its to type');
    var r = await planOf(d, { view: { w: 1322, h: 893 } });
    checkPlan(r.plan);
    eq(between(d, r, 'the bands'), 2, 'both are placed');
    // types given ranks of their own (rows, each in title order) are placed between their types too
    var rankedTypes = JSON.parse(JSON.stringify(d));
    rankedTypes.nodes.forEach(function (n) { if (n.in === 'Types') n.rank = n.relationship ? 1 : 0; });
    var rr = await planOf(rankedTypes, { view: { w: 1322, h: 893 } });
    checkPlan(rr.plan);
    eq(between(rankedTypes, rr, 'ranked types'), 2, 'both are placed in a ranked frame');
    // and a pill alone between two types with room sits on the line between them, at its middle
    var two = digest([{ title: 'Model', kind: 'frame' }].concat([types[0], types[1], types[5]].map(function (n) { return Object.assign({}, n, { in: 'Model' }); })),
      [{ from: 'Plugin', to: 'fills', text: 'fills' }, { from: 'fills', to: 'Extension point', text: 'filled by' }]);
    var r2 = await planOf(two, {});
    var s = {}; r2.plan.boards[0].shapes.forEach(function (x) { s[x.title] = x; });
    var mid = function (x) { return [x.x + x.w / 2, x.y + x.h / 2]; };
    var a = mid(s.Plugin), p = mid(s.fills), b = mid(s['Extension point']);
    assert(Math.abs(p[0] - (a[0] + b[0]) / 2) <= 1 && Math.abs(p[1] - (a[1] + b[1]) / 2) <= 1, 'the pill\'s middle is the middle of the line: ' + JSON.stringify([a, p, b]));
    // two relationship types between one pair (the typed fixture's writes and reads), each its own arc, pushed apart about the middle; and types three boards round
    var typed = fixture('typed'), inherit = fixture('inherit');
    var rt = await planOf(typed, {}), ri = await planOf(inherit, {});
    checkPlan(rt.plan); checkPlan(ri.plan);
    eq(between(typed, rt, 'typed'), 2, 'writes and reads');
    assert(between(inherit, ri, 'inherit') >= 1, 'inherit has one at least');
    // a type related to itself has no arc
    var self = digest([types[0], Object.assign({}, types[5], { title: 'uses' })].map(function (n) { return Object.assign({}, n, { in: undefined }); }),
      [{ from: 'Plugin', to: 'uses', text: 'uses' }, { from: 'uses', to: 'Plugin', text: 'used by' }]);
    var ms = model.buildModel(self);
    eq(layoutm.arcsOf(ms, ms.edges).size, 0, 'a type related to itself is drawn on the bends its halves keep');
  });

  await test('a typed digest\'s output is byte-identical for the same input, and in another order of nodes and edges; the commands refuse a digest whose types are wrong', async function () {
    var d = fixture('typed'), s0 = sizesOf(d);
    var a = await planm.planDigest(d, s0, {}, elk), b = await planm.planDigest(JSON.parse(JSON.stringify(d)), JSON.parse(JSON.stringify(s0)), {}, elk);
    eq(JSON.stringify(a.plan), JSON.stringify(b.plan), 'plan.json');
    eq(a.runs.map(function (r) { return r.name + '\n' + r.text; }).join('\n'), b.runs.map(function (r) { return r.name + '\n' + r.text; }).join('\n'), 'runs');
    var d2 = JSON.parse(JSON.stringify(d)); d2.nodes.reverse(); d2.edges.reverse();
    var c = await planm.planDigest(d2, s0, {}, elk);
    eq(a.runs.map(function (r) { return r.name + '\n' + r.text; }).join('\n'), c.runs.map(function (r) { return r.name + '\n' + r.text; }).join('\n'), 'runs with the input reversed');
    eq(JSON.stringify(a.plan), JSON.stringify(c.plan), 'plan.json with the input reversed');
    eq(sizes.measureScript(model.buildModel(d)), sizes.measureScript(model.buildModel(d2)), 'the measure script');
    // the fixture is clean, and drawn as the app takes it: the `//` in a value stays inside its quotes
    eq(checkm.checkDigest(d), { errors: [], warnings: [] });
    assert(a.runs.some(function (r) { return r.text.indexOf('"url":"https://temporal.example/ns//order"') > 0; }), 'a value with // is written inside the object');
    var files = {}, mio = { readText: function (p) { return files[p] != null ? files[p] : io.readText(p); }, writeText: function (p, t) { files[p] = t; }, mkdirp: function () {}, print: function () {}, now: function () { return 0; }, engine: 'test' };
    var bad = JSON.parse(JSON.stringify(d)); bad.nodes[7].is = 'Nobody';
    files['/bad.json'] = JSON.stringify(bad); files['/m.json'] = JSON.stringify(helpers.estimateMeasure(model.buildModel(d)));
    var threw = ''; try { await clim.run(['plan', '/bad.json', '/m.json', '/out'], mio); } catch (e) { threw = e.message; }
    assert(/"OrderWorkflow": is "Nobody", which names no type in the digest/.test(threw), 'plan refuses: ' + threw);
    threw = ''; try { await clim.run(['measure-script', '/bad.json'], mio); } catch (e) { threw = e.message; }
    assert(/names no type in the digest/.test(threw), 'measure-script refuses: ' + threw);
  });

  // ---- review fixes: records, the validator, merging, a list of types --------------------------------------------------------------------

  await test('two digests drawn into one unsaved board have two records, and the one replaced is this run\'s own: its digest\'s title first, then the newest by the time written in it', async function () {
    var rd = await import('../lib/redraw.mjs');
    var one = await planOf(digest([note('A1')], [], { title: 'Alpha' }), { promote: false });
    var two = await planOf(digest([note('B1')], [], { title: 'Beta' }), { promote: false });
    var older = rd.drawnRecord(one.plan, '', 4, 3, null, null, 1000), newer = rd.drawnRecord(two.plan, '', 4, 6, null, null, 2000);
    eq([older.at, newer.at, rd.drawnRecord(one.plan, '', 4, 3).at], [1000, 2000, null], 'a record says when it was written');
    var titles = [{ title: 'A1', inside: [] }, { title: 'B1', inside: [] }];   // what the file holds, as a query says it
    var recs = [{ name: 'board-4-0001.json', record: older }, { name: 'board-4-0002.json', record: newer }];
    eq(rd.pickRecord(recs, '', 4, titles, 'Beta'), 'board-4-0002.json', 'this run draws Beta: its record, though Alpha\'s is first by name');
    eq(rd.pickRecord(recs, '', 4, titles, 'Alpha'), 'board-4-0001.json', 'this run draws Alpha: its own');
    eq(rd.pickRecord(recs.slice().reverse(), '', 4, titles, 'Alpha'), 'board-4-0001.json', 'whatever order the folder lists them');
    eq(rd.pickRecord(recs, '', 4, titles), 'board-4-0002.json', 'no title known: the newest');
    eq(rd.pickRecord(recs, '', 4, titles, 'Gamma'), 'board-4-0002.json', 'a title of neither: the newest');
    // two digests of one title, each into a subboard of its own: told apart by the subboard, in the record's file name and in the pick
    var mapA = (await planOf(digest([note('A1')], []), { promote: false, into: 'Map A' })).plan, mapB = (await planOf(digest([note('B1')], []), { promote: false, into: 'Map B' })).plan;
    var ra = rd.drawnRecord(mapA, '', 4, 2, null, null, 1000), rb = rd.drawnRecord(mapB, '', 4, 2, null, null, 2000);
    assert(rd.recordName('', 4, ra.name) !== rd.recordName('', 4, rb.name), 'two record files: ' + ra.name + ' ' + rb.name);
    var two = [{ name: 'board-4-a.json', record: ra }, { name: 'board-4-b.json', record: rb }];
    eq([rd.pickRecord(two, '', 4, [{ title: 'Map A', inside: [] }, { title: 'Map B', inside: [] }], 'Map A'), rd.pickRecord(two, '', 4, [{ title: 'Map A', inside: [] }, { title: 'Map B', inside: [] }], 'Map B')], ['board-4-a.json', 'board-4-b.json'], 'each its own, though both are titled T');
    var tie = [{ name: 'b.json', record: Object.assign({}, newer, { at: 5 }) }, { name: 'a.json', record: Object.assign({}, older, { at: 5 }) }];
    eq(rd.pickRecord(tie, '', 4, titles), 'a.json', 'the same time: by name, so the pick is the same every time');
    eq(rd.pickRecord([{ name: 'x.json', record: older }, { name: 'p.json', record: rd.drawnRecord(one.plan, '/f.canvasboard', 4, 3, null, null, 1) }], '/f.canvasboard', 4, titles), 'p.json', 'a record with a path still comes before one told by the id');
  });

  await test('the validator follows local $refs (#/$defs and #/definitions), guards a cycle, and says what it did not check', async function () {
    var v = typesm.validateValue, c = typesm.checkValue;
    var defs = { type: 'object', properties: { n: { $ref: '#/$defs/count' }, m: { $ref: '#/definitions/count' }, deep: { $ref: '#/$defs/box' } }, $defs: { count: { type: 'integer' }, box: { type: 'object', properties: { n: { $ref: '#/$defs/count' } }, required: ['n'] } }, definitions: { count: { type: 'integer' } } };
    eq(v({ n: 'abc' }, defs, 'v'), ['v.n is "abc", and the schema wants integer'], '#/$defs');
    eq(v({ m: 'abc' }, defs, 'v'), ['v.m is "abc", and the schema wants integer'], '#/definitions');
    eq(v({ deep: { n: 1.5 } }, defs, 'v'), ['v.deep.n is 1.5, and the schema wants integer'], 'a ref inside a ref');
    eq(v({ deep: {} }, defs, 'v'), ['v.deep.n is required, and has no value']);
    eq(v({ n: 3, m: 4, deep: { n: 5 } }, defs, 'v'), [], 'values that fit');
    eq(v('x', { $ref: '#' , type: 'integer' }, 'v'), ['v is "x", and the schema wants integer'], 'the root as a ref');
    var loop = { $ref: '#/$defs/a', $defs: { a: { $ref: '#/$defs/b' }, b: { $ref: '#/$defs/a' } } };
    var r = c(5, loop, 'v');
    eq(r.errors, [], 'a cycle ends'); eq(r.unchecked.map(function (u) { return u.keyword; }), ['$ref'], 'and is said to be unchecked');
    eq(c(5, { $ref: '#/$defs/nowhere' }, 'v').unchecked, [{ path: 'v', keyword: '$ref' }], 'a ref to nothing');
    eq(c(5, { $ref: 'http://example.com/x.json' }, 'v').unchecked, [{ path: 'v', keyword: '$ref' }], 'a ref outside the schema');
    var u = c({ a: 'x', b: [1, 2], c: { d: 1 } }, { type: 'object', properties: { a: { type: 'string', pattern: '^z', minLength: 2 }, b: { type: 'array', items: { type: 'integer', maximum: 1 }, uniqueItems: true }, c: { anyOf: [{ type: 'object' }] }, e: { const: 1 } }, additionalProperties: false }, 'v');
    eq(u.unchecked.map(function (x) { return x.path + ' ' + x.keyword; }).sort(), ['v additionalProperties', 'v.a minLength', 'v.a pattern', 'v.b uniqueItems', 'v.b[] maximum', 'v.c anyOf'], 'each keyword it passed over, at the member it is on (a member with no value is not asked)');
    eq(c('x', { type: 'string', minimum: 3, maxItems: 1 }, 'v').unchecked, [], 'a keyword of another kind of value does not apply');
    eq(c([1], { items: [{ type: 'string' }] }, 'v').unchecked, [{ path: 'v', keyword: 'items' }], 'tuple items');
    // check: a value the ref says is wrong is refused, and a keyword that was not checked is a warning naming the member and the keyword
    var d = typed([note('w1')]); d.nodes[1].schema = { type: 'object', properties: { retries: { $ref: '#/$defs/n' } }, $defs: { n: { type: 'integer' } } };
    d.nodes[4].is = 'Table'; d.nodes[4].fieldValues = { retries: 'abc' };
    said(errorsOf(d), /^"w1": fieldValues\.retries is "abc", and the schema wants integer \(the type "Table"\)/, 'a value against a $ref');
    var p = typed([note('p1'), note('p2'), note('p3'), note('p4')]); p.nodes[1].schema = { type: 'object', properties: { code: { type: 'string', pattern: '^[a-z]+$' } } };
    for (var i = 4; i < 8; i++) { p.nodes[i].is = 'Table'; p.nodes[i].fieldValues = { code: 'a' }; }
    var rp = checkm.checkDigest(p);
    eq(rp.errors, []);
    var said1 = rp.warnings.filter(function (w) { return /pattern/.test(w); });
    eq(said1.length, 1, 'once for the type and the member, not for every note: ' + JSON.stringify(rp.warnings));
    assert(/fieldValues\.code/.test(said1[0]) && /"pattern"/.test(said1[0]) && /"p1"/.test(said1[0]) && /3 more/.test(said1[0]) && /"Table"/.test(said1[0]), said1[0]);
    // a type with no unchecked keyword gives none, and the shipped fixtures' types are untouched
    eq(checkm.checkDigest(typed([note('q1')])).warnings, []);
  });

  await test('the validator\'s edge cases: required is an own property, and an enum of objects does not care how its keys are ordered', async function () {
    var v = typesm.validateValue;
    eq(v({}, { required: ['constructor'] }, 'v'), ['v.constructor is required, and has no value'], 'constructor is not a value');
    eq(v({}, { required: ['toString', '__proto__'] }, 'v').length, 2, 'nor are the rest of Object.prototype');
    eq(v({ constructor: 1 }, { required: ['constructor'] }, 'v'), [], 'an own member of that name is');
    var e = { enum: [{ a: 1, b: [1, { x: 1, y: 2 }] }, 'z'] };
    eq(v({ b: [1, { y: 2, x: 1 }], a: 1 }, e, 'v'), [], 'the same object in another order of keys');
    eq(v({ a: 1, b: [1, { x: 1, y: 3 }] }, e, 'v').length, 1, 'another value is still refused');
    eq(v([2, 1], { enum: [[1, 2]] }, 'v').length, 1, 'a list keeps its order');
  });

  await test('compare fails on a row\'s problem that is a value breaking its schema (a class wrong at a path), and still not on what is by design', async function () {
    var d = typed([note('w1'), note('t1')], []);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1' }; d.nodes[5].is = 'Table';
    var r = await planOf(d), b = r.plan.boards[0];
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, did: 'created', at: [[s.x, s.y], [s.w, s.h]] }; });
    var withProblem = function (p) { return rows.map(function (x, i) { return i === 2 ? Object.assign({ problems: [p] }, x) : x; }); };
    var bad = cmpRows(r, { changes: withProblem({ field: 'retries', path: '/retries', class: 'wrong', message: 'retries is "abc", and should be an integer' }), warnings: [] });
    eq(bad.ok, false, 'a value that breaks its schema fails the run'); assert(/retries is "abc"/.test(bad.mismatches.join('\n')), 'and says which: ' + JSON.stringify(bad.mismatches));
    assert(/retries is "abc"/.test(clim.compareText(bad)), clim.compareText(bad));
    [{ field: 'tables', class: 'needed', message: 'tables is needed' }, { field: 'to', class: 'wrong', message: 'writes runs to a Table. "w1" is a Workflow.' }, { field: 'jobs', class: 'wrong', message: 'jobs has 2 notes, and should have at most 1' }, { field: 'to', class: 'warning', message: 'an end that cannot be read' }].forEach(function (p) {
      var ok = cmpRows(r, { changes: withProblem(p), warnings: [] });
      eq(ok.ok, true, p.message + ' is by design'); eq(ok.warnings.typed, 1);
    });
  });

  await test('arrows of one pair and one type are merged in a canonical order: the same however the digest lists them, and a member two of them give differently is refused, naming both', async function () {
    var mk = function (edges) {
      var d = typed([note('a1'), note('b1')], edges);
      d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'a1' }; d.nodes[5].is = 'Table';
      return d;
    };
    var arrowOf = function (d) { return model.buildModel(d).edges.filter(function (e) { return e.from === 'a1'; })[0]; };
    var apart = [{ from: 'a1', to: 'b1', is: 'writes', fieldValues: { mode: 'insert' }, weight: 2, text: 'one' }, { from: 'a1', to: 'b1', is: 'writes', fieldValues: { colour: 'red' }, weight: 3, text: 'two' }];
    var fwd = arrowOf(mk(apart)), rev = arrowOf(mk(apart.slice().reverse()));
    eq(fwd.arrows[0].fieldValues, { colour: 'red', mode: 'insert' }, 'members of both');
    eq(JSON.stringify(fwd), JSON.stringify(rev), 'the same model whichever is listed first');
    eq(fwd.arrows[0].text, rev.arrows[0].text, 'and the same words');
    eq(errorsOf(mk(apart)), [], 'members that agree on nothing in common are fine');
    var clash = [{ from: 'a1', to: 'b1', is: 'writes', fieldValues: { mode: 'insert' } }, { from: 'a1', to: 'b1', is: ['writes'], fieldValues: { mode: 'upsert' }, weight: 4 }];
    var e1 = errorsOf(mk(clash)), e2 = errorsOf(mk(clash.slice().reverse()));
    said(e1, /^edge "a1" -> "b1" \(is writes\): fieldValues\.mode is "insert" in edges\[4\] and "upsert" in edges\[5\]/, 'both edges are named');
    said(e2, /^edge "a1" -> "b1" \(is writes\): fieldValues\.mode is "insert" in edges\[5\] and "upsert" in edges\[4\]/, 'by where they are in this digest');
    eq(e1.filter(function (x) { return /fieldValues\.mode/.test(x); }).length, 1, 'once');
    var strip = function (d) { var a = arrowOf(d).arrows[0]; return JSON.stringify([a.is, a.fieldValues, a.text]); };
    eq(strip(mk(clash)), strip(mk(clash.slice().reverse())), 'and the model is the same either way');
    // the ends: endRule is merged the same way
    var rule = function (rs) { var d = typed([]); d.edges = d.edges.concat(rs); return d; };
    var one = [{ from: 'Workflow', to: 'writes', endRule: { onlyOne: true } }, { from: 'Workflow', to: 'writes', endRule: { needed: true } }];
    var endOf = function (d) { return model.buildModel(d).edges.filter(function (e) { return e.from === 'Workflow' && e.to === 'writes'; })[0]; };
    eq(endOf(rule(one)).arrows[0].endRule, { needed: true, onlyOne: true });
    eq(JSON.stringify(endOf(rule(one))), JSON.stringify(endOf(rule(one.slice().reverse()))), 'the same either way');
    said(errorsOf(rule([{ from: 'Workflow', to: 'writes', endRule: { needed: true } }, { from: 'Workflow', to: 'writes', endRule: { needed: false } }])), /^edge "Workflow" -> "writes": endRule\.needed is (true|false) in edges\[\d+\] and (true|false) in edges\[\d+\]/, 'an end that is both');
  });

  await test('a list of types is a set: two orders of one list are one arrow, and verify and replay do not mind the order they come back in', async function () {
    eq(typesm.isKey(['writes', 'reads']), typesm.isKey(['reads', 'writes']), 'one key');
    var d = typed([note('w1'), note('t1')], [{ from: 'w1', to: 't1', is: ['writes', 'reads'], weight: 2, fieldValues: { mode: 'insert' } }, { from: 'w1', to: 't1', is: ['reads', 'writes'], weight: 3, fieldValues: { mode: 'insert' } }]);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1' }; d.nodes[5].is = 'Table';
    var m = model.buildModel(d), pair = m.edges.filter(function (e) { return e.from === 'w1' && e.to === 't1'; })[0];
    eq(pair.arrows.length, 1, 'one arrow'); eq(pair.weight, 5);
    var rev = model.buildModel(Object.assign({}, d, { edges: d.edges.slice().reverse() })).edges.filter(function (e) { return e.from === 'w1' && e.to === 't1'; })[0];
    eq(JSON.stringify(pair), JSON.stringify(rev), 'whichever is listed first');
    eq(pair.arrows[0].is, ['reads', 'writes'], 'drawn in the order that sorts first of those written, so the same each time');
    said(checkm.checkDigest(d).warnings, /^edge "w1" -> "t1": is is written in two orders \(reads, writes and writes, reads\)/, 'warned: a later type wins where two say the same, so the order means something');
    eq(checkm.checkDigest(typed([note('o1'), note('o2')], [{ from: 'o1', to: 'o2', is: ['writes', 'reads'] }])).warnings.filter(function (w) { return /two orders/.test(w); }), [], 'one order, no warning');
    // the same arrow, listed in another order of types by the app
    var r = await planOf(d), b = r.plan.boards[0];
    var rows = [];
    b.shapes.forEach(function (s) { rows.push({ board: [], in: [], title: s.title, kind: s.kind, x: 500 + s.x, y: 600 + s.y, w: s.w, h: s.h }); });
    b.edges.forEach(function (e) { rows.push({ board: [], kind: 'arrow', from: [e.from], to: [e.to], is: (e.is || []).slice().reverse() }); });
    eq(verifym.verify(r.plan, rows).summary.edgesMissing, [], 'verify: the same set is the same arrow');
    var replayRun = replaym.replay;
    var res = distribute(r, b.shapes.map(function (s) { return { did: 'created', title: s.title, kind: s.kind, at: [[s.x, s.y], [s.w, s.h]] }; }));
    b.edges.forEach(function (e) { arrowRow(r, res, e, e.is ? e.is.slice().reverse() : null); });
    var good = replayRun(r.plan, res, inFile(r.plan), r.statements);
    eq(good.ok, true, 'replay: ' + good.lines.join('\n'));
  });

  await test('a folder of drawing records skips what is not a record, with one warning naming the files, and picks among the rest', async function () {
    var rd = await import('../lib/redraw.mjs');
    var one = await planOf(digest([note('A1')], [], { title: 'Alpha' }), { promote: false });
    var rec = rd.drawnRecord(one.plan, '/f.canvasboard', 4, 3, null, null, 1000);
    var files = { '/r/good.json': JSON.stringify(rec), '/r/corrupt.json': '{"titles": [', '/r/other.json': JSON.stringify({ name: 'something else' }), '/r/list.json': '[1,2]', '/r/null.json': 'null', '/p/f.json': JSON.stringify({ path: '/f.canvasboard' }) };
    var out = [], warned = [], mio = { readText: function (p) { if (files[p] == null) throw new Error('no file ' + p); return files[p]; }, writeText: function () {}, mkdirp: function () {}, print: function (t) { out.push(t); }, warn: function (t) { warned.push(t); }, now: function () { return 7; }, engine: 'test' };
    await clim.run(['record-pick', '/f.canvasboard', '4', '', '/r/corrupt.json', '/r/good.json', '/r/other.json', '/r/list.json', '/r/null.json'], mio);
    eq(out, ['/r/good.json'], 'the record is picked');
    eq(warned.length, 1, 'one warning: ' + JSON.stringify(warned));
    assert(/corrupt\.json/.test(warned[0]) && /other\.json/.test(warned[0]) && /list\.json/.test(warned[0]) && /null\.json/.test(warned[0]) && !/good\.json/.test(warned[0]), warned[0]);
    var split = rd.readRecords(['/r/corrupt.json', '/r/good.json'], function (f) { return JSON.parse(files[f]); });
    eq(split.records.map(function (r) { return r.name; }), ['/r/good.json']); eq(split.skipped.map(function (s) { return s.name; }), ['/r/corrupt.json']);
    out.length = 0; warned.length = 0;
    await clim.run(['record-pick', '/f.canvasboard', '4', '', '/r/good.json'], mio);
    eq([out, warned], [['/r/good.json'], []], 'a folder of records says nothing');
    // the title and the time: drawn writes when, and record-pick takes the title of this run's digest
    out.length = 0;
    files['/plan.json'] = JSON.stringify(one.plan);
    await clim.run(['drawn', '/plan.json', '/f.canvasboard', '4', '3'], mio);
    eq(JSON.parse(out[0]).at, 7, 'drawn writes the time (the engine\'s clock)');
    out.length = 0;
    await clim.run(['name', '/plan.json'], mio);
    eq(out, ['Alpha'], 'a plan drawn as the board: its digest\'s title');
    out.length = 0; files['/d.json'] = JSON.stringify(digest([note('A1')], [], { title: 'Alpha' }));
    await clim.run(['name', '/d.json'], mio);
    eq(out, ['Alpha'], 'and a digest\'s');
    out.length = 0;
    await clim.run(['name', '/d.json', '--into', 'Alpha  map'], mio);
    eq(out, ['Alpha map'], 'a digest drawn into a subboard: the subboard, as a title is folded');
    out.length = 0; files['/into.json'] = JSON.stringify((await planOf(digest([note('A1')], [], { title: 'Alpha' }), { promote: false, into: 'Alpha map' })).plan);
    await clim.run(['name', '/into.json'], mio);
    eq(out, ['Alpha map'], 'and a plan of one');
    // titles are asked for only when the path does not say: a board with no file needs them, a file with a record does not
    files['/r/unsaved.json'] = JSON.stringify(rd.drawnRecord(one.plan, '', 9, 3, null, null, 5));
    out.length = 0;
    await clim.run(['record-needs-titles', '/f.canvasboard', '4', '/r/good.json'], mio);
    eq(out, [], 'a file with a record of its path');
    await clim.run(['record-needs-titles', '/g.canvasboard', '9', '/r/good.json', '/r/unsaved.json'], mio);
    eq(out, ['yes'], 'a board with an unsaved record of its id');
    out.length = 0;
    await clim.run(['record-needs-titles', '/g.canvasboard', '8', '/r/good.json', '/r/unsaved.json'], mio);
    eq(out, [], 'another board\'s id');
  });

  await test('a board with a container past the crowd is laid out once and not searched: its crowd packed as boxes, the plan held, nothing promoted, and the summary says why and to split it', async function () {
    var promote = await import('../lib/promote.mjs');
    // a frame of an index and CROWD pages it points at: a star, which laid out as a tree runs a row (or a column) as long as the pages
    var nodes = [{ title: 'Pages', kind: 'frame' }, note('Index', 'Pages')], edges = [];
    for (var i = 0; i < promote.CROWD; i++) { nodes.push(note('Page ' + i, 'Pages')); edges.push({ from: 'Index', to: 'Page ' + i }); }
    var r = await planOf(digest(nodes, edges));
    var rep = r.report.boards.root;
    eq(rep.stop, 'crowded'); eq(rep.crowded.container, 'Pages'); eq(rep.crowded.children, promote.CROWD + 1);
    eq(r.report.promotions, [], 'nothing promoted'); eq(rep.layout.layouts, 1, 'laid out once');
    eq(rep.algorithms.find(function (a) { return a.container === 'Pages'; }).algorithm, 'rectpacking', 'the crowd packed as boxes');
    var pages = r.plan.boards[0].shapes.find(function (s) { return s.title === 'Pages'; });
    assert(pages.w < 20000 && pages.h < 20000 && Math.max(pages.w / pages.h, pages.h / pages.w) < 4, 'a grid, not a row: ' + pages.w + ' x ' + pages.h);
    eq(r.plan.boards[0].shapes.length, promote.CROWD + 2, 'every shape planned: the pages, the index and the frame');
    checkPlan(r.plan);
    assert(r.report.warnings.some(function (w) { return /board "root" was laid out once and not searched: its frame "Pages" holds 151 shapes side by side, past 150.*split it into subboards/.test(w); }), r.report.warnings.join('\n'));
    assert(/warning: board "root" was laid out once/.test(clim.summarize(r)), clim.summarize(r));
    // one fewer is searched as ever: the index's arrows fanned out as pills
    nodes.pop(); edges.pop();
    var searched = await planOf(digest(nodes, edges));
    assert(searched.report.boards.root.stop !== 'crowded' && !searched.report.warnings.length, searched.report.boards.root.stop);
    assert(searched.report.promotions.some(function (p) { return p.node === 'Index'; }), 'the index is moved: ' + JSON.stringify(searched.report.promotions.map(function (p) { return p.node; })));
  });

  // ---- titles that repeat, and ids ----

  // A digest whose titles are all unique and that has no ids is planned as it always was: these are hashes of the plan (plan.json as the command writes it) and every run script, and of
  // the measure script, made by the tool before titles could repeat. A change that moves one of them changes what every such digest draws.
  // typed's plan moved once since, on purpose: its relationship types, measured as the pills the app draws them as, are placed between their types
  // (Layouter.straighten), where a loop could be drawn through the board before.
  var BEFORE = {
    acme: { measure: 'e4361993fab53091', plain: '4818114a0562a6a0', into: 'eec1be7dd1b726af', off: 'ff326373166a5edd' },
    tree: { measure: '40ed6d82fa465b48', plain: '4e4f9318e37ad87a', into: '8088356cf5f24bfa', off: '59e3b4b617ea5b24' },
    flat60: { measure: '7c4dee7ad79e5484', plain: '3270065918184a6b', into: 'ac1d551cbed31902', off: '9ba4c3a2529d9ed8' },
    spine: { measure: 'd234c5cd4b697c43', plain: '316c603b4d4da869', into: 'e6b19ae418e25626', off: '3a33b1ecac22cf9a' },
    typed: { measure: '4e994c90b737431e', plain: 'a06a8fac65ae69a2', into: 'bd6f0020fde56632', off: '8bd40cab1636e061' },
  };
  var hashOf = function (text) {
    var a = 0x811c9dc5, b = 0x01000193;
    for (var i = 0; i < text.length; i++) { var c = text.charCodeAt(i); a = Math.imul(a ^ c, 0x01000193) >>> 0; b = Math.imul(b ^ c, 0x85ebca6b) >>> 0; }
    return a.toString(16).padStart(8, '0') + b.toString(16).padStart(8, '0');
  };
  // one test for each fixture, so the parts a run is dealt into (below) can run them apart
  var BEFORE_NAMES = Object.keys(BEFORE);
  for (var bi = 0; bi < BEFORE_NAMES.length; bi++) {
    await test('a digest whose titles are all unique and that has no ids is planned as it was: the same plan and the same scripts, byte for byte, on every fixture (' + BEFORE_NAMES[bi] + ')', async function () {
      var name = BEFORE_NAMES[bi], d = fixture(name);
      eq(hashOf(sizes.measureScript(model.buildModel(d))), BEFORE[name].measure, name + ': the measure script');
      var sets = { plain: {}, into: { into: 'Map' }, off: { promote: false } };
      for (var set in sets) {
        var r = await planOf(d, sets[set]), text = JSON.stringify(r.plan, null, 1);
        r.runs.slice().sort(function (x, y) { return x.name < y.name ? -1 : 1; }).forEach(function (run) { text += '\u0000' + run.name + '\u0000' + run.text; });
        eq(hashOf(text), BEFORE[name][set], name + ' (' + set + '): plan.json and the scripts');
      }
    });
  }

  await test('check: a title is unique among the nodes in one container, and may repeat in two; an id is unique; a reference names one node by its id, or by its title when only one has it', async function () {
    var node = function (title, extra) { return Object.assign({ title: title }, extra || {}); };
    var frames = [node('a', { kind: 'frame' }), node('b', { kind: 'frame' })];
    // the same title in two containers is fine, and so is one in a container and one on the first board
    eq(errorsOf(digest(frames.concat([node('index.ts', { in: 'a' }), node('index.ts', { in: 'b' }), node('index.ts')]), [])), [], 'three index.ts, in three places');
    // two in one container: both named, with the container
    var top = errorsOf(digest([node('Note'), node('note')], []));
    eq(top.length, 1, JSON.stringify(top));
    assert(/^duplicate title "note" \(also "Note"\): nodes\[0\] and nodes\[1\] are both in the first board's top level; a title is unique among the nodes in one container/.test(top[0]), top[0]);
    var inFrame = errorsOf(digest(frames.concat([node('index.ts', { in: 'a' }), node('index.ts', { in: 'a' })]), []));
    assert(inFrame.length === 1 && /duplicate title "index\.ts": nodes\[2\] and nodes\[3\] are both in "a"/.test(inFrame[0]), JSON.stringify(inFrame));
    // an id: unique, a non-empty string
    said(errorsOf(digest([node('A', { id: 'x' }), node('B', { id: 'x' })], [])), /^two nodes have the id "x" \(nodes\[0\] "A" and nodes\[1\] "B"\): an id is unique in the digest/, 'two of one id');
    said(errorsOf(digest([node('A', { id: '' })], [])), /nodes\[0\] "A": id is a non-empty string, not ""/, 'a blank id');
    said(errorsOf(digest([node('A', { id: '  ' })], [])), /id is a non-empty string/, 'a blank id of spaces');
    said(errorsOf(digest([node('A', { id: 7 })], [])), /nodes\[0\] "A": id is a non-empty string, not 7/, 'an id that is no string');
    eq(errorsOf(digest([node('A', { id: 'a' }), node('A', { id: 'b', in: 'a' , kind: 'frame' })], [])).length, 1, 'a frame in a note: that is another refusal (below), not the ids');
    // a reference that names no node
    said(errorsOf(digest([node('A', { in: 'Nowhere' })], [])), /^"A" is in "Nowhere", which is not a node/, 'an unknown in');
    said(errorsOf(digest([node('A')], [{ from: 'A', to: 'Nowhere' }])), /^edge A -> Nowhere: unknown title "Nowhere" in edges\[0\] \(no node has that id or title\)/, 'an unknown to');
    said(errorsOf(digest([node('A')], [{ from: 'Nowhere', to: 'A' }])), /unknown title "Nowhere" in edges\[0\]/, 'an unknown from');
    said(errorsOf(digest([node('A')], [{ from: 'A', to: 7 }])), /^edges\[0\]: to is the id or title of a node, not 7/, 'a reference that is no string');
    // a title several nodes have where a reference uses it: say to give the nodes ids
    var rep = frames.concat([node('index.ts', { in: 'a' }), node('index.ts', { in: 'b' }), node('Other')]);
    said(errorsOf(digest(rep, [{ from: 'Other', to: 'index.ts' }])), /^edges\[0\] to "index\.ts" is a title 2 nodes have \(nodes\[2\], nodes\[3\]\): give the nodes ids and name one by its id/, 'an edge to a title two have');
    said(errorsOf(digest(rep.concat([node('Held', { in: 'index.ts', kind: 'frame' })]), [])), /^nodes\[5\] "Held" is in "index\.ts", a title 2 nodes have \(nodes\[2\], nodes\[3\]\): give the nodes ids and name one by its id/, 'an in to a title two have');
    // ... which an id answers, and an id wins where a string is both some node's id and another's title
    var ided = frames.concat([node('index.ts', { in: 'a', id: 'a/index.ts' }), node('index.ts', { in: 'b', id: 'b/index.ts' }), node('Other')]);
    eq(errorsOf(digest(ided, [{ from: 'Other', to: 'a/index.ts' }, { from: 'b/index.ts', to: 'Other' }])), [], 'named by id');
    var both = [node('A', { id: 'B' }), node('B', { id: 'x' })];
    eq(model.buildModel(digest(both, [{ from: 'A', to: 'B' }])).edges.length, 0, 'B is the id of A, so an edge from A to B is from A to A, which is ignored');
    var taken = model.buildModel(digest([node('A', { id: 'T' }), node('T')], []));
    eq([...taken.nodes.keys()].sort(), ['T', 'T  in the first board'], 'a node with no id takes no key that is another\'s id');
    // a type's title is unique across the whole digest
    var type = function (t, extra) { return node(t, Object.assign({ schema: { type: 'object' }, text: 'a type' }, extra || {})); };
    said(errorsOf(digest(frames.concat([type('Table', { in: 'a' }), type('Table', { in: 'b' })]), [])), /^two types are called "Table" \(nodes\[2\] and nodes\[3\]\): a type's title is unique in the whole digest, since is names a type by its title/, 'two types of one title');
    eq(errorsOf(digest(frames.concat([type('Table', { in: 'a' }), node('Table', { in: 'b' })]), [])), [], 'a type and a note may share a title');
    // titles over 80 characters and the other refusals are as they were
    said(errorsOf(digest([node(new Array(82).join('x'))], [])), /over 80 characters/, 'a title over 80');
    // the titles already in the file are refused only where draw could still find a shape outside the drawing by its title: the --into title and a type's
    eq(checkm.checkDigest(digest(rep, []), { existing: ['index.ts', 'Other', 'a'] }).errors, [], 'a node may have a title the file has');
    said(checkm.checkDigest(digest([type('Table')], []), { existing: ['table'] }).errors, /^"Table" is a type, and the file already has a shape of that title/, 'but not a type');
    said(checkm.checkDigest(digest([node('A')], []), { existing: ['map'], into: 'Map' }).errors, /^--into "Map" is already on a board in the file/, 'nor the subboard it goes into');
  });

  await test('a node\'s key is its id, else its title, and a title more than one node has is qualified by the containers (two spaces keep titles in their order); the plan names nodes by it', async function () {
    var d = fixture('repeats'), m = model.buildModel(d);
    var keys = [...m.nodes.keys()];
    eq(keys.length, 15, 'every node'); eq(new Set(keys).size, 15, 'each its own key');
    eq(m.node('Config').title, 'Config'); eq(m.node('Invoice').id, null, 'a node with no id, and a title that is its alone, is its title');
    eq(m.node('admin/components/index.ts').title, 'index.ts', 'a node with an id is its id');
    eq(m.node('admin/components/index.ts').chain, ['admin', 'admin/components'], 'and says the containers it is in, by key');
    // no id, and a title two nodes have: qualified by the containers
    var q2 = model.buildModel(digest([{ title: 'F', kind: 'frame' }, { title: 'G', kind: 'frame', in: 'F' }, { title: 'n', in: 'F' }, { title: 'n', in: 'G' }, { title: 'n' }], []));
    eq([...q2.nodes.keys()].sort(), ['F', 'G', 'n  in F', 'n  in F > G', 'n  in the first board']);
    eq(util.label('n  in F > G'), 'n in F > G', 'said with one space');
    // keys sort as the titles do: a shared title is not moved past a title it was before
    eq([...model.buildModel(digest([note('a'), note('a b'), note('a!'), { title: 'F', kind: 'frame' }, note('a', 'F')], [])).nodes.keys()], ['F', 'a  in F', 'a  in the first board', 'a b', 'a!'], 'the model lists them in that order');
    // the plan: a shape says its title, its id when it has one, and its key when more than one has the title and it has no id
    var r = await planOf(d, {});
    var shapes = r.plan.boards.reduce(function (all, b) { return all.concat(b.shapes); }, []);
    eq(shapes.filter(function (s) { return s.title === 'index.ts'; }).map(function (s) { return s.id; }).sort(), ['admin/components/index.ts', 'app/index.ts', 'billing/index.ts', 'components/index.ts', 'lib/index.ts']);
    assert(!('id' in shapes.find(function (s) { return s.title === 'Config'; })) && !('key' in shapes.find(function (s) { return s.title === 'Config'; })), 'a node with a unique title and no id says only its title');
    var plain = await planOf(digest([{ title: 'F', kind: 'frame' }, { title: 'n', in: 'F' }, { title: 'n' }], []), {});
    eq(plain.plan.boards[0].shapes.map(function (s) { return s.key || s.title; }).sort(), ['F', 'n  in F', 'n  in the first board'], 'a shared title with no id says its key');
    eq(plain.plan.boards[0].shapes.find(function (s) { return s.key === 'n  in F'; }).in, 'F', 'and a shape is in the key of its frame');
    // the same input, the same plan, whichever order the nodes and the edges are listed in
    var rev = Object.assign({}, d, { nodes: d.nodes.slice().reverse(), edges: d.edges.slice().reverse() });
    var r2 = await planOf(rev, {});
    eq(JSON.stringify(r2.plan.boards), JSON.stringify(r.plan.boards), 'the plan');
    eq(r2.runs.map(function (x) { return x.text; }).join('\n'), r.runs.map(function (x) { return x.text; }).join('\n'), 'and the scripts');
  });

  // Each name a script writes means the shape intended and no other: read back from the scripts, as draw reads a name (names.mjs says what it takes a name to mean).
  // A line's names are the quoted titles (and the word `board`) joined by `>` before any attribute with a value of its own; a name that follows the word `in` is a container.
  var namesOf = function (line) {
    var cut = line.search(/ (text|description|schema|is|fieldValues|endRule|public): /), s = cut < 0 ? line : line.slice(0, cut);
    var tokens = [], i = 0;
    while (i < s.length) {
      if (s[i] === ' ') { i++; continue; }
      if (s[i] === '"') { var t = ''; i++; while (s[i] !== '"') { if (s[i] === '\\') { i++; t += s[i] === 'n' ? '\n' : s[i]; } else t += s[i]; i++; } i++; tokens.push({ title: t }); continue; }
      var w = ''; while (i < s.length && s[i] !== ' ') w += s[i++];
      tokens.push({ word: w });
    }
    var groups = [];
    for (var k = 0; k < tokens.length; k++) {
      var g = null, first = k;
      if (tokens[k].title != null) g = { head: null, parts: [tokens[k].title] };
      else if (tokens[k].word === 'board' && tokens[k + 1] && tokens[k + 1].word === '>' && tokens[k + 2] && tokens[k + 2].title != null) { g = { head: 'board', parts: [tokens[k + 2].title] }; k += 2; }
      if (!g) continue;
      while (tokens[k + 1] && tokens[k + 1].word === '>' && tokens[k + 2] && tokens[k + 2].title != null) { g.parts.push(tokens[k + 2].title); k += 2; }
      g.inClause = first > 0 && tokens[first - 1].word === 'in';
      groups.push(g);
    }
    return groups;
  };
  // the nodes a name means to draw in a run on `board`: those of the path (a tail of the containers a node is in, or all of them from the --into card or the top of the board), the board's own first
  var meaningsOf = function (m, g, into, board) {
    var last = g.parts[g.parts.length - 1], containers = g.parts.slice(0, -1);
    var chain = function (n) { return n.chain.map(function (k) { return m.node(k).title; }); };
    var found = [...m.nodes.values()].filter(function (n) {
      if (n.title !== last) return false;
      var c = chain(n);
      if (g.head === 'board') return n.board === 'root' && c.length === containers.length && containers.every(function (p, i) { return c[i] === p; });
      if (into && g.parts.length > 1 && g.parts[0] === into) { var rest = g.parts.slice(1, -1); return c.length === rest.length && rest.every(function (p, i) { return c[i] === p; }); }
      return containers.length <= c.length && containers.every(function (p, i) { return c[c.length - containers.length + i] === p; });
    });
    var here = found.filter(function (n) { return n.board === board; });
    return here.length ? here : found;
  };
  // every script of a plan: each shape's own name, and each edge's ends, mean the node the statement says; the container a shape is `in` and the places it goes against
  // mean the node that holds it (the --into card, which is no node, when none does); a bare title is its node's alone, but for what draw takes from the board of the run
  var namesMean = function (r, d, into, existing) {
    var m = model.buildModel(d), have = new Set(existing || []), seen = { bare: 0, paths: 0 };
    var held = function (title) { return [...m.nodes.values()].filter(function (n) { return n.title === title; }); };
    r.plan.runs.forEach(function (name) {
      var run = r.statements.runs[name], text = r.runs.find(function (x) { return x.name === name; }).text.split('\n').filter(Boolean);
      text.forEach(function (line, i) {
        var says = run.lines[i];
        if (says.into) return;
        var groups = namesOf(line), board = run.board;
        var node = says.shape != null ? m.node(says.shape) : null;
        groups.forEach(function (g, k) {
          var bare = g.parts.length === 1 && !g.head, means = meaningsOf(m, g, into, board);
          seen[bare ? 'bare' : 'paths']++;
          var at = line + ' | name ' + (k + 1);
          var ownWithIn = bare && node && k === 0 && groups.some(function (x) { return x.inClause; });
          // what it means
          if (node && k === 0) eq(means.map(function (n) { return n.key; }), [node.key], at + ' is the shape');
          else if (node && node.parent) eq(means.map(function (n) { return n.key; }), [node.parent], at + ' is the container');
          else if (node && !node.parent && into) assert(g.parts.length === 1 && g.parts[0] === into, at + ' is the --into card');
          else if (says.edge && k < 2) eq(means.map(function (n) { return n.key; }), [k ? says.edge.to : says.edge.from], at + ' is an end');
          else if (says.describe != null) eq(means.map(function (n) { return n.key; }), [says.describe], at + ' is the card');
          else if (!(node && !node.parent && !into)) assert(means.length === 1, at + ' means one node');
          if (!bare) {
            // a path, in a subboard's file, has a part the file has nothing called, or starts at the --into card
            if (into && g.head == null && g.parts[0] !== into) assert(g.parts.slice(0, -1).some(function (p) { return !have.has(p); }), at + ' is a path of titles the file has');
            return;
          }
          if (g.parts[0] === into) return;
          // a bare title: its board's alone (its own name in a statement that says `in`); else no other node's, but the first board's, when it is the board itself
          var title = g.parts[0], same = held(title).filter(function (n) { return n.board === board; });
          if (ownWithIn) { eq(same.length, 1, at + ' is its board\'s alone'); return; }
          assert(held(title).length === 1 || (!into && board === 'root' && same.length === 1), at + ' is no other node\'s: ' + held(title).length);
          if (into) assert(!have.has(title), at + ' is a title the file has');
        });
      });
    });
    return seen;
  };

  await test('every name a script writes means the node intended and no other: bare where its title is its alone (and the file has none), else a path, on the fixtures, with the file holding the same titles, drawn into a subboard and as the board', async function () {
    var d = fixture('repeats'), titles = d.nodes.map(function (n) { return n.title; });
    var nothing = await planOf(d, {}), c1 = namesMean(nothing, d, null, []);
    assert(c1.bare > 0 && c1.paths > 0, 'both forms: ' + JSON.stringify(c1));
    var into = await planOf(d, { into: 'Map' }), c2 = namesMean(into, d, 'Map', []);
    assert(c2.paths > 0, JSON.stringify(c2));
    var held = await planOf(d, { into: 'Map', existing: ['Config', 'index.ts', 'components', 'app', 'Checkout', 'lib'] });
    namesMean(held, d, 'Map', ['Config', 'index.ts', 'components', 'app', 'Checkout', 'lib']);
    var all = await planOf(d, { into: 'Map', existing: titles });
    namesMean(all, d, 'Map', titles);
    // none of the titles bare in an end or a container when the file has them
    var scripts = all.runs.map(function (x) { return x.text; }).join('');
    assert(!/ in "(Config|app|lib|admin|Billing|components)"/.test(scripts) && !/edge "(Config|app|lib|admin|Billing|Invoice|Checkout|components)" /.test(scripts) && !/-> "(Config|Invoice|Checkout)"/.test(scripts), 'the file\'s titles are named by paths: ' + scripts);
    // the fixtures with unique titles: all bare, as they were
    var names = Object.keys(BEFORE);
    for (var i = 0; i < names.length; i++) {
      var fx = fixture(names[i]), r = await planOf(fx, { into: 'Map' }), c = namesMean(r, fx, 'Map', []);
      eq(c.paths, 0, names[i] + ': no path where every title is its own');
    }
  });

  await test('digests that repeat titles at random (frames and subboards of the same names in each other, notes of one title in most of them, ids to tell them apart): every name means its node, or the plan says no name tells it from another', async function () {
    var rand = util.rng(7), pick = function (list) { return list[Math.floor(rand() * list.length)]; };
    var pool = ['a', 'b', 'c', 'd'], planned = 0, refused = 0;
    for (var seed = 0; seed < 14; seed++) {
      var nodes = [], held = { top: new Set() }, count = 0;
      var make = function (container, depth, boardDepth) {
        var key = container == null ? 'top' : container.id, used = held[key] || (held[key] = new Set());
        var n = 2 + Math.floor(rand() * 4);
        for (var i = 0; i < n; i++) {
          var title = pick(pool);
          if (used.has(title)) continue;
          used.add(title);
          var kind = depth < 3 && rand() < 0.35 ? (rand() < 0.4 ? 'subboard' : 'frame') : 'sticky-note';
          var node = { id: 'n' + (++count), title: title, kind: kind };
          if (container) node.in = container.id;
          nodes.push(node);
          if (kind !== 'sticky-note') make(node, depth + 1);
        }
      };
      make(null, 0);
      var leaves = nodes.filter(function (n) { return n.kind === 'sticky-note'; }), edges = [];
      for (var e = 0; e < leaves.length; e++) { var a = pick(leaves), b = pick(leaves); if (a !== b) edges.push({ from: a.id, to: b.id }); }
      // some nodes carry no id, as long as nothing refers to them and their title is not shared
      var shared = {}; nodes.forEach(function (n) { shared[n.title] = (shared[n.title] || 0) + 1; });
      var d = digest(nodes.map(function (n) { var c = Object.assign({}, n); if (shared[n.title] === 1 && !edges.some(function (x) { return x.from === n.id || x.to === n.id; }) && !nodes.some(function (x) { return x.in === n.id; })) delete c.id; return c; }), edges);
      assert(checkm.checkDigest(d).errors.length === 0, 'a digest: ' + JSON.stringify(checkm.checkDigest(d).errors) + ' ' + JSON.stringify(d));
      var modes = [[null, []], ['Map', []], ['Map', pool.slice(0, 2)], ['Map', pool]];
      for (var j = 0; j < modes.length; j++) {
        var r;
        try { r = await planOf(d, { promote: false, into: modes[j][0], existing: modes[j][1] }); } catch (err) {
          assert(/^cannot name "/.test(err.message), 'only a name that cannot be written is refused: ' + err.message);
          assert(modes[j][0] == null, 'drawn into a subboard, every node can be named (the --into card starts a path): ' + err.message);
          refused++; continue;
        }
        namesMean(r, d, modes[j][0], modes[j][1]);
        planned++;
      }
    }
    assert(planned > 30, 'plans made: ' + planned + ', refused: ' + refused);
  });

  await test('the measure script writes two nodes of one title as two statements (paths, as measure takes them), and its rows are read by line: swapped, they are swapped sizes', async function () {
    var d = fixture('repeats'), m = model.buildModel(d), at = sizes.measurePlan(m);
    var lines = at.text.split('\n').filter(Boolean);
    var indexes = lines.filter(function (l) { return /"index\.ts"/.test(l) && /^sticky-note/.test(l); });
    eq(indexes.length, 5, 'five statements for the five index.ts');
    eq(new Set(indexes.map(function (l) { return l.split(' below ')[0]; })).size, 5, 'each its own path: ' + indexes.map(function (l) { return l.split(' size:')[0]; }).join(' | '));
    assert(indexes.some(function (l) { return /^sticky-note "admin" > "components" > "index\.ts" /.test(l); }) && indexes.some(function (l) { return /^sticky-note "Billing" > "index\.ts" /.test(l); }), 'by the containers, outermost first');
    assert(lines.some(function (l) { return /^sticky-note board > "Checkout" /.test(l); }) && lines.some(function (l) { return /^sticky-note "Billing" > "Checkout" /.test(l); }), 'the one in no container is board > "Checkout", the other is in Billing');
    assert(lines.some(function (l) { return /^sticky-note "Config" /.test(l); }) && lines.some(function (l) { return /^subboard "Billing"/.test(l); }), 'a title that is its own is bare');
    assert(lines.filter(function (l) { return /^edge /.test(l); }).every(function (l) { return / via: reference$/.test(l); }), 'the edges are the pills');
    // every statement has a line, and every edge through a reference is for a node, or for a node from where its pill sits
    eq(at.shapeAt.size, 10, 'a line for each note and card');
    var ends = sizes.pillTargets(m), keys = [...at.pillAt.values()];
    eq(keys.filter(function (k) { return ends.indexOf(k) >= 0; }).sort(), ends.slice().sort(), 'a line for each pill');
    // an end whose title another node has is measured again from each place it is pointed at from, both ends by their paths: its pill says where it is
    eq(keys.filter(function (k) { return ends.indexOf(k) < 0; }).sort(), [sizes.pillKey('admin/components/index.ts', 'f:components'), sizes.pillKey('billing/checkout', 'b:Billing'),
      sizes.pillKey('billing/checkout', 'b:root'), sizes.pillKey('billing/checkout', 'f:admin/components'), sizes.pillKey('checkout', 'f:lib'),
      sizes.pillKey('components/index.ts', 'f:app'), sizes.pillKey('lib/index.ts', 'f:app')].sort(), 'and one from each place the five repeated ends are pointed at from');
    at.pillAt.forEach(function (key, line) { if (key === sizes.pillKey('billing/checkout', 'f:admin/components')) eq(lines[line - 1], 'edge "admin" > "components" > "index.ts" -> "Billing" > "Checkout" via: reference'); });
    at.pillAt.forEach(function (key, line) { if (key === sizes.pillKey('billing/checkout', 'b:root')) eq(lines[line - 1], 'edge board > "Checkout" -> "Billing" > "Checkout" via: reference', 'a start on the root, from the top'); });
    assert(!keys.some(function (k) { return k.indexOf('Config') === 0 && k !== 'Config'; }), 'a title that is its own is measured once');
    at.shapeAt.forEach(function (line, key) { assert(lines[line - 1] && lines[line - 1].indexOf(m.node(key).title) > 0, key + ' is on line ' + line); });
    // the sizes come back by line: a measure that answers with rows in any order, titles the same, gives each node its own
    var me = helpers.estimateMeasure(m);
    var big = me.shapes.find(function (s) { return s.line === at.shapeAt.get('app/index.ts'); }), small = me.shapes.find(function (s) { return s.line === at.shapeAt.get('lib/index.ts'); });
    big.size = [300, 555]; small.size = [300, 222];
    var sz = sizes.sizesFrom(m, me), rev = sizes.sizesFrom(m, Object.assign({}, me, { shapes: me.shapes.slice().reverse() }));
    eq([sz.shapes['app/index.ts'].h, sz.shapes['lib/index.ts'].h], [555, 222], 'each its own');
    Object.keys(sz.shapes).forEach(function (k) { eq(rev.shapes[k], sz.shapes[k], 'whatever order the rows come in: ' + k); });
    var lost = JSON.parse(JSON.stringify(me)); lost.shapes = lost.shapes.filter(function (s) { return s.line !== at.shapeAt.get('lib/index.ts'); });
    var threw = ''; try { sizes.sizesFrom(m, lost); } catch (e) { threw = e.message; }
    assert(/no size for: lib\/index\.ts/.test(threw), 'a missing row is said by the node: ' + threw);
    // a pill is for the node its line says, and for one from where it sits, as wide as what it says there
    eq(Object.keys(sz.pillWidth).sort(), keys.slice().sort(), 'a pill width for each end, and each from where it sits');
    eq(sz.pillWidth[sizes.pillKey('billing/checkout', 'f:admin/components')], helpers.pillEstimate('Checkout', 'Billing'));
    eq(sz.pillWidth[sizes.pillKey('billing/checkout', 'b:Billing')], helpers.pillEstimate('Checkout', ''), 'on its own board, it says nothing more');
    eq(sz.pillWidth[sizes.pillKey('admin/components/index.ts', 'f:components')], helpers.pillEstimate('index.ts', 'admin › components'));
    // a measurement of another script (made with other titles beside the drawing, say) is refused, not read by the wrong lines
    var other = helpers.estimateMeasure(m, { existing: ['Config'] });
    threw = ''; try { sizes.sizesFrom(m, other); } catch (e) { threw = e.message; }
    assert(/the measurement is of another script: line \d+ is a pill for "[^"]+", not "[^"]+"; measure again/.test(threw), threw);
    eq(Object.keys(sizes.sizesFrom(m, other, { existing: ['Config'] }).pillWidth).length, keys.length + 1, 'read with the titles it was made with: Config from lib too');
  });

  await test('a pill for an end whose title another shape has is laid out as wide as measure says from where it sits; one whose title is its own, as wide as anywhere', async function () {
    var d = fixture('repeats'), m = model.buildModel(d), me = helpers.estimateMeasure(m), at = sizes.measurePlan(m);
    // make each width from where a pill sits its own, so a pill laid out at another's would show
    var n = 0;
    me.references.forEach(function (r) { if (at.pillAt.get(r.line).indexOf('\u0000') >= 0) r.size = [200 + 10 * (n++), r.size[1]]; });
    var sz = sizes.sizesFrom(m, me), r = await planm.planDigest(d, sz, {}, elk), seen = 0;
    r.plan.boards.forEach(function (b) {
      b.pills.forEach(function (p) {
        var seated = sz.pillWidth[sizes.pillKey(p.for, m.node(p.start).container)];
        if (seated != null) seen++;
        eq(p.w, seated != null ? seated : sz.pillWidth[p.for], 'the pill of ' + p.start + ' for ' + p.for);
      });
    });
    assert(seen > 0, 'some pill is laid out from where it sits');
  });

  await test('a title the file holds beside the drawing, or the subboard the drawing goes in, is another shape: measure-script measures its pills from where they sit, and the plan reads them so', async function () {
    var d = fixture('tree'), m = model.buildModel(d), ends = sizes.pillTargets(m), t = ends[0], title = m.node(t).title;
    var plain = sizes.measurePlan(m);
    eq(plain.pillAt.size, ends.length, 'titles all its own: a line for each pill and no more');
    var beside = sizes.measurePlan(m, { existing: [title] }), into = sizes.measurePlan(m, { into: title });
    var extra = function (at) { return [...at.pillAt.values()].filter(function (k) { return k.indexOf('\u0000') >= 0; }); };
    assert(extra(beside).length > 0 && extra(beside).every(function (k) { return k.split('\u0000')[0] === t; }), 'the file has its title: ' + extra(beside).join(', '));
    eq(extra(into), extra(beside), 'and so does the card it all goes in');
    eq(plain.text, beside.text.split('\n').filter(function (l) { return !/ via: reference$/.test(l) || plain.text.indexOf(l + '\n') >= 0; }).join('\n'), 'the rest is as it was');
    // through the commands: measure-script and plan given the same titles read the same lines
    var files = {}, out = [];
    var mio = { readText: function (p) { if (files[p] != null) return files[p]; return io.readText(p); }, writeText: function (p, x) { files[p] = x; }, mkdirp: function () {}, print: function (x) { out.push(x); }, warn: function () {}, now: function () { return 0; }, engine: 'test' };
    files['/d.json'] = JSON.stringify(d); files['/t.json'] = JSON.stringify([title]);
    await clim.run(['measure-script', '/d.json', '--existing', '/t.json'], mio);
    eq(out[0] + '\n', beside.text, 'measure-script --existing');
    out.length = 0;
    await clim.run(['measure-script', '/d.json', '--into', title], mio);
    eq(out[0] + '\n', into.text, 'measure-script --into');
    files['/m.json'] = JSON.stringify(helpers.estimateMeasure(m, { existing: [title] }));
    await clim.run(['plan', '/d.json', '/m.json', '/out', '--existing', '/t.json'], mio);
    assert(files['/out/plan.json'], 'planned from that measurement');
    var threw = ''; try { await clim.run(['plan', '/d.json', '/m.json', '/out2'], mio); } catch (e) { threw = e.message; }
    assert(/the measurement is of another script/.test(threw), 'and without the titles it was measured with, refused: ' + threw);
    threw = ''; try { await clim.run(['measure-script', '/d.json', '--mess', '1'], mio); } catch (e) { threw = e.message; }
    assert(/unknown option --mess/.test(threw), threw);
  });

  // what the app would answer for every run of a plan, the rows told by the statements of the run (their lines) and by nothing else: a result's `title` is a shape's own
  var drawnAs = function (r) {
    var where = placesm.placesOf(r.plan), boxes = {}, pills = {};
    r.plan.boards.forEach(function (b) { b.shapes.forEach(function (s) { boxes[placesm.shapeKey(s)] = s; }); pills[b.board] = b.pills.slice(); });
    var res = {};
    r.plan.runs.forEach(function (name) {
      var run = r.statements.runs[name], changes = [];
      run.lines.forEach(function (says, i) {
        var line = i + 1;
        if (says.into) changes.push({ line: line, did: 'created', kind: 'subboard', title: r.plan.into, at: [[0, 0], [10, 10]] });
        else if (says.shape != null) { var s = boxes[says.shape]; changes.push({ line: line, did: 'created', kind: s.kind, title: s.title, at: [[s.x, s.y], [s.w, s.h]] }); }
        else if (says.describe != null) changes.push({ line: line, did: 'updated', kind: 'subboard', title: boxes[says.describe].title });
        else if (says.edge) {
          var e = says.edge;
          if (e.via) {
            var list = pills[run.board], at = list.findIndex(function (p) { return p.start === e.from && p.for === e.to; });
            if (at >= 0) { var p = list.splice(at, 1)[0]; changes.push({ line: line, did: 'created', kind: 'reference', at: [[p.x, p.y], [p.w, p.h]] }); }
          }
          changes.push(Object.assign({ line: line, did: 'connected', kind: 'arrow', from: boxes[e.from].title, to: boxes[e.to].title }, e.is ? { is: e.is } : {}));
        }
      });
      res[name] = { changes: changes, warnings: [] };
    });
    return res;
  };

  await test('a result is matched to the plan by the line of each statement: two shapes of one title are told apart, in compare, in replay and in verify', async function () {
    var cmpm = await import('../lib/compare.mjs'), d = fixture('repeats');
    for (var into of [null, 'Map']) {
      var r = await planOf(d, { into: into });
      var results = drawnAs(r), where = placesm.placesOf(r.plan);
      r.plan.runs.forEach(function (name) { var c = cmpm.compareRun(r.plan, results[name], name, r.statements); assert(c.ok, name + ': ' + JSON.stringify(c.mismatches)); });
      var ok = replaym.replay(r.plan, results, inFile(r.plan), r.statements);
      eq(ok.ok, true, (into || 'the board') + ': ' + ok.lines.join('\n'));
      eq([ok.shapesWithin1, ok.shapes, ok.arrows, ok.arrowsPlanned, ok.pillsWithin1, ok.pills, ok.described, ok.restated], [ok.shapes, 15, 9, 9, 2, 2, 1, 0]);
      // two shapes of one title with their boxes swapped are off the plan, and the one named is the one by its key
      var swapped = JSON.parse(JSON.stringify(results)), run = r.plan.runs.find(function (n) { return /-in-1\.draw$/.test(n); });
      var rows = swapped[run].changes.filter(function (c) { return c.title === 'index.ts'; });
      assert(rows.length >= 2, 'two index.ts in one run: ' + rows.length);
      var tmp = rows[0].at; rows[0].at = rows[1].at; rows[1].at = tmp;
      var bad = cmpm.compareRun(r.plan, swapped[run], run, r.statements);
      assert(!bad.ok && bad.mismatches.length === 2 && bad.mismatches.every(function (m) { return /^[a-z/.]*index\.ts: delta/.test(m); }), 'both are named by their keys: ' + JSON.stringify(bad.mismatches));
      // ... and the file lacking one of them (another, by its title, is there) fails: its place is its own
      var wrong = inFile(r.plan).map(function (p) { return p.title === 'index.ts' && p.inside.join() === (into ? 'Map,lib' : 'lib') ? { title: 'index.ts', inside: p.inside.concat(['elsewhere']) } : p; });
      var lacking = replaym.replay(r.plan, results, wrong, r.statements);
      assert(!lacking.ok && /not in the file: lib\/index\.ts/.test(lacking.lines.join('\n')), (into || 'the board') + ': ' + lacking.lines.join('\n'));
      // a shape the plan creates that was found unchanged: named by its key
      var again = JSON.parse(JSON.stringify(results)); again[run].changes.filter(function (c) { return c.title === 'index.ts'; })[1].did = 'unchanged';
      var restated = cmpm.compareRun(r.plan, again[run], run, r.statements);
      assert(!restated.ok && /^"[a-z/.]*index\.ts" was unchanged, not created/.test(restated.mismatches[0]), JSON.stringify(restated.mismatches));
      // verify reads the file back by place: the board and frames of each shape
      var boxOf = {}; r.plan.boards.forEach(function (b) { b.shapes.forEach(function (s) { boxOf[placesm.shapeKey(s)] = s; }); });
      var rowsOf = function () {
        var out = [];
        r.plan.boards.forEach(function (b) {
          var chain = where.boardChain(b.board);
          b.shapes.forEach(function (s) { out.push({ board: chain, in: where.byKey.get(placesm.shapeKey(s)).frames, title: s.title, kind: s.kind, x: s.x, y: s.y, w: s.w, h: s.h }); });
          b.pills.forEach(function (p) { out.push({ board: chain, in: [], kind: 'reference', for: boxOf[p.for].title, x: p.x, y: p.y, w: p.w, h: p.h }); });
          b.edges.forEach(function (e) { out.push({ board: chain, kind: 'arrow', from: where.containers(e.from).concat([boxOf[e.from].title]), to: e.via ? [boxOf[e.to].title] : where.containers(e.to).concat([boxOf[e.to].title]), pill: !!e.via }); });
        });
        return out;
      };
      var v = verifym.verify(r.plan, rowsOf());
      eq([v.summary.missing, v.summary.wrongFrame, v.summary.edgesMissing, v.summary.shapesWithin1, v.summary.pillsWithin1, v.summary.extraPills], [[], [], [], 15, 2, 0], (into || 'the board') + ': verify');
      // the notes called index.ts in the wrong frames: the one in lib, the one in app, swapped
      var mixed = rowsOf().map(function (x) { return x.title === 'index.ts' && x.in.join() === 'lib' ? Object.assign({}, x, { in: ['app'] }) : x.title === 'index.ts' && x.in.join() === 'app' ? Object.assign({}, x, { in: ['lib'] }) : x; });
      var vm = verifym.verify(r.plan, mixed);
      eq([vm.summary.shapesWithin1, vm.summary.missing], [13, []], 'app and lib swap their frames: each is found in its own, at the other\'s box, so those two are off the plan');
      var gone = rowsOf().filter(function (x) { return !(x.title === 'index.ts' && x.in.join() === 'lib'); });
      var vg = verifym.verify(r.plan, gone);
      assert(vg.summary.missing.length >= 1 && /lib\/index\.ts/.test(vg.summary.missing.join()), 'a shape not found is named by its key: ' + JSON.stringify(vg.summary.missing));
      var elsewhere = rowsOf().map(function (x) { return x.title === 'index.ts' && x.in.join() === 'lib' ? Object.assign({}, x, { in: ['components'] }) : x; });
      var ve = verifym.verify(r.plan, elsewhere);
      assert(ve.summary.wrongFrame.length === 1 && /^root: lib\/index\.ts planned in lib, landed in components$/.test(ve.summary.wrongFrame[0]), 'one that landed in another frame is said by its key and the frames: ' + JSON.stringify(ve.summary));
    }
  });

  await test('drawing records go by place: a drawing of repeated titles is taken back by names that mean its own shapes, and is not taken for the file\'s shapes of those titles', async function () {
    var rd = redrawm, d = fixture('repeats');
    var asBoard = await planOf(d, {}), rec = rd.drawnRecord(asBoard.plan, '/f.canvasboard', 7, 12);
    eq(rec.takes.map(function (t) { return t.name; }).sort(), [
      '"Billing"', '"Checkout"', '"Config"', '"admin" > "components"', '"admin" > "components" > "index.ts"', '"admin"', '"app" > "index.ts"', '"app"', '"lib" > "index.ts"', '"lib"',
      'board > "components"', 'board > "components" > "index.ts"'].sort(), 'each shape of the first board by a name that means it alone');
    eq(rec.takes.length, 12, 'every shape of the first board, in a frame or not');
    eq(rec.places.length, 15, 'the place of every shape'); assert(rec.places.some(function (p) { return p.join('>') === 'Billing>Checkout'; }) && rec.places.some(function (p) { return p.join('>') === 'admin>components>index.ts'; }), 'by the containers, then the title');
    // the file as the drawing left it: the take-back deletes each of them, once
    var place = function (p) { return { title: p[p.length - 1], inside: p.slice(0, -1) }; };
    var file = rec.places.map(place), onRoot = file.filter(function (p) { return p.inside[0] !== 'Billing'; });
    var script = rd.replaceScript(rec, file, onRoot).split('\n');
    eq(script.length, 12, script.join(' | ')); assert(script.indexOf('delete board > "components" > "index.ts"') >= 0 && script.indexOf('delete "Billing"') >= 0, script.join(' | '));
    // what a hand added with a title the drawing has is not the drawing's, and is not taken back
    var added = file.concat([{ title: 'index.ts', inside: [] }, { title: 'Checkout', inside: ['Billing', 'Extra'] }]);
    eq(rd.foreign(added, rec), ['index.ts', 'Billing > Extra > Checkout'], 'foreign, by place');
    eq(rd.foreign(file, rec), [], 'and nothing of its own is');
    assert(rd.replaceScript(rec, added, added.filter(function (p) { return p.inside[0] !== 'Billing'; })).split('\n').indexOf('delete "index.ts"') < 0, 'a loose index.ts is not deleted');
    // a drawing that stopped part way is taken back as far as it got
    var part = file.filter(function (p) { return p.inside[0] !== 'admin' && p.title !== 'admin' && p.title !== 'Config'; });
    var partScript = rd.replaceScript(rec, part, part.filter(function (p) { return p.inside[0] !== 'Billing'; })).split('\n');
    eq(partScript.length, 8, 'only what is there: ' + partScript.join(' | ')); assert(!partScript.some(function (l) { return /admin|Config/.test(l); }), 'not what was never drawn');
    // the file's titles for the next plan: less the drawing's own shapes, by place (a shape of the file with a title the drawing has stays)
    eq(rd.minus(file.concat([{ title: 'app', inside: ['Mine'] }, { title: 'index.ts', inside: ['Mine'] }]), rec).sort(), ['app', 'index.ts'], 'the titles the file keeps');
    // into a subboard: one name, the subboard
    var into = await planOf(d, { into: 'Repeats map' }), recInto = rd.drawnRecord(into.plan, '/f.canvasboard', 7, 3);
    eq(recInto.takes, [{ place: ['Repeats map'], name: '"Repeats map"', into: true }]);
    eq(rd.replaceScript(recInto, [{ title: 'Repeats map', inside: [] }, { title: 'Checkout', inside: ['Repeats map'] }], []), 'delete "Repeats map"');
    assert(rd.sameFile(rd.drawnRecord(into.plan, '', 4), '', 4, [{ title: 'Repeats map', inside: [] }]) && !rd.sameFile(rd.drawnRecord(into.plan, '', 4), '', 4, [{ title: 'Checkout', inside: [] }]), 'an unsaved board is told by its subboard, not by a title a shape of its own has');
    assert(rd.sameFile(rd.drawnRecord(asBoard.plan, '', 4), '', 4, [{ title: 'app', inside: [] }]) && !rd.sameFile(rd.drawnRecord(asBoard.plan, '', 4), '', 4, [{ title: 'index.ts', inside: [] }]), 'as the board itself, by the place of a shape it put on the first board');
    // the record of both drawings while one is drawn over the other keeps both ways of taking back
    var both = rd.drawnRecord(into.plan, '/f.canvasboard', 7, 2, rec, 12);
    eq(both.takes.length, 13, 'the subboard, and the shapes of the last');
  });

  if (part) io.print('part ' + part.k + ' of ' + part.n + ': ' + (results.length + failed) + ' of ' + defined + ' tests');
  io.print(results.length + ' passed, ' + failed + ' failed');
  if (failed) throw new Error('tests failed');
}).catch(function (e) { io.print('ERROR ' + (e && e.stack ? e.stack : e)); setTimeout(function () { throw e; }, 0); });
