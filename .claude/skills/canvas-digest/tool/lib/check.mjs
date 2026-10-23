// The checks on a digest before anything is measured or drawn. Pure: what the file and the app know comes in as options.
import { buildModel, readNodes, MAX_TITLE } from './model.mjs';
import { typeProblems } from './types.mjs';
import { fold, label } from './util.mjs';

export const KINDS = ['sticky-note', 'frame', 'subboard', 'auto'];
export { MAX_TITLE };
export const MAX_IN_FRAME = 15, MAX_ON_BOARD = 150;

/**
 * digest, and options {existing: titles already in the file, kinds: the kinds `canvas kinds` lists, into: the --into title}. Returns {errors, warnings}:
 * errors stop the run. Refuses (naming the nodes) two nodes of one title in one container (a title is unique among the nodes in one container, case aside,
 * and may repeat in two), two of one id or an id that is no non-empty string, an `in`, `from` or `to` that names no node or a title several have, two types
 * of one title (`is` names a type by its title) and titles over 80 characters; kinds the app does not list or the tool cannot lay out; and everything the
 * model refuses (a cycle in `in`, a frame that is public), and what is wrong with how shapes and edges are typed (`typeProblems`: an `is` that names no
 * type, `endRule` on an edge that is no end, values that don't fit their schema...). Of the titles in the file it refuses only those draw could still find
 * a shape outside the drawing by: the --into title and the titles of types (`is:` finds a type anywhere in the file); the scripts name every other node
 * so that nothing outside the drawing can be meant (names.mjs). Warns past 15 children in a frame or 150 shapes on a board.
 */
export function checkDigest(digest, opts = {}) {
  const errors = [], warnings = [];
  const existing = new Set((opts.existing || []).map((t) => fold(t).toLowerCase()));
  const known = opts.kinds ? new Set(opts.kinds) : null;
  const into = opts.into ? fold(opts.into) : null;   // the title of the subboard the digest is drawn into: a shape of the digest, and the file's, would share it
  if (into) {
    if (!into.length || into.length > MAX_TITLE) errors.push(`--into "${into}" is empty or over ${MAX_TITLE} characters`);
    if (existing.has(into.toLowerCase())) errors.push(`--into "${into}" is already on a board in the file; titles are file-wide`);
  }
  const read = readNodes(digest);
  for (const e of read.errors) errors.push(e);
  for (const it of read.items) {
    const t = it.title;
    if (into && t.toLowerCase() === into.toLowerCase()) errors.push(`"${t}" is also the --into title; the subboard that holds the digest can't share a title with a node`);
    if (it.raw.schema != null && existing.has(t.toLowerCase())) errors.push(`"${t}" is a type, and the file already has a shape of that title: is: finds a type anywhere in the file by its title, so a type's title is the file's alone`);
    const kind = it.raw.kind || 'sticky-note';
    if (!KINDS.includes(kind)) errors.push(`"${t}": kind ${kind} is not one the digest lays out (sticky-note, frame, subboard or auto)`);
    else if (known && kind !== 'auto' && !known.has(kind)) errors.push(`"${t}": the app has no kind ${kind}`);
  }
  if (errors.length) return { errors, warnings };
  let model;
  try { model = buildModel(digest); } catch (e) { return { errors: [e.message], warnings }; }
  for (const w of model.warnings) warnings.push(w);
  const typed = typeProblems(model);
  for (const m of typed.errors) errors.push(m);
  for (const m of typed.warnings) warnings.push(m);
  for (const [cid, kids] of model.kids) {
    if (cid[0] === 'f' && kids.length > MAX_IN_FRAME) warnings.push(`frame "${label(cid.slice(2))}" holds ${kids.length} shapes; past ${MAX_IN_FRAME} it reads as a crowd (split it, or make it a subboard)`);
    if (cid[0] === 'b') {
      const onBoard = [...model.nodes.values()].filter((n) => n.board === cid.slice(2) && n.kind !== 'frame').length;
      if (onBoard > MAX_ON_BOARD) warnings.push(`board "${label(cid.slice(2))}" has ${onBoard} shapes; past ${MAX_ON_BOARD} a board is hard to read (make a subboard of a part)`);
    }
  }
  return { errors, warnings };
}
