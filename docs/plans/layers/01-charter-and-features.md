# 01 · Why each layer exists, and a layer for features

**Commit title:** Every layer says why it exists and how to tell a module belongs there; Jump To, Moving, Reordering and Snapping are features, and a vertical is a kind

**Depends on:** nothing. **Unblocks:** every later plan cites the charter this one lands.

## Complaint

- `reordering`, `jumpTo` and `moving` sit in the vertical layer, but none of them is a kind. All three are cross-cutting: they work on every shape and no kind opts in.
- Nothing documented can settle where a module belongs. The `Package.swift` header gives each layer a one-liner, and several of those one-liners are lists of current members ("the keys, the selection, the panel, menus…"). A list can't decide a new case.

## Justification

What the code shows (checked against `Package.swift`, the sources and the docs):

- **Vertical has three working definitions, and they disagree:**
  - "the kinds", the CLAUDE.md map heading ("**Verticals** (the kinds)");
  - "a feature (shape kinds, tools)", the `Package.swift` header;
  - "a feature no kind opts into and nothing imports", which `Package.swift` gives at the JumpTo and Moving lines as the reason they're verticals, and which jump-to.md, moving.md and both modules' headers repeat.

  The guide stretched its own definition to take Reordering: "a shape kind and the tool that places it, *or what every kind with a capability gets (Reordering's Arrange menu)*" (`docs/plugin-system.md:362`).
- **What the audit actually enforces for vertical is "a leaf":** it may import surfaces and concerns, and no plugin layer may import it. That's all the rule says.
- **In practice, a feature's layer is decided by which way its imports point, not by what it is:**
  - Find (⌘F) is a surface, because Titles, Mentions and Connections fill its `FindableTexts` point.
  - Jump To (⌘K) is the same sort of palette, but it reaches into Titles and Boards itself, so it lands in vertical.
  - Moving imports no concern at all, only foundation plus SlashCommands and TableOfContents (`Package.swift:251`), and is a vertical.
  - Snapping has Moving's profile exactly (no extension point, no property, no kind, nothing imports it, applies by capability) and is a **concern** (`Package.swift:228`). Its topic file gives no reason: "a concern on the core alone".
- **The four have the same measured profile:** no `ShapeKind`, no `ExtensionPoint`, no `PropertyKey`, and no importer but their own tests. Every module tagged concern declares an extension point or a shape property, except Snapping. Every module tagged surface declares an extension point or is imported by another plugin module. Every kind declares a `ShapeKind`. So the tests below split today's modules cleanly, with only those four out of place.

Without a test, the next cross-cutting feature (a minimap toggle, an export command, a presenter mode) has no right answer. It goes wherever its imports happen to let it.

## The charter

Each layer answers one question. Its import rule follows from that answer, and it has a test a reviewer can apply, which the audit holds where it can. This commit writes the charter for the layers as they stand after it. Plans 05 and 07 delete `lexicon` and `appex` and edit the charter as they do.

| Layer | Why it exists (the question it answers) | May use | The test |
|---|---|---|---|
| wire | What the app and its command line say to each other, so `canvas` builds without the app | wire | imports nothing but the wire (held today) |
| foundation | What every plugin stands on and no plugin shapes: the core, its host contract, and pure libraries | foundation, wire | knows no plugin (held today) |
| ui | The window around the canvas, so no plugin reaches the window and the window reaches no plugin | foundation, wire | — |
| surface | Something other plugins build on or show themselves on; it knows no concern, so anything can appear on it without it knowing | foundation, surface | **declares an extension point, or another plugin module imports it** |
| concern | A meaning shapes carry or kinds opt into (a property on shapes, or a point kinds fill), shown on surfaces | foundation, surface, concern | **declares an extension point or a shape property (`PropertyKey`)** |
| **feature** (new) | A cross-cutting behavior the person uses (a palette, a command, a gesture) that nothing builds on. It is horizontal in reach and a leaf in the graph | foundation, surface, concern | **declares no `ShapeKind`, no extension point and no `PropertyKey`; no module imports it** |
| vertical | A shape kind: its props, definition, tool, and its opt-ins to concerns. Kinds never know each other | foundation, surface, concern | **declares a `ShapeKind`; no module imports it** |
| language | Where an agent's request arrives over the wire and is answered; the only plugin layer that speaks the wire | foundation, surface, language, wire | knows no concern (held today) |
| lexicon | *(until plan 05)* a language's words for the concerns | foundation, surface, concern, language | — |
| app | The product's executable: the one place the shipped list is composed, which no module imports | foundation, ui, wire | `+ shipped`, `@_spi(Product)`, names no plugin (held today) |
| appex | *(until plan 07)* the Quick Look extension | foundation, ui | — |
| cli | The command line, which knows only the wire | wire | (held today) |
| testsupport, test | as today | | |

**Placing a new module** (written into the guide):

