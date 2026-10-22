# Types and new shapes: the binding decisions for the build

Read this first. Where a spec in this folder (core-prereqs.md, types-module.md, is-a.md, instances-behaviors.md, custom-shapes.md) disagrees with this file, THIS FILE WINS. The two critic files (critic-architecture.md, critic-coverage.md) explain why; their resolutions are folded in below.

The design (the owner's working doc, "Types and new shapes") is final. The owner approved the build plan on 2026-10-09, taking every pick below. Never call a custom shape a "class", in code names, UI copy, hints, docs or commit messages.

## The owner's picks (user-visible)

1. Making a type: `/type` on a line of a note (a slash command with no argument). The note shows a Type chip whose menu has Remove Type (clears `schema` in one step; the words stay). Agents make a type with draw's `schema:` attribute. A type note may have types of its own (supertypes): `/is-a` on a type note admits only types. The field reader never reads a type note's words into fields.
2. Types start public: `/type` (and draw making a type) makes the note public in the same step, through Publishing's API (Types depends on Publishing). The person can make it private afterwards.
3. A custom shape is a frame holding the Bool added property `isShape` (key `isShape`), set by the three ways in. Its Shape chip's menu has Remove Shape (back to a plain frame; instances' chips go dashed and what it gave is taken back, as on a delete). A frame that only holds types (the owner's "$schema" frame) is not a shape.
4. Arrow shapes: arrows are drawn only from ports, so picking an arrow shape (e.g. Friendship) in the Shapes tool's menu arms it: the next arrow drawn from a port becomes an instance. The + chip does not show on arrow shapes. (Arrow shapes are also made by Turn into on selected arrows, `/is-a` in a label, and `edge … is:` in draw.)
5. Chips: one per type, in the left run after the title pill (`aboveTopLeft`); when the next one can't show whole, it and the rest fold into a "+N" chip. A click on a chip opens a small menu: Go to "Person", Remove "Person" (Remove left out when the shape is read-only). "+N" opens a menu listing every type. On arrows, chips and the lock sit above the label (anchor: `geometry.label`, else the open outline's middle, widened to a minimum width).
6. An arrow shape's ends: an instance arrow whose ends aren't (through the is-a lineage) the template's end types gets a Validation warning, e.g. `Ends at “Acme”, which isn’t a Person.` Binding is never blocked.
7. The template: turning it into another kind while it has instances is refused (shake, and the frame's panel opens its Instances section), through a generic veto point in Transform. A candidate of another kind brought into the frame while instances exist isn't taken as the template. Zero templates: warning `No template.`, no + chip, dimmed in the Shapes menu. Two or more: the frontmost whose kind matches the instances (else the frontmost) is the template; each other warns `Another template is in front.` The template's size is copied when an instance is made; public and locked come through the chain (kept in step).
8. Undo: the person's own action and what it changes on that shape are one atomic step (settle runs inside their transaction). Propagated rewrites are one step per board, "Update Instances". Read answers landing within about a second on one board are one step, "Read Fields". Deleting a type or custom shape takes back what it gave on EVERY board inside the delete's own step, so one ⌘Z brings everything back (this needs the core change in S1).
9. Reads: nothing is read when a file opens. Stale instances show "to read" with a Read action (a quit mid-run, a failure, a declined confirm). Count while running: "Reading 36 of 120". No automatic retry; after 3 transport failures in a row the queue stops with a Retry.
10. Queries: `:is-a("Person")` is transitive through `is` lists, custom shapes' builds-on (containment, through pills) and their types, cycle-safe. `.Person` stays refused (reason `unsupported`) with a hint to `:is-a`. `[a.b]` paths read values inside objects, untyped (each test typed by the JSON value found).
11. Confirmed design items: the model reads an instance's words into its types' fields; a value set by hand on an instance is its own, survives type edits and re-reads, and the panel marks it own with Reset.

## Names (one spelling everywhere)

- Modules: `Types` (layer: concern), `Placing` (layer: surface; Moving's beside-a-shape solver, `Surroundings`/`Landing`, moved out of Moving, which then imports it).
- Added properties (each gets `Tests/CompositionTests/Fixtures/added/<key>.v0.json` in the slice that ships it; fixtures are never edited afterwards):
  - `is` on typeable kinds (notes, arrows): an ordered `[TypeLink]`, where `TypeLink` is a one-field wrapper around `ShapeID` conforming to `ShapeNaming` (coded by hand as the bare uuid string; `ShapeID` itself must NOT conform). Shape ids only; no built-in entries. Empty is none. Never a `Set`. `contentMediaType` for draw/query text formats: `text/x-canvas-type`.
  - `schema` on kinds that `canBeType()` (notes): a `SchemaText` (ShapeNaming through `urn:uuid` `$ref`s). A note is a Type iff `schema` is present.
  - `fieldValues` on typeable kinds: a `FieldValues` struct wrapping `JSONObject`, `SchemaDescribed` written by hand (`{type: object}`), `readOnly: true` keyword (draw can't write it; queries and `canvas kinds` see it). Absent field = absent key; empty = none. No core `JSONValue: SchemaDescribed` conformance.
  - `isShape` (Bool) on kinds that `definesShapes()` (frames).
  - `behaviors` on kinds that are `typeTemplate()`s (notes, arrows): a JSON Schema text of `$` keys only, written from the template's words by the type sync parameterized with a behaviors-only prompt.
- Edge type: `is-a` (root, declared by Types), derived from `is` with `registrar.edges(in:as:)`.
- Build audit: `ORDINARY_IDS=(frame is)` in build.sh, and build.md's sentence updated.
- Tool id: `static let shapes: ToolID = "shape-tool"` (any spelling no other module writes); label "Shape"; it takes the retiring Schema tool's place in the toolbar and its S key.
- One file-wide service `TypeIndex` (exposed as `editor.types`), grown slice by slice: type notes and revisions; then links, instances, lineage, `affected(by:)`; then custom-shape definitions (builds-on and template come ONLY from the definition reading through `topology.children` and stand-ins; nothing else computes them). Never scans per frame; follows ChangeSets; reads nothing on a move.
- One style enum: `TypesStyle`.
- Opt-in sugar (declared by Types, called by the kinds): `typeWords(_ words: WritableKeyPath<Props, MentionText>, drawnIn:, fitting:)` (the kind-agnostic words contract, `TypeWords` point); `canBeType()` (opts into `schema`, requires typeWords); `typeable()` (opts into `is` and `fieldValues`, requires typeWords); `typeTemplate()` (opts into `behaviors`); `definesShapes()` (opts into `isShape`). StickyNotes (vertical) calls typeWords, canBeType, typeable, typeTemplate. Connections (concern, owns the arrow) calls typeWords, typeable, typeTemplate (Connections → Types). Frames (vertical) calls definesShapes.
- Confirm: the core's `editor.ask(CanvasQuestion, answer:)`; the host shows an NSAlert sheet. Never `editor.confirm`.
- Agent-visible names never say "class": the generic query-hint claim is `typeWord`, the declaration flag `namesTypes`.
- Step names: "Make Type", "Remove Type", "Add Type", "Update Schema", "Update Text", "Update Instances", "Read Fields", "Change <Field>", "New Shape", "New Shape from <title>", "New Shape from These", "Draft Type", "Turn into <title>", "Remove Shape".

## Module graph

- Types depends (at the end) on: Adornments, Canvas, ContextMenus, DetailPanel, LanguageModels, Mentions, Placing, ProseMaps, Publishing, Selection, SlashCommands, TableOfContents (only if used), Titles, Topology, Transform, Validation. The audit refuses a declared dependency nothing imports, so each slice adds only what it imports.
- Types never imports a vertical (StickyNotes, Frames, References, …), a language, or Connections. Arrow ends are read through Topology (`edges(carriedBy:)`, resolved through stand-ins). Reference pills are read through Topology's stand-ins, and made through `registry.standIns` makers (as draw does), never through References.
- Connections → Types and Mentions; StickyNotes → Types; Frames → Types; DrawLexicon → Types; QueryLexicon → Types; Composition, CompositionTests, BenchmarkTests → Types. No cycles (Types' closure never reaches Connections, StickyNotes, Frames or the lexicons).
- `$` keys: `$K` maps to the instance kind's property named K as `registry.schema(for:)` lists it (added properties included), written through `registry.shape(_:setting:)` (the path canvas draw uses), filtered at run time from the user's schema text, never from a literal. Excluded: JSON Schema's own `$` keywords (`$schema`, `$id`, `$ref`, `$defs`, `$anchor`, `$comment`, `$vocabulary`, `$dynamicRef`, `$dynamicAnchor`) and every property Types declares. `$type` is a read-only alias for `is` offered in completions and never written. A key the kind lacks, or a value that doesn't decode, is skipped.
- Behavior syntax in a type's or template's schema: a `$K` property with `{"default": v}` (a constant) or `{"x-canvas-from": "<field>"}` (from a field's value).
- Composition order: TypesPlugin (and its faces) after PublishingPlugin; TypeNamesPlugin / TypeQueriesPlugin beside their siblings; ShapesToolPlugin where SchemasPlugin was (toolbar: Note, Subboard, Frame, Shape, Reference).

## The chain

One level-order linearization, shared by settling and by `:is-a`: the instance's own value → the template → the instance's types, later first → the next level (each type's own types, and a custom shape's template then its builds-on, front first) → … → the primitive's default. Dedupe on first visit, guard cycles with a visited set. Fields: the first level naming a field supplies its whole subschema (nothing merged; `required` from that level). Override, never `allOf`.

## Retiring Schemas

Remove outright (no user data): the Schemas module and SchemasTests, the schema-card kind, its editor/skeleton/plugin, the `schema-link` channel and every test of it. Delete `Fixtures/kinds/schema-card.v0.json` and `v1.json` with the kind. Never touch `Fixtures/files/frames.v5.json`: its card is read as kept aside and the file must still write back byte for byte. Keep Titles' generic derived-title API (no shipped user afterwards; its removal is a separate cleanup). The prompt literals in SchemaPrompts.swift and ProseMapPrompt.swift stay byte for byte where the eval scripts parse them; only paths in the scripts change.

## Rules for every slice

- Work and commit only in your own clone (path given in your prompt). Never touch the session worktree, main, other clones, or other sessions' worktrees/branches. No `git push`. No `git stash`.
- Read CLAUDE.md (already in context) and the topic file of every area you touch before changing it; follow `docs/plugin-system.md` where they point.
- A change to a subsystem updates its topic file (and docs/plugin-system.md, and the canvas skill when draw/query/kinds/words/edge types change) in the SAME commit. A new module gets a `.claude/rules/<name>.md` with `paths:` and a line in CLAUDE.md's map. New `.claude/rules/types.md` (paths: `Sources/Types/**`, `Tests/TypesTests/**`, the lexicon files, `scripts/schema-prompts/**`, `scripts/field-prompts/**`) is created by the Types slice; later slices extend it.
- Tests: never touch the user's pasteboard (`NSPasteboard.withUniqueName()` / the plugin's private one), never use the app's socket (`temporarySocketPath()`), never reach the network (`model: ScriptedLanguageModel()`; live tests only behind their env flags, never set), close every `BoardDocument` you edit (`defer { close() }`), pass every new `Suite` to `runTests` in its `main.swift`.
- Sources compile in Swift 6 mode with `-warnings-as-errors`. `./build.sh audit` must pass. Before you finish, `./test.sh` must be green in your clone (use `TEST_FILTER=…` while iterating; run the full suite at the end). If the build says "this SDK is not supported by the compiler", prefix with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
- Never edit an existing fixture. Never regenerate the arrow proof-of-concept fixtures from the app.
- `./build.sh bench` budgets: never loosen one quietly; re-measure any whose subject changes, and say so.
- Never print, log or write the Anthropic API key.
- Commit messages: lead with why (the owner's intent: userland types and custom shapes, "Types and new shapes"; the decision that applies), then what; the repo's plain, dense voice (see `git log`); no process noise (reviews, clones, merges). End with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Several commits are fine.
