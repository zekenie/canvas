// Types in a digest: a note that holds a JSON Schema is a type, a note that is one is an instance, an arrow that is one of a relationship type is a
// relationship, and an arrow between a type and a relationship type is one of its ends. This is what the tool says of them: how they are written
// into a draw script, and what check refuses. Pure, and the same under jsc and node.
import { lit, byTitle } from './util.mjs';

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

/** Whether an edge between these two nodes is an end of a relationship type: it joins a relationship type and a type, whichever way it points. */
export function isEndOf(a, b) {
  const type = (n) => n.kind === 'sticky-note' && !!n.schema && !n.relationship;
  const rel = (n) => n.kind === 'sticky-note' && !!n.schema && n.relationship;
  return (rel(a) && type(b)) || (type(a) && rel(b));
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

function walk(value, schema, path, root, stack, out) {
  if (value === null || value === undefined) return;
  if (!plainObject(schema)) return;
  const skip = (keyword) => {
    const at = path.replace(/\[\d+\]/g, '[]'), k = at + '\u0000' + keyword;
    if (!out.seen.has(k)) { out.seen.add(k); out.unchecked.push({ path: at, keyword }); }
  };
  if (typeof schema.$ref === 'string') {
    const target = resolveRef(schema.$ref, root);
    // a ref that names nothing here, or that comes back to itself over the same value (a cycle), is passed over and said
    if (!target || stack.length >= MAX_REF_DEPTH || stack.some((s) => s.ref === schema.$ref && s.value === value)) skip('$ref');
    else walk(value, target, path, root, stack.concat([{ ref: schema.$ref, value }]), out);
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
    if (Array.isArray(schema.required)) for (const r of schema.required) if (!hasOwn(value, r) || value[r] === undefined || value[r] === null) out.errors.push(`${path}.${r} is required, and has no value`);
    const props = plainObject(schema.properties) ? schema.properties : {};
    for (const k of Object.keys(props)) if (hasOwn(value, k)) walk(value[k], props[k], `${path}.${k}`, root, stack, out);
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

/**
 * Everything wrong with how a model's shapes and edges are typed, as {errors, warnings} of sentences that name the shape. An `is` that names no type
 * in the digest (or a relationship type on a note, or a plain type on an arrow); `is` on a frame, a subboard or a type; `relationship` without a
 * `schema`; a `schema` that is no object, or on a shape that is no note; a `$ref` to a shape's id; `endRule` on an arrow that is no end of a
 * relationship type; an end of one that sits on another board than the relationship type; values with no type, or that don't fit their type.
 */
export function typeProblems(model) {
  const errors = [], warnings = [];
  const nodes = [...model.nodes.values()].sort((a, b) => byTitle(a.title, b.title));
  const typeNamed = (t) => { const n = model.nodes.get(t); return n && n.schema ? n : null; };
  // the keywords of a type's schema that a value passed through without being checked, once for the type, the member and the keyword
  const passed = new Map();
  const values = (owner, value, type, what) => {
    const r = checkValue(value, type.schema, 'fieldValues');
    for (const u of r.unchecked) {
      const k = [type.title, u.path, u.keyword].join('\u0000');
      if (!passed.has(k)) passed.set(k, { type: type.title, what, path: u.path, keyword: u.keyword, owners: [] });
      passed.get(k).owners.push(owner);
    }
    return r.errors;
  };
  for (const n of nodes) {
    const q = `"${n.title}"`;
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
    if (n.is.length && n.schemaGiven) errors.push(`${q}: a type can't say is (a type that builds on another isn't drawn by a digest)`);
    for (const t of n.is) {
      const type = typeNamed(t);
      if (!type) errors.push(`${q}: is "${t}", which names no type in the digest`);
      else if (type.relationship) errors.push(`${q}: is "${t}", a relationship type: only an arrow is one`);
    }
    if (n.fieldValuesGiven) {
      if (!plainObject(n.fieldValues)) errors.push(`${q}: fieldValues is a JSON object, not ${Array.isArray(n.fieldValues) ? 'a list' : JSON.stringify(n.fieldValues)}`);
      else if (!n.is.length) errors.push(`${q}: fieldValues needs an is (the type whose fields they are)`);
      else for (const t of n.is) { const type = typeNamed(t); if (type && !type.relationship && plainObject(type.schema)) for (const m of values(q, n.fieldValues, type, 'type')) errors.push(`${q}: ${m} (the type "${t}")`); }
    }
  }
  for (const e of model.edges) {
    const q = `edge "${e.from}" -> "${e.to}"`;
    const a = model.nodes.get(e.from), b = model.nodes.get(e.to);
    if (e.end) {
      const rel = a.relationship ? a : b, other = rel === a ? b : a;
      if (a.board !== b.board) errors.push(`${q}: an end of the relationship type "${rel.title}", but "${other.title}" is on ${other.board === 'root' ? 'the first board' : `the board of "${other.board}"`} and "${rel.title}" on ${rel.board === 'root' ? 'the first board' : `the board of "${rel.board}"`}; a relationship type, its ends and the types they join are drawn in one script on one board`);
      if (e.via) errors.push(`${q}: an end of the relationship type "${rel.title}" is a plain arrow, never a reference`);
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
        else for (const t of arrow.is) { const type = typeNamed(t); if (type && type.relationship && plainObject(type.schema)) for (const m of values(q, arrow.fieldValues, type, 'relationship type')) errors.push(`${q}: ${m} (the relationship type "${t}")`); }
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
