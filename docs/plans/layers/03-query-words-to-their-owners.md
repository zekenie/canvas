# 03 · Each concern gives queries its own words; QueryLexicon goes

**Commit title:** The plugins that own a meaning give queries its words: titles, boards' names, mentions and validity from their own modules, the selection's from the engine's, and QueryLexicon is gone

**Depends on:** 01 (the charter this edits). **Unblocks:** 05, which deletes the lexicon layer once DrawLexicon goes too.

## Complaint

"Wondering if we should have dependency inversion around `QueryLexicon` and `DrawLexicon` so that modules can define their own behavior instead of having these high level imports of everything."

## Justification

- **The inversion already exists. What's centralised is who fills the points.**
  - `Queries` (the engine) declares its points: `QueryNames`, `QueryBoardNames`, `QueryWords` and `QueryTextFormats` (`Sources/Queries/QueryPoints.swift:36, :62, :263, :327`). It knows no concern.
  - `QueryLexicon` is one module that imports Boards, Mentions, Titles, Validation, Selection, Topology and Queries, and fills all of those points.
- **QueryLexicon was structurally needed when it was written, and isn't now.**
  - At the clone's oldest commit (`cff699a`) `Queries` was a language, and concerns may not import a language.
  - `e1127f8` relayered Queries to surface ("whose imports were already only foundation and surface modules"). Concerns may import surfaces, so since then Titles, Boards, Mentions and Validation could fill the points themselves. No layer rule stops them.
  - QueryLexicon imports no language at all, so it no longer joins a language to concerns, which is the lexicon layer's one stated job.
- **The docs admit this.**
  - `.claude/rules/build.md:43`: "any concern may now contribute a query word directly, which the convention, words for a concern through QueryLexicon, leaves to the lexicon, and the audit does not yet enforce".
  - `docs/plugin-system.md:7067`: "words for a concern still come through QueryLexicon, by convention, though the layers don't forbid a concern contributing one".
- **The pattern is already shipped.**
  - `Connections.ArrowLightsPlugin` and `Mentions.MentionLightsPlugin` live in their concern modules and write queries into Neighbors' point. Neighbors is a surface that imports Queries.
  - A face a list should be able to leave out is a plugin value in its owner's module: `TitleValidationPlugin`, `MentionFindPlugin`, `ValidationDetailsPlugin`. The query words are the same kind of face.
- **Every reason the docs give for the lexicon survives the move, except one with no stated basis:**

  | Reason given | After the move |
  |---|---|
  | "a language that knew a concern couldn't be tested with fixtures in its place" | **Kept.** Queries still imports no concern, and QueriesTests keep their fixture words. |
  | "a list without a concern leaves its words out" | **Kept.** Each word stays its own plugin value (`TitleQueriesPlugin` in Titles), and leaving it out is deleting its line. |
  | "the one place a language and the concerns meet" | Describes the module, and goes with it. For queries it was already untrue: no language is involved. |
  | concerns "know no language" / "nor any of them of queries" | Lost for queries. No reason for it is given anywhere, and for queries it isn't even a layer rule, since Queries is a surface. |

- **What the hub costs:** every new concern with a query word edits QueryLexicon and adds another import to it. The words for Titles sit away from Titles' code. And the APIs the words read (`registry.titleIsDerived`, `TitleProperty.folded`, Validation's `cachedResult`, `MentionText.plainText`…) have to be public only so another module can reach them.

**Where the selection's word goes.** Selection is a surface, and *below* Queries: Queries may import Selection with no cycle (Selection → Keyboard → Canvas), but Selection importing Queries would put the engine under 16 modules (measured). The rule is the one the guide already gives: an edge between two modules goes "from the module that owns a meaning to the one it builds on". The higher module, the one that knows both sides, holds the join. So `SelectionQueriesPlugin` moves into Queries, as a plugin value of its own, which a list can still leave out. This adds Selection and Keyboard to Queries' closure. Every concern that will import Queries already reaches Selection (Titles through Adornments, Validation through DetailPanel, Boards and Mentions directly). The only module that newly reaches Selection is QueryTranslation.

**The rule this commit writes into the charter:**

> A word in a language is given by the module that owns its meaning, as a plugin value of its own, through the engine's points. When the owner sits below the engine, the engine's module gives it.

## Tactics

1. **Move the files.** Each keeps its plugin's type name and id, so registry report lines and ids don't change.
   - `Sources/QueryLexicon/TitleQueries.swift` → `Sources/Titles/TitleQueries.swift`
   - `BoardQueries.swift` → `Sources/Boards/`
   - `MentionQueries.swift` → `Sources/Mentions/`
   - `ValidationQueries.swift` → `Sources/Validation/`
   - `SelectionQueries.swift` → `Sources/Queries/`

   In each, drop the now-self import (`import Titles` inside Titles, `import Queries` inside Queries). Delete `Sources/QueryLexicon`.
