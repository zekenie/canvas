# Layers: where each module should live, in commits

A plan for the module graph. Each file here is one commit: the complaint it answers, why it's right, and what to do. They're numbered in the order to land them. This was planned in an environment without the Swift toolchain, so every plan ends with what to run on the Mac (`./build.sh audit`, `./test.sh`, the app).

## The findings, and where each went

| # | Finding | Verdict | Plan |
|---|---|---|---|
| 1 | `Reordering` isn't a vertical; maybe it's part of `Canvas` | It's a feature. Its restacking belongs in the core, and the Arrange menu stays a plugin | [01](01-charter-and-features.md), [02](02-restacking-in-the-core.md) |
| 2 | `JumpTo` is horizontal, not a vertical | A feature: horizontal in reach, a leaf in the graph | [01](01-charter-and-features.md) |
| 3 | `Moving` is horizontal, not a vertical | A feature (it imports no concern at all) | [01](01-charter-and-features.md) |
| — | *(found on the way)* `Snapping` is tagged concern with the same profile as Moving | A feature | [01](01-charter-and-features.md) |
| 4a | `InfiniteCanvas` belongs in `Canvas` | No: see "Considered and not planned" | — |
| 4b | A layer with one member is wrong | No: layers are roles with rules, and five have one member | [01](01-charter-and-features.md) writes each layer's reason |
| 4c | `HostSlots` should merge into `Canvas` | Yes, on different evidence than the spot check: its points are the core's. The most debatable plan, and independent of the rest | [06](06-host-slots-into-the-core.md) |
| 5 | `appex` needn't be its own layer | Right about its import rule; its packaging becomes a qualifier | [07](07-quick-look-in-the-app-layer.md) |
| 6 | Invert the lexicons so modules define their own words | Yes. Queries' points are already reachable. Draw's need the engine split out of Automation first | [03](03-query-words-to-their-owners.md), [04](04-draw-engine-out-of-automation.md), [05](05-draw-words-to-their-owners.md) |
| — | "I wish every layer had a raison d'être" | The charter: one question per layer, an import rule that follows from it, and a test the audit holds | [01](01-charter-and-features.md) |

## The layers after all seven

| Layer | Why it exists | Members after the plans |
|---|---|---|
| wire | What the app and `canvas` say to each other | CanvasRPC |
| foundation | What every plugin stands on and no plugin shapes | Canvas (with the host slots), Geometry, DrawScript, QueryLanguage, TextEditing, FuzzyMatching |
| ui | The window around the canvas | CanvasUI |
| surface | What other plugins build on or show themselves on; knows no concern | Keyboard, Selection, DetailPanel, ContextMenus, SlashCommands, TableOfContents, Adornments, LanguageModels, ProseMaps, Topology, Find, Queries, QueryTranslation, Neighbors, **Draw** |
| concern | A meaning shapes carry or kinds opt into | Validation, Clipboard, Titles, Locking, Publishing, Connections, Mentions, Boards, Transform |
| **feature** | A cross-cutting behavior nothing builds on | JumpTo, Moving, Reordering, Snapping |
| vertical | A shape kind | StickyNotes, Schemas, Subboards, Frames, References |
| language | Where an agent's request arrives over the wire | Automation, QueryCommands |
| app | The product's executables: the one place the list is composed | InfiniteCanvas, CanvasQuickLook (`app of InfiniteCanvas`) |
| cli | The command line, which knows only the wire | CanvasCLI |
| testsupport, test | as today | |

Gone: **lexicon** (QueryLexicon and DrawLexicon dissolve into the modules that own each word), **appex** (folded into app), and the **HostSlots** module (folded into Canvas). New: **feature**, and the **Draw** engine split out of Automation.

## Order

```
01 charter + feature layer ─┬─ 02 restacking in the core
                            ├─ 03 query words to their owners ─┐
                            ├─ 04 draw engine out of Automation ┴─ 05 draw words to their owners (lexicon layer gone)
                            ├─ 06 host slots into the core
                            └─ 07 Quick Look in the app layer
```

- **01 goes first**, because every other plan cites its charter, and it's cheap: retags, docs and audit checks, no code moved.
- **02** is small and self-contained.
- **03 before 05**, because 05 deletes the lexicon layer and needs QueryLexicon gone first. **04 before 05**, because draw's points have to leave the language layer before a concern can fill them.
- **06 and 07** are independent and can land any time after 01. 06 is the one with the most room for disagreement (its file says why).

## Rules the plans write down

1. **Each layer answers one question**, has an import rule that follows from it, and has a test the audit holds where it can (01).
2. **Invert a dependency only when more than one contributor is real.** A point with one contributor, made only so a module can change layer, is the wrong fix (01: why Jump To isn't a surface).
3. **The owner of a meaning gives its words to every language**, as a plugin value of its own, through the engine's points. When the owner sits below the engine, the engine's module gives it (03, 05).
4. **An engine any plugin may run is a surface; the command that speaks the wire is a language.** Queries / QueryCommands already split that way, and Draw / Automation will (04).
5. **A module splits from another only when something must build without the other, or a layer forbids an import the merged module would need** (06).

## Considered and not planned

- **`InfiniteCanvas` into `Canvas`.** It's the `@main` executable, 127 lines. It imports CanvasUI, which imports Canvas, so the move is a cycle. It's also the one place every plugin is linked in (`+ shipped`), which a module every plugin imports can't be. A thin main is the right shape for a composition root.
- **Folding the app layer into ui.** CanvasUI is a library that tests and the Quick Look extension import. `@main` and `+ shipped` have to be in an executable no one imports.
- **One-member layers.** Five layers have one member today (wire, ui, app, appex, cli), and three will after plan 07 (wire, ui, cli). That's fine: a layer is a set of rules (what it may import, `+ shipped`, `@_spi(Product)`), not a group that needs company. appex goes because its rules are the app's, not because it's alone. Plan 01 writes each layer's reason down.
- **Extracting Queries' points into a module of their own**, so a concern needn't import the engine. The point types are bound to the engine: internal initializers, and types only the engine builds (`QueryShape`, `QueryPreparation`, `ContributedPseudoClass`), so a split would mean exposing engine internals. Concerns may already import the engine, and build.sh recompiles a dependent only on an interface change. Plan 03 imports the engine.
- **Jump To as a surface with a `JumpTargets` point that Titles fills.** One contributor, made only to change a layer (rule 2). Find is a surface because three plugins fill its point.
- **Arrange as ContextMenus' own items**, like Delete and Select All. Those run Selection's commands, which every list with ContextMenus has. Arrange is something a list should be able to leave out (02).
- **Connections' arrow as a kind module of its own.** The charter allows a concern to own the one kind it's drawn as. Splitting it would force the welcome board (in StickyNotes) to make arrows without naming their kind, and arrows are pinned to tldraw parity. It's a separate question from the findings.
- **The core's `CanvasCommand` list** (`Sources/Canvas/Model/Identity.swift:90-125`: cut, undo, find, jumpTo, zoom…). It's the menu bar's vocabulary, which plugins handle. A host slot for menu-bar items would remove it, but no finding asked for that.
- **Merging QueryCommands into Automation.** Both are languages. Nothing in the findings asks for it.

## Each plan's shape

**Complaint** (the finding, in its words) · **Justification** (what the code and docs show, with file:line) · **Tactics** (code, `Package.swift`, `build.sh`, tests and docs, in order, including the topic files CLAUDE.md requires in the same commit) · **Verification** · **Risks and open questions** · **Not in this commit**.
