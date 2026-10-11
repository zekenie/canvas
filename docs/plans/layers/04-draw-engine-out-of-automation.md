# 04 · `canvas draw`'s engine is a surface, Draw; Automation is the command line over it

**Commit title:** canvas draw's engine is a surface any plugin may run, Draw, as Queries is the query engine; Automation is the command line's commands over it, and the wire stays out of the engine

**Depends on:** 01 (the charter). **Unblocks:** 05, where concerns fill draw's points themselves.

## Complaint

The lexicon finding: "dependency inversion around `QueryLexicon` and `DrawLexicon` so that modules can define their own behavior". For draw, that's blocked by one fact. Draw's extension points (`DrawNames`, `DrawEdges`, `DrawChecks`, `DrawTextFormats`, in `Sources/Automation/DrawPoints.swift`) are declared in Automation, a **language**, and a concern may not import a language. DrawLexicon exists to bridge that gap. Removing it means moving the points first, and the points belong to the engine, not to the command line.

## Justification

- **Automation is two modules in one** (5,016 lines; mapped file by file):
  - **The engine, about 4,420 lines in 12 files** (about 4,510 with the kinds listing): parse with DrawScript, resolve names, edges and texts through its points, lay out with the solver, commit in one transaction, report a row per shape (Draw, Drawing, DrawCommit, DrawStandIns, DrawBoard, DrawLayout, DrawPoints, DrawTexts, DrawVocabulary, DrawObstacles, DrawQueries, Measure).
  - **The command line, about 500 lines:** the commands point and its sugar, parameter schemas, `AutomationContext`, `AutomationError` and its mapping to `RPCError`, `hostCommands` and the JSON bridge (Automation.swift, the first half of Commands.swift, Show.swift, JSONBridge.swift).
- **The engine barely touches the wire.** It uses wire types in four places:
  - `Draw.swift:93`, `[String: JSON]` in a result row;
  - `DrawCommit.swift:149`, `JSON(value)`;
  - `Drawing.swift:366` and `:998`, `RPC.commandName` (`"canvas"`) in two hints that name other commands.

  Canvas's own `JSONValue` (`Sources/Canvas/Persistence/JSONValue.swift`) has the same six cases and is `Codable`.
- **`AutomationError` is the engine's thrown type** (157 `throw` statements in the engine files, 101 of them `throw AutomationError(`, and about 60 `throws(AutomationError)` signatures). **But the engine uses six of its fields:**
  - It reads message, reason, hint, line, statement and errors.
  - Column, length and `details` are QueryCommands' alone.
  - `invalidParams` only passes through, at `DrawCommit.swift:293`, and nothing on the engine side sets it.

  So an engine error with those six fields carries everything. Its wire code is always "failed", and Automation maps it in about ten lines.
- **Everything else the engine imports is a surface or the foundation:**
  - Adornments, for `measure`'s title-row reach (`Measure.swift:113`);
  - Queries and QueryLanguage, to check a query a property holds (`DrawQueries.swift:10-14`);
  - Topology (stand-ins), DrawScript, Geometry and Canvas.

  HostSlots is used only by `hostCommands`, which stays on the command side. So the engine can be a surface: it knows no concern, and once it's out of a language, concerns may fill its points.
- **This is the split queries already made.** `Queries` is the engine (a surface any plugin may run) and `QueryCommands` is the language (`canvas query` over the wire). `e1127f8` moved Queries to surface for exactly this reason. Draw is the same shape and was never split, which is the only reason DrawLexicon still has a job.
- **The engine is useful past the command line.** Moving already places a shape "as `canvas draw` places one" by calling DrawScript's solver itself (`Sources/Moving/Landing.swift`). Once the engine is a surface, a feature can run draw's placement instead of re-deriving it. That's not done here.

## Design

**New module `Draw`** (`Sources/Draw`, `// layer: surface`):

- Dependencies: Adornments, Canvas, DrawScript, Geometry, Queries, QueryLanguage, Topology. No CanvasRPC, no HostSlots.
- `DrawError`: message, reason, hint, line, statement, errors. The engine's typed throw, in place of `AutomationError` at every engine throw site.
- `DrawPlugin: ListedPlugin`, id `PluginID.drawEngine = "draw-engine"`. It:
  - owns the four points (each `owner` becomes `.drawEngine`, from `.automation`);
  - holds the debug counters that are now Automation's (`Commands.swift:20-23`, bumped at `DrawBoard.swift:45, :334`);
  - contributes a "draw engine" mark, as `QueriesPlugin` contributes "query engine" (`Sources/Queries/Queries.swift:36-55`), so its row in the registry report says what it is.

  On the id: not `"draw"`. `Tests/CanvasRPCTests/ArgumentTests.swift:34` writes `"draw"` and can't depend on Draw, so the id check would refuse it. And at most 19 characters, or every row of the registry report re-pads (`Registry.swift:356`).
