# Shape connection edges API

Claude Code session `849bcff1-71a2-43e9-80f1-c67e0589829d`, 2026-09-28 13:42 to 2026-09-28 17:34 UTC, on `main`, `topology`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-09-28 13:42] USER:
I want to talk about how shapes can be connected to one another. Now, this is a little bit speculative because many of the features that are going to be built on top of this abstraction don't exist yet. But I think now is the time to do it. Right now, there are currently two ways that shapes can be connected. Arrows and mentions. Both are simply edges in a sort of shape graph. But one um, one type shows the edge literally as another shape on the board, and the other is only shown in, in, in text. I want, there to be, an edges API. I want to be able to ask questions like, what are all the shapes connected to this shape? And know that these three are connected by mention and these three are connected by arrow. I want to also be clear that there will be more types of ways that shapes can be connected to each other. This is perhaps loosely based on TL draw bindings, but I have to say, TL draw bindings I find to be quite confusing. And their goals are not exactly the same as my goals. I need you to think through what state is derived and what is the system of record. Because I could definitely see a universal API for edges, being the system of record, but it doesn't quite make sense because in the case of arrows, when the arrow shape is added to the board, it itself is its presence is the edge. And when it's deleted, it is no longer the edge. So perhaps the edges API is derived.

[2026-09-28 13:44] USER (sent mid-turn):
Also note, edges will need a type. Beyond just mention an arrow. For example, different arrow channels a concept we already have are meaningfully different in the edges API semantic space.

[2026-09-28 13:45] WORKFLOW:
Map how shapes connect today, design an edges API three ways, judge, and synthesize

[2026-09-28 13:45] ASSISTANT:
The design workflow is running with nine agents. Four readers go first. Three designs follow, each from a different angle: edges derived from what shapes already hold, a steelman of edges as stored records, and starting from the queries and future edge types. Then an adversarial judge checks their claims against the code, and a synthesis produces one recommendation plus the decisions that are yours to make. I'll bring you the result when it finishes.

[2026-09-28 13:51] USER:
note: this will be consumed by a yet to be built query engine that answers questions about the board. takes in an input string in a custom dsl and outputs data as a response. not part of this task, but just FYI. knowing what is connected to what is going to be important to this product as we build it out

[2026-09-28 13:52] EDIT /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/849bcff1-71a2-43e9-80f1-c67e0589829d/workflows/scripts/edges-api-design-wf_c4f55fb6-253.js:
are meaningfully different in the edges API semantic space."

And a second follow-up (context, not part of this task): "this will be consumed by a yet to be built query engine that answers questions about the board. takes in an input string in a custom dsl and outputs data as a response. not part of this task, but just FYI. knowing what is connected to what is going to be important to this product as we build it out"

