// Types in a digest: a note that holds a JSON Schema is a type, a note that is one is an instance, an arrow that is one of a relationship type is a
// relationship, and an arrow between a type and a relationship type is one of its ends. A type may be of types too: it builds on them, and its
// notes have their fields. This is what the tool says of them: how they are written into a draw script, the order a chain of them is read in, the
// round each is drawn in, and what check refuses. A node is the model's by its key; a type is named by its title (`model.types`), wherever an `is`
// names one. Pure, and the same under jsc and node.
import { lit, byTitle, label } from './util.mjs';

/** `is:` as draw takes it: a title, or several as JSON. */
export const isLit = (titles) => (titles.length === 1 ? lit(titles[0]) : JSON.stringify(titles));

/** The attributes a note writes for what it is: its schema (as the quoted string draw reads), the mark of a relationship type, the types it is and its values. */
export function noteTyping(n) {
  let s = '';
  if (n.schema) s += ` schema: ${lit(JSON.stringify(n.schema))}` + (n.relationship ? ' relationship: true' : '');
  if (n.is && n.is.length) s += ` is: ${isLit(n.is)}`;
  if (n.fieldValues) s += ` fieldValues: ${JSON.stringify(n.fieldValues)}`;
  return s;
}

/** The attributes an arrow writes for what it is: the relationship types it is, its values, and the rule it is for the end it is. */
export function arrowTyping(a) {
  let s = '';
  if (a.is && a.is.length) s += ` is: ${isLit(a.is)}`;
  if (a.fieldValues) s += ` fieldValues: ${JSON.stringify(a.fieldValues)}`;
  if (a.endRule) s += ` endRule: ${JSON.stringify(a.endRule)}`;
  return s;
}

/**
 * An arrow's `is`, as one key (an arrow of a pair is told from the others by it). A list of types is a set for identity: `["R1", "R2"]` and
 * `["R2", "R1"]` are one arrow (the order a drawing is written in means something to draw, where two types say the same, but never which arrow it is).
 */
export const isKey = (is) => [...(is || [])].sort().join('\u0000');

/** Whether a node is a type: a note that holds a schema (a relationship type is one too). */
export const isType = (n) => n.kind === 'sticky-note' && !!n.schema;

/** Whether a node is a note of a type: one that says `is` and is no type itself (a type's `is` is what it builds on). */
export const isInstance = (n) => n.kind === 'sticky-note' && n.is.length > 0 && !n.schema;

/** Whether an edge between these two nodes is an end of a relationship type: it joins a relationship type and a type, whichever way it points. */
export function isEndOf(a, b) {
  const type = (n) => isType(n) && !n.relationship;
  const rel = (n) => isType(n) && n.relationship;
  return (rel(a) && type(b)) || (type(a) && rel(b));
}

// ---- the order a chain of types is read in ---------------------------------------------------------------------------------------------

const unique = (xs) => { const seen = new Set(); return xs.filter((x) => !seen.has(x) && seen.add(x)); };

/** A list of types as a chain reads it: each once, the first, latest first (the app's `TypeOrder.heads`). */
export const heads = (list) => unique(list).reverse();

/** The first head that is in no other list's tail, taken out of every list, until none is left; null where none is. */
function merge(lists) {
  let ls = lists.filter((l) => l.length);
  const out = [];
  while (ls.length) {
    const head = ls.map((l) => l[0]).find((h) => !ls.some((l) => l.indexOf(h, 1) > 0));
    if (head === undefined) return null;
    out.push(head);
    ls = ls.map((l) => (l[0] === head ? l.slice(1) : l)).filter((l) => l.length);
  }
  return out;
}

/** C3 alone: `L(x) = [x] + merge(L(p1), ..., L(pn), [p1...pn])`, and for the heads the same with no head of its own; null where it has no order. */
function c3(hs, parents, excluding) {
  const memo = new Map(), active = new Set();
  const linear = (s) => {
    if (s === excluding) return null;
    if (memo.has(s)) return memo.get(s);
    if (active.has(s)) return null;
    active.add(s);
    const rest = merged(unique(parents(s)));
    active.delete(s);
    if (!rest) return null;
    memo.set(s, [s].concat(rest));
    return memo.get(s);
  };
  const merged = (own) => {
    const lists = [];
    for (const p of own) { const l = linear(p); if (!l) return null; lists.push(l); }
    return merge(lists.concat([own]));
  };
  return merged(unique(hs));
}

