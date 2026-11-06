// The checks on a graph document before anything is measured or drawn: only what the layout needs to read it. Everything else the app refuses
// (a value, a title, a type, a channel), and the tool prints the app's words.
import { buildModel, readGraph, kindsTable } from './model.mjs';

/**
 * graph, and options {kinds: `canvas kinds`' answer}. Returns {errors, warnings}: errors stop the run. Refuses (naming keys) a key that is no non-empty
 * string or is used twice, a kind the app doesn't list or can't draw, an `in` that names no node or one whose kind holds neither shapes nor a board, a
 * cycle in `in`, an edge end that names no node, a layout hint of the wrong type, `layout.pill: true` on a kind no pill stands for. Warns of the
 * edges the layout has no way to draw (the app's own refusals come with the measurement).
 */
export function checkGraph(graph, opts = {}) {
  const kinds = kindsTable(opts.kinds);
  const read = readGraph(graph, kinds);
  if (read.errors.length) return { errors: read.errors, warnings: [] };
  let model;
  try { model = buildModel(graph, null, kinds); } catch (e) { return { errors: [e.message], warnings: [] }; }
  return { errors: [], warnings: model.warnings.slice() };
}