- **Public entry points.** Today these are internal and take Automation's types:
  - `draw(script:dryRun:reveal:program:in editor:) throws(DrawError) -> DrawResult`;
  - `measure(…)`, over a registry;
  - `kinds(in registry:)`, the kinds listing and `unplaceable` (`Commands.swift:116-205`, `:158`);
  - the naming `canvas show` borrows (`FileNames.container`, `drawNaming`, `quoted`, `indefinite`).

  `program` is the command line's name for the two hints that name its commands. Automation passes `RPC.commandName`, so the engine names no wire constant. The result types become public, with `JSONValue` in place of `JSON`.

**Automation** (still `// layer: language`):

- Keeps:
  - `Automation.swift`: the commands point, sugar, parameter checking, `AutomationContext`, `AutomationError`, `rpcError`, `runAutomationCommand`;
  - `Commands.swift :1-114`: `AutomationPlugin` registering `draw`, `show`, `kinds` and `measure`, and `hostCommands`;
  - `Show.swift` and `JSONBridge.swift` (QueryCommands' `QueryOutput.swift:62` uses the bridge);
  - the commands' parameter schemas, `DrawParams` and `MeasureParams` (`x-stdin` is the command line's).
- Each command resolves its board (the `no_board` error stays here), calls Draw's entry point, encodes the result, and maps `DrawError` to `AutomationError` field for field, so `rpcError` writes exactly the wire error it writes today.
- Its dependencies become exactly what's left imports. Expected: Canvas, CanvasRPC, Draw, DrawScript (Show.swift names `ScriptError.Reason`, `:3, :42, :53`) and HostSlots, dropping Adornments, Geometry, Queries, QueryLanguage and Topology. HostSlots drops out too if plan 06 has landed first, since `hostCommands` then comes from Canvas. The audit settles it.
- QueryCommands is unaffected. It uses the commands sugar, `AutomationContext`, `AutomationError` and the JSON bridge, none of draw.

## Tactics

1. **Move the files** with `git mv`, so history follows: Draw, Drawing, DrawCommit, DrawStandIns, DrawBoard, DrawLayout, DrawPoints, DrawTexts, DrawVocabulary, DrawObstacles, DrawQueries and Measure → `Sources/Draw/`. Split `Commands.swift`: the kinds listing and `unplaceable` go to `Sources/Draw/Kinds.swift`. Leave `DrawParams` and `MeasureParams` in Automation, in a new `Sources/Automation/Params.swift`.
2. **In the moved files:**
   - `AutomationError` → `DrawError`: mechanical, the 101 constructions and about 60 signatures. Drop the `invalidParams:` argument at `DrawCommit.swift:293`.
   - `JSON` → `JSONValue` at the two sites.
   - `RPC.commandName` → the run's `program` at the two sites.
   - `import CanvasRPC` lines go (Measure's is already unused).
   - Make public only what Automation and, after 05, the concerns call.
3. **Add `DrawPlugin`, `PluginID.drawEngine`, the mark, and the counters' new home** (`Sources/Draw/Draw.swift`'s plugin section).
4. **Automation:**
   - The commands call the entry points.
   - Add `AutomationError.init(_ error: DrawError)`, which also maps nested `errors`.
   - `PluginID.automation` stays, and still owns the commands point (`AutomationCommands`, `Automation.swift:28`), which QueryCommands fills. Only the four draw points change owner (`DrawPoints.swift:31, :110, :166, :224`). Rewrite its comment (`Automation.swift:14-16`).
5. **`Package.swift`:**
   - Add the `Draw` target among the surfaces.
   - Rewrite Automation's dependencies.
   - DrawLexicon replaces `Automation` with `Draw` in its dependencies: every symbol it uses moved there (the point sugars, `EdgeRequest`, `DrawIssue`, `DrawTextContext`, `drawCanName`, and the error type). So after this commit DrawLexicon imports no language, the state QueryLexicon was in.
   - In the ships table, insert `"Draw.DrawPlugin"` just before `"Automation.AutomationPlugin"`, so DrawLexicon's plugins, which fill its points, still follow it. Rewrite that comment (`:157-159`).
   - The header: the surface row names the draw engine.
