# The graph document

One JSON file. It says what the things are (their kind and the attributes the app reads), which holds which, and what points at what. It says nothing about where anything goes: `digest` decides that. It is also the file `canvas apply` takes once it has places.

```json
{
  "drawing": "native-canvas",
  "layout": {"mess": 0.1, "ranks": "rows"},
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
| `layout.mess` | the dial, 0 (tidy) to 1 (loose). Default 0.1. `--mess` on the command wins. |
| `layout.promote` | `false` promotes no hub, whatever the dial. Default `true`. |
| `layout.ranks` | `"rows"` or `"columns"`: which way shapes with a `layout.rank` run. Left out, whichever the view shows larger. `--ranks` on the command wins. |

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
| `public` | `true` pins the node as a pill target (the app makes it public); `false` rules it out: never promoted, never fanned out, no edge to it is a pill. Not for a node that holds shapes. |

## Edges

| field | meaning |
|---|---|
| `from`, `to` | node keys. |
| `props` | optional, for the app: the arrow's attributes as `canvas kinds arrow` lists them (`text`, `is`, `fieldValues`, `endRule`, ...). Passed through. |
| `key` | optional; an edge may carry one of its own. |
| `layout` | `weight` (a number, default 1: how much the layout wants the ends near) and `direct` (`true`: never a pill). |

Edges are told apart by their ends and their `is`. Two alike are refused by the app. Edges between one pair count as one to the layout (weights added), and each is drawn.

Edges the layout can't draw are left out with a warning, in the app's words where it refused them (`canvas measure` lists them): between a container and what it holds, between kinds that share no channel. The layout's own limits: an edge to a node that holds shapes goes only between nodes on one board (never through a pill); an edge between boards goes through a pill for its far end, so one to a kind no pill stands for is left out.

## Pills

A node many arrows point at, or an edge between boards, is drawn as a **reference pill** beside the start, standing for the far end (`to`). The app makes the far end public. You say nothing of it; `layout.public` and `layout.direct` are the only controls. The result is in drawing.json: an edge's `place.pill` is `{"at": [x, y], "in": "<frame key>"}` where the pill sits, or `{"share": "<node key>"}` to draw into the pill that node's edge makes.

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

`report.json` says what became a pill target and why, the moves the loop made, totals, timings and crowded boards.
