// How the scripts name the shapes of a drawing. Every name a run writes (a shape statement's own name and its `in`, a placement's target, an edge's
// ends, `share:`'s host, a card whose description is written, a take-back's deletes) must name exactly the shape meant, whatever else the file holds
// and whatever else the digest repeats. Pure: it reads the model and what the file's titles are, and the same under jsc and node.
//
// What `canvas draw` does with a name (language.md, "Titles are the names" and "Paths"):
//   - a title names the one shape that has it on the board the run draws on; but which board that is, a run's statements decide by the boards their titles
//     are on, and a title on the board the window shows counts before any other: a title the file has beside the drawing can pull a run onto another
//     board, and so can one the drawing has on the window's board and on another (the first board, as the board itself);
//   - `in "X"` takes a title or a path, and finds a container among all the file's, the window's board's first;
//   - an edge's end on another board is found among all the file's boards;
//   - a path (`"Cart" > "Checkout"`) names every shape whose chain of containers ends with its parts, each directly inside the one before; its first
//     part is a container looked up wherever the file has one, or the word `board` (the top of the board the run draws on).
// So a name is bare (`"T"`) only where it can mean nothing but the shape:
//   - its own name, in a statement that says where it goes (`in`): when no other shape of its board has the title (draw looks inside the container first,
//     and then on the board);
//   - an edge's end, or a card whose description is written, on the board of the run: when no other shape of the board has the title, and no shape of
//     the file beside the drawing (none of the digest's other boards, which draw might take for the board of the run; the board that is the window's,
//     when the digest is the board itself, is the exception: a title that board has is taken for it);
//   - a container, `in` it, and an edge's end on another board: when no other node of the digest has the title, nor any shape of the file.
// Anywhere else it is a path, which cannot mean anything else either: the shortest tail of the node's containers and title that no other node ends
// with, and that has a part the file has nothing called (so nothing outside the drawing has a chain through it); failing that one that starts at the
// `--into` card, whose title is free in the file (`check` refuses it otherwise); failing that, when the drawing is the board itself (the file holds
// nothing else), `board >` from the top of the first board, which only a run on that board can write (and not as the start of an edge to another board).
import { q, fold } from './util.mjs';

/** A path as draw writes it. */
export const BOARD = '\u0000board';   // the head of a path that starts at the top of the board the run draws on
export const written = (parts) => parts.map((p, i) => (i === 0 && p === BOARD ? 'board' : q(p))).join(' > ');

export class Spelling {
  /**
   * model; into: the title of the subboard the whole digest goes in (null: the digest is the board itself, and nothing else is in the file);
   * existing: the titles the file holds beside the drawing (an array or a Set; unknown: none), which matter only with `into`.
   */
  constructor(model, into, existing) {
    this.model = model;
    this.into = into || null;
    this.existing = this.into ? new Set([...(existing || [])].map(fold)) : new Set();
    this.byTitle = new Map();   // exact title -> the nodes that have it
    for (const n of model.nodes.values()) {
      if (!this.byTitle.has(n.title)) this.byTitle.set(n.title, []);
      this.byTitle.get(n.title).push(n);
    }
    this.cache = new Map();
    this.titleOf = (key) => model.node(key).title;
    this.absent = new Set();   // the titles a name relies on the file not having, for the draw to check again
  }

  /** The containers a node is in, outermost first, as their titles. */
  chainTitles(n) { return n.chain.map(this.titleOf); }

  /** Whether `n` is the only node that a path (its container parts, then a title) names. */
  only(n, parts) {
    const containers = parts.slice(0, -1);
    for (const m of this.byTitle.get(parts[parts.length - 1]) || []) {
      if (m === n) continue;
      const chain = this.chainTitles(m);
      if (containers.length <= chain.length && containers.every((p, i) => chain[chain.length - containers.length + i] === p)) return false;
    }
    return true;
  }

  /** How many nodes have this title, and how many of them are on this board. */
  count(title, board) {
    const list = this.byTitle.get(title) || [];
    return board === undefined ? list.length : list.filter((m) => m.board === board).length;
  }

  /** Whether a bare title means node `n` alone in this role: 'own' (a statement's own name, with an `in`), 'container' (`in` it, a placement's target), 'end' (an edge's end, a card). */
  bareOk(n, role, board) {
    const free = !this.existing.has(n.title);
    if (role === 'own') return this.count(n.title, n.board) === 1;
    if (role === 'container') return free && this.count(n.title) === 1;
    if (n.board !== board) return free && this.count(n.title) === 1;   // an end on another board
    return free && this.count(n.title, n.board) === 1 && (this.count(n.title) === 1 || (!this.into && board === 'root'));
  }

  /** The way to name node `key` by a path that means it alone: {parts, bare: false}. */
  path(key) {
    if (this.cache.has(key)) return this.cache.get(key);
    const n = this.model.node(key);
    const all = this.chainTitles(n).concat([n.title]);
    let out;
    for (let k = 2; k <= all.length && !out; k++) {
      const parts = all.slice(-k);
      const free = parts.slice(0, -1).find((p) => !this.existing.has(p));
      if (this.only(n, parts) && (!this.into || free !== undefined)) out = { bare: false, parts, needs: this.into ? [free] : [] };
    }
    if (!out && this.into) out = { bare: false, parts: [this.into].concat(all), needs: [] };
    if (!out && n.board === 'root') out = { bare: false, parts: [BOARD].concat(all), needs: [], board: 'root' };
    if (!out) out = { bare: false, parts: null, needs: [] };
    this.cache.set(key, out);
    return out;
  }

  /**
   * The text that names node `key` in a run drawing on `board`, in a role (see the top): a bare title where that means the node alone, else a path.
   * A name that starts at the board the run draws on (`board >`) can be written only in a run on it. Throws when no name means the node alone.
   */
  name(key, board, role) {
    const n = this.model.node(key);
    if (this.bareOk(n, role || 'end', board)) {
      if (this.into && role !== 'own') this.absent.add(n.title);
      return q(n.title);
    }
    const s = this.path(key);
    if (!s.parts) throw new Error(`cannot name "${n.title}" (${key.replace('  in ', ', in ')}) so that the app can tell it from the other shapes with that title: give the shapes that hold it, or it, titles that tell them apart`);
    if (s.board && board !== s.board) throw new Error(`cannot name "${n.title}" from another board: the drawing is the board itself, and "${n.title}" has the title of a shape deeper in it, which only a path from the top of the first board tells apart`);
    for (const t of s.needs) this.absent.add(t);
    return written(s.parts);
  }

  /**
   * What a shape statement writes for its own name and for where it goes: {name, in}. A bare title goes with an `in` (the frame or subboard that
   * holds it, else the `--into` card, else none: the board itself); a path says where the shape is, and takes no `in`.
   */
  own(key) {
    const n = this.model.node(key);
    if (this.bareOk(n, 'own', n.board)) return { name: q(n.title), in: n.parent ? this.name(n.parent, n.board, 'container') : this.into ? q(this.into) : null };
    return { name: this.name(key, n.board, 'own'), in: null };
  }
}
