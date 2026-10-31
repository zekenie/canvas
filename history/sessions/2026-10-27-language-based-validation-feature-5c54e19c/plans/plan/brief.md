# Language rules: frames for the build plan, component by component, against their APIs

You are drawing wireframes for the build plan of a feature that isn't built: **language rules**. A type carries a few English sentences; every shape of that type (notes, and arrows of a relationship type) is checked against them in the background by a fast "decision model" (Jev, from TypeSafe), and a confident failure is an ordinary validation warning: Validation's orange ring and a line in the Issues tab that quotes the sentence. The owner asked for "the plan enriched with component by component wireframes that consider their APIs": every frame shows one component as a person meets it **and names the code interface behind each thing in the frame**, existing or new. This round draws pictures only: it writes no app code and changes nothing in the repository.

## Paths and limits

- SCRATCH = `/private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-language-validation-feature-9707df/5c54e19c-eecf-40b5-a6f7-141090714e71/scratchpad`. Write only in your own folder, `SCRATCH/plan/frames/<your letter>/`.
- REPO (read only) = `/Users/zekenie/code/native-canvas/.claude/worktrees/language-validation-feature-9707df`. Read its `Sources/` when you want to see how something the frame borrows looks (a panel section, a status line with buttons, a settings pane, a card). Don't read under `.claude/worktrees/` but REPO, nor the owner's other projects.
- Don't run `./build.sh`, `./test.sh` or start an app. A test copy of the app is already running with the prototype's boards (2 Cars, 3 Votes, 4 Listings): you may run read-only commands against it, `REPO/build/canvas` with `CANVAS_SOCKET=${TMPDIR}ic-rules-proto.sock` (`boards`, `query`, `capture --dark --scale 2`, `draw --dry-run`). Never draw for real, and never touch another socket.
- Never print, log or write an API key.

## Read first

1. The look: the earlier rounds' generators and frames. `SCRATCH/wire/brief.md` (the app's look, the kit, measuring text with `SCRATCH/mock/measure`, rendering with `SCRATCH/mock/svgpng`); direction B, which the owner is refining (`SCRATCH/wire/b-on-the-type/`: PNGs, `design.md`, `src/`); the real-data frames that followed it (`SCRATCH/proto/pictures/cars/` and `votes/`: PNGs, `notes.md`, `src/`). Copy pieces from those generators so the frames look like the same app. The owner loved frame 6 (`votes/6-why-flagged.png`): it was real data.
2. The real boards as the app draws them: `SCRATCH/plan/captures/listings-board.png` (Listings, board 4, dark, 2x), `SCRATCH/proto/captures/cars-board.png`, `votes-board.png`, `pa8-board.png`. Lay boards out as those are laid out.
3. Your facts: `SCRATCH/plan/facts-listings.json` (the listings: every value, sentence and verdict, and the Corolla's and the Mustang's real requests and answers), `SCRATCH/proto/pictures/facts-cars.json`, `SCRATCH/proto/pictures/facts-votes.json`. **Use only what they say.** Quote titles, values, sentences and counts exactly. A frame that needs a state no run produced (a spinner, a missing key) draws the state and invents no number; say so in your notes.
4. The plan's components and their APIs, below. **Use these names.** If a frame needs an interface not listed, don't invent one: leave it out and say so in your notes.

## The frame

- 1440 × 900 points, dark appearance, PNG at 2x (2880 × 1800) beside the SVG.
- Top left: the frame's id and a few plain words in `#8E8E93`, 14 px ("F5 · Why a listing is flagged").
- Left, about 1000 wide: the app (a crop of the window: canvas, and the detail panel at its right, 340 wide, as the earlier frames have it), or the diagram or terminal the frame is.
- Right, 440 wide, on `#141416` with a 1 px `#2C2C2E` rule between: **the legend**. The component's name (17 px semibold), then one entry per marker: the number, what it is in plain words (13 px), the interface in monospace (12 px, `#C7C7CC`), and a tag: `exists` (gray `#636366`) or `new` (magenta `#D63AFF`), with the module after it (`new · Types`, `exists · Validation`). Last, a "Keys" line where the frame has stops (what Tab, Return, Space, Escape do there, from the component below).
- **Markers**: 20 px magenta (`#D63AFF`) circles with a white number, beside the element they name with a 1 px magenta leader where they can't touch it. Never over text the frame needs. At most nine a frame: name what the component adds or relies on, not every pixel.
- No captions on the canvas itself; what a frame shows beyond its legend goes in your notes.
- Open every PNG at full size and fix overlaps, cut words and legend overflow before you hand in.

## The components and their APIs

Names marked **new** are the plan's sketches; everything else exists today (paths are under REPO/Sources).

