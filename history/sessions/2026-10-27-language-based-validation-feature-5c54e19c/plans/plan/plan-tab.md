# Plan

What gets built, one component at a time. Each one shows what a person sees, in frames drawn from the prototype's real boards and answers. Under each frame, a table names the code behind every numbered mark, marked **exists** or **new** with its module. Landings come last.

## What the API research changed

- **File-wide.** Checks run over the whole file, the board shown first. `:warned` and draw read the whole file, so checking only the board shown would read as a false clean elsewhere.
- **A Rules tab.** Rules get a tab beside Schema. Under the JSON they'd sit below a box as tall as the schema.
- **`$rules` held aside.** Rules stay in the type's schema, but Types must hold them as it holds `$color`. Otherwise the model that keeps a type's words and schema in step is sent the rules and may rewrite or drop them. Types gains one generic point for this.
- **`:warned` says the rule and waits.** Today `:warned` rows carry no problems, and only queries that read edges wait for settling. Validation's words learn both.
- **`:scope` is the engine's word.** It is bound per request, so every chip of every shape runs in one batch.

## 1 · A type's Rules tab

[[F1]]

A tab on every type, a relationship type's too: its own sentences, each editable, with the count of shapes it flags beside it. The count selects them, and highlighting it lights them. Inherited rules come after, dimmed, with "from Car". `add rule` is last, and a status line appears when nothing can be checked.

| Interface | What it does | |
|---|---|---|
| `RulesTab: DetailTab`, `order: .after(TypeSchemaTab.self)` | the tab, on every shape that holds a schema | new · LanguageRules |
| `DetailTextArea(…, coloring:)` | a sentence, its chips drawn as chips | new argument · DetailPanel |
| `editor.ruleWriter.setRules(_:of:)` | writes `$rules`, one step "Change Rules" | new · LanguageRules |
| `RuleChecks.flagged(by:)` | the count beside a rule | new · LanguageRules |
| `editor.goTo(ids)` | the count selects what the rule flags | exists · Selection |
| `registrar.outlines { … TintedOutlines … }` | a highlighted count lights its shapes | exists · Canvas |
| `DetailStatusLine(_:isBusy:actions:)` | "Not checked" with Open Settings… or Retry | exists · DetailPanel |

**Keys.** Tab and ⇧Tab walk sentence, chip and count in reading order. Return on a count selects its shapes, and on an inherited rule goes to its type. VoiceOver reads a rule as "Rule, The description mentions no damage or wear., flags 5".

## 2 · Chips: a phrase that finds

[[F2]]

[[F3]]

A phrase in brackets is a query. It's written in English and translated as a reference pill's words are. The line under the rule shows the query and what it finds, for one shape when it uses `:scope`. Highlighting the line lights what it finds.

| Interface | What it does | |
|---|---|---|
| `queryTranslator.translate(_:about: .rule)` | the phrase to a query; the prompt teaches `:scope` | `.rule` new · QueryTranslation |
| `:scope`, `:scope-start`, `:scope-end` | the shape checked, and an arrow's ends | new · Queries |
| `QueryMatchRequest(text, scope:)`, `queries.matches([…])` | every chip of every shape in one batch | `scope:` new · Queries |
| `checkStored(_:binding: .scope)` | a stored chip checked as written | `binding:` new · Queries |
| `DetailCodeEditor(…, completions:)` | the query edited by hand | exists · DetailPanel |

**Tests.** QueryPromptTests for the prompt that teaches the words, SkillTests for the query reference, and a key walk through a rule with two chips.

## 3 · Rules on the type's note

[[F4]]

**A, on the note:** a new Types point at the foot of a type's rows, covering layout, drawing, faces, ⌥Tab parts, skeleton bars and a relationship type's card. **B, a count by the pill:** one adornment and nothing new in Types; the Rules tab holds the rest.

## 4 · A flagged shape

[[F5]]

The ring, the dot in the table of contents and the Issues line are Validation's. The line quotes the rule and offers Ignore and Show Rule. Under it is a section of LanguageRules': the shape's rules read together, each with its state, and Shown, which lists what the model saw under the labels it was given. Highlighting a group lights its shapes.

