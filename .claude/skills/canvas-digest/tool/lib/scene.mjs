// A drawing as obstacles on grids (the cut's last passes, share.mjs and restore.mjs, ask them what is clear): its notes (and their titles' room),
// frames and pills, and every segment of every line, each on or off, so a pass tries a change and takes it back. Nothing here decides a layout.
import { arrowPath, segCross, segHitsBox, cellsOf, cellsAlong } from './geom.mjs';
import { HEALTH } from './health.mjs';

export const LEAF = 0, HOLDS = 1, PILL = 2;   // what a solid on the grid is: a note (or its title's room), a shape that holds shapes, a pill
export const MARGIN = HEALTH.margin, GAP = 16, CELL = 320;

const segsOf = (path) => { const out = []; for (let j = 1; j < path.length; j++) out.push({ x1: path[j - 1][0], y1: path[j - 1][1], x2: path[j][0], y2: path[j][1] }); return out; };
export const near = (a, b, g) => a.x < b.x + b.w + g && b.x < a.x + a.w + g && a.y < b.y + b.h + g && b.y < a.y + a.h + g;
export const within = (a, b, g) => a.x >= b.x + g && a.y >= b.y + g && a.x + a.w <= b.x + b.w - g && a.y + a.h <= b.y + b.h - g;

/** Items on a grid of cells, each with an `on` flag (taken off rather than removed): boxes by the cells they cover, segments by those they pass. */
export class Grid {
  constructor() { this.cells = new Map(); this.n = 0; }
  put(k, it) { let l = this.cells.get(k); if (!l) this.cells.set(k, l = []); l.push(it); }
  addBox(it) { it.n = this.n++; cellsOf(it.box.x, it.box.y, it.box.x + it.box.w, it.box.y + it.box.h, CELL, (k) => this.put(k, it)); }
  addSeg(it) { it.n = this.n++; cellsAlong(it.seg, CELL, (k) => this.put(k, it)); }
  /** What is on in the cells a box covers, or a segment passes, each once, in the order put. */
  inBox(b, g) { const out = new Map(); cellsOf(b.x - g, b.y - g, b.x + b.w + g, b.y + b.h + g, CELL, (k) => { for (const it of this.cells.get(k) || []) if (it.on()) out.set(it.n, it); }); return [...out.keys()].sort((p, q) => p - q).map((k) => out.get(k)); }
  along(s) { const out = new Map(); cellsAlong(s, CELL, (k) => { for (const it of this.cells.get(k) || []) if (it.on()) out.set(it.n, it); }); return [...out.keys()].sort((p, q) => p - q).map((k) => out.get(k)); }
}

/**
 * A drawing as obstacles on grids: its notes (and their titles' room), frames and pills (`solids`), and every segment of every line
 * (`lines`). A pill is on or off by its key (`pill`), and a line into a pill with it.
 */
export class Scene {
  constructor(model, layout, B) {
    this.m = model; this.solids = new Grid(); this.lines = new Grid(); this.pills = []; this.noteBox = new Map();
    for (const s of B.shapes) {
      if (s.frame) { this.solids.addBox({ kind: HOLDS, id: s.id, box: s.box, on: () => true }); continue; }
      this.noteBox.set(s.id, s.box);
      this.solids.addBox({ kind: LEAF, id: s.id, box: s.box, on: () => true });
      if (s.tab) this.solids.addBox({ kind: LEAF, id: s.id, box: s.tab, on: () => true });
    }
    this.at = layout.pills.map((p) => this.addPill({ x: p.x, y: p.y, w: p.w, h: p.h }));   // layout pill index -> key
    for (const l of B.lines) this.addLine(l.a, l.intoPill ? this.at[+l.b.slice(1)] : -1, segsOf(l.path), l.b);
  }
  /** A pill put on the grid, on: its key. */
  addPill(box) { const k = this.pills.length, it = { kind: PILL, id: '\u0002' + k, box, live: true }; it.on = () => it.live; this.pills.push(it); this.solids.addBox(it); return k; }
  setPill(k, on) { this.pills[k].live = on; }
  /** A line from `a` (into the pill `pill`, or -1), on while its pill is; `b` its other end's id. */
  addLine(a, pill, segs, b) {
    const it = this.pills[pill], line = { a, b: pill >= 0 ? it.id : b, on: pill >= 0 ? () => it.live : () => true };
    for (const seg of segs) this.lines.addSeg({ seg, line, on: line.on });
  }
  /** Whether a pill's box is clear: of every note and title room by the gap (but `self`'s), of every frame but those that hold it, of every pill, and of every line by the margin. */
  boxClear(box, holders, self) {
    for (const it of this.solids.inBox(box, GAP)) {
      if (it.kind === HOLDS && holders.has(it.id)) continue;
      if (self != null && it.kind === LEAF && it.id === self) continue;
      if (near(box, it.box, GAP)) return false;
    }
    for (const it of this.lines.inBox(box, MARGIN)) if (segHitsBox(it.seg, box, -MARGIN)) return false;
    return true;
  }
  /** The segments of a user's lines into a pill at `box`: as many as its edge draws, bowed apart as the app bows them. */
  linePaths(u, box, e) {
    const out = [], A = this.noteBox.get(u), n = Math.max(1, (e && e.items.length) || 1);
    for (let k = 0; k < n; k++) {
      const steps = k % 2 ? (k + 1) / 2 : -(k / 2);
      for (const s of segsOf(arrowPath(A, box, -steps * HEALTH.pairBend, HEALTH.samples))) out.push(s);
    }
    return out;
  }
  /** Whether a user's lines into a pill at `box` (whose id is `pid`) cross no line but those at either end and run over no shape or pill but their ends. */
  reaches(u, box, pid, holders, e) {
    const mine = new Set(this.m.node(u).frames);
    for (const h of holders) mine.add(h);
    for (const seg of this.linePaths(u, box, e)) {
      for (const it of this.solids.inBox({ x: Math.min(seg.x1, seg.x2), y: Math.min(seg.y1, seg.y2), w: Math.abs(seg.x2 - seg.x1), h: Math.abs(seg.y2 - seg.y1) }, MARGIN)) {
        if (it.kind === LEAF && it.id === u) continue;
        if (it.kind === HOLDS && mine.has(it.id)) continue;
        if (it.id === pid) continue;
        if (segHitsBox(seg, it.box, -MARGIN)) return false;
      }
      for (const it of this.lines.along(seg)) {
        const l = it.line;
        if (l.a === u || l.b === u || l.a === pid || l.b === pid) continue;
        if (segCross(seg, it.seg)) return false;
      }
    }
    return true;
  }
}
