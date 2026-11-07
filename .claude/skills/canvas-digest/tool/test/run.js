// Unit tests:  jsc test/run.js     or     node test/run.js
// Classic script (import() finds ../lib from here in both engines). No app, no sockets, no pasteboard, no network.
var isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
var RUN_ARGS = typeof arguments !== 'undefined' ? Array.prototype.slice.call(arguments) : [];   // jsc's, after `--`
var fsr = isNode ? require('fs') : null;
var io = {
  readText: function (p) { return isNode ? fsr.readFileSync(p, 'utf8') : readFile(p); },
  print: function (s) { isNode ? console.log(s) : print(s); },
};
Promise.all([import('../lib/dial.mjs'), import('../lib/model.mjs'), import('../lib/sizes.mjs'), import('../lib/elk.mjs'), import('../lib/plan.mjs'), import('../lib/cli.mjs'), import('../lib/util.mjs'), import('../lib/layout.mjs'), import('../lib/promote.mjs'), import('../lib/cost.mjs'), import('../lib/noise.mjs'), import('../lib/check.mjs'), import('./helpers.mjs'), import('../lib/emit.mjs')]).then(async function (mods) {
  var dialm = mods[0], sizes = mods[2], elkm = mods[3], clim = mods[5], util = mods[6], layoutm = mods[7], promm = mods[8], costm = mods[9], noisem = mods[10], helpers = mods[12];
  var base = util.TOOL_DIR;
  // The app's kinds as the tool reads them (`canvas kinds`): the tool names no kind, and the driver gives them to every command that reads a document.
  // This copy is what the tests read them by (CompositionTests' DigestTests hold it to the app's answer).
  var KINDS = JSON.parse(io.readText(base + '/test/fixtures/kinds.json'));
  var model = Object.assign({}, mods[1], { buildModel: function (d, mess, kinds, opts) { return mods[1].buildModel(d, mess, kinds === undefined ? KINDS : kinds, opts); } });
  var checkm = Object.assign({}, mods[11], { checkGraph: function (d, opts) { return mods[11].checkGraph(d, Object.assign({ kinds: KINDS }, opts || {})); } });
  var planm = Object.assign({}, mods[4], { planGraph: function (d, sz, opts, e) { return mods[4].planGraph(d, sz, Object.assign({ kinds: KINDS }, opts || {}), e); } });
  var elk = await elkm.loadElk(io, base);
  var RECORD = isNode && process.argv[2] === 'record';
  var results = [], failed = 0;
  // `jsc test/run.js -- K/N` runs the tests dealt to part K of N (the Kth, the K+Nth, ... of them in order, counting from 0), so a caller can run the parts side by side;
  // the part's last line says how many of how many it ran. Without it, every test runs.
  var partArg = isNode ? process.argv[2] : RUN_ARGS[0];
  if (partArg === 'record') partArg = null;
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

  // Graph documents, written compactly: a node by its title (which is also its key), the notes' words in props.text. `old` shapes of the digest tests
  // ({title, kind, in, text, rank, pill}) become nodes ({key, kind, in, props, layout}), and an edge's weight and direct move under `layout`.
  function note(t, f, text) { var n = { title: t, kind: 'sticky-note', text: text || '' }; if (f) n.in = f; return n; }
  function nodeOf(n) {
    var out = { key: n.key || n.title };
    if (n.in) out.in = n.in;
    out.kind = n.kind || 'sticky-note';
    var props = Object.assign({}, n.props || {}), lay = Object.assign({}, n.layout || {});
    for (var k in n) { if (['key', 'title', 'kind', 'in', 'props', 'layout'].indexOf(k) >= 0) continue; if (k === 'rank' || k === 'pill') lay[k] = n[k]; else props[k] = n[k]; }
    if (n.title != null) props.title = n.title;
    out.props = props;
    if (Object.keys(lay).length) out.layout = lay;
    return out;
  }
  function edgeOf(e) {
    var out = { from: e.from, to: e.to }, props = Object.assign({}, e.props || {}), lay = Object.assign({}, e.layout || {});
    for (var k in e) { if (['from', 'to', 'props', 'layout', 'key'].indexOf(k) >= 0) continue; if (k === 'weight' || k === 'direct') lay[k] = e[k]; else props[k] = e[k]; }
    if (Object.keys(props).length) out.props = props;
    if (Object.keys(lay).length) out.layout = lay;
    return out;
  }
  function digest(nodes, edges, extra) {
    var d = { drawing: 't', nodes: nodes.map(nodeOf), edges: edges.map(edgeOf) };
    if (extra && extra.layout) d.layout = extra.layout;
    if (extra && extra.policy) d.layout = extra.policy;
    return d;
  }
  var fixture = function (name) { return JSON.parse(io.readText(base + '/test/fixtures/' + name + '.graph.json')); };
  // the app's answer for a graph, estimated; `refused` are the edges it would not draw
  var measureOf = function (d, refused) { var m = model.buildModel(d); return helpers.estimateMeasure(m, d, refused); };
  var sizesOf = function (d) { var m = model.buildModel(d); return sizes.sizesFrom(m, helpers.estimateMeasure(m, d)); };
  var planOf = async function (d, opts) { return planm.planGraph(d, function (m) { return sizes.sizesFrom(m, helpers.estimateMeasure(m, d)); }, opts || {}, elk); };
  // a plan must be self-consistent: nothing overlaps, shapes inside their frames 40 clear, pills inside their start's frame
  function checkPlan(plan) {
    plan.boards.forEach(function (b) {
      var by = {}; b.shapes.forEach(function (s) { by[s.key] = s; });
      var boxes = b.shapes.map(function (s) { return { id: s.key, x: s.x, y: s.y, w: s.w, h: s.h, kind: s.kind }; })
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
        assert(s.x >= 0 && s.y >= 0, 'negative offset ' + s.key);
        if (s.in) { var f = by[s.in]; assert(s.x >= f.x + 40 && s.y >= f.y + 40 && s.x + s.w <= f.x + f.w - 40 && s.y + s.h <= f.y + f.h - 40, s.key + ' is not 40 inside ' + s.in); }
      });
      b.pills.forEach(function (p) { var st = by[p.start]; if (st.in) { var f = by[st.in]; assert(p.x + p.w <= f.x + f.w - 40 && p.y >= f.y + 40 && p.y + p.h <= f.y + f.h - 40, 'pill of ' + p.start + ' leaves ' + st.in); } });
    });
  }
  var pillSet = function (plan) { var s = []; plan.boards.forEach(function (b) { b.edges.forEach(function (e) { if (e.via) s.push(b.board + '|' + e.from + '>' + e.to); }); }); return s.sort(); };
  // the document's edges whose start is on a board, in the order the apply document lists them
  var edgeRows = function (r, board) { return r.drawing.edges.filter(function (e) { return r.model.node(e.from).board === board; }); };
  var pillOf = function (e) { return e.place && e.place.pill; };

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
    var rows = edgeRows(r, 'root');
    pills.forEach(function (pl) {
      var frame = 'Team ' + pl.start.charAt(1);
      var mine = rows.filter(function (e) { return e.to === 'Hub' && e.from.charAt(1) === pl.start.charAt(1) && e.from.charAt(0) === 'u'; });
      eq(mine.length, 5, 'five edges for ' + frame);
      var host = mine.filter(function (e) { return pillOf(e).at; });
      eq(host.map(function (e) { return e.from; }), [pl.start], 'one edge makes the pill, the host\'s: ' + frame);
      assert(pillOf(host[0]).in === frame, 'in its frame');
      mine.filter(function (e) { return !pillOf(e).at; }).forEach(function (e) { eq(pillOf(e), { share: pl.start }, 'the others share the host\'s pill'); assert(rows.indexOf(e) > rows.indexOf(host[0]), 'after the host\'s'); });
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
    assert(edgeRows(r, 'root').filter(function (e) { return e.from === 'Loose' && e.to === 'Hub'; }).every(function (e) { return pillOf(e).share == null && pillOf(e).at; }), 'Loose\'s pill is its own');
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
    var shapes = {}; root.shapes.forEach(function (s) { shapes[s.key] = s; });
    var len = function (host) { var p = { x: shapes[host].x + shapes[host].w + 80, y: shapes[host].y + shapes[host].h / 2 - 16, w: pill.w, h: 32 }; var t = 0; ['U1', 'U2', 'U3', 'U4', 'U5'].forEach(function (u) { if (u !== host) { var a = shapes[u]; t += Math.hypot(a.x + a.w / 2 - (p.x + p.w / 2), a.y + a.h / 2 - (p.y + 16)); } }); return t; };
    var best = Math.min.apply(null, ['U1', 'U2', 'U3', 'U4', 'U5'].map(len));
    assert(len(pill.start) <= best * 1.15, 'the host ' + pill.start + ' is within 15% of the best: ' + len(pill.start) + ' vs ' + best);
    var rows = edgeRows(r, 'root').filter(function (e) { return e.to === 'Hub'; });
    eq(rows[0].from, pill.start, 'the host\'s edge is listed first'); assert(pillOf(rows[0]).at, 'and makes the pill');
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
    for (var c = 1; c <= 11; c++) { nodes.push(note('c' + c, 'Wide')); edges.push({ from: prev, to: 'c' + c }); prev = 'c' + c; }
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
    var rows = edgeRows(r2, 'root');
    pills.forEach(function (pl) {
      var mine = rows.filter(function (e) { return e.to === 'Hub' && /^[ab]\d$/.test(e.from) && (e.from === pl.start || pillOf(e).share === pl.start); });
      eq(mine.length, 4, 'four edges for the cluster of ' + pl.start);
      var host = rows.find(function (e) { return e.from === pl.start && e.to === 'Hub'; });
      assert(pillOf(host).at && pillOf(host).share == null, 'the host\'s edge makes the pill: ' + JSON.stringify(host.place));
      mine.filter(function (e) { return e !== host; }).forEach(function (e) { eq(pillOf(e), { share: pl.start }, 'a member says share: the host'); assert(rows.indexOf(e) > rows.indexOf(host), 'after the host\'s'); });
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
    var rows = edgeRows(r, 'root').filter(function (e) { return e.to === 'Hub' && /^[a-z]\d$/.test(e.from); });
    assert(rows.filter(function (e) { return pillOf(e).share != null; }).length === 7 && rows.filter(function (e) { return pillOf(e).at; }).length === 1, 'seven share the host\'s pill, one makes it');
  });

  await test('a higher --prefer never makes more pills', async function () {
    var fx = wideFixture(2, 4, 14), d = digest(fx.nodes, fx.edges);
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
    var rows = edgeRows(r, 'root');
    hubPills(r, fx.users).filter(function (x) { return x.users === 1; }).forEach(function (x) { assert(pillOf(rows.find(function (e) { return e.from === x.start && e.to === 'Hub'; })).share == null, 'a lone user\'s pill is its own'); });
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
    var a = await planm.planGraph(d, s0, {}, elk), b = await planm.planGraph(JSON.parse(JSON.stringify(d)), JSON.parse(JSON.stringify(s0)), {}, elk);
    eq(JSON.stringify(a.plan), JSON.stringify(b.plan), 'the plan');
    eq(JSON.stringify(a.drawing), JSON.stringify(b.drawing), 'drawing.json');
    var d2 = JSON.parse(JSON.stringify(d)); d2.nodes.reverse(); d2.edges.reverse();
    var c = await planm.planGraph(d2, s0, {}, elk);
    eq(JSON.stringify(a.plan), JSON.stringify(c.plan), 'plan.json with the input reversed');
  });

  // ---- spines ----
  // the spine fixture: Band's cards A, B, C and D point at Base's notes and not at each other: X every card, Y A and B, Z C and D, V A and
  // C, W A alone. A pairs with B (two in common), C with D: rows [A, B] and [C, D], A and C on the left. (DigestTests draws it too.)
  function spineFixture(more) { var d = fixture('spine'); d.edges = d.edges.concat(more || []); return d; }
  var algorithmOf = function (r, container) { var a = r.report.boards.root.algorithms.find(function (x) { return x.container === container; }); return a && a.algorithm; };
  await test('a frame of cards that point at many of the same shapes, and not at each other, is a spine: its shared pills between its two columns', async function () {
    var r = await planOf(spineFixture());
    eq(algorithmOf(r, 'Band'), 'spine', 'Band is a spine');
    assert(algorithmOf(r, 'Base') !== 'spine', 'Base, which points at nothing, is not');
    var root = rootOf(r.plan), by = {};
    root.shapes.forEach(function (s) { by[s.key] = s; });
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
    // the document: each shared pill made by its first card's edge, at the place the plan has it, in Band; the others share it
    var rows = edgeRows(r, 'root');
    var edgeOf = function (a, b) { return rows.find(function (e) { return e.from === a && e.to === b; }); };
    var band = by.Band;
    [['A', 'X', x], ['A', 'Y', y], ['C', 'Z', z]].forEach(function (k) {
      var p = pillOf(edgeOf(k[0], k[1]));
      assert(p && p.in === 'Band', 'the maker of ' + k[1] + "'s pill, in Band: " + JSON.stringify(p));
      eq(p.at, [k[2].x - band.x, k[2].y - band.y], 'its place in Band');
    });
    [['B', 'X', 'A'], ['C', 'X', 'A'], ['D', 'X', 'A'], ['B', 'Y', 'A'], ['D', 'Z', 'C']].forEach(function (k) { eq(pillOf(edgeOf(k[0], k[1])), { share: k[2] }, k.join(' ')); });
    // a copy of its own for a card alone in its row, on its left, placed where the plan has it
    [['A', 'V'], ['A', 'W'], ['C', 'V']].forEach(function (k) {
      var p = pillOf(edgeOf(k[0], k[1])), pl = root.pills.find(function (q) { return q.start === k[0] && q.for === k[1]; });
      eq(p.at, [pl.x - band.x, pl.y - band.y], k.join(' ') + ' is where the plan has it');
    });
    assert(rows.indexOf(edgeOf('A', 'X')) < rows.indexOf(edgeOf('B', 'X')), 'the maker before the edges that share its pill');
    eq(r.plan.boards[0].pills.map(function (p) { return p.for; }).filter(function (t) { return 'VWXYZ'.indexOf(t) >= 0; }).filter(function (t, i, a) { return a.indexOf(t) === i; }).sort(), ['V', 'W', 'X', 'Y', 'Z'], 'what a spine points at is reached through pills');
    checkPlan(r.plan);
    // byte for byte the same, and the same in another order
    var again = await planOf(spineFixture());
    eq(JSON.stringify(again.plan), JSON.stringify(r.plan), 'plan.json');
    eq(JSON.stringify(again.drawing), JSON.stringify(r.drawing), 'drawing.json');
    var d2 = spineFixture(); d2.nodes.reverse(); d2.edges.reverse();
    var reversed = await planOf(d2);
    eq(JSON.stringify(reversed.plan), JSON.stringify(r.plan), 'plan.json with the input reversed');
    var placesOf = function (x) { return JSON.stringify(x.drawing.nodes.map(function (n) { return [n.key, n.place]; }).sort()); };
    eq(placesOf(reversed), placesOf(r), 'the places with the input reversed');
  });

  await test('a frame whose cards point at each other is no spine, and its shared pills are in a host\'s column as ever; nor is any with promote off or at mess 1', async function () {
    var r = await planOf(spineFixture([{ from: 'A', to: 'B' }]));
    assert(algorithmOf(r, 'Band') !== 'spine', 'Band is laid out as any frame is: ' + algorithmOf(r, 'Band'));
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
    var d = spineFixture(); d.nodes.push(nodeOf(note('Idle', 'Band')));
    var idle = await planOf(d);
    eq(algorithmOf(idle, 'Band'), 'spine');
    var root = rootOf(idle.plan), by = {};
    root.shapes.forEach(function (sh) { by[sh.key] = sh; });
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
    var p = pillOf(edgeRows(r, 'Lib').find(function (e) { return e.from === 'A' && e.to === 'X'; }));
    assert(p && p.in == null, 'in nothing: ' + JSON.stringify(p));
    eq(p.at, [x.x, x.y], 'from the board\'s origin, where the plan has it');
    eq(lib.shapes.map(function (s) { return s.key; }).sort(), ['A', 'B', 'C'], 'the board holds its shapes and nothing else');
    checkPlan(r.plan);
  });

  await test('promote off: every arrow plain, only the pills between boards; edges between boards are pills', async function () {
    var nodes = [{ title: 'Sub', kind: 'subboard' }, note('Inner A', 'Sub'), note('Inner B', 'Sub'), note('Top A'), note('Top B')];
    var edges = [{ from: 'Top A', to: 'Top B' }, { from: 'Top A', to: 'Inner B' }, { from: 'Inner A', to: 'Top B' }, { from: 'Inner A', to: 'Inner B' }];
    var r = await planOf(digest(nodes, edges), { promote: false });
    eq(r.report.promotions.length, 0);
    var ps = pillSet(r.plan);
    eq(ps, ['Sub|Inner A>Top B', 'root|Top A>Inner B'], 'pills');
    // the document keeps the nodes and the edges as given, an edge through a pill saying where its pill is
    eq(r.drawing.nodes.map(function (n) { return n.key; }), nodes.map(function (n) { return n.title; }), 'the nodes, in the order given');
    eq(r.drawing.edges.filter(function (e) { return pillOf(e); }).map(function (e) { return e.from + '>' + e.to; }).sort(), ['Inner A>Top B', 'Top A>Inner B'], 'the edges through pills');
    eq(r.drawing.edges.filter(function (e) { return !pillOf(e); }).map(function (e) { return e.from + '>' + e.to; }).sort(), ['Inner A>Inner B', 'Top A>Top B'], 'the arrows');
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

  await test('the dial and the model: the flag wins over layout.mess; mu comes from mess', async function () {
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
          var ps = b.pills.filter(function (p) { return p.start === s.key; });
          var x1 = Math.max.apply(null, [s.x + s.w].concat(ps.map(function (p) { return p.x + p.w; })));
          var y0 = Math.min.apply(null, [s.y].concat(ps.map(function (p) { return p.y; }))), y1 = Math.max.apply(null, [s.y + s.h].concat(ps.map(function (p) { return p.y + p.h; })));
          return { t: s.key, in: s.in, x: s.x, y: y0, w: x1 - s.x, h: y1 - y0 };
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
          assert(near >= 60 && near <= 160, 'mess ' + mess + ': ' + f.key + ' is ' + Math.round(near) + ' from the nearest frame (draw\'s gaps: 40, 80)');
        });
      }
    }
  });

  await test('packing: a hub whose arrows all became pills sits with its frame mates, not a board away', async function () {
    // Hub is promoted (it has pills for every user), so it has no plain arrow left in its own frame
    var fx = hubFixture(3, 6); var r = await planOf(digest(fx.nodes, fx.edges), { mess: 0.2 });
    assert(r.report.promotions.length >= 1, 'hub promoted');
    var b = rootOf(r.plan), hubS = b.shapes.find(function (s) { return s.key === 'Hub'; });
    var frame = b.shapes.find(function (s) { return s.key === 'Hub frame'; });
    assert(hubS.x >= frame.x + 40 && hubS.y >= frame.y + 40, 'the hub is inside its frame');
    assert(frame.w * frame.h <= 4 * hubS.w * hubS.h + 1, 'the hub\'s frame is not a mostly-empty field around a lone note: ' + frame.w + 'x' + frame.h);
  });

  // ---- the build: the digest checks, the measure script and JSON, the fixtures, the commands ----
  await test('a popular node is promoted whatever the layout measures: the most arrows first, by the dial\'s count, never at mess 1', async function () {
    var fx = hubFixture(4, 5);   // 20 users point at Hub
    var d = digest(fx.nodes, fx.edges);
    eq([dialm.dial(0).popular, dialm.dial(0.1).popular, dialm.dial(0.5).popular, dialm.dial(1).popular], [4, 5, 9, 14], 'the dial\'s popular');
    var r = await planOf(d, { marginPills: 100000 });   // a margin no measured gain beats
    eq(r.report.promotions.map(function (p) { return [p.mode, p.node, !!p.popular, p.arrows]; }), [['in', 'Hub', true, 20]], 'the hub, as popular, with its 20 arrows');
    eq(r.plan.boards[0].edges.filter(function (e) { return !e.via && e.to === 'Hub'; }).length, 0, 'no plain arrow into it is left');
    assert(r.plan.boards[0].pills.some(function (p) { return p.for === 'Hub'; }), 'and its users have pills for it');
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
    var rep = { totals: { pills: 0, sharedArrows: 0, arrows: 0 }, warnings: [],
      promotions: [{ board: 'root', mode: 'in', node: 'Kept' }, { board: 'root', mode: 'in', node: 'Back' }, { board: 'Part', mode: 'out', node: 'Fan' }, { board: 'Part', mode: 'out', node: 'Fan back' }, { board: 'Part', mode: 'in', node: 'Back' }],
      boards: { root: { stop: 'little-gain', demotions: [{ board: 'root', mode: 'in', node: 'Back' }] }, Part: { stop: 'good-enough', demotions: [{ board: 'Part', mode: 'out', node: 'Fan back' }] } } };
    var text = clim.summarize({ report: rep, plan: { boards: [] }, model: { dial: { mess: 0.1, longest: 1300 } } });
    assert(/promoted 2: Kept, Back;/.test(text), 'the promotion taken back on the root is left out; the one of that name on another board stays: ' + text);
    assert(/fanned out 1: Fan$/m.test(text), 'and so is the fan-out taken back: ' + text);
  });

  await test('a node that points at many is fanned out: each of its uses a pill beside it; never to a shape kept off pills, nor an edge that is never a pill', async function () {
    var targets = ['t1', 't2', 't3', 't4', 't5', 't6', 't7', 't8'];
    var nodes = [note('Joiner')].concat(targets.map(function (t) { return note(t); })).concat([{ title: 'Private', kind: 'sticky-note', text: 'x', pill: false }, note('Plain')]);
    var edges = targets.map(function (t) { return { from: 'Joiner', to: t }; }).concat([{ from: 'Joiner', to: 'Private' }, { from: 'Joiner', to: 'Plain', direct: true }]);
    var r = await planOf(digest(nodes, edges), { marginPills: 100000 });
    eq(r.report.promotions.map(function (p) { return [p.mode, p.node, !!p.popular, p.arrows]; }), [['out', 'Joiner', true, 8]], 'the joiner, fanned out, for its 8 uses that may be pills');
    eq(r.report.boards.root.fanned, ['Joiner']); eq(r.report.boards.root.promoted, [], 'nothing is promoted');
    var out = r.plan.boards[0].edges.filter(function (e) { return e.from === 'Joiner'; });
    eq(out.filter(function (e) { return e.via; }).map(function (e) { return e.to; }).sort(), targets, 'each use is an edge through a reference');
    eq(out.filter(function (e) { return !e.via; }).map(function (e) { return e.to; }).sort(), ['Plain', 'Private'], 'the direct edge and the one to a shape kept off pills stay arrows');
    eq(r.plan.boards[0].pills.filter(function (p) { return p.start === 'Joiner'; }).length, 8, 'eight pills beside it');
    eq(r.plan.boards[0].pills.map(function (p) { return p.for; }).sort(), targets, 'the pills stand for the uses, and none for the joiner');
    assert(r.drawing.edges.filter(function (e) { return e.from === 'Joiner' && pillOf(e); }).length === 8, 'drawn that way: eight edges through pills');
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
    assert(r.plan.boards[0].pills.some(function (p) { return p.for === 'n6'; }), 'n6 has a pill');
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

  function rankedDigest() {
    var nodes = [{ title: 'Low', kind: 'frame', rank: 2 }, { title: 'Top', kind: 'frame', rank: 0 }, { title: 'Mid', kind: 'frame', rank: 1 }, note('Loose', null, 'no rank')];
    ['A', 'B', 'C', 'D'].forEach(function (x) { nodes.push(note('Top ' + x, 'Top', 'x')); });
    nodes.push(note('Mid A', 'Mid', 'x'), note('Low A', 'Low', 'x'), note('Low B', 'Low', 'x'));
    return digest(nodes, [{ from: 'Low A', to: 'Top A' }, { from: 'Low B', to: 'Mid A' }, { from: 'Mid A', to: 'Top B' }]);
  }
  function shapesOf(r) { var by = {}; rootOf(r.plan).shapes.forEach(function (s) { by[s.key] = s; }); return by; }
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

  await test('layout.ranks says which way ranked children run, and --ranks says it over the document', async function () {
    var d = Object.assign(rankedDigest(), { layout: { ranks: 'rows' } }), wide = { w: 2400, h: 800 };
    assert(isRows(shapesOf(await planOf(d, { promote: false, view: wide }))), 'the digest says rows, in a view that would have columns');
    assert(isColumns(shapesOf(await planOf(d, { promote: false, view: wide, ranks: 'columns' }))), 'the option says columns over it');
    assert(isColumns(shapesOf(await planOf(d, { promote: false, view: wide, ranks: 'auto' }))), 'and auto leaves it to the view');
    var threw = ''; try { model.buildModel(Object.assign(rankedDigest(), { layout: { ranks: 'sideways' } })); } catch (e) { threw = e.message; }
    assert(/layout\.ranks is rows or columns/.test(threw), 'another word is refused: ' + threw);
    eq(checkm.checkGraph(Object.assign(rankedDigest(), { layout: { ranks: 'sideways' } })).errors.length, 1, 'and check says so');
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
    var pages = r.plan.boards[0].shapes.find(function (s) { return s.key === 'Pages'; });
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



  // ---- the render layer names nothing of the app ----
  await test('no kind, attribute or channel name of the app is a string literal in lib/*.mjs, and the check sees each kind of quote', async function () {
    var names = await import('./names-lib.mjs');
    var scanned = names.scan(io.readText);
    eq(scanned.bad.map(names.say), [], 'string literals naming the app');
    ['frame', 'sticky-note', 'subboard', 'reference', 'text', 'description', 'private', 'fieldValues', 'frame-link', 'note-link', 'subboard-link'].forEach(function (n) { assert(scanned.names[n], n + ' is collected from the kinds'); });
    var found = function (src) { return names.offences('x.mjs', src, scanned.names).map(function (o) { return o.line + ':' + o.text; }); };
    eq(found("var a = 'frame';\nvar b = \"text\";\nvar c = `private`;"), ['1:frame', '2:text', '3:private'], 'single, double and backtick');
    eq(found("// 'frame' in a comment\n/* \"text\" too */\nvar a = 'a frame in words'; var b = x.private; var r = /frame/;"), [], 'comments, longer strings, property names and regular expressions are not literals');
    // the modules named in names-lib are the ones in lib/ (jsc cannot list a folder; node can)
    if (isNode) eq(fsr.readdirSync(base + '/lib').filter(function (f) { return /\.mjs$/.test(f); }).map(function (f) { return f.replace(/\.mjs$/, ''); }).sort(), names.LIB_MODULES.slice().sort(), 'the modules names-lib scans');
  });

  // ---- the document's structure ----
  var errorsOf = function (d) { return checkm.checkGraph(d).errors; };
  var said = function (list, re, m) { assert(list.some(function (e) { return re.test(e); }), (m || 'no error says ' + re) + ': ' + JSON.stringify(list)); };
  var tiny = function () { return digest([note('F', null), { title: 'Fr', kind: 'frame' }, note('A', 'Fr'), note('B')], [{ from: 'A', to: 'B' }]); };

  await test('check: a good document has no errors; the structure it refuses names keys', async function () {
    eq(errorsOf(tiny()), [], 'a good one');
    eq(errorsOf(fixture('acme')), []); eq(errorsOf(fixture('tree')), []); eq(errorsOf(fixture('typed')), []);
    var d = tiny(); d.nodes.push({ key: 'A', kind: 'sticky-note' });
    said(errorsOf(d), /two nodes have the key "A"/, 'a key twice');
    d = tiny(); d.nodes.push({ key: '', kind: 'sticky-note' }); d.nodes.push({ kind: 'sticky-note' });
    eq(errorsOf(d).filter(function (e) { return /has no key/.test(e); }).length, 2, 'an empty key and none');
    d = tiny(); d.nodes[2].in = 'Nowhere';
    said(errorsOf(d), /"A" is in Nowhere, which is not a node's key/);
    d = tiny(); d.nodes[2].in = 'B';
    said(errorsOf(d), /"A" is in "B", and the kind sticky-note holds no shapes or board/, 'in a note');
    d = tiny(); d.nodes[1].in = 'Fr';
    said(errorsOf(d), /"Fr" is in itself/);
    d = tiny(); d.nodes[1].in = 'A'; d.nodes[2].kind = 'frame';
    said(errorsOf(d), /"in" runs in a circle: "Fr" is in "A" is in "Fr"/);
    d = tiny(); d.edges.push({ from: 'A', to: 'Ghost' });
    said(errorsOf(d), /edges\[1\] A -> Ghost: to "Ghost" is not a node's key/);
    d = tiny(); d.nodes[3].kind = 'arrow';
    said(errorsOf(d), /"B": a document can't draw the kind arrow: it joins two shapes/, 'a kind the app lists as not drawable, in the app\'s words');
    d = tiny(); d.nodes[3].kind = 'blob';
    said(errorsOf(d), /"B": the app has no kind blob \(canvas kinds lists /);
    d = tiny(); delete d.nodes[3].kind;
    said(errorsOf(d), /"B" has no kind/);
    d = tiny(); delete d.drawing;
    said(errorsOf(d), /drawing is the drawing's name/);
    d = tiny(); d.nodes[3].layout = { rank: 'high', pill: 1 }; d.edges[0].layout = { weight: 'heavy', direct: 'yes' }; d.layout = { mess: 3, ranks: 'sideways' };
    eq(errorsOf(d).length, 6, 'hints of the wrong type: ' + JSON.stringify(errorsOf(d)));
    d = tiny(); d.nodes[3].layout = { pill: true }; d.nodes.push({ key: 'Ref', kind: 'reference' }); d.nodes[4].layout = { pill: true };
    said(errorsOf(d), /"Ref" is layout.pill: true, and no pill can stand for the kind reference/, 'pill: true where no pill stands');
    d = tiny(); d.nodes.push({ key: 'root', kind: 'subboard' });
    said(errorsOf(d), /"root" names the drawing's own board/);
  });

  await test('check refuses nothing the app owns: titles may repeat, props are never read, an edge may repeat, an attribute may be anything', async function () {
    var d = digest([{ title: 'Same', key: 'a', kind: 'sticky-note', text: 'x' }, { title: 'Same', key: 'b', kind: 'sticky-note', text: 'y' }, { key: 'c', kind: 'frame' }, { key: 'd', kind: 'sticky-note', in: 'c', props: { nonsense: [1, { 2: 3 }], title: 42, size: 'a lot' } }],
      [{ from: 'a', to: 'b' }, { from: 'a', to: 'b' }, { from: 'a', to: 'b', props: { is: ['nothing'] } }, { from: 'c', to: 'd' }]);
    eq(errorsOf(d), [], 'nothing the app owns is refused here');
    var r = await planOf(d);
    eq(r.drawing.nodes.map(function (n) { return n.props; }), d.nodes.map(function (n) { return n.props; }), 'props pass through as they are');
    eq(r.drawing.edges.length, 4, 'three edges alike and one more, all listed');
    eq(r.model.nodes.size, 4, 'titles tell the tool nothing: the keys do');
  });

  // ---- the app's answer to measure ----
  await test('sizes: a node\'s size by key, a frame\'s title width and smallest, pills by (for, from); the edges the app refuses are left out with its words', async function () {
    var d = tiny(); d.edges.push({ from: 'B', to: 'A' });
    var m = model.buildModel(d), me = helpers.estimateMeasure(m, d);
    me.nodes.A.size = [411, 222]; me.nodes.Fr.titleWidth = 700; me.nodes.Fr.size = [150, 90];
    var sz = sizes.sizesFrom(m, me);
    eq(sz.shapes.A, { w: 411, h: 222, above: 30 }, 'size and above, by key');
    eq(sz.frames.Fr, { min: { w: 150, h: 90 }, titleWidth: 700 }, 'a frame\'s smallest and its title');
    assert(sz.pillWidth[sizes.pillKey('B', 'f:Fr')] > 0 && sz.pillWidth[sizes.pillKey('A', 'b:root')] > 0, 'pills by what they stand for and the container their start is in: ' + JSON.stringify(sz.pillWidth));
    eq(sz.constants.pillHeight, 40, 'constants read as before');
    var gone = me.nodes.B; delete me.nodes.B;
    var threw = ''; try { sizes.sizesFrom(m, me); } catch (e) { threw = e.message; } me.nodes.B = gone;
    assert(/no size for: B/.test(threw), threw);
    // a frame is never narrower than its title
    return planm.planGraph(d, function (mm) { return sizes.sizesFrom(mm, me); }, {}, elk).then(function (r) {
      var fr = r.plan.boards[0].shapes.find(function (s) { return s.key === 'Fr'; });
      assert(fr.w >= 700 && fr.h >= 90, 'the frame is as wide as its title and no smaller than the app says: ' + fr.w + ' x ' + fr.h);
      var n = r.drawing.nodes.find(function (x) { return x.key === 'Fr'; });
      eq(n.place.size, [fr.w, fr.h], 'and drawing.json says so');
    });
  });

  await test('an edge the app refuses is left out of drawing.json with a warning in its words naming both keys; the layout lays out without it', async function () {
    var d = tiny(); d.edges.push({ from: 'A', to: 'Fr' });
    var refused = [{ edge: 1, from: 'A', to: 'Fr', refused: { reason: 'nested', message: 'a shape and the frame that holds it share no arrow', hint: 'draw it to a shape beside it' } }];
    var me = measureOf(d, refused);
    var r = await planm.planGraph(d, function (m) { return sizes.sizesFrom(m, me); }, { refused: sizes.refusedEdges(me) }, elk);
    eq(r.drawing.edges.map(function (e) { return e.from + '>' + e.to; }), ['A>B'], 'left out');
    eq(r.report.warnings, ['edge "A" -> "Fr" left out: the app refuses it: a shape and the frame that holds it share no arrow (draw it to a shape beside it)']);
    eq(sizes.refusedEdges({ edges: [{ edge: 3, refused: { message: 'm' } }, { edge: 4 }] }).size, 1, 'only the refused');
    // without it said, the layout makes its own limits: an edge between boards to a kind no pill stands for, or at a shape that holds shapes
    var cross = digest([{ title: 'Sub', kind: 'subboard' }, note('In', 'Sub'), { title: 'Ref', kind: 'reference' }, { title: 'Fr', kind: 'frame' }, note('Out'), note('Top')], [{ from: 'In', to: 'Ref' }, { from: 'In', to: 'Fr' }, { from: 'In', to: 'Top' }]);
    var c = await planOf(cross);
    eq(c.drawing.edges.map(function (e) { return e.to; }), ['Top'], 'the others are left out');
    eq(c.report.warnings.length, 2); assert(/no pill can stand for the kind reference/.test(c.report.warnings[0]) && /holds shapes only as an arrow on one board/.test(c.report.warnings[1]), c.report.warnings.join('\n'));
  });

  // ---- drawing.json ----
  // the absolute place (from the board's origin) of every node of a drawing, from its place and its frame's
  var absoluteOf = function (drawing) {
    var by = {}, out = {};
    drawing.nodes.forEach(function (n) { by[n.key] = n; });
    var up = function (k) {
      if (out[k]) return out[k];
      var n = by[k], p = n.in && by[n.in] && by[n.in].kind === 'frame' ? up(n.in) : { x: 0, y: 0 };
      return (out[k] = { x: p.x + n.place.at[0], y: p.y + n.place.at[1], w: n.place.size[0], h: n.place.size[1] });
    };
    drawing.nodes.forEach(function (n) { up(n.key); });
    return out;
  };

  await test('drawing.json is the document as given with places: props, layout and edges pass through; a node in a frame is placed from the frame, any other from its board; sizes are the measured ones', async function () {
    var d = fixture('tree'), before = JSON.stringify(d);
    var r = await planOf(d);
    eq(JSON.stringify(d), before, 'the input is not changed');
    eq(r.drawing.drawing, d.drawing, 'the drawing\'s name');
    eq(r.drawing.nodes.map(function (n) { return n.key; }), d.nodes.map(function (n) { return n.key; }), 'every node, in the order given');
    r.drawing.nodes.forEach(function (n, i) {
      var raw = d.nodes[i];
      eq(JSON.stringify(n.props), JSON.stringify(raw.props), 'props of ' + n.key + ' as given');
      eq(n.in, raw.in, 'in'); eq(n.kind, raw.kind, 'kind');
      assert(n.place && n.place.at.length === 2 && n.place.size.length === 2 && n.place.size[0] > 0, 'a place for ' + n.key);
    });
    var me = measureOf(d);
    r.drawing.nodes.forEach(function (n) { if (n.kind !== 'frame') eq(n.place.size, me.nodes[n.key].size.map(Math.ceil), 'the measured size of ' + n.key); });
    // a node in a frame: from its frame's top-left, clear of its edge by the inset
    var abs = absoluteOf(r.drawing);
    r.drawing.nodes.forEach(function (n) {
      if (n.in && r.model.node(n.in).holds === 'shapes') { var f = abs[n.in], b = abs[n.key]; assert(b.x >= f.x + 40 && b.y >= f.y + 40 && b.x + b.w <= f.x + f.w - 40 && b.y + b.h <= f.y + f.h - 40, n.key + ' is inside ' + n.in); assert(n.place.at[0] >= 40 && n.place.at[1] >= 40, 'from the frame\'s top-left'); }
    });
    // what the plan has in its boards is what the document says, each from its container
    r.plan.boards.forEach(function (b) { b.shapes.forEach(function (s) { var n = r.drawing.nodes.find(function (x) { return x.key === s.key; }); eq(n.place.size, [s.w, s.h], 'size of ' + s.key); if (!s.in) eq(n.place.at, [s.x, s.y], 'a board\'s own shape is from the origin: ' + s.key); }); });
    // edges: as given, in order but for those that share a pill, which follow the pill's maker
    eq(r.drawing.edges.length, d.edges.length - r.model.dropped.size, 'every edge but those left out');
    r.drawing.edges.forEach(function (e) { if (!pillOf(e)) eq(Object.keys(e).sort(), Object.keys(d.edges.find(function (x) { return x.from === e.from && x.to === e.to; })).sort(), 'an arrow is as given'); });
    checkPlan(r.plan);
  });

  await test('an edge through a pill: the maker\'s place and frame, the sharers\' share, the maker first; a pill is beside its start; across boards the pill is for the far end', async function () {
    var d = fixture('tree');
    var r = await planOf(d), abs = absoluteOf(r.drawing);
    var pilled = r.drawing.edges.filter(pillOf);
    assert(pilled.length >= 10, 'the tree has pills: ' + pilled.length);
    pilled.forEach(function (e) {
      var p = pillOf(e), start = r.model.node(e.from);
      if (p.share != null) {
        var host = pilled.find(function (x) { return x.from === p.share && x.to === e.to && pillOf(x).at; });
        assert(host, 'a sharer\'s host makes the pill for ' + e.to + ': ' + JSON.stringify(e));
        assert(pilled.indexOf(host) < pilled.indexOf(e), 'the maker before its sharers');
        eq(r.model.node(p.share).container, start.container, 'the same container');
      } else {
        eq(p.in || null, start.container[0] === 'f' ? start.container.slice(2) : null, 'the pill is in the frame of its start');
        var near = abs[e.from], px = (p.in ? abs[p.in].x : 0) + p.at[0], py = (p.in ? abs[p.in].y : 0) + p.at[1];
        assert(Math.abs(px - (near.x + near.w)) < 700 && Math.abs(py - near.y) < 700, 'the pill of ' + e.from + ' > ' + e.to + ' is beside its start: ' + [px, py] + ' vs ' + JSON.stringify(near));
      }
    });
    // an edge between boards is a pill for its far end, through which the far end is reached
    var crossing = d.edges.filter(function (e) { return r.model.node(e.from).board !== r.model.node(e.to).board && !r.model.dropped.has(d.edges.indexOf(e)); });
    assert(crossing.length >= 1, 'the tree has edges between boards');
    crossing.forEach(function (e) { assert(pillOf(r.drawing.edges.find(function (x) { return x.from === e.from && x.to === e.to; })), e.from + ' > ' + e.to + ' goes through a pill'); });
    // two edges of one pair: the first makes the pill, the second shares it (the start is the host)
    var two = digest([note('Hub'), note('U1'), note('U2'), note('U3'), note('U4'), note('U5'), note('U6')], ['U1', 'U2', 'U3', 'U4', 'U5', 'U6'].map(function (u) { return { from: u, to: 'Hub' }; }).concat([{ from: 'U1', to: 'Hub', props: { text: 'again' } }]));
    var t = await planOf(two, { promote: true, popular: 1 });
    var u1 = t.drawing.edges.filter(function (e) { return e.from === 'U1'; });
    eq(u1.length, 2);
    if (pillOf(u1[0])) { assert(pillOf(u1[0]).at || pillOf(u1[0]).share != null, 'a pill'); eq(pillOf(u1[1]) && pillOf(u1[1]).share != null, true, 'the second edge of a pair goes into the first one\'s pill'); }
    // a loop is drawn straight
    var loop = await planOf(digest([note('A'), note('B')], [{ from: 'A', to: 'A' }, { from: 'A', to: 'B' }]));
    assert(loop.drawing.edges.length === 2 && !pillOf(loop.drawing.edges[0]), 'a loop stays in the document, with no pill');
  });

  await test('drawing.json is the same for the same input and for the input in another order, and keeps what a person can read: places are numbers, pills at integers', async function () {
    var d = fixture('acme'), a = await planOf(d), b = await planOf(JSON.parse(JSON.stringify(d)));
    eq(JSON.stringify(a.drawing), JSON.stringify(b.drawing), 'byte for byte');
    var rev = JSON.parse(JSON.stringify(d)); rev.nodes.reverse(); rev.edges.reverse();
    var c = await planOf(rev), place = function (x) { return JSON.stringify(x.drawing.nodes.map(function (n) { return [n.key, n.place]; }).sort()); };
    eq(place(c), place(a), 'the same places with nodes and edges reversed');
    a.drawing.nodes.forEach(function (n) { n.place.at.concat(n.place.size).forEach(function (v) { assert(typeof v === 'number' && isFinite(v), 'a number'); }); });
  });

  // a hash of each fixture's drawing.json, as the tool wrote it when this was recorded: a change that moves one changes every drawing of such a document.
  // Recorded after the render layer was rewritten (keys, `canvas apply`'s document): the layout is the one it was, with the app's own measure for sizes.
  var HASHES = { acme: '7d3435946541b66a', tree: '97bd2262acc4bf10', flat60: 'b2b139a5f51ccf7f', spine: '355749a0468d41be', typed: '445edc977fe8736d', frames: 'b3c3d462c4356684' };
  var hashOf = function (text) {
    var a = 0x811c9dc5, b = 0x01000193;
    for (var i = 0; i < text.length; i++) { var c = text.charCodeAt(i); a = Math.imul(a ^ c, 0x01000193) >>> 0; b = Math.imul(b ^ c, 0x85ebca6b) >>> 0; }
    return a.toString(16).padStart(8, '0') + b.toString(16).padStart(8, '0');
  };
  var HASH_NAMES = ['acme', 'tree', 'flat60', 'spine', 'typed', 'frames'];
  for (var hi = 0; hi < HASH_NAMES.length; hi++) await (function (name) {
    return test('the drawing of the ' + name + ' fixture is byte for byte what it was when recorded', async function () {
      var r = await planOf(fixture(name));
      var got = hashOf(JSON.stringify(r.drawing, null, 1));
      if (RECORD) { io.print('HASH ' + name + ' ' + got); return; }
      eq(got, HASHES[name], name + ': the drawing moved; if that is meant, record it again (node test/run.js record)');
    });
  })(HASH_NAMES[hi]);

  // ---- drawing again in place ----
  // what `canvas query ':drawn-by("NAME")' --brief` answers for a drawing the app holds exactly as drawn: a row for each node with its box in world
  // units, its board, `inside` (the names of the subboards and frames it is inside, outermost first) and `in` (the key of the drawing's shape that holds it)
  var rowsOf = function (drawing, edit) {
    var abs = absoluteOf(drawing), by = {};
    drawing.nodes.forEach(function (n) { by[n.key] = n; });
    var rows = drawing.nodes.map(function (n) {
      var inside = [], p = n.in;
      while (p) { inside.unshift(p); p = by[p].in; }
      var b = abs[n.key], row = { id: 'id:' + n.key, key: n.key, at: [[b.x, b.y], [b.w, b.h]], board: 'board:1', inside: inside };
      if (n.in) row.in = n.in;
      return row;
    });
    if (edit) edit(rows);
    return { rows: rows, absent: [] };
  };
  var placesOfNodes = function (r) { var o = {}; r.drawing.nodes.forEach(function (n) { o[n.key] = JSON.stringify(n.place); }); return o; };

  await test('drawing again in place: a drawing as the file holds it comes out as it is, a moved shape stays where it was put, and a larger frame stays larger', async function () {
    var d = fixture('acme');
    var first = await planOf(d), rows = rowsOf(first.drawing);
    var again = await planOf(d, { current: rows });
    eq(placesOfNodes(again), placesOfNodes(first), 'every shape where it is');
    eq(JSON.stringify(again.drawing.edges), JSON.stringify(first.drawing.edges), 'and its pills');
    // a person moved a note inside its frame, and made a frame larger: the layout starts from there
    var note1 = first.drawing.nodes.find(function (n) { return n.in && n.kind !== 'frame'; }), frame1 = first.drawing.nodes.find(function (n) { return n.kind === 'frame' && n.key !== note1.in; });
    var moved = rowsOf(first.drawing, function (rs) {
      var rn = rs.find(function (x) { return x.key === note1.key; }); rn.at[0][1] += 11;
      var rf = rs.find(function (x) { return x.key === frame1.key; }); rf.at[1][0] += 120; rf.at[1][1] += 60;
    });
    var kept = await planOf(d, { current: moved });
    var at = function (r, k) { return r.drawing.nodes.find(function (n) { return n.key === k; }).place; };
    eq(at(kept, note1.key).at, [note1.place.at[0], note1.place.at[1] + 11], 'the note is where it was put');
    eq(at(kept, frame1.key).size, [at(first, frame1.key).size[0] + 120, at(first, frame1.key).size[1] + 60], 'the frame keeps its larger size');
    eq(at(kept, frame1.key).at, at(first, frame1.key).at, 'and its place');
    assert(kept.report.boards.root.kept.indexOf('b:root') >= 0 && kept.report.boards.root.kept.length >= 3, 'the report says which containers kept their members: ' + JSON.stringify(kept.report.boards.root.kept));
    checkPlan(kept.plan);
  });

  await test('drawing again in place: the pills and arrows the drawing drew, rows of it too (`pill …`, `edge …`), hold no place in a container', async function () {
    var d = fixture('acme');
    var first = await planOf(d);
    var frame = first.drawing.nodes.find(function (n) { return n.kind === 'frame'; });
    var rows = rowsOf(first.drawing, function (rs) {
      var f = rs.find(function (x) { return x.key === frame.key; });
      rs.push({ id: 'id:pill', key: 'pill a -> b', at: [[f.at[0][0] + 1, f.at[0][1] + 1], [100, 40]], board: 'board:1', in: frame.key, inside: f.inside.concat([frame.key]) });
      rs.push({ id: 'id:edge', key: 'edge a -> b', board: 'board:1', in: frame.key, inside: f.inside.concat([frame.key]) });
    });
    var again = await planOf(d, { current: rows });
    eq(placesOfNodes(again), placesOfNodes(first), 'every shape where it is');
    assert(again.report.boards.root.kept.indexOf('f:' + frame.key) >= 0, 'the frame keeps its members: ' + JSON.stringify(again.report.boards.root.kept));
  });

  await test('drawn again in place as rows, ranked frames drawn as columns are rows: the ranks say which way, and what each band holds is kept', async function () {
    var d = rankedDigest();
    var columns = await planOf(d, { promote: false, ranks: 'columns' });
    var rows = await planOf(d, { promote: false, ranks: 'rows', current: rowsOf(columns.drawing) });
    assert(isRows(shapesOf(rows)), 'rows: ' + JSON.stringify(shapesOf(rows).Top) + ' ' + JSON.stringify(shapesOf(rows).Mid));
    var inside = function (r) { var o = {}; r.drawing.nodes.filter(function (n) { return n.in === 'Top'; }).forEach(function (n) { o[n.key] = JSON.stringify(n.place.at); }); return o; };
    eq(inside(rows), inside(columns), 'a band keeps where its notes are');
    assert(rows.report.boards.root.kept.indexOf('f:Top') >= 0 && rows.report.boards.root.kept.indexOf('b:root') < 0, 'the band kept, the board laid out by its ranks: ' + JSON.stringify(rows.report.boards.root.kept));
  });

  await test('drawing again in place: a container whose members changed is laid out afresh, one whose members did not keeps them, and a rows answer with absent shapes is read', async function () {
    var d = fixture('acme'), first = await planOf(d), rows = rowsOf(first.drawing);
    var frames = first.drawing.nodes.filter(function (n) { return n.kind === 'frame'; }).map(function (n) { return n.key; });
    var target = frames[0], other = frames[1];
    var members = function (key) { return first.drawing.nodes.filter(function (n) { return n.in === key; }).map(function (n) { return n.key; }); };
    // a note added to a frame: the frame lays out afresh (a member it has not held), the others keep their shapes where they are
    var grown = JSON.parse(JSON.stringify(d)); grown.nodes.push(nodeOf(note('Newcomer', target, 'new')));
    var a = await planOf(grown, { current: rows });
    members(other).forEach(function (k) { eq(a.drawing.nodes.find(function (n) { return n.key === k; }).place, first.drawing.nodes.find(function (n) { return n.key === k; }).place, k + ' of an untouched frame stays'); });
    assert(a.drawing.nodes.find(function (n) { return n.key === 'Newcomer'; }), 'the newcomer is placed');
    checkPlan(a.plan);
    var abs = absoluteOf(a.drawing), mine = members(target).concat(['Newcomer']);
    mine.forEach(function (k, i) { mine.slice(i + 1).forEach(function (j) { var p = abs[k], q = abs[j]; assert(!(p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h), k + ' and ' + j + ' overlap'); }); });
    // a note taken out of the document: its frame lays out afresh too (the file holds one the document no longer has)
    var shrunk = JSON.parse(JSON.stringify(d)), gone = members(other)[0];
    shrunk.nodes = shrunk.nodes.filter(function (n) { return n.key !== gone; }); shrunk.edges = shrunk.edges.filter(function (e) { return e.from !== gone && e.to !== gone; });
    var b = await planOf(shrunk, { current: rows });
    members(target).forEach(function (k) { eq(b.drawing.nodes.find(function (n) { return n.key === k; }).place, first.drawing.nodes.find(function (n) { return n.key === k; }).place, k + ' of an untouched frame stays'); });
    // a note moved by hand to another frame: both frames lay out afresh
    var carried = rowsOf(first.drawing, function (rs) { var rn = rs.find(function (x) { return x.key === members(target)[0]; }); rn.in = other; rn.inside = [other]; });
    var c = await planOf(d, { current: carried });
    var kept = c.report.boards.root.kept;
    assert(kept.indexOf('f:' + target) < 0 && kept.indexOf('f:' + other) < 0 && kept.indexOf('b:root') >= 0, 'the two frames the note left and entered are laid out afresh, the board keeps: ' + JSON.stringify(kept));
    checkPlan(c.plan);
    // an answer that is a bare list of rows is read as well, and rows without a place are ignored
    var bare = await planOf(d, { current: rows.rows.concat([{ id: 'x', key: 'gone', inside: [] }]) });
    eq(placesOfNodes(bare), placesOfNodes(first), 'a list of rows');
  });

  await test('drawing again in place: subboards and nested frames keep their members too; the file holding shapes the document lacks is laid out afresh above them', async function () {
    var d = fixture('tree'), first = await planOf(d), rows = rowsOf(first.drawing);
    var again = await planOf(d, { current: rows });
    eq(placesOfNodes(again), placesOfNodes(first), 'a tree comes out as it is');
    var inside = first.drawing.nodes.find(function (n) { return n.in && first.model.node(n.in).holds === 'board'; });
    assert(inside, 'the tree has a shape on a subboard');
    var moved = rowsOf(first.drawing, function (rs) { rs.forEach(function (rn) { if (rn.key === inside.key || rn.inside.indexOf(inside.key) >= 0) rn.at[0][0] += 9; }); });   // a frame moved by hand takes what it holds with it
    var m = await planOf(d, { current: moved });
    eq(m.drawing.nodes.find(function (n) { return n.key === inside.key; }).place.at[0], inside.place.at[0] + 9, 'a shape on a subboard starts from where it is');
    checkPlan(m.plan);
  });

  await test('a pinned node has a pill drawn for it, and none with promotion off', async function () {
    var d = fixture('acme');
    d.nodes.find(function (n) { return n.key === 'Platform team'; }).layout = { pill: true };
    var off = await planOf(d, { promote: false });
    assert(off.drawing.edges.every(function (e) { return !(e.place && e.place.pill); }), 'no pill is drawn with promotion off');
    var on = await planOf(d);
    assert(on.drawing.edges.some(function (e) { return e.to === 'Platform team' && e.place && e.place.pill; }), 'a pill is drawn for the pinned node');
  });

  await test('props are the app\'s: a hub whose props say private: true is laid out as any other hub, and the document keeps what it says', async function () {
    // whether a pill may stand for a shape is the app's to say (canvas apply refuses one for a private node, by key); the layout reads no props
    var fx = hubFixture(4, 5), marked = hubFixture(4, 5);
    marked.nodes.forEach(function (n) { if (n.title === 'Hub') n.props = Object.assign({}, n.props, { private: true }); });
    var plain = await planOf(digest(fx.nodes, fx.edges), { marginPills: 100000 });
    var r = await planOf(digest(marked.nodes, marked.edges), { marginPills: 100000 });
    eq(JSON.stringify(r.plan.boards), JSON.stringify(plain.plan.boards), 'the same boards, pills and moves');
    eq(r.drawing.nodes.find(function (n) { return n.key === 'Hub'; }).props.private, true, 'its props passed through');
  });

  // ---- the commands ----
  var memory = function (files) {
    var out = { files: files || {}, printed: [], warned: [] };
    out.io = {
      readText: function (p) { if (p in out.files) return out.files[p]; return io.readText(p); },
      writeText: function (p, t) { out.files[p] = t; },
      mkdirp: function () {}, print: function (t) { out.printed.push(t); }, warn: function (t) { out.warned.push(t); }, now: function () { return Date.now(); }, engine: 'test',
    };
    return out;
  };
  var KINDS_PATH = base + '/test/fixtures/kinds.json';

  await test('the commands: check, plan (writes drawing.json and report.json, prints a summary an agent can relay), applied, refusals, extract; unknown options are refused', async function () {
    var d = fixture('acme'), me = measureOf(d);
    var mem = memory({ '/g.json': JSON.stringify(d), '/m.json': JSON.stringify(me) });
    await clim.run(['check', '/g.json', '--kinds', KINDS_PATH], mem.io);
    eq(JSON.parse(mem.printed.pop()), { errors: [], warnings: [] });
    await clim.run(['plan', '/g.json', '/m.json', '/out', '--kinds', KINDS_PATH, '--view', '1440x900'], mem.io);
    var summary = mem.printed.pop();
    assert(/^plan: 1 board\(s\), 29 shapes, \d+ pills/.test(summary) && /laid out for a view of 1440 x 900/.test(summary) && !/public/.test(summary), summary);
    var drawing = JSON.parse(mem.files['/out/drawing.json']), report = JSON.parse(mem.files['/out/report.json']);
    eq(drawing.nodes.length, 29); eq(drawing.drawing, 'acme'); assert(report.totals && report.promotions && report.view.w === 1440 && report.timings.engine === 'test', 'report.json');
    eq(Object.keys(mem.files).sort(), ['/g.json', '/m.json', '/out/drawing.json', '/out/report.json'], 'two files written, and nothing else');
    var threw = ''; try { await clim.run(['plan', '/g.json', '/m.json', '/out', '--kinds', KINDS_PATH, '--records', 'x'], mem.io); } catch (e) { threw = e.message; }
    assert(/unknown option --records/.test(threw), threw);
    threw = ''; try { await clim.run(['plan', '/g.json', '/m.json', '/out', '--kinds', KINDS_PATH, '--view', 'wide'], mem.io); } catch (e) { threw = e.message; }
    assert(/--view takes a width and a height/.test(threw), threw);
    // a measurement with a size missing is said, by key
    var broken = JSON.parse(JSON.stringify(me)); delete broken.nodes.CTO;
    mem.files['/b.json'] = JSON.stringify(broken); threw = '';
    try { await clim.run(['plan', '/g.json', '/b.json', '/out', '--kinds', KINDS_PATH], mem.io); } catch (e) { threw = e.message; }
    assert(/no size for: CTO/.test(threw), threw);
    // a document with errors is said before it is laid out
    mem.files['/bad.json'] = JSON.stringify(Object.assign({}, d, { nodes: d.nodes.concat([{ key: 'CTO', kind: 'frame' }]) }));
    await clim.run(['check', '/bad.json', '--kinds', KINDS_PATH], mem.io);
    var chk = JSON.parse(mem.printed.pop());
    eq(chk.errors.length, 1); await clim.run(['check-text', '/chk.json'].map(function (x, i) { return i === 1 ? '/chk.json' : x; }), Object.assign(mem.io, { readText: function (p) { return p === '/chk.json' ? JSON.stringify({ errors: chk.errors, warnings: ['w'] }) : mem.files[p]; } }));
    eq(mem.printed.pop(), 'error: ' + chk.errors[0] + '\nwarning: w');
    // the app's answers, in a few words
    mem.files['/ref.json'] = JSON.stringify({ error: { reason: 'refused', message: 'no', hint: 'h', refusals: [{ key: 'file:a', reason: 'x', message: 'a title is needed', hint: 'give it one' }, { edge: 2, reason: 'y', message: 'no channel' }] } });
    mem.io.readText = function (p) { return p in mem.files ? mem.files[p] : io.readText(p); };
    await clim.run(['refusals', '/ref.json'], mem.io);
    eq(mem.printed.pop(), 'file:a: a title is needed (give it one)\nedge 2: no channel');
    // given the drawing, an edge is named by its ends too: its place in drawing.json is not its place in the graph document
    mem.files['/dr.json'] = JSON.stringify({ edges: [{ from: 'a', to: 'b' }, { from: 'c', to: 'd' }, { from: 'e', to: 'f' }] });
    await clim.run(['refusals', '/ref.json', '/dr.json'], mem.io);
    eq(mem.printed.pop(), 'file:a: a title is needed (give it one)\nedge from "e" to "f": no channel');
    mem.files['/ap.json'] = JSON.stringify({ drawing: 'x', dryRun: false, nodes: [{ key: 'a', did: 'created' }, { key: 'b', did: 'updated', overrode: ['moved'] }, { key: 'c', did: 'updated' }], edges: [{ edge: 0, did: 'created' }], deleted: [{ key: 'z' }], warnings: [{ key: 'b', message: 'a note is long' }] });
    await clim.run(['applied', '/ap.json'], mem.io);
    eq(mem.printed.pop(), 'applied x: shapes 1 created, 2 updated; edges 1 created; 1 deleted\noverrode a person\'s change on 1 shape(s): b (moved)\nwarning: b: a note is long');
    mem.files['/ap2.json'] = JSON.stringify({ drawing: 'x', dryRun: true, nodes: [], edges: [], warnings: [{ edge: 1, message: 'odd' }] });
    await clim.run(['applied', '/ap2.json', '/dr.json'], mem.io);
    eq(mem.printed.pop(), 'dry run x: shapes none; edges none; 0 deleted\nwarning: edge from "c" to "d": odd');
    await clim.run(['extract', 'kinds', KINDS_PATH], mem.io);
    eq(JSON.parse(mem.printed.pop()).map(function (k) { return k.kind; }), ['arrow', 'emoji-sticker', 'frame', 'reference', 'sticky-note', 'subboard']);
    threw = ''; try { await clim.run(['nonsense'], mem.io); } catch (e) { threw = e.message; }
    assert(/THE MESS DIAL/.test(threw), 'the usage');
  });

  await test('--current is read from a file: the plan starts from where the drawing\'s shapes are', async function () {
    var d = fixture('acme'), first = await planOf(d);
    var mem = memory({ '/g.json': JSON.stringify(d), '/m.json': JSON.stringify(measureOf(d)), '/c.json': JSON.stringify(rowsOf(first.drawing, function (rs) { rs[5].at[0][0] += 13; rs[5].at[0][1] += 5; })) });
    await clim.run(['plan', '/g.json', '/m.json', '/o', '--kinds', KINDS_PATH, '--current', '/c.json'], mem.io);
    var drawn = JSON.parse(mem.files['/o/drawing.json']);
    assert(JSON.stringify(drawn.nodes.map(function (n) { return n.place; })) !== JSON.stringify(first.drawing.nodes.map(function (n) { return n.place; })), 'a hand-moved shape moves the layout');
  });

  if (part) io.print('part ' + part.k + ' of ' + part.n + ': ' + (results.length + failed) + ' of ' + defined + ' tests');
  io.print(results.length + ' passed, ' + failed + ' failed');
  if (failed) throw new Error('tests failed');
}).catch(function (e) { io.print('ERROR ' + (e && e.stack ? e.stack : e)); setTimeout(function () { throw e; }, 0); });
