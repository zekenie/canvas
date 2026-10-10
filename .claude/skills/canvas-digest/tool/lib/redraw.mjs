// Drawing a digest again in its place: what a drawing made (drawn.json), the script that takes it back, and which board is the target.
// Pure: the driver hands in canvas's answers and the plan.
import { q, fold } from './util.mjs';

// Titles as the app tells them apart: spaces folded, case kept ("canvas" beside "Canvas" is another shape).
const key = (t) => fold(t);
const union = (a, b) => [...new Set([...(a || []), ...(b || [])])];
// A file's path as the app lists it: /tmp, /var and /etc are links into /private.
const real = (p) => String(p).replace(/^\/(?=(tmp|var|etc)(\/|$))/, '/private/');

/**
 * One open board's field (`id`, `path`, `fileShapes` or `shows`) from `canvas boards`; the board is `front` for the one in front, or
 * its id, its file or its name, as `--board` takes them. A file or a name that two open boards have is refused, with their ids.
 */
export function boardField(boards, which, field, also) {
  const list = Array.isArray(boards) ? boards : [];
  const w = String(which);
  // a file as it was named, or as its links resolve (`also`, the driver's): the app lists the path a board was saved by
  const paths = [w].concat(also ? [String(also)] : []).map(real);
  let found = w === 'front' ? list.filter((b) => b.frontmost) : list.filter((b) => String(b.id) === w);
  if (w !== 'front' && !found.length) found = list.filter((b) => b.path && paths.includes(real(b.path)));
  if (w !== 'front' && !found.length) found = list.filter((b) => b.name === w);
  if (found.length > 1) throw new Error(`${found.length} open boards are ${w} (boards ${found.map((b) => b.id).join(', ')}): name the one by its id`);
  const board = found[0];
  if (!board) throw new Error(w === 'front' ? 'no board is open in the app: open one, or draw into a new file (--new-file PATH)' : `no open board is ${w} (canvas boards lists them)`);
  if (!['id', 'path', 'fileShapes', 'shows'].includes(field)) throw new Error(`board: ${field} is not id, path, fileShapes or shows`);
  const v = board[field];
  return v == null ? '' : v;
}

/** What is deleted to take a drawing back: its subboard, or each shape it put on the file's root. */
const takes = (drawn) => drawn.takes || (drawn.into ? [drawn.into] : drawn.root || []);
/** The subboards among them that a drawing went into (`--into`): the rest are shapes of the file's root board. */
const intos = (drawn) => drawn.intos || (drawn.into ? [drawn.into] : []);
const headers = (drawn) => union(drawn.header ? [drawn.header] : [], drawn.headers);
const count = (v) => (v == null || v === '' || isNaN(+v) ? null : +v);

/**
 * What a drawing of the plan makes, kept as drawn.json so a later run can take it back: the board's file (and its id, which is what tells
 * a board with no file yet), the subboard it went into (or null: the file's root), the digest's first board's header, the titles on that
 * board, what is deleted to take it back (`takes`: the subboard, or the root's shapes; `intos`: the subboards among them), every title,
 * and how many shapes the file held once it was drawn, or when it stopped (`shapes`: null while it is being drawn).
 *
 * `over` is the record of the drawing this one replaces, while this one is being drawn: until it is whole, an undo or two in the app
 * may bring that one back, so the record holds both drawings' titles, headers and what takes either back, and `was`, how many shapes
 * the file held just before the take-back (what one undo past this drawing's scripts brings back; kept for a drawing made as the board,
 * which is drawn only once the take-back has left the file empty, so the count is exactly the last drawing's, whichever way it was drawn).
 */
