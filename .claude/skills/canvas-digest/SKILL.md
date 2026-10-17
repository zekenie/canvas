---
name: canvas-digest
description: Lay out a large body of connected information as boards in Infinite Canvas: a codebase, an org, research notes, a plan, a dependency map, anything with dozens to hundreds of things and the links between them. You write a digest (a JSON list of nodes, where each sits, and the edges between them), and `digest` measures it in the app, decides where every shape goes and which hubs become public shapes with reference pills, then draws it with `canvas draw`. Use when asked to "map this codebase onto a board", "digest this into boards", "lay out these notes and how they connect", "turn this graph into a canvas", or when a script would be over about 40 shapes or has hubs that many arrows point at. NOT for placing a few shapes by hand (that's the canvas skill and `canvas draw`), NOT for reading or querying a board (`canvas query`), NOT for changing shapes the user made, and NOT for diagrams meant for a file.
---

# Digesting a body of information into boards

`canvas draw` places each shape against ones you already named, and that's right for a dozen shapes. Past forty it stops being work you can do by hand: you can't see the board, so every distance is a guess, and a note that many arrows point at turns the page into a knot. `digest` is the other way round. You say **what the things are, which holds which, and what points at what**; it works out the rest: sizes measured in the app, an arrangement of every board, which hubs get pills, and a `draw` script for each step with every position stated exactly.

It uses the canvas skill's `canvas` command and draws only with it. Read that skill first for the app, the boards and how `--board` works.

## When

- A body of connected things you've read or gathered: a repository's modules and what imports what, an org and who works with whom, research notes and their citations, a plan's tasks and dependencies.
- You'd otherwise write more than about forty shapes, or arrows would run between groups.
- It makes a **new** board: a new file, a new subboard on a board you name, or an empty board's own. It never moves or restates a shape it didn't make.
- To draw a digest **again** (it changed, or the dial did), run it with the same `--out` and `--replace`: its last drawing (`drawn.json` there) is taken back first, one undo step, and drawn anew in its place, when it is in the target board's file. On a board that holds anything else, a digest drawn as the board is refused.

## The steps

(`digest ready graph.json <target>` says whether a draw could start, before you spend time on the digest: the app running, the board able to take it, a new file's folder there, and, with `--replace`, the last drawing one the app will take back.) Everything runs through `digest`, the driver in this skill's folder (`.claude/skills/canvas-digest/digest` in this repository); it is the only thing here that runs `canvas`, and it finds `canvas` itself (`$CANVAS_CLI`, else the one beside it, in the app or in the repository's checkout, else your PATH). The state of the app is the canvas skill's [Check the app](../canvas/SKILL.md#check-the-app). Every command takes the digest and, where it draws or reads a board, a **target**: `--board <id>` with `--into "Title"` (the digest goes in a new subboard of that open board, called Title); `--board <id>` alone (the digest is that board, which must be empty); or `--new-file <path>` (a new board's file, made and opened by `canvas new`; the digest is its board). `--board front` is the board in front. `--out <dir>` says where the files go (default: the digest's name with `.out`).

1. **Write the digest.** A JSON file of `nodes` (title, kind, what holds it, text) and `edges` (from, to). The format, and how to choose what holds what, is in [reference/graph.md](reference/graph.md). Make containers for the groups a reader would name (a package, a team, a theme): frames for a group on a board, subboards for a part big enough to open (`kind: auto` picks). Keep titles short and unique across the whole file; keep each frame to about 15 shapes.
2. **Check it.** `digest check graph.json --board <id> --into "Title"`. It refuses duplicate titles, titles over 80 characters, a title already in the file (one `canvas query`; with `--new-file` there is nothing to clash with), and a kind `canvas kinds` doesn't list; it warns past 15 shapes in a frame or 150 on a board. Fix what it says and run it again: a board with a frame of more than 150 shapes, or more than 1,000 in all, is laid out once and not searched (it would take hours), and reads as a crowd.
3. **Measure and plan it.** `digest plan graph.json --into "Title"` measures every shape with `canvas measure` (a note as tall as its text, a pill as wide as its label), lays out every board, and writes `plan.json`, `report.json` and the draw scripts (`runs/NN-<board>-<step>.draw`) to the out folder. It prints a short summary: the boards, the shapes, the pills, **what it will make public and why**, and where the loop stopped. Nothing is drawn yet. If the summary isn't what you meant, change the digest or the dial and plan again: `plan` measures again when the digest is newer than its `measure.json`, and keeps the measurement otherwise. (`digest measure graph.json` does only the measuring, into `measure.json`.)
4. **Draw it.** `digest draw graph.json --board <id>` (or `--new-file <path>`). Each script is a dry run first: every `at` row it gets back is compared with the plan, and it stops before drawing a script whose dry run isn't the plan, naming the shape, rather than drawing a wrong board. Then it draws the script for real and compares again. The order is the plan's: the subboard (with `--into`), then each board's shapes (public ones made public in their own statements), then each board's edges, the host of a shared pill first and the others saying `share: "<host>"`.
5. **Verify.** `digest verify graph.json --board <id>` reads every saved result back against the plan (each shape and pill within a unit of its place, each arrow drawn, no shape restated) and asks the file for its titles. It says `verify ok` or what is off.
6. **Tell the user** what you made and what is public (below).

`digest all graph.json <target> [--mess N] [--promote off] [--prefer N] [--cap N] [--view WxH] [--ranks rows|columns] [--into "Title"] [--replace]` runs check, measure, plan, draw and verify in order and stops at the first that fails. If a step fails, the message says which script and what the app said (exit 1 refused, 4 not the plan). Don't fix a script by hand and run it alone: change the digest and plan again, because the later scripts are placed against the earlier ones. A drawn board's runs are each one undo step (Edit › Undo Draw), but the plan can't be resumed: run it again with `--replace` (it takes back what was drawn and draws it all; that works whether the user has undone some of it, all of it, or nothing), or plan again into a new place.

A warning that shapes landed outside the window's view is not a problem: a big drawing is bigger than the window, and the camera is the user's.

## Types

A digest can say what its things are, not only how they connect: a node with a `schema` is a **type** (Postgres table, Temporal workflow, Lambda), a node with `is: "Table"` and `fieldValues` is a note of it, a node with `relationship: true` is a **relationship type** (`writes`), and an edge with `is: "writes"` is a relationship between two notes. Then a question like "which workflows write the orders table?" is a `canvas query`. `check` refuses what the app would draw wrongly (an `is` naming no type, values that don't fit their schema, a `$ref` to a shape's id, an `endRule` on an edge that isn't an end of a relationship type, ends on another board than their relationship type), and `plan` measures the types with their ends so a typed note is planned at the size it keeps. The format, the refusals and the order of the runs (types and their ends first, then the notes of a type, then the arrows) are in [reference/graph.md](reference/graph.md#types). A typed drawing warns by design (a Needed row still empty, a relationship that doesn't fit its ends): `draw` and `verify` report those and don't stop for them. Tell the user what they say.

## The dial

One number sets how tidy the board is: `--mess`, from 0 (tidy) to 1 (loose), or `"policy": {"mess": 0.3}` in the digest; the flag wins. The default is **0.1**.

- **Tidy** (0 to 0.2) turns more arrows into pills: fewer long arrows and crossings, more pills, bigger boards. This is the right place to start.
- **Loose** (0.5 and up) keeps plain arrows: smaller boards, more lines across them. At 1 the tool turns no arrow on a board into a pill: only edges between boards use them, and the users of a node you pinned with `public: true` (`--promote off` leaves those as arrows too).

What it decides, on each board:

- **Popular shapes first, on a board that needs it.** A board that is tidy enough with plain arrows (nothing crossing, nothing over a shape, by the dial) is left as it is. On any other, a shape that many arrows point at is *promoted*: it is made public, and each shape that points at it shows a pill for it beside itself. A shape that points at many is *fanned out*: each thing it points at is a pill beside it. "Many" is the dial's: 5 arrows at 0.1, 4 at 0, 9 at 0.5. The most arrows go first, until the board is tidy enough or no shape is popular.
- **Then the judgment calls.** For shapes with fewer arrows it lays the board out both ways and keeps a move only when it clearly pays, up to a cap (a share of the board's shapes).
- **No arrow runs too long.** One over the dial's length (1300 units at 0.1, about four notes) becomes a pill beside its start. Length is as the view sees it: an arrow may run further across a wide view than down it.

`--promote off` (or `"promote": false` in the digest) does none of it. `--cap 0..1`, `--margin PILLS` and `--popular ARROWS` override the dial's, and `--prefer N` is how many pills' prices a hub's second pill in one frame must save (default 2: one pill is preferred, and a far group of users gets its own).

## The view

Every board is laid out to fill the window it will be seen in, when it is fit to that window: wider than tall for a wide one. As it plans, `digest` asks the app how much room the target board's window has for a board (`canvas boards` says it, as `view`; for a new file, the window in front's), and the plan's first line says the view it laid out for.

- `--view 1312x772` says another view: for a board meant for a screen you can't ask. With no window and no `--view` it assumes 1440 x 960 and says so.
- Shapes with a `rank` (layers, phases) run as rows or as columns, whichever the view shows larger. `"policy": {"ranks": "rows"}` in the digest says which, and `--ranks rows|columns` says it over the digest.
- A drawing is shaped once, for the window as it was. It isn't laid out again when the window changes: draw it again (`--replace`) for that.

## What it makes public

A reference pill stands for a **public** shape, so promoting a hub makes it public. The tool makes public only shapes it creates itself, never one that was already on a board, and says which:

- a shape many point at, whose users it gives pills to (the report says `promoted`),
- what a pill beside a shape that points at many stands for (`fanned out`), and the end of an arrow that would run too long,
- the end of any edge that crosses boards or says `via: reference`,
- a node you wrote `public: true` on.

`public: false` on a node means never promote it, and `direct: true` on an edge means that edge is never a pill.

Tell the user the list from the summary, in a sentence: how many shapes are public, a few names, and why (they are the ones many arrows point at, so their users show a pill beside them instead of a long line). A public shape shows a Public chip and can be referenced from other boards. Each script is one undo step (Edit › Undo Draw), so the user can step back through the run; deleting the new subboard takes it all.

## Limits

- It doesn't update a drawing shape by shape: `--replace` takes the last one back and draws the digest anew, so what the user changed in it goes too (one Undo Draw after the run's own brings the last drawing back).
- An edge can't start or end on a frame (a frame has no ports); point it at a shape in it. A subboard can be an end.
- Pills read from the app's own sizes. If the app changes how a note or a pill is sized, plan again; a plan is only good for the app it measured.
