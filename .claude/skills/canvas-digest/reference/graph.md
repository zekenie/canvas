# The graph document

One JSON file. It says what the things are (their kind and the attributes the app reads), which holds which, and what points at what. It says nothing about where anything goes: `digest` decides that. It is also the file `canvas apply` takes once it has places.

```json
{
  "drawing": "native-canvas",
  "layout": {"ranks": "rows"},
  "nodes": [
    {"key": "type:File", "kind": "sticky-note", "props": {"title": "File", "schema": "{\"type\":\"object\"}"}},
    {"key": "module:Canvas", "kind": "subboard", "props": {"title": "Canvas"}, "layout": {"rank": 0}},
    {"key": "folder:Sources/Canvas", "in": "module:Canvas", "kind": "frame", "props": {"title": "Canvas"}},
    {"key": "file:Sources/Canvas/Editor.swift", "in": "folder:Sources/Canvas", "kind": "sticky-note",
     "props": {"title": "Editor.swift", "is": ["type:File"], "fieldValues": {"lines": 412}}}
  ],
  "edges": [
    {"from": "file:Sources/Canvas/Editor.swift", "to": "file:Sources/Canvas/Shape.swift", "props": {"text": "uses"}, "layout": {"weight": 3}}
  ]
}
```

## Who reads what

- The **app** reads `kind`, `props` and the ends of an edge. Every rule about shapes is its: what a kind accepts, what a title may be, what a type or a relationship allows, which shapes can be joined, what a value must be. When it refuses something, `digest` prints the app's words with the key.
- **`digest`** reads `key`, `in`, `kind` (only to ask `canvas kinds` what it holds and which pills can stand for it) and `layout`. It never looks inside `props`, checks no value, names no kind, attribute or channel, and writes back what you gave it, with places.

## The top

| field | meaning |
|---|---|
| `drawing` | the drawing's name. Required. The app keeps a record by it: drawing again with the same name updates the shapes by key. |
| `layout.placement` | `"stars"` or `"rows"`: how every container is placed where its node doesn't say. Left out, stars where a container's links have a cycle, else rows (SKILL.md, Which links are pills). |
| `layout.ranks` | `"rows"` or `"columns"`: which way shapes with a `layout.rank` run. Left out, whichever the view shows larger. `--ranks` on the command wins. |

| `layout.clustered` | the tool's own, marking a document whose links `digest cluster` has weighed and cut: `{"by": "<the embedding model>"}`, or `{"by": null, "why": "..."}` where the groups were by the links alone. Written by `digest cluster`, never by you (it is refused on a document that has it: a lens's document is grouped once). A document that has it may also have the tool's `layout.cut` on edges; without it that is refused. |

## Nodes

A flat list. A node says which node holds it with `in`.

| field | meaning |
|---|---|
| `key` | required: a non-empty string, unique in the document, the same from run to run. It is the node's identity everywhere: the layout, the app's record, the refusals. Nothing reads it for meaning, so make it carry what you know of the thing (`file:src/a.ts`). Titles are props: two nodes may share one. |
| `kind` | required: a kind `canvas kinds` lists as drawable (`sticky-note`, `frame`, `subboard`, ...). |
| `in` | optional: the key of the node that holds it. That node's kind must hold shapes (a frame's: they sit in it) or a board (a subboard's: they sit on its board). No cycles. |
| `props` | optional object, for the app: any attribute `canvas kinds` lists for the kind, as JSON, with the value `canvas draw` takes (a string, number, boolean, null, list or object: `"title"`, `"text"`, `"color": "green"`, `"is": ["type:File"]`, `"fieldValues": {...}`). Where a value names another shape (a type in `is`, a mention `@[...]` in a text), it may name a node by its key; a key wins over a title. An attribute that takes text may be given a JSON object or list, which is written as its JSON text. Passed through to the drawing byte for byte. |
| `layout` | optional object of hints for `digest`; the app ignores it. |

Node hints:

| `layout.` | meaning |
|---|---|
| `rank` | a number. A container's ranked children run as rows (the lowest rank on top, key order within a row) or as columns (the lowest at the left), whatever the arrows ask. A frame alone in its row is stretched to the widest row; one alone in its column to the tallest. A child with no rank goes after them. |
| `pill` | `true` pins the node as a pill target; `false` rules it out: no link into it is cut into a pill, so no pill stands for it. Not for a node that holds shapes. A node the document makes private (`props.private: true`) wants `false`, and no edge from another board: the app refuses a pill for it. |
| `placement` | on a frame or a subboard: `"stars"` or `"rows"`, how its children (a subboard's: its board's) are placed, over the document's. |

## Edges

| field | meaning |
|---|---|
| `from`, `to` | node keys. |
| `props` | optional, for the app: the arrow's attributes as `canvas kinds arrow` lists them (`text`, `is`, `fieldValues`, `endRule`, ...). Passed through. |
| `key` | optional; an edge may carry one of its own. |
| `layout` | `weight` (a number above 0 and at most 1,000,000, default 1: how much the layout wants the ends near, and how late the link is cut) and `direct` (`true`: never a pill). `cut` is the tool's own (`true`: cut between two groups of a container's shapes, a pill before anything is placed that is an arrow again where the finished drawing has a clear line for it), written by `digest cluster` on `clustered.json` and refused in a document without `layout.clustered`, and with `direct`, or into a node marked `layout.pill: false`. `digest cluster` also writes `weight` on every link where the app measured tightness: 1 to 49 on a link cut between groups and 50 to 100 on the rest, the tighter the heavier within each, so the layout wants the ends of a tighter link nearer and cuts it later. |

