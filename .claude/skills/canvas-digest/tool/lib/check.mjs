// The checks on a digest before anything is measured or drawn. Pure: what the file and the app know comes in as options.
import { buildModel } from './model.mjs';
import { typeProblems } from './types.mjs';
import { fold } from './util.mjs';

export const KINDS = ['sticky-note', 'frame', 'subboard', 'auto'];
export const MAX_TITLE = 80, MAX_IN_FRAME = 15, MAX_ON_BOARD = 150;

/**
 * digest, and options {existing: titles already in the file, kinds: the kinds `canvas kinds` lists}. Returns {errors, warnings}: errors stop the run.
 * Refuses duplicate titles (folded, case aside), titles over 80 characters, titles already in the file, kinds the app does not list or the tool
 * cannot lay out, and everything the model refuses (an unknown `in`, an edge to nothing), and what is wrong with how shapes and edges are typed
 * (`typeProblems`: an `is` that names no type, `endRule` on an edge that is no end, values that don't fit their schema...). Warns past 15 children
 * in a frame or 150 shapes on a board.
 */
export function checkDigest(digest, opts = {}) {
  const errors = [], warnings = [];
  const seen = new Map();
  const existing = new Set((opts.existing || []).map((t) => fold(t).toLowerCase()));
  const known = opts.kinds ? new Set(opts.kinds) : null;
  const into = opts.into ? fold(opts.into) : null;   // the title of the subboard the digest is drawn into: a shape of the digest, and the file's, would share it
  if (into) {
    if (!into.length || into.length > MAX_TITLE) errors.push(`--into "${into}" is empty or over ${MAX_TITLE} characters`);
    if (existing.has(into.toLowerCase())) errors.push(`--into "${into}" is already on a board in the file; titles are file-wide`);
  }
  for (const n of digest.nodes || []) {
    const t = fold(n.title);
    if (!t) { errors.push('a node has no title'); continue; }
    const key = t.toLowerCase();
    if (seen.has(key)) errors.push(`duplicate title "${t}"` + (seen.get(key) === t ? '' : ` (also "${seen.get(key)}")`));
    else seen.set(key, t);
    if (t.length > MAX_TITLE) errors.push(`"${t}" is over ${MAX_TITLE} characters`);
    if (into && key === into.toLowerCase()) errors.push(`"${t}" is also the --into title; the subboard that holds the digest can't share a title with a node`);
    if (existing.has(key)) errors.push(`"${t}" is already on a board in the file; titles are file-wide`);
    const kind = n.kind || 'sticky-note';
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
  for (const h of model.headers.values()) if (existing.has(h.toLowerCase())) errors.push(`the board's header "${h}" is already in the file`);
  for (const [cid, kids] of model.kids) {
    if (cid[0] === 'f' && kids.length > MAX_IN_FRAME) warnings.push(`frame "${cid.slice(2)}" holds ${kids.length} shapes; past ${MAX_IN_FRAME} it reads as a crowd (split it, or make it a subboard)`);
    if (cid[0] === 'b') {
      const onBoard = [...model.nodes.values()].filter((n) => n.board === cid.slice(2) && n.kind !== 'frame').length;
      if (onBoard > MAX_ON_BOARD) warnings.push(`board "${cid.slice(2)}" has ${onBoard} shapes; past ${MAX_ON_BOARD} a board is hard to read (make a subboard of a part)`);
    }
  }
  return { errors, warnings };
}
