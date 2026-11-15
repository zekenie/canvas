// Planarity: whether a graph can be drawn with no two of its edges crossing, and the links to cut so that a board's can be.
//   isPlanar(n, edges)            the left-right planarity test (de Fraysseix and Rosenstiehl; as Brandes writes it out, and NetworkX's
//                                 `check_planarity` runs it, without recursion), linear in the graph's size. Vertices are 0..n-1, edges [u, v] pairs; a
//                                 loop or an edge given twice changes nothing.
//   planarCut(n, kept, ordered)   which of `ordered` (pairs, the most wanted first) a greedy maximal planar subgraph over `kept` (pairs
//                                 that can't be cut) leaves out: each pair is added in turn and left out when the graph stops being
//                                 planar. The fewest such cuts is NP-hard (skewness); greedy is what the spike showed is enough.

/** Whether the graph of `n` vertices and these edges is planar. */
export function isPlanar(n, edges) {
  const adj = Array.from({ length: n }, () => []);
  const seen = new Set();
  let m = 0;
  for (const [u, v] of edges) {
    if (u === v) continue;
    const key = u < v ? u * n + v : v * n + u;
    if (seen.has(key)) continue;
    seen.add(key);
    adj[u].push(v); adj[v].push(u);
    m++;
  }
  if (n > 2 && m > 3 * n - 6) return false;
  return new LRTest(n, adj).planar();
}

/** The pairs of `ordered` a greedy maximal planar subgraph over `kept` leaves out, as their indexes in `ordered`. */
export function planarCut(n, kept, ordered) {
  // pairs that can't be cut and aren't planar among themselves can't be helped: the cut is then made as if they weren't there
  const base = isPlanar(n, kept) ? kept.slice() : [];
  const cut = [];
  if (isPlanar(n, base.concat(ordered))) return cut;
  const now = base;
  ordered.forEach((pair, i) => {
    now.push(pair);
    if (!isPlanar(n, now)) { now.pop(); cut.push(i); }
  });
  return cut;
}

/** One run of the left-right test: orient the graph by a depth-first search, then test for the constraints its back edges make. */
class LRTest {
  constructor(n, adj) {
    this.n = n; this.adj = adj;
    this.height = new Int32Array(n).fill(-1);
    this.parentEdge = new Float64Array(n).fill(-1);   // an oriented edge is v * n + w; -1 for none
    this.oriented = new Set();
    this.out = Array.from({ length: n }, () => []);
    this.lowpt = new Map(); this.lowpt2 = new Map(); this.nesting = new Map();
    this.lowptEdge = new Map(); this.ref = new Map(); this.stackBottom = new Map();
    this.S = [];
    this.side = new Map();
  }

  planar() {
    const roots = [];
    this.roots = roots;
    this.ind = new Int32Array(this.n); this.skip = new Set();
    for (let v = 0; v < this.n; v++) if (this.height[v] < 0) { this.height[v] = 0; roots.push(v); this.orient(v); }
    this.ordered = this.out.map((ws, v) => ws.slice().sort((a, b) => this.nesting.get(v * this.n + a) - this.nesting.get(v * this.n + b)));
    this.ind = new Int32Array(this.n); this.skip = new Set();
    for (const v of roots) if (!this.test(v)) return false;
    return true;
  }

  // Both passes walk the depth-first tree with a stack of their own, not by recursion (a container of thousands of children in a chain
  // would run the engine's stack out): a vertex goes back on the stack under the child it descends to, and `ind` is where its edges resume,
  // `skip` the tree edges whose first half is done (NetworkX's dfs_orientation and dfs_testing, as they are written without recursion).