/**
 * Where C3 has no order: walk depth first from the heads, each type's parents in order, a type's place in the walk its rank, an edge back to a type
 * on the walk's path dropped; then list, of the types not listed that no unlisted type builds on, the one of lowest rank, until none is left.
 */
function fallback(hs, parents, excluding) {
  const walked = [], seen = new Set(), path = new Set(), edges = new Map();
  const walk = (s) => {
    seen.add(s); walked.push(s); path.add(s);
    const kept = [];
    for (const p of unique(parents(s))) {
      if (p === excluding || path.has(p)) continue;
      kept.push(p);
      if (!seen.has(p)) walk(p);
    }
    edges.set(s, kept);
    path.delete(s);
  };
  for (const h of unique(hs)) if (h !== excluding && !seen.has(h)) walk(h);
  const blockers = new Map();
  for (const ps of edges.values()) for (const p of ps) blockers.set(p, (blockers.get(p) || 0) + 1);
  const listed = [], done = new Set();
  for (let next; (next = walked.find((s) => !done.has(s) && !blockers.get(s))) !== undefined;) {
    listed.push(next); done.add(next);
    for (const p of edges.get(next)) blockers.set(p, blockers.get(p) - 1);
  }
  return listed;
}

/**
 * The types `hs` (a list as `heads` reads it) lead to, in the one order the app reads them in (`TypeOrder.linearized`, ported: the two must agree,
 * since the first type in it to name a field is the one whose definition the field has): a type before every type it builds on, each once, and
 * where that leaves a choice, the one a list names later. C3 (Python's method resolution order) where it has an order, else a depth-first walk
 * breaks the ties. `parents(t)` is t's own list as `heads` reads it; `excluding` is never listed.
 */
export function linearized(hs, parents, excluding = null) {
  return c3(hs, parents, excluding) || fallback(hs, parents, excluding);
}

/** The types of the digest a shape's list (`is`) leads to, in the order their fields are read: its own types, later first, and what they build on (titles). */
export function chainOf(model, list) {
  const type = (t) => { const n = model.types.get(t); return n && n.schema ? n : null; };   // `is` names a type by its title
  return linearized(heads(list), (t) => (type(t) ? heads(type(t).is) : [])).filter(type);
}

/**
 * The round each type and relationship type of the digest is drawn in, after every board's shapes (a script for each board a round): no earlier
 * than every type it builds on, and a round later than one on another board, since a script draws on one board and `is:` names a type drawn before
 * it or in it; and a type no earlier than a relationship type it is an end of, since the end is drawn with the type (it gives the type a row, and a
 * note is drawn at the size it keeps). So when a type is drawn, everything that sizes it is there or in its script. Check refuses a type that
 * builds on itself; this ends a ring all the same. Keyed by each type's key, as the model's nodes are (an `is` names a type by its title).
 */
export function typeRounds(model) {
  const rounds = new Map(), active = new Set();
  const ends = new Map();   // a type's key -> the keys of the relationship types it is an end of
  for (const e of model.edges) {
    if (!e.end) continue;
    const a = model.nodes.get(e.from), type = a.relationship ? e.to : e.from, rel = a.relationship ? e.from : e.to;
    ends.set(type, (ends.get(type) || []).concat([rel]));
  }
  const round = (key) => {
    if (rounds.has(key)) return rounds.get(key);
    if (active.has(key)) return 0;
    active.add(key);
    const n = model.nodes.get(key);
    let r = 0;
    for (const p of n.is) { const s = model.types.get(p); if (s && s.schema) r = Math.max(r, round(s.key) + (s.board === n.board ? 0 : 1)); }
    for (const rel of ends.get(key) || []) r = Math.max(r, round(rel));
    active.delete(key);
    rounds.set(key, r);
    return r;
  };
  for (const n of model.nodes.values()) if (n.schema) round(n.key);
  return rounds;
}

// ---- values against a schema ------------------------------------------------------------------------------------------------------------

const plainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const kindOf = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);
const fits = (v, t) => (t === 'integer' ? kindOf(v) === 'number' && Number.isInteger(v) : t === 'number' ? kindOf(v) === 'number' && isFinite(v) : kindOf(v) === t);
const show = (v) => { const s = JSON.stringify(v); return s.length > 40 ? s.slice(0, 37) + '...' : s; };
/** A value as text, the same for the same value whatever order an object's keys were written in. */
export const canon = (v) => (Array.isArray(v) ? '[' + v.map(canon).join(',') + ']' : plainObject(v) ? '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}' : JSON.stringify(v));