6. **`build.sh`:** nothing. It names no module.
7. **Tests:**
   - **AutomationTests** keep driving draw through the commands. Draw is in Automation's closure, so they may name it.
     - Every test registry that uses draw's points adds `DrawPlugin()`: `CommandTests.swift:104`, `DrawTests.swift:998`, `DrawTextTests.swift:512, :518`, `DrawStandInTests.swift:493`.
     - Counter reads move to the engine's (`DrawTextTests.swift:477`, `DrawStandInTests.swift:971`).
   - **DrawLexicon's four test targets** (TitleNamesTests, PortEdgesTests, ValidationChecksTests, MentionTextsTests) can't keep running draw through Automation's commands. They test DrawLexicon, whose closure no longer holds Automation. Their helpers switch to Draw's entry points:
     - TitleNamesTests `:42-64`;
     - PortEdgesTests' `Support.swift:219-246`;
     - ValidationChecksTests `:41-45`;
     - MentionTextsTests' `Fixtures.swift:147-170`.

     Results are read by encoding them (`JSON(encoding:)`; CanvasRPC is still in the closure). Errors are read from `DrawError`'s fields where bodies read `.data?["line"]` today. Each helper adds `DrawPlugin()` to its registry. The wire's own shape stays held by AutomationTests and CompositionTests' CommandLineTests.
   - **The registry report gains the draw-engine row.** Update the pinned report in `Tests/CompositionTests/ShippedTests.swift:99-169` and the guide's block in `docs/plugin-system.md`. The test "the guide shows the registry report as it is" compares the two byte for byte. Paste the report the built registry prints.
8. **Docs:**
   - `.claude/rules/command-line.md`: Automation is the command line's commands, and `canvas draw`'s engine is Draw, a surface. Say what moved. Its `paths:` frontmatter adds `Sources/Draw/**`.
   - `.claude/rules/build.md`, "Layers": Draw joins the surfaces ("the draw engine, which every plugin may run, as the query engine"), Automation's import list shrinks, and the sentence "A language (Automation's `canvas draw`, and the query engine, Queries, though it is a surface)…" is rewritten.
   - `docs/plugin-system.md`:
     - the surface bullet in "Horizontal and vertical";
     - the module-graph table's surface row;
     - "The command line" (where draw's points and their owner are described);
     - the registry report block (above).
   - `CLAUDE.md`:
     - the module-graph rule's parenthesis ("the query engine, Queries, and the English-to-query translator, QueryTranslation, are surfaces every plugin may run") adds the draw engine, Draw;
     - the map's command-line line names Draw.
   - **The canvas skill does not change.** No message changes, and SkillTests hold that.

## Verification

- `./build.sh audit`: Draw passes the surface test (it declares points, and Automation imports it), imports no concern and no wire, and Automation's imports equal its dependencies.
- AutomationTests and the four DrawLexicon test targets, run as the executables test.sh builds (`build/debug/AutomationTests/AutomationTests`, and so on). `TEST_FILTER` matches suite and test names, not targets, and fails when nothing matches.
- Then a full `./test.sh`. Hold particularly:
  - CompositionTests' **CommandLineTests**, **SkillTests**, **MeasureTests** and AutomationTests' **Draw\*Tests**, which pin `canvas draw`'s output and errors through the built `canvas`. They must pass with no change to their expectations.
  - **ShippedTests** and the guide test, with the new row.
- In the app:
  - `build/canvas draw` with a named note, an edge, a mention in text and a schema card that warns;
  - a `--dry-run`;
  - a script with an error on line 3 (same line, reason and hint as before);
  - `build/canvas measure`, `kinds` and `show --root`.
- `./build.sh bench`: the benchmarks reach draw through `hostCommands` and should not move.

## Risks and open questions

- **Byte-identical output is the whole bar.**
  - `JSONValue` must encode exactly as `JSON` does. Both hold numbers as `.number(Double)` and encode them with the same call (`JSON.swift:63`, and JSONValue's `encode(to:)`). Their objects differ: `JSONObject` versus `[String: JSON]`. So compare the encoded result rows, key order included, before switching.
  - The error mapping must keep every field and the nesting `rpcError` produces.
- **Public surface:** expose only what Automation and the concerns call. An engine that's a surface should have a public API someone designed, not a dump of everything that used to be internal.
- **The size of the move** (about 4,510 lines). It's mechanical, but review it as `git mv` plus a small diff. Don't let logic changes ride along.

## Not in this commit

- Moving DrawLexicon's words into their owners, and deleting the lexicon layer: plan 05.
- A `DrawTests` target holding the engine's tests directly. AutomationTests cover the engine through the commands today, and splitting them is a follow-up.
- Moving letting Draw place its shapes instead of DrawScript's solver: a possible follow-up.
- Splitting `command-line.md` into an engine topic file: worth doing if the file is unwieldy, but it's a docs decision of its own.