  orient(root) {
    const { n, ind, skip } = this, stack = [root];
    while (stack.length) {
      const v = stack.pop(), e = this.parentEdge[v], adj = this.adj[v];
      while (ind[v] < adj.length) {
        const w = adj[ind[v]], vw = v * n + w;
        if (!skip.has(vw)) {
          if (this.oriented.has(vw) || this.oriented.has(w * n + v)) { ind[v]++; continue; }
          this.oriented.add(vw); this.out[v].push(w);
          this.lowpt.set(vw, this.height[v]); this.lowpt2.set(vw, this.height[v]);
          if (this.height[w] < 0) {   // a tree edge: w now, then v again from this edge
            this.parentEdge[w] = vw; this.height[w] = this.height[v] + 1;
            stack.push(v, w); skip.add(vw);
            break;
          }
          this.lowpt.set(vw, this.height[w]);   // a back edge
        }
        // the nesting order: by the lowest point it returns to, and after those that return there alone (chordal)
        this.nesting.set(vw, 2 * this.lowpt.get(vw) + (this.lowpt2.get(vw) < this.height[v] ? 1 : 0));
        if (e >= 0) {
          const lv = this.lowpt.get(vw), le = this.lowpt.get(e);
          if (lv < le) { this.lowpt2.set(e, Math.min(le, this.lowpt2.get(vw))); this.lowpt.set(e, lv); }
          else if (lv > le) this.lowpt2.set(e, Math.min(this.lowpt2.get(e), lv));
          else this.lowpt2.set(e, Math.min(this.lowpt2.get(e), this.lowpt2.get(vw)));
        }
        ind[v]++;
      }
    }
  }

  top() { return this.S.length ? this.S[this.S.length - 1] : null; }
  conflicting(I, b) { return !empty(I) && this.lowpt.get(I.high) > this.lowpt.get(b); }
  lowest(P) {
    if (empty(P.L)) return this.lowpt.get(P.R.low);
    if (empty(P.R)) return this.lowpt.get(P.L.low);
    return Math.min(this.lowpt.get(P.L.low), this.lowpt.get(P.R.low));
  }

  test(root) {
    const { n, ind, skip } = this, stack = [root];
    while (stack.length) {
      const v = stack.pop(), e = this.parentEdge[v], ws = this.ordered[v];
      let descended = false;
      while (ind[v] < ws.length) {
        const w = ws[ind[v]], ei = v * n + w;
        if (!skip.has(ei)) {
          this.stackBottom.set(ei, this.top());
          if (ei === this.parentEdge[w]) { stack.push(v, w); skip.add(ei); descended = true; break; }   // a tree edge: w first
          this.lowptEdge.set(ei, ei); this.S.push({ L: interval(), R: interval(ei, ei) });
        }
        // the new return edges
        if (this.lowpt.get(ei) < this.height[v]) {
          if (ind[v] === 0) this.lowptEdge.set(e, this.lowptEdge.get(ei));
          else if (!this.addConstraints(ei, e)) return false;
        }
        ind[v]++;
      }
      if (!descended && e >= 0) this.removeBackEdges(e);
    }
    return true;
  }

  addConstraints(ei, e) {
    const P = { L: interval(), R: interval() };
    // the return edges of ei, merged into P's right
    do {
      const Q = this.S.pop();
      if (!empty(Q.L)) swap(Q);
      if (!empty(Q.L)) return false;
      if (this.lowpt.get(Q.R.low) > this.lowpt.get(e)) {
        if (empty(P.R)) P.R = { low: Q.R.low, high: Q.R.high };
        else this.ref.set(P.R.low, Q.R.high);
        P.R.low = Q.R.low;
      } else this.ref.set(Q.R.low, this.lowptEdge.get(e));
    } while (this.top() !== this.stackBottom.get(ei));
    // the return edges of the edges before it that conflict with it, merged into P's left
    while (this.S.length && (this.conflicting(this.top().L, ei) || this.conflicting(this.top().R, ei))) {
      const Q = this.S.pop();
      if (this.conflicting(Q.R, ei)) swap(Q);
      if (this.conflicting(Q.R, ei)) return false;
      this.ref.set(P.R.low, Q.R.high);
      if (Q.R.low != null) P.R.low = Q.R.low;
      if (empty(P.L)) P.L = { low: Q.L.low, high: Q.L.high };
      else this.ref.set(P.L.low, Q.L.high);
      P.L.low = Q.L.low;
    }
    if (!(empty(P.L) && empty(P.R))) this.S.push(P);
    return true;
  }

