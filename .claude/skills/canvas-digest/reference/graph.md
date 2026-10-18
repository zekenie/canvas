# The digest format

A digest is one JSON file. It says what the things are, which holds which, and what points at what. It says nothing about where anything goes.

```json
{
  "title": "Name of the whole",
  "text": "What the whole is, said on its first board",
  "policy": {"mess": 0.1, "promote": true, "ranks": "rows"},
  "nodes": [{"title": "…", "kind": "auto", "in": "…", "text": "…", "public": true, "rank": 0,
             "schema": {}, "relationship": true, "is": "…", "fieldValues": {}}],
  "edges": [{"from": "…", "to": "…", "weight": 1, "text": "…", "via": "reference", "direct": true,
             "is": "…", "fieldValues": {}, "endRule": {"needed": true}}]
}
```

## The top

| field | meaning |
|---|---|
| `title` | what the digest is of. It names the first board's header note, `About <title>`. Default `Digest`. |
| `text` | what the first board's header note says. Default `<title>. Drawn by canvas-digest.` |
| `policy.mess` | the dial, 0 (tidy) to 1 (loose). Default 0.1. `--mess` on the command wins. |
| `policy.promote` | `false` promotes no hub, whatever the dial. Default `true`. |
| `policy.ranks` | `"rows"` or `"columns"`: which way shapes with a `rank` run (below). Left out, whichever the view shows larger. `--ranks` on the command wins. |

## Nodes

A node is a shape. The list is flat: a node says which node holds it with `in`.

