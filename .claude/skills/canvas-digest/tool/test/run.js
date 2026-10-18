// Unit tests:  jsc test/run.js     or     node test/run.js
// Classic script (import() finds ../lib from here in both engines). No app, no sockets, no pasteboard, no network.
var isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
var fsr = isNode ? require('fs') : null;
var io = {
  readText: function (p) { return isNode ? fsr.readFileSync(p, 'utf8') : readFile(p); },
  print: function (s) { isNode ? console.log(s) : print(s); },
};
Promise.all([import('../lib/dial.mjs'), import('../lib/model.mjs'), import('../lib/sizes.mjs'), import('../lib/elk.mjs'), import('../lib/plan.mjs'), import('../lib/cli.mjs'), import('../lib/util.mjs'), import('../lib/layout.mjs'), import('../lib/promote.mjs'), import('../lib/cost.mjs'), import('../lib/noise.mjs'), import('../lib/check.mjs'), import('./helpers.mjs'), import('../lib/compare.mjs'), import('../lib/types.mjs'), import('../lib/verify.mjs')]).then(async function (mods) {
  var dialm = mods[0], model = mods[1], sizes = mods[2], elkm = mods[3], planm = mods[4], clim = mods[5], util = mods[6], layoutm = mods[7], promm = mods[8], costm = mods[9], noisem = mods[10], checkm = mods[11], helpers = mods[12], compareRun0 = mods[13].compareRun, typesm = mods[14], verifym = mods[15];
  var base = util.TOOL_DIR;
  var elk = await elkm.loadElk(io, base);
  var results = [], failed = 0;
  async function test(name, fn) {
    try { await fn(); io.print('ok   ' + name); results.push(name); }
    catch (e) { failed++; io.print('FAIL ' + name + ': ' + (e && e.message ? e.message : e)); }
  }
  function assert(c, m) { if (!c) throw new Error(m || 'assertion failed'); }
  function eq(a, b, m) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((m || 'not equal') + ': ' + JSON.stringify(a) + ' vs ' + JSON.stringify(b)); }

  function note(t, f, text) { var n = { title: t, kind: 'sticky-note', text: text || '' }; if (f) n.in = f; return n; }
  function digest(nodes, edges, extra) { return Object.assign({ title: 'T', nodes: nodes, edges: edges }, extra || {}); }
  var fixture = function (name) { return JSON.parse(io.readText(base + '/test/fixtures/' + name + '.digest.json')); };
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
  // where the exact placement a line gives (`right of "A" left (gap: x) below "B" top (gap: y)`, or `left of "A" right (gap: x)` and `above "B" bottom (gap: y)`,
  // each axis against its own shape) puts a box of w x h, given the boxes of the shapes it names by title: [x, y], or null when the line says none
  var placedAt = function (l, boxes, w, h) {
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

  await test('a spine that is the board itself places its shared pills against the shapes drawn on the board', async function () {
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
    eq(placedAt(l, libBoxes, x.w, x.h), [x.x, x.y], 'its place against the shapes, as the shapes have theirs');
    assert(lib.origin === undefined && !/About/.test(JSON.stringify(lib.shapes)), 'the board has no header note');
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
    var inFile = checkm.checkDigest(digest([note('A'), note('B')], []), { existing: ['b', 'Other'] });
    assert(inFile.errors.length === 1 && /"B" is already on a board/.test(inFile.errors[0]), JSON.stringify(inFile));
    var hdr = checkm.checkDigest(digest([note('A')], []), { existing: ['About T'] });
    assert(/header "About T"/.test(hdr.errors[0]), 'the header note too: ' + JSON.stringify(hdr));
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

  await test('check: warns past 15 shapes in a frame and 150 on a board, and for an edge into a frame', async function () {
    var nodes = [{ title: 'F', kind: 'frame' }];
    for (var i = 0; i < 16; i++) nodes.push(note('n' + i, 'F'));
    var r = checkm.checkDigest(digest(nodes, []));
    eq(r.errors, [], 'no error'); assert(r.warnings.length === 1 && /frame "F" holds 16/.test(r.warnings[0]), JSON.stringify(r.warnings));
    var big = []; for (var j = 0; j < 151; j++) big.push(note('b' + j));
    var rb = checkm.checkDigest(digest(big, []));
    assert(rb.warnings.length === 1 && /board "root" has 151/.test(rb.warnings[0]), JSON.stringify(rb.warnings));
    var re = checkm.checkDigest(digest([{ title: 'F', kind: 'frame' }, note('A')], [{ from: 'A', to: 'F' }]));
    assert(/frame has no ports/.test(re.warnings.join()), JSON.stringify(re));
  });

  await test('the measure script: every note, card and the first board\'s header once, then one edge through a reference to each end that is pointed at', async function () {
    var d = fixture('tree'), m = model.buildModel(d);
    var lines = sizes.measureScript(m).split('\n').filter(Boolean);
    var shapes = lines.filter(function (l) { return !/^edge /.test(l); }), edges = lines.filter(function (l) { return /^edge /.test(l); });
    var leaves = d.nodes.filter(function (n) { return n.kind !== 'frame'; }).length;
    eq(shapes.length, leaves + 1, 'every note and subboard, and the header of the first board: a subboard\'s board has none');
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
    var ox = 1000, oy = 2000;
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, at: [[ox + s.x, oy + s.y], [s.w, s.h]] }; });
    var good = compareRun0(r.plan, { changes: rows, on: null, warnings: [] }, {});
    eq(good.ok, true, JSON.stringify(good)); eq(good.shapesWithin1, b.shapes.length, 'all within 1');
    rows[1].at[0][0] += 5;
    var bad = compareRun0(r.plan, { changes: rows, warnings: [] }, {});
    eq(bad.ok, false, 'a box 5 off'); assert(bad.mismatches.length === 1, JSON.stringify(bad.mismatches));
    rows[1].at[0][0] -= 5;
    var pushed = compareRun0(r.plan, { changes: rows, warnings: [{ line: 3, message: 'B was pushed 40 right' }] }, {});
    eq(pushed.ok, false, 'a push fails'); eq(pushed.warnings.push, 1, 'and is counted');
    var view = compareRun0(r.plan, { changes: rows, warnings: [{ line: 1, message: '2 shapes landed outside the view — --reveal brings them into view' }] }, {});
    eq(view.ok, true, 'a shape outside the window is not the plan\'s business'); eq(view.warnings.view, 1, 'and is counted apart');
  });

  await test('--into: the whole digest goes in a subboard of that title, made by the first run; compare maps its board back to root', async function () {
    var d = fixture('acme');
    var r = await planOf(d, { into: 'Acme map' });
    eq(r.plan.into, 'Acme map');
    eq(r.plan.runs[0], '00-into.draw'); eq(r.runs[0].text, 'subboard "Acme map"\n');
    var top = r.runs[1].text.split('\n').filter(Boolean);
    assert(/^sticky-note "About /.test(top[0]) && / in "Acme map"/.test(top[0]), 'the header is in the subboard: ' + top[0]);
    r.runs.slice(1).forEach(function (run) { run.text.split('\n').filter(function (l) { return /^(sticky-note|frame|subboard) /.test(l); }).forEach(function (l) { assert(/ in "/.test(l), 'every shape is in something: ' + l); }); });
    assert(top.some(function (l) { return / in "Acme map"/.test(l) && !/^sticky-note "About/.test(l); }), 'shapes on the top board are in the subboard');
    var plain = await planOf(d, {});
    assert(plain.plan.into === null && plain.plan.runs[0] !== '00-into.draw' && !/ in "Acme map"/.test(plain.runs[0].text), 'without --into nothing changes');
    var b = r.plan.boards[0], ox = 100, oy = 200;
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, at: [[ox + s.x, oy + s.y], [s.w, s.h]] }; });
    b.pills.forEach(function (p) { rows.push({ kind: 'reference', at: [[ox + p.x, oy + p.y], [p.w, p.h]] }); });
    var res = compareRun0(r.plan, { changes: rows, on: { board: 'x', title: 'Acme map' }, warnings: [] }, {});
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
    var replayRun = (await import('../lib/replay.mjs')).replay;
    var d = fixture('acme'), r = await planOf(d, {}), b = r.plan.boards[0], ox = 300, oy = 400;
    var names = r.plan.runs.map(function (n) { return n.replace(/\.draw$/, ''); });
    var mk = function () {
      var res = {};
      r.plan.runs.forEach(function (n) { res[n] = { changes: [], warnings: [], on: null }; });
      var first = res[r.plan.runs[0]], last = res[r.plan.runs[r.plan.runs.length - 1]];
      b.shapes.forEach(function (s) { first.changes.push({ did: 'created', title: s.title, kind: s.kind, at: [[ox + s.x, oy + s.y], [s.w, s.h]] }); });
      b.pills.forEach(function (p) { first.changes.push({ did: 'created', kind: 'reference', at: [[ox + p.x, oy + p.y], [p.w, p.h]] }); });
      b.edges.forEach(function (e) { last.changes.push({ did: 'connected', kind: 'arrow', from: e.from, to: e.to }); });
      return res;
    };
    var titles = b.shapes.map(function (s) { return s.title; });
    var ok = replayRun(r.plan, mk(), titles);
    eq(ok.ok, true, ok.lines.join('\n')); eq(ok.lines[0], 'verify ok');
    eq([ok.shapesWithin1, ok.shapes, ok.pillsWithin1, ok.pills, ok.arrows, ok.arrowsPlanned], [b.shapes.length, b.shapes.length, b.pills.length, b.pills.length, b.edges.length, b.edges.length]);
    var gone = mk(); delete gone[r.plan.runs[r.plan.runs.length - 1]];
    assert(!replayRun(r.plan, gone, titles).ok, 'a run that did not happen');
    var off = mk(); off[r.plan.runs[0]].changes[1].at[0][0] += 7;
    assert(/delta/.test(replayRun(r.plan, off, titles).lines.join('\n')), 'a box 7 off names the shape');
    var restated = mk(); restated[r.plan.runs[0]].changes[2].did = 'updated';
    assert(/not created/.test(replayRun(r.plan, restated, titles).lines.join('\n')), 'a restated shape');
    var lacking = replayRun(r.plan, mk(), titles.slice(1));
    assert(!lacking.ok && /not in the file/.test(lacking.lines.join('\n')), 'a title the file lacks');
    var fewer = mk(); fewer[r.plan.runs[r.plan.runs.length - 1]].changes.pop();
    assert(/arrows landed/.test(replayRun(r.plan, fewer, titles).lines.join('\n')), 'an arrow that did not land');
    eq(names.length, r.plan.runs.length);
  });

  await test('extract: what the driver reads out of canvas\'s JSON', async function () {
    var ex = (await import('../lib/replay.mjs')).extract;
    eq(ex('titles', { rows: [{ title: 'A' }, { kind: 'arrow' }, { title: 'B' }] }), ['A', 'B']);
    eq(ex('kinds', [{ kind: 'sticky-note' }, { kind: 'frame' }]), ['sticky-note', 'frame']);
    eq(ex('id', { id: 4, name: 'Plans' }), 4);
    eq(ex('count', { count: 7, rows: [] }), 7);
    var threw = ''; try { ex('nope', {}); } catch (e) { threw = e.message; }
    assert(/not titles, root-titles, kinds, id, count or errors/.test(threw), threw);
  });

  // ---- what reviewing 9716c09f and 4840572f found ----------------------------------------------------------------

  await test('a pill 400 units off the plan fails compare and replay, as a shape does; a pill on the plan passes', async function () {
    var replayRun = (await import('../lib/replay.mjs')).replay;
    var r = await planOf(fixture('acme'), {}), b = r.plan.boards[0], ox = 300, oy = 400;
    assert(b.pills.length >= 2, 'the plan has pills: ' + b.pills.length);
    var mk = function (shift) {
      var changes = [];
      b.shapes.forEach(function (s) { changes.push({ did: 'created', title: s.title, kind: s.kind, at: [[ox + s.x, oy + s.y], [s.w, s.h]] }); });
      b.pills.forEach(function (p, i) { changes.push({ did: 'created', kind: 'reference', at: [[ox + p.x + (i === 0 ? shift : 0), oy + p.y], [p.w, p.h]] }); });
      return changes;
    };
    var good = compareRun0(r.plan, { changes: mk(0), on: null, warnings: [] }, {});
    eq(good.ok, true, JSON.stringify(good.mismatches)); eq(good.pillsWithin1, b.pills.length, 'every pill within 1');
    var bad = compareRun0(r.plan, { changes: mk(400), on: null, warnings: [] }, {});
    eq(bad.ok, false, 'a pill 400 off fails compare'); assert(bad.worstPill > 1 && bad.pillsWithin1 < b.pills.length, 'and is counted: ' + bad.worstPill);
    assert(bad.mismatches.some(function (m) { return /^pill of .* for .*: delta -?\d+,-?\d+$/.test(m); }), 'and names the pill: ' + JSON.stringify(bad.mismatches));
    assert(/MISMATCH[\s\S]*pill of/.test(clim.compareText(bad)), 'the text says so');
    var results = {}; r.plan.runs.forEach(function (n) { results[n] = { changes: [], warnings: [], on: null }; });
    var last = r.plan.runs[r.plan.runs.length - 1];
    b.edges.forEach(function (e) { results[last].changes.push({ did: 'connected', kind: 'arrow', from: e.from, to: e.to }); });
    var titles = b.shapes.map(function (s) { return s.title; });
    results[r.plan.runs[0]].changes = mk(0);
    eq(replayRun(r.plan, results, titles).ok, true, 'on the plan: verify ok');
    results[r.plan.runs[0]].changes = mk(400);
    var failed = replayRun(r.plan, results, titles);
    eq(failed.ok, false, 'replay fails'); eq(failed.lines[0], 'verify FAILED');
    assert(/pill of .* delta /.test(failed.lines.join('\n')), failed.lines.join('\n'));
  });

  await test('a shape the plan creates must be created: found unchanged (or updated) on the board fails compare and replay, naming it', async function () {
    var r = await planOf(digest([note('A'), note('B')], [{ from: 'A', to: 'B' }])), b = r.plan.boards[0];
    var rows = b.shapes.map(function (s) { return { did: 'created', title: s.title, kind: s.kind, at: [[1000 + s.x, 2000 + s.y], [s.w, s.h]] }; });
    eq(compareRun0(r.plan, { changes: rows, warnings: [] }, {}).ok, true, 'created passes');
    rows[1].did = 'unchanged';
    var res = compareRun0(r.plan, { changes: rows, warnings: [] }, {});
    eq(res.ok, false, 'unchanged fails'); assert(res.mismatches.join().indexOf('"' + rows[1].title + '" was unchanged, not created') >= 0, JSON.stringify(res.mismatches));
    assert(/drawn before/.test(res.mismatches.join()), 'and says the plan was drawn before');
    // an arrow row, or a reference row, with a did of its own is not a shape
    rows[1].did = 'created'; rows.push({ did: 'unchanged', kind: 'arrow', title: 'A', from: 'A', to: 'B' });
    eq(compareRun0(r.plan, { changes: rows, warnings: [] }, {}).ok, true, 'an arrow that was already there is not a shape');
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
    // the plan's titles the file holds
    var r = await planOf(fixture('acme'), { into: 'Acme map' });
    files['/plan.json'] = JSON.stringify(r.plan); files['/t.json'] = JSON.stringify(['cto', 'Unrelated']);
    await clim.run(['clashes', '/plan.json', '/t.json'], mio);
    eq(out, ['error: "CTO" is already on a board in the file; titles are file-wide'], 'a clash, folded for case'); out.length = 0;
    files['/t.json'] = JSON.stringify(['acme map']);
    await clim.run(['clashes', '/plan.json', '/t.json'], mio); assert(/"Acme map" is already/.test(out[0]), 'the subboard it goes into is a title too'); out.length = 0;
    files['/t.json'] = JSON.stringify(['Unrelated']);
    await clim.run(['clashes', '/plan.json', '/t.json'], mio); eq(out, [], 'none: nothing printed');
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
    var few = hubFixture(2, 2);   // 4 users, under the 5 of mess 0.1
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
    // on a tie, the first node by title, whichever way its move goes: A (or Z) points at B and four more, and four more point at B
    var ties = [];
    for (var k = 0; k < 2; k++) {
      var src = ['A', 'Z'][k];
      var tie = digest([note(src), note('B')].concat(['t1', 't2', 't3', 't4', 'u1', 'u2', 'u3', 'u4'].map(function (x) { return note(x); })),
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

  await test('only the first board has a header note, and a shape called what it would be makes it give way; a subboard\'s board has none', async function () {
    var d = digest([{ title: 'T', kind: 'subboard' }, note('In T', 'T', 'x'), note('About T', null, 'taken')], []);
    var m = model.buildModel(d);
    eq([m.headers.get('root'), m.headers.has('T'), m.headers.size], ['About T (digest)', false, 1], 'one header, past the note called what it would be; none for the subboard');
    var r = await planOf(d, { promote: false });
    var all = r.plan.boards.reduce(function (a, b) { return a.concat(b.shapes.map(function (x) { return x.title; })); }, []);
    eq(all.length, new Set(all).size, 'no title twice in the plan');
    eq(r.plan.boards.map(function (b) { return b.origin || null; }), ['About T (digest)', null], 'the header is the first board\'s origin, and only it has one');
    eq(r.plan.boards.map(function (b) { return b.anchors && b.anchors.x === b.anchors.y; }), [true, true], 'a board with one shape (or the header) is placed from it');
  });

  // ---- ranks, headers, and drawing again in place ----
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

  await test('the first board\'s header says the digest\'s text; a subboard\'s text is its description, written once what it may mention is drawn', async function () {
    var d = digest([{ title: 'Part', kind: 'subboard', text: 'What the part is, with @[Root note].' }, note('In part', 'Part', 'x'), note('Root note', null, 'y'), { title: 'Bare', kind: 'subboard' }, note('In bare', 'Bare', 'y')], [], { text: 'The whole, said once.' });
    var m = model.buildModel(d);
    eq(sizes.headerText(m), 'The whole, said once.');
    eq(sizes.headerText(model.buildModel(digest([note('A')], []))), 'T. Drawn by canvas-digest.', 'without one it says what it is of');
    var r = await planOf(d, { promote: false });
    var all = r.runs.map(function (x) { return x.text; }).join('\n');
    assert(all.indexOf('sticky-note "About T"') >= 0 && all.indexOf('text: "The whole, said once."') >= 0, 'the root header');
    assert(all.indexOf('About Part') < 0 && all.indexOf('About Bare') < 0, 'no subboard\'s board has a header note');
    assert(!all.split('\n').some(function (l) { return /^subboard /.test(l) && /size:/.test(l) && /description:/.test(l); }), 'a subboard\'s card is drawn with no description: it is written after');
    var names = r.runs.map(function (x) { return x.name; });
    var describe = r.runs.filter(function (x) { return /-describe\.draw$/.test(x.name); });
    eq(describe.map(function (x) { return x.text; }), ['subboard "Part" description: "What the part is, with @[Root note]."\n'], 'one statement a card with a description, restating nothing else; Bare has none');
    eq(r.plan.described, (function () { var o = {}; o[describe[0].name] = ['Part']; return o; })(), 'the plan says which run describes which card');
    var lastShape = Math.max.apply(null, names.map(function (n, i) { return /-(top|in-\d+|notes)\.draw$/.test(n) ? i : -1; }));
    assert(names.indexOf(describe[0].name) > lastShape, 'after every run that draws a shape: ' + names.join(' '));
    var mm = sizes.measureScript(m);
    assert(mm.indexOf('"About Part"') < 0 && mm.indexOf('What the part is') < 0, 'only the first board\'s header is measured, and a description is not');
    assert(mm.indexOf('"About T"') >= 0, 'that one is');
    var none = await planOf(digest([note('A', null, 'x')], []), { promote: false });
    eq(none.plan.described, undefined, 'a digest with no description has none in its plan');
  });

  await test('a shape is placed against the drawn shapes it does not span, with no negative gap: right of and below, else left of and above; none to place against is none said', async function () {
    var emitm = await import('../lib/emit.mjs');
    var A = { x: 100, y: 0, w: 300, h: 200 }, boxes = { A: A, B: { x: 100, y: 300, w: 400, h: 40 } };
    var boxMap = new Map(Object.keys(boxes).map(function (t) { return [t, boxes[t]]; }));
    var at = function (s, refs) { var l = emitm.against('b', s, 'S', refs, boxMap); return [l, placedAt(l, boxes, s.w, s.h)]; };
    eq(at({ x: 150, y: 20, w: 60, h: 60 }, ['A'])[1], [150, 20], 'right of its left edge, below its top');
    var left = at({ x: 0, y: 50, w: 100, h: 50 }, ['A']);
    assert(/^left of "A" right \(gap: 300\) below "A" top \(gap: 50\)$/.test(left[0]) && left[1][0] === 0, 'left of A: its right edge a gap left of A\'s right edge: ' + left[0]);
    var above = at({ x: 150, y: -60, w: 50, h: 40 }, ['A']);
    assert(/^right of "A" left \(gap: 50\) above "A" bottom \(gap: 220\)$/.test(above[0]) && above[1][1] === -60, 'above A: ' + above[0]);
    eq(at({ x: 20, y: -10, w: 30, h: 30 }, ['A'])[1], [20, -10], 'left of and above at once');
    // a shape that spans the first on an axis is placed against the next it does not span
    eq(at({ x: 90, y: 10, w: 330, h: 20 }, ['A', 'B'])[1], [90, 10], 'wider than A, and left of it: against B');
    assert(/"B" right/.test(emitm.against('b', { x: 90, y: 10, w: 330, h: 20 }, 'S', ['A', 'B'], boxMap)), 'by its right edge, since it is left of B and does not span it');
    var threw = ''; try { emitm.against('b', { x: 0, y: 0, w: 1000, h: 20 }, 'S', ['A'], boxMap); } catch (e) { threw = e.message; }
    assert(/"S" is wider than every shape drawn before it/.test(threw), 'a shape spanning every one it could be placed against is said: ' + threw);
    eq(emitm.against('b', A, 'A', [], boxMap), '', 'nothing drawn: no placement');
  });

  // draws the plan's shape runs as an app would, exactly: a shape with no placement where the app puts a drawing with nothing to hang on, every other where its
  // placement puts it, and the result is every title's box
  function simulate(r) {
    var boxesOf = {};
    r.runs.filter(function (x) { return /-(top|in-\d+|notes)\.draw$/.test(x.name); }).forEach(function (run) {
      run.text.split('\n').filter(Boolean).forEach(function (l) {
        var m = /^(sticky-note|frame|subboard) "([^"]+)".* size: (\d+)x(\d+)/.exec(l);
        if (!m) return;
        var w = Number(m[3]), h = Number(m[4]), at = placedAt(l, boxesOf, w, h);
        assert(!/gap: -/.test(l), 'no negative gap: ' + l);
        boxesOf[m[2]] = { x: (at || [640, 480])[0], y: (at || [640, 480])[1], w: w, h: h };
      });
    });
    return boxesOf;
  }
  // every shape lands where the plan has it, relative to the board's origin, read off the board's two anchors
  function landsAsPlanned(r, boxesOf) {
    r.plan.boards.forEach(function (b) {
      if (!b.shapes.length) return;
      var by = {}; b.shapes.forEach(function (s) { by[s.title] = s; });
      var ox = boxesOf[b.anchors.x].x - by[b.anchors.x].x, oy = boxesOf[b.anchors.y].y - by[b.anchors.y].y;
      b.shapes.forEach(function (s) {
        var g = boxesOf[s.title];
        assert(g, b.board + ': ' + s.title + ' was not drawn');
        assert(Math.abs(g.x - ox - s.x) < 1e-6 && Math.abs(g.y - oy - s.y) < 1e-6 && g.w === s.w && g.h === s.h, b.board + ': ' + s.title + ' planned ' + JSON.stringify([s.x, s.y, s.w, s.h]) + ', placed ' + JSON.stringify([g.x - ox, g.y - oy, g.w, g.h]));
      });
    });
  }

  await test('every board\'s shapes land where the plan has them when placed as their runs say: from the header note, or from two of the board\'s own shapes', async function () {
    var names = ['acme', 'tree', 'flat60', 'spine', 'typed'];
    for (var i = 0; i < names.length; i++) {
      var r = await planOf(fixture(names[i]), { into: i % 2 ? 'Map' : null });
      landsAsPlanned(r, simulate(r));
      checkPlan(r.plan);
    }
    // a subboard's board of notes with no arrows: packed, so the widest and the tallest are anywhere, and some shapes are left of and above them
    var nodes = [{ title: 'Part', kind: 'subboard', text: 'Part.' }, { title: 'Other', kind: 'subboard', text: 'Other.' }, { title: 'Frame', kind: 'frame' }];
    var words = ['Short', 'A rather longer note title here', 'Mid title', 'Tiny', 'The longest title of all, which makes its note the widest of them', 'Another one', 'And one more', 'Last'];
    words.forEach(function (w) { nodes.push(note(w, 'Part', 'x'), note(w + ' two', 'Other', 'y')); });
    nodes.push(note('In frame A', 'Frame', 'z'), note('In frame B', 'Frame', 'z'), note('Loose'));
    var many = await planOf(digest(nodes, []), { promote: false });
    landsAsPlanned(many, simulate(many));
    var part = many.plan.boards.find(function (b) { return b.board === 'Part'; });
    var forms = many.runs.filter(function (x) { return /-part-/.test(x.name); }).map(function (x) { return x.text; }).join('');
    assert(/left of "/.test(forms) || /above "/.test(forms), 'a board where some shape is left of or above the one it is placed against, so those forms are drawn: ' + part.anchors.x + ' ' + part.anchors.y);
  });

  await test('what the runs do on the app is compared to the plan from the anchors, and a description is checked as written, not as created', async function () {
    var rpl = await import('../lib/replay.mjs');
    var d = digest([{ title: 'Part', kind: 'subboard', text: 'The part, with @[Loose].' }, note('One', 'Part', 'x'), note('A longer second note', 'Part', 'y'), note('Third', 'Part', 'z'), note('Loose', null, 'w')], []);
    var r = await planOf(d, { promote: false });
    var boxesOf = {};
    var results = {}, line = 0;
    r.runs.forEach(function (run) {
      var changes = [];
      run.text.split('\n').filter(Boolean).forEach(function (l) {
        var m = /^(sticky-note|frame|subboard) "([^"]+)"/.exec(l), sz = /size: (\d+)x(\d+)/.exec(l);
        line++;
        if (/-describe\.draw$/.test(run.name)) { var b = boxesOf[m[2]]; changes.push({ line: line, did: 'updated', kind: m[1], title: m[2], at: [[b.x, b.y], [b.w, b.h]] }); return; }
        var w = Number(sz[1]), h = Number(sz[2]), at = placedAt(l, boxesOf, w, h) || [200, 300];
        boxesOf[m[2]] = { x: at[0] + 1000, y: at[1] + 500, w: w, h: h };   // the first of a board lands anywhere
        changes.push({ line: line, did: 'created', kind: m[1], title: m[2], at: [[boxesOf[m[2]].x, boxesOf[m[2]].y], [w, h]] });
      });
      results[run.name] = { changes: changes, warnings: [] };
    });
    // placements are against where the shapes landed, not the plan: put it right, the board's own offset being the first shape's (1000, 500 more than planned)
    Object.keys(boxesOf).forEach(function (t) { var b = boxesOf[t]; b.x -= 1000; b.y -= 500; });
    var ok = rpl.replay(r.plan, results, Object.keys(boxesOf));
    eq([ok.described, ok.describedPlanned, ok.restated], [1, 1, 0], 'one description, written once, and no shape restated: ' + ok.lines.join(' | '));
    assert(/descriptions 1\/1/.test(ok.lines[1]), 'the summary says it: ' + ok.lines[1]);
    // a description that changed nothing was not written
    var bad = JSON.parse(JSON.stringify(results)), name = r.runs.find(function (x) { return /-describe\.draw$/.test(x.name); }).name;
    bad[name].changes[0].did = 'unchanged';
    var fail = rpl.replay(r.plan, bad, null);
    assert(!fail.ok && /was unchanged: its description was not written/.test(fail.problems.join()), 'said: ' + fail.problems.join(' | '));
    // the driver names a run as the plan does less `.draw`, and a dry run too: the same run, the same description
    var cmpm = await import('../lib/compare.mjs');
    eq([cmpm.compareRun(r.plan, results[name], {}, name.replace(/\.draw$/, '') + ' (dry run)').described, cmpm.compareRun(r.plan, results[name], {}, name.replace(/\.draw$/, '')).described], [1, 1], 'a description is a description under either name');
    // and a run that never happened is said
    var gone = JSON.parse(JSON.stringify(results)); delete gone[name];
    assert(/was planned/.test(rpl.replay(r.plan, gone, null).problems.join()) || /no result was saved/.test(rpl.replay(r.plan, gone, null).problems.join()), 'a description run that did not happen is said');
  });

  await test('drawing again in place: what a drawing makes, whether it is in a board\'s file, what is clear of it, and the script that takes it back', async function () {
    var rd = await import('../lib/redraw.mjs');
    var r = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('In part', 'Part', 'x'), note('Root note', null, 'y')], []), { promote: false });
    var d = rd.drawnRecord(r.plan, '/f.canvasboard', 7, 12);
    eq(d.into, null); eq(d.path, '/f.canvasboard'); eq(d.board, '7'); eq(d.header, 'About T'); eq(d.shapes, 12);
    eq(rd.drawnRecord(r.plan, '/f.canvasboard', 7).shapes, null, 'while it is drawn, the count is not known');
    eq(d.root.slice().sort(), ['About T', 'Part', 'Root note'], 'the root board\'s shapes');
    assert(d.titles.indexOf('In part') >= 0 && d.titles.indexOf('About Part') < 0, 'every title: a subboard\'s board has no header note');
    assert(rd.sameFile(d, '/f.canvasboard', 9) && !rd.sameFile(d, '/g.canvasboard', 7) && !rd.sameFile(d, '', 7), 'by path, when there is one');
    var unsaved = rd.drawnRecord(r.plan, '', 4);
    assert(rd.sameFile(unsaved, '', 4, ['About T', 'Part']) && !rd.sameFile(unsaved, '', 5, ['About T']), 'by id, for a board with no file');
    assert(!rd.sameFile(unsaved, '', 4, ['Part']) && !rd.sameFile(unsaved, '', 4), 'and only while the drawing\'s header is in it: a later board may get the id');
    assert(rd.sameFile(unsaved, '/f.canvasboard', 4, ['About T']) && !rd.sameFile(unsaved, '/f.canvasboard', 4, ['Part']) && !rd.sameFile(unsaved, '/f.canvasboard', 5, ['About T']), 'a board saved since it was drawn on is still told by its id and the header');
    assert(rd.sameFile(rd.drawnRecord(r.plan, '/private/tmp/f.canvasboard', 7), '/tmp/f.canvasboard', 7) && !rd.sameFile(d, '/g.canvasboard', 7, ['About T']), 'a path is the file\'s own (/tmp is /private/tmp); two paths that differ are two files, whatever the id');
    eq(rd.minus(['Root  note', 'Mine', 'root note'], d), ['Mine', 'root note'], 'the file less the drawing (spaces folded, case kept: "root note" is another shape)');
    eq([rd.beyond(d, 12), rd.beyond(d, 13), rd.beyond(d, 9), rd.beyond(rd.drawnRecord(r.plan, '/f', 7), 40)], [0, 1, 0, 0], 'shapes beyond the drawing: one added; fewer is fine; unknown counts none');
    eq(rd.foreign(['About T', 'Part'], d), [], 'nothing foreign');
    // a folder of records, one a target file: the one told by the file's path, else by the board's id and header; never another's
    var recs = [{ name: 'b.json', record: unsaved }, { name: 'a.json', record: d }];
    eq([rd.pickRecord(recs, '/f.canvasboard', 7, ['About T']), rd.pickRecord(recs, '/g.canvasboard', 7, ['About T']), rd.pickRecord(recs, '', 4, ['About T']), rd.pickRecord(recs, '', 4, ['Part']), rd.pickRecord([], '/f.canvasboard', 7, [])], ['a.json', '', 'b.json', '', ''], 'the record of a file');
    var pn = rd.recordName('/tmp/f.canvasboard', 7, 'About T');
    assert(pn === rd.recordName('/private/tmp/f.canvasboard', 9, 'x') && pn !== rd.recordName('/tmp/g.canvasboard', 7, 'About T') && /^file-[0-9a-f]{16}\.json$/.test(pn), 'a file has one record name; two files two');
    assert(rd.recordName('', 4, 'About T') !== rd.recordName('', 4, 'About U') && /^board-4-[0-9a-f]{16}\.json$/.test(rd.recordName('', 4, 'About T')), 'a board with no file: its id and header');
    eq(rd.replaceScript(d, ['About T', 'Part', 'In part']), 'delete "About T"\ndelete "Part"', 'the root\'s shapes the file still holds; a subboard takes what is on its board');
    eq(rd.replaceScript(d, []), '', 'nothing left to take back');
    var into = await planOf(digest([note('A', null, 'x')], []), { promote: false, into: 'Map' });
    var di = rd.drawnRecord(into.plan, '/f.canvasboard', 7);
    eq(rd.replaceScript(di, ['Map', 'A', 'About T']), 'delete "Map"', 'into a subboard: the subboard alone');
    // a drawing made in place of the last one, until it is whole: the record is of both, since an undo or two may bring the last one back
    var next = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('New note', null, 'z')], []), { promote: false });
    var both = rd.drawnRecord(next.plan, '/f.canvasboard', 7, 3, d, 12);   // it stopped with 3 shapes in the file, which held 12 before the take-back
    eq([both.shapes, both.was], [3, 12], 'how many shapes the file holds as it stopped, and held before the last drawing was taken back');
    eq(both.takes.slice().sort(), ['About T', 'New note', 'Part', 'Root note'], 'what takes either back');
    assert(both.titles.indexOf('In part') >= 0 && both.titles.indexOf('New note') >= 0, 'the titles of both');
    eq(rd.foreign(['About T', 'Part', 'In part', 'Root note'], both), [], 'the last drawing, undone back, is not foreign');
    eq([rd.beyond(both, 3), rd.beyond(both, 0), rd.beyond(both, 12)], [0, 0, 0], 'part of the new drawing, none of it, or the last one whole: nothing added');
    eq([rd.beyond(both, 14), rd.beyond(both, 5), rd.beyond(both, 11)], [2, 2, 8], 'an arrow and a note added to either are counted, so the take-back is refused; a count that is neither drawing\'s is too');
    var early = rd.drawnRecord(next.plan, '/f.canvasboard', 7, null, d, 12);   // stopped before a count was taken
    eq([early.shapes, rd.beyond(early, 9), rd.beyond(early, 12), rd.beyond(early, 13)], [null, 0, 0, 1], 'with no count of its own, up to the last drawing\'s may be part of this one');
    eq(rd.replaceScript(both, ['About T', 'Part', 'Root note', 'In part'], ['About T', 'Part', 'Root note']), 'delete "About T"\ndelete "Part"\ndelete "Root note"', 'the last drawing is taken back by its own shapes');
    eq(rd.replaceScript(both, ['About T', 'New note'], ['About T', 'New note']), 'delete "About T"\ndelete "New note"', 'and as much of the new one as was drawn by its');
    eq(rd.replaceScript({ into: null, root: ['A', 'B'] }, ['B']), 'delete "B"', 'a record made before `takes` reads the same');
    // a shape the last drawing had on the root that this one holds inside a subboard goes with its subboard: one `delete` of it there
    // would put the script on two boards, which draw refuses
    var movedIn = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('Root note', 'Part', 'y')], []), { promote: false });
    var mv = rd.drawnRecord(movedIn.plan, '/f.canvasboard', 7, 2, d, 12);
    eq(rd.replaceScript(mv, ['About T', 'Part', 'Root note', 'In part'], ['About T', 'Part']), 'delete "About T"\ndelete "Part"', 'only what is on the root board');
    eq(rd.replaceScript(mv, ['About T', 'Part', 'Root note', 'In part'], ['About T', 'Part', 'Root note']), 'delete "About T"\ndelete "Part"\ndelete "Root note"', 'and the last drawing, undone back, by all three');
    // the last one drawn as the board, this one into a subboard of it (or the other way round): the subboard where the file holds it, the root's shapes where they are on the root
    var intoB = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('In part', 'Part', 'x'), note('Root note', null, 'y')], []), { promote: false, into: 'B' });
    var mixed = rd.drawnRecord(intoB.plan, '/f.canvasboard', 7, 5, d, 12);
    eq([mixed.was, mixed.intos, rd.beyond(mixed, 99)], [null, ['B'], 0], 'a drawing into a subboard counts nothing of the file');
    eq(rd.replaceScript(mixed, ['B', 'About T', 'Part', 'Root note', 'In part'], ['B']), 'delete "B"', 'the new subboard, with the same titles inside it');
    eq(rd.replaceScript(mixed, ['About T', 'Part', 'Root note', 'In part'], ['About T', 'Part', 'Root note']), 'delete "About T"\ndelete "Part"\ndelete "Root note"', 'the last drawing, back on the root');
    // the other way round: the last one into a subboard, this one as the board, which is drawn only on a file the take-back left empty,
    // so the count before it is the last drawing's own
    var back = rd.drawnRecord(next.plan, '/f.canvasboard', 7, 2, rd.drawnRecord(intoB.plan, '/f.canvasboard', 7, 9), 9);
    eq([back.was, rd.beyond(back, 9), rd.beyond(back, 10), rd.beyond(back, 2)], [9, 0, 1, 0], 'the subboard\'s drawing, undone back, is not counted as shapes added');
    eq(rd.replaceScript(back, ['B', 'About T', 'Part', 'Root note', 'In part'], ['B']), 'delete "B"', 'and is taken back by its subboard');
    var intoUnsaved = rd.drawnRecord(intoB.plan, '', 4);
    assert(rd.sameFile(intoUnsaved, '', 4, ['B', 'Mine']) && !rd.sameFile(intoUnsaved, '', 4, ['Mine']), 'a drawing into a subboard that stopped after its first script is told by the subboard: its header is not drawn yet');
    var rp = await import('../lib/replay.mjs');
    eq(rp.extract('root-titles', { rows: [{ board: 'root', title: 'A' }, { board: 'X', title: 'B' }, { board: 'root' }] }), ['A'], 'the titles on the root board');
    var renamed = rd.drawnRecord((await planOf(Object.assign(digest([note('A', null, 'x')], []), { title: 'U' }), { promote: false })).plan, '', 4, null, unsaved);
    assert(rd.sameFile(renamed, '', 4, ['About T']) && rd.sameFile(renamed, '', 4, ['About U']), 'either drawing\'s header tells the board');
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

  await test('how far off its shape a container is: the ratio of the two shapes; a board\'s header note counted; nothing for a board the view shows whole', async function () {
    eq(elkm.offShape(300, 100, 1.5), 2, 'twice too wide');
    eq(elkm.offShape(100, 300, 1.5), 4.5, 'four and a half times too tall');
    eq(elkm.offShape(150, 100, 1.5), 1, 'the shape itself');
    eq(elkm.offShapeOf(300, 100, { aspect: 1.5 }), 2, 'a shape with no view: the ratio');
    eq(elkm.offShapeOf(300, 100, { aspect: 1.5, headW: 0, headH: 100 }), 1, 'the header\'s room is part of the board');
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
    said(e, /^"Region": a frame can't be a type's instance/, 'is on a frame');
    said(e, /^"Card": a subboard can't be a type's instance/, 'is on a subboard');
    said(e, /^"Orphan": relationship: true needs a schema/, 'relationship without schema');
    said(e, /^"Rel note": is "writes", a relationship type: only an arrow is one/, 'a note of a relationship type');
    said(e, /^"Typed type": a type can't say is/, 'a type that is of a type');
    said(e, /^"Refd": the schema has a \$ref to urn:uuid:7c1e2a04-4b9e-4e0c-9d8c-5b0e7f3a2c11/, 'a $ref to an id');
    said(e, /^"Frame type": a frame can't be a type/, 'a schema on a frame');
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
    assert(h('Workflow').size[0] >= 320 && h('w1').size[0] >= 320, 'a typed note is 320 wide at least');
    assert(h('Workflow').size[1] > 200, 'a type with fields and ends grows');
    // an untyped digest has the script it always had
    var plain = sizes.measureScript(model.buildModel(fixture('tree')));
    assert(!/schema|relationship|is: |fieldValues|endRule/.test(plain), 'nothing typed in an untyped digest');
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
    assert(sh('Workflow').w >= 320 && sh('Workflow').h > 200, 'the type is stated at its measured size');
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
      b.shapes.forEach(function (s) { out.push({ board: 'root', title: s.title, kind: s.kind, x: origin.x + s.x, y: origin.y + s.y, w: s.w, h: s.h }); });
      b.edges.forEach(function (e) { out.push({ board: 'root', kind: 'arrow', from: e.from, to: e.to, is: e.is }); });
      if (mutate) mutate(out);
      return out;
    };
    var ok = verifym.verify(r.plan, rows());
    eq(ok.summary.edgesMissing, [], 'every arrow found: ' + JSON.stringify(ok.summary.edgesMissing));
    var swapped = verifym.verify(r.plan, rows(function (out) { out.forEach(function (x) { if (x.kind === 'arrow' && x.from === 'w1') x.is = ['writes']; }); }));
    eq(swapped.summary.edgesMissing, ['root: w1 -> t1 is reads'], 'two arrows of one type are not one of each');
    var plainArrow = verifym.verify(r.plan, rows(function (out) { out.forEach(function (x) { if (x.kind === 'arrow' && x.from === 'w1' && x.is[0] === 'reads') delete x.is; }); }));
    eq(plainArrow.summary.edgesMissing, ['root: w1 -> t1 is reads'], 'a plain arrow is not a relationship');
    var replayRun = (await import('../lib/replay.mjs')).replay;
    var res = {}; r.plan.runs.forEach(function (n) { res[n] = { changes: [], warnings: [], on: null }; });
    var first = res[r.plan.runs[0]], last = res[r.plan.runs[r.plan.runs.length - 1]], ox = 300, oy = 400;
    b.shapes.forEach(function (s) { first.changes.push({ did: 'created', title: s.title, kind: s.kind, at: [[ox + s.x, oy + s.y], [s.w, s.h]] }); });
    b.edges.forEach(function (e) { last.changes.push(Object.assign({ did: 'connected', kind: 'arrow', from: e.from, to: e.to }, e.is ? { is: e.is } : {})); });
    var titles = b.shapes.map(function (s) { return s.title; });
    var good = replayRun(r.plan, res, titles);
    eq(good.ok, true, good.lines.join('\n'));
    last.changes.forEach(function (c) { if (c.from === 'w1' && c.is && c.is[0] === 'reads') c.is = ['writes']; });
    var bad = replayRun(r.plan, res, titles);
    assert(!bad.ok && /not drawn as the relationship the plan says: w1 -> t1 is reads/.test(bad.lines.join('\n')), 'two arrows of the same type, the second type missing: ' + bad.lines.join('\n'));
  });

  await test('compare reports what a typed drawing says by design without failing the run, and still fails on a push, an order warning or a shape off its box', async function () {
    var d = typed([note('w1'), note('t1')], []);
    d.nodes[4].is = 'Workflow'; d.nodes[4].fieldValues = { name: 'w1' }; d.nodes[5].is = 'Table';
    var r = await planOf(d), b = r.plan.boards[0];
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, did: 'created', at: [[1000 + s.x, 2000 + s.y], [s.w, s.h]] }; });
    var warnings = [
      { line: 6, severity: 'incomplete', attribute: 'tables', message: '"w1": tables is needed' },
      { line: 7, severity: 'error', attribute: 'to', message: 'edge "w1" -> "t1": reads runs to a Table. “w1” is a Workflow.' },
      { line: 8, severity: 'error', attribute: 'jobs', message: '"Ann": jobs has 2 notes, and should have at most 1' },
      { line: 9, message: '2 shapes landed outside the view' }];
    var res = compareRun0(r.plan, { changes: rows, warnings: warnings }, {});
    eq(res.ok, true, JSON.stringify(res)); eq(res.warnings.typed, 3, 'the three typed ones are counted'); eq(res.warnings.view, 1);
    eq(res.warningMessages, [], 'and are no failure to name'); assert(res.typedMessages.length === 3 && /tables is needed/.test(res.typedMessages[0]), res.typedMessages.join());
    var withProblems = rows.map(function (x, i) { return i === 2 ? Object.assign({ problems: [{ field: 'tables', class: 'needed', message: 'tables is needed' }] }, x) : x; });
    var viaRows = compareRun0(r.plan, { changes: withProblems, warnings: [] }, {});
    eq(viaRows.ok, true); eq(viaRows.warnings.typed, 1, 'a row\'s problems are counted too'); assert(/^[^:]+: tables is needed$/.test(viaRows.typedMessages[0]), viaRows.typedMessages[0]);
    var pushed = compareRun0(r.plan, { changes: rows, warnings: warnings.concat([{ line: 3, message: 'B was pushed 40 right' }]) }, {});
    eq(pushed.ok, false, 'a push still fails'); eq(pushed.warnings.push, 1);
    var ordered = compareRun0(r.plan, { changes: rows, warnings: warnings.concat([{ line: 3, code: 'unordered', message: 'these two cannot be ordered' }]) }, {});
    eq(ordered.ok, false, 'an order warning still fails');
    var off = rows.map(function (x, i) { return i === 1 ? Object.assign({}, x, { at: [[x.at[0][0] + 9, x.at[0][1]], x.at[1]] }) : x; });
    eq(compareRun0(r.plan, { changes: off, warnings: warnings }, {}).ok, false, 'a shape off its box still fails');
    var text = clim.compareText(res);
    assert(/^ok .*; 3 warning\(s\) a typed drawing gives by design: /.test(text), text);
    // any other warning fails nothing and is said, never only counted: a title near one the board has, in the run's line and in verify's
    var near = { line: 4, code: 'near_title', message: 'created "worker (x)"; the board has "Workers (x)": to change that one, write its title exactly' };
    var withNear = compareRun0(r.plan, { changes: rows, warnings: warnings.concat([near]) }, {});
    eq(withNear.ok, true, 'another warning fails nothing'); eq(withNear.warnings.other, 1); eq(withNear.warningMessages, [], 'and is no failure to name');
    assert(/; 1 other warning\(s\): line 4: created "worker \(x\)"; the board has "Workers \(x\)"/.test(clim.compareText(withNear)), clim.compareText(withNear));
    var said = (await import('../lib/replay.mjs')).replay(r.plan, { [r.plan.runs[0]]: { changes: rows, warnings: [near] } }, null);
    assert(said.lines.some(function (l) { return /^  warning: .*line 4: created "worker \(x\)"/.test(l); }), said.lines.join('\n'));
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

  await test('two digests drawn into one unsaved board have two records, and the one replaced is this run\'s own: its header first, then the newest by the time written in it', async function () {
    var rd = await import('../lib/redraw.mjs');
    var one = await planOf(digest([note('A1')], [], { title: 'Alpha' }), { promote: false });
    var two = await planOf(digest([note('B1')], [], { title: 'Beta' }), { promote: false });
    var older = rd.drawnRecord(one.plan, '', 4, 3, null, null, 1000), newer = rd.drawnRecord(two.plan, '', 4, 6, null, null, 2000);
    eq([older.at, newer.at, rd.drawnRecord(one.plan, '', 4, 3).at], [1000, 2000, null], 'a record says when it was written');
    var titles = ['About Alpha', 'A1', 'About Beta', 'B1'];
    var recs = [{ name: 'board-4-0001.json', record: older }, { name: 'board-4-0002.json', record: newer }];
    eq(rd.pickRecord(recs, '', 4, titles, 'About Beta'), 'board-4-0002.json', 'this run draws Beta: its record, though Alpha\'s is first by name');
    eq(rd.pickRecord(recs, '', 4, titles, 'About Alpha'), 'board-4-0001.json', 'this run draws Alpha: its own');
    eq(rd.pickRecord(recs.slice().reverse(), '', 4, titles, 'About Alpha'), 'board-4-0001.json', 'whatever order the folder lists them');
    eq(rd.pickRecord(recs, '', 4, titles), 'board-4-0002.json', 'no header known: the newest');
    eq(rd.pickRecord(recs, '', 4, titles, 'About Gamma'), 'board-4-0002.json', 'a header of neither: the newest');
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
    var rows = b.shapes.map(function (s) { return { title: s.title, kind: s.kind, did: 'created', at: [[1000 + s.x, 2000 + s.y], [s.w, s.h]] }; });
    var withProblem = function (p) { return rows.map(function (x, i) { return i === 2 ? Object.assign({ problems: [p] }, x) : x; }); };
    var bad = compareRun0(r.plan, { changes: withProblem({ field: 'retries', path: '/retries', class: 'wrong', message: 'retries is "abc", and should be an integer' }), warnings: [] }, {});
    eq(bad.ok, false, 'a value that breaks its schema fails the run'); assert(/retries is "abc"/.test(bad.mismatches.join('\n')), 'and says which: ' + JSON.stringify(bad.mismatches));
    assert(/retries is "abc"/.test(clim.compareText(bad)), clim.compareText(bad));
    [{ field: 'tables', class: 'needed', message: 'tables is needed' }, { field: 'to', class: 'wrong', message: 'writes runs to a Table. "w1" is a Workflow.' }, { field: 'jobs', class: 'wrong', message: 'jobs has 2 notes, and should have at most 1' }, { field: 'to', class: 'warning', message: 'an end that cannot be read' }].forEach(function (p) {
      var ok = compareRun0(r.plan, { changes: withProblem(p), warnings: [] }, {});
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
    b.shapes.forEach(function (s) { rows.push({ board: 'root', title: s.title, kind: s.kind, x: 500 + s.x, y: 600 + s.y, w: s.w, h: s.h }); });
    b.edges.forEach(function (e) { rows.push({ board: 'root', kind: 'arrow', from: e.from, to: e.to, is: (e.is || []).slice().reverse() }); });
    eq(verifym.verify(r.plan, rows).summary.edgesMissing, [], 'verify: the same set is the same arrow');
    var replayRun = (await import('../lib/replay.mjs')).replay;
    var res = {}; r.plan.runs.forEach(function (n) { res[n] = { changes: [], warnings: [], on: null }; });
    var first = res[r.plan.runs[0]], last = res[r.plan.runs[r.plan.runs.length - 1]];
    b.shapes.forEach(function (s) { first.changes.push({ did: 'created', title: s.title, kind: s.kind, at: [[300 + s.x, 400 + s.y], [s.w, s.h]] }); });
    b.edges.forEach(function (e) { last.changes.push(Object.assign({ did: 'connected', kind: 'arrow', from: e.from, to: e.to }, e.is ? { is: e.is.slice().reverse() } : {})); });
    var good = replayRun(r.plan, res, b.shapes.map(function (s) { return s.title; }));
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
    // the header and the time: drawn writes when, and record-pick takes the header of this run
    out.length = 0;
    files['/plan.json'] = JSON.stringify(one.plan);
    await clim.run(['drawn', '/plan.json', '/f.canvasboard', '4', '3'], mio);
    eq(JSON.parse(out[0]).at, 7, 'drawn writes the time (the engine\'s clock)');
    out.length = 0;
    await clim.run(['header', '/plan.json'], mio);
    eq(out, ['About Alpha'], 'a plan\'s header');
    out.length = 0; files['/d.json'] = JSON.stringify(digest([note('A1')], [], { title: 'Alpha' }));
    await clim.run(['header', '/d.json'], mio);
    eq(out, ['About Alpha'], 'and a digest\'s');
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
    eq(r.plan.boards[0].shapes.length, promote.CROWD + 3, 'every shape planned: the pages, the index, the frame and the header');
    checkPlan(r.plan);
    assert(r.report.warnings.some(function (w) { return /board "root" was laid out once and not searched: its frame "Pages" holds 151 shapes side by side, past 150.*split it into subboards/.test(w); }), r.report.warnings.join('\n'));
    assert(/warning: board "root" was laid out once/.test(clim.summarize(r)), clim.summarize(r));
    // one fewer is searched as ever: the index's arrows fanned out as pills
    nodes.pop(); edges.pop();
    var searched = await planOf(digest(nodes, edges));
    assert(searched.report.boards.root.stop !== 'crowded' && !searched.report.warnings.length, searched.report.boards.root.stop);
    assert(searched.report.promotions.some(function (p) { return p.node === 'Index'; }), 'the index is moved: ' + JSON.stringify(searched.report.promotions.map(function (p) { return p.node; })));
  });

  io.print(results.length + ' passed, ' + failed + ' failed');
  if (failed) throw new Error('tests failed');
}).catch(function (e) { io.print('ERROR ' + (e && e.stack ? e.stack : e)); setTimeout(function () { throw e; }, 0); });