So: don't design the query engine or its DSL, but design the edges API so such an engine can sit on it well: edge types need stable names a DSL can write (as ChannelID is a shipped, never-changing string), queries must work across the whole file (every board), results must be plain data (ids, types, direction, carrier), and traversal/filtering by type and direction should be cheap. Say what the API gives such an engine and what it leaves to it. (The engine will presumably be reached by agents through the canvas CLI; how agents read is the user's to design.)`

[2026-09-28 13:52] ASSISTANT:
Noted. The four readers don't depend on that context, so I've added it to the script's design brief only. When they finish, I'll stop the run and resume it. The readers' results come back from cache, and the three designs, the judge and the synthesis all run with the query engine in view.

The designs won't design the engine or its DSL, but they'll be held to what the engine needs from the edges API:
- **Stable type names:** a DSL can write them, and they never change once shipped, as `ChannelID` doesn't.
- **Whole-file queries:** results cover every board, not just the one on screen.
- **Plain data:** results are ids, type, direction and the carrier shape (the arrow, or the note holding the mention).
- **Cheap filtering and traversal:** by type and direction.

[2026-09-28 14:03] NOTICE:
background task completed: Background command "Wait until all four readers finish" completed (exit code 0)

[2026-09-28 14:03] ASSISTANT:
All four readers finished. I'll stop the run and resume it with the updated brief.

[2026-09-28 14:03] WORKFLOW:
/Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/849bcff1-71a2-43e9-80f1-c67e0589829d/workflows/scripts/edges-api-design-wf_c4f55fb6-253.js

[2026-09-28 14:04] ASSISTANT:
The core and prior-art reports reach the same shape of answer:
- **Record:** the connecting thing holds both ends, as FigJam, Miro and Datomic's ref attributes do, and as our arrows and mention text already do.
- **Edges:** a derived, file-wide index, rebuilt from each commit's changes.
- **Types:** declared by plugins in a small tree, so a query for `connection` also finds `note-link`.

The prior-art report also shows what tldraw and Excalidraw paid for their stored bindings: repair code, migrations, and hooks that re-ran during undo. The three designs, the judge and the synthesis are still running.

[2026-09-28 14:22] NOTICE:
background task completed: Dynamic workflow "Map how shapes connect today, design an edges API three ways, judge, and synthesize" completed

[2026-09-28 14:23] ASSISTANT:
Your instinct is right: the edges API should be derived. What saves an edge is the shape that carries it, and the edges API is an index built from those shapes, never saved. Three independent designs and an adversarial judge all landed there, including the one told to argue for stored edges. The full design is in the file I sent; here's the core of it.

## System of record vs derived

- **The shape that carries the edge is the system of record.** An arrow's record holds its edge: its bound `start`/`end` plus `added.channel`. A mention's text holds its edge.
- **The edges API is a file-wide index over those shapes.** It lives in memory only and can be rebuilt from the file at any time.

Your arrow observation is the deciding reason. A stored edge beside the arrow would be a second record that has to agree with the first. tldraw and Excalidraw both show what that costs:
- **tldraw** moved arrow ends into binding records in 2.2. That led to repair code for duplicate bindings, hooks that re-ran during undo, and caches keyed on the wrong record, and the migration can't be reversed.
- **Excalidraw** stores the reverse side too. That led to load-time repairs and crashes on stale back-references, and its maintainers have proposed going one-way with an in-memory index.

Deriving also keeps what the code already does well:
- **Undo stays exact.** An undo arrives as an ordinary commit, and an index that never writes can't misfire during it.
- **Delete and copy keep their meanings.** Arrow bindings let go on delete; mentions are left dangling and get renamed on copy.
- **Sync stays open.** Only shape records ever cross between clients.

## What an edge is

```swift
struct Edge {
    let type: EdgeTypeID    // most specific: "note-link", "connection", "mention"
    let source: ShapeID?    // nil only for an arrow's free end
    let target: ShapeID?
    let carrier: ShapeID    // the shape whose record holds it: the arrow, or the mentioner
    let slot: String        // which property of the carrier ("text", "checklist"); "" for an arrow
    let count: Int          // a note mentioning B twice: 2
}
```

- **An arrow edge has an identity: the arrow itself.** Two arrows A→B are two edges.
- **A mention has no identity of its own.** It's keyed by (mentioner, property, target) with a count, because text positions move with every keystroke.
- **Direction:** an arrow runs from its start to its end; a mention runs from the mentioner to the shape it mentions.

## Edge types

This covers your follow-up about channels.
- **Type ids are stable strings,** like `ChannelID`: the DSL writes them, they never change once shipped, and the id audit polices them.
- **The plugin that owns the meaning declares the type.** Types form a single-parent tree; each edge reports its most specific type, and a query can match a family.
- **Channels are edge types, under the same string.** `registrar.channel(NoteLink.self)` would also declare the edge type `note-link` under `connection`, in the same call. So a channel can't exist without its edge type.

```
connection        Ports: an arrow with no channel is exactly this
├─ note-link      StickyNotes
├─ task-link      TaskCards
└─ schema-link    Schemas
mention           Mentions
```

- **The carrier is not the type.** "Arrow" is how an edge is stored; `note-link` is what it means. Merging those two is tldraw's `binding.type` mistake.
- **Queries match either way:** `.within("connection")` is every arrow, and `.only("connection")` is plain arrows alone.
- **An unknown channel keeps its string.** An arrow on a channel no installed plugin declares reports that string as its type, marked undeclared, rather than being folded into `connection`.

## Where each connection's truth lives

| Connection | What holds it (saved) | Edge |
|---|---|---|
| Arrow, with or without a channel | The arrow's terminals, plus `added.channel` | One edge; the arrow is its carrier |
| Arrow with one free end | The arrow's record | A loose edge; left out of neighbor queries unless asked for |
| Mention, in text or nested in a value | The mentioner's text | One per (mentioner, property, target) |
| Subboard containing shapes | The file's board tree | **Not an edge**; the file already answers it in O(1) |
| Future "blocked by" | A property holding shape names, on the blocked shape | One per name, typed `blocked-by` |
| A note sitting inside a frame | Nothing; it's geometry | Not an edge; the query engine computes it |
| A relation neither end can hold (symmetric, or with facts of its own) | **Nothing today** | The one case that would need something new; decide when it's real |

## The API

A new horizontal, **Edges**, would hold the type points and an `EdgeIndex` service (`editor.edges`). Ports and Mentions would build on it and contribute sources. Each source is a pure function of one record: Ports for connector kinds, Mentions over the kinds that hold names.

- `editor.edges.neighbors(of: x)` returns `["mention": [a, b, c], "not […2394 more chars]

[2026-09-28 14:26] USER:
<!-- reply -->
> What an edge is

what's the difference between source and carrier?

[2026-09-28 14:26] ASSISTANT:
The source is where the edge starts in the graph. The carrier is the shape whose record holds the edge, so it's where the edge is saved.

For a mention they're the same shape. For an arrow they're different.

| | source | target | carrier |
|---|---|---|---|
| Note N mentions task T | N | T | N (its text holds the token) |
| Arrow R from A to B | A | B | R (its terminals hold both ends) |
| Future "blocked by": task T is blocked by U, written on T | T | U | T |
| Same relation written on U instead ("U blocks T") | U | T | U |

**The arrow case is why both fields exist.** R isn't an endpoint of its own edge; it is the edge. Without a carrier field you'd have to model it as A→R→B, which is tldraw's shape: two bindings from the arrow, and `from`/`to` that don't mean start/end.

**Direction and storage are separate choices.** The last two rows show a relation's direction is its meaning, while its carrier is whichever shape stores it.

The two fields serve different questions:
- **Source and target are for graph questions:** what's connected to X, and which way.
- **The carrier is for lifecycle questions:**
  - which record to re-read when something changes;
  - what undo, copy, delete and sync move;
  - which board the edge is on;
  - "what does this arrow connect", which is `edges(carriedBy: R)`.

**Deleting the carrier deletes the edge.** Deleting an endpoint doesn't:
- Delete R and the edge is gone.
- Delete A and R lets go of it, leaving a loose edge.
- Delete T and N's mention stays as a missing edge.

For mentions the carrier field is redundant, since it equals the source. It's kept on every edge anyway, so the query engine never has to ask which kind of edge it's looking at.

An arrow can also be the carrier of one edge and an endpoint of others, for example when a note mentions the arrow.

[2026-09-28 14:27] USER:
in simple terms explain the system of record vs derived

[2026-09-28 14:28] ASSISTANT:
The system of record is what gets saved in the file: shapes, nothing else. The edges are worked out from those shapes whenever the app needs them, and never saved.

Two examples:
- **An arrow** is saved as a shape that says "I start on A and end on B, on channel note-link." That record is the connection. Nothing else says A connects to B.
- **A mention** is saved as text inside a note: "…ask @[Budget](shape:1234)…". That text is the connection. Nothing else says the note mentions Budget.

The edges index reads those saved shapes and builds a lookup table: "A: connected to B by note-link; mentioned by N". The table lives in memory. When a shape changes, only that shape's rows are redone. Close the file and the table is gone; open it and it's rebuilt from the shapes.

Why not save the edges too? Because then the same fact would be written in two places, the arrow and an edge record, and they could disagree. The arrow might say it ends on B while an edge record still says C. Every delete, undo, copy and paste would have to update both, and every bug would leave them out of step. With one place to write, they can't drift.

A comparison: a book's text is the system of record, and its index at the back is derived. You never edit the index by hand; you regenerate it from the text. Delete a page and its index entries disappear the next time you regenerate. The edges API is the canvas's index.

[2026-09-28 14:34] USER:
what module is this code in? how does it relate to the module system? in my mind it would sort of make sense as a low level module that arrow and mention depend on and register the edge behavior with

[2026-09-28 14:34] ASSISTANT:
That's essentially the design: a new module, **Edges**, a horizontal that depends on `Canvas` alone and sits at the bottom of the horizontal stack, the way `Keyboard` does. One difference from your picture: **Ports registers the arrow edges, not Arrows.**

```
Canvas (foundation)
└─ Edges            horizontal, on Canvas; new
   ├─ Ports         + Edges: declares `connection`, a type per channel, and the connector's edges
   │   └─ ArrowPorts   bridge; unchanged (makes arrows the connector)
   └─ Mentions      + Edges: declares `mention`, and edges over every kind that holds names

Arrows              unchanged: knows no channel, so it knows no edge type
StickyNotes, TaskCards, Schemas   unchanged: their registrar.channel(…) now declares an edge type too
```

What Edges owns:
- `EdgeTypeID`;
- the `EdgeTypes` point (declared types) and the `EdgeSources` point (per-kind "here's what this record carries");
- the `Edge` value;
- the `EdgeIndex` service (`editor.edges`).

In `Package.swift` that's one line:

```swift
.target(name: "Edges", dependencies: ["Canvas"]),   // layer: horizontal
```

`Ports` and `Mentions` would each add `"Edges"` to their dependencies. `EdgeTypeID` would join the audited id types in `build.sh`'s `ID_DECL`, so no module can write another's type string without depending on it. Any plugin list with Ports or Mentions would need `EdgesPlugin()` before them, as anything with a key needs `KeyboardPlugin()`.

**Why Ports and not Arrows.** An arrow's edge type is its channel, and Arrows deliberately knows nothing about channels. ArrowPorts is the only code that knows both. If Arrows registered its own edges, it could only emit `connection`, and Ports would need a second mechanism to refine that to `note-link`: two sources for one arrow, and a precedence rule between them. Ports already owns the connection concept: `connects(K.self, …)` names whichever kind draws connections, and `connectionEnds` reads its ends. So Ports registers the edges for whatever kind is the connector. That also matches where you're headed, since ports are meant to replace the arrow tool: the edge belongs to "a connection", not to "an arrow".

The cost: a plugin list with Arrows but no Ports has arrows that carry no edges. The shipped app always has both. If you'd rather arrows carry edges on their own, the alternative is for ArrowPorts to register them instead of Ports. The catch is that each channel would then declare its edge type in a second place, not in the same `registrar.channel` call.

**Why not in `Canvas` itself.** The core already has the low-level half, and it stays there:
- `ShapeReferencing` (bindings) and `ShapeNaming` (names) are the mechanics that keep references valid when a shape is deleted or copied. The core has to own that, because `Transaction.delete` and copy live there.
- Edges adds meaning on top: typed edges and a queryable index.

Putting that meaning in the core would break its rule of knowing no particular concern. It would also make every editor pay for a file-wide index as it opens, even with no plugin that carries edges.

[2026-09-28 14:37] USER:
ok i'm feeling good about this design

[2026-09-28 14:37] WRITE /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/edges-api-design.md:
---
name: edges-api-design
description: "Edges API (2026-09-28, design only, user approved the direction): typed, file-wide, derived index; the carrier shape is the system of record; a new Edges horizontal that Ports and Mentions build on"
metadata:
  type: project
---

On 2026-09-28 the user asked for an edges API ("what are all the shapes connected to this shape, and how"), and said they felt good about this design. Nothing is built yet.

- **System of record = the carrier shape; edges are derived.** An arrow's record (terminals + `added.channel`) is its edge; a mention's text is its edge; a future relation ("blocked by") is a property holding shape names on the shape it's about. The index lives in memory, is rebuilt from `CanvasFile`, and is never saved. The user's own argument: an arrow's presence *is* the edge. tldraw's binding records and Excalidraw's two-way storage were rejected.
- **Edge** = type, source, target (nil for an arrow's free end), carrier (the shape holding it: the arrow, or the mentioner), slot (property), count. An arrow edge's identity is the arrow; a mention's is (mentioner, property, target).
- **Types.** `EdgeTypeID` is a stable string, audited like `ChannelID`, in a single-parent tree; each edge reports its most specific type; filters are `.within` (the family) and `.only` (exact). The user insisted channels are distinct edge types: `registrar.channel(C.self)` declares the type with the same string, under `connection`. `mention` is a root. The carr […1469 more chars]

[2026-09-28 14:37] ASSISTANT:
Good. I saved the direction to memory, because the full design doc sits in this session's scratchpad, which may not survive. The memory records:
- edges are derived, and the carrier shape is the system of record;
- the type tree, with channels as edge types;
- `Edges` as a horizontal that Ports and Mentions build on;
- the query engine as its eventual consumer;
- the six open decisions, still unanswered.

Nothing is built yet. When you want to go further, I can take the open decisions one at a time, then build it in a worktree.

[2026-09-28 14:50] USER:
yes go

[2026-09-28 14:50] GIT:
git merge-base main mentions-phase2 | cut -c1-8 && git log --oneline main..mentions-phase2 | head -20 && git -C .claude/worktrees/mentions-phase2 status --short | head

[2026-09-28 14:50] ASK:
Q: Should a subboard's containment of the shapes on its board be an edge type in the index?
   options: No, not an edge (Recommended): Every shape has exactly one containing board, so it would appear in every neighbor answer, and a subboard of 10,000 shapes would have 10,000 edges. The file's board tree already answers it in O(1); the query engine can offer it as a relation of its own.; Yes, a `contains` edge: Subboard → each shape on its board, declared by Edges or Boards. One uniform graph for the engine, at the cost of huge degrees on subboards and noise in 'what's connected to X'.
Q: Is an arrow with one free end (bound at one end, loose at the other) an edge?
   options: Yes, a loose edge (Recommended): Reported with a nil end, left out of neighbor answers unless a query asks for loose edges. Deleting a shape in the app leaves these today, and 'what did X connect to' can still find them.; No, only both-ends-bound: An arrow counts as an edge only while both ends are on shapes, as `connectionEnds` reads it today. Simpler; half-bound arrows are invisible to the graph.
Q: mentions-phase2 (backlinks, still in progress) changes MentionState's index. How should Edges land relative to it?
   options: Edges first, fold Mentions' index in (Recommended): Build Edges on main now and replace MentionState's forward/backward with the index in the same change. phase2 then merges onto it, and its backlinks read incoming mention edges, becoming file-wide (flipping its pinned per-board test). Most conflict for phase2, but no duplicate index.; Edges first, leave MentionState alone: Build Edges on main with Mentions contributing its edge source, but keep MentionState's own index for now. No conflict with phase2; two indexes of mentions until a follow-up folds them together after phase2 lands.; Wait for phase2 to land: Build Edges on top of main once phase2 is in, folding its backlinks in directly. No rework, but Edges waits.
Q: What's the permanent type word for the family of arrow/port connections (the root that `note-link` and `schema-link` sit under, and what a plain arrow reports)?
   options: connection (Recommended): Names the meaning, not the carrier; the codebase already calls what a connector draws a connection, and ports are meant to replace the arrow tool.; arrow: Names what's drawn today. Reads naturally now, but names the carrier, and would be wrong if connections are later drawn by something other than arrows.

[2026-09-28 14:51] USER (sent mid-turn):
This is a really great question. And the answer is absolutely not. However, it is something. It's a parent-child relationship, which is not an edge, but it is something that we have yet to describe. And I expect that there will be a sibling API that answers the exact same question. Is A inside of B? In fact, this question makes me wonder if the module or plugin we're writing should have a different name, a name that could perhaps contain both of these concepts.

[2026-09-28 14:51] ANSWER:
The user answered: "Should a subboard's containment of the shapes on its board be an edge type in the index?"="[User dismissed — do not proceed, wait for next instruction]", "Is an arrow with one free end (bound at one end, loose at the other) an edge?"="[User dismissed — do not proceed, wait for next instruction]", "mentions-phase2 (backlinks, still in progress) changes MentionState's index. How should Edges land relative to it?"="[User dismissed — do not proceed, wait for next instruction]", "What's the permanent type word for the family of arrow/port connections (the root that `note-link` and `schema-link` sit under, and what a plain arrow reports)?"="[User dismissed — do not proceed, wait for next instruction]". Read the answers carefully — they may request clarification, changes, or that you not proceed — and follow what they actually say.

[2026-09-28 14:52] ASSISTANT:
Agreed, containment isn't an edge. They differ in shape:
- **An edge** is many-to-many, typed, and directed, and it's carried by a shape (the arrow, or the note holding the mention).
- **Containment** is a tree: every shape has exactly one parent. The questions are "what's A's parent?", "what's inside B?" and "is A inside B, at any depth?"

So they're siblings: two relations between shapes, each with its own API.

**On the name:** I'd call the module **`Relations`**. Edges and containment are both relations between shapes, and the word doesn't lean toward either one. The module would hold two sibling services:
- `editor.edges`: the graph described so far, with `neighbors(of:)`, `edges(of:direction:types:)` and the type tree.
- `editor.containment`: the tree, with `parent(of:)`, `children(of:)`, `ancestors(of:)` and `isInside(a, b)`.

It reads well for the query engine too: its DSL asks about relations, and each answer says which one. The other names I considered:
- `Structure`: covers both, but vague, and easy to read as layout.
- `Topology`: exact (how things connect and nest), but jargon.
- `Graph`: people hear only edges, and a tree reads oddly under it.

**Containment's system of record already exists.** A shape's parent is the owner of the board it's stored on: `CanvasFile.children`, keyed by owner. The core keeps the lookup current (`file.board(containing:)`, `owner(of:)`). So containment starts as a uniform read over the core's board tree, with nothing new stored, which is the same rule as edges. The module would also leave room for future containers (frames, groups) to declare parent-child. They'd share one tree, with each parent link typed (board, frame) the way edges are.

**One thing "is A inside B?" needs pinned down: structural or spatial.** Structural means A is recorded as being on B's board, or in B's frame; that's a fact in the file, and it's what I've described. Spatial means A happens to sit within B's bounds, which is geometry and changes on every drag. I'd treat spatial as the query engine's to compute, not a relation. If you meant spatial, the design is different.

The other three questions are still open whenever you're ready: arrows with a free end, how this lands relative to `mentions-phase2`, and `connection` vs `arrow` as the family word.

[2026-09-28 15:17] USER:
topology?

[2026-09-28 15:17] ASSISTANT:
I dismissed it too quickly. Topology may be the better name: in the network sense, it's how things are connected and nested regardless of where they sit.

**The case for it.** A board's topology is what doesn't change when you drag things around. That's exactly the line this design draws:
- Moving a shape changes its geometry but not its edges or its parent, which is why the index costs nothing on a drag.
- Spatial "inside" (A happens to sit within B's bounds) is geometry, not topology, so the name keeps it out.

It also covers both halves naturally:
- edges are the network's links;
- containment is its nesting.

Relations only says "shapes relate somehow". Topology says the relations are structural.

**The case against it.**
- **In GIS and computational geometry, "topological relations" are the spatial predicates:** contains, within, touches, overlaps. Someone from that world, or a DSL user, might expect "is A inside B" to mean geometric containment. That's the one meaning we're excluding.
- **It's more jargon than Relations** for someone reading the plugin guide.

How it reads:

```swift
editor.topology.neighbors(of: a)        // ["mention": […], "note-link": […]]
editor.topology.parent(of: a)
editor.topology.isInside(a, b)
```

I'd take Topology over Relations if the plugin guide defines it in one sentence: "what connects and contains what, whatever is where; spatial relations aren't part of it." That definition does useful work, because it's the rule a future relation has to pass to belong here. Relations is the safer, plainer choice if you'd rather not carry the GIS ambiguity.

[2026-09-28 15:25] USER:
ok lets go with topology

[2026-09-28 15:25] WRITE /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/edges-api-design.md:
---
name: edges-api-design
description: "Topology module (2026-09-28, design only, user approved the direction): edges as a typed, file-wide, derived index whose system of record is the carrier shape, plus a sibling containment API; Ports and Mentions build on it"
metadata:
  node_type: memory
  type: project
  originSessionId: 849bcff1-71a2-43e9-80f1-c67e0589829d
  modified: 2026-09-28T14:37:40.827Z
---

On 2026-09-28 the user asked for an edges API ("what are all the shapes connected to this shape, and how"), and said they felt good about this design. Nothing is built yet.

- **Name: `Topology`** (the user chose it over `Relations`). It is a horizontal on `["Canvas"]` holding two sibling APIs:
  - **edges**: the graph.
  - **containment**: the tree, parent-child ("is A inside B?").
  - The plugin guide defines it in one sentence: *what connects and contains what, whatever is where; spatial relations aren't part of it.* That sentence is the test a future relation must pass.
  - Watch the GIS sense, where "topological relations" means spatial predicates.
- **Containment is NOT an edge.** The user: "absolutely not… it's a parent-child relationship… a sibling API that answers… is A inside of B?"
  - Its system of record already exists: the board a shape is stored on (`CanvasFile.children` keyed by owner; the core's `board(containing:)`/`owner(of:)`). It starts as a uniform read over that, with room for future containers (frames, groups) in one single-parent tree whose links are […2904 more chars]

[2026-09-28 15:26] ASSISTANT:
It's `Topology`, and I've recorded that in memory. Four decisions are left before I build:

[2026-09-28 15:26] ASK:
Q: Does containment ship in the first build, or edges only?
   options: Both, containment thin (Recommended): Edges in full, plus containment as a uniform read over the board tree that exists today (parent, children, ancestors, isInside), with its extension point for future containers left for when frames or groups arrive.; Edges only: Build the edges half now and name the module Topology; containment comes as its own change later.
Q: Is an arrow with one free end (bound at one end, loose at the other) an edge?
   options: Yes, a loose edge (Recommended): Reported with a nil end, left out of neighbor answers unless a query asks for loose edges. Deleting a shape in the app leaves these today, and 'what did X connect to' can still find them.; No, only both-ends-bound: An arrow counts as an edge only while both ends are on shapes, as connectionEnds reads it today. Simpler; half-bound arrows are invisible to the graph.
Q: mentions-phase2 (backlinks, still in progress in another worktree) changes MentionState's index. How should Topology land relative to it?
   options: First, fold Mentions' index in (Recommended): Build on main now and replace MentionState's forward/backward with the edges index in the same change. phase2 then merges onto it, and its backlinks read incoming mention edges, becoming file-wide (flipping its pinned per-board test). More conflict for phase2, no duplicate index.; First, leave MentionState alone: Build on main with Mentions contributing its edge source, but keep MentionState's own index for now. No conflict with phase2; two indexes of mentions until a follow-up folds them together.; Wait for phase2 to land: Build on main once phase2 is in, folding its backlinks in directly. No rework, but Topology waits.
Q: What's the permanent type word for the family of arrow/port connections (the root that note-link and schema-link sit under, and what a plain arrow reports)?
   options: connection (Recommended): Names the meaning, not the carrier; the codebase already calls what a connector draws a connection, and ports are meant to replace the arrow tool.; arrow: Names what's drawn today. Reads naturally now, but names the carrier, and would be wrong if connections are later drawn by something other than arrows.

[2026-09-28 15:27] ANSWER:
Your questions have been answered: "Does containment ship in the first build, or edges only?"="Both, containment thin (Recommended)", "Is an arrow with one free end (bound at one end, loose at the other) an edge?"="No, only both-ends-bound", "mentions-phase2 (backlinks, still in progress in another worktree) changes MentionState's index. How should Topology land relative to it?"="First, fold Mentions' index in (Recommended)", "What's the permanent type word for the family of arrow/port connections (the root that note-link and schema-link sit under, and what a plain arrow reports)?"="arrow". You can now continue with these answers in mind.

[2026-09-28 15:27] EDIT /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/edges-api-design.md:
- **The user's answers (2026-09-28):**
  - The first build ships both halves: edges in full, and containment as a thin read over the board tree (parent, children, ancestors, isInside). The extension point for future containers waits for frames or groups.
  - An arrow with a free end is **not** an edge. Only both-ends-bound connections count, as `connectionEnds` reads them. There's no loose edge and no `includingLoose`, and `ConnectorContribution.ends` is unchanged.
  - Topology lands first, on main, and folds Mentions' `forward`/`backward` into the edges index in the same change. `mentions-phase2` then merges onto it, and its backlinks become file-wide.
  - The family word is **`arrow`**, against my recommendation of `connection`. The plain arrow's type is `arrow`; `note-link` and `schema-link` sit under it.
- **Still open (my defaults):**
  - a relation no one draws or writes lives in a naming property first;
  - `canvas draw` matches edges by (from, to, type), as a follow-up, not in this build.

[2026-09-28 15:28] ASSISTANT:
I'm working in the `topology` worktree now. Before writing the build brief, I'm reading the code the change touches: Ports, MentionState, and the core's service and extension-point shapes.

[2026-09-28 15:30] ASSISTANT:
I have what I need. I'll write the build brief into the scratchpad so every agent works from the same spec.

[2026-09-28 15:33] WORKFLOW:
Build the Topology horizontal (edges + containment), integrate Ports/ArrowPorts/Mentions, document, review, verify, fix

[2026-09-28 15:33] ASSISTANT:
I've started building Topology in the `topology` worktree, working from your answers:

- **Scope:** edges and containment ship together. Containment is a thin read over the board tree (`parent`, `children`, `ancestors`, `isInside`).
- **Loose ends:** only arrows bound at both ends are edges.
- **Sequencing:** Topology lands before `mentions-phase2` and takes over Mentions' who-mentions-whom index, so `mentioners(of:)` becomes file-wide.
- **Family word:** `arrow`. A plain arrow reports `arrow`, and `note-link` and `schema-link` sit under it.

`arrow` is already the Arrows kind's id, and the build's id check tracks id strings regardless of their type. So `ArrowPorts` declares the `arrow` edge type, since it's the only module that knows both arrows and ports. Ports' `connects` takes the connector's edge type, and each `registrar.channel` declares its own type under it. Ports still never learns what an arrow is.

The run builds the core, then the integration, then the docs, then reviews from four angles, verifies the findings and fixes them. I'll report back when it finishes. Nothing goes to main until you've seen it and said so.

[2026-09-28 16:51] NOTICE:
background task completed: Dynamic workflow "Build the Topology horizontal (edges + containment), integrate Ports/ArrowPorts/Mentions, document, review, verify, fix" completed

[2026-09-28 16:52] GIT:
git status --short | head && git log --oneline -8 && echo --- && git log --oneline -5 main && git merge-base main topology | cut -c1-7 && git diff --stat main...topology | tail -3

[2026-09-28 16:53] WORKFLOW:
Make backlinks file-wide per the user, then re-review the rebased topology branch, verify, fix

[2026-09-28 16:53] ASSISTANT:
The code reads cleanly:
- **ArrowPorts** takes `arrow` from the Arrows kind's name, so the string stays with its one owner in the id audit.
- **Ports' `channel(_:)`** declares the matching edge type in the same call, under the connector's family.
- **Mentions' edge source** is about fifteen lines over the kinds that hold names.

I'll report when the follow-up finishes.

[2026-09-28 17:29] NOTICE:
background task completed: Dynamic workflow "Make backlinks file-wide per the user, then re-review the rebased topology branch, verify, fix" completed

[2026-09-28 17:30] EDIT /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/edges-api-design.md:
On 2026-09-28 the user asked for an edges API ("what are all the shapes connected to this shape, and how"), and said they felt good about this design.

**Status (2026-09-28):** built on branch/worktree `topology` (6 commits, rebased onto main eb514e1), reviewed twice, and green. It is NOT landed: it waits for the user's go-ahead, then gets squashed to one commit.
- Main's phase-2 backlinks landed mid-build. The fold was ported onto them, and backlinks were made file-wide per the user.
- It adds one core API, `editor.withoutObservingDocument {}`.
- `ArrowEdge.id` is taken from `Arrow.kind`, because the id audit gives a string one owner.

[2026-09-28 17:30] ASSISTANT:
Topology is built on the `topology` branch and reviewed twice. `./build.sh audit` and the full `./test.sh` pass on the final commit, which I ran myself. The app builds, and every benchmark is within budget. It isn't on main.

```swift
editor.topology?.neighbors(of: note)
// ["mention": [a, b], "note-link": [c], "arrow": [d]]
editor.topology?.edges(of: note, .incoming, types: .within("arrow"))  // every arrow; .only("arrow") is plain arrows alone
editor.topology?.isInside(note, subboard)                             // containment: parent, children, ancestors
```

**What it is.** A new `Topology` horizontal that depends only on `Canvas`.
- Its index covers the whole file, lives in memory, and is rebuilt from the shapes; nothing new is saved.
- Plugins say what a record carries through pure sources.
- Ports declares each channel's edge type under the connector's family, `arrow`. ArrowPorts owns `arrow`, and Mentions declares `mention`.
- Mentions' own who-mentions-whom index is gone; it reads Topology's.

**What changed while it was built.**
- **Main moved.** Phase 2's backlinks landed as eb514e1 mid-build. The branch is rebased onto it (its history rewritten) and the fold was ported onto the backlinks.
- **Backlinks are file-wide now, as you chose.** The first port had kept them limited to the board shown, so I had that changed. Mentioned In lists mentioners from other boards after this board's, and clicking one shows its board.
- **One new core API:** `editor.withoutObservingDocument { … }`, so the backlinks panel can read the file without redrawing on every commit. It's generic, but it's a new surface on the core.

**Differences from the spec.**
- `ArrowEdge.id` is taken from the Arrows kind's name instead of being written as `"arrow"`, because the id audit lets a string have only one owning module.
- A foreign file's arrow whose channel string happens to name another edge type, like `mention`, is treated as a plain `arrow`, not as a mention.

**Watch this one.** Deleting a subboard over 10,001 shapes takes 14.9 ms against its 16 ms budget. About 3 ms of that is Topology hearing the cascade.

**Not in this build:**
- `canvas draw` still matches edges by (from, to), not by type.
- There's no agent command for reading edges; that's yours to design.
- MentionValidation still looks up mention targets on the board shown only.

The branch is six commits and about 3,100 lines added across 56 files. When you say go, I'll squash it to one commit, rebase onto whatever main is by then, run the tests again and fast-forward main.

[2026-09-28 17:31] USER:
has this been reviewed yet?

[2026-09-28 17:31] ASSISTANT:
Yes, twice. The last fix commit hasn't been.

**First round**, on the branch as first built:
- **Four independent reviewers**, one per area: the index across every kind of commit, what folding Mentions' index changed, fit with the spec and CLAUDE.md's rules, and tests and docs.
- **Four findings, each checked by a second agent and fixed in 73df13f:**
  - the branch no longer merged with main;
  - a foreign channel string could make an arrow count as a mention;
  - one test couldn't fail;
  - one guard was never exercised.

**Second round**, after the rebase and file-wide backlinks:
- **Three reviewers:** Mentions after the fold and the backlinks change, what the branch does to main's tests and docs, and the core and Ports after the rebase.
- **Four findings, verified and fixed in ae8ebfb:**
  - a copy of the file that made some commits cost the whole file;
  - `isMentioned` building an array on every drag event;
  - arrow edges needlessly redrawing backlinks;
  - two stale doc lines.

**Gaps:**
- **ae8ebfb hasn't had an independent review.** That includes the new core API `editor.withoutObservingDocument`, `hasEdges(where:)` and `touched(types:)`. Tests and benchmarks pass on it.
- **Two of its fixes have no test that fails without them:** the file copy and the array allocation. Neither is observable from a test, so their tests only cover the new APIs' behavior.
- **Both rounds were agents I ran in this session,** not the `/code-review` skill.

Want me to review ae8ebfb?

[2026-09-28 17:32] USER:
lets merge and squash

[2026-09-28 17:33] ASSISTANT:
Main hasn't moved since the rebase (it's still at eb514e1), so squashing needs no second rebase. I'll squash the six commits into one, with a message that leads with why.

[2026-09-28 17:33] COMMIT MESSAGE FILE topology-commit.txt:
Add Topology: what connects and contains what, one typed index of the whole file, derived from the shapes

The user asked for an edges API: to ask what's connected to a shape and know that these three
are connected by mention and those three by arrow, with more kinds of connection to come, and
arrow channels meaningfully different kinds. A query engine that answers questions about a board
(a DSL in, data out) is planned on top of it, so what connects to what is central to the product.
Until now each concern answered it alone: Mentions kept its own who-mentions-whom index, for the
board shown only; arrows had no reverse index at all (a delete and `canvas draw` scan the board).

What's derived and what's the record. The user's own observation settled it: an arrow's presence
is the edge, and deleting it ends the edge. So the carrier shape is the system of record (an
arrow's bound ends and its channel, a note's text), and the edges are an index derived from the
records, kept in memory, rebuilt from the file, never saved. Stored edge records were designed
and rejected: tldraw moved arrow ends into binding records and has paid in repair code, hooks that
re-ran on undo and caches keyed on the wrong record; Excalidraw stores the reverse side and repairs
it on load. Here a second copy could only disagree, while a derived index gets exact undo (an
undo is an ordinary commit), delete and copy semantics (bindings let go, names dangle and are
renamed) and a future sync for free: only shape records ever cross.

Named Topology, not Relations or Graph (the user's choice): what connects and contains what,
whatever is where. Edges are a typed graph; containment is a sibling, a tree (which board a shape
is on), which the user was firm is not an edge. Spatial relations (a note within a rectangle's
bounds) are geometry, left to the query engine. The GIS sense of the word, where topological
relations are spatial predicates, is the one to watch.

The module (a horizontal on the core alone):
- `EdgeTypeID`, audited like `ChannelID`: a DSL writes these strings, so they never change once
  shipped. Types form a single-parent tree; an edge reports its most specific type; `.within`
  asks for a family, `.only` for a type alone. A type nobody declares (a channel from a newer app)
  is kept as written, a root.
- `EdgeSources`: what a record carries, a pure function of that one record and the registry, so a
  commit costs the records it changed, a move nothing, and undo is exact. The property rule
  (`edges(in: P.self, as: T.self)`) makes every name in an added property an edge: where a future
  relation nobody draws ("blocked by") would live, with no new record kind.
- `TopologyIndex` (`editor.topology`): `neighbors(of:)` grouped by type, `edges(of:_:types:)`,
  `edges(ofType:)`, `edges(carriedBy:)`, `hasEdges(where:)`, `end(_:)` (live, missing,
  unavailable, worked out when read), per-shape revisions and `touched(types:)`; and containment:
  `parent`, `children`, `ancestors`, `isInside`, over the board tree. File-wide over the boards
  the editor can show. Every commit path (a write to a hidden board, a cascade, a paste of boards,
  undo of Delete Hidden Shapes, a file put in place) runs through one loop over removed, elsewhere,
  and changed-but-not-moved ids; a board switch reads nothing; `catchUp` lets a service that hears
  a commit first read it current.

An edge is type, source, target, carrier (the shape holding it: the arrow; the mentioner), slot
(the property) and count. An arrow edge's identity is the arrow, so two arrows A→B are two edges;
a mention's is its mentioner, property and target, with a count, since text offsets move.

The user's decisions, asked one at a time:
- An arrow with a free end is not an edge; only connections bound at both ends count.
- The family word is `arrow` (I recommended `connection`, since ports are meant to replace the
  arrow tool; the user chose `arrow`). ArrowPorts declares it, its id taken from `Arrow.kind`: the
  id audit gives a string one owner, and writing "arrow" again there would have needed Arrows to
  depend on ArrowPorts.
- Each channel is its own edge type: `registrar.channel(C.self)` declares the type of the same
  name under the connector's family, resolved from the registry, so Ports still never learns what
  an arrow is. `connects(_:edgeType:…)` names the family and registers the connector's edges. A
  foreign channel string that names another declared type (`mention`) is the family's, never that
  type.
- Topology lands first and takes over Mentions' index. Mentions declares `mention` and a source
  over the naming kinds; MentionState drops forward/backward and the stash that kept them per
  board, and reads Topology: `mentioners(of:)` and the backlinks (Mentioned In, Show What
  Mentions, `isMentioned`), which landed in eb514e1 per board only because the index was, are now
  the whole file's, as the user chose: another board's mentioners are listed after this board's,
  and clicking one shows its board. To read other boards without observing the file on every
  commit, the core lends `editor.withoutObservingDocument { … }`.

Every plugin list with Ports or Mentions needs `TopologyPlugin()`; the shipped list has it right
after Selection, so its index hears each commit before the services that read it.

Costs, release bench at 10,000 shapes: Topology's index and Mentions' catalog at open 33 ms
(budget 50); neighbors of a shape with 100 edges 0.022 ms (1); a drag's input unchanged; entering
a subboard cold 161 ms (250); deleting a subboard over 10,001 shapes 14.9 ms (16: about 3 ms of it
is Topology hearing the cascade), undone 34 ms and redone 19 ms (100).

Not built: `canvas draw` still matches edges by their ends, not their type; no command lets
agents read edges (how agents read a board is the user's to design); MentionValidation still looks
targets up on the board shown; no extension point for containers besides boards (frames, groups).

Built from a de […361 more chars]

===== [2026-09-28 17:33] commit written: Add Topology: what connects and contains what, one typed index of the whole file, derived from the shapes =====

[2026-09-28 17:33] GIT:
git reset --soft main

[2026-09-28 17:33] GIT:
git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/849bcff1-71a2-43e9-80f1-c67e0589829d/scratchpad/topology-commit.txt

[2026-09-28 17:33] ASSISTANT:
The squash's tree is identical to the commit I ran the full tests on. Next I'll leave the worktree and fast-forward main.

[2026-09-28 17:33] GIT:
git merge --ff-only topology && git log -2 --oneline

[2026-09-28 17:33] ASSISTANT:
Landed. Now cleaning up the worktree and branch this session made.

[2026-09-28 17:34] EDIT /Users/zekenie/.claude/projects/-Users-zekenie-code-native-canvas/memory/edges-api-design.md:
**Status:** landed on main as one squashed commit, f31bad7 (2026-09-28, with the user's go-ahead). It was reviewed twice first. The last fix round's additions (`withoutObservingDocument`, `hasEdges(where:)`, `touched(types:)`) never had an independent review; the user landed it knowing that. The code, docs/plugin-system.md ("Topology") and CLAUDE.md are now the record, so trim this memory to what they don't say.

[2026-09-28 17:34] ASSISTANT:
Topology is on main as one squashed commit, f31bad7. Main hadn't moved since the rebase, so it went in as a fast-forward, and its tree is identical to the commit I ran the audit and full `./test.sh` on. The `topology` worktree and branch are removed.

Other sessions' worktrees are still open: `house-rules`, `schema-completion` and two detached ones. Anything based on main before today will conflict in `MentionState.swift`, and needs `TopologyPlugin()` in any plugin list that has Ports or Mentions.

The last fix round never had an independent review: `editor.withoutObservingDocument`, `hasEdges(where:)` and `touched(types:)`. The commit message says so.