  removeBackEdges(e) {
    const { n } = this, u = Math.floor(e / n);
    // the conflict pairs whose lowest return is u go
    while (this.S.length && this.lowest(this.top()) === this.height[u]) { const P = this.S.pop(); if (P.L.low != null) this.side.set(P.L.low, -1); }
    if (this.S.length) {
      const P = this.S.pop();
      while (P.L.high != null && P.L.high % n === u) P.L.high = this.ref.has(P.L.high) ? this.ref.get(P.L.high) : null;
      if (P.L.high == null && P.L.low != null) { this.ref.set(P.L.low, P.R.low); this.side.set(P.L.low, -1); P.L.low = null; }
      while (P.R.high != null && P.R.high % n === u) P.R.high = this.ref.has(P.R.high) ? this.ref.get(P.R.high) : null;
      if (P.R.high == null && P.R.low != null) { this.ref.set(P.R.low, P.L.low); this.side.set(P.R.low, -1); P.R.low = null; }
      this.S.push(P);
    }
    // the side of e is the side of a highest return edge
    if (this.lowpt.get(e) < this.height[u]) {
      const T = this.top(), hl = T.L.high, hr = T.R.high;
      this.ref.set(e, hl != null && (hr == null || this.lowpt.get(hl) > this.lowpt.get(hr)) ? hl : hr);
    }
  }
}

const interval = (low = null, high = null) => ({ low, high });
const empty = (I) => I.low == null && I.high == null;
const swap = (P) => { const t = P.L; P.L = P.R; P.R = t; };

// ---- the embedding: where each vertex's edges go round it, so the graph can be drawn with none crossing (the left-right test's second half,
// as NetworkX's check_planarity completes it: each edge's side resolved, the adjacency sorted by the signed nesting depth, then a depth-first
// walk that puts each back edge beside its ancestor's left or right reference), and a drawing from it: the embedding made a triangulation
// (components joined, each face made two-connected and fanned into triangles) and drawn by Tutte's barycentric method, an outer triangle
// fixed and every other vertex at the middle of its neighbours, which draws a three-connected planar graph with no two edges crossing.

/** A rotation system: each vertex's neighbours clockwise (`cw`, `ccw` as maps), and the first of them. */
class Rotation {
  constructor(n) { this.n = n; this.cw = Array.from({ length: n }, () => new Map()); this.ccw = Array.from({ length: n }, () => new Map()); this.first = new Int32Array(n).fill(-1); }
  has(v, w) { return this.cw[v].has(w); }
  addCW(v, w, ref) {
    if (ref == null || ref < 0) { this.cw[v].set(w, w); this.ccw[v].set(w, w); this.first[v] = w; return; }
    const c = this.cw[v].get(ref);
    this.cw[v].set(ref, w); this.ccw[v].set(w, ref); this.cw[v].set(w, c); this.ccw[v].set(c, w);
  }
  addCCW(v, w, ref) {
    if (ref == null || ref < 0) { this.addCW(v, w, null); return; }
    this.addCW(v, w, this.ccw[v].get(ref));
    if (ref === this.first[v]) this.first[v] = w;
  }
  addFirst(v, w) { this.addCCW(v, w, this.cw[v].size ? this.first[v] : null); }
  around(v) { const out = []; if (!this.cw[v].size) return out; let w = this.first[v]; do { out.push(w); w = this.cw[v].get(w); } while (w !== this.first[v] && out.length <= this.cw[v].size); return out; }
  /** The half-edge after v -> w round its face: w -> the neighbour of w before v. */
  next(v, w) { return this.ccw[w].get(v); }
}