// What the validator passes over, by the kind of value it would apply to. A schema using one of these for a value that has it is said by check, so that a pass is never silent.
const UNCHECKED = {
  any: ['anyOf', 'oneOf', 'allOf', 'not', 'if', 'const'],
  string: ['format', 'pattern', 'minLength', 'maxLength'],
  number: ['format', 'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf'],
  array: ['minItems', 'maxItems', 'uniqueItems', 'contains', 'minContains', 'maxContains', 'prefixItems', 'unevaluatedItems'],
  object: ['additionalProperties', 'patternProperties', 'propertyNames', 'minProperties', 'maxProperties', 'dependentRequired', 'dependentSchemas', 'unevaluatedProperties'],
};
const MAX_REF_DEPTH = 64;

/** A local `$ref` (`#`, `#/$defs/x`, `#/definitions/x`, any JSON pointer into the type's own schema) as the schema it names; undefined for any other. */
function resolveRef(ref, root) {
  if (ref === '#') return root;
  if (!ref.startsWith('#/')) return undefined;
  let cur = root;
  for (const raw of ref.slice(2).split('/')) {
    let part;
    try { part = decodeURIComponent(raw); } catch (e) { return undefined; }
    part = part.replace(/~1/g, '/').replace(/~0/g, '~');
    if (cur === null || typeof cur !== 'object' || !hasOwn(cur, part)) return undefined;
    cur = cur[part];
  }
  return plainObject(cur) ? cur : undefined;
}

// `own` (for the value a type's fields are held in, and nothing under it): whether a member is this type's to check, since a chain checks a field
// by the first of its types that names it alone; null, every member.
function walk(value, schema, path, root, stack, out, own = null) {
  if (value === null || value === undefined) return;
  if (!plainObject(schema)) return;
  const skip = (keyword) => {
    const at = path.replace(/\[\d+\]/g, '[]'), k = at + '\u0000' + keyword;
    if (!out.seen.has(k)) { out.seen.add(k); out.unchecked.push({ path: at, keyword }); }
  };
  const mine = (k) => !own || own(k);
  if (typeof schema.$ref === 'string') {
    const target = resolveRef(schema.$ref, root);
    // a ref that names nothing here, or that comes back to itself over the same value (a cycle), is passed over and said
    if (!target || stack.length >= MAX_REF_DEPTH || stack.some((s) => s.ref === schema.$ref && s.value === value)) skip('$ref');
    else walk(value, target, path, root, stack.concat([{ ref: schema.$ref, value }]), out, own);
  }
  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => fits(value, t))) { out.errors.push(`${path} is ${show(value)}, and the schema wants ${types.join(' or ')}`); return; }
  }
  const kind = kindOf(value);
  for (const kw of UNCHECKED.any.concat(UNCHECKED[kind] || [])) if (schema[kw] !== undefined) skip(kw);
  if (kind === 'array' && Array.isArray(schema.items)) skip('items');
  if (Array.isArray(schema.enum) && !schema.enum.some((x) => canon(x) === canon(value))) {
    out.errors.push(`${path} is ${show(value)}, and the schema allows only ${schema.enum.map(show).join(', ')}`);
  }
  if (kind === 'object') {
    if (Array.isArray(schema.required)) for (const r of schema.required) if (mine(r) && (!hasOwn(value, r) || value[r] === undefined || value[r] === null)) out.errors.push(`${path}.${r} is required, and has no value`);
    const props = plainObject(schema.properties) ? schema.properties : {};
    for (const k of Object.keys(props)) if (mine(k) && hasOwn(value, k)) walk(value[k], props[k], `${path}.${k}`, root, stack, out);
  } else if (kind === 'array' && plainObject(schema.items)) {
    value.forEach((item, i) => walk(item, schema.items, `${path}[${i}]`, root, stack, out));
  }
}

