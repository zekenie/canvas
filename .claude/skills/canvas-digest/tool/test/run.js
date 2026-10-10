// Unit tests:  jsc test/run.js     or     node test/run.js
// Classic script (import() finds ../lib from here in both engines). No app, no sockets, no pasteboard, no network.
var isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
var fsr = isNode ? require('fs') : null;
var io = {
  readText: function (p) { return isNode ? fsr.readFileSync(p, 'utf8') : readFile(p); },
  print: function (s) { isNode ? console.log(s) : print(s); },
};
Promise.all([import('../lib/dial.mjs'), import('../lib/model.mjs'), import('../lib/sizes.mjs'), import('../lib/elk.mjs'), import('../lib/plan.mjs'), import('../lib/cli.mjs'), import('../lib/util.mjs'), import('../lib/layout.mjs'), import('../lib/promote.mjs'), import('../lib/cost.mjs'), import('../lib/noise.mjs'), import('../lib/check.mjs'), import('./helpers.mjs'), import('../lib/compare.mjs')]).then(async function (mods) {
  var dialm = mods[0], model = mods[1], sizes = mods[2], elkm = mods[3], planm = mods[4], clim = mods[5], util = mods[6], layoutm = mods[7], promm = mods[8], costm = mods[9], noisem = mods[10], checkm = mods[11], helpers = mods[12], compareRun0 = mods[13].compareRun;
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
    planOf = function (dd, opts) { return planOf0(dd, Object.assign({ popular: 100000 }, opts || {})); };   // no node is popular here: every move is a judgment call
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
    var r2 = await planOf(digest(fx.nodes, fx.edges));
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

  await test('the measure script: every note, card and header once, then one edge through a reference to each end that is pointed at', async function () {
    var d = fixture('tree'), m = model.buildModel(d);
    var lines = sizes.measureScript(m).split('\n').filter(Boolean);
    var shapes = lines.filter(function (l) { return !/^edge /.test(l); }), edges = lines.filter(function (l) { return /^edge /.test(l); });
    var leaves = d.nodes.filter(function (n) { return n.kind !== 'frame'; }).length;
    eq(shapes.length, leaves + 2, 'every note and subboard, and a header a board (two boards)');
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

  await test('a board\'s header is never another\'s: a subboard called what the digest is keeps its own, and the digest\'s gives way', async function () {
    var d = digest([{ title: 'T', kind: 'subboard' }, note('In T', 'T', 'x'), note('About T (digest)', null, 'taken too')], []);
    var m = model.buildModel(d);
    eq(m.headers.get('T'), 'About T'); eq(m.headers.get('root'), 'About T (digest) (digest)', 'past the subboard\'s header and the note');
    var r = await planOf(d, { promote: false });
    var all = r.plan.boards.reduce(function (a, b) { return a.concat(b.shapes.map(function (x) { return x.title; })); }, []);
    eq(all.length, new Set(all).size, 'no title twice in the plan');
  });

  // ---- ranks, headers, and drawing again in place ----
  await test('ranked frames are rows in rank order, each as wide as the widest, what they hold centred; an unranked shape goes below them', async function () {
    var nodes = [{ title: 'Low', kind: 'frame', rank: 2 }, { title: 'Top', kind: 'frame', rank: 0 }, { title: 'Mid', kind: 'frame', rank: 1 }, note('Loose', null, 'no rank')];
    ['A', 'B', 'C', 'D'].forEach(function (x) { nodes.push(note('Top ' + x, 'Top', 'x')); });
    nodes.push(note('Mid A', 'Mid', 'x'), note('Low A', 'Low', 'x'), note('Low B', 'Low', 'x'));
    // arrows that point up the ranks: a layered layout would put Low above Top; the ranks win
    var edges = [{ from: 'Low A', to: 'Top A' }, { from: 'Low B', to: 'Mid A' }, { from: 'Mid A', to: 'Top B' }];
    var r = await planOf(digest(nodes, edges), { promote: false });
    var by = {}; rootOf(r.plan).shapes.forEach(function (s) { by[s.title] = s; });
    assert(by.Top.y + by.Top.h < by.Mid.y && by.Mid.y + by.Mid.h < by.Low.y, 'top, mid, low: ' + [by.Top.y, by.Mid.y, by.Low.y]);
    assert(by.Low.y + by.Low.h < by.Loose.y, 'the unranked note is below the bands');
    eq([by.Mid.w, by.Low.w], [by.Top.w, by.Top.w], 'every band as wide as the widest');
    eq([by.Mid.x, by.Low.x], [by.Top.x, by.Top.x], 'the bands are flush');
    var mid = by['Mid A'];
    assert(Math.abs((mid.x + mid.w / 2) - (by.Mid.x + by.Mid.w / 2)) <= 1, 'a narrow band\'s note is centred in it');
    checkPlan(r.plan);
  });

  await test('a board\'s header says the digest\'s text (the first board) or its subboard\'s; without one it says what it is of', async function () {
    var d = digest([{ title: 'Part', kind: 'subboard', text: 'What the part is.' }, note('In part', 'Part', 'x'), { title: 'Bare', kind: 'subboard' }, note('In bare', 'Bare', 'y')], [], { text: 'The whole, said once.' });
    var m = model.buildModel(d);
    eq(sizes.headerText(m, 'root'), 'The whole, said once.');
    eq(sizes.headerText(m, 'Part'), 'What the part is.');
    eq(sizes.headerText(m, 'Bare'), 'Bare. Drawn by canvas-digest.');
    var r = await planOf(d, { promote: false });
    var all = r.runs.map(function (x) { return x.text; }).join('\n');
    assert(all.indexOf('sticky-note "About T"') >= 0 && all.indexOf('text: "The whole, said once."') >= 0, 'the root header');
    assert(/sticky-note "About Part" in "Part" .*text: "What the part is\."/.test(all), 'the part\'s header');
    assert(!/subboard "Part"[^\n]*text:/.test(all), 'a subboard\'s card has no text');
    var mm = sizes.measureScript(m);
    assert(mm.indexOf('"About Part"') >= 0 && mm.indexOf('What the part is.') >= 0, 'the header is measured with its text');
  });

  await test('drawing again in place: what a drawing makes, whether it is in a board\'s file, what is clear of it, and the script that takes it back', async function () {
    var rd = await import('../lib/redraw.mjs');
    var r = await planOf(digest([{ title: 'Part', kind: 'subboard' }, note('In part', 'Part', 'x'), note('Root note', null, 'y')], []), { promote: false });
    var d = rd.drawnRecord(r.plan, '/f.canvasboard', 7, 12);
    eq(d.into, null); eq(d.path, '/f.canvasboard'); eq(d.board, '7'); eq(d.header, 'About T'); eq(d.shapes, 12);
    eq(rd.drawnRecord(r.plan, '/f.canvasboard', 7).shapes, null, 'while it is drawn, the count is not known');
    eq(d.root.slice().sort(), ['About T', 'Part', 'Root note'], 'the root board\'s shapes');
    assert(d.titles.indexOf('In part') >= 0 && d.titles.indexOf('About Part') >= 0, 'every title');
    assert(rd.sameFile(d, '/f.canvasboard', 9) && !rd.sameFile(d, '/g.canvasboard', 7) && !rd.sameFile(d, '', 7), 'by path, when there is one');
    var unsaved = rd.drawnRecord(r.plan, '', 4);
    assert(rd.sameFile(unsaved, '', 4, ['About T', 'Part']) && !rd.sameFile(unsaved, '', 5, ['About T']), 'by id, for a board with no file');
    assert(!rd.sameFile(unsaved, '', 4, ['Part']) && !rd.sameFile(unsaved, '', 4), 'and only while the drawing\'s header is in it: a later board may get the id');
    assert(rd.sameFile(unsaved, '/f.canvasboard', 4, ['About T']) && !rd.sameFile(unsaved, '/f.canvasboard', 4, ['Part']) && !rd.sameFile(unsaved, '/f.canvasboard', 5, ['About T']), 'a board saved since it was drawn on is still told by its id and the header');
    assert(rd.sameFile(rd.drawnRecord(r.plan, '/private/tmp/f.canvasboard', 7), '/tmp/f.canvasboard', 7) && !rd.sameFile(d, '/g.canvasboard', 7, ['About T']), 'a path is the file\'s own (/tmp is /private/tmp); two paths that differ are two files, whatever the id');
    eq(rd.minus(['Root  note', 'Mine', 'root note'], d), ['Mine', 'root note'], 'the file less the drawing (spaces folded, case kept: "root note" is another shape)');
    eq([rd.beyond(d, 12), rd.beyond(d, 13), rd.beyond(d, 9), rd.beyond(rd.drawnRecord(r.plan, '/f', 7), 40)], [0, 1, 0, 0], 'shapes beyond the drawing: one added; fewer is fine; unknown counts none');
    eq(rd.foreign(['About T', 'Part'], d), [], 'nothing foreign');
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
    eq(rd.replaceScript(mv, ['About T', 'Part', 'Root note', 'About Part'], ['About T', 'Part']), 'delete "About T"\ndelete "Part"', 'only what is on the root board');
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

  io.print(results.length + ' passed, ' + failed + ' failed');
  if (failed) throw new Error('tests failed');
}).catch(function (e) { io.print('ERROR ' + (e && e.stack ? e.stack : e)); setTimeout(function () { throw e; }, 0); });
