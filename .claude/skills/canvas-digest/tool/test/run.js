// Unit tests:  jsc test/run.js     or     node test/run.js
// Classic script (import() finds ../lib from here in both engines). No app, no sockets, no pasteboard, no network.
var isNode = typeof process !== 'undefined' && process.versions && process.versions.node;
var RUN_ARGS = typeof arguments !== 'undefined' ? Array.prototype.slice.call(arguments) : [];   // jsc's, after `--`
var fsr = isNode ? require('fs') : null;
var io = {
  readText: function (p) { return isNode ? fsr.readFileSync(p, 'utf8') : readFile(p); },
  print: function (s) { isNode ? console.log(s) : print(s); },
};
Promise.all([import('../lib/model.mjs'), import('../lib/sizes.mjs'), import('../lib/elk.mjs'), import('../lib/plan.mjs'), import('../lib/cli.mjs'), import('../lib/util.mjs'), import('../lib/layout.mjs'), import('../lib/check.mjs'), import('./helpers.mjs'), import('../lib/health.mjs'), import('../lib/geom.mjs'), import('../lib/planarity.mjs'), import('../lib/stars.mjs'), import('../lib/cut.mjs'), import('../lib/cluster.mjs')]).then(async function (mods) {
  var sizes = mods[1], elkm = mods[2], clim = mods[4], util = mods[5], layoutm = mods[6], helpers = mods[8], healthm = mods[9], geomm = mods[10], planarm = mods[11], starsm = mods[12], cutm = mods[13], clusterm = mods[14];
  var base = util.TOOL_DIR;
  // The app's kinds as the tool reads them (`canvas kinds`): the tool names no kind, and the driver gives them to every command that reads a document.
  // This copy is what the tests read them by (CompositionTests' DigestTests hold it to the app's answer).
  var KINDS = JSON.parse(io.readText(base + '/test/fixtures/kinds.json'));
  var model = Object.assign({}, mods[0], { buildModel: function (d, kinds, opts) { return mods[0].buildModel(d, kinds === undefined ? KINDS : kinds, opts); } });
  var checkm = Object.assign({}, mods[7], { checkGraph: function (d, opts) { return mods[7].checkGraph(d, Object.assign({ kinds: KINDS }, opts || {})); } });
  var planm = Object.assign({}, mods[3], { planGraph: function (d, sz, opts, e) { return mods[3].planGraph(d, sz, Object.assign({ kinds: KINDS }, opts || {}), e); } });
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

  await test('no edges: the notes are packed, nothing cut, nothing overlaps', async function () {
    var nodes = [{ title: 'F', kind: 'frame' }];
    for (var i = 0; i < 12; i++) nodes.push(note('Note ' + (i < 10 ? '0' : '') + i, i < 8 ? 'F' : null, 'Text ' + i));
    var r = await planOf(digest(nodes, []));
    var rep = r.report.boards.root;
    assert(rep.algorithms.every(function (a) { return a.algorithm === 'rectpacking'; }), 'algorithms ' + JSON.stringify(rep.algorithms));
    eq([rep.end.arrows, rep.end.pills, rep.cut, rep.cutFurther, rep.stop], [0, 0, 0, 0, 'clean'], 'arrows, pills, cuts and where it stopped');
    var size = rep.health.size;
    assert(Math.max(size[0] / size[1], size[1] / size[0]) <= 3, 'the board\'s shape: ' + size);
    checkPlan(r.plan);
  });

  // ---- planarity, stars and the cut ----
  var complete = function (n) { var e = []; for (var i = 0; i < n; i++) for (var j = i + 1; j < n; j++) e.push([i, j]); return e; };
  await test('planarity: K4, the octahedron, the icosahedron, a wheel and a triangulated grid are planar; K5, K3,3 and the Petersen graph, and either subdivided, are not; a loop or an edge given twice changes nothing', async function () {
    var P = planarm.isPlanar;
    eq(P(4, complete(4)), true, 'K4');
    eq(P(5, complete(5)), false, 'K5');
    eq(P(5, complete(5).slice(1)), true, 'K5 less an edge');
    var k33 = []; for (var a = 0; a < 3; a++) for (var b = 3; b < 6; b++) k33.push([a, b]);
    eq(P(6, k33), false, 'K3,3');
    eq(P(6, k33.slice(1)), true, 'K3,3 less an edge');
    eq(P(7, k33.slice(1).concat([[0, 6], [6, 3]])), false, 'K3,3 with an edge subdivided');
    var k5s = []; complete(5).forEach(function (e, i) { k5s.push([e[0], 5 + i], [5 + i, e[1]]); });
    eq(P(15, k5s), false, 'K5 with every edge subdivided (20 edges, under Euler\'s 39)');
    var petersen = [[0, 1], [1, 2], [2, 3], [3, 4], [4, 0], [0, 5], [1, 6], [2, 7], [3, 8], [4, 9], [5, 7], [7, 9], [9, 6], [6, 8], [8, 5]];
    eq(P(10, petersen), false, 'the Petersen graph');
    var octahedron = complete(6).filter(function (e) { return !(e[0] % 2 === 0 && e[1] === e[0] + 1); });
    eq([octahedron.length, P(6, octahedron)], [12, true], 'the octahedron: 3n - 6 edges, planar');
    var ico = [];
    for (var i = 0; i < 5; i++) { var u = 1 + i, u2 = 1 + (i + 1) % 5, l = 6 + i, l2 = 6 + (i + 1) % 5; ico.push([0, u], [u, u2], [u, l], [u, l2], [l, l2], [l, 11]); }
    eq([ico.length, P(12, ico)], [30, true], 'the icosahedron: 3n - 6 edges, planar');
    var wheel = []; for (var w = 1; w <= 8; w++) wheel.push([0, w], [w, w % 8 + 1]);
    eq(P(9, wheel), true, 'a wheel');
    var grid = [], at = function (r, c) { return r * 5 + c; };
    for (var r = 0; r < 5; r++) for (var c = 0; c < 5; c++) { if (c < 4) grid.push([at(r, c), at(r, c + 1)]); if (r < 4) grid.push([at(r, c), at(r + 1, c)]); if (r < 4 && c < 4) grid.push([at(r, c), at(r + 1, c + 1)]); }
    eq(P(25, grid), true, 'a triangulated grid');
    eq(P(25, grid.concat([[at(0, 0), at(4, 4)], [at(0, 4), at(4, 0)]])), false, 'and with two chords across it that must cross');
    eq(P(4, complete(4).concat(complete(4), [[0, 0], [2, 2]])), true, 'K4 with every edge twice and two loops');
    eq(P(9, complete(4).concat(complete(5).map(function (e) { return [e[0] + 4, e[1] + 4]; }))), false, 'K4 beside K5: one part that is not');
    eq(P(9, complete(4).concat(complete(5).slice(1).map(function (e) { return [e[0] + 4, e[1] + 4]; }))), true, 'K4 beside K5 less an edge');
  });

  await test('the planar cut: what it leaves out of K6 is three edges or more, never the first, and what it keeps is planar and takes none of them back; edges it may not cut are kept', async function () {
    var k6 = complete(6), cut = planarm.planarCut(6, [], k6);
    assert(cut.length >= 3, 'K6 has 15 edges, and a planar graph of 6 vertices 12 at most: ' + cut);
    assert(cut.indexOf(0) < 0, 'the most wanted is kept');
    var kept = k6.filter(function (e, i) { return cut.indexOf(i) < 0; });
    eq(planarm.isPlanar(6, kept), true, 'what is kept is planar');
    cut.forEach(function (i) { eq(planarm.isPlanar(6, kept.concat([k6[i]])), false, 'taking ' + k6[i] + ' back makes it not planar'); });
    eq(planarm.planarCut(5, complete(4), [[0, 4], [1, 4], [2, 4], [3, 4]]), [3], 'K4 kept: of the fifth vertex\'s four, the least wanted is cut');
    eq(planarm.planarCut(4, [], complete(4)), [], 'a planar graph loses nothing');
  });

  await test('the planar drawing: a cycle, a wheel, a triangulated grid, a tree, two parts apart and two triangles at one vertex are drawn straight with no two edges crossing and every vertex apart; K5 and K3,3 have no embedding and no drawing', async function () {
    var cycle = []; for (var i = 0; i < 7; i++) cycle.push([i, (i + 1) % 7]);
    var wheel = []; for (var w = 1; w <= 8; w++) wheel.push([0, w], [w, w % 8 + 1]);
    var grid = [], at = function (r, c) { return r * 5 + c; };
    for (var r = 0; r < 5; r++) for (var c = 0; c < 5; c++) { if (c < 4) grid.push([at(r, c), at(r, c + 1)]); if (r < 4) grid.push([at(r, c), at(r + 1, c)]); if (r < 4 && c < 4) grid.push([at(r, c), at(r + 1, c + 1)]); }
    var tree = [[0, 1], [0, 2], [1, 3], [1, 4], [2, 5], [2, 6], [6, 7]];
    var parts = complete(4).concat([[4, 5], [5, 6], [6, 7], [7, 8], [8, 4]]);
    var bowtie = [[0, 1], [1, 2], [2, 0], [2, 3], [3, 4], [4, 2]];
    [['a cycle', 7, cycle], ['a wheel', 9, wheel], ['a triangulated grid', 25, grid], ['a tree', 8, tree], ['two parts apart', 9, parts], ['two triangles at one vertex', 5, bowtie]].forEach(function (g) {
      var X = planarm.planarDrawing(g[1], g[2]);
      assert(X && X.length === g[1], g[0] + ' is drawn');
      eq(planarm.countCrossings(X, g[2]), 0, g[0] + ': no two edges cross');
      for (var a = 0; a < g[1]; a++) for (var b = a + 1; b < g[1]; b++) assert(Math.abs(X[a][0] - X[b][0]) + Math.abs(X[a][1] - X[b][1]) > 1e-6, g[0] + ': ' + a + ' and ' + b + ' are apart');
      eq(JSON.stringify(planarm.planarDrawing(g[1], g[2])), JSON.stringify(X), g[0] + ': the same twice');
    });
    var k33 = []; for (var a = 0; a < 3; a++) for (var b = 3; b < 6; b++) k33.push([a, b]);
    eq([planarm.planarEmbedding(5, complete(5)), planarm.planarDrawing(5, complete(5))], [null, null], 'K5');
    eq([planarm.planarEmbedding(6, k33), planarm.planarDrawing(6, k33)], [null, null], 'K3,3');
  });

  await test('a note\'s pills in strips: in every arrangement but a column, each line from the note to a pill passes no other of its pills within the margin, a row or a column of a strip holds 8 at most, and no pill is on the note or on another; a side alone is offered wherever its pills fit there', async function () {
    var stripsm = await import('../lib/strips.mjs');
    var K = sizes.DEFAULT_CONSTANTS, noteBox = { w: 300, h: 200, above: 30 };
    var pillsOf = function (n) { var ps = []; for (var i = 0; i < n; i++) ps.push({ w: 80 + (i * 37) % 200 }); return ps; };
    var overlap = function (p, q) { return p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h; };
    [1, 5, 8, 9, 17, 40, 62].forEach(function (n) {
      var alts = stripsm.stripAlts(noteBox, pillsOf(n), K).filter(function (a) { return a && a.side && !/^column/.test(a.side); });
      assert(alts.length > 0, n + ' pills: some strips hold them');
      alts.forEach(function (a) {
        var N = { x: a.nx, y: a.ny, w: a.nw, h: a.nh }, name = n + ' pills, ' + a.side;
        eq(a.pills.length, n, name + ': every pill');
        a.pills.forEach(function (p, i) {
          var s = geomm.arrowBetween(N, p);
          a.pills.forEach(function (q, j) { if (j !== i) assert(!geomm.segHitsBox(s, q, -8), name + ': the line to pill ' + i + ' passes pill ' + j); });
          assert(!overlap(p, N), name + ': pill ' + i + ' is on the note');
          a.pills.forEach(function (q, j) { if (j > i) assert(!overlap(p, q), name + ': pills ' + i + ' and ' + j + ' overlap'); });
        });
        eq(a.own, 0, name + ': it counts no line over its own pills');
        (a.strips || []).forEach(function (b) {
          var inside = a.pills.filter(function (p) { var cx = p.x + p.w / 2, cy = p.y + p.h / 2; return cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h; });
          var lines = {}; inside.forEach(function (p) { var k = b.w >= b.h ? Math.round(p.y) : Math.round(p.x); lines[k] = (lines[k] || 0) + 1; });
          Object.keys(lines).forEach(function (k) { assert(lines[k] <= 8, name + ': ' + lines[k] + ' pills in one ' + (b.w >= b.h ? 'row' : 'column')); });
        });
      });
    });
    [6, 9, 10, 14, 17, 22, 23, 26].forEach(function (n) {
      var sides = stripsm.stripAlts(noteBox, pillsOf(n), K).filter(Boolean).map(function (a) { return a.side; });
      ['below', 'above'].forEach(function (side) { assert(sides.indexOf(side) >= 0, n + ' pills: ' + side + ' alone is offered: ' + sides.join(', ')); });
    });
  });

  await test('stars: a hub among its users and a ring, drawn with no crossing, no arrow over a box and nothing overlapping, the same twice, and kept where it is when it starts from there', async function () {
    var items = [], edges = [];
    for (var i = 0; i < 13; i++) items.push({ w: 200 + 10 * (i % 3), h: 90 });
    for (var u = 1; u <= 6; u++) edges.push({ a: 0, b: u, w: 1 });                            // 0 the hub of 1 to 6
    for (var k = 0; k < 6; k++) edges.push({ a: 7 + k, b: 7 + (k + 1) % 6, w: 1 });           // 7 to 12 a ring
    edges.push({ a: 6, b: 7, w: 1 });
    var pos = starsm.starsLayout(items, edges, { aspect: 1.5 });
    var boxes = pos.map(function (p, i) { return { x: p.x, y: p.y, w: items[i].w, h: items[i].h }; });
    for (var a = 0; a < 13; a++) for (var b = a + 1; b < 13; b++) assert(!(boxes[a].x < boxes[b].x + boxes[b].w && boxes[b].x < boxes[a].x + boxes[a].w && boxes[a].y < boxes[b].y + boxes[b].h && boxes[b].y < boxes[a].y + boxes[a].h), a + ' overlaps ' + b);
    var seg = function (e) { var p = boxes[e.a], q = boxes[e.b]; return { x1: p.x + p.w / 2, y1: p.y + p.h / 2, x2: q.x + q.w / 2, y2: q.y + q.h / 2 }; };
    edges.forEach(function (e, i) { edges.slice(i + 1).forEach(function (f) { if (e.a === f.a || e.a === f.b || e.b === f.a || e.b === f.b) return; assert(!geomm.segCross(seg(e), seg(f)), JSON.stringify(e) + ' crosses ' + JSON.stringify(f)); }); });
    edges.forEach(function (e) { boxes.forEach(function (bx, j) { if (j !== e.a && j !== e.b) assert(!geomm.segHitsBox(seg(e), bx), JSON.stringify(e) + ' runs over ' + j); }); });
    eq(starsm.starsLayout(items, edges, { aspect: 1.5 }), pos, 'the same again');
    var from = boxes.map(function (bx) { return [bx.x + bx.w / 2, bx.y + bx.h / 2]; });
    // the compaction after may nudge a box a few units, never more
    var stayed = starsm.starsLayout(items, edges, { aspect: 1.5, fromNotes: from });
    stayed.forEach(function (p, i) { assert(Math.abs(p.x - pos[i].x) <= 4 && Math.abs(p.y - pos[i].y) <= 4, 'started from where it is, ' + i + ' stays: ' + JSON.stringify([p, pos[i]])); });
    // a note with a column of pills, which may go on its right or its left (strips.mjs's arrangements: its box, its note in it, its strips and pills)
    var withColumn = function (w, h, nw, nh, ny) {
      var side = function (left) {
        var pills = [];
        for (var j = 0; j * 52 + 40 <= h; j++) pills.push({ x: left ? 0 : nw, y: j * 52, w: w - nw, h: 40 });
        return { w: w, h: h, nx: left ? w - nw : 0, ny: ny, nw: nw, nh: nh, strips: [{ x: left ? 0 : nw, y: 0, w: w - nw, h: h }], pills: pills };
      };
      return { w: w, h: h, alts: [side(false), side(true)], alt: 0 };
    };
    // a hub with a column of pills: its arrows leave the note on the side the column is not
    var hub = [withColumn(420, 90, 200, 90, 0), { w: 200, h: 90 }, { w: 200, h: 90 }, { w: 200, h: 90 }], spokes = [{ a: 0, b: 1, w: 1 }, { a: 0, b: 2, w: 1 }, { a: 0, b: 3, w: 1 }];
    // four notes in a chain and a note with a column of pills: no arrow runs over a box or a column
    var five = [{ w: 200, h: 100 }, { w: 200, h: 100 }, { w: 200, h: 100 }, { w: 200, h: 100 }, withColumn(440, 280, 200, 100, 90)];
    var chain = [[1, 0], [2, 1], [3, 2], [4, 0]].map(function (p) { return { a: p[0], b: p[1], w: 1 }; });
    var overs = function (items, links, at) {
      var note = function (i) { var it = items[i], p = at[i]; if (!it.alts) return { x: p.x, y: p.y, w: it.w, h: it.h }; var a = it.alts[p.alt]; return { x: p.x + a.nx, y: p.y + a.ny, w: a.nw, h: a.nh }; };
      var column = function (i) { var it = items[i], p = at[i]; if (!it.alts) return null; var s = it.alts[p.alt].strips[0]; return { x: p.x + s.x, y: p.y + s.y, w: s.w, h: s.h }; };
      var count = 0;
      links.forEach(function (e) {
        var a = note(e.a), b = note(e.b), s = { x1: a.x + a.w / 2, y1: a.y + a.h / 2, x2: b.x + b.w / 2, y2: b.y + b.h / 2 };
        items.forEach(function (it, j) { if (j !== e.a && j !== e.b && geomm.segHitsBox(s, note(j))) count++; if (column(j) && geomm.segHitsBox(s, column(j))) count++; });
      });
      return count;
    };
    eq(overs(five, chain, starsm.starsLayout(five, chain, { aspect: 1.5 })), 0, 'no arrow runs over a box or a column');
    var hp = starsm.starsLayout(hub, spokes, { aspect: 1.5 });
    var ha = hub[0].alts[hp[0].alt], note0 = { x: hp[0].x + ha.nx, y: hp[0].y + ha.ny, w: 200, h: 90 }, column = { x: hp[0].x + ha.strips[0].x, y: hp[0].y + ha.strips[0].y, w: ha.strips[0].w, h: ha.strips[0].h };
    spokes.forEach(function (e) { var s = { x1: note0.x + 100, y1: note0.y + 45, x2: hp[e.b].x + 100, y2: hp[e.b].y + 45 }; assert(!geomm.segHitsBox(s, column), 'the arrow to ' + e.b + ' runs over its start\'s own pills: ' + JSON.stringify(hp)); });
  });

  await test('stars: a child with no link is shelved beside the rest every time, never left where an earlier layout put it', async function () {
    // a chain of five and a note with no link, which an earlier round of the cut left far off (as Selection's Accessibility.swift was, 7,000 units away)
    var items = [0, 1, 2, 3, 4, 5].map(function () { return { w: 200, h: 100 }; }), edges = [[0, 1], [1, 2], [2, 3], [3, 4]].map(function (p) { return { a: p[0], b: p[1], w: 1 }; });
    var from = [[0, 0], [300, 0], [600, 0], [600, 200], [300, 200], [-5000, 4000]];
    var nearest = function (pos) {
      var a = { x: pos[5].x, y: pos[5].y, w: 200, h: 100 };
      return Math.min.apply(null, [0, 1, 2, 3, 4].map(function (i) { return gapOf(a, { x: pos[i].x, y: pos[i].y, w: 200, h: 100 }); }));
    };
    var kept = starsm.starsLayout(items, edges, { aspect: 1.5, fromNotes: from });
    assert(nearest(kept) <= 300, 'started from where it was: ' + nearest(kept) + ' from the nearest: ' + JSON.stringify(kept));
    var fresh = starsm.starsLayout(items, edges, { aspect: 1.5 });
    assert(nearest(fresh) <= 300, 'laid out afresh: ' + nearest(fresh) + ' from the nearest: ' + JSON.stringify(fresh));
    // exactly where: below the rest when they are wider than the shape wanted, under the one that reaches lowest (else right of the one that
    // reaches furthest right), 56 clear
    var spot = function (pos) {
      var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      [0, 1, 2, 3, 4].forEach(function (i) { x0 = Math.min(x0, pos[i].x); y0 = Math.min(y0, pos[i].y); x1 = Math.max(x1, pos[i].x + 200); y1 = Math.max(y1, pos[i].y + 100); });
      var below = (x1 - x0) / Math.max(1, y1 - y0) >= 1.5;
      var far = [0, 1, 2, 3, 4].reduce(function (f, i) { return (below ? pos[i].y > pos[f].y : pos[i].x > pos[f].x) ? i : f; }, 0);
      return below ? { x: pos[far].x, y: y1 + 56 } : { x: x1 + 56, y: pos[far].y };
    };
    [['started from where it was', kept], ['laid out afresh', fresh]].forEach(function (c) {
      var s = spot(c[1]);
      assert(Math.abs(c[1][5].x - s.x) <= 1 && Math.abs(c[1][5].y - s.y) <= 1, c[0] + ': the shelf hangs from the shape that reaches furthest: ' + JSON.stringify([c[1][5], s]));
    });
  });

  await test('the cut: K5 of notes is no planar graph, so a link becomes a pill and the board draws clean; a link marked direct, or into a shape kept off pills, is never cut', async function () {
    var five = ['A', 'B', 'C', 'D', 'E'], nodes = five.map(function (t) { return note(t); }), edges = [];
    five.forEach(function (a, i) { five.slice(i + 1).forEach(function (b) { edges.push({ from: a, to: b }); }); });
    var r = await planOf(digest(nodes, edges)), rep = r.report.boards.root;
    assert(rep.cut >= 1, 'the planar cut takes a link: ' + rep.cut);
    eq([rep.stop, rep.health.status, rep.health.crossings, rep.health.overShapes, rep.health.links], ['clean', 'clean', 0, 0, 10], 'and the board is clean');
    eq(rep.health.cut, rep.cut + rep.cutFurther - rep.restored, 'the links with no arrow are the ones cut, less those put back');
    var pilled = r.drawing.edges.filter(pillOf);
    eq(pilled.length, rep.cut + rep.cutFurther - rep.restored, 'each an edge through a pill');
    pilled.forEach(function (e) { assert(r.plan.boards[0].pills.some(function (p) { return p.for === e.to; }), 'a pill stands for its far end: ' + e.to); });
    var text = clim.summarize(r), said = /\ncut: (\d+) of 10 links made pills, (\d+) so each board's links are planar and (\d+) more where a drawing still crossed or ran over a shape/.exec(text);
    assert(said && +said[1] === rep.cut + rep.cutFurther && +said[2] === rep.cut && +said[3] === rep.cutFurther, 'the summary says the cut: ' + text);
    // every link direct: nothing can be cut, and the board is not clean
    var direct = (await planOf(digest(nodes, edges.map(function (e) { return Object.assign({ direct: true }, e); })))).report.boards.root;
    eq([direct.cut, direct.cutFurther, direct.stop, direct.end.pills], [0, 0, 'not clean', 0], 'direct links are kept');
    // E kept off pills: no link into it is cut, and K4's take the cut
    var never = nodes.slice(0, 4).concat([{ title: 'E', kind: 'sticky-note', text: '', pill: false }]);
    var n = await planOf(digest(never, edges));
    eq(n.drawing.edges.filter(function (e) { return pillOf(e) && e.to === 'E'; }).length, 0, 'no pill stands for E');
    var left = n.report.boards.root.health;
    assert(left.status === 'clean' || left.examples.every(function (x) { return /-> "E"/.test(x); }), 'what is left unclean is a link into E, which no cut may take: ' + JSON.stringify(left.examples));
  });

  await test('the planar cut keeps the most wanted first: the heavier link, then the one at the busier shape, then key order; ranked, the nearer ranks first', async function () {
    var five = ['A', 'B', 'C', 'D', 'E'], k5 = [];
    five.forEach(function (a, i) { five.slice(i + 1).forEach(function (b) { k5.push({ from: a, to: b }); }); });
    var cutOf = function (nodes, edges) { var d = digest(nodes, edges); var L = new layoutm.Layouter(model.buildModel(d), 'root', sizesOf(d), {}, elk); return [...cutm.planarLinks(L).cut].sort().map(function (k) { return k.replace('\u0000', '>'); }); };
    eq(cutOf(five.map(function (t) { return note(t); }), k5), ['D>E'], 'all alike: the last by key is cut');
    eq(cutOf(five.map(function (t) { return note(t); }), k5.map(function (e) { return e.from === 'D' && e.to === 'E' ? Object.assign({ weight: 3 }, e) : e; })), ['C>E'], 'a heavier link is kept: the last of the rest goes');
    eq(cutOf(five.map(function (t) { return note(t); }).concat([note('F')]), k5.concat([{ from: 'E', to: 'F' }])), ['C>D'], 'links at the busier shape (E, now with five) are kept: the last of the others goes');
    eq(cutOf(five.map(function (t, i) { return { title: t, kind: 'sticky-note', text: '', rank: i }; }), k5), ['A>E'], 'ranked: the longest span goes');
    // what the drawing still crosses: the link in the most conflicts first, the least wanted on a tie, and a conflict with nothing to cut passed over
    var lines = [{ key: 'a', cuttable: true }, { key: 'b', cuttable: true }, { key: 'c', cuttable: true }, { key: 'd', cuttable: false }];
    eq(cutm.conflictCuts([[0, 1], [1, 2], [3]], lines, function () { return 1; }), ['b'], 'b is in two conflicts: cutting it mends both');
    eq(cutm.conflictCuts([[0, 1]], lines, function (k) { return k === 'a' ? 5 : 3; }), ['b'], 'a tie: the least wanted');
  });

  await test('placement: rows where the links have no cycle (a tree where they are one), stars where they have one, ranks where there are ranks, and layout.placement over it, on the document or a node', async function () {
    var algoOf = function (r, c) { var a = r.report.boards.root.algorithms.find(function (x) { return x.container === c; }); return a && a.algorithm; };
    var four = ['A', 'B', 'C', 'D'].map(function (t) { return note(t); });
    var dag = [{ from: 'A', to: 'B' }, { from: 'A', to: 'C' }, { from: 'B', to: 'D' }, { from: 'C', to: 'D' }];
    var tree = [{ from: 'A', to: 'B' }, { from: 'A', to: 'C' }, { from: 'C', to: 'D' }];
    var cycle = [{ from: 'A', to: 'B' }, { from: 'B', to: 'C' }, { from: 'C', to: 'D' }, { from: 'D', to: 'A' }];
    eq(algoOf(await planOf(digest(four, dag)), 'root'), 'layered', 'no cycle: rows');
    eq(algoOf(await planOf(digest(four, tree)), 'root'), 'mrtree', 'a tree');
    eq(algoOf(await planOf(digest(four, cycle)), 'root'), 'stars', 'a cycle: stars');
    eq(algoOf(await planOf(digest(four, dag, { layout: { placement: 'stars' } })), 'root'), 'stars', 'the document asks for stars');
    eq(algoOf(await planOf(digest(four, cycle, { layout: { placement: 'rows' } })), 'root'), 'layered', 'the document asks for rows');
    var framed = [{ title: 'F', kind: 'frame', layout: { placement: 'rows' } }].concat(['A', 'B', 'C', 'D'].map(function (t) { return note(t, 'F'); }));
    eq(algoOf(await planOf(digest(framed, cycle, { layout: { placement: 'stars' } })), 'F'), 'layered', 'a frame\'s own over the document\'s');
    eq(algoOf(await planOf(rankedDigest()), 'root'), 'ranked', 'ranked children are rows or columns');
    var threw = ''; try { model.buildModel(digest(four, dag, { layout: { placement: 'grid' } })); } catch (e) { threw = e.message; }
    assert(/layout\.placement is stars or rows/.test(threw), 'another word is refused: ' + threw);
  });

  await test('a container in rows kept unclean only by arrows the cut may not take (between frames) is placed as stars instead, and draws clean', async function () {
    // the frames fixture: in rows, the arrow from the frame api to the frame store ran over the subboard Billing between them
    var r = await planOf(fixture('frames')), rep = r.report.boards.root;
    eq([rep.stop, rep.asStars], ['clean', ['b:root']], 'placed as stars, and clean');
    eq(rep.algorithms.find(function (a) { return a.container === 'root'; }).algorithm, 'stars');
    var plain = await planOf(fixture('acme'));
    eq(plain.report.boards.root.asStars, [], 'a board the cut makes clean keeps its placements');
    var asked = fixture('frames'); asked.layout = { placement: 'rows' };
    var kept = (await planOf(asked)).report.boards.root;
    eq([kept.asStars, kept.stop], [[], 'not clean'], 'rows the document asks for stay rows, and the board is said not clean');
  });

  await test('a cut link is a pill of its own beside its start, in its start\'s column alone', async function () {
    var nodes = [{ title: 'F', kind: 'frame' }, note('Hub')].concat(['u1', 'u2', 'u3'].map(function (t) { return note(t, 'F'); }));
    var d = digest(nodes, ['u1', 'u2', 'u3'].map(function (u) { return { from: u, to: 'Hub' }; }));
    var L = new layoutm.Layouter(model.buildModel(d), 'root', sizesOf(d), {}, elk);
    var none = L.pillPlan({ cut: new Set() });
    eq([none.direct.length, none.groups.length], [3, 0], 'three arrows and no pill');
    var two = L.pillPlan({ cut: new Set(['u2\u0000Hub', 'u3\u0000Hub']) });
    eq(two.direct.map(function (e) { return e.from; }), ['u1'], 'u1 keeps its arrow');
    eq(two.groups.map(function (g) { return [g.target, g.froms]; }), [['Hub', ['u2']], ['Hub', ['u3']]], 'a pill each');
    eq(two.members.length, 0, 'no arrow runs to another\'s pill');
    ['u2', 'u3'].forEach(function (u) { eq((two.byStart.get(u) || []).map(function (en) { return en.e.to; }), ['Hub'], u + '\'s pill is in its own column'); });
  });


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

  await test('a frame whose cards point at each other is no spine, and its links are pills only where the cut makes them', async function () {
    var r = await planOf(spineFixture([{ from: 'A', to: 'B' }]));
    assert(algorithmOf(r, 'Band') !== 'spine', 'Band is laid out as any frame is: ' + algorithmOf(r, 'Band'));
    assert(rootOf(r.plan).pills.every(function (p) { return !p.free; }), 'none free');
    checkPlan(r.plan);
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

  await test('edges between boards are pills; a board that draws clean as it is cuts nothing', async function () {
    var nodes = [{ title: 'Sub', kind: 'subboard' }, note('Inner A', 'Sub'), note('Inner B', 'Sub'), note('Top A'), note('Top B')];
    var edges = [{ from: 'Top A', to: 'Top B' }, { from: 'Top A', to: 'Inner B' }, { from: 'Inner A', to: 'Top B' }, { from: 'Inner A', to: 'Inner B' }];
    var r = await planOf(digest(nodes, edges));
    eq([r.report.totals.cut, r.report.totals.cutFurther], [0, 0], 'nothing cut');
    var ps = pillSet(r.plan);
    eq(ps, ['Sub|Inner A>Top B', 'root|Top A>Inner B'], 'pills');
    // the document keeps the nodes and the edges as given, an edge through a pill saying where its pill is
    eq(r.drawing.nodes.map(function (n) { return n.key; }), nodes.map(function (n) { return n.title; }), 'the nodes, in the order given');
    eq(r.drawing.edges.filter(function (e) { return pillOf(e); }).map(function (e) { return e.from + '>' + e.to; }).sort(), ['Inner A>Top B', 'Top A>Inner B'], 'the edges through pills');
    eq(r.drawing.edges.filter(function (e) { return !pillOf(e); }).map(function (e) { return e.from + '>' + e.to; }).sort(), ['Inner A>Inner B', 'Top A>Top B'], 'the arrows');
    checkPlan(r.plan);
  });


  // ---- the packing ----
  function gapOf(a, b) { var dx = Math.max(b.x - (a.x + a.w), a.x - (b.x + b.w), 0), dy = Math.max(b.y - (a.y + a.h), a.y - (b.y + b.h), 0); return Math.hypot(dx, dy); }
  function rootOf(plan) { return plan.boards.find(function (b) { return b.board === 'root'; }); }

  await test('pack: no box stranded from its nearest mate, boxes never overlap, the same input gives the same positions', async function () {
    var seed = 7; var rnd = function () { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    for (var trial = 0; trial < 12; trial++) {
      var n = 8 + Math.floor(rnd() * 10), items = [], pos = [];
      for (var i = 0; i < n; i++) { items.push({ w: 100 + Math.floor(rnd() * 250), h: 60 + Math.floor(rnd() * 120) }); }
      // scattered on a wide board, some far away (the stranded kind), made clear of each other first
      for (var i = 0; i < n; i++) pos.push({ x: Math.floor(rnd() * 6000), y: Math.floor(rnd() * 6000) });
      pos = elkm.removeOverlaps(items, pos, 64, 64);
      var edges = []; for (var i = 1; i < n; i += 2) edges.push({ a: i, b: Math.floor(rnd() * i), n: 1 });
      [0].forEach(function () {
        var r = elkm.pack(items, pos, edges, 64, 64), r2 = elkm.pack(items, pos, edges, 64, 64);
        eq(r.pos, r2.pos, 'deterministic');
        var boxes = items.map(function (it, i) { return { x: r.pos[i].x, y: r.pos[i].y, w: it.w, h: it.h }; });
        for (var i = 0; i < n; i++) {
          var near = Infinity;
          for (var j = 0; j < n; j++) { if (i === j) continue; assert(!(boxes[i].x < boxes[j].x + boxes[j].w && boxes[j].x < boxes[i].x + boxes[i].w && boxes[i].y < boxes[j].y + boxes[j].h && boxes[j].y < boxes[i].y + boxes[i].h), 'overlap'); near = Math.min(near, gapOf(boxes[i], boxes[j])); }
          assert(near <= 160, 'trial ' + trial + ': box ' + i + ' is ' + Math.round(near) + ' from its nearest mate');
        }
      });
    }
  });

  await test('packing in a plan: no frame member far from its nearest frame mate, frames close together', async function () {
    var d = fixture('acme');
    var fx = hubFixture(4, 5); var hub = digest(fx.nodes, fx.edges);
    for (var input of [d, hub]) {
      var r = await planOf(input);
      checkPlan(r.plan);
      var b = rootOf(r.plan);
      var units = b.shapes.filter(function (s) { return s.kind !== 'frame' && s.in; }).map(function (s) {
        var ps = b.pills.filter(function (p) { return p.start === s.key; });
        var x0 = Math.min.apply(null, [s.x].concat(ps.map(function (p) { return p.x; }))), x1 = Math.max.apply(null, [s.x + s.w].concat(ps.map(function (p) { return p.x + p.w; })));
        var y0 = Math.min.apply(null, [s.y].concat(ps.map(function (p) { return p.y; }))), y1 = Math.max.apply(null, [s.y + s.h].concat(ps.map(function (p) { return p.y + p.h; })));
        return { t: s.key, in: s.in, x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
      });
      units.forEach(function (u) {
        var mates = units.filter(function (v) { return v.in === u.in && v !== u; });
        if (!mates.length) return;
        var near = Math.min.apply(null, mates.map(function (v) { return gapOf(u, v); }));
        assert(near <= 200, u.t + ' is ' + Math.round(near) + ' from its nearest mate in ' + u.in);
      });
      var frames = b.shapes.filter(function (s) { return s.kind === 'frame' && !s.in; });
      frames.forEach(function (f) {
        var others = frames.filter(function (g) { return g !== f; });
        if (!others.length) return;
        var near = Math.min.apply(null, others.map(function (g) { return gapOf(f, g); }));
        assert(near >= 40 && near <= 200, f.key + ' is ' + Math.round(near) + ' from the nearest frame');
      });
    }
  });

  // ---- the build: the digest checks, the measure script and JSON, the fixtures, the commands ----
  function rankedDigest() {
    var nodes = [{ title: 'Low', kind: 'frame', rank: 2 }, { title: 'Top', kind: 'frame', rank: 0 }, { title: 'Mid', kind: 'frame', rank: 1 }, note('Loose', null, 'no rank')];
    ['A', 'B', 'C', 'D'].forEach(function (x) { nodes.push(note('Top ' + x, 'Top', 'x')); });
    nodes.push(note('Mid A', 'Mid', 'x'), note('Low A', 'Low', 'x'), note('Low B', 'Low', 'x'));
    return digest(nodes, [{ from: 'Low A', to: 'Top A' }, { from: 'Low B', to: 'Mid A' }, { from: 'Mid A', to: 'Top B' }]);
  }
  function shapesOf(r) { var by = {}; rootOf(r.plan).shapes.forEach(function (s) { by[s.key] = s; }); return by; }
  var isRows = function (by) { return by.Top.y + by.Top.h < by.Mid.y && by.Mid.y + by.Mid.h < by.Low.y; };
  var isColumns = function (by) { return by.Top.x + by.Top.w < by.Mid.x && by.Mid.x + by.Mid.w < by.Low.x; };

  await test('ranked frames holding stars: the next round starts from the layout of the width chosen, not the last one tried', async function () {
    // three ranked frames of five notes each in a ring with a chord (stars), and links between them, in a tall view (rows, a band of many
    // widths tried); the state stars leaves for the next round (each frame's middles) is the chosen width's: what is drawn, moved as a block
    var nodes = [], edges = [];
    ['P', 'Q', 'R'].forEach(function (f, r) {
      nodes.push({ title: f, kind: 'frame', rank: r });
      var ring = [1, 2, 3, 4, 5].map(function (i) { return f + i; });
      ring.forEach(function (t, i) { nodes.push(note(t, f, 'a note\nof two lines')); edges.push({ from: t, to: ring[(i + 1) % 5] }); });
      edges.push({ from: ring[0], to: ring[2] });
    });
    edges.push({ from: 'P1', to: 'Q1' }, { from: 'Q3', to: 'R1' }, { from: 'P2', to: 'R2' });
    var d = digest(nodes, edges), m = model.buildModel(d);
    var L = new layoutm.Layouter(m, 'root', sizesOf(d), { view: { w: 800, h: 1600 }, spines: true }, elk);
    var first = await L.layout({ cut: new Set() });
    var frames = first.containers.filter(function (c) { return c.algorithm === 'stars' && c.cid[0] === 'f'; });
    eq(frames.map(function (c) { return c.container; }), ['P', 'Q', 'R'], 'three stars frames');
    frames.forEach(function (c) {
      var mids = L.starsAt.get(c.cid), off = null;
      first.boxes.forEach(function (bx, k) {
        if (m.node(k).container !== c.cid) return;
        var o = [bx.x + bx.w / 2 - mids.get(k)[0], bx.y + bx.h / 2 - mids.get(k)[1]];
        if (!off) off = o;
        assert(Math.abs(o[0] - off[0]) <= 1 && Math.abs(o[1] - off[1]) <= 1, c.container + "'s " + k + ' is not where the state it leaves says: ' + JSON.stringify([o, off]));
      });
    });
  });

  await test('ranked frames as rows are in rank order, each as wide as the widest, what they hold centred; an unranked shape goes below them', async function () {
    var r = await planOf(rankedDigest(), { ranks: 'rows' });
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
    var r = await planOf(rankedDigest(), { ranks: 'columns' });
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
    var wide = await planOf(rankedDigest(), { view: { w: 2400, h: 800 } }), tall = await planOf(rankedDigest(), { view: { w: 800, h: 2400 } });
    var w = shapesOf(wide), t = shapesOf(tall);
    assert(isColumns(w), 'a wide view: columns');
    assert(isRows(t), 'a tall view: rows');
    // the band of four notes is laid out to its slot: narrower as a column of the wide view than as a row of it would be
    var rowsOfWide = shapesOf(await planOf(rankedDigest(), { view: { w: 2400, h: 800 }, ranks: 'rows' }));
    assert(w.Top.w < rowsOfWide.Top.w, 'a column is narrower than the row: ' + w.Top.w + ' against ' + rowsOfWide.Top.w);
    eq([wide.report.view.from, wide.report.view.w], ['given', 2400], 'the report says the view the plan is for');
    checkPlan(wide.plan); checkPlan(tall.plan);
  });

  await test('a board is laid out to the shape of the view: wider than tall for a wide view, taller than wide for a tall one', async function () {
    var d = fixture('acme');
    var wide = await planOf(d, { view: { w: 1600, h: 800 } }), tall = await planOf(d, { view: { w: 800, h: 1600 } });
    var sizeOf = function (r) { return r.report.boards.root.health.size; };
    assert(sizeOf(wide)[0] > sizeOf(wide)[1], 'a wide view: ' + sizeOf(wide));
    assert(sizeOf(tall)[1] > sizeOf(tall)[0], 'a tall view: ' + sizeOf(tall));
    [[wide, 2], [tall, 0.5]].forEach(function (x) { var s = sizeOf(x[0]); assert(elkm.offShape(s[0], s[1], x[1]) <= 1.6, 'near the view\'s shape: ' + s); checkPlan(x[0].plan); });
    // the same digest, the same view: the same plan
    var again = await planOf(d, { view: { w: 1600, h: 800 } });
    eq(JSON.stringify(again.plan), JSON.stringify(wide.plan), 'the same again');
  });

  await test('layout.ranks says which way ranked children run, and --ranks says it over the document', async function () {
    var d = Object.assign(rankedDigest(), { layout: { ranks: 'rows' } }), wide = { w: 2400, h: 800 };
    assert(isRows(shapesOf(await planOf(d, { view: wide }))), 'the digest says rows, in a view that would have columns');
    assert(isColumns(shapesOf(await planOf(d, { view: wide, ranks: 'columns' }))), 'the option says columns over it');
    assert(isColumns(shapesOf(await planOf(d, { view: wide, ranks: 'auto' }))), 'and auto leaves it to the view');
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

  await test('boxes pushed apart move only where they overlap', async function () {
    // two boxes too near are pushed apart along the way they overlap least; a third, clear of both, stays
    var three = [{ w: 200, h: 100 }, { w: 200, h: 100 }, { w: 200, h: 100 }], at = [{ x: 0, y: 0 }, { x: 150, y: 10 }, { x: 0, y: 600 }];
    var out = elkm.pushApart(three, at, 40, 64);
    eq(out[2], at[2], 'the box clear of the others has not moved');
    assert(out[1].x - (out[0].x + 200) >= 40 - 1e-6, 'the two are 40 apart across: ' + JSON.stringify(out));
    eq(elkm.pushApart(three, [{ x: 0, y: 0 }, { x: 240, y: 0 }, { x: 0, y: 164 }], 40, 64), [{ x: 0, y: 0 }, { x: 240, y: 0 }, { x: 0, y: 164 }], 'boxes already clear stay where they are');
  });

  await test('a board with a container past the crowd is laid out once and cut no further than planar: its crowd packed as boxes, and the summary says why and to split it', async function () {
    // a frame of an index and CROWD pages it points at: a star, which laid out as a tree runs a row (or a column) as long as the pages
    var nodes = [{ title: 'Pages', kind: 'frame' }, note('Index', 'Pages')], edges = [];
    for (var i = 0; i < layoutm.CROWD; i++) { nodes.push(note('Page ' + i, 'Pages')); edges.push({ from: 'Index', to: 'Page ' + i }); }
    var r = await planOf(digest(nodes, edges));
    var rep = r.report.boards.root;
    eq(rep.stop, 'crowded'); eq(rep.crowded.container, 'Pages'); eq(rep.crowded.children, layoutm.CROWD + 1);
    eq([rep.rounds, rep.cutFurther], [0, 0], 'laid out once, and cut no further');
    eq(rep.algorithms.find(function (a) { return a.container === 'Pages'; }).algorithm, 'rectpacking', 'the crowd packed as boxes');
    var pages = r.plan.boards[0].shapes.find(function (s) { return s.key === 'Pages'; });
    assert(pages.w < 20000 && pages.h < 20000 && Math.max(pages.w / pages.h, pages.h / pages.w) < 4, 'a grid, not a row: ' + pages.w + ' x ' + pages.h);
    eq(r.plan.boards[0].shapes.length, layoutm.CROWD + 2, 'every shape planned: the pages, the index and the frame');
    checkPlan(r.plan);
    assert(r.report.warnings.some(function (w) { return /board "root" was laid out once and cut no further than its links' planar cut: its frame "Pages" holds 151 shapes side by side, past 150.*split it into subboards/.test(w); }), r.report.warnings.join('\n'));
    assert(/warning: board "root" was laid out once/.test(clim.summarize(r)), clim.summarize(r));
    // one fewer is laid out by its links, and cut as any board is
    nodes.pop(); edges.pop();
    var fewer = await planOf(digest(nodes, edges));
    assert(fewer.report.boards.root.stop !== 'crowded' && !fewer.report.warnings.length, fewer.report.boards.root.stop);
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
    d = tiny(); d.nodes[3].layout = { rank: 'high', pill: 1 }; d.edges[0].layout = { weight: 'heavy', direct: 'yes' }; d.layout = { placement: 'grid', ranks: 'sideways' };
    eq(errorsOf(d).length, 6, 'hints of the wrong type: ' + JSON.stringify(errorsOf(d)));
    [0, -0.5, 1e7].forEach(function (w) { d = tiny(); d.edges[0].layout = { weight: w }; said(errorsOf(d), /edges\[0\] A -> B: layout\.weight is a number above 0 and at most 1,000,000, not /, 'a weight of ' + w + ', by its ends'); });
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
    eq(sz.shapes.A, { w: 411, h: 222, above: 30, titleWidth: 0 }, 'size, above and the title\'s width, by key');
    eq(sz.frames.Fr, { min: { w: 150, h: 90 }, titleWidth: 700, above: 9 }, 'a frame\'s smallest, its title and the room the title takes above it');
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
    var two = digest([{ title: 'Sub', kind: 'subboard' }, note('U1', 'Sub'), note('Hub')], [{ from: 'U1', to: 'Hub' }, { from: 'U1', to: 'Hub', props: { text: 'again' } }]);
    var u1 = (await planOf(two)).drawing.edges.filter(function (e) { return e.from === 'U1'; });
    eq(u1.length, 2);
    assert(pillOf(u1[0]) && pillOf(u1[0]).at, 'the first makes the pill: ' + JSON.stringify(u1[0].place));
    eq(pillOf(u1[1]), { share: 'U1' }, 'the second edge of a pair goes into the first one\'s pill');
    // a loop is drawn straight
    var loop = await planOf(digest([note('A'), note('B')], [{ from: 'A', to: 'A' }, { from: 'A', to: 'B' }]));
    assert(loop.drawing.edges.length === 2 && !pillOf(loop.drawing.edges[0]), 'a loop stays in the document, with no pill');
  });

  await test('links put back by the drawing: a link the cut made a pill that has a clear line on the finished drawing is an arrow again, and the board stays clean; one whose line would cross another stays a pill', async function () {
    // K5 is no planar graph: the cut takes links, and the drawing has room for some of them again, but not for all
    var five = ['A', 'B', 'C', 'D', 'E'], nodes = five.map(function (t) { return note(t); }), edges = [];
    five.forEach(function (a, i) { five.slice(i + 1).forEach(function (b) { edges.push({ from: a, to: b }); }); });
    var d = digest(nodes, edges), r = await planOf(d), rep = r.report.boards.root;
    assert(rep.restored >= 1, 'a link is put back: ' + rep.restored);
    eq([rep.stop, rep.health.status, rep.health.overOwnPills], ['clean', 'clean', 0], 'the board is clean');
    var cutKeys = r.results.get('root').state.cut, back = r.drawing.edges.filter(function (e) { return !pillOf(e) && cutKeys.has(e.from + '\u0000' + e.to); });
    eq(back.length, rep.restored, 'each is an edge with no pill, drawn as an arrow');
    eq(r.report.totals.restored, rep.restored, 'the totals count them');
    assert(/\n.*put back as arrows/.test(clim.summarize(r)), 'and the summary says so');
    // each link still a pill would cross another line or run over a shape if it were an arrow: the board would not be clean
    var m = model.buildModel(d), sz = sizes.sizesFrom(m, helpers.estimateMeasure(m, d)), still = r.drawing.edges.filter(pillOf);
    assert(still.length >= 1, 'a link is still a pill');
    still.forEach(function (p) {
      var as = JSON.parse(JSON.stringify(r.drawing));
      as.edges.forEach(function (e) { if (e.from === p.from && e.to === p.to) delete e.place; });
      assert(healthm.healthOf(m, as, sz, { view: r.report.view }).totals.clean === 0, p.from + ' > ' + p.to + ' stays a pill: as an arrow the board would not be clean');
    });
  });

  await test('shared pills by the drawing: notes that use one shape on another board share a pill each of them reaches clean, and the board stays clean', async function () {
    var users = ['A', 'B', 'C', 'D', 'E', 'F'], nodes = users.map(function (t) { return note(t); }).concat([{ title: 'Lib', kind: 'subboard' }, note('X', 'Lib'), note('Y', 'Lib')]), edges = [];
    users.forEach(function (u, i) { edges.push({ from: u, to: 'X' }); if (i % 2) edges.push({ from: u, to: 'Y' }); if (i) edges.push({ from: users[i - 1], to: u }); });
    var r = await planOf(digest(nodes, edges)), rep = r.report.boards.root;
    assert(rep.sharedByDrawing >= 1, 'a pill is shared: ' + rep.sharedByDrawing);
    eq([rep.health.status, rep.health.overOwnPills], ['clean', 0], 'the board is clean, and no line runs over a pill its note uses');
    var sharers = r.drawing.edges.filter(function (e) { return pillOf(e) && pillOf(e).share != null; });
    assert(sharers.length >= 1, 'an edge goes into a pill another note makes');
    eq(rep.end.arrows, 5, 'sharing costs no arrow');
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
  // Recorded with the layout of docs/plans/board-layout as built (cut until planar, placed as stars or rows, cut until clean, pills in strips,
  // links put back where the drawing has a clear line, pills shared where the notes reach a spot by clear lines); jsc and node draw each alike.
  var HASHES = { acme: 'abf7dca9fb2afcd7', tree: 'cfe3264f23fbc489', flat60: '8e073bcc029ef67a', spine: '3a734d448327b89a', typed: 'f9237a88d58e80a6', frames: '99b1d0e9ce914a2b' };
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
  var rowsOf = function (drawing, edit, noEdges) {
    var abs = absoluteOf(drawing), by = {};
    drawing.nodes.forEach(function (n) { by[n.key] = n; });
    var rows = drawing.nodes.map(function (n) {
      var inside = [], p = n.in;
      while (p) { inside.unshift(p); p = by[p].in; }
      var b = abs[n.key], row = { id: 'id:' + n.key, key: n.key, at: [[b.x, b.y], [b.w, b.h]], board: 'board:1', inside: inside };
      if (n.in) row.in = n.in;
      return row;
    });
    // and a row for each pill an edge made, kept under the edge's key, as the app answers: `in` its frame, else the subboard whose board it is on;
    // and a row for each edge, with no place: its key (its own, else its ends and what tells a pair's edges apart, then a count), the ends it joins
    // and the pill it runs through (the pill the edge makes, or the one the host it shares goes into)
    var insideOf = function (k) { var out = [], p = k; while (p) { out.unshift(p); p = by[p].in; } return out; };
    var seen = {}, recKeys = drawing.edges.map(function (e) {
      var k = e.key || e.from + ' -> ' + e.to + (e.props && e.props.is !== undefined ? ' is ' + JSON.stringify(e.props.is) : '');
      seen[k] = (seen[k] || 0) + 1;
      return e.key ? k : seen[k] > 1 ? k + ' #' + seen[k] : k;
    });
    var makerOf = function (e) { for (var i = 0; i < drawing.edges.length; i++) { var x = drawing.edges[i]; if (x.from === e.place.pill.share && x.to === e.to && x.place && x.place.pill && x.place.pill.at) return recKeys[i]; } return null; };
    drawing.edges.forEach(function (e, i) {
      var p = e.place && e.place.pill;
      if (!p || !p.at) return;
      var holder = p.in, up = by[e.from].in;
      while (!holder && up) { if (by[up].kind === 'subboard') holder = up; up = by[up].in; }
      var f = p.in ? abs[p.in] : { x: 0, y: 0 }, row = { id: 'id:pill:' + recKeys[i], key: 'pill ' + recKeys[i], at: [[f.x + p.at[0], f.y + p.at[1]], [100, 40]], board: 'board:1', inside: holder ? insideOf(holder) : [] };
      if (holder) row.in = holder;
      rows.push(row);
    });
    if (!noEdges) drawing.edges.forEach(function (e, i) {
      var p = e.place && e.place.pill, maker = p ? (p.at ? recKeys[i] : makerOf(e)) : null;
      var c = { type: 'note-link', from: { id: 'id:' + e.from, title: e.from }, to: { id: 'id:' + e.to, title: e.to } };
      if (maker) c.via = { to: { id: 'id:pill:' + maker } };
      rows.push({ id: 'id:edge:' + recKeys[i], key: 'edge ' + recKeys[i], kind: 'arrow', board: 'board:1', inside: [], connection: c });
    });
    if (edit) edit(rows);
    return { rows: rows, absent: [] };
  };
  var placesOfNodes = function (r) { var o = {}; r.drawing.nodes.forEach(function (n) { o[n.key] = JSON.stringify(n.place); }); return o; };

  // a frame of a plugin and its six points, each point used by a file beside the frame, the files in a ring
  function pointsDigest(extra) {
    var nodes = [{ title: 'Points', kind: 'frame' }, note('Plugin', 'Points')], edges = [];
    for (var i = 1; i <= 6; i++) {
      nodes.push(note('P' + i, 'Points'), note('File' + i));
      edges.push({ from: 'Plugin', to: 'P' + i }, { from: 'File' + i, to: 'P' + i }, { from: 'File' + i, to: 'File' + (i % 6 + 1) });
    }
    (extra || []).forEach(function (n) { nodes.push(n); });
    return digest(nodes, edges);
  }

  await test('a frame whose members a shape beside it links to is laid out with its container: the links to its members are arrows, the board clean', async function () {
    var d = pointsDigest(), r = await planOf(d), rep = r.report.boards.root;
    var algo = function (c) { var a = rep.algorithms.find(function (x) { return x.container === c; }); return a && a.algorithm; };
    eq([algo('Points'), algo('root')], ['group', 'stars'], 'the frame is a group of its container\'s stars');
    eq(rep.stop, 'clean', 'clean');
    checkPlan(r.plan);
    var drawn = r.drawing.edges.filter(function (e) { return /^File/.test(e.from) && /^P\d/.test(e.to) && !(e.place && e.place.pill); });
    assert(drawn.length >= 4, 'most files reach their point by an arrow: ' + drawn.length + ' of 6');
    // every member inside its frame, the frame's box round them
    var abs = absoluteOf(r.drawing), f = abs.Points;
    r.drawing.nodes.filter(function (n) { return n.in === 'Points'; }).forEach(function (n) { var b = abs[n.key]; assert(b.x >= f.x && b.y >= f.y && b.x + b.w <= f.x + f.w && b.y + b.h <= f.y + f.h, n.key + ' is inside its frame'); });
    // the same again; a frame of notes no shape beside it links to stays one box
    eq(JSON.stringify((await planOf(d)).drawing), JSON.stringify(r.drawing), 'the same again');
    var alone = await planOf(digest([{ title: 'Points', kind: 'frame' }, note('A', 'Points'), note('B', 'Points'), note('C')], [{ from: 'A', to: 'B' }, { from: 'B', to: 'A' }, { from: 'C', to: 'C' }]));
    assert(alone.report.boards.root.algorithms.every(function (a) { return a.algorithm !== 'group'; }), 'no shape beside it links in: one box');
    // drawn again in place: as the file holds it, it comes out as it is; with a note added beside it, the board is mended clean
    var same = await planOf(d, { current: rowsOf(r.drawing) });
    eq(placesOfNodes(same), placesOfNodes(r), 'drawn again, where it is');
    var grown = await planOf(pointsDigest([note('Newcomer')]), { current: rowsOf(r.drawing) });
    eq(grown.report.boards.root.stop, 'clean', 'a note added: clean');
    checkPlan(grown.plan);
  });


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
    var columns = await planOf(d, { ranks: 'columns' });
    var rows = await planOf(d, { ranks: 'rows', current: rowsOf(columns.drawing) });
    assert(isRows(shapesOf(rows)), 'rows: ' + JSON.stringify(shapesOf(rows).Top) + ' ' + JSON.stringify(shapesOf(rows).Mid));
    // a band as wide as the widest centres what it holds: each note where it was against the others
    var inside = function (r) { var o = {}, held = r.drawing.nodes.filter(function (n) { return n.in === 'Top'; }), first = held[0].place.at; held.forEach(function (n) { o[n.key] = JSON.stringify([n.place.at[0] - first[0], n.place.at[1] - first[1]]); }); return o; };
    eq(inside(rows), inside(columns), 'a band keeps where its notes are');
    assert(rows.report.boards.root.kept.indexOf('f:Top') >= 0 && rows.report.boards.root.kept.indexOf('b:root') < 0, 'the band kept, the board laid out by its ranks: ' + JSON.stringify(rows.report.boards.root.kept));
  });

  await test('drawing again in place: a note added to a container, taken out of it or carried to another is put down beside the shapes that stay, which stay where they are; a rows answer with absent shapes is read', async function () {
    var d = fixture('acme'), first = await planOf(d), rows = rowsOf(first.drawing);
    var frames = first.drawing.nodes.filter(function (n) { return n.kind === 'frame'; }).map(function (n) { return n.key; });
    var target = frames[0], other = frames[1];
    var members = function (key) { return first.drawing.nodes.filter(function (n) { return n.in === key; }).map(function (n) { return n.key; }); };
    var placeIn = function (r, k) { return r.drawing.nodes.find(function (n) { return n.key === k; }).place; };
    // every shape but those named is where it was, and the frames hold their members
    var stay = function (r, but) {
      first.drawing.nodes.forEach(function (n) { if (but.indexOf(n.key) < 0) eq(placeIn(r, n.key).at, n.place.at, n.key + ' stays'); });
    };
    // a note added to a frame: the frame keeps its members (it is not laid out afresh), the newcomer is put down beside them
    var grown = JSON.parse(JSON.stringify(d)); grown.nodes.push(nodeOf(note('Newcomer', target, 'new')));
    var a = await planOf(grown, { current: rows });
    assert(a.report.boards.root.kept.indexOf('f:' + target) >= 0 && !a.report.boards.root.afresh, 'the frame with a newcomer keeps its members: ' + JSON.stringify(a.report.boards.root.kept));
    eq(a.report.boards.root.health.status, 'clean', 'clean');
    stay(a, ['Newcomer', target]);
    assert(a.drawing.nodes.find(function (n) { return n.key === 'Newcomer'; }), 'the newcomer is placed');
    checkPlan(a.plan);
    var abs = absoluteOf(a.drawing), mine = members(target).concat(['Newcomer']);
    mine.forEach(function (k, i) { mine.slice(i + 1).forEach(function (j) { var p = abs[k], q = abs[j]; assert(!(p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h), k + ' and ' + j + ' overlap'); }); });
    // a note taken out of the document: the others stay, and the pills to it are gone
    var shrunk = JSON.parse(JSON.stringify(d)), gone = members(other)[0];
    shrunk.nodes = shrunk.nodes.filter(function (n) { return n.key !== gone; }); shrunk.edges = shrunk.edges.filter(function (e) { return e.from !== gone && e.to !== gone; });
    var b = await planOf(shrunk, { current: rows });
    assert(b.report.boards.root.kept.indexOf('f:' + other) >= 0 && !b.report.boards.root.afresh, 'the frame that lost a member keeps the rest: ' + JSON.stringify(b.report.boards.root.kept));
    stay(b, [gone]);
    eq(b.report.boards.root.health.status, 'clean', 'still clean');
    // a note moved by hand to another frame: the frame it entered puts it down beside its members, the others stay
    var carried = rowsOf(first.drawing, function (rs) { var rn = rs.find(function (x) { return x.key === members(target)[0]; }); rn.in = other; rn.inside = [other]; });
    var c = await planOf(d, { current: carried });
    var kept = c.report.boards.root.kept;
    assert(kept.indexOf('f:' + target) >= 0 && kept.indexOf('f:' + other) >= 0 && kept.indexOf('b:root') >= 0 && !c.report.boards.root.afresh, 'both frames and the board keep their members: ' + JSON.stringify(kept));
    eq(c.report.boards.root.health.status, 'clean', 'clean');
    checkPlan(c.plan);
    // an answer that is a bare list of rows is read as well, and rows without a place are ignored
    var bare = await planOf(d, { current: rows.rows.concat([{ id: 'x', key: 'gone', inside: [] }]) });
    eq(placesOfNodes(bare), placesOfNodes(first), 'a list of rows');
  });

  await test('drawing again in place: a document the file holds as drawn comes out exactly as it is, every container kept and no board laid out afresh', async function () {
    var names = ['acme', 'tree', 'flat60', 'spine', 'typed', 'frames'];
    for (var i = 0; i < names.length; i++) {
      var d = fixture(names[i]), first = await planOf(d), again = await planOf(d, { current: rowsOf(first.drawing) });
      eq(JSON.stringify(again.drawing), JSON.stringify(first.drawing), names[i] + ': the same drawing, byte for byte');
      Object.keys(again.report.boards).forEach(function (bd) {
        var rep = again.report.boards[bd];
        assert(!rep.afresh && rep.kept.length >= 1, names[i] + ' ' + bd + ' kept: ' + JSON.stringify(rep.kept));
        eq([rep.rounds, rep.cutFurther], [0, 0], names[i] + ' ' + bd + ': nothing was mended');
      });
    }
  });

  await test('drawing again in place: a note added goes beside the shapes it links to and nothing else moves, a note taken out or a link added moves none, and a longer note grows where it stands', async function () {
    var d = fixture('acme'), first = await planOf(d), rows = rowsOf(first.drawing), abs0 = absoluteOf(first.drawing);
    var moved = function (r, but) { var abs = absoluteOf(r.drawing); return Object.keys(abs0).filter(function (k) { return but.indexOf(k) < 0 && JSON.stringify(abs0[k]) !== JSON.stringify(abs[k]); }); };
    var added = JSON.parse(JSON.stringify(d)); added.nodes.push(nodeOf(note('Newcomer'))); added.edges.push({ from: 'Newcomer', to: 'Sales' }, { from: 'Newcomer', to: 'Finance' });
    var a = await planOf(added, { current: rows }), abs = absoluteOf(a.drawing);
    eq(moved(a, []), [], 'no shape moved');
    var dist = function (p, q) { return Math.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)); };
    assert(Math.min(dist(abs.Newcomer, abs.Sales), dist(abs.Newcomer, abs.Finance)) < 1200, 'the newcomer is beside one of the notes it links to: ' + Math.round(dist(abs.Newcomer, abs.Sales)));
    eq([a.report.boards.root.health.status, a.report.boards.root.afresh], ['clean', false], 'clean, and the board was not laid out afresh');
    checkPlan(a.plan);
    var removed = JSON.parse(JSON.stringify(d)); removed.nodes = removed.nodes.filter(function (n) { return n.key !== 'Legal'; }); removed.edges = removed.edges.filter(function (e) { return e.from !== 'Legal' && e.to !== 'Legal'; });
    eq(moved(await planOf(removed, { current: rows }), ['Legal']), [], 'a note taken out: no shape moved');
    var linked = JSON.parse(JSON.stringify(d)); linked.edges.push({ from: 'Marketing', to: 'People' });
    var l = await planOf(linked, { current: rows });
    eq(moved(l, []), [], 'a link added: no shape moved');
    eq(l.report.boards.root.health.status, 'clean', 'and the board is clean');
    var taller = JSON.parse(JSON.stringify(d));
    taller.nodes.find(function (n) { return n.key === 'CTO'; }).props.text = 'A longer text\n\nthat takes\n\nmore lines\n\nthan it did\n\nbefore: a note that grew taller';
    var t = await planOf(taller, { current: rows }), tabs = absoluteOf(t.drawing);
    eq(moved(t, ['CTO']), [], 'a longer note: no other shape moved');
    eq([tabs.CTO.x, tabs.CTO.y, tabs.CTO.h > abs0.CTO.h], [abs0.CTO.x, abs0.CTO.y, true], 'it grew where it stands');
  });

  await test('drawing again in place: a link that is a pill stays a pill and an arrow an arrow, whatever else changes, and a board whose notes and links did not change is not redone', async function () {
    var d = fixture('acme'), first = await planOf(d), rows = rowsOf(first.drawing);
    var state = function (r) { var o = {}; r.drawing.edges.forEach(function (e) { o[e.from + '>' + e.to] = e.place && e.place.pill ? (e.place.pill.share != null ? 'share' : 'pill') : 'arrow'; }); return o; };
    var s0 = state(first), pills = Object.keys(s0).filter(function (k) { return s0[k] !== 'arrow'; }).length;
    assert(pills >= 20 && pills < Object.keys(s0).length, 'the drawing has both: ' + pills + ' pills of ' + Object.keys(s0).length);
    var changed = JSON.parse(JSON.stringify(d));
    changed.nodes.find(function (n) { return n.key === 'CTO'; }).props.text = 'A longer text\n\nthat takes\n\nmore lines\n\nthan it did\n\nbefore: a note that grew taller';
    changed.nodes.push(nodeOf(note('Newcomer', 'Operations'))); changed.edges.push({ from: 'Newcomer', to: 'Legal' });
    var r = await planOf(changed, { current: rows }), s1 = state(r);
    eq(Object.keys(s0).filter(function (k) { return s0[k] !== s1[k]; }), [], 'every link keeps being what it was');
    // a document of two boards, one of them changed: the other comes out as it is, the pills that point into the changed one aside
    var t = fixture('tree'), tf = await planOf(t), tr = rowsOf(tf.drawing);
    var edited = JSON.parse(JSON.stringify(t)); edited.nodes.push(nodeOf(note('Extra', 'Auth', 'extra'))); edited.edges.push({ from: 'Extra', to: 'Login' });
    var e = await planOf(edited, { current: tr });
    assert(e.report.boards.Backend.kept.length >= 1 && !e.report.boards.Backend.afresh, 'the changed board keeps its containers');
    var rootNodes = function (x) { return x.drawing.nodes.filter(function (n) { return x.model.node(n.key).board === 'root'; }).map(function (n) { return [n.key, n.place]; }); };
    eq(rootNodes(e), rootNodes(tf), 'the other board is as it was');
    eq(e.report.boards.root.ms < 1000, true, 'and costs next to nothing: ' + e.report.boards.root.ms + ' ms');
  });

  await test('drawing again in place: a board a person tangled is mended where it is kept, and kept with what is left said where no cut mends it', async function () {
    var d = digest([note('A'), note('B'), note('C'), note('D')], [{ from: 'A', to: 'B' }, { from: 'C', to: 'D' }]);
    var first = await planOf(d), at = function (r, k) { return r.drawing.nodes.find(function (n) { return n.key === k; }).place.at; };
    eq(first.report.boards.root.health.status, 'clean');
    // a person drags the four into a square, so A -> B crosses C -> D: kept where they are, and a link cut so the board is clean again
    var square = { A: [0, 0], B: [1400, 900], C: [1400, 0], D: [0, 900] };
    var tangled = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (r) { if (square[r.key]) r.at[0] = square[r.key].slice(); }); }) });
    var t = tangled.report.boards.root;
    eq([t.stop, t.health.status, t.afresh, t.kept], ['clean', 'clean', false, ['b:root']], 'mended where it is');
    assert(t.cutFurther > first.report.boards.root.cutFurther, 'by a cut the fresh plan did not need: ' + t.cutFurther);
    ['A', 'B', 'C', 'D'].forEach(function (k) { eq(at(tangled, k), square[k], k + ' stays where the person put it'); });
    // a person drags A away and puts C on the room B's title takes, 10 units above it: both stay where they put them (the board is not laid out afresh),
    // and B, which C covers, is put down again
    var b = first.drawing.nodes.find(function (n) { return n.key === 'B'; }).place, c = first.drawing.nodes.find(function (n) { return n.key === 'C'; }).place;
    var moved = { A: [b.at[0] - 1500, b.at[1]], C: [b.at[0], b.at[1] - c.size[1] - 10] };
    var heldBy = new Map([['A', new Set(['moved'])], ['C', new Set(['moved'])]]);
    var onTitle = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (r) { if (moved[r.key]) r.at[0] = moved[r.key]; }); }), changed: heldBy });
    var o = onTitle.report.boards.root;
    eq([o.stop, o.health.status, o.afresh], ['clean', 'clean', false], 'kept, and clean');
    eq([at(onTitle, 'A'), at(onTitle, 'C')], [moved.A, moved.C], 'what the person moved stays where they put it');
    eq(o.held, ['A', 'C'], 'the report says which are held');
    assert(o.moved.some(function (m) { return m.key === 'B' && /covered/.test(m.why); }), 'B is put down again, because a person\'s shape covers it: ' + JSON.stringify(o.moved));
    // without `changed` (an app that does not say) a shape put on another's title is not known to be a person's: the check says so, and the board is kept as it is (never laid out afresh: that would put back what a person moved)
    var unknown = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (r) { if (moved[r.key]) r.at[0] = moved[r.key]; }); }) });
    eq([unknown.report.boards.root.afresh, unknown.report.boards.root.health.status], [false, 'not clean'], 'kept, and said, where nothing says whose it is');
    eq([at(unknown, 'A'), at(unknown, 'C')], [moved.A, moved.C], 'and what the person moved stays');
  });

  await test('drawing again in place: the cut is read from the rows of the edges: a link through a pill stays a pill, a link through none an arrow, and a note that shares a pill stays in the pill the file has it in', async function () {
    var names = ['acme', 'flat60', 'spine', 'typed'], shared = 0;
    for (var i = 0; i < names.length; i++) {
      var first = await planOf(fixture(names[i]));
      shared += first.drawing.edges.filter(function (e) { return e.place && e.place.pill && e.place.pill.share != null; }).length;
      var again = await planOf(fixture(names[i]), { current: rowsOf(first.drawing) });
      eq(JSON.stringify(again.drawing.edges), JSON.stringify(first.drawing.edges), names[i] + ': every link what it was, every sharer in the pill it was in');
    }
    assert(shared >= 10, 'the fixtures have notes that share a pill: ' + shared);
    // a link the file draws through a pill stays one though a straight line from its note is clear, and one it draws as an arrow stays an arrow
    var d = fixture('acme'), f = await planOf(d), rows = rowsOf(f.drawing);
    var viaOf = function (rs) { var o = {}; rs.rows.forEach(function (r) { if (r.connection) o[r.key] = r.connection.via ? r.connection.via.to.id : null; }); return o; };
    var before = viaOf(rows), made = f.drawing.edges.filter(function (e) { return e.place && e.place.pill; });
    assert(made.length >= 20 && Object.keys(before).some(function (k) { return before[k] == null; }), 'the file has both');
    var edited = JSON.parse(JSON.stringify(d)); edited.nodes.push(nodeOf(note('Extra', 'Operations'))); edited.edges.push({ from: 'Extra', to: 'Legal' });
    var r = await planOf(edited, { current: rows }), pills = function (x) { var o = {}; x.drawing.edges.forEach(function (e) { o[e.from + '>' + e.to] = e.place && e.place.pill ? JSON.stringify(e.place.pill) : 'arrow'; }); return o; };
    var p0 = pills(f), p1 = pills(r);
    eq(Object.keys(p0).filter(function (k) { return p0[k] !== p1[k]; }), [], 'nothing of the file\'s links changed for a note added');
  });

  await test('drawing again in place: a note a person moved onto another stays, its pills come with it, the note it covers is put down again, and nothing else moves', async function () {
    var d = fixture('acme'), first = await planOf(d), rows = rowsOf(first.drawing), abs0 = absoluteOf(first.drawing);
    var by = {}; first.drawing.nodes.forEach(function (n) { by[n.key] = n; });
    // a note with pills of its own, and another note beside it in the same container
    var owners = {}; first.drawing.edges.forEach(function (e) { if (e.place && e.place.pill && e.place.pill.at && by[e.from].kind !== 'frame') owners[e.from] = (owners[e.from] || 0) + 1; });
    var A = Object.keys(owners).filter(function (k) { return owners[k] >= 2; }).sort()[0];
    var B = first.drawing.nodes.filter(function (n) { return n.key !== A && n.kind !== 'frame' && n.in === by[A].in && !owners[n.key]; }).map(function (n) { return n.key; }).sort()[0];
    assert(A && B, 'a note with pills and one beside it: ' + A + ' ' + B);
    var target = [abs0[B].x + 10, abs0[B].y + 6];
    var r = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === A) x.at[0] = target.slice(); }); }), changed: new Map([[A, new Set(['moved'])]]) });
    var rep = r.report.boards.root, abs = absoluteOf(r.drawing);
    eq([abs[A].x, abs[A].y, abs[A].w, abs[A].h], [target[0], target[1], abs0[A].w, abs0[A].h], 'the note is where the person put it');
    eq([rep.afresh, rep.stop, rep.health.status], [false, 'clean', 'clean'], 'kept, and clean');
    eq(rep.held, [A], 'held');
    eq(rep.moved.map(function (m) { return m.key; }), [B], 'only the note it covers moved: ' + JSON.stringify(rep.moved));
    assert(/covered/.test(rep.moved[0].why), 'and the report says why: ' + rep.moved[0].why);
    var still = Object.keys(abs0).filter(function (k) { return k !== A && k !== B && JSON.stringify(abs0[k]) !== JSON.stringify(abs[k]); });
    eq(still, [], 'no other shape moved');
    // its pills are about it now, not where they were
    var mine = r.drawing.edges.filter(function (e) { return e.from === A && e.place && e.place.pill && e.place.pill.at; });
    assert(mine.length >= 2, 'it still has its pills');
    mine.forEach(function (e) {
      var pa = e.place.pill.at, f = e.place.pill.in ? abs[e.place.pill.in] : { x: 0, y: 0 }, px = f.x + pa[0], py = f.y + pa[1];
      assert(Math.abs(px - abs[A].x) < 800 && Math.abs(py - abs[A].y) < 800, 'its pill for ' + e.to + ' is about the note: ' + Math.round(px - abs[A].x) + ', ' + Math.round(py - abs[A].y));
    });
    // a second plan from what that drew, with the person\'s move no longer a change, holds as it is
    var again = await planOf(d, { current: rowsOf(r.drawing) });
    eq(JSON.stringify(again.drawing), JSON.stringify(r.drawing), 'drawn again, it is as it is');
  });

  await test('drawing again in place: a note a person put on another inside a frame stays, the frame grows as little as it must, and the shapes it reaches are put down again', async function () {
    var d = pointsDigest(), first = await planOf(d), rows = rowsOf(first.drawing), abs0 = absoluteOf(first.drawing);
    var A = 'P1', B = 'P2', target = [abs0[B].x + 12, abs0[B].y + 8];
    var r = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === A) x.at[0] = target.slice(); }); }), changed: new Map([[A, new Set(['moved'])]]) });
    var rep = r.report.boards.root, abs = absoluteOf(r.drawing);
    eq([abs[A].x, abs[A].y], target, 'the note is where the person put it');
    eq([rep.afresh, rep.health.status], [false, 'clean'], 'kept, and clean');
    assert(rep.moved.some(function (m) { return m.key === B && /covered/.test(m.why); }), 'the note it covers is put down again: ' + JSON.stringify(rep.moved));
    var f = abs.Points;
    ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'Plugin'].forEach(function (k) { var b = abs[k]; assert(b.x >= f.x && b.y >= f.y && b.x + b.w <= f.x + f.w && b.y + b.h <= f.y + f.h, k + ' is inside its frame'); });
    checkPlan(r.plan);
  });

  // a person drops a note of the tree document's Clients frame where they like, as a drag does (the first drawing's rows, the one note's place changed, the note
  // said to be changed), and the drawing is made again: `where` is the key of the shape whose top-left it goes to, or the point [x, y] it goes to
  // `real`: the app's own measure of the tree document (fixtures/tree.measure.json), and the drawing the driver makes of it: the document grouped by that measure's tightness
  // (`cluster`), then planned, and the redraw grouped over the document as it now is (the file's rows, what a person changed) before it is planned from them
  var TREE_MEASURE = JSON.parse(io.readText(base + '/test/fixtures/tree.measure.json'));
  var droppedOn = async function (moved, where, real, fixtureName) {
    var d = fixture(fixtureName || 'tree'), changed = new Map([[moved, new Set(['moved'])]]);
    var planned = function (g, opts) {
      if (!real) return planOf(g, opts);
      return planm.planGraph(g, function (m) { return sizes.sizesFrom(m, TREE_MEASURE); }, Object.assign({ refused: sizes.refusedEdges(TREE_MEASURE) }, opts || {}), elk);
    };
    var first = await planned(real ? clusterm.clusterGraph(d, TREE_MEASURE, { kinds: KINDS }).graph : d), abs0 = absoluteOf(first.drawing);
    var at = typeof where === 'string' ? [abs0[where].x, abs0[where].y] : typeof where[0] === 'string' ? [abs0[where[0]].x + where[1], abs0[where[0]].y + where[2]] : where;   // a key, a point, or [key, dx, dy]
    var rows = rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === moved) x.at[0] = at.slice(); }); });
    var g = real ? clusterm.clusterGraph(d, TREE_MEASURE, { kinds: KINDS, current: rows, changed: changed }).graph : d;
    var r = await planned(g, { current: rows, changed: changed }), abs = absoluteOf(r.drawing);
    var was = Object.assign({}, abs0); was[moved] = Object.assign({}, abs0[moved], { x: at[0], y: at[1] });
    var by = {}; first.drawing.nodes.forEach(function (n) { by[n.key] = n; });
    return { first: first, r: r, rep: r.report.boards.root, abs0: was, abs: abs, kind: function (k) { return by[k].kind; } };
  };
  var same = function (a, b) { return Math.abs(a.x - b.x) <= 0.5 && Math.abs(a.y - b.y) <= 0.5 && Math.abs(a.w - b.w) <= 0.5 && Math.abs(a.h - b.h) <= 0.5; };
  var inFrame = function (b, f) { return b.x >= f.x && b.y >= f.y && b.x + b.w <= f.x + f.w && b.y + b.h <= f.y + f.h; };
  var onBox = function (a, b) { return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h; };

  await test('drawing again in place: the note a person\'s note covers goes to the room the person left in the frame, so no frame grows and no other shape moves', async function () {
    var o = await droppedOn('Mobile app', 'Web app');
    eq(o.rep.moved.map(function (m) { return m.key; }), ['Web app'], 'only the note it covers moved: ' + JSON.stringify(o.rep.moved));
    assert(/covered/.test(o.rep.moved[0].why), 'and the report says a person\'s shape covered it: ' + o.rep.moved[0].why);
    eq(Object.keys(o.abs0).filter(function (k) { return k !== 'Web app' && !same(o.abs0[k], o.abs[k]); }), [], 'no frame grew or moved, no shape beside it moved');
    assert(inFrame(o.abs['Web app'], o.abs.Clients), 'it is inside its frame, in the room the person left: ' + JSON.stringify(o.abs['Web app']));
    assert(!onBox(o.abs['Web app'], o.abs['Mobile app']), 'not on the person\'s note');
    eq([o.rep.afresh, o.rep.health.status], [false, 'clean'], 'kept, and clean');
  });

  // the room a person's note left is as tight as the drawing had it: Clients' notes were packed by the document's own spacing, 34 units between Admin console's footprint (its
  // title's row and its pill) and Web app's, less than the 40 a put-down keeps between footprints; the covered note, once the mend cuts its link (the arrow would cross Web
  // app) into a pill, has a footprint as tall as Admin console's was and more. It takes the room at the least gap before the frame grows
  // the same case on the estimated measure and on the app's own (fixtures/tree.measure.json, what `canvas measure --tightness` answered for the tree document in DigestTests' test of
  // it, kept from its output folder): on the app's, the covered note's pill and the line to it lie just where the person's note puts its own below it, the room the note left
  var coveredTakesTheRoom = async function (real) {
    var o = await droppedOn('Admin console', 'Mobile app', real);
    eq(o.rep.moved.map(function (m) { return m.key; }), ['Mobile app'], 'only the note under the person\'s note moved: ' + JSON.stringify(o.rep.moved));
    eq(o.rep.moved[0].why, 'a person\'s shape covered it', 'and the report says why');
    eq(Object.keys(o.abs0).filter(function (k) { return k !== 'Mobile app' && !same(o.abs0[k], o.abs[k]); }), [], 'no frame grew or moved, no other shape moved (Clients and Gateway stay)');
    assert(inFrame(o.abs['Mobile app'], o.abs.Clients), 'it is inside its frame: ' + JSON.stringify(o.abs['Mobile app']));
    assert(!onBox(o.abs['Mobile app'], o.abs['Admin console']), 'not on the person\'s note');
    eq([o.rep.afresh, o.rep.health.status], [false, 'clean'], 'kept, and clean');
    // its link out of the frame is a pill now (the arrow would cross Web app), set beside it, inside the frame, and on no note
    var mine = o.r.drawing.edges.filter(function (e) { return e.from === 'Mobile app'; });
    assert(mine.length === 1 && mine[0].place && mine[0].place.pill && mine[0].place.pill.at, 'its link is a pill: ' + JSON.stringify(mine.map(function (e) { return e.place; })));
    var pa = mine[0].place.pill.at, pill = { x: o.abs.Clients.x + pa[0], y: o.abs.Clients.y + pa[1], w: 128, h: 40 };
    assert(inFrame(pill, o.abs.Clients), 'the pill is inside the frame');
    ['Web app', 'Admin console', 'Mobile app'].forEach(function (k) { assert(!onBox(pill, o.abs[k]), 'the pill is on no note: ' + k); });
  };
  await test('drawing again in place: a note a person drops on a note with a link out of the frame takes the room the person left, with its pill: only it moves, no frame grows or moves (estimated measure)', function () { return coveredTakesTheRoom(false); });
  await test('drawing again in place: a note a person drops on a note with a link out of the frame takes the room the person left, with its pill: only it moves, no frame grows or moves (the app\'s measure)', function () { return coveredTakesTheRoom(true); });

  // a person drags a note of a frame out to where it lies on no note of its board: the frame grows to hold it, and the shapes it then reaches are put down again, the
  // shapes the person's note covers none
  await test('drawing again in place: a shape put down again because a frame grew around a person\'s note is reported as "a frame grew", and none as covered', async function () {
    var o = await droppedOn('Web app', [1300, 650]);
    var whys = {}; o.rep.moved.forEach(function (m) { whys[m.key] = m.why; });
    var person = o.abs['Web app'];
    eq([person.x, person.y], [1300, 650], 'the note is where the person put it');
    assert(o.abs.Clients.w > o.abs0.Clients.w && o.abs.Clients.h > o.abs0.Clients.h && inFrame(person, o.abs.Clients), 'the frame grew to hold it: ' + JSON.stringify([o.abs0.Clients, o.abs.Clients]));
    ['Gateway', 'Backend'].forEach(function (k) { assert(!onBox(person, o.abs0[k]), 'the person\'s note lies on no note of its board: ' + k); });
    var grew = Object.keys(whys).filter(function (k) { return o.kind(k) !== 'frame' && !/container that moved/.test(whys[k]); });
    assert(grew.length >= 1, 'a frame grew and put a shape down again: ' + JSON.stringify(o.rep.moved));
    grew.forEach(function (k) { eq(whys[k], 'a frame grew', k + ': what the grown frame reached is not said to be covered by the person\'s note'); });
    eq(Object.keys(whys).filter(function (k) { return /covered/.test(whys[k]); }), [], 'none is said to be covered');
    eq([o.rep.afresh, o.rep.health.status], [false, 'clean'], 'kept, and clean');
  });

  // a document grouped by tightness has link weights 50 to 100 inside a group and 1 to 49 between groups (a lens document may give `layout.weight` too): the spot a redraw
  // puts a new note at weighs each placed neighbour's pull by its link's weight against the weights of the note's own links
  await test('drawing again in place: a new note linked to two notes far apart lands nearer the one its heavier link goes to, and where the links weigh the same it lands where it did before the weights counted', async function () {
    var nodes = [], edges = [];
    for (var k = 0; k < 8; k++) nodes.push(note('N' + k));
    for (var j = 0; j < 7; j++) edges.push({ from: 'N' + j, to: 'N' + (j + 1), weight: 60 });
    var d = digest(nodes, edges), first = await planOf(d), rows = rowsOf(first.drawing), abs0 = absoluteOf(first.drawing);
    var landed = async function (wLeft, wRight) {
      var added = JSON.parse(JSON.stringify(d));
      added.nodes.push(nodeOf(note('Newcomer')));
      added.edges.push(edgeOf({ from: 'Newcomer', to: 'N0', weight: wLeft }), edgeOf({ from: 'Newcomer', to: 'N7', weight: wRight }));
      var r = await planOf(added, { current: rows }), abs = absoluteOf(r.drawing), rep = r.report.boards.root;
      eq(Object.keys(abs0).filter(function (k) { return !same(abs0[k], abs[k]); }), [], wLeft + '/' + wRight + ': no shape of the file moved');
      eq([rep.health.status, rep.afresh], ['clean', false], wLeft + '/' + wRight + ': clean, and kept');
      var toLeft = Math.hypot(abs.Newcomer.x - abs.N0.x, abs.Newcomer.y - abs.N0.y), toRight = Math.hypot(abs.Newcomer.x - abs.N7.x, abs.Newcomer.y - abs.N7.y);
      return { x: abs.Newcomer.x, y: abs.Newcomer.y, toLeft: toLeft, toRight: toRight };
    };
    var heavyLeft = await landed(90, 10), heavyRight = await landed(10, 90), tight = await landed(60, 20);
    assert(heavyLeft.toLeft + 200 < heavyLeft.toRight, 'the heavy link on the left: nearer the left one (' + Math.round(heavyLeft.toLeft) + ' against ' + Math.round(heavyLeft.toRight) + ')');
    assert(heavyRight.toRight + 200 < heavyRight.toLeft, 'the heavy link on the right: nearer the right one (' + Math.round(heavyRight.toRight) + ' against ' + Math.round(heavyRight.toLeft) + ')');
    assert(tight.toLeft + 100 < tight.toRight, 'and the same for weights of a group and between groups');
    // each weight alike, whatever it is (past the cap of 3 a link's pull had, and under it): where the unweighted score put it, the middle of the two
    var alike = [await landed(1, 1), await landed(50, 50), await landed(80, 80), await landed(100, 100)];
    alike.forEach(function (p, i) { eq([Math.round(p.x), Math.round(p.y)], [1288, 709], 'equal weights, the same place as before the weights counted: ' + [1, 50, 80, 100][i]); });
  });

  // what a redraw puts down keeps what the first drawing kept: the notes an arrow joins keep the gap an arrow needs between their boxes (the tight pass the frame's own room is
  // taken at keeps the least gap between footprints only), a covered note's links weigh as they were written (an arrow does not weigh twice a pill), and a pill the
  // put-down gives a place stays inside the frame it is in
  var drawnBetween = function (o) {
    var out = [], by = {};
    o.r.drawing.nodes.forEach(function (n) { by[n.key] = n; });
    o.r.drawing.edges.forEach(function (e) { if (!(e.place && e.place.pill) && by[e.from] && by[e.to] && by[e.from].in === by[e.to].in) out.push([e.from, e.to]); });
    return out;
  };
  var gapOf = function (a, b) { return Math.max(b.x - (a.x + a.w), a.x - (b.x + b.w), b.y - (a.y + a.h), a.y - (b.y + b.h)); };
  await test('drawing again in place: a note dropped on another leaves the notes an arrow joins at least a gap apart, and the board clean', async function () {
    var o = await droppedOn('Finance', ['People', 10, 6], false, 'acme');
    var near = drawnBetween(o).filter(function (p) { return gapOf(o.abs[p[0]], o.abs[p[1]]) < 40 - 0.5; });
    eq(near.map(function (p) { return p.join(' -> ') + ' ' + gapOf(o.abs[p[0]], o.abs[p[1]]); }), [], 'no two notes of one container an arrow joins are under 40 apart');
    eq([o.rep.afresh, o.rep.health.status], [false, 'clean'], 'kept, and clean');
  });
  // the tight pass keeps an arrow's two notes a gap apart (box to box, where the arrow runs) and the footprints, their titles' rows and pills, the least gap: the room the
  // person left is taken wherever the arrow has its room, and a frame grows only where it has none (Login on Tokens in the tree still grows Auth: the spot beside Passwords
  // has Tokens' arrow to Services over Passwords)
  var linkedUnder = function (o, who) { return drawnBetween(o).filter(function (p) { return p.indexOf(who) < 0 && gapOf(o.abs[p[0]], o.abs[p[1]]) < 40 - 0.5; }); };
  await test('drawing again in place: a note dropped on another takes the room the person left wherever its arrows have theirs, and notes an arrow joins are a gap apart box to box', async function () {
    var o = await droppedOn('CTO', ['Payments team', 10, 6], false, 'acme'), grown = [];
    o.first.drawing.nodes.forEach(function (n) { if (n.kind === 'frame') { var f = absoluteOf(o.first.drawing)[n.key], g = o.abs[n.key]; if (g.w > f.w + 0.5 || g.h > f.h + 0.5) grown.push(n.key + ' ' + f.w + 'x' + f.h + ' -> ' + g.w + 'x' + g.h); } });
    eq(grown, [], 'no frame grew: the covered note took the room the person left');
    eq(linkedUnder(o, 'CTO'), [], 'no two notes of one container an arrow joins, the person\'s own aside, are under 40 apart');
    eq([o.rep.afresh, o.rep.health.status], [false, 'clean'], 'kept, and clean');
    var s = await droppedOn('Search index', ['Catalog DB', 10, 6]);
    eq([s.abs.Stores.w, s.abs.Stores.h], [722, 900], 'Stores grows by no more than the note the person put over its edge');
    eq(linkedUnder(s, 'Search index'), [], 'and no two notes an arrow joins, the person\'s own aside, are under 40 apart');
    eq([s.rep.afresh, s.rep.health.status], [false, 'clean'], 'kept, and clean');
    var l = await droppedOn('Login', ['Tokens', 10, 6]);
    eq(linkedUnder(l, 'Login'), [], 'Login on Tokens: no two notes an arrow joins, the person\'s own aside, are under 40 apart');
    eq([l.rep.afresh, l.rep.health.status], [false, 'clean'], 'kept, and clean');
  });
  await test('drawing again in place: a covered note whose links are arrows and pills of one weight lands where it did before the weights counted', async function () {
    var o = await droppedOn('Passwords', 'Tokens');
    eq([Math.round(o.abs.Tokens.x * 100) / 100, Math.round(o.abs.Tokens.y * 100) / 100], [1172.62, 1230.75], 'Tokens, covered, where the unweighted score put it');
    eq([o.rep.afresh, o.rep.health.status], [false, 'clean'], 'kept, and clean');
  });
  await test('drawing again in place: the pill of a covered note\'s link, shared with another note, stays inside its frame, and the board is clean', async function () {
    var o = await droppedOn('Orders DB', ['Cache', 10, 6]);
    eq([o.rep.afresh, o.rep.health.status, o.rep.conflicts || []], [false, 'clean', []], 'kept, and clean');
    var pills = o.r.drawing.edges.filter(function (e) { return e.place && e.place.pill && e.place.pill.at; });
    pills.forEach(function (e) {
      var p = e.place.pill, f = p.in ? o.abs[p.in] : null;
      if (f) assert(p.at[0] >= 0 && p.at[1] >= 0 && p.at[0] + 128 <= f.w && p.at[1] + 40 <= f.h, 'the pill of ' + e.from + ' -> ' + e.to + ' is inside ' + p.in + ': ' + JSON.stringify(p.at));
    });
  });

  await test('drawing again in place: two shapes a person put on one another both stay, and the board is kept with what is left said, not laid out afresh', async function () {
    var d = digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'C' }, { from: 'B', to: 'C' }]);
    var first = await planOf(d), abs0 = absoluteOf(first.drawing);
    var r = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'A') x.at[0] = [abs0.B.x + 20, abs0.B.y + 20]; }); }), changed: new Map([['A', new Set(['moved'])], ['B', new Set(['resized'])]]) });
    var rep = r.report.boards.root, abs = absoluteOf(r.drawing);
    eq([abs.A.x, abs.A.y, abs.B.x, abs.B.y], [abs0.B.x + 20, abs0.B.y + 20, abs0.B.x, abs0.B.y], 'both where they are');
    eq([rep.afresh, rep.stop, rep.held], [false, 'not clean', ['A', 'B']], 'kept, not clean, both held');
    assert(rep.conflicts.length >= 1 && /"A"/.test(rep.conflicts.join(' ')), 'the conflict is said: ' + JSON.stringify(rep.conflicts));
  });

  // two ranked frames of notes (bands) with links among them: a person moves one note of the lower band
  function bandsDigest() {
    var nodes = [], edges = [];
    ['Top', 'Low'].forEach(function (f, r) {
      nodes.push({ title: f, kind: 'frame', rank: r });
      var ring = [1, 2, 3, 4].map(function (i) { return f[0] + i; });
      ring.forEach(function (t, i) { nodes.push(note(t, f, 'a note\nof two lines')); edges.push({ from: t, to: ring[(i + 1) % 4] }); });
    });
    edges.push({ from: 'T1', to: 'L1' }, { from: 'T3', to: 'L3' });
    return digest(nodes, edges);
  }

  await test('drawing again in place: what a redraw leaves is read back as it is, so the next redraw draws it the same: a person\'s move in a ranked band, a longer note, a board left not clean, a frame made smaller', async function () {
    var d = bandsDigest(), first = await planOf(d), abs0 = absoluteOf(first.drawing);
    var again = async function (r, doc) { return planOf(doc || d, { current: rowsOf(r.drawing) }); };
    var same = function (a, b, m) { eq(JSON.stringify(a.drawing), JSON.stringify(b.drawing), m); };
    // a note of a ranked band moved by hand: held, and the band is not laid out again by its ranks when the move is no longer a change
    var onL3 = [abs0.L3.x + 30, abs0.L3.y + 20];
    var moved = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'L2') x.at[0] = onL3.slice(); }); }), changed: new Map([['L2', new Set(['moved'])]]) });
    var abs = absoluteOf(moved.drawing);
    eq([abs.L2.x, abs.L2.y], onL3, 'the note is where the person put it, on another, which is put down again');
    same(await again(moved), moved, 'the ranked band is read back as it is');
    // moved, and its text longer: it takes the size its text has, where it stands, and drawn again nothing moves
    var longer = JSON.parse(JSON.stringify(d));
    longer.nodes.find(function (n) { return n.key === 'L2'; }).props.text = new Array(40).join('A longer text\n');
    var grown = await planOf(longer, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'L2') x.at[0][0] += 250; }); }), changed: new Map([['L2', new Set(['moved'])]]) });
    var ga = absoluteOf(grown.drawing);
    eq([ga.L2.x, ga.L2.y, ga.L2.h > abs0.L2.h], [abs0.L2.x + 250, abs0.L2.y, true], 'it is where it was put, and as tall as its text');
    same(await again(grown, longer), grown, 'drawn again, a longer note that was moved stays');
    // a board a redraw leaves not clean (two shapes of a person's on each other) is drawn again with none of the notes moved
    var e = digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'C' }, { from: 'B', to: 'C' }]), ef = await planOf(e), ea = absoluteOf(ef.drawing);
    var tangled = await planOf(e, { current: rowsOf(ef.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'A') x.at[0] = [ea.B.x + 20, ea.B.y + 20]; }); }), changed: new Map([['A', new Set(['moved'])], ['B', new Set(['resized'])]]) });
    eq(tangled.report.boards.root.stop, 'not clean', 'not clean');
    var t2 = await planOf(e, { current: rowsOf(tangled.drawing) }), t2a = absoluteOf(t2.drawing), t1a = absoluteOf(tangled.drawing);
    eq(['A', 'B', 'C'].map(function (k) { return [t2a[k].x, t2a[k].y]; }), ['A', 'B', 'C'].map(function (k) { return [t1a[k].x, t1a[k].y]; }), 'drawn again, none of the notes moves, though nothing says whose they are');
    // a frame a person made smaller than what it holds stays at their size on the redraw after that too
    var p = pointsDigest(), pf = await planOf(p), pa = absoluteOf(pf.drawing), fr = pa.Points;
    var small = await planOf(p, { current: rowsOf(pf.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'Points') x.at[1] = [fr.w - 120, fr.h - 100]; }); }), changed: new Map([['Points', new Set(['resized'])]]) });
    eq([absoluteOf(small.drawing).Points.w, absoluteOf(small.drawing).Points.h], [fr.w - 120, fr.h - 100], 'the frame has the size they gave it');
    same(await planOf(p, { current: rowsOf(small.drawing) }), small, 'and is read back at it');
  });

  await test('drawing again in place: a shape a person carried into another container stays there, which the drawing says, and the report says what was carried', async function () {
    var d = digest([{ title: 'F1', kind: 'frame' }, { title: 'F2', kind: 'frame' }, note('X', 'F1'), note('Y', 'F1'), note('Z', 'F2'), note('W', 'F2')], [{ from: 'X', to: 'Y' }, { from: 'Z', to: 'W' }, { from: 'X', to: 'Z' }]);
    var first = await planOf(d), abs0 = absoluteOf(first.drawing), f2 = abs0.F2;
    var at = [f2.x + 30, f2.y + f2.h + 200];
    var r = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'X') { delete x.in; x.inside = []; x.at[0] = at.slice(); } }); }), changed: new Map([['X', new Set(['frame', 'moved'])]]) });
    var xn = r.drawing.nodes.find(function (n) { return n.key === 'X'; }), ra = absoluteOf(r.drawing);
    eq([xn.in || null, ra.X.x, ra.X.y], [null, at[0], at[1]], 'X is on the board where the person put it, not in its frame');
    eq(r.report.carried, [{ key: 'X', in: null }], 'the report says so');
    // not a change of container (no frame or board in what changed): the document says where it is
    var kept = await planOf(d, { current: rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'X') { delete x.in; x.inside = []; x.at[0] = at.slice(); } }); }), changed: new Map([['X', new Set(['moved'])]]) });
    eq(kept.drawing.nodes.find(function (n) { return n.key === 'X'; }).in, 'F1', 'the document\'s container otherwise');
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

  await test('a pinned node (layout.pill: true) has a pill only where a pill is needed: none for an arrow on its board, one for a link from another board', async function () {
    var pinned = { title: 'B', kind: 'sticky-note', text: 'b', pill: true };
    var lone = await planOf(digest([note('A'), pinned], [{ from: 'A', to: 'B' }]));
    eq(lone.drawing.edges.filter(pillOf).length, 0, 'A -> B is an arrow');
    var far = await planOf(digest([{ title: 'Sub', kind: 'subboard' }, note('A', 'Sub'), pinned], [{ from: 'A', to: 'B' }]));
    assert(far.plan.boards.some(function (b) { return b.pills.some(function (p) { return p.for === 'B'; }); }), 'a pill from another board stands for it');
  });

  await test('props are the app\'s: a node whose props say private: true is laid out as any other, and the document keeps what it says', async function () {
    // whether a pill may stand for a shape is the app\'s to say (canvas apply refuses one for a private node, by key); the layout reads no props
    var plain = fixture('acme'), marked = fixture('acme');
    marked.nodes.forEach(function (n) { if (n.key === 'Platform team') n.props = Object.assign({}, n.props, { private: true }); });
    var a = await planOf(plain), b = await planOf(marked);
    eq(JSON.stringify(b.plan.boards), JSON.stringify(a.plan.boards), 'the same boards and pills');
    eq(b.drawing.nodes.find(function (n) { return n.key === 'Platform team'; }).props.private, true, 'its props passed through');
  });

  await test('what the report says: no word of what is public, in the plan, the report or the summary', async function () {
    var names = ['acme', 'tree', 'flat60', 'spine', 'frames', 'typed'];
    for (var i = 0; i < names.length; i++) {
      var r = await planOf(fixture(names[i]));
      eq([r.report.public, r.report.publicWhy, r.plan.public], [undefined, undefined, undefined], names[i] + ': nothing is reported public');
      assert(!/public/.test(clim.summarize(r)), names[i] + ': the summary says nothing of public');
    }
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
    assert(/\nhealth: [01] of 1 board\(s\) clean; \d+ crossings, \d+ lines over shapes, \d+ shapes on top of others/.test(summary), 'the summary says how many boards are clean: ' + summary);
    assert(/\ncut: \d+ of \d+ links made pills/.test(summary), 'and how many links were cut: ' + summary);
    var drawing = JSON.parse(mem.files['/out/drawing.json']), report = JSON.parse(mem.files['/out/report.json']);
    eq(drawing.nodes.length, 29); eq(drawing.drawing, 'acme'); assert(report.totals && report.public === undefined && report.view.w === 1440 && report.timings.engine === 'test', 'report.json');
    assert(report.health && report.health.boards === 1 && report.health.margin === 8 && /^(clean|not clean)$/.test(report.boards.root.health.status), 'report.json has each board\'s health and the totals: ' + JSON.stringify(report.health));
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
    assert(/THE CUT/.test(threw), 'the usage');
    threw = ''; try { await clim.run(['plan', '/g.json', '/m.json', '/out', '--kinds', KINDS_PATH, '--mess', '0.5'], mem.io); } catch (e) { threw = e.message; }
    assert(/unknown option --mess/.test(threw), 'the dial is gone: ' + threw);
  });

  await test('--current is read from a file: the plan starts from where the drawing\'s shapes are', async function () {
    var d = fixture('acme'), first = await planOf(d);
    var mem = memory({ '/g.json': JSON.stringify(d), '/m.json': JSON.stringify(measureOf(d)), '/c.json': JSON.stringify(rowsOf(first.drawing, function (rs) { rs[5].at[0][0] += 13; rs[5].at[0][1] += 5; })) });
    await clim.run(['plan', '/g.json', '/m.json', '/o', '--kinds', KINDS_PATH, '--current', '/c.json'], mem.io);
    var drawn = JSON.parse(mem.files['/o/drawing.json']);
    assert(JSON.stringify(drawn.nodes.map(function (n) { return n.place; })) !== JSON.stringify(first.drawing.nodes.map(function (n) { return n.place; })), 'a hand-moved shape moves the layout');
  });

  await test('--changed is read from a file, and the summary says what a redraw did: the boards as they were, shapes put down, a person\'s shapes held', async function () {
    var d = fixture('acme'), first = await planOf(d), abs0 = absoluteOf(first.drawing), by = {};
    first.drawing.nodes.forEach(function (n) { by[n.key] = n; });
    var A = first.drawing.nodes.filter(function (n) { return n.kind !== 'frame'; })[3].key, B = first.drawing.nodes.filter(function (n) { return n.kind !== 'frame' && n.key !== A && n.in === by[A].in; })[0].key;
    var cur = rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === A) x.at[0] = [abs0[B].x + 10, abs0[B].y + 6]; }); });
    var changed = { rows: [Object.assign({}, cur.rows.find(function (x) { return x.key === A; }), { changed: ['moved'] })] };
    var mem = memory({ '/g.json': JSON.stringify(d), '/m.json': JSON.stringify(measureOf(d)), '/c.json': JSON.stringify(cur), '/h.json': JSON.stringify(changed) });
    await clim.run(['plan', '/g.json', '/m.json', '/o', '--kinds', KINDS_PATH, '--current', '/c.json', '--changed', '/h.json'], mem.io);
    var drawn = JSON.parse(mem.files['/o/drawing.json']), rep = JSON.parse(mem.files['/o/report.json']);
    eq(drawn.nodes.find(function (n) { return n.key === A; }).place.at, [abs0[B].x + 10 - (by[A].in ? abs0[by[A].in].x : 0), abs0[B].y + 6 - (by[A].in ? abs0[by[A].in].y : 0)], 'the shape a person moved is where they put it');
    var said = mem.printed.join('\n');
    assert(/redraw: \d+ board\(s\) as the file has them, \d+ with \d+ shape\(s\) put down, 0 laid out afresh/.test(said) && /1 shape\(s\) a person put where they are held/.test(said), 'the summary says what it did: ' + said);
    assert(!/so each board's links are planar|put back as arrows/.test(said), 'and says nothing that does not apply to a redraw');
    eq(rep.redraw, true);
    var hold = await clim.run(['changed-by', '/g.json'], mem.io);
    assert(/^:changed\("/.test(mem.printed[mem.printed.length - 1]), 'the query that asks: ' + mem.printed[mem.printed.length - 1]);
  });

  // ---- health: every board measured on its drawing ----
  // a drawing by hand: each node's box in its board's coordinates (`at`: key -> [x, y, w, h], from its frame's top-left when it is in one) and,
  // by an edge's place in the list, the pill it goes through ({at, in} or {share})
  function drawnBy(d, at, pills) {
    return {
      drawing: d.drawing,
      nodes: d.nodes.map(function (n) { var b = at[n.key]; return Object.assign({}, n, { place: { at: [b[0], b[1]], size: [b[2], b[3]] } }); }),
      edges: d.edges.map(function (e, i) { return pills && pills[i] ? Object.assign({}, e, { place: { pill: pills[i] } }) : Object.assign({}, e); }),
    };
  }
  function healthBy(d, at, pills, opts) {
    var m = model.buildModel(d), me = helpers.estimateMeasure(m, d);
    if (opts && opts.tweak) opts.tweak(me);   // the measurement as a test wants it (a title's width)
    return healthm.healthOf(m, drawnBy(d, at, pills), sizes.sizesFrom(m, me), Object.assign({ view: { w: 1440, h: 960 } }, opts || {}));
  }

  await test('health: two arrows that cross are a crossing; two that share an end are not', async function () {
    var at = { A: [0, 0, 100, 100], B: [400, 400, 100, 100], C: [400, 0, 100, 100], D: [0, 400, 100, 100] };
    var h = healthBy(digest([note('A'), note('B'), note('C'), note('D')], [{ from: 'A', to: 'B' }, { from: 'C', to: 'D' }]), at).boards.root;
    eq([h.status, h.crossings, h.overShapes, h.onTop], ['not clean', 1, 0, 0], 'the diagonals cross');
    eq(h.examples, ['"A" -> "B" crosses "C" -> "D"']);
    h = healthBy(digest([note('A'), note('B'), note('C'), note('D')], [{ from: 'A', to: 'B' }, { from: 'C', to: 'A' }]), at).boards.root;
    eq([h.status, h.crossings, h.links, h.cut, h.pills], ['clean', 0, 2, 0, 0], 'lines that meet at A cross nothing');
  });

  await test('health: a line that passes within 8 units of a shape runs over it; one 9 units off does not', async function () {
    var d = digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'B' }]), untitled = { tweak: function (me) { me.nodes.C.above = 0; } };
    var near = healthBy(d, { A: [0, 0, 100, 100], B: [600, 0, 100, 100], C: [300, 57, 100, 100] }, null, untitled).boards.root;
    eq([near.status, near.overShapes], ['not clean', 1], 'seven units below the line');
    eq(near.examples, ['"A" -> "B" runs over "C"']);
    var off = healthBy(d, { A: [0, 0, 100, 100], B: [600, 0, 100, 100], C: [300, 59, 100, 100] }, null, untitled).boards.root;
    eq([off.status, off.overShapes], ['clean', 0], 'nine units below it');
  });

  await test('health: a line over the room another shape\'s title takes runs over that shape; over its own end\'s title it does not', async function () {
    var d = digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'B' }]);
    var h = healthBy(d, { A: [0, 0, 100, 100], B: [600, 0, 100, 100], C: [300, 70, 100, 100] }).boards.root;
    eq([h.status, h.overShapes, h.examples], ['not clean', 1, ['"A" -> "B" runs over "C"']], 'twenty units above C, in the room its title takes (30 here)');
    h = healthBy(digest([note('A'), note('B')], [{ from: 'A', to: 'B' }]), { A: [0, 0, 100, 100], B: [0, 300, 100, 100] }).boards.root;
    eq([h.status, h.overShapes], ['clean', 0], 'into B from above, over B\'s own title');
    // the room is as wide as the title, where the measurement says how wide that is
    var p = digest([note('N'), note('P'), note('T')], [{ from: 'P', to: 'T' }]), at = { N: [0, 0, 300, 100], P: [800, -100, 100, 100], T: [800, 500, 100, 100] };
    eq(healthBy(p, at, { 0: { at: [200, -41] } }).boards.root.onTop, 1, 'a pill over the right of a title row the shape\'s width');
    eq(healthBy(p, at, { 0: { at: [200, -41] } }, { tweak: function (me) { me.nodes.N.titleWidth = 100; } }).boards.root.onTop, 0, 'clear of a title 100 wide');
  });

  await test('health: an arc that bends around a shape runs over nothing; the straight line runs over it', async function () {
    var d = digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'B' }]), at = { A: [0, 0, 100, 100], B: [600, 0, 100, 100], C: [300, 20, 100, 60] };
    eq(healthBy(d, at).boards.root.overShapes, 1, 'straight');
    eq(healthBy(d, at, null, { bendOf: function () { return 150; } }).boards.root.overShapes, 0, 'bent 150 units, below it');
    // the arc bulges to the side the app's ArrowGeometry puts a positive bend: along (-dy, dx), below a line drawn left to right
    var box = function (b) { return { x: b[0], y: b[1], w: b[2], h: b[3] }; }, path = geomm.arrowPath(box(at.A), box(at.B), 150, 16);
    assert(path.length > 2 && path.every(function (p) { return p[1] >= 50 - 1e-6; }) && Math.max.apply(null, path.map(function (p) { return p[1]; })) > 190, 'below: ' + JSON.stringify(path));
  });

  await test('health: a note\'s lines into its own pills over its other pills fail nothing; another\'s line over a pill does, and crosses', async function () {
    var nodes = [note('H'), note('T1'), note('T2'), note('S'), note('U')], at = { H: [0, 0, 100, 100], T1: [2000, 0, 100, 100], T2: [2000, 400, 100, 100], S: [200, 300, 78, 100], U: [200, -400, 78, 100] };
    var pills = { 0: { at: [200, 40] }, 1: { at: [400, 40] } };
    var h = healthBy(digest(nodes, [{ from: 'H', to: 'T1' }, { from: 'H', to: 'T2' }]), at, pills).boards.root;
    eq([h.status, h.overOwnPills, h.overShapes, h.crossings, h.pills, h.links, h.cut], ['clean', 1, 0, 0, 2, 2, 2], 'H\'s line to its far pill runs over its near one: counted apart');
    h = healthBy(digest(nodes, [{ from: 'H', to: 'T1' }, { from: 'H', to: 'T2' }, { from: 'S', to: 'U' }]), at, pills).boards.root;
    eq([h.status, h.overOwnPills, h.overShapes, h.crossings, h.links, h.cut], ['not clean', 1, 1, 1, 3, 2], 'S\'s arrow runs over H\'s pill and crosses H\'s line to the other');
    eq(h.examples, ['"H" -> its pill for "T2" crosses "S" -> "U"', '"S" -> "U" runs over the pill for "T1" beside "H"']);
  });

  await test('health: a note\'s line over a pill it shares is its own; over one it doesn\'t use, it runs over a shape', async function () {
    var nodes = [note('H'), note('S'), note('T1'), note('T2')], at = { H: [0, -300, 100, 100], S: [0, 0, 100, 100], T1: [2000, 0, 100, 100], T2: [2000, 400, 100, 100] };
    var pills = { 0: { at: [200, 40] }, 1: { at: [400, 40] }, 2: { share: 'H' }, 3: { share: 'H' } };
    var h = healthBy(digest(nodes, [{ from: 'H', to: 'T1' }, { from: 'H', to: 'T2' }, { from: 'S', to: 'T2' }]), at, pills).boards.root;
    eq([h.status, h.overShapes, h.overOwnPills, h.pills, h.links, h.cut], ['not clean', 1, 0, 2, 3, 3], 'S uses only H\'s pill for T2, and its line runs over the one for T1');
    eq(h.examples, ['"S" -> the pill for "T2" beside "H" runs over the pill for "T1" beside "H"']);
    h = healthBy(digest(nodes, [{ from: 'H', to: 'T1' }, { from: 'H', to: 'T2' }, { from: 'S', to: 'T2' }, { from: 'S', to: 'T1' }]), at, pills).boards.root;
    eq([h.status, h.overShapes, h.overOwnPills, h.pills, h.links, h.cut], ['clean', 0, 1, 2, 4, 4], 'S shares both: its own');
  });

  await test('health: the second arrow between two shapes is bowed apart from the first, as the app draws it', async function () {
    var at = { A: [0, 0, 100, 100], B: [600, 0, 100, 100], C: [300, 80, 100, 60] }, untitled = { tweak: function (me) { me.nodes.C.above = 0; } };
    var one = healthBy(digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'B' }]), at, null, untitled).boards.root;
    eq([one.status, one.overShapes], ['clean', 0], 'the straight arrow passes 30 units above C');
    var two = healthBy(digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'B' }, { from: 'B', to: 'A' }]), at, null, untitled).boards.root;
    eq([two.status, two.overShapes, two.crossings, two.links], ['not clean', 1, 0, 1], 'the second bows 34 units, into C');
    eq(two.examples, ['"B" -> "A" runs over "C"']);
    var other = healthBy(digest([note('A'), note('B'), note('C')], [{ from: 'B', to: 'A' }, { from: 'A', to: 'B' }]), at, null, untitled).boards.root;
    eq(other.examples, ['"A" -> "B" runs over "C"'], 'listed the other way round, the other arrow is the second, bowed the same way');
    var bent = healthBy(digest([note('A'), note('B'), note('C')], [{ from: 'A', to: 'B' }, { from: 'B', to: 'A' }]), at, null, Object.assign({ bendOf: function (e) { return e.from === 'B' ? 90 : 0; } }, untitled)).boards.root;
    eq([bent.status, bent.overShapes], ['clean', 0], 'an edge bent its own way keeps its bend: 90 units the other side');
  });

  await test('health: shapes on top: a note on a note, a pill on a note\'s title, a pill on a frame it is not in; shapes in their own frame are not', async function () {
    var h = healthBy(digest([note('N'), note('O')], []), { N: [0, 0, 100, 100], O: [50, 50, 100, 100] }).boards.root;
    eq([h.status, h.onTop, h.examples], ['not clean', 1, ['"N" is on "O"']], 'a note on a note');
    // the room a note's title takes above it (measure's above: 30 here) is the note's
    h = healthBy(digest([note('N'), note('P'), note('T')], [{ from: 'P', to: 'T' }]), { N: [0, 0, 300, 100], P: [800, -100, 100, 100], T: [800, 500, 100, 100] }, { 0: { at: [10, -41] } }).boards.root;
    eq([h.status, h.onTop, h.overShapes, h.examples], ['not clean', 1, 1, ['"P" -> its pill for "T" runs over "N"', 'the pill for "T" beside "P" is on the title of "N"']], 'a pill on a note\'s title, its line over the title too');
    h = healthBy(digest([note('N'), note('P'), note('T')], [{ from: 'P', to: 'T' }]), { N: [0, 0, 300, 100], P: [800, -100, 100, 100], T: [800, 500, 100, 100] }, { 0: { at: [10, -72] } }).boards.root;
    eq([h.status, h.onTop], ['clean', 0], 'clear of the title');
    // a note and a pill inside their frame are the frame's; a pill on the board over the frame is on it
    var nodes = [{ title: 'F', kind: 'frame' }, note('M', 'F'), note('Q'), note('T'), note('T2')];
    var at = { F: [0, 0, 400, 300], M: [40, 60, 100, 100], Q: [600, 100, 100, 100], T: [600, 600, 100, 100], T2: [900, 600, 100, 100] };
    h = healthBy(digest(nodes, [{ from: 'M', to: 'T2' }]), at, { 0: { at: [200, 60], in: 'F' } }).boards.root;
    eq([h.status, h.onTop, h.overShapes], ['clean', 0, 0], 'M and its pill in F');
    h = healthBy(digest(nodes, [{ from: 'M', to: 'T2' }, { from: 'Q', to: 'T' }]), at, { 0: { at: [200, 60], in: 'F' }, 1: { at: [350, 120] } }).boards.root;
    eq([h.status, h.onTop, h.overShapes, h.examples], ['not clean', 1, 0, ['"F" is on the pill for "T" beside "Q"']], 'Q\'s pill on F (its line stops at the pill, short of F)');
  });

  // a relationship type's two ends, which the app draws as one arc through it: P -> J -> C, J beside both on a line through them
  var throughNodes = [note('P'), note('C'), note('J'), note('D')], throughEdges = [{ from: 'P', to: 'J' }, { from: 'J', to: 'C' }];
  var lined = { tweak: function (me) { me.lines = [{ through: 'J', edges: [0, 1] }]; } };

  await test('sizes: the measure\'s lines through a node, each half by the ends of its edge; a line the model can\'t read is left out', async function () {
    var d = digest(throughNodes, throughEdges.concat([{ from: 'P', to: 'C' }])), m = model.buildModel(d), me = helpers.estimateMeasure(m, d);
    me.lines = [{ through: 'J', edges: [0, 1] }, { through: 'nobody', edges: [0, 1] }, { through: 'J', edges: [0, 9] }, { through: 'J', edges: [2] }];
    eq(sizes.sizesFrom(m, me).lines, [{ through: 'J', first: ['P', 'J'], second: ['J', 'C'] }]);
    eq(sizes.sizesFrom(m, helpers.estimateMeasure(m, d)).lines, [], 'none said, none');
  });

  await test('health: the two ends the measure says are one line are drawn as the app draws them, one arc through the node, here looping off the board', async function () {
    var d = digest(throughNodes, throughEdges), at = { P: [0, 0, 100, 100], C: [300, 0, 100, 100], J: [600, 60, 64, 24], D: [150, 7480, 100, 100] };
    var straight = healthBy(d, at).boards.root;
    eq([straight.status, straight.overShapes, straight.examples], ['not clean', 1, ['"P" -> "J" runs over "C"']], 'drawn straight, P\'s half would run through C');
    var arc = healthBy(d, at, null, lined).boards.root;
    eq([arc.status, arc.overShapes, arc.examples], ['not clean', 1, ['"P" -> "J" runs over "D"']], 'P\'s half goes the long way round the circle through the three middles: clear of C, over D');
    assert(arc.size[1] > 7500 && arc.fit < 0.15, 'the loop is the board\'s size: ' + JSON.stringify([arc.size, arc.fit]));
    // the arc as the app's ArrowThrough has it: P's half the long way round, away from C; J's half the short way, away from P
    var box = function (b) { return { x: b[0], y: b[1], w: b[2], h: b[3] }; }, mid = function (b) { return [b[0] + b[2] / 2, b[1] + b[3] / 2]; };
    var first = geomm.throughBend(mid(at.P), mid(at.J), mid(at.C)), second = geomm.throughBend(mid(at.J), mid(at.C), mid(at.P));
    assert(first > 7000 && second > 0 && second < 10, 'bends ' + first + ' and ' + second);
    var lowest = Math.max.apply(null, geomm.arrowPath(box(at.P), box(at.J), first, 16).map(function (p) { return p[1]; }));
    assert(Math.abs(lowest - 7535) < 1, 'the circle\'s foot, 7,535 down: ' + lowest);
  });

  await test('health: one arc only where the app draws one: straight with the node on the line, plain with a half through a pill', async function () {
    var d = digest(throughNodes, throughEdges);
    var on = healthBy(d, { P: [0, 0, 100, 100], C: [600, 0, 100, 100], J: [318, 38, 64, 24], D: [318, 300, 64, 64] }, null, lined).boards.root;
    eq([on.status, on.overShapes, on.size], ['clean', 0, [700, 394]], 'J on the line between P and C: straight');
    eq(geomm.isStraightThrough([50, 50], [350, 50.2], [650, 50]), true, 'a fifth of a unit off is on the line');
    eq(geomm.isStraightThrough([50, 50], [350, 50.3], [650, 50]), false, 'three tenths is off it');
    var at = { P: [0, 0, 100, 100], C: [300, 0, 100, 100], J: [600, 60, 64, 24], D: [150, 7480, 100, 100] };
    var cut = healthBy(d, at, { 0: { at: [140, 30] } }, lined).boards.root;
    eq([cut.status, cut.overShapes, cut.pills], ['clean', 0, 1], 'P\'s half into a pill beside P for J is no half of the line: both plain');
  });

  await test('health: every board of a plan has one, the report has the totals, and the same drawing measures the same', async function () {
    var d = fixture('tree'), r = await planOf(d);
    eq(Object.keys(r.report.boards).sort(), r.model.boards.slice().sort());
    r.model.boards.forEach(function (b) {
      var h = r.report.boards[b].health;
      assert(h && /^(clean|not clean)$/.test(h.status) && h.size.length === 2 && h.fit > 0 && h.fit <= 1 && h.seconds >= 0, b + ': ' + JSON.stringify(h));
      eq(h.status === 'clean', h.crossings + h.overShapes + h.onTop === 0, b + ': clean is nothing failing');
    });
    eq(r.report.health.boards, r.model.boards.length);
    var m = r.model, sz = sizes.sizesFrom(m, helpers.estimateMeasure(m, d));
    var once = healthm.healthOf(m, r.drawing, sz, { view: r.report.view }), again = healthm.healthOf(m, JSON.parse(JSON.stringify(r.drawing)), sz, { view: r.report.view });
    eq(once, again, 'the same drawing, read again');
    var noSeconds = function (o) { var c = JSON.parse(JSON.stringify(o)); Object.keys(c).forEach(function (b) { delete c[b].seconds; }); return c; };
    eq(noSeconds(once.boards), noSeconds(Object.fromEntries(r.model.boards.map(function (b) { return [b, r.report.boards[b].health]; }))), 'the plan\'s own');
  });


  // ---- clusters (cluster.mjs): each container's shapes grouped by how tightly their links hold them, the links between groups cut ----
  // the app's measure for a document with a `tightness` member: f(a, b) for each pair of notes on one board that a link joins (a < b), as the app answers it
  var tightMeasure = function (d, f, extra) {
    var m = model.buildModel(d), me = helpers.estimateMeasure(m, d), seen = {}, pairs = [];
    m.edges.forEach(function (e) {
      var a = m.node(e.from), b = m.node(e.to);
      if (e.from === e.to || a.board !== b.board || a.holds === 'shapes' || b.holds === 'shapes') return;
      var x = e.from < e.to ? e.from : e.to, y = e.from < e.to ? e.to : e.from, k = x + '\u0000' + y;
      if (seen[k]) return;
      seen[k] = 1;
      var p = { a: x, b: y, tightness: f(x, y) };
      if (a.board !== 'root') p.board = a.board;
      pairs.push(p);
    });
    pairs.sort(function (p, q) { return p.a < q.a ? -1 : p.a > q.a ? 1 : p.b < q.b ? -1 : p.b > q.b ? 1 : 0; });
    me.tightness = Object.assign({ model: 'test/embedding', texts: m.nodes.size, asked: 0, pairs: pairs }, extra || {});
    return me;
  };
  var FRAME = KINDS.filter(function (k) { return k.holds === 'shapes'; })[0].kind;
  // two lens frames of two notes each; a note beside each frame linked tightly to a note in it; one weak link between the frames
  var camps = function (mark) {
    var nodes = [{ title: 'F', kind: FRAME }, { title: 'G', kind: FRAME }, note('a', 'F'), note('b', 'F'), note('c'), note('x', 'G'), note('y', 'G'), note('z'), note('lone')];
    if (mark === 'never') nodes[6] = { title: 'y', kind: 'sticky-note', in: 'G', text: '', pill: false };
    var edges = [{ from: 'a', to: 'b' }, { from: 'a', to: 'c' }, { from: 'x', to: 'y' }, { from: 'x', to: 'z' }, Object.assign({ from: 'b', to: 'y' }, mark === 'direct' ? { direct: true } : {})];
    return digest(nodes, edges);
  };
  var campsTight = function (a, b) { return { 'a\u0000b': 0.9, 'a\u0000c': 1, 'x\u0000y': 0.9, 'x\u0000z': 1, 'b\u0000y': 0.1 }[a + '\u0000' + b]; };
  var edgeBy = function (g, from, to) { return g.edges.find(function (e) { return e.from === from && e.to === to; }); };
  var nodeBy = function (g, key) { return g.nodes.find(function (n) { return n.key === key; }); };

  await test('louvain: two triangles joined by one light link are two clusters, an equal gain goes to the lower cluster, and the same twice', async function () {
    var two = [[0, 1, 1], [1, 2, 1], [0, 2, 1], [3, 4, 1], [4, 5, 1], [3, 5, 1], [2, 3, 0.1]];
    var cl = clusterm.louvain(6, two);
    eq([cl[0] === cl[1], cl[1] === cl[2], cl[3] === cl[4], cl[4] === cl[5], cl[0] !== cl[3]], [true, true, true, true, true], 'two clusters: ' + cl);
    eq(clusterm.louvain(6, two), cl, 'the same twice');
    eq(clusterm.louvain(3, []), [0, 1, 2], 'no links: every node alone');
    // node 0 is linked once to each of two pairs, so it gains the same from either: it goes to the lower cluster (node 2's, not node 3's)
    var tie = clusterm.louvain(5, [[1, 2, 10], [3, 4, 10], [0, 2, 1], [0, 3, 1]]);
    eq([tie[0] === tie[2], tie[0] !== tie[3], tie[3] === tie[4]], [true, true, true], 'an equal gain goes to the lower community: ' + tie);
  });

  await test('clusters: the groups add nothing to the document: no frame, no shape changes container, nodes and edges keep their order; a lens frame is one item in what holds it and its own notes are grouped inside it; the document reads back', async function () {
    var d = camps(), r = clusterm.clusterGraph(d, tightMeasure(d, campsTight), { kinds: KINDS }), g = r.graph;
    eq(g.nodes, d.nodes, 'the lens\'s nodes, untouched and in their order: no frame added, none moved');
    eq(g.edges.map(function (e) { return e.from + '>' + e.to; }), d.edges.map(function (e) { return e.from + '>' + e.to; }), 'edges keep their order');
    eq(g.layout.clustered, { by: 'test/embedding' }, 'the note on the document');
    eq(model.buildModel(g).nodes.size, d.nodes.length, 'and it reads back');
    eq(Object.keys(r.report).sort(), ['boards', 'resolution', 'tightness', 'totals'], 'the report: no frames, kept, joined or dropped');
    eq(r.report.resolution, 1.5, 'groups of the usual size 1.5');
    eq(r.report.boards.length, 1, 'only boards with a link between two notes');
    eq(Object.keys(r.report.boards[0]).sort(), ['board', 'clusters', 'cut', 'levels', 'links', 'missing', 'notes'], 'a board\'s');
    eq([r.report.boards[0].clusters, r.report.boards[0].missing], [[3, 3], 0]);
    eq(r.report.boards[0].levels['b:root'], { F: 0, G: 1, c: 0, lone: 2, z: 1 }, 'each container\'s items and their group: a lens frame one item');
    eq(Object.keys(r.report.boards[0].levels).sort(), ['b:root', 'f:F', 'f:G'], 'a frame\'s own notes grouped inside it');
    eq(r.report.boards[0].levels['f:F'], { a: 0, b: 0 }, 'a frame\'s own notes make one group');
    eq(r.report.totals, { boards: 1, links: 5, cut: 1, missing: 0 });
    eq(clusterm.clusterLine(r.report), 'clusters: each container\'s shapes grouped by how tightly their links hold them, on 1 board(s); 1 of 5 linked pairs between two groups are cut before anything is placed, and come back as arrows where their line is clear (tightness: test/embedding)');
    // a plan lays it out as any document: the link between the groups is a pill before anything is placed, and counted so
    var p = await planOf(g), rep = p.report.boards.root;
    eq([rep.precut, p.report.totals.precut], [1, 1], 'one link cut between groups');
    eq(rep.stop, 'clean', 'clean');
    assert(/\ncut: \d+ of 5 links made pills: 1 between groups before anything was placed, /.test(clim.summarize(p)), clim.summarize(p));
  });

  await test('clusters: the resolution is an option, 1.5 by default: a higher one makes smaller groups, a lower one larger', async function () {
    var ring = digest(['n1', 'n2', 'n3', 'n4'].map(function (t) { return note(t); }), [{ from: 'n1', to: 'n2' }, { from: 'n2', to: 'n3' }, { from: 'n3', to: 'n4' }, { from: 'n4', to: 'n1' }]);
    var at = function (res) { var r = clusterm.clusterGraph(ring, measureOf(ring), res == null ? { kinds: KINDS } : { kinds: KINDS, res: res }); return [r.report.resolution, r.report.totals.cut]; };
    eq(at(), [1.5, 2], 'by default the four notes in a ring are two groups of two: two links between them');
    eq(at(1.5), at(), 'the default is 1.5');
    eq(at(0.5), [0.5, 0], 'larger groups: one');
    eq(at(2), [2, 4], 'smaller: each note alone, every link cut');
    eq(clusterm.louvain(4, [[0, 1, 1], [1, 2, 1], [2, 3, 1], [3, 0, 1]], 2), [0, 1, 2, 3], 'louvain takes it');
    [0, -1, NaN, 'x', Infinity].forEach(function (bad) {
      var threw = ''; try { clusterm.clusterGraph(ring, measureOf(ring), { kinds: KINDS, res: bad }); } catch (e) { threw = e.message; }
      assert(/the resolution of the groups is a number above 0/.test(threw), 'a bad resolution ' + bad + ': ' + threw);
    });
  });

  await test('clusters: a link between two clusters is cut, and a pair with a link marked direct or into a shape kept off pills is never cut: its weight is 50 to 100', async function () {
    var d = camps(), g = clusterm.clusterGraph(d, tightMeasure(d, campsTight), { kinds: KINDS }).graph;
    eq(edgeBy(g, 'b', 'y').layout, { weight: 1, cut: true }, 'cut: the one cut pair weighs 1');
    eq(['a>b', 'x>y', 'a>c', 'x>z'].map(function (k) { var e = edgeBy(g, k[0], k[2]); return [e.layout.weight, e.layout.cut]; }), [[50, undefined], [67, undefined], [83, undefined], [100, undefined]], 'the others weigh 50 to 100 by tightness, the tightest 100');
    ['direct', 'never'].forEach(function (mark) {
      var m = camps(mark), r = clusterm.clusterGraph(m, tightMeasure(m, campsTight), { kinds: KINDS }), e = edgeBy(r.graph, 'b', 'y');
      eq(e.layout.cut, undefined, mark + ': never cut');
      assert(e.layout.weight >= 50 && e.layout.weight <= 100, mark + ': weighs 50 to 100: ' + JSON.stringify(e.layout));
      eq(r.report.totals.cut, 0, mark + ': nothing cut');
    });
  });

  await test('clusters: the engine\'s weights are 1 to 49 for the cut pairs and 50 to 100 for the rest by tightness rank, rounded as the spike did: with 101 pairs kept, the one of rank 29 is 64', async function () {
    var nodes = [], edges = [], at = function (i) { return 'n' + (i < 10 ? '00' : i < 100 ? '0' : '') + i; };
    for (var i = 0; i < 102; i++) nodes.push(note(at(i)));
    for (var j = 0; j < 101; j++) edges.push({ from: at(j), to: at(j + 1), direct: true });
    var d = digest(nodes, edges), r = clusterm.clusterGraph(d, tightMeasure(d, function (a) { return +a.slice(1) / 1000; }), { kinds: KINDS });
    eq(edgeBy(r.graph, at(29), at(30)).layout.weight, 64, 'rank 29 of 101: 50 + round(50 * (29 / 100)), which is 14 and not 15');
    eq([edgeBy(r.graph, at(0), at(1)).layout.weight, edgeBy(r.graph, at(100), at(101)).layout.weight], [50, 100], 'the loosest kept pair 50, the tightest 100');
    eq(r.report.totals.cut, 0, 'all are direct: none cut');
    // the cut ones from 1 to 49: five pairs between clusters of a chain of notes that are not direct (the chain\'s ends, the loosest, are cut first)
    var w = []; r.graph.edges.forEach(function (e) { w.push(e.layout.weight); });
    assert(w.every(function (x) { return x >= 50 && x <= 100; }), 'every weight is in 50..100');
    var star = digest([note('hub'), note('p'), note('q'), note('r'), note('s'), note('t'), note('u')], [{ from: 'p', to: 'q' }, { from: 'q', to: 'r' }, { from: 'p', to: 'r' }, { from: 's', to: 't' }, { from: 't', to: 'u' }, { from: 's', to: 'u' }, { from: 'r', to: 's' }, { from: 'q', to: 't' }, { from: 'p', to: 'u' }]);
    var rs = clusterm.clusterGraph(star, tightMeasure(star, function (a, b) { return { 'p\u0000q': 0.9, 'q\u0000r': 0.8, 'p\u0000r': 0.7, 's\u0000t': 0.9, 't\u0000u': 0.8, 's\u0000u': 0.7, 'r\u0000s': 0.1, 'q\u0000t': 0.2, 'p\u0000u': 0.3 }[a + '\u0000' + b]; }), { kinds: KINDS });
    var cuts = rs.graph.edges.filter(function (e) { return e.layout && e.layout.cut; });
    eq(cuts.length, 3, 'the three links between the triangles');
    eq(cuts.map(function (e) { return e.layout.weight; }).sort(function (a, b) { return a - b; }), [1, 25, 49], 'the cut ones 1 to 49, the loosest 1, the tightest of them 49');
    eq([['r', 's'], ['q', 't'], ['p', 'u']].map(function (k) { return edgeBy(rs.graph, k[0], k[1]).layout.weight; }), [1, 25, 49], 'each cut link by its own: the loosest (0.1) 1, then 0.2, the tightest of them (0.3) 49');
  });

  await test('clusters: a link counts by its rank in its board and not by how tight it is, so the groups are the ranks\' and not those of the tightness itself', async function () {
    var names = ['a', 'b', 'c', 'd', 'e', 'f'], tight = { 'a\u0000c': 0.85, 'a\u0000f': 0.46, 'b\u0000f': 0.3, 'c\u0000e': 0.02, 'd\u0000e': 0.4, 'd\u0000f': 1 };
    var d = digest(names.map(function (t) { return note(t); }), [['a', 'c'], ['a', 'f'], ['b', 'f'], ['c', 'e'], ['d', 'e'], ['d', 'f']].map(function (l) { return { from: l[0], to: l[1] }; }));
    var r = clusterm.clusterGraph(d, tightMeasure(d, function (a, b) { return tight[a + '\u0000' + b]; }), { kinds: KINDS });
    var lv = r.report.boards[0].levels['b:root'];
    eq(lv, { a: 0, b: 1, c: 0, d: 2, e: 2, f: 1 }, 'grouped by the six links\' ranks, each 0.1 to 1');
    // the same links weighing what the tightness itself is would group otherwise: d, e and f together
    var items = names.map(function (n) { return n; }), ix = {}; items.forEach(function (n, i) { ix[n] = i; });
    var raw = clusterm.louvain(6, Object.keys(tight).map(function (k) { var p = k.split('\u0000'); return [ix[p[0]], ix[p[1]], tight[k]]; }), clusterm.RESOLUTION);
    assert(raw[ix.d] === raw[ix.f] && lv.d !== lv.f, 'by the raw tightness d and f are together, and by rank they are not: ' + raw);
  });

  await test('clusters: two links lifted onto one pair of items add up, and the sum decides the grouping', async function () {
    var FRAME2 = KINDS.filter(function (k) { return k.holds === 'shapes'; })[0].kind;
    var nodes = [{ title: 'F1', kind: FRAME2 }, { title: 'F2', kind: FRAME2 }, note('a', 'F1'), note('b', 'F1'), note('c', 'F2'), note('d', 'F2'), note('g'), note('h')];
    var tight = { 'a\u0000c': 0.4, 'b\u0000d': 0.36, 'g\u0000h': 0.56, 'b\u0000g': 0.37, 'd\u0000h': 0.57 };
    var d = digest(nodes, [['a', 'c'], ['b', 'd'], ['g', 'h'], ['b', 'g'], ['d', 'h']].map(function (l) { return { from: l[0], to: l[1] }; }));
    var r = clusterm.clusterGraph(d, tightMeasure(d, function (a, b) { return tight[a + '\u0000' + b]; }), { kinds: KINDS });
    // a -> c and b -> d are each lighter than b -> g and d -> h, but both join F1 and F2: together they outweigh either
    eq(r.report.boards[0].levels['b:root'], { F1: 0, F2: 0, g: 1, h: 1 }, 'F1 with F2, g with h');
  });

  await test('clusters: with no tightness every link weighs the same, the lens\'s own weights are left as they are, and the report and the summary say the groups are by the links alone', async function () {
    var tri = function (a, b, c) { return [{ from: a, to: b }, { from: b, to: c }, { from: a, to: c }]; };
    var d = digest(['a', 'b', 'c', 'd', 'e', 'f'].map(function (t) { return note(t); }), tri('a', 'b', 'c').concat(tri('d', 'e', 'f'), [{ from: 'c', to: 'd', weight: 7 }]));
    var r = clusterm.clusterGraph(d, measureOf(d), { kinds: KINDS }), g = r.graph;
    eq(r.report.tightness, { by: null, why: 'canvas measure gave no tightness' });
    eq(g.layout.clustered, { by: null, why: 'canvas measure gave no tightness' });
    eq(edgeBy(g, 'c', 'd').layout, { weight: 7, cut: true }, 'the bridge is cut and keeps the lens\'s weight');
    eq(g.edges.filter(function (e) { return e.layout && e.layout.weight != null && e.from !== 'c'; }).length, 0, 'no other weight written');
    eq(g.nodes, d.nodes, 'no frame made for the two triangles');
    eq(r.report.boards[0].levels['b:root'], { a: 0, b: 0, c: 0, d: 1, e: 1, f: 1 }, 'the two triangles');
    assert(/\(no tightness: canvas measure gave no tightness; grouped by the links alone, each weighing the same\)$/.test(clusterm.clusterLine(r.report)), clusterm.clusterLine(r.report));
    var text = clim.summarize(await planOf(g));
    assert(/\nclusters: by the links alone, each weighing the same \(no tightness: canvas measure gave no tightness\)/.test(text), text);
    assert(/1 between groups before anything was placed/.test(text), text);
    // the app says why it can't (no key): that is the reason given
    var m = measureOf(d); m.tightness = { unavailable: 'No OpenAI key', reason: 'no_key' };
    eq(clusterm.clusterGraph(d, m, { kinds: KINDS }).graph.layout.clustered, { by: null, why: 'No OpenAI key' });
  });

  await test('layout.cut and layout.clustered are the tool\'s own, typed and refused where they don\'t belong; a lens\'s node may use a key beginning cluster: (the tool makes no frame); a document is clustered once', async function () {
    var d = camps(), clustered = clusterm.clusterGraph(d, tightMeasure(d, campsTight), { kinds: KINDS }).graph;
    eq(model.readGraph(clustered, model.kindsTable(KINDS)).errors, [], 'the tool\'s own output reads');
    var withCut = function (g, key, value) { var c = JSON.parse(JSON.stringify(g)); c.edges[0].layout = Object.assign({}, c.edges[0].layout, { [key]: value }); return c; };
    var errs = function (g) { return model.readGraph(g, model.kindsTable(KINDS)).errors.join('\n'); };
    assert(/layout\.cut is the tool's own/.test(errs(withCut(d, 'cut', true))), 'layout.cut without layout.clustered: ' + errs(withCut(d, 'cut', true)));
    assert(/layout\.cut is true or false, not "yes"/.test(errs(withCut(clustered, 'cut', 'yes'))), errs(withCut(clustered, 'cut', 'yes')));
    var both = withCut(withCut(clustered, 'cut', true), 'direct', true);
    assert(/layout\.cut and layout\.direct are both true/.test(errs(both)), errs(both));
    var into = JSON.parse(JSON.stringify(clustered)); nodeBy(into, 'y').layout = { pill: false };
    var threw = ''; try { model.buildModel(into); } catch (e) { threw = e.message; }
    assert(/"b" -> "y" is cut .*no pill may stand for it/.test(threw), 'a cut link into a shape kept off pills: ' + threw);
    var direct = JSON.parse(JSON.stringify(clustered)); edgeBy(direct, 'b', 'y').layout.direct = true;
    threw = ''; try { model.buildModel(direct); } catch (e) { threw = e.message; }
    assert(/"b" -> "y" is cut/.test(threw) || /both true/.test(errs(direct)), 'cut and direct: ' + threw);
    var lensKey = digest([note('a'), note('b')], [{ from: 'a', to: 'b' }]); lensKey.nodes.push({ key: 'cluster:b:root:0', kind: FRAME, props: {} });
    eq(errs(lensKey), '', 'a key beginning cluster:b: is the lens\'s own: the tool makes no frame');
    var bad = JSON.parse(JSON.stringify(d)); bad.layout = { clustered: 'yes' };
    assert(/layout\.clustered is the tool's note/.test(errs(bad)), errs(bad));
    threw = ''; try { clusterm.clusterGraph(clustered, tightMeasure(clustered, campsTight), { kinds: KINDS }); } catch (e) { threw = e.message; }
    assert(/clustered already/.test(threw), 'clustered once: ' + threw);
    var lens = JSON.parse(JSON.stringify(d)); lens.nodes.push({ key: 'cluster:f:F:0', kind: FRAME, props: {} });
    eq(clusterm.clusterGraph(lens, measureOf(lens), { kinds: KINDS }).graph.nodes.map(function (n) { return n.key; }), lens.nodes.map(function (n) { return n.key; }), 'and clusters over it as over any frame');
  });

  await test('a link cut between groups is a pill before anything is placed and counts as precut, never as a planar cut, and comes back as an arrow where its line is clear, whatever else joins the same two notes or groups', async function () {
    var cutDoc = function (extra) { var g = digest([note('A'), note('B')], [Object.assign({ from: 'A', to: 'B' }, extra || {})]); g.layout = { clustered: { by: 'test' } }; g.edges[0].layout = Object.assign({ cut: true }, g.edges[0].layout); return g; };
    var plain = await planOf(digest([note('A'), note('B')], [{ from: 'A', to: 'B' }]));
    eq([plain.report.boards.root.end.pills, plain.report.boards.root.end.arrows, plain.report.boards.root.precut], [0, 1, 0], 'with no cut the link is an arrow');
    var r = await planOf(cutDoc()), rep = r.report.boards.root;
    eq([rep.precut, rep.cut, rep.cutFurther, rep.restored, rep.restoredCut, rep.end.pills, rep.end.arrows], [1, 0, 0, 1, 1, 0, 1], 'counted as precut and no more, then put back as an arrow: its line is clear');
    assert(!pillOf(r.drawing.edges[0]), 'the drawing has it as an arrow');
    eq([r.report.totals.precut, r.report.totals.restored, r.report.totals.restoredCut], [1, 1, 1]);
    assert(/\ncut: 1 of 1 links made pills: 1 between groups before anything was placed, 0 so each board's links are planar and 0 more where a drawing still crossed or ran over a shape; 1 of the 1 between groups and 0 of the others put back as arrows /.test(clim.summarize(r)), clim.summarize(r));
    // a link no pill may stand for between the same two notes is an arrow and no more; the cut link comes back beside it
    var held = cutDoc(); held.edges.push({ from: 'B', to: 'A', layout: { direct: true } });
    var k = await planOf(held), kr = k.report.boards.root;
    eq([kr.precut, kr.restoredCut, kr.end.pills, kr.end.arrows], [1, 1, 0, 2], 'both arrows: ' + JSON.stringify([kr.precut, kr.end]));
    // the same between two groups: the links of both lift to the one pair of the lens's frames, one of them to a lens frame (always direct)
    var d = camps(), g = clusterm.clusterGraph(d, tightMeasure(d, campsTight), { kinds: KINDS }).graph;
    g.edges.push({ from: 'c', to: 'G' });
    var l = await planOf(g), lr = l.report.boards.root;
    eq([lr.precut, lr.cut], [1, 0], 'counted as precut: ' + JSON.stringify([lr.precut, lr.cut]));
    assert(pillOf(edgeBy(l.drawing, 'b', 'y')) === undefined, 'b -> y, cut between the groups, comes back as an arrow where its line is clear, though c -> G joins them too: ' + JSON.stringify(edgeBy(l.drawing, 'b', 'y')));
    eq([lr.restored, lr.restoredCut], [1, 1], 'counted as put back, and as one that was cut between groups');
    assert(!pillOf(edgeBy(l.drawing, 'c', 'G')), 'c -> G, a link to a lens frame, is an arrow');
    // where its line is not clear it stays a pill: three notes in a row, the link cut between the outer two would run over the one between them
    var row = digest([note('N0'), note('N1'), note('N2')], [{ from: 'N0', to: 'N1', direct: true }, { from: 'N1', to: 'N2', direct: true }, { from: 'N0', to: 'N2', layout: { cut: true } }]);
    row.layout = { clustered: { by: 'test' } };
    var w = await planOf(row), wr = w.report.boards.root;
    eq([wr.precut, wr.restored, wr.restoredCut, wr.end.pills, wr.end.arrows, wr.stop], [1, 0, 0, 1, 2, 'clean'], 'a pill, counted as precut and not put back: ' + JSON.stringify([wr.precut, wr.restored, wr.end]));
    assert(pillOf(edgeBy(w.drawing, 'N0', 'N2')) && !pillOf(edgeBy(w.drawing, 'N0', 'N1')), 'the cut link is the pill');
    assert(/1 between groups before anything was placed, 0 so each board's links are planar and 0 more where a drawing still crossed or ran over a shape; 0 of the 1 between groups and 0 of the others put back as arrows /.test(clim.summarize(w)), clim.summarize(w));
  });

  await test('the mend of a fresh plan cuts the least wanted link first where the document was clustered by tightness, the one in the most conflicts first otherwise, and a redraw\'s mend still the one in the most', async function () {
    var lines = [{ key: 'a', cuttable: true }, { key: 'b', cuttable: true }, { key: 'c', cuttable: true }];
    var worth = function (k) { return k === 'b' ? 10 : 1; };
    eq(cutm.conflictCuts([[0, 1], [1, 2]], lines, worth), ['b'], 'by default: b is in both conflicts');
    eq(cutm.conflictCuts([[0, 1], [1, 2]], lines, worth, true), ['a', 'c'], 'least wanted first: a and c, though b alone would mend both');
    eq(cutm.conflictCuts([[0, 1], [0, 2]], lines, function () { return 1; }, true), ['a'], 'alike: the one in more conflicts');
    eq(cutm.frozenCuts([[0, 1], [1, 2]], lines, worth, null, null), ['b'], 'a redraw\'s: the one in the most conflicts');
  });

  await test('tightness: what the app answered by the two keys of a pair either way round, none to give and why, and an app that says nothing; a pair the answer lacks is counted', async function () {
    var t = sizes.tightnessFrom({ tightness: { model: 'm', texts: 3, asked: 0, pairs: [{ a: 'b', b: 'a', tightness: 0.5 }, { a: 'x', b: 'y', tightness: -0.25 }, { a: 'bad', b: 'x', tightness: null }] } });
    eq([t.by, t.why, t.of.get('a\u0000b'), t.of.get('x\u0000y'), t.of.size], ['m', null, 0.5, -0.25, 2], 'sorted by the tool, a bad row skipped');
    eq(sizes.tightnessFrom({ tightness: { unavailable: 'No OpenAI key', reason: 'no_key' } }).why, 'No OpenAI key');
    eq(sizes.tightnessFrom({}).why, 'canvas measure gave no tightness');
    eq(sizes.tightnessFrom(null).by, null);
    eq(clim.tightnessLine({ tightness: { model: 'm', texts: 962, asked: 12, pairs: [{ a: 'a', b: 'b', tightness: 0.1 }] } }), 'tightness: 1 linked pairs of notes, by m (asked for 12 of 962 texts)');
    eq(clim.tightnessLine({ tightness: { unavailable: 'No OpenAI key', reason: 'no_key' } }), 'tightness: unavailable (No OpenAI key): clusters by the links alone');
    var d = camps(), me = tightMeasure(d, campsTight);
    me.tightness.pairs = me.tightness.pairs.filter(function (p) { return !(p.a === 'b' && p.b === 'y'); });
    var r = clusterm.clusterGraph(d, me, { kinds: KINDS });
    eq([r.report.boards[0].missing, r.report.totals.missing], [1, 1], 'counted');
    assert(/; 1 pair\(s\) had no tightness$/.test(clusterm.clusterLine(r.report)), clusterm.clusterLine(r.report));
    var swapped = tightMeasure(d, campsTight); swapped.tightness.pairs = swapped.tightness.pairs.map(function (p) { return { a: p.b, b: p.a, tightness: p.tightness }; }).reverse();
    eq(JSON.stringify(clusterm.clusterGraph(d, swapped, { kinds: KINDS }).graph), JSON.stringify(clusterm.clusterGraph(d, tightMeasure(d, campsTight), { kinds: KINDS }).graph), 'the order the app gave them in doesn\'t matter');
  });

  await test('the commands cluster and tightness: cluster writes clustered.json and clusters.json and prints one line, tightness one line; unknown options are refused', async function () {
    var d = camps(), me = tightMeasure(d, campsTight, { asked: 4 });
    var mem = memory({ '/g.json': JSON.stringify(d), '/m.json': JSON.stringify(me) });
    await clim.run(['cluster', '/g.json', '/m.json', '/out', '--kinds', KINDS_PATH], mem.io);
    eq(mem.printed.pop(), 'clusters: each container\'s shapes grouped by how tightly their links hold them, on 1 board(s); 1 of 5 linked pairs between two groups are cut before anything is placed, and come back as arrows where their line is clear (tightness: test/embedding)');
    eq(Object.keys(mem.files).sort(), ['/g.json', '/m.json', '/out/clusters.json', '/out/clustered.json'].sort(), 'two files written');
    eq(JSON.parse(mem.files['/out/clustered.json']), clusterm.clusterGraph(d, me, { kinds: KINDS }).graph, 'the document');
    eq(JSON.parse(mem.files['/out/clusters.json']).totals, { boards: 1, links: 5, cut: 1, missing: 0 }, 'the report');
    await clim.run(['tightness', '/m.json'], mem.io);
    eq(mem.printed.pop(), 'tightness: 5 linked pairs of notes, by test/embedding (asked for 4 of 9 texts)');
    var threw = ''; try { await clim.run(['cluster', '/g.json', '/m.json', '/out', '--kinds', KINDS_PATH, '--bogus', 'x'], mem.io); } catch (e) { threw = e.message; }
    assert(/unknown option --bogus/.test(threw), threw);
    // a drawing as the file holds it, and what a person changed, are read from files
    var first = await planOf(clusterm.clusterGraph(d, me, { kinds: KINDS }).graph);
    mem.files['/c.json'] = JSON.stringify(rowsOf(first.drawing)); mem.files['/ch.json'] = JSON.stringify([]);
    await clim.run(['cluster', '/g.json', '/m.json', '/out2', '--kinds', KINDS_PATH, '--current', '/c.json', '--changed', '/ch.json'], mem.io);
    eq(mem.printed.pop(), 'clusters: each container\'s shapes grouped by how tightly their links hold them, on 1 board(s); 1 of 5 linked pairs between two groups only weigh the links: the file\'s arrows and pills stay (tightness: test/embedding)', 'a redraw says the groups only weigh the links, and the file\'s arrows and pills stay');
  });

  // ---- clusters on a redraw: the groups are found afresh over the document as it is now, only to weigh its links; nothing of the file's is kept here ----
  // the document as camps() draws it, and the file's rows of that drawing; `edit` changes the rows (what a person did), `more` the lens's document
  var campsDrawn = async function (extra, tight) {
    var d = camps(); if (extra) extra(d);
    var me = tightMeasure(d, tight || campsTight), g = clusterm.clusterGraph(d, me, { kinds: KINDS }).graph, r = await planOf(g);
    return { d: d, g: g, r: r, rows: rowsOf(r.drawing) };
  };
  var redrawn = async function (first, edit, grow, tight, changed) {
    var d = camps(); if (grow) grow(d);
    var rows = rowsOf(first.r.drawing, edit), me = tightMeasure(d, tight || campsTight);
    var c = clusterm.clusterGraph(d, me, { kinds: KINDS, current: rows, changed: changed });
    return { d: d, c: c, g: c.graph, rows: rows, r: await planOf(c.graph, { current: rows, changed: changed }) };
  };
  var holders = function (g) { var o = {}; g.nodes.forEach(function (n) { o[n.key] = n.in; }); return o; };
  var growCamps = function (extraNodes, extraEdges) { return function (d) { extraNodes.forEach(function (n) { d.nodes.push(nodeOf(n)); }); extraEdges.forEach(function (e) { d.edges.push(edgeOf(e)); }); }; };

  await test('a redraw groups the document afresh, only to weigh its links: nothing changed gives the same document and the same places, byte for byte, and nothing is added or kept', async function () {
    var first = await campsDrawn(), again = await redrawn(first);
    eq(JSON.stringify(again.g), JSON.stringify(first.g), 'the same clustered document');
    eq(JSON.stringify(again.r.drawing), JSON.stringify(first.r.drawing), 'and the same drawing');
    eq(placesOfNodes(again.r), placesOfNodes(first.r), 'places');
    eq(again.g.nodes, again.d.nodes, 'no frame added');
    eq(Object.keys(again.c.report).sort(), ['boards', 'resolution', 'tightness', 'totals'], 'the report says nothing of frames kept, joined or gone');
    eq(again.r.report.redraw, true);
  });

  await test('a redraw: a note a person carried into another frame is grouped where it is now, and one that is new is grouped with the rest as a fresh document would', async function () {
    var first = await campsDrawn(), abs0 = absoluteOf(first.r.drawing);
    var carry = await redrawn(first, function (rs) { var rn = rs.find(function (x) { return x.key === 'c'; }); rn.in = 'G'; rn.inside = ['G']; rn.at = [[abs0.G.x + 60, abs0.G.y + 60], rn.at[1]]; }, null, null, new Map([['c', new Set(['frame', 'moved'])]]));
    eq(holders(carry.c.carried).c, 'G', 'c is in G, where the person put it, in the document the groups were found over');
    eq(holders(carry.g).c, undefined, 'the clustered document keeps its own containers: the plan carries the shapes');
    eq(carry.c.report.carried, [{ key: 'c', in: 'G' }], 'and the report says what was carried');
    eq(carry.r.report.carried, [{ key: 'c', in: 'G' }], 'which the plan says too');
    eq(carry.g.nodes.length, carry.d.nodes.length, 'and no frame was added');
    var b = carry.c.report.boards[0];
    assert(Object.keys(b.levels['f:G']).indexOf('c') >= 0 && Object.keys(b.levels['b:root']).indexOf('c') < 0, 'grouped in G\'s own notes, not on the board: ' + JSON.stringify(b.levels));
    // a new note is grouped with the document as it now is: the link it brings weighs and may be cut as any other
    var rate = function (a, b2) { var v = { 'c\u0000n': 0.95, 'n\u0000z': 0.2 }[a + '\u0000' + b2]; return v !== undefined ? v : campsTight(a, b2); };
    var n = await redrawn(first, null, growCamps([note('n')], [{ from: 'n', to: 'c' }, { from: 'n', to: 'z' }]), rate);
    eq(n.g.nodes.map(function (x) { return x.key; }), n.d.nodes.map(function (x) { return x.key; }), 'no frame made');
    eq(n.c.report.boards[0].levels['b:root'].n, n.c.report.boards[0].levels['b:root'].c, 'n is grouped with c, the note it is most tightly linked to (0.95 against 0.2)');
    eq(edgeBy(n.g, 'n', 'z').layout.cut, true, 'and its looser link, to z, is cut between groups');
    eq(edgeBy(n.g, 'n', 'c').layout.cut, undefined, 'its tighter one is not');
    eq(n.r.report.boards.root.afresh, false, 'drawn in place');
  });

  await test('a redraw: a new link between two groups is an arrow where its line is clear, else a pill, and a note a person moved is held where they put it; the drawn-again document reads back the same', async function () {
    var big = function (d) { d.nodes.push(nodeOf(note('c2'))); d.edges.push(edgeOf({ from: 'a', to: 'c2' })); d.edges.push(edgeOf({ from: 'lone', to: 'c' })); };
    var tight = function (a, b) { var t = { 'a\u0000c2': 0.95, 'c\u0000lone': 0.9, 'c\u0000z': 0.05, 'c2\u0000z': 0.05 }[a + '\u0000' + b]; return t !== undefined ? t : campsTight(a, b); };
    var first = await campsDrawn(big, tight);
    eq(first.g.nodes, first.d.nodes, 'the first drawing has no frame but the lens\'s');
    // two new links, c -> z and c2 -> z, each between two groups: the file has no row for either
    var news = function (d) { big(d); d.edges.push(edgeOf({ from: 'c', to: 'z' })); d.edges.push(edgeOf({ from: 'c2', to: 'z' })); };
    var linked = await redrawn(first, null, news, tight);
    eq([edgeBy(linked.g, 'c', 'z').layout.cut, edgeBy(linked.g, 'c2', 'z').layout.cut], [true, true], 'cut: between two groups');
    eq(linked.r.report.boards.root.afresh, false, 'drawn in place');
    assert(!pillOf(edgeBy(linked.r.drawing, 'c', 'z')), 'c -> z: its line is clear, so an arrow though it is cut between groups: ' + JSON.stringify(edgeBy(linked.r.drawing, 'c', 'z').place));
    assert(pillOf(edgeBy(linked.r.drawing, 'c2', 'z')), 'c2 -> z: its line runs over the frame between, so a pill: ' + JSON.stringify(edgeBy(linked.r.drawing, 'c2', 'z').place));
    eq(linked.r.report.boards.root.stop, 'clean');
    // the shapes the file had stay where they were
    var abs0 = absoluteOf(first.r.drawing), abs1 = absoluteOf(linked.r.drawing);
    eq(Object.keys(abs0).filter(function (k) { return abs1[k].x !== abs0[k].x || abs1[k].y !== abs0[k].y; }), [], 'nothing the file had moved');
    // c moved far off by a person: its row is there, and it stays where they put it, whatever its links now are
    var out = await redrawn(first, function (rs) { var rn = rs.find(function (x) { return x.key === 'c'; }); rn.at[0] = [5000, 5000]; }, news, tight, new Map([['c', new Set(['moved'])]]));
    eq(out.g.nodes, out.d.nodes, 'no frame, and c is in none');
    var ctr = absoluteOf(out.r.drawing);
    eq([ctr.c.x, ctr.c.y], [5000, 5000], 'and held where the person put it');
    // the drawn-again document reads back the same
    var again = await planOf(out.g, { current: rowsOf(out.r.drawing) });
    eq(placesOfNodes(again), placesOfNodes(out.r), 'and the next redraw draws it the same');
    eq(JSON.stringify(again.drawing.edges.map(function (e) { return [e.from, e.to, !!pillOf(e)]; })), JSON.stringify(out.r.drawing.edges.map(function (e) { return [e.from, e.to, !!pillOf(e)]; })), 'the same links are arrows and pills');
  });

  await test('a redraw with a note carried into another container: cluster keeps the document\'s own containers, says what it carried and writes the carried document, whose measure sizes the pills the plan draws; nothing carried writes none', async function () {
    var d = digest([{ title: 'F1', kind: 'frame' }, { title: 'F2', kind: 'frame' }, note('X', 'F1'), note('Y', 'F1'), note('Z', 'F2'), note('W', 'F2')], [{ from: 'X', to: 'Y' }, { from: 'Z', to: 'W' }, { from: 'X', to: 'Z' }, { from: 'Y', to: 'W' }, { from: 'X', to: 'W' }, { from: 'Y', to: 'Z' }]);
    // a measure whose pill widths tell the container the note is in: 270 from the board, 150 from a frame (the 120 default is neither)
    var wide = function (g) { var m = measureOf(g); m.pills.forEach(function (p) { p.size = [p.from ? 150 : 270, p.size[1]]; }); return m; };
    var first = await planOf(clusterm.clusterGraph(d, wide(d), { kinds: KINDS }).graph), at = [absoluteOf(first.drawing).F2.x + 30, absoluteOf(first.drawing).F2.y + absoluteOf(first.drawing).F2.h + 200];
    var rows = rowsOf(first.drawing, function (rs) { rs.forEach(function (x) { if (x.key === 'X') { delete x.in; x.inside = []; x.at[0] = at.slice(); } }); });
    var changed = [{ key: 'X', changed: ['frame', 'moved'] }];
    var mem = memory({ '/g.json': JSON.stringify(d), '/m.json': JSON.stringify(wide(d)), '/c.json': JSON.stringify(rows), '/ch.json': JSON.stringify(changed) });
    var args = ['cluster', '/g.json', '/m.json', '/out', '--kinds', KINDS_PATH, '--current', '/c.json', '--changed', '/ch.json'];
    await clim.run(args, mem.io);
    eq(Object.keys(mem.files).filter(function (k) { return k.indexOf('/out/') === 0; }).sort(), ['/out/carried.json', '/out/clustered.json', '/out/clusters.json']);
    eq(nodeBy(JSON.parse(mem.files['/out/clustered.json']), 'X').in, 'F1', 'clustered.json keeps X in the container the document gave it');
    eq(nodeBy(JSON.parse(mem.files['/out/carried.json']), 'X').in, undefined, 'carried.json has it where the person put it: on the board');
    eq(JSON.parse(mem.files['/out/clusters.json']).carried, [{ key: 'X', in: null }], 'clusters.json says what it carried');
    // the driver measures carried.json (the app is asked of it), and plans clustered.json with that measure
    var carriedDoc = JSON.parse(mem.files['/out/carried.json']), mc = wide(carriedDoc);
    var own = measureOf(carriedDoc);
    mem.files['/mc.json'] = JSON.stringify(mc);
    await clim.run(['plan', '/out/clustered.json', '/mc.json', '/outp', '--kinds', KINDS_PATH, '--view', '1440x900', '--current', '/c.json', '--changed', '/ch.json'], mem.io);
    eq(JSON.parse(mem.files['/outp/report.json']).carried, [{ key: 'X', in: null }], 'the plan carries the shapes itself, so the report says so');
    assert(/; 1 of them carried into another container, which they stay in/.test(mem.printed.pop()), 'and the summary says so');
    // the pills are sized from the measure of the carried document: X -> Y and X -> Z are pills of notes now in other containers than the document's
    var direct = async function (m) { var g = JSON.parse(mem.files['/out/clustered.json']); return planm.planGraph(g, function (mo) { return sizes.sizesFrom(mo, m); }, { view: { w: 1440, h: 900 }, current: rows, changed: new Map([['X', new Set(['frame', 'moved'])]]), kinds: KINDS }, elk); };
    var viaCarried = await direct(mc), viaOwn = await direct(wide(d));
    var widths = function (r) { return r.plan.boards.reduce(function (a, b) { return a.concat(b.pills.map(function (p) { return p.start + '>' + p.for + ':' + p.w; })); }, []).sort(); };
    assert(widths(viaCarried).length > 0, 'pills are drawn: ' + JSON.stringify(widths(viaCarried)));
    assert(widths(viaCarried).every(function (w) { return /:(150|270)$/.test(w); }), 'no pill falls to the 120 default: ' + JSON.stringify(widths(viaCarried)));
    assert(JSON.stringify(widths(viaOwn)) !== JSON.stringify(widths(viaCarried)), 'a measure of the document before it was carried sizes them otherwise: ' + JSON.stringify(widths(viaOwn)));
    eq(JSON.parse(mem.files['/outp/drawing.json']), viaCarried.drawing, 'the drawing plan wrote is the one the carried measure gives');
    // nothing carried: no carried.json, no carried in the report
    var mem2 = memory({ '/g.json': JSON.stringify(d), '/m.json': JSON.stringify(wide(d)), '/c.json': JSON.stringify(rowsOf(first.drawing)), '/ch.json': JSON.stringify([]) });
    await clim.run(args, mem2.io);
    eq(Object.keys(mem2.files).filter(function (k) { return k.indexOf('/out/') === 0; }).sort(), ['/out/clustered.json', '/out/clusters.json']);
    eq(JSON.parse(mem2.files['/out/clusters.json']).carried, undefined);
  });

  await test('a redraw: a new link whose line is not clear shares a pill the file has for its target, which it reaches, before it gets one of its own; with no pill in the file for the target it gets its own', async function () {
    var d = fixture('acme'), first = await planOf(d), makers = function (r) { return r.drawing.edges.filter(function (e) { return pillOf(e) && pillOf(e).at; }); };
    var withLink = async function (from, to) {
      var d2 = JSON.parse(JSON.stringify(d)); d2.edges.push({ from: from, to: to });
      var r = await planOf(d2, { current: rowsOf(first.drawing) });
      return { r: r, e: r.drawing.edges.find(function (x) { return x.from === from && x.to === to; }) };
    };
    // the file draws Mobile team -> Mobile app 3 through a pill, in Engineering, where Payments team is too: its new link to Mobile app 3 goes into that pill
    var host = first.drawing.edges.find(function (e) { return e.from === 'Mobile team' && e.to === 'Mobile app 3'; });
    assert(host && pillOf(host) && pillOf(host).at, 'the file has the pill: ' + JSON.stringify(host));
    var s = await withLink('Payments team', 'Mobile app 3');
    eq(pillOf(s.e), { share: 'Mobile team' }, 'the new link goes into the file\'s pill');
    eq(makers(s.r).map(function (e) { return e.from + '>' + e.to + JSON.stringify(pillOf(e)); }), makers(first).map(function (e) { return e.from + '>' + e.to + JSON.stringify(pillOf(e)); }), 'and no new pill is made');
    eq(JSON.stringify(pillOf(s.r.drawing.edges.find(function (e) { return e.from === 'Mobile team' && e.to === 'Mobile app 3'; }))), JSON.stringify(pillOf(host)), 'the file\'s pill stays where it is');
    // the file has no pill for Data engineering: the same kind of link, of its own
    assert(!first.drawing.edges.some(function (e) { return e.to === 'Data engineering' && pillOf(e); }), 'the file has no pill for Data engineering');
    var o = await withLink('Payments team', 'Data engineering');
    assert(pillOf(o.e) && pillOf(o.e).at && pillOf(o.e).share === undefined, 'a pill of its own: ' + JSON.stringify(pillOf(o.e)));
    eq(makers(o.r).length, makers(first).length + 1, 'one pill more');
  });

  await test('the plan\'s mend cuts the least wanted link first in a document grouped by tightness (layout.clustered.by, each link weighed), the link in the most conflicts first in one that is not, and the weights are what it goes by', async function () {
    var names = ['N0', 'N1', 'N2', 'N3', 'N4', 'N5'];
    var links = [[0, 4, 1], [2, 1, 11], [4, 1, 18], [4, 3, 23], [2, 3, 29], [2, 4, 40], [1, 5, 45], [0, 5, 52], [2, 0, 59]];
    var mk = function (by, flat) {
      var d = digest(names.map(function (x) { return note(x); }), links.map(function (l) { return { from: names[l[0]], to: names[l[1]], layout: { weight: flat ? 1 : l[2] } }; }));
      if (by) d.layout = { clustered: { by: 'test/embedding' } };
      return d;
    };
    var pills = function (r) { return r.drawing.edges.filter(pillOf).map(function (e) { return e.from + '>' + e.to; }).sort(); };
    var by = await planOf(mk(true)), plain = await planOf(mk(false)), flat = await planOf(mk(true, true));
    assert(by.report.boards.root.cutFurther > 0 && plain.report.boards.root.cutFurther > 0, 'the mend cuts on both: ' + by.report.boards.root.cutFurther + ', ' + plain.report.boards.root.cutFurther);
    eq(pills(by), ['N2>N1', 'N2>N3', 'N2>N4'], 'grouped by tightness, by the weights: the 29 (N2 -> N3) is a pill, and the 45 (N1 -> N5) an arrow');
    eq(pills(plain), ['N1>N5', 'N2>N1', 'N2>N4'], 'not grouped by tightness: the link in the most conflicts, the 45 (N1 -> N5), is a pill, and the 29 an arrow');
    eq(pills(flat), pills(plain), 'the weights are what the first goes by: weighed alike it is the second');
    eq([by.report.boards.root.stop, plain.report.boards.root.stop, flat.report.boards.root.stop], ['clean', 'clean', 'clean']);
  });

  if (part) io.print('part ' + part.k + ' of ' + part.n + ': ' + (results.length + failed) + ' of ' + defined + ' tests');
  io.print(results.length + ' passed, ' + failed + ' failed');
  if (failed) throw new Error('tests failed');
}).catch(function (e) { io.print('ERROR ' + (e && e.stack ? e.stack : e)); setTimeout(function () { throw e; }, 0); });
