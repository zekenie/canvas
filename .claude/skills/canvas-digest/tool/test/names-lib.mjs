// The check that the render layer names nothing of the app: every kind name, attribute name, pill's need and channel name `canvas kinds` lists (the answer
// whole, test/fixtures/kinds.answer.json, which the kind-pages test writes from the app's) is looked for as a quoted string literal in lib/*.mjs (single or double quotes or backticks; comments are skipped). Used by names.js (a build step runs it)
// and by run.js. Pure: the files come in through `readText`.
import { TOOL_DIR } from '../lib/util.mjs';

// jsc cannot list a folder: the modules are named here, and run.js (under node) fails if lib/ has one that isn't
export const LIB_MODULES = ['check', 'cli', 'cost', 'dial', 'elk', 'emit', 'geom', 'layout', 'model', 'moves', 'noise', 'plan', 'promote', 'sizes', 'stress', 'util'];

/** The tool's own words, which a name of the app may be spelled as and still be the tool's: how a board's ranks run (`--ranks`, `layout.ranks`),
 *  rows or columns, as a table's `columns` attribute is spelled. Said here so the check passes them by name, and no other. */
export const OWN_WORDS = ['rows', 'columns'];

/** The names of the app a kinds answer holds, each with what it is: kinds, attributes (and what a pill needs of its shape), channels; the tool's own
 *  words (`OWN_WORDS`) left out. */
export function namesIn(kinds) {
  const names = Object.create(null);
  for (const k of kinds || []) {
    names[k.kind] = 'kind';
    for (const a of Object.keys(k.attributes || {})) names[a] = 'attribute';
    for (const v of k.via || []) { if (v.kind) names[v.kind] = 'kind'; if (v.needs) names[v.needs] = 'attribute'; }
    for (const side of Object.keys(k.edges || {})) for (const c of k.edges[side] || []) names[c] = 'channel';
  }
  for (const word of OWN_WORDS) delete names[word];
  return names;
}

/** [{file, line, text, what}] for every string literal in `source` that is one of `names`. */
export function offences(file, source, names) {
  const out = [], n = source.length;
  let line = 1, i = 0;
  while (i < n) {
    const c = source[i];
    if (c === '\n') { line++; i++; continue; }
    if (c === '/' && source[i + 1] === '/') { while (i < n && source[i] !== '\n') i++; continue; }
    if (c === '/' && source[i + 1] === '*') { i += 2; while (i < n && !(source[i] === '*' && source[i + 1] === '/')) { if (source[i] === '\n') line++; i++; } i += 2; continue; }
    if (c === '\'' || c === '"' || c === '`') {
      const start = line;
      let body = '';
      i++;
      while (i < n && source[i] !== c) {
        if (source[i] === '\\') { body += source[i + 1]; i += 2; continue; }
        if (source[i] === '\n') line++;
        body += source[i]; i++;
      }
      i++;
      if (body in names) out.push({ file, line: start, text: body, what: names[body] });
      continue;
    }
    if (c === '/' && /[=(,:;!&|?{}[]\s*$/.test(source.slice(Math.max(0, i - 8), i))) {   // a regular expression literal: skipped to its end
      i++;
      while (i < n && source[i] !== '/' && source[i] !== '\n') { if (source[i] === '\\') i++; i++; }
      i++; continue;
    }
    i++;
  }
  return out;
}

/** Every offence in lib/*.mjs, given a `readText(path)`. */
export function scan(readText) {
  const names = namesIn(JSON.parse(readText(TOOL_DIR + '/test/fixtures/kinds.answer.json')));
  const bad = [];
  for (const f of LIB_MODULES) for (const o of offences('lib/' + f + '.mjs', readText(TOOL_DIR + '/lib/' + f + '.mjs'), names)) bad.push(o);
  return { names, bad };
}

export const say = (o) => `${o.file}:${o.line}: the ${o.what} name "${o.text}" is a string literal; the render layer reads the app's kinds and names none of them`;
