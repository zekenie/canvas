// Planarity: whether a board's graph can be drawn with no crossings at all, and the fewest cuts that make it so.
// isPlanar splits the graph into biconnected components (Tarjan) and tests each with Demoucron–Malgrange–Pertuiset,
// which is quadratic but plenty for boards of tens of notes. Edges are [u, v] pairs of vertex numbers, simple and undirected.

export function isPlanar(n, edges) {
  if (n <= 4) return true;
  if (edges.length > 3 * n - 6) return false;
  const adj = Array.from({ length: n }, () => []);
  for (const [u, v] of edges) { adj[u].push(v); adj[v].push(u); }
  for (const comp of biconnected(n, adj)) if (!dmp(comp)) return false;
  return true;
}

function biconnected(n, adj) {
  const disc = new Array(n).fill(0), low = new Array(n).fill(0), stack = [], comps = [];
  let time = 0;
  const dfs = (u, parent) => {
    disc[u] = low[u] = ++time;
    for (const v of adj[u]) {
      if (!disc[v]) {
        stack.push([u, v]);
        dfs(v, u);
        low[u] = Math.min(low[u], low[v]);
        if (low[v] >= disc[u]) {
          const comp = [];
          let e;
          do { e = stack.pop(); comp.push(e); } while (!(e[0] === u && e[1] === v));
          comps.push(comp);
        }
      } else if (v !== parent && disc[v] < disc[u]) {
        stack.push([u, v]);
        low[u] = Math.min(low[u], disc[v]);
      }
    }
  };
  for (let u = 0; u < n; u++) if (!disc[u] && adj[u].length) dfs(u, -1);
  return comps;
}

function dmp(compEdges) {
  const ids = new Map(), vid = (x) => { if (!ids.has(x)) ids.set(x, ids.size); return ids.get(x); };
  const E = compEdges.map(([u, v]) => [vid(u), vid(v)]);
  const n = ids.size, m = E.length;
  if (n <= 4) return true;
  if (m > 3 * n - 6) return false;
  const adj = Array.from({ length: n }, () => []);
  E.forEach(([u, v], i) => { adj[u].push([v, i]); adj[v].push([u, i]); });
  const edgeIndex = (a, b) => adj[a].find(([y]) => y === b)[1];
  const inH = new Array(n).fill(false), embedded = new Array(m).fill(false);
  const cycle = findCycle(n, adj);
  for (const x of cycle) inH[x] = true;
  for (let k = 0; k < cycle.length; k++) embedded[edgeIndex(cycle[k], cycle[(k + 1) % cycle.length])] = true;
  const faces = [cycle.slice(), cycle.slice()];
  let count = cycle.length;
  while (count < m) {
    const frags = fragments(n, adj, E, inH, embedded);
    const faceSets = faces.map((f) => new Set(f));
    let pick = null;
    for (const fr of frags) {
      fr.ok = [];
      for (let fi = 0; fi < faces.length; fi++) if (fr.att.every((a) => faceSets[fi].has(a))) fr.ok.push(fi);
      if (!fr.ok.length) return false;
      if (fr.ok.length === 1 && !pick) pick = fr;
    }
    if (!pick) pick = frags[0];
    const fi = pick.ok[0], F = faces[fi];
    const path = pathIn(pick, adj, inH, E);
    const i = F.indexOf(path[0]), j = F.indexOf(path[path.length - 1]);
    const inner = path.slice(1, -1);
    const walk = (from, to) => { const out = []; for (let k = from; ; k = (k + 1) % F.length) { out.push(F[k]); if (k === to) break; } return out; };
    faces.splice(fi, 1, walk(i, j).concat(inner.slice().reverse()), walk(j, i).concat(inner));
    for (const x of inner) inH[x] = true;
    for (let k = 0; k + 1 < path.length; k++) { const ei = edgeIndex(path[k], path[k + 1]); if (!embedded[ei]) { embedded[ei] = true; count++; } }
  }
  return true;
}

function findCycle(n, adj) {
  const parent = new Array(n).fill(-1), state = new Array(n).fill(0);
  let found = null;
  const dfs = (u, pe) => {
    state[u] = 1;
    for (const [v, ei] of adj[u]) {
      if (found) return;
      if (ei === pe) continue;
      if (state[v] === 1) { const cyc = [u]; let x = u; while (x !== v) { x = parent[x]; cyc.push(x); } found = cyc.reverse(); return; }
      if (state[v] === 0) { parent[v] = u; dfs(v, ei); }
    }
    state[u] = 2;
  };
  dfs(0, -1);
  return found;
}

function fragments(n, adj, E, inH, embedded) {
  const frs = [];
  E.forEach(([u, v], i) => { if (!embedded[i] && inH[u] && inH[v]) frs.push({ kind: 'edge', edge: i, att: [u, v] }); });
  const comp = new Array(n).fill(-1);
  for (let s = 0, c = 0; s < n; s++) {
    if (inH[s] || comp[s] !== -1) continue;
    const verts = [], att = new Set(), q = [s];
    comp[s] = c;
    while (q.length) { const x = q.pop(); verts.push(x); for (const [y] of adj[x]) { if (inH[y]) att.add(y); else if (comp[y] === -1) { comp[y] = c; q.push(y); } } }
    frs.push({ kind: 'comp', vset: new Set(verts), att: [...att] });
    c++;
  }
  return frs;
}

function pathIn(fr, adj, inH, E) {
  if (fr.kind === 'edge') return E[fr.edge].slice();
  const a = fr.att[0], prev = new Map(), q = [];
  for (const [y] of adj[a]) if (fr.vset.has(y) && !prev.has(y)) { prev.set(y, a); q.push(y); }
  for (let h = 0; h < q.length; h++) {
    const x = q[h];
    for (const [y] of adj[x]) {
      if (inH[y] && y !== a) { const p = [y, x]; let z = x; while (prev.get(z) !== a) { z = prev.get(z); p.push(z); } p.push(a); return p.reverse(); }
      if (fr.vset.has(y) && !prev.has(y)) { prev.set(y, x); q.push(y); }
    }
  }
  throw new Error('a fragment with one attachment: the component is not biconnected');
}

/** The edges a greedy maximal planar subgraph leaves out, adding edges in `order`: an upper bound on the skewness. */
export function edgeCuts(n, ordered) {
  const kept = [], cut = [];
  for (const e of ordered) { kept.push(e); if (!isPlanar(n, kept)) { kept.pop(); cut.push(e); } }
  return cut;
}

/** The vertices removed, most connected first, until the rest is planar: an upper bound on planar vertex deletion. */
export function hubCuts(n, edges) {
  let E = edges;
  const removed = [];
  while (!isPlanar(n, E)) {
    const deg = new Array(n).fill(0);
    for (const [u, v] of E) { deg[u]++; deg[v]++; }
    let best = 0;
    for (let x = 1; x < n; x++) if (deg[x] > deg[best]) best = x;
    removed.push(best);
    E = E.filter(([u, v]) => u !== best && v !== best);
  }
  return removed;
}
