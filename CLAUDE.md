# Infinite Canvas

Native macOS infinite canvas (an AppKit document app, SwiftUI windows around an AppKit canvas), built from compiled-in plugins.

## How these instructions load

This file holds only what every task needs. The rest is in topic files in `.claude/rules/`, one per subsystem, listed in the [map](#map) below and linked to one another. Each topic file's `paths:` frontmatter names its subsystem's sources and tests: Claude Code puts the file in context when Claude uses Read, Edit or Write on a matching file, and not otherwise (not for Bash or Grep, for instance). So before planning or changing anything in an area, read its topic file, and follow its links as far as the task needs. `docs/plugin-system.md` is the long-form guide with the examples; each topic file links its sections.

Keep it that way: a change to a subsystem updates its topic file in the same commit; a new subsystem gets a topic file with `paths:` (a rules file without them loads in every session) and a line in the map; only what every task needs goes in this file.

## Build and test

- `./build.sh && open build/InfiniteCanvas.app` builds the app with `swiftc` directly (SwiftPM is broken with this machine's Command Line Tools) and opens it. Every mode audits the module graph first (`./build.sh audit` does only that), and `./build.sh graph`, `dot` and `api <Module>` read the graph: how it builds, and what the audit refuses, in [build](.claude/rules/build.md). `./build.sh bench` runs the benchmarks against their budgets: [benchmarks](.claude/rules/benchmarks.md).
- `./test.sh` builds every module but the app (debug, `-D DEBUG`) and runs the test executables, as many at once as there are cores (`TEST_JOBS=N`), slowest first, printing each one's output whole, in order. `TEST_FILTER=substring ./test.sh` runs the matching tests, and fails if none match. `TEST_UI_MENUS=1` adds the tests that open real (on-screen) menus, and runs the executables one at a time. Run by hand, a test executable takes `TEST_TIMES=1` (each test's seconds, on standard error). A time budget in a test measures the test thread's CPU time (TestKit's `threadCPUTime`), never the wall clock, which counts whatever else the machine runs. Every `Suite` a test target declares must be passed to `runTests` in its `main.swift`; test.sh fails otherwise.
- If the build fails with "this SDK is not supported by the compiler", a stale newer SDK is being picked. Prefix the command with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
- Sources compile in Swift 6 language mode. Keep them free of warnings (build.sh passes `-warnings-as-errors`).

## Rules for every change

Read `docs/plugin-system.md` first; it's the guide to the plugin system, with the examples.