| Interface | What it does | |
|---|---|---|
| `scope.validate(ignoringMoves: true) { … }` | a warning per rule that flags, less the ignored ones | exists · Validation |
| `ValidationIssue.actions` → `DetailStatus.actions`, drawn by `StatusList` | Ignore and Show Rule on the issue's line; the Issues tab draws its own lines, so the actions need a way through | new · Validation, DetailPanel |
| `DetailSection(…, in: IssuesTab.self, id: "rules")`, `.shownWhile` | the rules read together, and Shown; there whenever the shape's types have rules, issue or not | new section · LanguageRules |
| `RuleChecks.verdicts(of:)`, `RuleChecks.sent(for:)` | each rule's state (flags, holds, unsure, ignored, checking) and the state last sent | new · LanguageRules |
| `DetailRowList(onHighlight:)`, `DetailGroupHeader`, `DetailShapeRow` | Shown's groups and rows | exists · DetailPanel |
| `editor.selection = type`, `detailPanel.choose(.of(RulesTab.self))` | Show Rule | exists · DetailPanel |

[[F6]]

States: unsure shows nothing on the board, and the panel says so quietly. While a shape is checked again its ring stays until the new answer lands. An ignored rule says Ignored and offers Stop Ignoring. Without a key, one line says nothing is checked.

[[F7]]

One call reads every rule along the chain, most general first. Of two types that build on the same one, the later in the shape's list is the more specific, as Types reads a list. The prototype sent the Mustang's rules in the wrong order, so Jev was asked again with the order fixed; F7 shows that run. Vintage's qualifier still doesn't win: the Mustang breaks one at 0.74. The restored 1972 Beetle now rings too, because it fails the qualifier itself (0.71). A child's sentence can soften a parent's judgment, as Vintage's did for mileage, but not a literal rule. For such a shape, Ignore is the person's answer. Otherwise the exception goes into the parent's sentence.

[[F8]]

An arrow is checked as a note is. Its free context is its two ends and the other arrows of its type at each end. A chip brings the member's district.

## 5 · Ignore

An added property on the checked shape holds the sentences it ignores. An ignore lapses when its sentence changes.

| Interface | What it does | |
|---|---|---|
| `IgnoredRulesProperty` (`ignoredRules`) | the sentences ignored; `Fixtures/added/ignoredRules.v0.json` | new · LanguageRules |
| `note.checkedByRules()`, `arrow.checkedByRules()` | the kinds opt in, StickyNotes and Arrows calling LanguageRules' sugar | new |
| `transact("Ignore Rule")` | one step; Stop Ignoring another | exists · Canvas |

## 6 · The checks

[[F9]]

| Interface | What it does | |
|---|---|---|
| `RuleChecks` (`EditorService`): `documentDidChange`, `topology.follow` | marks dirty by footprint, by a type's rules, and chips on any commit that isn't a move | new · LanguageRules |
| `editor.scheduler` | waits for quiet: editing ends, or 3 s | exists · Canvas |
| `RuleVerdictCache` | answers by model version, rules and hash, in memory and in a file in Application Support | new · LanguageRules |
| `validation.recheck(ids)` | when answers land | exists · Validation |
| `topology.keepsSettling { busy }` | the command line waits while checks run | exists · Topology |

**Budget.** On a 10,000-shape board with 1,000 checked shapes, a commit costs what it changed, through the footprint index. Nothing runs per frame. Opening a file asks nothing it asked before, and a Quick Look preview asks nothing.

## 7 · What a rule sees

[[F10]]

The state is built off the main actor from one snapshot. It holds the shape, its types and their words, where it is, what's beside it, its edges and an arrow's ends, and each chip's finds. The biggest groups shrink past a budget, first to titles and then to counts. Its hash is the cache key. Its footprint, the shapes it read, says which commits ask again. The date is in what's sent, so an answer is kept for a day.

**The ring.** The answer for the rules read together decides it, so a more specific type's sentence can qualify a parent's. The Issues line quotes the rule whose own answer is highest. On round 1's cars, only the answer read together let Vintage's "mileage doesn't matter" win: 0.18, against 0.87 for Car's rule asked on its own.