1. Is it an executable? Then app, cli or test.
2. Does it know no plugin? Then foundation (or wire, or ui).
3. Does it define a shape kind? Then vertical. A concern may own the one kind it is drawn as (Connections' arrow).
4. Does it speak the wire? Then language.
5. Does it give shapes a meaning, a property they carry or a point kinds fill? Then concern.
6. Does something build on it, through its points or by importing it? Then surface, and it must know no concern.
7. Otherwise, feature.

**Two rules that go with it:**

- **Invert only when more than one contributor is real.** Declare a point that concerns fill (as Find does) when more than one plugin genuinely fills it. A point with one contributor, made only so a module can change layer, is the wrong fix. That's why Jump To becomes a feature here instead of a surface with a `JumpTargets` point.
- **The audit's tests are necessary, not sufficient.** A module can pass both the surface and concern tests. Which layer it gets is then decided by the question each layer answers, and the test only refuses an obvious misfit.

## Tactics

1. **`Package.swift`:**
   - Retag four lines: `JumpTo`, `Moving`, `Snapping` and `Reordering` become `// layer: feature`.
   - Rewrite the comments above the JumpTo and Moving lines (drop "as Reordering is one: a vertical").
   - Rewrite the header's layer list (`:13-56`) as the charter's "why it exists" and "test" columns, in the existing one-line-per-layer form. Keep the parseable target lines untouched.
   - The `ships` table doesn't change: no plugin moves module and the order is the same.
2. **`build.sh`:**
   - `MAY_USE`: add `feature "foundation surface concern"`, and add `feature` to the `test` list.
   - `PLUGIN_LAYER`: add `feature`.
   - The die message at `:135`: list feature among the plugin layers.
   - **New audit checks**, after the import check, over each module's non-test sources. Reuse the `ID_DECL` scan (`:519`), which already finds declared `ShapeKind` and `PropertyKey` ids per module, plus a new scan for `ExtensionPoint`/`KeyedExtensionPoint` conformances (`(enum|struct) X: …ExtensionPoint` or `extension X: …ExtensionPoint`):
     - vertical: declares at least one `ShapeKind`, or fail with "a vertical is a kind: <M> declares none; a cross-cutting behavior is a feature".
     - feature: declares no `ShapeKind`, no extension point and no `PropertyKey`, or fail naming the one found and the layer it points to (kind → vertical, point → surface or concern, property → concern).
     - concern: declares an extension point or a `PropertyKey`, or fail with "a concern gives shapes a meaning; <M> declares neither: is it a feature?".
     - surface: declares an extension point or is a dependency of another plugin module, or fail with "nothing builds on <M>: is it a feature?".
     - "No module imports a feature" needs no new check: no layer but test lists `feature` in `MAY_USE`.
3. **Sources:** update the header comments that call these modules verticals or concerns. JumpTo is `Sources/JumpTo/JumpTo.swift:10`, Moving is `Sources/Moving/Moving.swift:15-17`, Reordering's is `Examples/Reordering/Reordering.swift:11-14`, and Snapping's header is in `Sources/Snapping/`. No code changes.
4. **Docs.** Each subsystem's topic file goes in the same commit, per CLAUDE.md.
   - `docs/plugin-system.md`:
     - "Horizontal and vertical" (`:360-485`): a vertical is a kind. Add a "Features" paragraph: horizontal in reach, a leaf in the graph, the four modules, why Jump To isn't a surface (the one-contributor rule).
     - "The module graph" table (`:513-526`): add the feature row, add a "why it exists" column, and change the vertical row's module list.
     - The audit list: add the four layer tests.
     - "Placing a new module": the seven questions above, as a short subsection.
   - `.claude/rules/build.md`, "Layers": add features, drop the "a feature no kind opts into and nothing imports" phrasing from the vertical list, add the four tests to the audit bullet.
   - `CLAUDE.md`:
     - The module-graph rule bullet: add "features use surfaces and concerns, and nothing imports one".
     - The map: add a **Features** heading with jump-to, moving and snapping. Move Snapping's line out of Concerns and Jump To's and Moving's out of Verticals. Reordering's pointer, in the sticky-notes line, moves under Features.
   - `.claude/rules/jump-to.md`, `moving.md` and `snapping.md`: their opening lines ("a vertical…", "a concern on the core alone").
   - `.claude/rules/context-menus.md`: nothing; it doesn't name Reordering's layer.

## Verification

- `./build.sh audit` passes. Then deliberately retag one module of each kind and see the right refusal:
  - Moving as `vertical` fails the kind test.
  - Schemas as `feature` fails the feature test.
  - Snapping back to `concern` fails the concern test.

  Put them back.
- `./test.sh` passes unchanged. No code moved, and the four test targets' rules don't depend on the layer: `JumpToTests` and `MovingTests` are `<M>Tests`, which the M rule constrains whatever M's layer.

## Risks and open questions

- **The name `feature`.** The docs already use the phrase "a feature no kind opts into", so it reuses the project's own word. The alternatives considered, "behavior" and "command", are narrower than what's in the layer.
- **Detecting extension points by text** mirrors how the id check already works, and fails safe: a missed conformance makes the audit refuse, never pass. If a point is ever declared through a typealias or a macro, the scan needs to learn that form.

## Not in this commit

- Moving Reordering's restacking into the core is plan 02.
- The lexicon and appex layers are plans 03–05 and 07.
- Connections' arrow, a kind owned by a concern, stays as documented: the charter's question 3 allows it.