Edges are told apart by their ends and their `is`. Two alike are refused by the app. Edges between one pair count as one to the layout (weights added), and each is drawn.

Edges the layout can't draw are left out with a warning, in the app's words where it refused them (`canvas measure` lists them): between a container and what it holds, between kinds that share no channel. The layout's own limits: an edge to a node that holds shapes goes only between nodes on one board (never through a pill); an edge between boards goes through a pill for its far end, so one to a kind no pill stands for is left out.

## Pills

An edge between boards, or a link its board can't draw without crossing another (SKILL.md, Which links are pills), is drawn as a **reference pill** beside the start, standing for the far end (`to`). `layout.pill` and `layout.direct` are the only controls. The result is in drawing.json: an edge's `place.pill` is `{"at": [x, y], "in": "<frame key>"}` where the pill sits, or `{"share": "<node key>"}` to draw into the pill that node's edge makes.

## What `digest cluster` writes: clustered.json

The document with each link weighed and the links between groups cut, which `digest plan` then lays out as any other. It adds no node and moves none: the nodes, their `in` and their order are the lens's, and a lens's node may have any key. Each container's shapes (a board's, a frame's, the lens's own frames as one item each in what holds them) are grouped by how tightly their links hold them, and a link between two groups has `layout.cut: true`, unless a link of its pair may not be a pill (`layout.direct`, or into a node with `layout.pill: false`). Where the app measured how alike each link's two notes are, every link also has `layout.weight`: 1..49 where it is cut and 50..100 where not, the loosest lightest. The tool's own `layout.clustered` at the top says how it was grouped. `clusters.json` has each container's items and the group each is in. The app ignores all of it. Drawing again, a shape a person carried into another container is grouped where it now is, but `clustered.json` keeps the document's own containers: `clusters.json` then has `carried` (`[{key, in}]`), and `digest cluster` writes `carried.json`, the document with those shapes there, which the driver measures for the plan (a pill is sized from its note's container).

A drawing planned from `clustered.json` carries `layout.cut`, `layout.weight` and `layout.clustered` where drawing.json of a lens's document does not: the app ignores `layout`.

## What `digest plan` writes: drawing.json

The same document with places, for `canvas apply`:

```json
{"drawing": "native-canvas",
 "nodes": [{"key": "folder:Sources/Canvas", "in": "module:Canvas", "kind": "frame", "props": {...},
            "place": {"at": [40, 40], "size": [640, 400]}}],
 "edges": [{"from": "a", "to": "type:File", "props": {}, "place": {"pill": {"at": [300, 40], "in": "folder:x"}}},
           {"from": "b", "to": "type:File", "props": {}, "place": {"pill": {"share": "a"}}}]}
```

- `place.at` is the top-left of the shape's room, from its frame's top-left when `in` names a frame, else from its board's origin (the drawing's board, or a subboard's own). Negative numbers are fine; nothing is shifted.
- `place.size`: a frame's is the layout's; any other node's is the app's measured size.
- An edge with no `place` is an arrow between its ends. The maker of a shared pill is listed before the edges that share it.
- `layout` members pass through and the app ignores them.

`report.json` says each board's cut (`links`, `cut` to make them planar, `precut` between groups before anything was placed, `cutFurther` where a drawing still crossed, `restored` and `restoredCut` put back as arrows, `rounds`, `stop`) and placement, its health, totals, timings and crowded boards. It lists no pill targets and no reason for one: a pill stands for any shape that is not private.
