# Drawing in layers

(The plan as it stands in the owner's working doc, exported 2026-11-05. The doc's picture of the board is in board/root-now.jpg beside this folder.)

Three layers, each owning one concern and passing the rest through untouched. The kernel (the app and `canvas`) owns every rule about shapes, the render layer owns where things go, and ingest owns what a codebase is made of. Seven landings get there, starting with the app remembering what it drew and saying what you changed since, so a program and a person can take turns on one board.

## What's wrong now

Every change to the app gets made a second time above it. Since canvas-digest landed on 2026-10-09, 33 of the 84 commits that changed the app also had to change the canvas skills: 277 skill files in all.

| Date | The app learned | What it cost above the app |
| --- | --- | --- |
| 2026-11-04 | Frames and subboards can be of a type (60a448c8) | The digest's checks, emitter and type rules; the canvas skill's kind tables; the `--ask` prompt, with a live eval. Nothing in ingest, so no lens, example or lens doc types a frame. |
| 2026-10-30 | Arrows join frames (a5b69796) | The same commit edited the digest's model, and e0bc65b8 that day stopped it dropping those edges. `frameRefusal` now copies the app's channel rules by hand. |
| 2026-10-23 | A shape is told apart by its path (bd8ee669) | 33 skill files. The digest now spells every name so `canvas draw` can't resolve it to some other shape. |
| 2026-10-23 | A pill says where its shape is (0d716a33) | The digest's measuring had to learn it: a pill is measured once for each container an arrow to it starts in. |
| 2026-10-22 | Types build on types (follow-up f72eebd8) | The digest ported the app's type order (C3) to JavaScript "so the two must agree", beside its own JSON Schema validator. |
| 2026-10-22 | `canvas draw` names a board's origin (5c8153ae) | 31 skill files. Until then the digest drew an About note on every board to measure from. |

Features also land where they were first needed rather than where they belong, so one tool has what the next one lacks:

- Laying out many shapes exists only in canvas-digest, so past about 40 shapes the canvas skill sends an agent to another tool and another format.
- Drawing again in place exists only in the digest (`--replace` and its drawing records), so nothing drawn by hand can be redrawn.
- The digest checks every value against its types before it draws, because a run that fails part way leaves part of a drawing on the board.

Both come from one gap. `canvas draw` was made for an agent typing a few lines: shapes named by title, one board a run, no coordinates, no idea of a drawing to bring up to date. A program on top of it has to rebuild identity, order, checking and take-back itself, and copies the app's rules to do it.

## The rule the layers keep

Each layer adds one concern and passes everything else through untouched. It never decides what the layer below allows: it asks.

1. **One concern a layer.** The kernel says what can exist and makes it so. The render layer decides where things go. Ingest decides what a codebase is made of.
2. **Pass through what isn't yours.** A field the render layer doesn't lay out by (a type, a value, a color, whatever a plugin adds next) reaches the kernel as written, unread.
3. **Ask, don't copy.** What's allowed, what a kind holds, how big a shape is: the layer above asks the kernel (its description, a dry run, a measure) and shows the kernel's own words when it refuses.
4. **A feature lives at the lowest layer that can own it.** Drawing again in place, naming a shape exactly, laying out a graph: each is built once, where everything above it gets it.

**The test every change must pass:** a plugin gives frames a new property, and a lens can set it the same day, with no edit to the render layer, to ingest or to a hand-written skill page. A test holds this: a fixture plugin's property reaches a board from a fixture lens, and nothing above the kernel names it.

## Back and forth

A program draws, you change the board, and the program takes another pass that starts from what you did. This holds for an agent using `canvas draw` and for ingest, and it rests on three things:

1. **It remembers each drawing**: which shapes the program made, what it wrote on each, and where each one sat.
2. **It says what you changed since.** `canvas changes` lists every shape of the drawing you moved, resized, edited, put in another frame or deleted, and whatever you added or connected to it. An agent reads it before its next pass; the skill teaches that loop.
3. **Nothing you change is locked.** The program knows what you changed, and when it has a reason to move or rewrite something again, it does. An agent decides from what it reads. Ingest, with no one to ask, starts its layout from where things are now, so a shape you moved stays put unless the new layout has a reason to move it. A pass deletes only its own shapes: what you added isn't part of its drawing.