/**
 * A value against a schema, for the subset of JSON Schema the app's types use: `type` (a name or a list of them; integer and number told apart),
 * `properties` (a member the schema names, recursively), `required` (an own member that has a value), `enum` (objects compared whatever order their
 * keys are in), `items` (one schema for every item of a list) and local `$ref`s (`#/$defs/x`, `#/definitions/x`, a pointer into the type's own schema,
 * followed with a guard against a cycle). A null is taken as no value, as draw takes one. A member the schema doesn't name is not an error: the app
 * keeps it and no field shows it.
 *
 * Returns {errors, unchecked}: the messages for a value that doesn't fit, and `{path, keyword}` for each keyword it passed over on a value that
 * has one (a list's items as `path[]`): `anyOf`, `oneOf`, `allOf`, `not`, `if`, `const`, `format`, `pattern`, the bounds (`minimum`, `maxLength`,
 * `minItems`...), `uniqueItems`, `additionalProperties`, tuple `items`..., and a `$ref` that names nothing in the schema or comes back to itself.
 * The app checks all of them when the shape is drawn.
 */
export function checkValue(value, schema, path) {
  const out = { errors: [], unchecked: [], seen: new Set() };
  walk(value, schema, path, schema, [], out);
  return { errors: [...new Set(out.errors)], unchecked: out.unchecked };
}

/** The messages for a value that doesn't fit a schema (`checkValue`'s errors). */
export const validateValue = (value, schema, path) => checkValue(value, schema, path).errors;

/**
 * A value against a chain of types (`[{title, schema}]`, in `chainOf`'s order), as the app holds a note's values to its types and what they build
 * on: each field by the first type in the chain that names it in its `properties`, alone and with its `required` (so a field a type restates is
 * checked by its definition, never the one it replaces), and nothing else at the top: a `required` name no type has a property for names no field,
 * as in the app. What is under a field is checked as `checkValue` checks it. Returns `[{type, errors, unchecked}]`, a type each.
 */
export function checkChain(value, chain, path) {
  const winner = new Map();
  for (const t of chain) if (plainObject(t.schema.properties)) for (const k of Object.keys(t.schema.properties)) if (!winner.has(k)) winner.set(k, t.title);
  return chain.map((t) => {
    const out = { errors: [], unchecked: [], seen: new Set() };
    walk(value, t.schema, path, t.schema, [], out, (k) => winner.get(k) === t.title);
    return { type: t.title, errors: [...new Set(out.errors)], unchecked: out.unchecked };
  });
}

/** The `$ref`s of a schema that name a shape by its id (`urn:uuid:...`), which a digest cannot know. */
export function idRefs(schema) {
  const found = [];
  const walk = (v) => {
    if (Array.isArray(v)) { v.forEach(walk); return; }
    if (!v || typeof v !== 'object') return;
    for (const k of Object.keys(v)) {
      if (k === '$ref' && typeof v[k] === 'string' && /^urn:uuid:/i.test(v[k])) found.push(v[k]);
      else walk(v[k]);
    }
  };
  walk(schema);
  return found;
}

// ---- what check refuses -------------------------------------------------------------------------------------------------------------------

/** A ring of types through `start` (each building on the next, the last on `start`), the shortest; null for none. `next(t)`: what t builds on. */
function ringFrom(start, next) {
  const from = new Map(), level = [start];
  for (let i = 0; i < level.length; i++) {
    for (const p of next(level[i])) {
      if (p === start) { const ring = []; for (let t = level[i]; t !== start; t = from.get(t)) ring.unshift(t); return [start].concat(ring); }
      if (!from.has(p)) { from.set(p, level[i]); level.push(p); }
    }
  }
  return null;
}

/**
 * Everything wrong with how a model's shapes and edges are typed, as {errors, warnings} of sentences that name the shape. An `is` that names no type
 * in the digest (or a relationship type on a note, or a plain type on an arrow); `is` on a frame or a subboard; a type that builds on a type of the
 * other sort (a relationship type on a type, or a type on a relationship type), or on itself, however far; `relationship` without a `schema`; a
 * `schema` that is no object, or on a shape that is no note; a `$ref` to a shape's id; `endRule` on an arrow that is no end of a relationship type;
 * an end of one that sits on another board than the relationship type; values on a type, values with no type, or that don't fit their types
 * (`checkChain`). Warns of an edge between two types, which says nothing.
 */
