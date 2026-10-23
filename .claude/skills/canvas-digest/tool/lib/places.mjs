// Where the shapes of a plan are, read from the plan alone: the containers each is in (the `--into` card, the subboards above its board and its frames,
// outermost first, as titles), which is what `canvas query` says of a shape in the file (`inside`), so a drawing is found in the file by the place
// of each shape, never by a title that another shape may share. Pure.
import { q } from './util.mjs';
import { written, BOARD } from './names.mjs';

/** How a plan's shape is told apart from the others: its id when it has one, else its key (a title that more than one shape has is qualified), else its title. */
export const shapeKey = (s) => (s.id != null ? s.id : s.key != null ? s.key : s.title);

/** A place as one string: the containers outermost first, then the title. */
export const placeKey = (containers, title) => (containers || []).concat([title]).join('\u0000');

/** The places of a plan's shapes: {byKey: key -> {shape, board, title, frames, containers}, boardChain(board)}. */
export function placesOf(plan) {
  const byKey = new Map();
  for (const b of plan.boards) for (const s of b.shapes) byKey.set(shapeKey(s), { shape: s, board: b.board, title: s.title });
  const memo = new Map();
  const frames = (key) => {
    const e = byKey.get(key);
    return e.shape.in != null ? frames(e.shape.in).concat([byKey.get(e.shape.in).title]) : [];
  };
  const boardChain = (board) => {
    if (board === 'root') return plan.into ? [plan.into] : [];
    if (!memo.has(board)) { const card = byKey.get(board); memo.set(board, containers(board).concat([card.title])); }
    return memo.get(board);
  };
  const containers = (key) => boardChain(byKey.get(key).board).concat(frames(key));
  for (const [key, e] of byKey) { e.frames = frames(key); e.containers = containers(key); }
  return { byKey, boardChain, containers: (key) => byKey.get(key).containers, place: (key) => placeKey(byKey.get(key).containers, byKey.get(key).title) };
}

/**
 * How a take-back names each shape on the plan's first board: `delete <name>` must mean exactly that shape among the file's shapes there (the file's
 * root board holds only the drawing: a digest drawn as the board goes only on an empty one). A bare title where only one shape of the board has it; else the
 * shortest tail of its frames and title that no other shape of the board ends with; else the frames from the top of the board (`board >`).
 * Returns [{place: [containers..., title], name}] in the order of the plan's shapes.
 */
export function deleteNames(plan) {
  const root = plan.boards.find((b) => b.board === 'root');
  if (!root) return [];
  const places = placesOf(plan);
  const rootShapes = root.shapes.map((s) => ({ s, key: shapeKey(s), frames: places.byKey.get(shapeKey(s)).frames }));
  const byTitle = new Map();
  for (const r of rootShapes) { if (!byTitle.has(r.s.title)) byTitle.set(r.s.title, []); byTitle.get(r.s.title).push(r); }
  const only = (r, parts) => {
    const containers = parts.slice(0, -1);
    return !byTitle.get(parts[parts.length - 1]).some((m) => m !== r && containers.length <= m.frames.length && containers.every((p, i) => m.frames[m.frames.length - containers.length + i] === p));
  };
  return rootShapes.map((r) => {
    const place = places.byKey.get(r.key).containers.concat([r.s.title]);
    if (byTitle.get(r.s.title).length === 1) return { place, name: q(r.s.title) };
    const all = r.frames.concat([r.s.title]);
    for (let k = 2; k <= all.length; k++) if (only(r, all.slice(-k))) return { place, name: written(all.slice(-k)) };
    return { place, name: written([BOARD].concat(all)) };
  });
}