**How it knows which shape is which.** Every shape already has an id that survives a rename or a move, and that's enough for `canvas draw`: the app records the ids a run made. Ingest is different. Each run rebuilds its whole picture from the code, so it also gives each shape a name of its own, like "the note for `apps/web/src/index.ts`". That name is the key: it's how a new run matches its new picture to the shapes already on the board, even after you renamed or moved them.

This changes one promise of ingest. Drawn into a new file, a commit still gives the same boards every time; drawn again on its own board, it starts from your changes.

## The kernel

The kernel is the app plus `canvas`, and most of it is built. Two things are missing: an interface for programs, and layers above it that read what it already says about itself.

It owns every rule about shapes: kinds and their properties, types and values, channels, what holds what, what can be public, titles and paths, how big a shape draws, undo. A plugin declares each rule once.

**It already describes itself.** `canvas kinds` lists every kind's attributes, its channels by side, and whether it holds shapes or a board. A frame's entry lists `public`, and since 60a448c8 `is` and `fieldValues` too. The digest reads only the kinds' names from it, and refuses `public: true` on a frame.

| Face | For | Today | Needed |
| --- | --- | --- | --- |
| `canvas draw` | an agent typing a few lines | Titles as names, placements, one board a run, a dry run, one undo step | Kept as it is, each run recorded in a drawing; later written on `apply` |
| `canvas apply` | a program | Missing: the digest fakes one out of `draw` | A whole drawing by key: every board, exact places, one undo step. A dry run gives each key a verdict in the kernel's words |
| Drawings | every program that draws | The digest's own records, and taking a drawing back by names | The app remembers each drawing: its shapes (by id, and by key for a program that rebuilds its picture) and what it wrote on each. A new pass knows what a person changed, and may change it again |
| `canvas changes` | an agent before its next pass, and ingest | Missing: nothing says what a person changed | What a person moved, edited, deleted, added or connected since a drawing |
| `canvas kinds` | every layer above | Kinds, attributes, channels, what each holds | Also what can join what and what a pill can stand for. The skill's kind pages are generated from it |
| `canvas measure` | the render layer | Sizes for a draw script | Sizes for a graph document too |
| `canvas query`, `capture` | anyone reading | Built | Kept |

`apply` runs on Draw's engine, so every attribute a plugin gives Draw works in it unchanged: a property is the same property whichever face writes it. The kernel puts a document in order itself (types before their notes, descriptions after what they mention), since only it knows why.

## The render layer

The render layer turns a graph of anything into boards, and it is the one place layout lives. It is canvas-digest's layout core, kept, with its copies of the kernel taken out.

**The graph document** is what every producer writes, a lens or an agent:

- **nodes**, each with a key (the producer's own name for it, the same from run to run), the node that holds it, and a kind;
- **edges** between keys;
- **`layout`**, the hints the render layer reads: `rank`, `direct`, `public`, the dial;
- **`props`**, everything else (`text`, `is`, `fieldValues`, `color`, whatever a plugin adds next), handed to the kernel as written.

The render layer owns `layout`; the kernel owns `props`. Neither reads the other's.

**What it does.** It sends the whole document to the kernel once, as a dry run, and gets back each shape's size and which edges will be drawn. It lays out every board (ELK, ranks, spines, fit to the window), and picks which arrows become pills, among the shapes the kernel says a pill can stand for. Then it applies the whole drawing in one step and reports.

**What it stops doing**: checking what kinds may do, validating values, putting scripts in order, spelling names, holding a run to its plan, keeping records of its drawings. The kernel does each of these, once.

**Where it runs**: outside the app, as today, a client of `canvas` like any agent. Anything it needs that `canvas` doesn't offer shows a gap in the kernel's interface.

**One base skill.** The canvas skill and canvas-digest become one skill: the graph document for anything past a handful of shapes, `canvas draw` for a few by hand, queries and pictures to read a board. Its kind pages are generated from `canvas kinds`.

Layout quality belongs to this layer alone, so whatever makes boards read better lands once and every producer gets it. That work is outside this plan; the board below found four defects to start from.

## Ingest

Ingest decides what a codebase is made of, and nothing else. Its two phases stay as they are:

- **Setup**, an agent with the team in rounds: a survey, a picture recommended from the code, each decision a named rule. It writes `.canvas/ingest.json` and `.canvas/lens.py`, and shows each round on a board.
- **The run**, with no agent: `ingest` scans a commit, runs the lens twice in isolation, and hands the graph to the render layer. The same commit and lens draw the same boards.

What changes is what a lens writes:

- **Keys from the code**: a file's path, a table's name. Titles are what the code calls things. Today lenskit renames a title another shape of its container has, and gives repeats elsewhere ids built from their containers' titles, all so `canvas draw` can name each one.
- **Any property, the day the kernel has it.** A lens writes `is` on a frame or `color` on a note, and it reaches the board. The lens reference points at the generated kind pages instead of keeping its own copy.
- **Lenses written for the digest format are rewritten**: this repository's, the two worked examples, the Immich trials. No shim, since no board holds user data yet.

The scanners, the cache, the lock, the runner and lenskit's readers stay as they are.

## How a change travels

Layered, a change touches only the layer that owns its concern. A change to the app's rules stops at the kernel.

| Change | Today it touches | Layered it touches |
| --- | --- | --- |
| Frames and subboards take types | The app; the digest's checks, emitter and type rules; the canvas skill's tables; never ingest | The app. A lens can write it that day |
| Arrows join frames | The app; the digest's model, in two commits | The app. The render layer lays out what the dry run keeps |
| Notes take a color | The app; never the digest, which drops `color` without a word | The app |
| A shape is told apart by its path | The app; 33 skill files | The app. Nothing above it names shapes by title |
| A new kind that holds shapes | The app; the digest's kind list, sizes, emitter, docs | The app. The render layer lays it out as it lays out anything `canvas kinds` says holds shapes |
| Arrows kept off notes | The digest | The render layer, and every producer gets it |
| A new language's scanner | Ingest | Ingest |
| You change a board a program drew | The next run refuses the board | The program reads what you changed and builds on it |

## What goes away

Roughly 1,800 of the digest's 4,800 lines go (my estimate, module by module), and none of them are layout.

| Layer | Goes | Done instead by |
| --- | --- | --- |
| Render | Kind rules in `check.mjs` and `frameRefusal` | The dry run's verdicts |
| Render | `types.mjs`'s value checker and its port of the app's type order | The dry run |
| Render | `names.mjs` | Keys |
| Render | Rounds of scripts: types, then notes, then descriptions | `apply`, which orders a document itself |
| Render | `compare.mjs`, `replay.mjs`, most of `verify.mjs` | The verdicts, and a read-back by key |
| Render | `redraw.mjs`, `places.mjs`, `drawn.json`, `--records`, most of the driver | Drawings |
| Ingest | lenskit's title claims (`alone`, `type`, ids built from containers) | Keys |
| Skills | The kind tables hand-written in `language.md`, `graph.md` and `lens.md` | Pages generated from `canvas kinds` |

**Kept:** all of the kernel; the layout core (`layout`, `promote`, `moves`, `cost`, `elk`, the dial); ingest's scanners, cache, lock, runner, readers and default lens; the setup rounds.

## Build order

Seven landings. Each one redraws this repository's board through the new path, the same picture, and deletes what it replaces.

1. **Drawings and changes.** The app remembers what each `canvas draw` run made, and `canvas changes` says what a person changed since. The canvas skill teaches the loop: draw, read the changes, draw again.
2. **Apply by key.** `canvas apply` in the kernel. Its result says which of a person's changes a pass changed again. The digest's emitter writes to it in place of draw scripts: same plan, same picture.
3. **Kinds say more.** `canvas kinds` adds what can join what and what a pill can stand for. The skill's kind pages are generated from it at build.
4. **Render asks.** The digest drops its copies: kind rules, value checker, names, rounds, compare and replay, records. Every other field of a node passes through, so `color` works the day this lands, and the layout starts from where things are on the board.
5. **One base skill.** The canvas skill and canvas-digest merge.
6. **Ingest on the graph.** lenskit writes the graph document, keyed by the code, with no title claims, and a run on a board someone changed starts from their changes. A worked example types a frame, and the pass-through test lands.
7. **draw on apply.** `canvas draw` is rewritten on `apply`, so the app has one way to write a board.

Landing 1 needs nothing else, and 2 builds on it. 3 can run beside them; 4 needs 2 and 3.

## The board

I drew this plan with today's tools: as a digest (39 shapes on three boards, two types, three frames of a type), drawn by `digest all` into a new file in about a second, verified clean, then colored by hand. The file is `~/Documents/Ingest trials/Drawing in layers.canvasboard`.

[picture: board/root-now.jpg]

**What it showed about the layers:**

- **Colors were dropped without a word.** I wrote `color: green` on the three new parts. `digest check` said ok, and `[color]` found nothing on the board: the digest passes on only the fields it lists. `canvas draw` took the same colors at once.
- **Typed frames worked.** Each layer is a frame of the type Layer, its values in the panel, so 60a448c8's change to the digest holds.
- **The digest's own page disagrees with itself.** graph.md's `is` row still says "Notes only"; the row under it says a frame or a subboard holds values.
- **Your hand edits ended the program's part.** Once you re-laid the top two layers, the digest refused to draw again in place ("board 2 holds 1 shape(s) more than this digest's last drawing made"), so ranks I'd added for the Kernel row never landed. That's what Back and forth is for.

**What it showed about how boards look,** the render layer's to fix:

- **A layer laid out as one row runs its arrows over notes.** The view was 3,002 by 1,230, so each layer became one wide row, and an arrow between two notes of a row crosses the notes between them: in the Kernel row, `checks by` runs over Drawings and canvas measure.
- **Labels land on arrowheads** where notes sit close (`uses`, `sizes by`, `keeps keys`).
- **A long arrow cuts across a whole layer** (`pages made from`, which you turned into a pill by hand).
- **Everything came out one color.** A note of a type takes its type's color, picked from the type's id when none is set, so 17 parts and 3 frames were one orange until I set Part to yellow.

---

## Appendix: how we'd know (said in chat after message 6; not yet in the doc)

**Improved** (a change to the app stops at the app):
- How often app changes reach the skills: since the digest landed, 33 of 84 app commits also changed the canvas skills (277 files). Recount over `git log` after each landing; an app change should touch nothing in the render layer or lenskit.
- An audit instead of a habit: the build's audit already refuses a module that names another module's kinds or properties without depending on it; the same check over the render layer and lenskit makes "nothing above the kernel names a kind" a refusal.
- The pass-through test: a test plugin's new property reaches a board from a test lens, untouched.
- Today's drawing, redone: draw the plan's board, change it by hand, draw again. Today the digest dropped colors silently and refused the redraw; after landing 4 the colors should land, after landing 6 the redraw should take another pass, and `canvas changes` should name exactly what was changed.

**Made worse** (the boards and their answers stay what they are):
- The same picture: the digest's tests pin every fixture's plan byte for byte, and `verify` holds every shape within a unit of it. Each landing redraws this repository's board and the two worked examples; their plans don't move unless the landing means them to. Before-and-after pictures side by side.
- The same answers: the worked examples' README queries are tests and must answer the same.
- No worse refusals: every case `digest check` refuses today has a test with its sentence; each must still be refused, now by the app, naming the same node.
- Not slower in a way a person would feel: Medusa's 5,533 shapes plan in 42 s; a round of 2,000 shapes draws in a minute or two.