**1 · Decision models** (new module `DecisionModels`, platform engine; depends on Canvas and LanguageModels)
- `protocol DecisionModel: Sendable { func decide(_ request: DecisionRequest) async throws(DecisionModelError) -> DecisionAnswers }` **new**. `DecisionRequest { state: JSONObject; questions: [DecisionQuestion] }`, `DecisionQuestion { id; instructions; yes; no }`, `DecisionAnswers { model: String /* "jev-1.14.0" */; yes: [String: Double] }` **new**.
- Providers **new**: `JevModel(keys: .standard)` (POST `https://api.typesafe.ai/v1/systemone`, each question a `noul`), `LanguageDecisionModel(model:)` over `editor.languageModel` (Haiku 5.5 answers in words), `ScriptedDecisionModel` for tests.
- `DecisionModelsPlugin: OutwardPlugin` **new**, `init()` / `init(model:)`, `editor.decisionModel`; its key pane through `registrar.settingsPane("TypeSafe") { … }` (exists, `Canvas/Plugins/HostSlots.swift`), the key in a 0600 file beside the Anthropic one (`TypeSafeKeyStore` **new**, as `AnthropicKeyStore`), `.decisionModelKeyDidChange` **new** (as `.languageModelKeyDidChange`) so checks retry. Cutoffs per provider, `DecisionCutoffs(flag: 0.7, holds: 0.3)` **new**, set by the live eval.