- `Canvas` (the core) knows no particular shape or concern (its one tool is Hand), and must stay that way. A concern like validity is declared by a plugin (an `ExtensionPoint` in its own module) and other plugins opt in; if the core seems to need to know about one, add a generic extension point instead.
- `Package.swift` is the module graph, a target a line, each tagged `// layer:`, and the list of what ships (the plugins the product is made of, in order, each made by its name), and the audit refuses a cycle, an edge the layers don't allow, imports that aren't exactly a module's declared dependencies, and a module writing another module's kind, tool, plugin, property, channel or edge type id as a literal without depending on it. Every plugin may use the foundation (Geometry, Canvas, DrawScript, QueryLanguage, TextEditing, FuzzyMatching and Palette); beyond it, surfaces use only surfaces (the query engine, Queries, the draw engine, Draw, and the English-to-query translator, QueryTranslation, are surfaces every plugin may run), concerns use surfaces and concerns, features (cross-cutting behaviors that no kind opts into and no plugin imports: Jump To, Moving, Snapping, Reordering) use surfaces and concerns, languages (the command line over draw, and `canvas query`) use surfaces, languages and the wire (never a concern), and verticals use surfaces and concerns (never another vertical). A word in a language is given by the module that owns its meaning, as a plugin value of its own, through the engine's points; when the owner sits below the engine, the engine's module gives it. No module joins two others, and none imports the plugins to list them: shipping a plugin is its line in `Package.swift`'s table. A large module is in parts, folders of its directory with a table of their own in `Package.swift` (Types: nine), and a part names only what is in the parts its line says it uses: the build type-checks each with those sources alone. Plugins can't import CanvasUI, and the app imports no plugin: what a host takes of a plugin's goes through [host slots](.claude/rules/host-slots.md). Read [build](.claude/rules/build.md) before adding a module or an import.
- Change documents only with `editor.transact`, and name the step a user would call it (`transact("Name")`, `undoHistory.group("Name")` around several). A body that throws commits nothing and opens no step, and the error comes out untyped. Tools see `Pointer` values, never `NSEvent`; timers go through `editor.scheduler`. Model positions are world units; overlay sizes (handles, outlines, hit margins) are view points, divided by `zoom` in world space.
- Conform to `ShapeDefinition` (and capabilities), `Tool`, `Session`, `EditorService`, `MentionScope`, `TransformChannel` and any extension point that implements `check` or `summary` in an extension: only there does the compiler flag a near miss on a defaulted requirement ([plugins and kinds](.claude/rules/plugins-and-kinds.md)).
- A frame costs what's in view and what changed, never the whole board: per-frame code goes through `editor.paintOrder(in:)`, and a service keeps per-shape state and redoes only the shapes a commit's `ChangeSet` names ([drawing](.claude/rules/drawing.md)); `./build.sh bench` holds the budgets.
- Changing how a kind's props encode, even adding a member with a default, needs a migration and a new fixture in `Tests/CompositionTests/Fixtures/kinds` (an added property's value has migrations of its own, and fixtures in `Fixtures/added`); never edit a fixture ([boards on disk](.claude/rules/boards-on-disk.md)).
- A change to `canvas draw` or `canvas query`, their messages, the shipped kinds, the query words or edge types, or the `--ask` prompt changes the canvas skill (`.claude/skills/canvas`) too: SkillTests and QueryPromptTests hold them together ([command line](.claude/rules/command-line.md), [queries](.claude/rules/queries.md)).
- Arrows mirror tldraw's arc arrows: check tldraw before changing arrow behavior and call out any intentional deviation, and never regenerate the proof-of-concept fixtures from the app to make a change pass ([arrows](.claude/rules/arrows.md)).
- UI constants live in each module's `@MainActor` style enum (`Style`, `ArrowStyle`, `NoteStyle`, `TypesStyle`, ...), a kind's skeleton's beside its full look's (`NoteStyle.skeletonFill`, `SubboardStyle.skeletonBorderWidth`, `ReferenceStyle.skeletonFill`, `ArrowStyle.skeletonLineWidth`). The core's are internal (`Style.skeletonZoom`, `Style.skeleton`, `Style.skeletonText`, `Style.drawingPad`): a plugin goes by `editor.drawsSkeletons`, never the number, and one that simplifies further farther out reads `context.zoom`. Pure geometry (Geometry, `ArrowGeometry`) is nonisolated, so its constants live on those types.
- Never print, log or write the Anthropic API key ([language models](.claude/rules/language-models.md)).

## Tests

Read [testing](.claude/rules/testing.md) before writing a test, and the Testing section of the subsystem's topic file. In every test:

- Never touch the user's pasteboard: give the plugin a private one ([clipboard](.claude/rules/clipboard.md)).
- Never use the app's socket: a test listens on its own (`temporarySocketPath()`, TestKit) ([command line](.claude/rules/command-line.md)).
- Never reach the network: only the two live tests do, when asked, and every other test that builds the shipped list passes `model: ScriptedLanguageModel()` (ShippedTesting's `ShippedPlugins`; the list itself won't load for a test without a model and a pasteboard of its own: [language models](.claude/rules/language-models.md), [build](.claude/rules/build.md)).
- Close the `BoardDocument`s the test edits ([testing](.claude/rules/testing.md)).

Screen capture isn't permitted here: tests draw into bitmaps, and what a drawing change costs on screen is seen only in the app on screen ([testing](.claude/rules/testing.md)).

## Map

Each topic file starts with what it covers, the topics it touches, and its sections of the guide.

