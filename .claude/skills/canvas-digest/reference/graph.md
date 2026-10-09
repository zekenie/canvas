# The digest format

A digest is one JSON file. It says what the things are, which holds which, and what points at what. It says nothing about where anything goes.

```json
{
  "title": "Name of the whole",
  "policy": {"mess": 0.1, "promote": true},
  "nodes": [{"title": "…", "kind": "auto", "in": "…", "text": "…", "public": true}],
  "edges": [{"from": "…", "to": "…", "weight": 1, "text": "…", "via": "reference", "direct": true}]
}
```

## The top

| field | meaning |
|---|---|
| `title` | what the digest is of. It names the first board's header note, `About <title>`. Default `Digest`. |
| `policy.mess` | the dial, 0 (tidy) to 1 (loose). Default 0.1. `--mess` on the command wins. |
| `policy.promote` | `false` promotes no hub, whatever the dial. Default `true`. |

## Nodes

A node is a shape. The list is flat: a node says which node holds it with `in`.

| field | meaning |
|---|---|
| `title` | required. Unique across the whole file and the app's file (case aside, spaces folded), at most 80 characters. It is how edges, `in` and later scripts name the shape. |
| `kind` | `sticky-note` (the default), `frame`, `subboard` or `auto`. |
| `in` | the title of the frame or subboard that holds it. Left out, it is on the first board. |
| `text` | a note's words. A note is as tall as its text needs. Frames and subboards ignore it. |
| `public` | `true` pins the node public (it will be a thing others point at through a pill); `false` means never promote it. Left out, the loop decides. |

**Choosing kinds.**

- A **sticky-note** is a leaf: one thing. A note holds nothing.
- A **frame** is a group on a board that a reader sees at a glance (a package, a team, a theme). Nest them: a frame can hold frames. Keep each to about 15 shapes.
- A **subboard** is a card that opens its own board, for a part too big to show inline. Everything in it is laid out on its own board, and an edge from outside it is drawn as a pill.
- **auto** picks for you: a subboard when it holds over 40 notes or subboards, or when something sits three levels below it (it holds a frame that holds a frame that holds a shape), and a frame otherwise.
- Only containers can be named by `in`. Every title in `in` must be a node, and `in` can't run in a circle (A in B, B in A, or A in A): `check` and `plan` refuse it, naming the titles.

A board with more than about 150 shapes is hard to read; make a subboard of a part.

## Edges

An edge is "from points at to". Both must be notes or subboards, never frames.

| field | meaning |
|---|---|
| `from`, `to` | titles of nodes. An edge to itself is ignored. An edge that names a frame is dropped with a warning. |
| `weight` | how strongly the layout keeps the two near. Default 1. Two edges with the same ends are one edge, with their weights added. |
| `text` | what the arrow says. Short. |
| `via` | `"reference"` says the arrow is drawn into a pill, even between neighbors. The end is made public. |
| `direct` | `true` says this edge is never a pill, even if its end is a hub. Edges between boards ignore it: an arrow can't leave its board. |

**Which become pills.** An edge between two boards is always a pill, and its end is public. An edge with `via: "reference"` is too. For the rest the plan decides, one hub at a time, by what it costs in arrows that cross each other or run over shapes: when it promotes a hub, every shape that points at it gets a pill, shapes of one frame sharing one, and the hub is made public.

## An example, in words

An engineering team's service map, six things:

- The whole is called "Shop platform".
- A frame "Services" holds three notes: Orders (takes orders), Billing (charges them) and Catalog (what is for sale).
- A frame "Stores" holds two notes: Orders DB and Cache.
- One note, "Gateway", is on its own: every call from outside comes through it.
- Gateway points at Orders, Billing and Catalog (text "routes to"). Orders and Catalog point at Cache, and Orders points at Orders DB. Billing points at Orders.

As a digest that is a title, six nodes (two of kind `frame`, with the three notes `in` "Services" and the two `in` "Stores"), and eight edges. Cache has two users in one frame, so it isn't worth a pill; if five more services pointed at it from three frames, the plan would promote it: the Cache note becomes public, and each of those services shows a pill for it beside it (the ones in one frame sharing a pill) instead of a line across the board. The summary lists Cache under "public", with why.

## What the commands read and write

All files go in the out folder (`--out`, default the digest's name with `.out`).

| command | reads | writes |
|---|---|---|
| `check` | the digest, `canvas kinds`, one `canvas query` for the titles in the file (with `--board`) | `kinds.json`, `titles.json` |
| `measure` | the digest, `canvas measure` | `measure.draw` (what was measured), `measure.json` (the answer) |
| `plan` | the digest, `measure.json` | `plan.json`, `report.json`, `runs/NN-<board>-<step>.draw` |
| `draw` | the plan and runs | the board; `results/NN-<board>-<step>.dry.json` and `.json`, what `canvas draw` said of each run; `state.json`; `target.id` for a new file |
| `verify` | the plan, the saved results, one `canvas query` for the titles in the file | nothing |

`plan.json` has each board's shapes (`x`, `y`, `w`, `h` from the board's header note), its pills, and its edges in the order they are drawn; for an edge into a shared pill, `share` and `host` name the shape whose pill it reuses. It names the subboard the digest goes in (`into`, null for a new file) and the scripts in order (`runs`). `report.json` has the promotions with their costs, where each board's loop stopped and why, and the public set with a reason for each. Read the report when the summary isn't what you expected.
