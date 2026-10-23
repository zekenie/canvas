// Drawing a digest again in its place: what a drawing made (drawn.json), the script that takes it back, and which board is the target.
// Pure: the driver hands in canvas's answers and the plan.
import { q, fold } from './util.mjs';
import { placesOf, placeKey, deleteNames, shapeKey as shapeKeyOf } from './places.mjs';

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

/**
 * The room an open board's window has for a board fit to it, as `--view` takes it (`1312x772`), from `canvas boards`' `view`; '' when no
 * such board is open (`front`: none is in front) or its window has no size. The board is `front` or an id.
 */
export function boardView(boards, which) {
  const list = Array.isArray(boards) ? boards : [];
  const w = String(which);
  const board = w === 'front' ? list.find((b) => b.frontmost) : list.find((b) => String(b.id) === w);
  const v = board && board.view;
  return Array.isArray(v) && v[0] > 0 && v[1] > 0 ? `${Math.round(v[0])}x${Math.round(v[1])}` : '';
}

/**
 * What is deleted to take a drawing back: its subboard, or each shape it put on the file's root, each `{place, name}`: the place it is at in the file
 * (the containers it is in, outermost first, then its title: what a query says of a shape) and the name `delete` is given, which means that shape alone.
 */
const takes = (drawn) => drawn.takes || (drawn.into ? [{ place: [drawn.into], name: q(drawn.into), into: true }] : drawn.root || []);
const takeKey = (t) => placeKey(t.place.slice(0, -1), t.place[t.place.length - 1]);
/**
 * The names a record's drawings are told by in a board with no file (two while a drawing made in place of another is not yet whole): the
 * subboard each went into, else its digest's title. Only one digest is the board itself, and a subboard's title is the file's alone.
 */
const names = (drawn) => union(drawn.name ? [drawn.name] : [], drawn.names);
const count = (v) => (v == null || v === '' || isNaN(+v) ? null : +v);

/**
 * What a drawing of the plan makes, kept as drawn.json so a later run can take it back: the board's file (and its id, which is what tells
 * a board with no file yet), the subboard it went into (or null: the file's root), its name (that subboard, else the digest's title),
 * the shapes on its first board (`root`, each with its place and the name `delete` takes it by), what is deleted to take it back (`takes`: the
 * subboard, or the root's shapes), every title (`titles`) and the place of every shape (`places`: the containers
 * it is in, then its title, as a query's row says it), and how many shapes the file held once it was drawn, or when it stopped (`shapes`: null while it is
 * being drawn). `at` is when it was written (the clock's milliseconds, handed in), which is how the newest of two records of one board is told without
 * looking at file times.
 *
 * `over` is the record of the drawing this one replaces, while this one is being drawn: until it is whole, an undo or two in the app
 * may bring that one back, so the record holds both drawings' titles, names and what takes either back, and `was`, how many shapes
 * the file held just before the take-back (what one undo past this drawing's scripts brings back; kept for a drawing made as the board,
 * which is drawn only once the take-back has left the file empty, so the count is exactly the last drawing's, whichever way it was drawn).
 */
export function drawnRecord(plan, path, id, shapes, over, was, at) {
  const where = placesOf(plan);
  const titles = [], places = [];
  if (plan.into) { titles.push(plan.into); places.push([plan.into]); }
  for (const b of plan.boards) for (const s of b.shapes) { titles.push(s.title); places.push(where.containers(shapeKeyOf(s)).concat([s.title])); }
  const root = deleteNames(plan);
  const rec = { path: path || null, board: id == null || id === '' ? null : String(id), into: plan.into || null, name: plan.into || plan.title || null, root, titles, places, shapes: count(shapes), at: count(at) };
  rec.takes = takes(rec);
  if (!over) return rec;
  const merged = new Map();
  for (const t of takes(rec).concat(takes(over))) if (!merged.has(takeKey(t))) merged.set(takeKey(t), t);
  const seen = new Set(), both = [];
  for (const p of (rec.places || []).concat(over.places || [])) { const k = p.join('\u0000'); if (!seen.has(k)) { seen.add(k); both.push(p); } }
  return Object.assign(rec, {
    takes: [...merged.values()], titles: union(rec.titles, over.titles), places: both, names: union(names(rec), names(over)),
    was: rec.into ? null : count(was),
  });
}

/**
 * Whether the last drawing (drawn.json) is in this board's file: the same path, when both have one; or, for a drawing made on a board
 * with no file yet (which may have one since), the same board id and a shape of the drawing still in the file (`titles`: an id is the
 * app's for as long as it runs, and a later board may get it).
 */