| field | meaning |
|---|---|
| `title` | required. Unique across the whole file and the app's file (case aside, spaces folded), at most 80 characters. It is how edges, `in` and later scripts name the shape. |
| `kind` | `sticky-note` (the default), `frame`, `subboard` or `auto`. |
| `in` | the title of the frame or subboard that holds it. Left out, it is on the first board. |
| `text` | a note's words. A note is as tall as its text needs. A subboard's is its description, what its board is for: mention text, written once everything it may mention is drawn, and shown in the card's panel, never on the canvas (a subboard with none has none); a frame ignores it. |
| `public` | `true` pins the node public (it will be a thing others point at through a pill); `false` means never promote it. Left out, the loop decides. |
| `rank` | a number that puts the node in a row of its container's, or a column, whatever the arrows ask: rows with the lowest rank on top (each row's shapes left to right by title), or columns with the lowest at the left (each column's top to bottom), whichever the view shows larger (`policy.ranks` says which). A frame alone in its row is as wide as the widest row, what it holds centred, and one alone in its column as tall as the tallest, what it holds at its top: layers as bands, phases of a plan. Each band is laid out for its slot, wide and short in a row, narrow and tall in a column. A shape with no rank among ranked ones goes in a row (or a column) after them. |
| `source` | where the node was made from: a path, or `{"path": …, "line": …}`. For the digest's maker (and a reader of the file); the layout and the drawing ignore it. |

**Choosing kinds.**

- A **sticky-note** is a leaf: one thing. A note holds nothing.
- A **frame** is a group on a board that a reader sees at a glance (a package, a team, a theme). Nest them: a frame can hold frames. Keep each to about 15 shapes.
- A **subboard** is a card that opens its own board, for a part too big to show inline. Everything in it is laid out on its own board, and an edge from outside it is drawn as a pill.
- **auto** picks for you: a subboard when it holds over 40 notes or subboards, or when something sits three levels below it (it holds a frame that holds a frame that holds a shape), and a frame otherwise.
- Only containers can be named by `in`. Every title in `in` must be a node, and `in` can't run in a circle (A in B, B in A, or A in A): `check` and `plan` refuse it, naming the titles.

| `schema` | a JSON Schema, as a JSON object: the note is a **type** (a note whose fields are the schema's). The tool writes it as `canvas draw`'s quoted string. [Types](#types). |
| `relationship` | `true` on a type: it is a **relationship type**, which says what an arrow between two notes holds. Needs a `schema`. |
| `is` | a type's title, or a list of them: the note is one of that type (its panel shows the type's fields). Notes only. |
| `fieldValues` | an object: what the note holds for its types' fields. Held to their schemas. Needs `is`. |

A board with more than about 150 shapes is hard to read; make a subboard of a part.

## Edges

An edge is "from points at to". Both must be notes or subboards, never frames.

| field | meaning |
|---|---|
| `from`, `to` | titles of nodes. An edge to itself is ignored. An edge that names a frame is dropped with a warning. |
| `weight` | how strongly the layout keeps the two near. Default 1. Two edges with the same ends are one edge, with their weights added. |
| `is` | a relationship type's title, or a list: the arrow is a **relationship** of that type. Two edges between one pair with different `is` are two arrows, drawn each with its type, and one edge to the layout. [Types](#types). |
| `fieldValues` | an object: what the relationship holds for its type's fields. Needs `is`. |
| `endRule` | `{"needed": true, "onlyOne": true}` on an edge that is an **end** of a relationship type (an edge from a type into one, or out of one to a type): every note of the type has one such relationship, or at most one. |
| `text` | what the arrow says. Short. |
| `via` | `"reference"` says the arrow is drawn into a pill, even between neighbors. The end is made public. |
| `direct` | `true` says this edge is never a pill, even if its end is a hub. Edges between boards ignore it: an arrow can't leave its board. |

**Which become pills.** An edge between two boards is always a pill, and its end is public. An edge with `via: "reference"` is too. For the rest the plan decides, on each board that isn't tidy enough with plain arrows, a shape at a time, the one with the most arrows first: a shape many point at is promoted (every shape that points at it gets a pill, shapes of one frame sharing one, and it is made public), and a shape that points at many is fanned out (each thing it points at is a pill beside it, and is made public). Shapes with only a few arrows are moved only when that clearly costs less in arrows that cross each other or run over shapes. An arrow that would still run too long becomes a pill of its own. A frame (or a board) of at most six shapes that don't point at each other and point at two or more of the same shapes is a spine: every edge of its shapes is a pill, its shapes sit in two columns with the pills they share between them, a pill every one of them uses once in the middle, one some use shared within each row, and a copy for a shape alone in its row.

## Types

A note that holds a `schema` is a type, and a note that `is` one is an instance, as in the app. A relationship type is a type with `relationship: true`; its **ends** are two edges, one from a type into it (the *from* end) and one out of it to a type (the *to* end). The first line of an end's `text` names the row the end gives the notes of that type (`tables`, `writers`), and its `endRule` says what each note must have. An edge between two notes that says `is` with a relationship type's title is a **relationship**, and its `fieldValues` are what it holds. After drawing, `canvas query` answers the model: `:is-a("Table")`, `arrow:is-a("writes")`, `:start-of(arrow:is-a("writes"):ends-at("orders"))`, `:incomplete`, `arrow:misfit`.

```json
{
  "title": "Platform",
  "nodes": [
    {"title": "Model", "kind": "frame"},
    {"title": "Workflow", "in": "Model", "text": "A Temporal workflow", "schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
    {"title": "Table", "in": "Model", "text": "A table", "schema": {"type": "object", "properties": {"name": {"type": "string"}, "engine": {"enum": ["postgres", "dynamo"]}}}},
    {"title": "writes", "in": "Model", "text": "A workflow writes a table", "relationship": true, "schema": {"type": "object", "properties": {"mode": {"enum": ["insert", "upsert"]}}}},
    {"title": "Checkout", "kind": "subboard"},
    {"title": "OrderWorkflow", "in": "Checkout", "is": "Workflow", "fieldValues": {"name": "OrderWorkflow"}},
    {"title": "orders", "in": "Checkout", "is": "Table", "fieldValues": {"name": "orders", "engine": "postgres"}}
  ],
  "edges": [
    {"from": "Workflow", "to": "writes", "text": "tables", "endRule": {"needed": true}},
    {"from": "writes", "to": "Table", "text": "writers"},
    {"from": "OrderWorkflow", "to": "orders", "is": "writes", "fieldValues": {"mode": "insert"}}
  ]
}
```

**What `check` refuses**, each naming the shape: an `is` that names no type in the digest (or a relationship type on a note, or a plain type on an edge); `is` on a frame, a subboard, or a type; `relationship` without a `schema`, and a `schema` on anything that isn't a note; a `$ref` to `urn:uuid:` in a schema (a shape's id, which a digest cannot know: types relate through relationship types, and a `$ref` inside the schema, like `#/$defs/x`, is fine); `fieldValues` with no `is`, or that don't fit their type's schema (a `$ref` to `#/$defs/x` or `#/definitions/x` in it is followed); two edges of one pair and one type that give a member two different values (it names both: `edges[4]` and `edges[5]`, their places in the digest); `endRule` on an edge that is not an end, or that isn't `{"needed", "onlyOne"}`; an end that is itself a relationship (`is`) or goes through a reference; and a relationship type whose end types are on another board than it. `plan` and `measure` refuse the same. It warns of a type with no `text`, of a pair that lists one set of types in two orders (a later type wins where two say the same, so the order means something; the arrow is drawn in the order that sorts first, and `is: ["A", "B"]` and `["B", "A"]` are otherwise one arrow), and of a keyword the values aren't checked against (below) (a type has words and a schema that agree). `text` is what the type holds in words; write both.

**The values are held to a subset of JSON Schema**: `type` (a name or a list; integer and number told apart), `properties`, `required` (an own member with a value), `enum` (an object matches whatever order its keys are in) and `items` (one schema for every item), nested, and local `$ref`s (`#/$defs/x`, `#/definitions/x`, any pointer into the type's own schema; a cycle ends). A null counts as no value. Not checked: `format`, `pattern`, bounds (`minimum`, `maxLength`, `minItems`...), `additionalProperties`, `const`, `uniqueItems`, tuple `items`, `allOf`, `anyOf`, `oneOf`, `not`, `if`, and a `$ref` outside the schema. When a value reaches one of these, `check` **warns**, naming the member and the keyword (once for a type, a member and a keyword, with the first shape and how many more), so a pass is never silent. A member the schema doesn't name isn't refused (the app keeps it and no field shows it). The app judges the rest, and says it when it draws; a value it says breaks its field's schema (`problems` of class `wrong` at a path) fails the dry run, where a misfit or a row past Only one doesn't.

**Where the types go, and the order of the runs.** An end gives a row to every note of its types, so a type's note grows a row for each end it has, and a note of it grows by the same rows; the measure carries the types, the relationship types, their ends and the typed arrows, so every typed note is planned at the size it has with them, and a note that is a type or is one is at least 320 wide. Whether a relationship at a note changes its size was tried against the app: it doesn't (the rows are the ends', never what is drawn at them). So the runs are, in graph terms:

1. the `--into` subboard, then each board's shapes (the root first, then subboards by depth), as for any digest, **except** that a board's types, relationship types and the ends between them are one script: the run of the deepest frame any of them is in (the first one when none is in a frame), the ends after the shapes; and no note of a type is in these;
2. then, for each board that has notes of a type, one script (`NN-<board>-notes.draw`) of them, after every board's shapes: `is:` finds a type anywhere in the file, so every type exists, with its ends, before the first note of one is drawn, and every note is created at the size it keeps;
3. then, for each board that holds a subboard with a `text`, one script (`NN-<board>-describe.draw`) with a statement for each such card, `subboard "T" description: "..."`, which restates the card as it is: a description may mention a shape of any board (`@[Title]`), so every shape is drawn first;
4. then each board's arrows, as before, a line for each relationship (a typed arrow is written with its `is:`, `fieldValues:` and `text:`).

That is why a relationship type's end types must be on its board: an end is an arrow, and an arrow can't leave its board. Types may be on the first board (as a frame) or on a board of their own (a subboard); notes of them go on any board. `compare` holds every shape to its planned box in the run that draws it, so nothing may grow later. Two relationships between one pair are two lines (a pair that is a pill has one pill, the second line reusing it), `verify` finds each by its `is`, and an edge with no `is` beside typed ones is dropped with a warning (draw answers `ambiguous_edge`).

**Warnings that are the data.** A typed drawing says what is wrong or missing in what it draws: a relationship that doesn't fit its ends, a Needed row left empty (`tables is needed`), a row past Only one, a value that breaks its field. `digest draw` and `verify` report them (a count and the first, as "a typed drawing gives by design") and don't fail the run; they fail only on what they failed on before (a shape off its box, a push, an order the app can't carry out, a missing arrow) and on a value the app says breaks its field's schema (the digest's `check` should have refused it, or warned of the keyword it didn't apply).

## An example, in words

An engineering team's service map, six things:

- The whole is called "Shop platform".
- A frame "Services" holds three notes: Orders (takes orders), Billing (charges them) and Catalog (what is for sale).
- A frame "Stores" holds two notes: Orders DB and Cache.
- One note, "Gateway", is on its own: every call from outside comes through it.
- Gateway points at Orders, Billing and Catalog (text "routes to"). Orders and Catalog point at Cache, and Orders points at Orders DB. Billing points at Orders.

As a digest that is a title, eight nodes (two of kind `frame`, with three notes `in` "Services" and two `in` "Stores", and Gateway in neither), and seven edges. Cache has two users in one frame, so it isn't worth a pill; if five more services pointed at it from three frames, their arrows would cross the board and the plan would promote it (five arrows or more is popular, at the default dial): the Cache note becomes public, and each of those services shows a pill for it beside it (the ones in one frame sharing a pill) instead of a line across the board. The summary lists Cache under "public", with why.

## What the commands read and write

All files go in the out folder (`--out`, default the digest's name with `.out`).

| command | reads | writes |
|---|---|---|
| `check` | the digest, `canvas kinds`, one `canvas query` for the titles in the file (with `--board`) and `canvas boards` (drawn as the board, `--board` without `--into`: whether it is empty) | `kinds.json`, `titles.json`, `titles.all.json` |
| `measure` | the digest, `canvas measure` | `measure.draw` (what was measured), `measure.json` (the answer) |
| `plan` | the digest, `measure.json`, `canvas boards` (the room the target's window has for a board: the view every board is laid out for, unless `--view` says) | `plan.json`, `report.json`, `runs/NN-<board>-<step>.draw` |
| `draw` | the plan and runs; `drawn.json` with `--replace` | the board; `results/NN-<board>-<step>.dry.json` and `.json`, what `canvas draw` said of each run; `state.json`; `target.id` for a new file; `drawn.json`, what this drawing makes (the board's file and id, the subboard, the titles), which a later `--replace` takes back; with `--replace`, `replace.draw` and `results/replace.json` |
| `verify` | the plan, the saved results, one `canvas query` for the titles in the file | nothing |

`plan.json` has each board's shapes (`x`, `y`, `w`, `h` from the board's origin: the first board's header note, a subboard's board's own two shapes, its `anchors`, the widest and the tallest of those drawn first), its pills, and its edges in the order they are drawn; for an edge into a shared pill, `share` and `host` name the shape whose pill it reuses (or, for a spine's, the shape whose edge makes it, where the plan has it). It names the subboard the digest goes in (`into`, null for a new file) and the scripts in order (`runs`). `report.json` has the promotions with their costs, where each board's loop stopped and why, the public set with a reason for each, the view the plan is for (`view`: its width and height, and whether it was `given` or `assumed`), and each board's size and how far that is from the view's shape (`end.size`, `end.aspect`: 1 is the view's own shape, or a board the view shows whole). Read the report when the summary isn't what you expected.