**2 · Where a rule is kept**: in the type's schema, `"$rules": {"const": [{"says": "…", "find": [{"phrase": "…", "query": "…"}]}]}`, beside `$color` and `$autofill`. It copies with the type and agents write it with `canvas draw`'s `schema:`.
- Types today holds `$color` and `$autofill` aside from the model that keeps a type's words and schema in step (`HeldDirectives`, `Types/Type/HeldDirective.swift`, a closed list). **New in Types**: `registrar.typeDirective("rules")`, a point that lets another plugin's directive be held the same way: never sent to the model, carried across a schema written whole, and a change to it alone no change to the type's fields.
- **New in LanguageRules** (a new platform module on Types, Validation, Queries, QueryTranslation, Topology, DetailPanel, DecisionModels): `RuleBook` (an `EditorService`): `rules(of: type)`, `chain(for: shape)` (each type of the shape's chain with its rules, most general first, by `editor.types.lineage(of:)`); `editor.ruleWriter.setRules(_:of:)`, one step "Change Rules".

**3 · What a rule sees**: `RuleContext.build(for:in:)` **new**, pure, off the main actor, over `topology.snapshot(.resolved)` (exists: `shape(_:)`, `parent(of:)`, `children(of:)`, `edges(of:)`, `edges(carriedBy:)` for an arrow's ends) and the type graph. The state's labels are the prototype's: "shape", "its types", "in", "beside it, in the same place", "along its edges", "starts at", "ends at", "beside it at its start/end", and one entry per chip. Past a budget the biggest groups shrink to titles, then to counts by type. Its hash is the cache key; its footprint (the shapes it read) says which commits re-ask.

**4 · Chips: a phrase that finds**: a rule's phrase in brackets, `[the member's district]`, is a query.
- Written in English and translated as a reference pill's words are: `editor.queryTranslator.translate(_:about:)` (exists, `QueryTranslation/QueryTranslator.swift`) with a **new** `about: .rule` that teaches `:scope`.
- **New in Queries**: `:scope`, `:scope-start`, `:scope-end`, words bound per request, `QueryMatchRequest(text, scope: id)`, so every chip of every shape checked runs in one batch: `editor.queries.matches([…])` (exists, `Queries/QueryState.swift`: one snapshot, each distinct text once). A stored chip is checked as written (`checkStored`, exists, with a **new** binding argument so `:scope` passes where a shape is bound).
- Its states: writing, finding (a spinner), found N, finds nothing (0), can't (a word that reads the editor, such as `:selected`), edited by hand.

**5 · The checks**: `RuleChecks` **new** (an `EditorService`).
- Hears each commit (`documentDidChange(_ changes: ChangeSet, in:)`, exists) and `topology.follow { TopologyChange }` (exists); marks dirty the shapes whose footprint a change names, the shapes of a type whose rules changed (`editor.types.allInstances(of:)`, exists), and every shape with a chip on any commit that isn't a move (chips run again after quiet, as reference pills' answers do).
- Waits for quiet (editing ends, or 3 s idle, `editor.scheduler`), then one snapshot, one chip batch, contexts built off the main actor and hashed; a hash it has answered asks nothing; the rest go to `editor.decisionModel`, eight at a time, the board shown first, then the rest of the file. Answers are kept in memory and in a cache file in Application Support, so reopening a file asks nothing it asked before (a Quick Look preview asks nothing).
- Verdicts reach Validation through a rule: `forShapes(holding: IgnoredRulesProperty.self) { $0.validate(ignoringMoves: true) { … } }` (the point exists, `Validation/Validation.swift`) returning `.warning(sentence)` for each rule that flags, less the ignored ones; and `editor.validation?.recheck(ids)` (exists) when answers land. While it works it is a settle source, `topology.keepsSettling { busy }` (exists), so the command line can wait.

**6 · A flagged shape**: the ring, the table of contents' dot and the Issues line are Validation's (exist). **New in Validation**: actions on an issue, `ValidationIssue.actions: [IssueAction]`, drawn by `DetailStatusLine(_:isBusy:actions:)` (exists, `DetailPanel/TextViews.swift`). A rule's issue carries **Ignore** and **Show Rule**. Under the issues, LanguageRules' own section in the Issues tab (`DetailSection(…, in: IssuesTab.self, id: "rules")`, the point exists): the shape's rules read together, each with its state (flags, holds, unsure, ignored, checking) and the type it's on, and **Shown**: what the model was shown, by label, as rows (`DetailRowList(…, onHighlight:)`, `DetailGroupHeader`, `DetailShapeRow`, exist); highlighting a row lights those shapes on the canvas (`registrar.outlines { Outlines(tinted: [TintedOutlines(color:shapes:ring:)]) }`, exists) and Return goes to them (`editor.goTo`, exists).

**7 · Ignore**: an added property on the shape, `ignoredRules` **new** (`IgnoredRulesProperty`: the sentences ignored; a new fixture), which the kinds opt into through LanguageRules' sugar, `note.checkedByRules()`, `arrow.checkedByRules()` **new**. One step "Ignore Rule". It lapses when the sentence changes. Stop Ignoring is in the Rules section.

**8 · Rules on the type's note** (a later landing). Two ways, drawn side by side for the owner to pick:
- On the note, as direction B drew it: **new in Types**, a point for lines at the foot of a type's rows (where a failed read is drawn today, `RowBook.foot(of:)`): `$0.typeRowFoot { type, context in [RowFootLine] }`; Types lays them out, draws them, makes their faces and ⌥Tab parts and their skeleton bars. A relationship type's card gets the same lines.
- A count beside the type's pill, through what exists: an adornment, `$0.adornment(RulesChip.self) { … AdornmentLabel("Rules").counted(2) }` (as Publishing's "Public · 3"), and the panel for the rest.

**9 · A type's Rules tab**: `RulesTab` **new**, a panel tab of LanguageRules' (`DetailTab`, `order: .after(TypeSchemaTab.self)`, exists), on every shape that holds a schema, a relationship type's too.
- Its own rules: each sentence editable (`DetailTextArea`, exists, with a **new** `coloring:` argument, as `DetailCodeEditor` has, so a chip's phrase is drawn as one), a line under it for each chip (the phrase, its query, what it finds), and the count of shapes it flags, a button that selects them (`editor.select`) and lights them while highlighted.
- Then the rules it inherits, dimmed, "from Car", not edited here.
- `add rule` last, as the field card's `add field` is.
- A status line at the foot when nothing can be checked: `DetailStatusLine` with Open Settings… or Retry (exists).
- Keys: Tab and ⇧Tab walk sentence, chip, count, in reading order; Return on a count selects its shapes, on an inherited rule goes to its type; Escape leaves the panel.

**10 · Agents** (the command line)
- Writing: `canvas draw` writes `$rules` in a type's `schema:` (exists; the held directive keeps it across a schema written whole). Draw checks each chip's query as written (`registrar.drawChecks`, exists; a **new** contribution).
- Reading: `canvas query ':warned'` (exists) lists the flagged shapes; each row's `problems` (exists, `Queries/QueryResult.swift`, `ShapeProblem {field, path, class, message}`) holds `{"class": "warning", "message": "<the sentence>"}`. **New**: Validation's words wait while checks are pending, as edge queries wait for settling (`QueryRequest.settle`, exists).
- Asking: `canvas decide [--board N] <query> "<question>"` **new** (a module of its own, `DecisionCommands`, through `registrar.automationCommand(…, runAsync:)`, exists): one yes/no question asked of each shape the query finds, with the same free context, answering each row's probability; nothing is stored and nothing rings. This is the owner's "a binary question … through the cli, via an agent".
- The canvas skill (`.claude/skills/canvas`) says all of this, held by SkillTests.

## What you hand in

Your frames as `.svg` and `.png` in your folder, the generator you used (`src/`), and `notes.md` (at most ~250 words): each frame in a line, every place real data changed what the brief describes, every interface you needed and didn't find in the list, and anything left out for want of a fact. End your reply with the PNG paths.