**Workflow**
- [build](.claude/rules/build.md): how `build.sh` builds; `Package.swift`, the layers and what each may import; what ships (the list, plugins made by name, `+ shipped`, the product's text files); the parts of a module (the table, the check that type-checks each alone); what the audit refuses.
- [benchmarks](.claude/rules/benchmarks.md): what `./build.sh bench` measures, and every budget.
- [testing](.claude/rules/testing.md): the headless harness, views in unshown windows, the board documents a test closes, and which topic files have test guidance.

**The core** (Canvas, Geometry and CanvasUI)
- [plugins and kinds](.claude/rules/plugins-and-kinds.md): plugin values and the frozen registry; kinds, their definitions and capabilities; translating and placing sessions.
- [properties and schemas](.claude/rules/properties-and-schemas.md): property lists (`SchemaDefined`), kinds' JSON Schemas, `KindSchema`, added properties, file values (what a plugin keeps on the file as a whole).
- [shape references](.claude/rules/shape-references.md): values that bind or name other shapes, and what deletes, copies, cuts and draws do to them.
- [editor](.claude/rules/editor.md): what `CanvasEditor` lends every plugin: layout inputs and laid-out frames, outlines and their standoff, read-only shapes, drawing offsets, the glide, skeleton levels, cards, commands and zoom, keys, the hand, the translation adjuster, service hooks, edge scrolling.
- [editing](.claude/rules/editing.md): editing in place (`Editable`, the editing view, `EditContext`), and an editor's text held to its shape's render.
- [undo](.claude/rules/undo.md): steps, groups and coalescing, `DocumentDelta`, one history across boards.
- [boards in a file](.claude/rules/boards-in-a-file.md): `CanvasFile`, board revisions, the delete cascade, `transact(on:)`, and showing a board.
- [containers](.claude/rules/containers.md): shapes holding shapes on a board, settling what's put down, and putting a container down around shapes.
- [boards on disk](.claude/rules/boards-on-disk.md): `BoardDocument` and `BoardCodec`: formats, migrations and fixtures, what's kept aside, the view memory, autosave.
- [drawing](.claude/rules/drawing.md): what a frame may cost, the dot grid, skeletons, board previews, the minimap, the pointer over the views the canvas hosts.
- [Quick Look](.claude/rules/quick-look.md): a board file's preview and thumbnail in the Finder: `BoardPicture`, the app's extension, how it's built, signed and registered.

**Foundation**
- [host slots](.claude/rules/host-slots.md): what a window puts around its canvas, and what the app takes besides, from plugins: views over the canvas, the inspector, the subtitle, settings panes, tool tips, the commands the app's server runs; CanvasUI's chrome that places them, and the app.
- [text editing](.claude/rules/text-editing.md): `EditingTextView`, the app's spelling settings and the one caret list, under every editable text.
- [fuzzy matching](.claude/rules/fuzzy-matching.md): `FuzzyMatcher`, the matcher every list ranks typed text with; `TextSearch`, Find's, over folded texts; `PathMatcher`, Jump To's, over containment paths.
- [palette](.claude/rules/palette.md): the color math: a color as sRGB and OKLCH, the seven roles one color is drawn in on the light canvas and the dark (`Swatch`), contrast, the one test for a dark appearance.

**Surfaces**
- [keyboard](.claude/rules/keyboard.md): shortcuts and chords, how a key reaches the canvas, the menu bar.
- [selection](.claude/rules/selection.md): the select tool, handles and resizing, opening, Back, canvas buttons, going to shapes, faces, the shake a refused change gives.
- [detail panel](.claude/rules/detail-panel.md): sections, tabs, status lines, headers, bindings, text boxes, list rows (a row, a group's header, a search field), the code editor and its completions, and its overview and takeovers (what other plugins show in it).
- [table of contents](.claude/rules/table-of-contents.md): rows, marks, nesting, what's listed (front to back), its heading, hover, another board's outline, dragging rows.
- [adornments](.claude/rules/adornments.md): pills and chips on shapes: placing them, their places, drawing and pointing.
- [context menus](.claude/rules/context-menus.md): a shape's items, the canvas's items, right-clicks and Control-clicks.
- [slash commands](.claude/rules/slash-commands.md): commands typed on a line of a shape's text.
- [topology](.claude/rules/topology.md): edges and edge types (a child under another plugin's), their sources, stand-ins and the views through them, provided answers, the one delivery of every change (`follow`) and settling, containment as one tree, snapshots for other threads.
- [language models](.claude/rules/language-models.md): the model plugins ask, the Anthropic key and Settings, `--ask`'s model.
- [prose maps](.claude/rules/prose-maps.md): which words of a text say which part of a lower-level text (a type's highlights): targets, maps, asking the model, the request.
- [placing](.claude/rules/placing.md): where a box of shapes lands, beside a shape, in a frame or anywhere, placed as `canvas draw` places one: `Surroundings`, `Landing`; Moving's solver, for any plugin that puts shapes down.
- [find](.claude/rules/find.md): ⌘F: the `FindableTexts` point and its contributors, the index, the search off the main actor, scope and order, the highlights, the panel in the detail panel's place.
- [neighbors](.claude/rules/neighbors.md): hovering a shape, on the canvas or in the table of contents, outlines what's connected to it in a color for each way, and its panel's Connections tab lists them by the same ways (the lights, each a title, a color and a query, contributed by the plugin that owns the edges; a pointer lights as a mention); the subject, asking and asking again, where a match is drawn, rings, the core's tinted outlines it hands, and the lists (folding, searching, their rows).

**Concerns**
- [validation](.claude/rules/validation.md): rules and issues (and where in a value one is), the schema rule, what each commit re-checks and `recheck`, rings, where issues show.
- [titles](.claude/rules/titles.md): named and derived titles, the pill and the looks other plugins give it, the cover zoomed out, `TitleHeader`, `/title`, shared titles.
- [clipboard](.claude/rules/clipboard.md): cut, copy and paste; boards and containers copied whole; cut and paste as a move.
- [locking](.claude/rules/locking.md): locked shapes, read-only, the chip, `/lock`.
- [publishing](.claude/rules/publishing.md): public shapes (what another shape may stand for), the two dials, the chip and its count, refusing while held (the panel goes to Connections), `/public`.
- [connections](.claude/rules/connections.md): ports, channels and the connector.
- [arrows](.claude/rules/arrows.md): tldraw's arc arrows, their labels and binding rules, and the proof-of-concept parity tests.
- [mentions](.claude/rules/mentions.md): mentions in text: pills, the `@` picker (its lines with their board), one token alone (`MentionToken`), mention edges, what mentions a shape (its quote, Show What Mentions), layout by names, mentions' warnings.
- [boards](.claude/rules/boards.md): opening boards, Enclosing Board, what a board is called (the root, as the file is) and where that heads other plugins' lists, the path's crumbs and their menus.
- [transform](.claude/rules/transform.md): turning a shape into another kind: channels, sources and targets, the menu item and the command, frame into subboard.
- [types](.claude/rules/types.md): a note that holds a JSON Schema is a type, named by its title: the module's nine parts and what each may use, making one (`/is-a type`, Remove Type, New type), the file's types (`TypeIndex`), what a shape is (`is`, the `is-a` edge, the chips, the Types tab), a note that is one (its `fieldValues`, the chain and the field book, the rows it and its type have under their words and typing in them, the card a row with more in it opens and its form, the Fields section of the Types tab, the one writer that changes a value), Checks (needed, wrong, a warning), pointers to other notes (the pill, the picker, `field-link`), the title from a field, Agents (what `canvas draw`, `canvas query`, `--ask` and `canvas measure` read and write of all that), and the model's part (`TypeSync`: words and schema kept in step; highlights).
- [colors](.claude/rules/colors.md): the color a shape of a kind that opted in holds (a named color or a hex), the built-in names and a file's own, the book that says what every color looks like, how a kind draws its color, the panel's row, `/color`, Color ▸, what draw and queries say of it, and what each shipped kind does with its color.

**Languages** (what agents read and write)
- [command line](.claude/rules/command-line.md): `canvas`, the wire, `CommandServer`, Automation's commands (`measure` reads a board's types), Draw (the engine of `canvas draw`: `is:`, a note's values joined, `@[Title]` pointers, what each shape's values still need), the canvas skill.
- [queries](.claude/rules/queries.md): the query language, what a query sees and where it runs, the words their owners give (`:is-a`, `:incomplete`, paths into a note's values), `canvas query` and `--ask` (what it is told of types and fields).
- [digest](.claude/rules/digest.md): the canvas-digest skill: a large body of connected information laid out as boards by a tool outside the app (`digest`, jsc), measured with `canvas measure`, drawn with `canvas draw`; the digest format, the plan, what it makes public, the dry-run gate, drawing again in place; the codebase ingestion (`dogfood/model/ingest`) built on it.

**Features** (cross-cutting behaviors; no kind opts in and no plugin imports one)
- [jump to](.claude/rules/jump-to.md): ⌘K, a palette that goes to a shape by its title and where it is; the catalog, the ranking over the containment tree, the palette and its list, picks.
- [moving](.claude/rules/moving.md): `/move-to` and `/move-near`, the shape typed in moved into a frame, onto a subboard's board or beside a shape, on any board; the table of contents' drops that move shapes; what each takes, where it lands (draw's solver), the commit.
- [snapping](.claude/rules/snapping.md): what a drag snaps to, and its guides.
- Reordering (`Examples/`) has no file of its own: it is in [context menus](.claude/rules/context-menus.md).

**Verticals** (the kinds)
- [subboards](.claude/rules/subboards.md): a card that owns a board.
- [frames](.claude/rules/frames.md): a region that holds shapes, the Frame tool, and Create Frame.
- [references](.claude/rules/references.md): a pill that stands for a public shape: its props and writers, its look in every state, what it stands for, going to the original, its row and panel.
- Sticky notes have no file of their own: [editing](.claude/rules/editing.md) holds a note's editor against its render, and the files of what notes opt into hold the rest.
