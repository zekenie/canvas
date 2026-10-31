# Plan

What gets built, one component at a time. Each one has what a person sees (frames drawn from the prototype's real boards and answers), the code behind it (each interface marked exists or new, with its module), its keys and its tests. Landings come last.

## What the API research changed

- **File-wide.** Checks run over the whole file, the board shown first. `:warned` and draw read the whole file, so a check limited to the board shown would read as a false clean.
- **A Rules tab.** Rules get a tab of their own beside Schema. Placed under the JSON, they'd sit below a box as tall as the schema.
- **`$rules` held aside.** The rules stay in the type's schema, but Types must hold them as it holds `$color`. Otherwise the model that keeps a type's words and schema in step is sent the rules, and may rewrite or drop them. Types gains one generic point for that.
- **Waiting.** `canvas query ':warned'` doesn't wait today: only edge words wait for settling. Validation's words learn to.
- **`:scope`.** The query engine owns `:scope`, bound per request, so every chip of every shape runs in one batch.

## 1 · Decision models (F11)
A new engine beside LanguageModels: state in, yes/no probabilities out. Jev ships; a Haiku adapter proves the seam.
| Interface | What | |
| `DecisionModel.decide(_:) async throws -> DecisionAnswers` | the one call | new · DecisionModels |
| `JevModel(keys:)` | POST /v1/systemone, each question a `noul` | new |
| `LanguageDecisionModel(model:)` | Haiku 5.5 answers in words | new |
| `ScriptedDecisionModel` | tests' answers, held or released | new |
| `DecisionModelsPlugin: OutwardPlugin`, `editor.decisionModel` | handed to the list as LanguageModels is | new |
| `registrar.settingsPane("TypeSafe")` | the key pane | exists |
| `TypeSafeKeyStore`, `.decisionModelKeyDidChange` | 0600 file; checks retry | new |
| `DecisionCutoffs(flag: 0.7, holds: 0.3)` | a provider's cutoffs, set by the eval | new |
Tests: a URLProtocol stub for Jev; `ShippedPlugins` gets a scripted model by default (260 call sites keep compiling); ShippedTests' outward list and panes.

## 2 · Where a rule is kept
`"$rules": {"const": [{"says": "…", "find": [{"phrase": "…", "query": "…"}]}]}` in the type's schema. It copies with the type; draw writes it.
| `registrar.typeDirective("rules")` | Types holds another plugin's directive aside: never sent to the sync, carried across a schema written whole, no change to the type's fields | new · Types |
| `RuleBook.rules(of:)`, `chain(for:)` | a type's rules; a shape's, most general first, by `types.lineage(of:)` | new · LanguageRules |
| `editor.ruleWriter.setRules(_:of:)` | one step, "Change Rules" | new |
Tests: a type's sync never sees `$rules`; draw's `schema:` keeps it; Remove Type takes it with the schema.

## 3 · What a rule sees (F10)
| `RuleContext.build(for:in:)` | the state under its labels, shrunk past a budget; its hash and footprint | new · LanguageRules |
| `topology.snapshot(.resolved)`: `shape`, `parent`, `children`, `edges(of:)`, `edges(carriedBy:)` | one step around, through pills | exists · Topology |
Tests: each label from a board in a test (a note, an arrow, a frame's child, a pill); shrinking; the hash moves only when what's sent moves.

## 4 · The checks (F9)
| `RuleChecks` (`EditorService`): `documentDidChange`, `topology.follow` | marks dirty by footprint, by a type's rules, chips on any commit that isn't a move | new |
| `editor.scheduler` | waits for quiet: editing ends, or 3 s | exists |
| `queries.matches([QueryMatchRequest(text, scope:)])` | every chip of every dirty shape in one batch | exists, `scope:` new |
| `RuleVerdictCache` | answers by (model version, rules, hash), in memory and a file in Application Support | new |
| `scope.validate(ignoringMoves: true)` | a warning per rule that flags, less the ignored | exists · Validation |
| `validation.recheck(ids)` | when answers land | exists |
| `topology.keepsSettling { busy }` | the command line can wait | exists |
Budget: a commit on a 10,000-shape board with 1,000 checked shapes marks dirty in O(what changed); nothing per frame. Quick Look asks nothing.

## 5 · A type's Rules tab (F1)
| `RulesTab: DetailTab`, `.after(TypeSchemaTab.self)` | on every shape that holds a schema | new · LanguageRules |
| `DetailTextArea(…, coloring:)` | a sentence, its chips drawn as chips | coloring new · DetailPanel |
| count button: `editor.select`, outlines | selects what a rule flags; highlighted, lights it | exists |
| `DetailStatusLine(…, actions: [Open Settings…])` | nothing can be checked | exists |
Keys: Tab walks sentence, chip, count; Return on a count selects; on an inherited rule, goes to its type. VoiceOver: "Rule, The description mentions no damage or wear., flags 5".

## 6 · Chips (F2, F3)
| `queryTranslator.translate(_:about: .rule)` | the phrase in English to a query; teaches `:scope` | `.rule` new · QueryTranslation |
| `:scope`, `:scope-start`, `:scope-end` | bound per request | new · Queries |
| `checkStored(_:binding: .scope)` | a stored chip is checked as written | binding new |
| `DetailCodeEditor(…, completions:)` | the query edited by hand | exists |
Tests: QueryPromptTests (the ask prompt teaches the words); SkillTests (the query reference lists them).

## 7 · A flagged shape (F5–F8)
| ring, dot, Issues line | Validation's | exists |
| `ValidationIssue.actions` → `DetailStatusLine(actions:)` | Ignore, Show Rule | new · Validation |
| `DetailSection(…, in: IssuesTab.self, id: "rules")` | the rules read together, each with its state; Shown | new section, point exists |
| `DetailRowList(onHighlight:)`, `registrar.outlines` | a group highlighted lights its shapes | exists |
| Show Rule: `editor.selection = type`, `detailPanel.choose(.of(RulesTab.self))` | | exists |

## 8 · Ignore (F6)
| `IgnoredRulesProperty` (`ignoredRules`) | the sentences ignored; lapses when one changes | new · fixture |
| `note.checkedByRules()`, `arrow.checkedByRules()` | the kinds opt in | new |
One step, "Ignore Rule"; Stop Ignoring in the rules section.

## 9 · Agents (F12, F13)
| draw's `schema:` | writes `$rules` | exists |
| `registrar.drawChecks` | a chip's query checked as drawn | new contribution |
| `:warned` and row `problems` | the sentence as the problem's message | exists |
| Validation's words wait while checks settle | | new · Queries, Validation |
| `canvas decide <query> "<question>"` | one yes/no of many shapes; nothing stored | new · DecisionCommands |
The canvas skill says all of it (SkillTests).

## 10 · Rules on the type's note (F4) — your pick
A on the note: a new Types point at the foot of a type's rows (layout, drawing, faces, ⌥Tab parts, skeleton bars, a relationship type's card). B a chip by the pill: nothing new but the chip.

## Landings
1. Decision models, and the TypeSafe pane.
2. Rules checked: Types' held directive, the book, the context, the checks and their cache, the warning, `:warned` waiting. Rules are written by draw and in the JSON.
3. The panel: the Rules tab, the Issues section with Shown, issue actions, Ignore.
4. Chips: `:scope`, the translator's `.rule`, the chip in the tab, draw's check.
5. Agents: `canvas decide`, the skill.
6. Rules on the type's note (A or B).
Each lands with its tests, key walks, and the live eval for the prompt it changes.