| Interface | What it does | |
|---|---|---|
| `RuleContext.build(for:in:)` | the state, its hash and its footprint | new · LanguageRules |
| `topology.snapshot(.resolved)`: `shape`, `parent`, `children`, `edges(of:)`, `edges(carriedBy:)` | one step around, read through pills | exists · Topology |
| `RuleBook.chain(for:)` | the rules along the chain, most general first, by `types.lineage(of:)` | new · LanguageRules |
| `RulePrompts`, from a text file the product ships | the questions' words: one for the rules read together, one for each rule | new · LanguageRules |

## 8 · Decision models

[[F11]]

A new engine beside LanguageModels: state in, a probability for each yes/no question out. Jev ships. A Haiku 5.5 adapter proves the seam isn't shaped around Jev.

| Interface | What it does | |
|---|---|---|
| `DecisionModel.decide(_:) async throws -> DecisionAnswers` | the one call; `DecisionAnswers { model, yes, usage }` | new · DecisionModels |
| `DecisionModelError` | messages that name the provider: "No TypeSafe key", "Can't reach TypeSafe" | new · DecisionModels |
| `JevModel(keys:)` | POST `/v1/systemone`, each question a `noul` | new · DecisionModels |
| `LanguageDecisionModel(model:)` | Haiku 5.5 answers in words | new · DecisionModels |
| `ScriptedDecisionModel` | tests' answers, held or released | new · DecisionModels |
| `DecisionModelsPlugin: OutwardPlugin`, `editor.decisionModel` | handed to the list as LanguageModels is | new · DecisionModels |
| `registrar.settingsPane("TypeSafe")` | the pane, under Anthropic's: Settings stacks every plugin's pane | exists · Canvas |
| `TypeSafeSettingsView`, `TypeSafeKeySettings`, `TypeSafeKeyStore`, `.decisionModelKeyDidChange` | Save, Remove, and Test with a one-question call; the key in a 0600 file; checks retry on a new key | new · DecisionModels |
| `DecisionModels.showSettings()` | Open Settings…, sending `showSettings:` as Anthropic's does | new · DecisionModels |
| `DecisionCutoffs(flag: 0.7, holds: 0.3)` | a provider's cutoffs, set by the live eval | new · DecisionModels |

**Tests.** Jev runs against a URLProtocol stub. `ShippedPlugins` gets a scripted model by default, so its 260 call sites keep compiling.

## 9 · Where a rule is kept

`"$rules": {"const": [{"says": "…", "find": [{"phrase": "…", "query": "…"}]}]}` in the type's schema, beside `$color`. It copies with the type, and draw writes it.

| Interface | What it does | |
|---|---|---|
| `registrar.typeDirective("rules")` | Types holds another plugin's directive aside: the sync never sees it, a schema written whole carries it, and a change to it alone leaves the type's fields as they were | new · Types |
| `RuleBook.rules(of:)` | a type's rules | new · LanguageRules |

**Tests.** The sync never sees `$rules`, draw's `schema:` keeps it, and Remove Type takes it with the schema.

## 10 · Agents

[[F12]]

[[F13]]

| Interface | What it does | |
|---|---|---|
| draw's `schema:` | writes `$rules` | exists · Draw |
| a rule on types, `$0.validate { … }` | a chip that can't be read warns on its type; draw reports it through Validation's check, the one `drawChecks` takes | new rule · LanguageRules |
| `:warned` rows' `problems` | the sentence, `class` `warning` | new · Validation |
| Validation's words wait while checks run | as edge queries wait for settling | new · Queries, Validation |
| `canvas decide <query> "<question>"` | one yes/no question of many shapes; nothing stored, nothing rings | new · DecisionCommands |

The canvas skill says all of this (SkillTests).

## Landings

1. **Decision models.** The engine, Jev, the Haiku adapter, the scripted model and the TypeSafe pane.
2. **Rules checked.** Types' held directive, the rule book, the context, the checks and their cache, the warning, and `:warned` listing and waiting. Rules are written with draw or in the JSON.
3. **The panel.** The Rules tab, the Issues section with Shown, issue actions and Ignore.
4. **Chips.** `:scope`, the translator's `.rule`, the chip in the tab, and draw's check.
5. **Agents.** `canvas decide` and the skill.
6. **Rules on the type's note:** A or B.

Each landing comes with its tests and key walks, and a live eval for any prompt it changes.
