# 05 · Each concern gives `canvas draw` its own words; DrawLexicon and the lexicon layer go

**Commit title:** The plugins that own a meaning give canvas draw its words, as they give queries theirs: names from Titles, edges from Connections, checks from Validation, text from Mentions; DrawLexicon and the lexicon layer are gone

**Depends on:** 03 (QueryLexicon gone) and 04 (draw's points in a surface). It deletes the lexicon layer. Plans 06 and 07 also edit the layer docs, and may land before or after it.

## Complaint

Same as 03: let "modules define their own behavior instead of having these high level imports of everything."

## Justification

- **After 04, draw's points are a surface's (Draw), so concerns may fill them**, exactly as concerns could fill Queries' points once Queries was a surface (03). DrawLexicon then imports no language: its dependencies are Draw, Canvas, Connections, Mentions, Titles and Validation. That's the state QueryLexicon was in, and it has the same remedy.
- **Most of DrawLexicon is Connections' knowledge, kept somewhere else.** `PortEdgesPlugin` is 312 of DrawLexicon's 427 lines. About 230 of them are channel rules (`EdgeChannels`): which channel an edge between two shapes takes, built on about fifteen Connections APIs (`PortTable.swift:115, :119, :220, :231`, `ChannelProperty` at `Ports.swift:78`, `dotChannels`, `canConnect`, `connectionChannel`). Those rules belong beside the ports and channels they describe. Today a change to channels means editing two modules.
- **The other three are small and each reads one owner:**
  - `TitleNamesPlugin`, 28 lines, reads `registry.title(of:)`, `titleIsDerived` and `TitleProperty`;
  - `ValidationChecksPlugin`, 20 lines, reads `registry.validationIssues`;
  - `MentionTextsPlugin`, 67 lines, reads `MentionTextFormat.resolvingNames` and `registry.mentionAdmission`.
- **Each stays a plugin value of its own, in its owner's module,** as Find's contributors are (`TitleFindPlugin`, `MentionFindPlugin`, `ArrowFindPlugin`). The registry refuses a contribution whose point's owner isn't installed. If Titles' own plugin filled `DrawNames`, a list with Titles and no Draw engine would be refused. As a separate value, a list without Draw just leaves it out, and a list without a concern leaves its words out, which is what the lexicon's plugin values gave.
- **With both lexicons gone, the lexicon layer is empty, and its rule changes shape.**
  - Before: "only a lexicon joins a language to concerns".
  - After: a language still imports no concern (still enforced, and still why AutomationTests and QueriesTests can fill the points with fixtures), and a concern fills the engine's points (rule 3 in the index). No module joins two others any more.
- **The APIs made public only for a lexicon can go back to internal.** That's the encapsulation the hub was costing (deferred from 03, so one sweep covers both).

## Tactics

1. **Move the files.** Each keeps its plugin's type name and id: `title-names`, `port-edges`, `validation-checks` and `mention-texts`, which only the registry report's copies (`ShippedTests.swift:143-146`, the guide) and MentionTextsTests write.
   - `Sources/DrawLexicon/TitleNames.swift` → `Sources/Titles/`
   - `PortEdges.swift` → `Sources/Connections/`
   - `ValidationChecks.swift` → `Sources/Validation/`
   - `MentionTexts.swift` → `Sources/Mentions/`

   Drop each file's self-import and delete `Sources/DrawLexicon`.
2. **`Package.swift`:**
   - Titles, Connections, Validation and Mentions each add `Draw`, plus DrawScript or Geometry where a moved file names their types directly (check `PortEdges.swift`). Delete the DrawLexicon target.
   - The ships table: `"DrawLexicon.TitleNamesPlugin"` → `"Titles.TitleNamesPlugin"`, then `"Connections.PortEdgesPlugin"`, `"Validation.ValidationChecksPlugin"`, `"Mentions.MentionTextsPlugin"`. Same positions, after `"Draw.DrawPlugin"`. Rewrite the comment (`:157-159`).
   - The header: delete the lexicon row, and rewrite the paragraph "only a lexicon joins modules, and only a language to concerns" as rule 3.
3. **`build.sh`:**
   - Remove `lexicon` from `MAY_USE` (its own row, and the `test` row's list), from `PLUGIN_LAYER`, and from the die message at `:135`.
   - Rewrite the comment at `:25-26` ("only a lexicon joins a language to the concerns its words are about").
   - `grep -n lexicon build.sh` for any message left.
   - Afterwards a target tagged `lexicon` fails as an unknown layer.
4. **Tests:**
   - Retag: TitleNamesTests `test of DrawLexicon` → `test of Titles`, PortEdgesTests → `test of Connections`, ValidationChecksTests → `test of Validation`, MentionTextsTests → `test of Mentions`.
   - Their helpers already call Draw's entry points (plan 04). Drop `DrawLexicon` from their dependencies. Every remaining dependency must sit inside the new owner's closure, and the audit checks it.
   - `import DrawLexicon` → the owner, if it isn't imported already.
5. **Narrowing sweep.** Take every symbol a moved file from 03 or 05 reads from its owner. Make it `internal` if, after both moves, nothing outside the owner uses it.
   - Check with grep over `Sources` and `Tests`. Tests reach only public API, since `@testable` is banned, so a symbol any test uses stays public.
   - Candidates: `registry.titleIsDerived`, `TitleProperty.folded`, Validation's `cachedResult(for:)`, `MentionText.plainText`, `MentionTextFormat.resolvingNames`, `registry.mentionAdmission`, and the Connections APIs `PortEdges` reads.
   - Draw's own API (`drawCanName` and the point sugar) stays public. It's how concerns fill the points.
6. **Docs:**
   - `.claude/rules/build.md`, "Layers": lexicons and their import lists go, and rule 3 replaces the paragraph on what a lexicon is.
   - `docs/plugin-system.md`:
     - "Horizontal and vertical": the lexicon bullet becomes rule 3, and "No module joins two others but a lexicon" becomes "No module joins two others".
     - "The module graph": the example target line at `:505` is DrawLexicon's, so use another module's. The table's lexicon row goes. In the audit list, "only a lexicon joins a language to concerns" becomes "a language can't import a concern, nor a concern a language: a concern fills the engine's points".
     - The command line's description of draw's words (around `:8934` and `:9462-9475`).
   - `CLAUDE.md`, the module-graph rule:
     - drop "lexicons use surfaces, concerns and languages" from the layer list;
     - "No module joins two others but a lexicon" → "No module joins two others".

     The map's Languages section no longer mentions a lexicon.
   - `.claude/rules/command-line.md` and `mentions.md`: their `paths:` frontmatter names DrawLexicon files. Point it at the moved files, so the topics still load for them.
   - `validation.md`, `titles.md`, `connections.md` and `mentions.md`: one line each for the draw word the module now gives.
   - `README.md`, if it lists DrawLexicon.
   - **The canvas skill does not change.** The words are the same.

## Verification

- `./build.sh audit`. Then tag a module `lexicon` and see "unknown layer". Make Titles import Automation and see the language refusal. Put both back.
- The four retagged targets, run as the executables test.sh builds (`build/debug/TitleNamesTests/TitleNamesTests`, `PortEdgesTests`, `ValidationChecksTests`, `MentionTextsTests`). `TEST_FILTER` matches suite and test names, not targets.
- Then a full `./test.sh`. Hold particularly:
  - CommandLineTests and SkillTests: draw's output is unchanged.
  - ShippedTests and the guide's report: unchanged, since ids and contributions are the same.
- In the app: `build/canvas draw` with a named note (a title), an edge between two notes on their channel, a schema card that's invalid (its warning), and a note whose text says `@[Title]` (a mention). Each answers as before.

## Risks and open questions

- **Connections grows** by about 312 lines and gains the draw engine. Its closure gains only Draw itself: it already reaches Adornments (through Publishing) and DrawScript, Queries, QueryLanguage and Topology (through Neighbors). That's in proportion: the rules were Connections' anyway.
- **The narrowing sweep can make a test stop compiling**, if a test used an API through a path the grep missed. The compiler finds it, and the answer is to keep that symbol public.

## Not in this commit

- Any new draw word or query word: this commit only moves who gives them.