export function typeProblems(model) {
  const errors = [], warnings = [];
  const nodes = [...model.nodes.values()].sort((a, b) => byTitle(a.key, b.key));
  const typeNamed = (t) => { const n = model.types.get(t); return n && n.schema ? n : null; };   // `is` names a type by its title
  const builtOn = (t) => { const n = typeNamed(t); return n ? n.is.filter(typeNamed) : []; };
  const reaches = (t, target) => {
    const seen = new Set([t]), level = [t];
    for (let i = 0; i < level.length; i++) for (const p of builtOn(level[i])) { if (p === target) return true; if (!seen.has(p)) { seen.add(p); level.push(p); } }
    return false;
  };
  // the keywords of a type's schema that a value passed through without being checked, once for the type, the member and the keyword
  const passed = new Map();
  // a value against its types and what they build on, of one sort (types for a note, relationship types for an arrow); an error names the type whose
  // field it breaks, and, for one the list doesn't name, the type of the list that builds on it
  const values = (owner, value, list, relationship, what) => {
    const chain = chainOf(model, list).map(typeNamed).filter((t) => !!t.relationship === relationship && plainObject(t.schema));
    const out = [];
    for (const r of checkChain(value, chain, 'fieldValues')) {
      for (const u of r.unchecked) {
        const k = [r.type, u.path, u.keyword].join('\u0000');
        if (!passed.has(k)) passed.set(k, { type: r.type, what, path: u.path, keyword: u.keyword, owners: [] });
        passed.get(k).owners.push(owner);
      }
      const via = list.includes(r.type) ? '' : `, which "${list.find((t) => reaches(t, r.type))}" builds on`;
      for (const m of r.errors) out.push(`${m} (the ${what} "${r.type}"${via})`);
    }
    return out;
  };
  for (const n of nodes) {
    const q = `"${label(n.key)}"`;
    const typing = n.schemaGiven || n.relationshipGiven || n.is.length || n.isBad || n.fieldValuesGiven;
    if (typing && n.kind !== 'sticky-note') {
      const what = n.is.length || n.isBad || n.fieldValuesGiven ? `a ${n.kind} can't be a type's instance (only notes and arrows are)` : `a ${n.kind} can't be a type (a type is a note)`;
      errors.push(`${q}: ${what}`);
      continue;
    }
    if (n.schemaGiven) {
      if (!plainObject(n.schema)) errors.push(`${q}: schema is a JSON object (the tool writes it as the quoted text draw takes), not ${n.schema === null ? 'null' : Array.isArray(n.schema) ? 'a list' : typeof n.schema}`);
      else {
        for (const ref of idRefs(n.schema)) errors.push(`${q}: the schema has a $ref to ${ref}, a shape's id, which a digest can't know (types relate through relationship types; a $ref inside the schema, like "#/$defs/x", is fine)`);
        if (!n.text) warnings.push(`${q}: a type has words and a schema that agree; this one has no text`);
      }
    }
    if (n.relationshipGiven) {
      if (typeof n.relationshipRaw !== 'boolean') errors.push(`${q}: relationship is true or false, not ${JSON.stringify(n.relationshipRaw)}`);
      else if (n.relationship && !n.schemaGiven) errors.push(`${q}: relationship: true needs a schema (a relationship type is a type that says what an arrow between two notes holds)`);
    }
    if (n.isBad) errors.push(`${q}: is is a type's title, or a list of them`);
    // a type's is names the types it builds on, of its own sort: a type built on a relationship type would make its notes of one, which only an
    // arrow is, and a relationship type built on a type would make its arrows of a type
    const asType = n.schemaGiven, asRelationship = asType && n.relationship;
    for (const t of n.is) {
      const type = typeNamed(t);
      if (!type) errors.push(`${q}: is "${t}", which names no type in the digest`);
      else if (asRelationship && !type.relationship) errors.push(`${q}: builds on "${t}", which isn't a relationship type: a relationship type builds only on relationship types`);
      else if (!asRelationship && type.relationship) errors.push(asType ? `${q}: builds on "${t}", a relationship type: a type builds only on types that aren't` : `${q}: is "${t}", a relationship type: only an arrow is one`);
    }
    // a ring has no order to draw it in, and the app makes none (draw refuses one through the file's shapes, not among one script's): said once, by
    // its first title
    const ring = asType ? ringFrom(n.title, builtOn) : null;
    if (ring && ring.every((t) => byTitle(n.title, t) <= 0)) {
      errors.push(ring.length === 1 ? `${q}: is "${n.title}", itself: a type can't build on itself` : `${q}: builds on ${ring.slice(1).concat([n.title]).map((t) => `"${t}"`).join(', which builds on ')}: a type can't build on itself, however far`);
    }
    if (n.fieldValuesGiven) {
      if (asType) errors.push(`${q}: fieldValues on a type: a type's note shows its fields and never values, which are for its notes`);
      else if (!plainObject(n.fieldValues)) errors.push(`${q}: fieldValues is a JSON object, not ${Array.isArray(n.fieldValues) ? 'a list' : JSON.stringify(n.fieldValues)}`);
      else if (!n.is.length) errors.push(`${q}: fieldValues needs an is (the type whose fields they are)`);
      else for (const m of values(q, n.fieldValues, n.is, false, 'type')) errors.push(`${q}: ${m}`);
    }
  }
  for (const e of model.edges) {
    const q = `edge "${label(e.from)}" -> "${label(e.to)}"`;
    const a = model.nodes.get(e.from), b = model.nodes.get(e.to);
    if (e.end) {
      const rel = a.relationship ? a : b, other = rel === a ? b : a;
      if (a.board !== b.board) errors.push(`${q}: an end of the relationship type "${rel.title}", but "${other.title}" is on ${other.board === 'root' ? 'the first board' : `the board of "${label(other.board)}"`} and "${rel.title}" on ${rel.board === 'root' ? 'the first board' : `the board of "${label(rel.board)}"`}; a relationship type, its ends and the types they join are drawn in one script on one board`);
      if (e.via) errors.push(`${q}: an end of the relationship type "${rel.title}" is a plain arrow, never a reference`);
    } else if (a.kind === 'sticky-note' && b.kind === 'sticky-note' && a.schema && b.schema) {
      warnings.push(`${q}: both ends are types, so the arrow says nothing; a type that builds on another says is ("is": "${b.title}" on "${label(e.from)}")`);
    }
    for (const arrow of e.arrows) {
      if (arrow.isBad) errors.push(`${q}: is is a relationship type's title, or a list of them`);
      for (const t of arrow.is) {
        const type = typeNamed(t);
        if (!type) errors.push(`${q}: is "${t}", which names no type in the digest`);
        else if (!type.relationship) errors.push(`${q}: is "${t}", a type that isn't a relationship type: a note is of it, and an arrow only of a relationship type`);
      }
      if (arrow.is.length && e.end) errors.push(`${q}: an end of a relationship type joins a type and a relationship type; it is not itself a relationship`);
      if (arrow.fieldValuesGiven) {
        if (!plainObject(arrow.fieldValues)) errors.push(`${q}: fieldValues is a JSON object, not ${Array.isArray(arrow.fieldValues) ? 'a list' : JSON.stringify(arrow.fieldValues)}`);
        else if (!arrow.is.length) errors.push(`${q}: fieldValues needs an is (the relationship type whose fields they are)`);
        else for (const m of values(q, arrow.fieldValues, arrow.is, true, 'relationship type')) errors.push(`${q}: ${m}`);
      }
      // two edges of one pair and one type that give a member two values: which wins would be the digest's order, so neither does
      const tag = arrow.is.length ? ` (is ${arrow.is.join(', ')})` : '';
      for (const c of arrow.conflicts) errors.push(`${q}${tag}: ${c.which}.${c.member} is ${show(c.a.value)} in edges[${c.a.index}] and ${show(c.b.value)} in edges[${c.b.index}]; say it once, or the same in both`);
      if (arrow.orders.length > 1) warnings.push(`${q}: is is written in two orders (${arrow.orders.map((o) => o.join(', ')).join(' and ')}); a later type wins where two say the same, so the order means something. Drawn as ${arrow.is.join(', ')}`);
      if (arrow.endRuleGiven) {
        const r = arrow.endRule;
        if (!e.end) errors.push(`${q}: endRule is only for an end of a relationship type (an edge from a type into one, or out of one to a type)`);
        else if (!plainObject(r) || !Object.keys(r).length || Object.keys(r).some((k) => k !== 'needed' && k !== 'onlyOne') || Object.keys(r).some((k) => typeof r[k] !== 'boolean')) errors.push(`${q}: endRule is {"needed": true|false, "onlyOne": true|false}, not ${JSON.stringify(r)}`);
      }
    }
  }
  for (const p of passed.values()) {
    const first = p.owners[0], more = p.owners.length > 1 ? ` and ${p.owners.length - 1} more` : '';
    warnings.push(`${first}${more}: ${p.path} uses "${p.keyword}" in the ${p.what} "${p.type}", which this check doesn't apply; the app checks it when the value is drawn, and the dry run fails if it is wrong`);
  }
  return { errors, warnings };
}