export function drawnRecord(plan, path, id, shapes, over, was) {
  const root = plan.boards.find((b) => b.board === 'root');
  const titles = [];
  if (plan.into) titles.push(plan.into);
  for (const b of plan.boards) for (const s of b.shapes) titles.push(s.title);
  const rec = { path: path || null, board: id == null || id === '' ? null : String(id), into: plan.into || null, header: root ? root.origin : null, root: root ? root.shapes.map((s) => s.title) : [], titles, shapes: count(shapes) };
  rec.takes = takes(rec); rec.intos = intos(rec);
  if (!over) return rec;
  return Object.assign(rec, {
    takes: union(rec.takes, takes(over)), intos: union(rec.intos, intos(over)), titles: union(rec.titles, over.titles), headers: union(headers(rec), headers(over)),
    was: rec.into ? null : count(was),
  });
}

/**
 * Whether the last drawing (drawn.json) is in this board's file: the same path, when both have one; or, for a drawing made on a board
 * with no file yet (which may have one since), the same board id and the drawing's header still in the file (`titles`: an id is the
 * app's for as long as it runs, and a later board may get it).
 */
export function sameFile(drawn, path, id, titles) {
  if (!drawn) return false;
  if (drawn.path) return !!path && real(drawn.path) === real(path);
  if (drawn.board == null || id == null || id === '' || drawn.board !== String(id)) return false;
  // its header, or the subboard it went into: one that stopped after its first script has the subboard and no header yet
  const mine = new Set(headers(drawn).concat(intos(drawn)).map(key));
  return Array.isArray(titles) && titles.some((t) => mine.has(key(t)));
}

/**
 * Shapes the file holds beyond the last drawing (one drawn as the board): titled or not, an arrow or a note the user added. The file
 * may hold as many as the drawing made (`shapes`; fewer is part of it, or some of it undone) or, for a drawing that replaced another
 * and stopped, exactly as many as the file held before (`was`: the other one, undone back). 0 when no count is known.
 */
export function beyond(drawn, fileShapes) {
  if (!drawn || drawn.into) return 0;
  const n = +fileShapes, now = count(drawn.shapes), was = count(drawn.was);
  if (now == null && was == null) return 0;
  if ((now != null && n <= now) || n === was) return 0;
  if (now == null) return Math.max(0, n - was);   // stopped before a count was taken: under the last drawing's, it may be part of this one
  return n - (was != null && was < n ? Math.max(now, was) : now);
}

/** The file's titles less the ones the last drawing made: what a new drawing in its place has to keep clear of. */
export function minus(titles, drawn) {
  const ours = new Set((drawn.titles || []).map(key));
  return titles.filter((t) => !ours.has(key(t)));
}

/** The titles in the file that the last drawing didn't make: shapes a drawing on the file's root would be drawn among. */
export function foreign(titles, drawn) {
  return minus(titles, drawn);
}

/**
 * The script that takes the last drawing back: its subboard, which takes its board with it, or each shape it put on the file's root (the
 * subboards among them take their boards, a shape's arrows and pills go with it). Only titles the file still holds: a drawing that stopped
 * part way is taken back as far as it got. Empty when there is nothing to take back.
 *
 * `rootTitles` are the titles on the file's root board. A shape a drawing put on the root is taken back only where it is on the root:
 * the record of two drawings (drawnRecord's `over`) names the takes of both, and a title that one has on the root the other may hold
 * inside a subboard, where its subboard takes it (and where a `delete` of it would put the script on two boards, which draw refuses).
 */
export function replaceScript(drawn, titles, rootTitles) {
  const have = new Set(titles.map(key)), onRoot = rootTitles ? new Set(rootTitles.map(key)) : have;
  const into = new Set(intos(drawn).map(key));
  return takes(drawn).filter((t) => (into.has(key(t)) ? have : onRoot).has(key(t))).map((t) => `delete ${q(t)}`).join('\n');
}

/** Whether the file holds a title, as a new shape's title is checked against it: spaces folded, case apart or not. */
export function hasTitle(titles, title) {
  const t = fold(title).toLowerCase();
  return titles.some((x) => fold(x).toLowerCase() === t);
}
