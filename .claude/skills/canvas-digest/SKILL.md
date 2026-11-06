---
name: canvas-digest
description: >-
  Lay out a large body of connected information as boards in Infinite Canvas: a codebase, an org, research notes, a plan, a dependency map, anything with dozens to hundreds of things and the links between them. You write a graph document (nodes by key, where each sits, the edges between them), and `digest` measures it in the app, decides where every shape goes and which hubs become public shapes with reference pills, then draws it with `canvas apply` in one step. Use when asked to "map this codebase onto a board", "digest this into boards", "lay out these notes and how they connect", "turn this graph into a canvas", or when a script would be over about 40 shapes or has hubs that many arrows point at. NOT for placing a few shapes by hand (that's the canvas skill and `canvas draw`), NOT for reading or querying a board (`canvas query`), NOT for changing shapes the user made, and NOT for diagrams meant for a file.
---

# Laying out a body of information as boards

`canvas draw` places each shape against ones you already named, and that's right for a dozen shapes. Past forty you can't see the board, so every distance is a guess, and a note that many arrows point at turns the page into a knot. `digest` is the other way round. You say **what the things are, which holds which, and what points at what**, as a graph document with a key for each node. It asks the app for sizes, works out where everything goes and which hubs get pills, and the app draws the whole document by key (`canvas apply`) in one step, all or nothing.

Three layers, each passing the rest through unread: the app owns every rule about shapes (what a kind takes, what a title may be, what is refused); `digest` owns where things go; whatever makes the document (you, or [canvas-ingest](../canvas-ingest/SKILL.md) for a repository) owns what the things are. Read the canvas skill first for the app and the boards.

## When

- A body of connected things you've read or gathered: a repository's modules and what imports what, an org and who works with whom, research notes and their citations, a plan's tasks and dependencies.
- You'd otherwise write more than about forty shapes, or arrows would run between groups.
- Drawing it **again** is the same command with the same `drawing` name: the app updates the drawing's shapes by key, makes new ones, deletes those whose keys are gone, and touches nothing it didn't draw. The layout starts from where the shapes are (below).

## The steps

`digest` (this skill's folder; `.claude/skills/canvas-digest/digest` in this repository) is the only thing here that runs `canvas`, and it finds it (`$CANVAS_CLI`, else the one beside it, else your PATH). `digest ready` says whether a draw could start: the app running with a board open, and the app new enough to have `canvas apply`.

1. **Write the document.** The format, with what is read and what is passed through, is in [reference/graph.md](reference/graph.md). A node needs a `key` (the same every run: it is the identity the app's record and the refusals use), a `kind` and, in `props`, whatever the app reads for that kind (`canvas kinds` lists the attributes). Make containers for the groups a reader would name: frames for a group on a board, subboards for a part big enough to open; `in` says which holds which. Keep each frame to about 15 shapes. Edges are `from`, `to` (keys) and `props`; an edge between boards, or to a node many point at, becomes a pill on its own.
2. **Check it.** `digest check graph.json`. It refuses only what the layout can't read: a key twice or missing, a kind the app doesn't list or can't draw, an `in` that names no node, a node whose kind holds nothing, a cycle, an edge end that names no node, a wrong `layout` hint. Everything else (a value, a title, a type) the app refuses when it measures or applies, in its words, naming the key.
3. **Measure and plan it.** `digest plan graph.json --out DIR` measures the document with `canvas measure` (a note as tall as its text, a pill as wide as its label and the place it says its shape is, a frame's title width, the edges the app would refuse), lays out every board, and writes `DIR/drawing.json` (the document with places) and `DIR/report.json`. It prints a short summary: the boards, the shapes, the pills, **what it will make public and why**, and where the loop stopped. Nothing is drawn. If the summary isn't what you meant, change the document or the dial and plan again.
4. **Apply it.** `digest apply --dry-run --out DIR` answers what would be done and what the app would refuse; `digest apply --out DIR [--on NAME]` draws it. A refusal exits 1, prints each refusal by key with the app's message and hint, and changes nothing. One undo step (Edit › Undo Draw).
5. **Tell the user** what you made and what is public (below).

`digest all graph.json --out DIR [--on NAME] [--view WxH] [--mess N]` runs check, measure, plan (from where the drawing is now, when the file holds it), apply `--dry-run` and apply, and stops at the first that fails. `--on NAME` is the board to draw on: a subboard's title, path or `#id`; left out, the front board's root, or, for a drawing the file already has, where it was drawn.

A warning that shapes landed outside the window's view is not a problem: a big drawing is bigger than the window, and the camera is the user's.

## Drawing again

When the file already holds the drawing, `digest all` asks it where its shapes are (`canvas query ':drawn-by("NAME")' --brief`; a file without the drawing answers no rows and the plan starts afresh, while a query that fails stops `digest`, since drawing afresh would move a person's shapes back) and plans from there: a frame or board whose members are exactly the keys it holds now (none added, removed or moved between containers) keeps every member where it is, the frame at least its current size; any other container is laid out afresh. So a drawing a person has tidied stays as they left it where the document hasn't changed, and the app's `overrode` list says what a person had changed that this apply changed again. The pills are decided afresh each time (the same document decides the same); they are laid out beside the kept shapes, or the container is laid out afresh when they no longer fit, and the app moves each pill already drawn to where the plan puts it (a pill a person dragged away goes back beside its shape). Ranked bands are laid out by their ranks whatever their places now, so `--ranks rows` over a drawing of columns turns it, each band keeping what it holds.

## The dial

One number sets how tidy the board is: `--mess`, from 0 (tidy) to 1 (loose), or `"layout": {"mess": 0.3}` in the document; the flag wins. The default is **0.1**.

- **Tidy** (0 to 0.2) turns more arrows into pills: fewer long arrows and crossings, more pills, bigger boards. This is the right place to start.
- **Loose** (0.5 and up) keeps plain arrows: smaller boards, more lines across them. At 1 no arrow on a board becomes a pill: only edges between boards use them, and the users of a node you pinned with `layout.public: true` (`--promote off` leaves those as arrows too).

What it decides, on each board:

- **Popular shapes first, on a board that needs it.** A board that is tidy enough with plain arrows (nothing crossing, nothing over a shape, by the dial) is left as it is. On any other, a shape that many arrows point at is *promoted*: it is made public, and each shape that points at it shows a pill for it beside itself. A shape that points at many is *fanned out*: each thing it points at is a pill beside it. "Many" is the dial's: 5 arrows at 0.1, 4 at 0, 9 at 0.5. The most arrows go first, until the board is tidy enough or no shape is popular.
- **Then the judgment calls.** For shapes with fewer arrows it lays the board out both ways and keeps a move only when it clearly pays, up to a cap (a share of the board's shapes).
- **No arrow runs too long.** One over the dial's length (1300 units at 0.1, about four notes) becomes a pill beside its start. Length is as the view sees it: an arrow may run further across a wide view than down it.
- **Cards that point at the same shapes sit around them.** A frame (or a board) of at most six shapes that don't point at each other, and point at two or more of the same shapes, is a *spine*: its shapes in two columns, and between them the pills they share, so no arrow crosses a shape. Everything a spine's shapes point at is a pill; at 1, and with `--promote off`, nothing is a spine.

`--promote off` (or `"promote": false` in the document) does none of it. `--cap 0..1`, `--margin PILLS` and `--popular ARROWS` override the dial's, and `--prefer N` is how many pills' prices a hub's second pill in one frame must save (default 2: one pill is preferred, and a far group of users gets its own).

## The view

Every board is laid out to fill the window it will be seen in, when it is fit to that window: wider than tall for a wide one. `--view 1312x772` says the room the window has; with none the tool assumes 1440 x 960 and its summary says so. Shapes with a `layout.rank` (layers, phases) run as rows or as columns, whichever the view shows larger; `"layout": {"ranks": "rows"}` in the document says which, and `--ranks rows|columns` says it over the document. A drawing is shaped once, for the window as it was.

## What it makes public

A reference pill stands for a **public** shape, so promoting a hub makes it public. The app makes public the end a pill stands for; `digest` says which, and why, in its summary:

- a shape many point at, whose users it gives pills to (`promoted`),
- what a pill beside a shape that points at many stands for (`fanned out`), and the end of an arrow that would run too long,
- the end of any edge that crosses boards, and what a spine's shapes point at,
- a node you wrote `layout.public: true` on, when a pill stands for it (a pinned node no pill is drawn for, as with `--promote off`, is not made public, and is not listed).

`layout.public: false` on a node means never promote it, and `layout.direct: true` on an edge means that edge is never a pill.

Tell the user the list from the summary, in a sentence: how many shapes are public, a few names, and why (they are the ones many arrows point at, so their users show a pill beside them instead of a long line). A public shape shows a Public chip and can be referenced from other boards.

## Limits

- An edge at a frame is an arrow to another frame or a subboard on its board, never a pill, so a frame is never a hub.
- The app refuses what it refuses (a frame and what it holds, kinds with no channel in common): such an edge is left out with the app's words as a warning.
- Pills read from the app's own sizes. If the app changes how a note or a pill is sized, plan again; a plan is only good for the app it measured.