export function sameFile(drawn, path, id, places) {
  if (!drawn) return false;
  if (drawn.path) return !!path && real(drawn.path) === real(path);
  if (drawn.board == null || id == null || id === '' || drawn.board !== String(id)) return false;
  // what takes it back: the shapes it put on the file's root, or the subboard it went into (a place in the file is its own, whatever title another shape has)
  const mine = new Set(takes(drawn).map(takeKey));
  return Array.isArray(places) && places.some((p) => mine.has(placeKey(p.inside, p.title)));
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

/**
 * The titles of the file's shapes less those of the last drawing's own, by place (`places`: what the file holds, as `canvas query` says it): what a new
 * drawing in its place has to keep clear of. A shape of the file that has a title the drawing has too, somewhere else, is not the drawing's.
 */
export function minus(places, drawn) {
  const ours = new Set((drawn.places || []).map((p) => placeKey(p.slice(0, -1), p[p.length - 1])));
  return places.filter((p) => !ours.has(placeKey(p.inside, p.title))).map((p) => p.title);
}

/** The shapes in the file that the last drawing didn't make, by place: shapes a drawing on the file's root would be drawn among. As their places read, `a > b > title`. */
export function foreign(places, drawn) {
  const ours = new Set((drawn.places || []).map((p) => placeKey(p.slice(0, -1), p[p.length - 1])));
  return places.filter((p) => !ours.has(placeKey(p.inside, p.title))).map((p) => (p.inside || []).concat([p.title]).join(' > '));
}

/**
 * The script that takes the last drawing back: its subboard, which takes its board with it, or each shape it put on the file's root (the
 * subboards among them take their boards, a shape's arrows and pills go with it), each by the name that means that shape alone. Only shapes the file
 * still holds, by place: a drawing that stopped part way is taken back as far as it got. Empty when there is nothing to take back.
 *
 * `rootPlaces` are the places of the shapes on the file's root board. A shape a drawing put on the root is taken back only where it is on the root:
 * the record of two drawings (drawnRecord's `over`) names the takes of both, and a title that one has on the root the other may hold
 * inside a subboard, where its subboard takes it (and where a `delete` of it would put the script on two boards, which draw refuses).
 */
export function replaceScript(drawn, places, rootPlaces) {
  const at = (list) => new Set(list.map((p) => placeKey(p.inside, p.title)));
  const have = at(places), onRoot = rootPlaces ? at(rootPlaces) : have;
  return takes(drawn).filter((t) => (t.into ? have : onRoot).has(takeKey(t))).map((t) => `delete ${t.name}`).join('\n');
}

/** Whether the file holds a title, as a new shape's title is checked against it: spaces folded, case apart or not. */
export function hasTitle(titles, title) {
  const t = fold(title).toLowerCase();
  return titles.some((x) => fold(x).toLowerCase() === t);
}

/**
 * Which of a folder of drawing records (`records`: [{name, record}], one per target file; `--records DIR`) is the last drawing in this
 * board's file: the one `sameFile` says, a record with a path before one told by the board's id, so that a file is its own record's
 * and never another's. Of several that are told by the id (two digests drawn into one unsaved board have a record each), the one named
 * `name`, this run's own (`names`), then the newest by the `at` written in it, then by file name: never the file times, so the pick is the
 * same for the same folder. The name of the record's file, or '' when no record is of this file.
 */
export function pickRecord(records, path, id, places, name) {
  const mine = name ? key(name) : null;
  const rank = (r) => (mine && names(r.record).some((h) => key(h) === mine) ? 0 : 1);
  const list = (records || []).slice().sort((a, b) => rank(a) - rank(b) || (count(b.record.at) || 0) - (count(a.record.at) || 0) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const hit = (withPath) => list.find((r) => !!r.record.path === withPath && sameFile(r.record, path, id, places));
  const found = hit(true) || hit(false);
  return found ? found.name : '';
}

/** Whether a board with this id could be told only by the file's titles: a record of a drawing made on a board with no file, of this id. */
export function needsTitles(records, id) {
  return id != null && id !== '' && (records || []).some((r) => !r.record.path && r.record.board === String(id));
}

/**
 * The files of a records folder read as records: `read(name)` gives a file's JSON (or throws). What is not JSON, or is not a record (a
 * drawing record has a `titles` list), is `skipped` with why, so that one stray file in the folder never stops a run.
 */
export function readRecords(names, read) {
  const records = [], skipped = [];
  for (const name of names) {
    let record;
    try { record = read(name); } catch (e) { skipped.push({ name, why: 'not JSON' }); continue; }
    if (record === null || typeof record !== 'object' || Array.isArray(record) || !Array.isArray(record.titles)) skipped.push({ name, why: 'not a drawing record: it has no titles list' });
    else records.push({ name, record });
  }
  return { records, skipped };
}

// Two 32-bit FNV-1a hashes of a text with different offsets, as 16 hex digits: a name for a record, not a secret.
function digestOf(text) {
  let a = 0x811c9dc5, b = 0x01000193;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    a = Math.imul(a ^ c, 0x01000193) >>> 0;
    b = Math.imul(b ^ c, 0x85ebca6b) >>> 0;
  }
  return (a.toString(16).padStart(8, '0') + b.toString(16).padStart(8, '0'));
}

/**
 * The file name of a new drawing record: for a board with a file, a hash of the file's path (so the same file has the same record
 * again); for one with none yet, its id and a hash of the drawing's name (`name`: the subboard it goes into, else the digest's title).
 */
export function recordName(path, id, name) {
  if (path) return `file-${digestOf(real(path))}.json`;
  return `board-${String(id).replace(/[^0-9A-Za-z_-]/g, '')}-${digestOf(String(name || ''))}.json`;
}