2. **`Package.swift`, dependencies:**
   - Titles adds `Queries`.
   - Boards adds `Queries`.
   - Validation adds `Queries`.
   - Mentions adds `Queries`. It reaches Queries through Neighbors, but the audit wants every import declared. It already declares `Topology`.
   - Queries adds `Selection`.
   - Add `QueryLanguage` wherever a moved file uses its types directly. Check each file's types: `TitleQueries` and `MentionQueries` are the likely ones.
   - Delete the `QueryLexicon` target.
3. **`Package.swift`, the `ships` table:**
   - `"QueryLexicon.TitleQueriesPlugin"` → `"Titles.TitleQueriesPlugin"`, and likewise `Boards.`, `Mentions.`, `Validation.`, `Queries.SelectionQueriesPlugin`.
   - Same positions: still after `Queries.QueriesPlugin`, whose point they fill (the registry refuses a contribution whose point's owner isn't installed).
   - Rewrite the table's comment ("what queries take from the plugins that own a concern…") to say each owner gives its words.
4. **Test targets:**
   - Change `// layer: test of QueryLexicon` to `test of Titles`, `test of Boards`, `test of Mentions`, `test of Validation` and `test of Queries` (SelectionQueriesTests).
   - Drop `QueryLexicon` from each test's dependencies. Each remaining dependency is inside its new owner's closure (checked: e.g. TitleQueriesTests' Adornments, Keyboard, Selection, SlashCommands, Topology and QueryLanguage all sit under Titles once Titles imports Queries).
   - In each test's sources: `import QueryLexicon` → the owner module, if it isn't imported already.
5. **Sources, comments only:**
   - `Sources/Queries/QueryPoints.swift:5` ("each an extension point filled by QueryLexicon") and `:348` ("Sugar (what QueryLexicon writes)").
   - `Sources/Queries/Queries.swift`.
   - `Tests/BenchmarkTests/QueryBenchmarks.swift:729`.
6. **Docs:**
   - `.claude/rules/queries.md`:
     - the points sentence ("Its points, each filled by QueryLexicon");
     - the shipped-list sentence ("(QueryLexicon's)");
     - the Testing paragraph ("QueryLexicon's tests use fixtures only" → each owner's).
   - `.claude/rules/titles.md`, `boards.md`, `mentions.md` and `validation.md`: one line each, for the word the module now gives. Also `selection.md`, if it names `SelectionQueriesPlugin`; otherwise `queries.md` covers it.
   - `.claude/rules/build.md`, "Layers": QueryLexicon leaves the lexicon list and Queries' import list. Replace the "any concern may now contribute… the audit does not yet enforce" sentence with the rule above.
   - `docs/plugin-system.md`:
     - "Horizontal and vertical": the lexicon bullet and the surface bullet's "still come through QueryLexicon";
     - the module-graph table's lexicon row (DrawLexicon only, until 05);
     - "What plugins add" (`:7067`);
     - the Queries section.
   - `CLAUDE.md`: the map's queries line ("the lexicon's words" → "the words their owners give").
   - `Package.swift`'s header: the lexicon row names DrawLexicon only.
   - `README.md`, if its module list names QueryLexicon.
   - Not the canvas skill. No word, kind or edge type changes, so SkillTests and QueryPromptTests hold as they are.

## Verification

- `./build.sh audit` (the import check holds the new dependencies both ways).
- `TEST_FILTER=Queries ./test.sh`, which catches the five moved test targets, QueriesTests and QueryCommandsTests.
- Then a full `./test.sh`. CompositionTests' QueryShippedTests and QueryPromptTests must pass unchanged, since the shipped vocabulary is identical. So must ShippedTests' registry report and the guide's copy of it (`Tests/CompositionTests/ShippedTests.swift`, "the guide shows the registry report as it is"). The report lists plugins by id and contribution, never by module, and both are unchanged.
- In the app, with `canvas query ':selected'`, `canvas query '"Checkout"'` and `canvas query ':invalid'`: same answers as before.

## Risks and open questions

- **Closure growth:** Titles gains three modules (Queries, DrawScript, QueryLanguage), which every module above Titles now compiles against. Validation gains four (those plus Topology). build.sh recompiles a dependent only when a dependency's `.swiftmodule` changes. Queries' interface has changed in 2 of the last 50 commits.
- **Narrowing APIs** made public only for the lexicon is deferred to plan 05, so one sweep covers both lexicons.

## Not in this commit

- DrawLexicon: its points live in a language, and those come first in plan 04.
- Removing the lexicon layer from build.sh: plan 05, when it's empty.
