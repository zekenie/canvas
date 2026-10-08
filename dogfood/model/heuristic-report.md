# Arrows or pills between files on one board

(Saved by the main session from the agent's final message; the harness kept the agent from writing it.)

**Result:** 353 of the 762 same-board uses stay arrows. The current heuristic keeps 254, and only 122 of the new 353 are arrows today. 18 boards get hubs (47 files in all). The other 31 boards keep every arrow except the ones another note already relays (defined below). The rules read only the index, never positions. They run over all 54 boards in 0.01 s.

`heuristic.py` exposes `references(board)`, and `references_of(nodes, uses, weight, title=str)` runs the same rules on any graph. `references(board)` calls it with the board's files, their uses and the number of symbols each use names.

## The rules

1. **Hubs: a board's most-used files, measured against that board.**
   - **h** is the board's h-index of users: the largest h such that h of its files are each used by at least h of its files. A pair used both ways counts for both ends.
   - **Candidates** are files used by more than h files. They become hubs most-used first. On a tie, the file with more one-way users goes first.
   - **What a hub does:** every use of it becomes a pill, and so does every pair that includes it (one pill on each side). The hub's own one-way uses of other files stay arrows, so a hub still points at what it owns (MentionState → MentionCatalog, MentionMatching, …).
   - **No hubs below h = 3.** Three files each used by the same three others form K3,3, the smallest set of arrows into popular files that can't be drawn without a crossing. With h ≤ 2, at most two files have three or more users, and two such stars always draw without a crossing (K2,n is planar).
   - **Guard:** a candidate is skipped if making it a hub would leave a file tied to it both ways with no arrow at all. That happens with a plugin and a piece it registers: the plugin uses the piece's type, and the piece uses the plugin's kind. Frames.swift, Subboards.swift, Publishing.swift and References.swift keep their arrows this way.
2. **Relays: an arrow that a third note already carries becomes a pill.**
   - A → C goes when A → B and B → C are arrows, B uses C at least as much as A does, and A uses B at least as much too. The last condition is waived when A and B use each other: two files tied both ways act as one, so if both use C, only the one that uses it more points at C.
   - "Much" means the number of symbols named (`names` in the index).
   - Arrows are checked weakest first, each against the arrows still left. A pair goes only when both of its directions are relayed.
   - A relay that has been counted on is never removed later, so no file loses its last arrow this way.

## Why

- **What a hub is.** Popularity is measured against the board's own files, not a constant. h follows each board's size and density and is at most the square root of its uses (Schemas 6, Mentions 5, Canvas/Model 4, Titles 2). "More users than h" picks the head of a skewed distribution and nothing out of a flat one: Find (4,3,3,3,3,3) gets one hub, SlashCommands (3,3,3,2,…) gets none, and no board ever has more than h hubs.
- **What the rule picks.** The hubs turn out to be models, state and style constants: Identity, ShapeRecord, MentionText, MentionState, SelectionState, ArrowModel, JSONReader, and FrameStyle, SelectionStyle, ReferenceStyle and the other style enums. A pill names these as well as an arrow does, and no column layout can put one next to all of its users.
- **What the arrows show.** Each board's flow from its entry point (plugin, tool, transaction) down to the pieces, plus its clusters of files tied both ways.
  - A relay removes an arrow that only skips over a note already carrying the use. In a column, that arrow would be an arc over its neighbour.
  - It does so only when the relay is at least as strong, so a weak incidental use can't make a strong direct one look redundant.
  - Full transitive reduction was tried first. On Queries, a 1-symbol use (QueryVocabulary → Queries) closes a cycle through the whole board, and full reduction then dropped Resolution → QueryPlan, the board's strongest use at 88 symbols. Limiting relays to two strength-checked steps avoids this, so cycles need no other handling.
- **The only fixed number is 3,** from K3,3. h, the bar for candidates, the order of hubs, the guard and the relay strengths all come from the board's own graph.
- **Pairs used both ways** count for both ends' popularity. A pair is one <-> arrow or a pill on each side, never split. A pair with a hub in it is a pair of pills. In relays, a pair acts as one file.
- **Frames** are not an input. They are hand-made topic groups, and the rules read only the code. 139 of the 282 arrows on framed boards stay inside one top-level frame. The rest are the flow between topics (Mentions.swift → MentionEdges, MentionFaces, MentionMenus).
- **Files left with only pills.** There are three, and each uses nothing but hubs: MentionRows, SchemaSkeleton, and Selection/Popovers. Popovers is tied both ways to SelectionState, which became a hub while Popovers still had its arrow to Selection.swift; Selection.swift becoming a hub later took that last arrow. Each file's pills list exactly what it uses. Drawing one hub use back as an arrow would break "a hub is a pill everywhere".
- **Not used: a cap per note.** The busiest notes left are References.swift (9 arrows), ArrowDefinition (8), and Evaluation and Transaction (7 each). They are integrators, and their fan of arrows is the main flow. A cap would cut it by rank, which is what CAP = 6 did.
- **Safety net: keep it, but demote it.**
  - After layout, bend any arrow that crosses a shape (the existing `clear_bend`, up to 0.14 of the arrow's length).
  - If no small bend clears it, list it in the `plan` output for the layout to fix. Don't turn it into a pill silently, and drop CAP.
  - On the old grid, 233 of these 353 arrows fail the bend test, including all three on QueryTranslation. That comes from the grid, which never puts linked notes together. A pill fallback would bring back the layout-dependence these rules remove.
  - If a hard no-crossing guarantee is needed, fall back to a pill only as a last resort, and count those pills per board.

## Per board

"Uses" counts a pair used both ways once. "Now" is what the layout's `decide_board` chose before these rules. Each hub is followed by its number of users on the board.

| Board | Files | Uses | h | Hubs (users) | After hubs | Arrows | Now |
|---|---:|---:|---:|---|---:|---:|---:|
| DrawScript | 9 | 15 | 3 | DrawScript 4, DrawScript/Syntax 4 | 7 | **7** | 11 |
| QueryLanguage | 8 | 19 | 3 | QueryLanguage/Syntax 5 | 14 | **9** | 12 |
| TextEditing | 8 | 8 | 2 | — | 8 | **6** | 6 |
| FuzzyMatching | 4 | 1 | 1 | — | 1 | **1** | 1 |
| Canvas/Model | 15 | 54 | 4 | Identity 13, ShapeRecord 10, CanvasDocument 7, BoardID 6 | 18 | **15** | 14 |
| Canvas/Editor | 15 | 30 | 3 | CanvasEditor 9, Scheduler 6, Input 4 | 11 | **11** | 8 |
| Canvas/Shapes | 3 | 3 | 1 | — | 3 | **3** | 0 |
| Canvas/Plugins | 5 | 10 | 3 | ExtensionPoint 4, Registry 4 | 3 | **2** | 2 |
| Canvas/Tools | 4 | 3 | 1 | — | 3 | **3** | 2 |
| Canvas/Rendering | 8 | 7 | 1 | — | 7 | **6** | 4 |
| Canvas/Schema | 6 | 6 | 2 | — | 6 | **6** | 5 |
| Canvas/Persistence | 4 | 5 | 1 | — | 5 | **5** | 3 |
| CanvasRPC | 8 | 14 | 2 | — | 14 | **10** | 8 |
| CanvasUI | 12 | 13 | 2 | — | 13 | **13** | 5 |
| Keyboard | 2 | 1 | 1 | — | 1 | **1** | 1 |
| Selection | 15 | 38 | 4 | SelectionState 10, Selection 9, SelectionStyle 7 | 13 | **12** | 6 |
| DetailPanel | 9 | 14 | 2 | — | 14 | **11** | 6 |
| ContextMenus | 3 | 3 | 2 | — | 3 | **2** | 0 |
| SlashCommands | 7 | 12 | 3 | — | 12 | **9** | 5 |
| TableOfContents | 7 | 12 | 2 | — | 12 | **10** | 6 |
| Adornments | 5 | 8 | 2 | — | 8 | **6** | 4 |
| LanguageModels | 7 | 7 | 2 | — | 7 | **7** | 5 |
| ProseMaps | 6 | 9 | 2 | — | 9 | **8** | 4 |
| Topology | 9 | 23 | 3 | Topology 8, EdgeTypes 5, Forwarding 5 | 7 | **7** | 7 |
| Find | 7 | 17 | 3 | FindStyle 4 | 13 | **7** | 6 |
| Validation | 3 | 2 | 1 | — | 2 | **2** | 0 |
| Clipboard | 2 | 1 | 1 | — | 1 | **1** | 0 |
| Titles | 5 | 5 | 2 | — | 5 | **4** | 3 |
| Locking | 2 | 1 | 1 | — | 1 | **1** | 0 |
| Connections | 18 | 51 | 4 | ArrowModel 13, ArrowStyle 8 | 30 | **26** | 10 |
| Mentions | 25 | 72 | 5 | Mentionable 11, MentionText 11, MentionState 9, MentionStyle 8, MentionScope 7 | 26 | **24** | 20 |
| Publishing | 6 | 11 | 3 | PublicStyle 4, PublishingState 4 (kept: Publishing 4) | 3 | **3** | 5 |
| Boards | 5 | 6 | 2 | — | 6 | **5** | 2 |
| Snapping | 3 | 3 | 1 | — | 3 | **3** | 1 |
| Transform | 3 | 2 | 1 | — | 2 | **2** | 0 |
| Automation | 15 | 47 | 5 | Automation 10, Drawing 10, DrawPoints 9, Draw 7 | 13 | **13** | 8 |
| Queries | 13 | 37 | 4 | QueryPoints 7 | 30 | **22** | 11 |
| QueryTranslation | 3 | 3 | 1 | — | 3 | **3** | 0 |
| QueryCommands | 3 | 2 | 1 | — | 2 | **2** | 0 |
| StickyNotes | 5 | 4 | 1 | — | 4 | **4** | 2 |
| Schemas | 19 | 70 | 6 | JSONReader 14, SchemaReferences 9, SchemaCard 9, SchemaCardDefinition 8, SchemaSync 7 | 25 | **19** | 19 |
| Subboards | 7 | 13 | 3 | SubboardDefinition 5, SubboardStyle 4 (kept: Subboards 5) | 4 | **4** | 10 |
| Frames | 8 | 15 | 3 | FrameStyle 6, FrameDefinition 4 (kept: Frames 6) | 5 | **5** | 8 |
| JumpTo | 7 | 13 | 3 | JumpToStyle 4 | 9 | **6** | 5 |
| References | 15 | 60 | 5 | ReferenceStyle 13, ReferenceState 11, ReferenceCondition 7, ReferenceAnswers 7 (kept: References 10) | 23 | **17** | 16 |
| Moving | 4 | 6 | 2 | — | 6 | **4** | 2 |
| Composition | 4 | 2 | 1 | — | 2 | **2** | 1 |
| CanvasQuickLook | 3 | 2 | 1 | — | 2 | **2** | 0 |
| CanvasCLI | 3 | 2 | 1 | — | 2 | **2** | 0 |
| **All 49 boards with uses** | 367 | 762 | | 47 hubs on 18 boards | 421 | **353** | 254 |

## Worked examples

**Mentions: 25 files, 72 uses, h = 5, 24 arrows.**
- **Hubs.** Mentionable and MentionText (11 users each), MentionState (9), MentionStyle (8) and MentionScope (7). These are the model, the per-editor state and the style. The next file down has only 4 users.
- **Arrows.**
  - The plugin's flow: Mentions.swift ↔ MentionDrawing, and Mentions.swift → MentionEdges, MentionFaces, MentionMenus.
  - The pill cluster: MentionDrawing ↔ MentionTextStyle ↔ MentionPill, with MentionFaces and MentionFind both → MentionDrawing.
  - Typing: MentionTextArea → MentionTextView → MentionPicker and MentionPill.
  - The state's own pieces: MentionState → MentionCatalog, MentionMatching, MentionBacklinks, MentionLabels and MentionEdges.
  - Smaller links: MentionedIn → MentionBacklinks, and MentionValidation → MentionProblems.
- **Relayed.** MentionTextView → MentionTextStyle, through MentionPill.
- **Pills only.** MentionRows.

**Automation: 15 files, 47 uses, h = 5, 13 arrows.**
- **Hubs.** Automation.swift (10: the command registry and errors), Drawing (10: the resolved script, which 6 other files extend), DrawPoints (9) and Draw (7: DrawResult and DrawChange).
- **Arrows.** They show the parts of the draw pipeline:
  - DrawCommit → DrawLayout → DrawObstacles.
  - DrawCommit → DrawStandIns ↔ DrawBoard, with Show and DrawTexts both → DrawBoard.
  - DrawTexts ↔ DrawVocabulary, which DrawQueries and Commands.swift (AutomationPlugin) also use.
  - Commands → Show.
- **Cost.** Drawing's 8 pairs become 16 pills. Drawing's note now lists the pipeline, and every piece shows a Drawing pill.

**Canvas/Model: 15 files, 54 uses, h = 4, 15 arrows.**
- **Hubs.** Identity (13), ShapeRecord (10), CanvasDocument (7) and BoardID (6): the ids and records everything stands on. The next file down has 3 users.
- **Arrows.** They show how a document changes:
  - Transaction → Containment, CanvasFile, ChangeSet, StackingKey and AddedProperty.
  - Enclosing → Settling → Transaction; both extend Transaction.
  - CanvasFile ↔ DocumentDelta → ChangeSet.
  - Two hubs keep their own one-way arrows: CanvasDocument → StackingKey, and ShapeRecord → ShapeMeta.
- **Relayed.** CanvasFile → ChangeSet, through DocumentDelta. Enclosing → Containment and Settling → Containment, both through Transaction.

**Schemas: 19 files, 70 uses, h = 6, 19 arrows.**
- **Hubs.** JSONReader (14), SchemaReferences (9), SchemaCard (9), SchemaCardDefinition (8) and SchemaSync (7: the model sync that the panel, highlights, editor and plugin all watch). SchemaDocument (6 users, equal to h) stays an arrow target.
- **Arrows.**
  - The plugin: SchemasPlugin → SchemaDocument and SchemaLinks, and SchemasPlugin ↔ SchemaPanel and SchemaHighlightPopovers.
  - The panel's JSON: SchemaPanel ↔ SchemaCompletions → JSONCompleter → JSONCaret, plus JSONCompleter ↔ SchemaDocument.
  - Highlights: SchemaDescriptionEditor → SchemaHighlights, and SchemaHighlightPopovers → SchemaHighlights → JSONPointer and SchemaPrompts.
- **Relayed.** SchemaPanel → JSONCompleter (10 symbols), through SchemaCompletions (17).
- **Pills only.** SchemaSkeleton.
- **Cost.** SchemaSync ↔ SchemaPrompts, the whole "Kept in step by the model" frame, becomes a pair of pills.

**Selection: 15 files, 38 uses, h = 4, 12 arrows.**
- **Hubs.** SelectionState (10; tied both ways to 9 files), Selection.swift (9: SelectionPlugin and the kinds' selectability) and SelectionStyle (7). The next file down is Opening, with 4.
- **Arrows.** They show the select tool dispatching:
  - SelectTool → Brush, Buttons, Faces, Handles, Labels and Opening.
  - Handles → Resizing and Buttons.
  - GoingTo → Opening and SelectionHistory.
  - SelectionState → SelectionHistory, and Selection → RefusalShake.
- **Relayed.** SelectTool → Resizing, through Handles.
- **Pills only.** Selection/Popovers.

**QueryTranslation: 3 files, 3 uses, h = 1, 3 arrows (today it has 0).**
- **Hubs.** None. AskRequest has 2 users.
- **Arrows.** All three stay: QueryTranslator → AskAnswer → AskRequest, and QueryTranslator → AskRequest.
- **Why the shortcut stays.** QueryTranslator uses AskRequest more (11 symbols) than AskAnswer does (2), so AskAnswer doesn't relay it.

## Canvas's own board, its 8 folders

`references_of(*canvas_folders())`. The weight is the number of file pairs between two folders, and Style.swift is left out. There are 43 uses, drawn as 25: 18 pairs used both ways and 7 one-way uses.
- **h = 4.** Model, Persistence, Plugins and Shapes each have 7 users and are the candidates.
- **Hubs.** Model, Persistence and Shapes; every folder shows them as pills.
- **Kept.** Plugins keeps its arrows. Schema is tied both ways to only those four folders, so it would have no arrow left otherwise.
- **Relayed.** Plugins ↔ Rendering and Rendering ↔ Tools, both through Editor.
- **5 arrows remain:** Editor ↔ Plugins, Editor ↔ Rendering, Editor ↔ Tools, Plugins ↔ Schema and Plugins ↔ Tools.
- **Note.** Persistence is a hub on count alone. Editor, Rendering and Tools each use it through a single file pair.

## Judgment calls worth a look

- **Small kind boards.** FrameDefinition (4 users of 7) and SubboardDefinition are hubs, so plugin ↔ definition becomes a pair of pills.
  - Frames keeps 5 arrows: Frames.swift ↔ CreateFrame, FrameHeader, FrameRow and FrameTool, plus FrameSkeleton → Frames.swift.
  - To keep the plugin ↔ definition arrow, stop a kept candidate's two-way partners from becoming hubs.
- **Automation.** Draw is a hub, so Commands → Draw becomes a pill, and that is the plugin registering the draw command.
- **Queries stays the densest board:** 22 arrows on 13 notes. Only QueryPoints stands out (7 users; the next are 4, 4, 4), and QueryState and Evaluation use nearly everything.
- **Hubs count users, not symbols.** Selection.swift is a hub on 9 users, eight of which name a single one of its symbols.
- **The guard is checked once, when a candidate's turn comes.** A guard re-checked against every hub after each choice would keep Selection.swift with eight weak arrows into it. The per-turn version was chosen, and Popovers being pill-only is its one side effect.

## Files

- **`heuristic.py`:** `references(board)`, `arrows(board)`, `references_of(nodes, uses, weight, title=str)`, `decide(board)` and `decide_graph(...)` (which return h, hubs, kept candidates and arrows), and `canvas_folders()`. Run alone, it prints each board's h, hubs and arrows.
- **`heuristic_check.py`:** checks the invariants on every board: a partition into arrows and references, pairs never split, no arrow into a hub, relays never isolating a file, and `references_of` matching `references`. Its digest is the same across `PYTHONHASHSEED` values.

The scripts behind the tables above, and the discarded variants, weren't kept.