/** A planar graph's rotation system (Rotation), or null when it isn't planar or the embedding fails its check (Euler's formula, face by face). */
export function planarEmbedding(n, edges) {
  const adj = Array.from({ length: n }, () => []);
  const seen = new Set();
  let m = 0;
  for (const [u, v] of edges) {
    if (u === v) continue;
    const key = u < v ? u * n + v : v * n + u;
    if (seen.has(key)) continue;
    seen.add(key);
    adj[u].push(v); adj[v].push(u);
    m++;
  }
  if (n > 2 && m > 3 * n - 6) return null;
  const t = new LRTest(n, adj);
  if (!t.planar()) return null;
  const sign = (e) => {
    const chain = [];
    let x = e;
    while (t.ref.get(x) != null) { chain.push(x); x = t.ref.get(x); }
    for (let i = chain.length - 1; i >= 0; i--) {
      const c = chain[i], r = t.ref.get(c);
      t.side.set(c, (t.side.has(c) ? t.side.get(c) : 1) * (t.side.has(r) ? t.side.get(r) : 1));
      t.ref.set(c, null);
    }
    return t.side.has(e) ? t.side.get(e) : 1;
  };
  const depth = new Map();
  for (let v = 0; v < n; v++) for (const w of t.out[v]) { const e = v * n + w; depth.set(e, sign(e) * t.nesting.get(e)); }
  const R = new Rotation(n);
  const ordered = t.out.map((ws, v) => ws.slice().sort((a, b) => depth.get(v * n + a) - depth.get(v * n + b)));
  for (let v = 0; v < n; v++) { let prev = null; for (const w of ordered[v]) { R.addCW(v, w, prev); prev = w; } }
  const leftRef = new Int32Array(n).fill(-1), rightRef = new Int32Array(n).fill(-1), ind = new Int32Array(n);
  for (const root of t.roots) {
    const stack = [root];
    while (stack.length) {
      const v = stack.pop();
      while (ind[v] < ordered[v].length) {
        const w = ordered[v][ind[v]++], ei = v * n + w;
        if (ei === t.parentEdge[w]) {
          R.addFirst(w, v); leftRef[v] = w; rightRef[v] = w;
          stack.push(v, w);
          break;
        }
        if ((t.side.has(ei) ? t.side.get(ei) : 1) === 1) R.addCW(w, v, rightRef[w]);
        else { R.addCCW(w, v, leftRef[w]); leftRef[w] = v; }
      }
    }
  }
  // the check: every component's vertices less its edges plus its faces is two
  let faces = 0, verts = 0;
  const done = new Set();
  for (let v = 0; v < n; v++) if (R.cw[v].size !== adj[v].length) return null;
  for (let v = 0; v < n; v++) {
    if (R.cw[v].size) verts++;
    for (const w of R.around(v)) {
      if (done.has(v * n + w)) continue;
      faces++;
      let a = v, b = w, guard = 0;
      while (!done.has(a * n + b)) { done.add(a * n + b); const c = R.next(a, b); a = b; b = c; if (++guard > 4 * m + 8) return null; }
    }
  }
  let comps = 0;
  const mark = new Uint8Array(n);
  for (let v = 0; v < n; v++) {
    if (mark[v] || !adj[v].length) continue;
    comps++;
    const st = [v]; mark[v] = 1;
    while (st.length) { const x = st.pop(); for (const y of adj[x]) if (!mark[y]) { mark[y] = 1; st.push(y); } }
  }
  if (verts - m + faces !== 2 * comps) return null;
  return R;
}

/** The rotation system made a triangulation in place (NetworkX's triangulate_embedding): returns the outer triangle. */
function triangulate(R) {
  const n = R.n;
  // one component: each joined to the next
  const comp = new Int32Array(n).fill(-1), reps = [];
  for (let v = 0; v < n; v++) {
    if (comp[v] >= 0) continue;
    reps.push(v);
    const st = [v]; comp[v] = reps.length - 1;
    while (st.length) { const x = st.pop(); for (const y of R.cw[x].keys()) if (comp[y] < 0) { comp[y] = reps.length - 1; st.push(y); } }
  }
  for (let i = 0; i + 1 < reps.length; i++) { R.addFirst(reps[i], reps[i + 1]); R.addFirst(reps[i + 1], reps[i]); }
  const counted = new Set(), key = (a, b) => a * n + b;
  const faceList = [];
  let outer = [];
  for (let v = 0; v < n; v++) {
    for (const w of R.around(v)) {
      if (counted.has(key(v, w))) continue;
      counted.add(key(v, w));
      let v1 = v, v2 = w, v3 = R.next(v1, v2), guard = 0;
      const face = [v], set = new Set([v]);
      while (v2 !== v || v3 !== w) {
        if (v1 === v2 || ++guard > 8 * n * n + 64) throw new Error('bad half-edge');
        if (set.has(v2)) {
          R.addCW(v1, v3, v2); R.addCCW(v3, v1, v2);
          counted.add(key(v2, v3)); counted.add(key(v3, v1));
          v2 = v1;
        } else { set.add(v2); face.push(v2); }
        v1 = v2;
        const nv2 = v3, nv3 = R.next(v2, v3);
        v2 = nv2; v3 = nv3;
        counted.add(key(v1, v2));
      }
      faceList.push(face);
      if (face.length > outer.length) outer = face;
    }
  }
  for (const face of faceList) {
    let v1 = face[0], v2 = face[1];
    if (v2 == null) continue;
    let v3 = R.next(v1, v2), v4 = R.next(v2, v3), guard = 0;
    if (v1 === v2 || v1 === v3) continue;
    while (v1 !== v4) {
      if (++guard > 8 * n + 64) throw new Error('bad face');
      if (R.has(v1, v3)) { v1 = v2; v2 = v3; v3 = v4; }
      else { R.addCW(v1, v3, v2); R.addCCW(v3, v1, v2); v2 = v3; v3 = v4; }
      v4 = R.next(v2, v3);
    }
  }
  return [outer[0], outer[1], R.next(outer[0], outer[1])];
}

