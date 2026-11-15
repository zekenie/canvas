---
name: canvas-digest
description: >-
  Lay out a large body of connected information as boards in Infinite Canvas: a codebase, an org, research notes, a plan, a dependency map, anything with dozens to hundreds of things and the links between them. You write a graph document (nodes by key, where each sits, the edges between them), and `digest` measures it in the app, decides where every shape goes and which links become reference pills so no arrow crosses another, then draws it with `canvas apply` in one step. Use when asked to "map this codebase onto a board", "digest this into boards", "lay out these notes and how they connect", "turn this graph into a canvas", or when a script would be over about 40 shapes or has hubs that many arrows point at. NOT for placing a few shapes by hand (that's the canvas skill and `canvas draw`), NOT for reading or querying a board (`canvas query`), NOT for changing shapes the user made, and NOT for diagrams meant for a file.
---

# Laying out a body of information as boards

`canvas draw` places each shape against ones you already named, and that's right for a dozen shapes. Past forty you can't see the board, so every distance is a guess, and a note that many arrows point at turns the page into a knot. `digest` is the other way round. You say **what the things are, which holds which, and what points at what**, as a graph document with a key for each node. It asks the app for sizes, works out where everything goes and which links become pills, and the app draws the whole document by key (`canvas apply`) in one step, all or nothing.

Three layers, each passing the rest through unread: the app owns every rule about shapes (what a kind takes, what a title may be, what is refused); `digest` owns where things go; whatever makes the document (you, or [canvas-ingest](../canvas-ingest/SKILL.md) for a repository) owns what the things are. Read the canvas skill first for the app and the boards.

## When

- A body of connected things you've read or gathered: a repository's modules and what imports what, an org and who works with whom, research notes and their citations, a plan's tasks and dependencies.
- You'd otherwise write more than about forty shapes, or arrows would run between groups.
- Drawing it **again** is the same command with the same `drawing` name: the app updates the drawing's shapes by key, makes new ones, deletes those whose keys are gone, and touches nothing it didn't draw. The layout starts from where the shapes are (below).

## The steps

`digest` (this skill's folder; `.claude/skills/canvas-digest/digest` in this repository) is the only thing here that runs `canvas`, and it finds it (`$CANVAS_CLI`, else the one beside it, else your PATH). `digest ready` says whether a draw could start: the app running with a board open, and the app new enough to have `canvas apply`.

1. **Write the document.** The format, with what is read and what is passed through, is in [reference/graph.md](reference/graph.md). A node needs a `key` (the same every run: it is the identity the app's record and the refusals use), a `kind` and, in `props`, whatever the app reads for that kind (`canvas kinds` lists the attributes). Make containers for the groups a reader would name: frames for a group on a board, subboards for a part big enough to open; `in` says which holds which. Keep each frame to about 15 shapes. Edges are `from`, `to` (keys) and `props`; an edge between boards becomes a pill on its own, and so does one its board can't draw without crossing another (Which links are pills, below).
2. **Check it.** `digest check graph.json`. It refuses only what the layout can't read: a key twice or missing, a kind the app doesn't list or can't draw, an `in` that names no node, a node whose kind holds nothing, a cycle, an edge end that names no node, a wrong `layout` hint. Everything else (a value, a title, a type) the app refuses when it measures or applies, in its words, naming the key.
3. **Measure, group and plan it.** `digest plan graph.json --out DIR` measures the document with `canvas measure --tightness` (a note as tall as its text, a pill as wide as its label and the place it says its shape is, a frame's title width, the edges the app would refuse, how alike each link's two notes are), groups each container's shapes (Groups, below) and cuts the links between groups, lays out every board, and writes `DIR/drawing.json` (the document with places) and `DIR/report.json`. It prints a short summary: the boards, the shapes, the pills, how many links it cut into pills, and **how many boards are clean** (below). Nothing is drawn. If the summary isn't what you meant, change the document and plan again.
4. **Apply it.** `digest apply --dry-run --out DIR` answers what would be done and what the app would refuse; `digest apply --out DIR [--on NAME]` draws it. A refusal exits 1, prints each refusal by key with the app's message and hint, and changes nothing. One undo step (Edit › Undo Draw).
5. **Tell the user** what you made and how many links it drew as pills (below).

`digest all graph.json --out DIR [--on NAME] [--view WxH]` runs check, measure (with tightness), the groups, plan (from where the drawing is now, when the file holds it), apply `--dry-run` and apply, and stops at the first that fails. `--on NAME` is the board to draw on: a subboard's title, path or `#id`; left out, the front board's root, or, for a drawing the file already has, where it was drawn.

A warning that shapes landed outside the window's view is not a problem: a big drawing is bigger than the window, and the camera is the user's.

## Clean boards

Every plan measures every board on the drawing it will apply, and says in its summary how many are clean: no arrow crosses another, none runs over a shape or the title above it (or within 8 units of one), and no shape sits on another or on the title above it. A note's lines into pills over the pills it uses itself are counted apart and don't count against it. The summary names the five least clean boards; `report.json` has each board's `health`: its status, the crossings, lines over shapes and shapes on top, a few examples by key, its links and how many are cut into pills, its pills, its size and the zoom a window shows it whole at, and the seconds its layout took. A plan cuts links into pills until every board is clean (Which links are pills, below); a board that still isn't (what crosses can't be cut, or the board is too crowded to lay out again and again) is drawn all the same. Tell the user how many boards are clean, in a sentence, with the least clean if they are few.

## Drawing again

When the file already holds the drawing, `digest all` asks it where its shapes are (`canvas query ':drawn-by("NAME")' --brief`) and what a person changed of them (`:changed("NAME")`); a file without the drawing answers no rows and the plan starts afresh, while a query that fails stops `digest`, since drawing afresh would move a person's shapes back. A redraw then moves a shape only for a reason. Every shape, arrow and pill stays as the file has it, so an unchanged document changes nothing, and only what the document changed is decided: a new note goes to the nearest clean spot by its links, the tighter ones counting for more, a longer note grows where it stands, a new link is an arrow where its line is clear, else a share of a pill the file has, else a pill of its own. What a person moved, resized or carried into another frame stays where they put it, with its pills about it, and a shape of the drawing's own that it now covers moves out of its way, as little as it can; the report's `held`, `moved` (with why) and `carried` say which. A shape the document itself put in another frame goes there all the same, and the app's `overrode` list says what a person had changed that this apply changed again. On a later redraw a person's shape is kept in place like the rest, moving only for a reason, and one they carried into another frame goes back to the frame the document has it in. The groups are found again over the document as it is (a note a person carried is grouped in its new frame), only to weigh its links; nothing the file has is regrouped by them, so to group a drawn board again from the tightness, draw it into a new file. A board is laid out afresh only when the file holds none of it; one whose conflicts no cut mends is drawn as it is and said not clean. Ranked bands are turned only when `--ranks` asks for another way than the file has them, each band keeping what it holds.

## Groups

A board of many notes reads better as groups. Before the plan, `digest` groups each container's shapes (a board, or a frame of the document's) by how tightly their links hold them. The groups add nothing to the board: no frame, no container, and no shape moves out of the board or frame the document put it in. They only decide which links are cut. A link is as tight as its two notes are alike: `canvas measure --tightness` asks the app's embedding model (OpenAI's text-embedding-3-large) for a vector of each note's title and text, and a board's links are ranked by how alike their two notes are. The groups are found by Louvain community detection at its resolution 1.5, which makes smaller groups than its usual 1. A frame of the document's own is one item in what holds it, never split, and its own notes are grouped inside it. A link between two groups is cut, a pill before anything is placed, and the layout's own further cuts go the loosest first, so a group's links are mostly arrows. A cut link comes back as an arrow where, once everything is placed, its line crosses nothing; the summary says how many did. A link marked `layout.direct`, a link at a frame, and one into a node marked `layout.pill: false` (or of a kind no pill stands for) is never cut. The driver's messages call a group a cluster.

- **The key.** A tightness needs an OpenAI API key saved in Settings (the OpenAI pane). With one, the app sends each note's title and text, as `digest` would draw them, to OpenAI; it keeps every vector it receives in a file, so a text it has seen is not sent again. Nothing asks first: the saved key is the opt-in. Tell the user once when a run will send text (a codebase's, for ingest).
- **Without it** (no key, no network, an older app, or a measure that took longer than `--timeout`), the driver says why and the groups are by the links alone, each link weighing the same; the summary says so. The drawing is still clean; the groups are less apt. Before anything is drawn, run the step again once the key is saved (or after a timeout: the vectors that landed are kept) and the groups come from the tightness. Once the file holds the drawing, a redraw keeps what is drawn; to group it again from the tightness, draw into a new file, which starts afresh.
- **No frames to expect.** The board holds the shapes of the document and no others, so a path or a query's `inside` runs through the document's own frames.

## Which links are pills

A link becomes a reference pill only where its board can't draw it as an arrow without crossing another. There is no setting for how many: `digest` cuts the fewest links it finds, board by board, a container at a time.

- **Planar first.** A board can be drawn with no arrow crossing another exactly when its links make a planar graph. The links are taken the most wanted first (among ranked shapes, the nearer ranks before all else; then the heavier, by `layout.weight`; then the one at the busier shape, so a hub keeps its arrows and gives up its weakest users first), and each that would make the graph non-planar becomes a pill beside its start.
- **Then placed.** A container whose links have a cycle is laid out as **stars**: each hub among the shapes it links to, the most linked nearest, every link pulling, a pill's too, so what is linked sits close. One whose links have no cycle is laid out in **rows** (down or across, or as a tree); ranked shapes run as rows or as columns (below). `"layout": {"placement": "stars"}` or `"rows"`, on the document or on a frame's or a subboard's node, says which outright.
- **Then cut until clean.** The drawing is measured as the app will draw it (below), and a link in a crossing, or whose arrow runs over a shape, becomes a pill too; the board is laid out again from where it was, until it is clean (eight rounds at most). Where what crosses can't be cut (an arrow between frames, say), a container in rows is placed as stars instead, unless `layout.placement` asks for rows there.
- **Frames sit among what they link to.** A frame that a shape beside it links to is laid out with the shapes around it: its members are placed among them, each on the frame's edge toward what it links to, and the frame is drawn round them.
- **Then put back where there is room.** The cut decides before the shapes are placed, so on the finished drawing a link it made a pill, one cut between two groups too, is drawn as an arrow again wherever its line crosses nothing and runs over no shape or pill.
- **Pills stand in short strips.** A note's pills (one for each shape it points at) are in strips beside it, on the side its arrows leave least, at most eight to a row or column, each on a straight line that runs over none of the note's other pills. Notes of a board that use one shape share one pill, placed where each of them reaches it by a clear line; any that cannot keep a pill of its own.
- **Cards that point at the same shapes sit around them.** A frame (or a board) of at most six shapes that don't point at each other, and point at two or more of the same shapes, is a *spine*: its shapes in two columns, and between them the pills they share, so no arrow crosses a shape. Everything a spine's shapes point at is a pill.

A link marked `layout.direct: true` is never cut, nor one into a node marked `layout.pill: false`. A board or a frame holding more than 150 shapes side by side, or a board of more than 1,000 shapes in all, is cut to planar and laid out once, and the summary says to split it. The summary's `cut:` line says how many links became pills, and how many of those the drawing needed past the planar cut.

## The view

Every board is laid out to fill the window it will be seen in, when it is fit to that window: wider than tall for a wide one. `--view 1312x772` says the room the window has; with none the tool assumes 1440 x 960 and its summary says so. Shapes with a `layout.rank` (layers, phases) run as rows or as columns, whichever the view shows larger; `"layout": {"ranks": "rows"}` in the document says which, and `--ranks rows|columns` says it over the document. A drawing is shaped once, for the window as it was.

## What it reaches through pills

Every shape is public unless a person made it private, so a pill can stand for any shape the digest draws, and nothing is made public or private by it. A node whose `props` say `private: true` can't be stood for: write `layout.pill: false` on it too, and draw no edge to it from another board, or `canvas apply` refuses the pill, naming the node (the tool reads no `props`). The pill targets are:

- the end of a link cut into a pill, so its board draws with no arrow crossing another,
- the end of any edge that crosses boards, and what a spine's shapes point at,
- a node you wrote `layout.pill: true` on, when a pill stands for it (a pinned node no pill is drawn for stands for nothing).

`layout.pill: false` on a node keeps it off pills: no link into it is cut and no edge between boards may reach it. `layout.direct: true` on an edge means that edge is never a pill.

Tell the user how many links became pills, a few names of what they stand for, and why (a line to them would have crossed others, so the shapes that point at them show a pill beside them instead).

## Limits

- An edge at a frame is an arrow to another frame or a subboard on its board, never a pill, so a frame is never a hub.
- The app refuses what it refuses (a frame and what it holds, kinds with no channel in common): such an edge is left out with the app's words as a warning.
- Pills read from the app's own sizes. If the app changes how a note or a pill is sized, plan again; a plan is only good for the app it measured.