/**
 * A straight-line drawing of a planar graph on `n` vertices (points [x, y], in a triangle of side about 1000), from its embedding: null when the
 * graph isn't planar or the drawing of `edges` has two crossing (which Tutte's theorem rules out, but for rounding).
 */
export function planarDrawing(n, edges) {
  if (n === 0) return [];
  if (n === 1) return [[0, 0]];
  if (n === 2) return [[0, 0], [1000, 0]];
  const R = planarEmbedding(n, edges);
  if (!R) return null;
  let outer;
  try { outer = triangulate(R); } catch (e) { return null; }
  if (new Set(outer).size !== 3) return null;
  const X = new Array(n).fill(null);
  const H = Math.sqrt(3) / 2;
  X[outer[0]] = [0, 0]; X[outer[1]] = [1000, 0]; X[outer[2]] = [500, 1000 * H];
  const inner = [];
  for (let v = 0; v < n; v++) if (!X[v]) inner.push(v);
  const at = new Map(inner.map((v, i) => [v, i])), k = inner.length;
  if (k) {
    // the Laplacian of the inner vertices, solved by Gaussian elimination with partial pivoting
    const A = inner.map(() => new Float64Array(k + 2));
    inner.forEach((v, i) => {
      const nb = [...R.cw[v].keys()];
      A[i][i] = nb.length;
      for (const w of nb) {
        if (at.has(w)) A[i][at.get(w)] -= 1;
        else { A[i][k] += X[w][0]; A[i][k + 1] += X[w][1]; }
      }
    });
    for (let c = 0; c < k; c++) {
      let p = c;
      for (let r = c + 1; r < k; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
      if (Math.abs(A[p][c]) < 1e-12) return null;
      if (p !== c) { const tmp = A[p]; A[p] = A[c]; A[c] = tmp; }
      for (let r = c + 1; r < k; r++) {
        const f = A[r][c] / A[c][c];
        if (f === 0) continue;
        for (let j = c; j < k + 2; j++) A[r][j] -= f * A[c][j];
      }
    }
    const sol = new Array(k);
    for (let r = k - 1; r >= 0; r--) {
      let sx = A[r][k], sy = A[r][k + 1];
      for (let j = r + 1; j < k; j++) { sx -= A[r][j] * sol[j][0]; sy -= A[r][j] * sol[j][1]; }
      sol[r] = [sx / A[r][r], sy / A[r][r]];
    }
    inner.forEach((v, i) => { X[v] = sol[i]; });
  }
  if (countCrossings(X, edges)) return null;
  return X;
}

/** How many pairs of `edges` (index pairs) cross, drawn straight between the points `X`. */
export function countCrossings(X, edges) {
  let c = 0;
  const o = (a, b, p) => { const v = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]); return v > 1e-9 ? 1 : v < -1e-9 ? -1 : 0; };
  for (let i = 0; i < edges.length; i++) for (let j = i + 1; j < edges.length; j++) {
    const [a, b] = edges[i], [p, q] = edges[j];
    if (a === p || a === q || b === p || b === q) continue;
    if (o(X[a], X[b], X[p]) * o(X[a], X[b], X[q]) < 0 && o(X[p], X[q], X[a]) * o(X[p], X[q], X[b]) < 0) c++;
  }
  return c;
}
