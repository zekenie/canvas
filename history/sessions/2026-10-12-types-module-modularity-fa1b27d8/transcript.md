# Types module modularity

Claude Code session `fa1b27d8-889c-415d-ab71-30240bf2ba2b`, 2026-10-12 20:41 to 2026-10-12 21:35 UTC, on `main`, `types-parts`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-12 20:41] USER:
[image attached]

[2026-10-12 20:41] USER:
I'd like you to ponder if we can create some internal modularity inside `types`

its one of the most complex modules. 

to be clear i'm not asking for this refactor to do much more than just re-bucket existing stuff. i think it would just be more clear if we had some sub-modules with some boundaries

[2026-10-12 20:46] ASSISTANT:
Yes, and it is nearly a pure re-bucket: the 80 files already fall into nine parts that depend on each other in one direction, with six declarations in the wrong file. The file-to-file graph behind this is a text match I filtered by hand, not the compiler's.

Each part uses only the parts above it:

| Part | Files | Lines | What it is |
|---|---|---|---|
| JSON | 7 | 2,700 | reader, caret, completer, pointer, meta-schema, `SchemaDocument`, `SchemaValue`; knows no type |
| Type | 9 | 1,500 | `schema` and `is`, readings, references, the graph, `TypeIndex`, colors |
| Fields | 18 | 2,600 | the chain, `FieldBook`, kinds, paths, values, text, summaries, links, the writer |
| Checks | 4 | 1,250 | `FieldCheck`, `FieldChecker`, `FieldChecks`, `FieldSchemas` |
| Sync | 4 | 1,550 | `TypeSync`, prompts, highlights (uses only JSON and Type) |
| Is a | 6 | 800 | make/add/remove commands, `/is-a`, the menu, chips, the Types and Schema tabs |
| Form | 17 | 3,750 | `FieldSheet`, `FieldFormView` and its extensions, cards, link picker, the panel's Fields |
| Rows | 10 | 2,850 | `RowBook`, drawing, faces, editing, `RowsView` |
| Engines | 4 | 400 | what draw, queries and Find read |

What has to move between files for that order to hold:
- **`TypesStyle`**: it is declared in `TypesPlugin.swift` and used about 330 times from every part, so it needs a file of its own at the bottom. Six ink and dot constants declared in Rows files are also used by Form.
- **`SchemaDirectives`**: it lives in `TitleSource.swift` but the JSON part uses it.
- **`typeable()`**: it is in `IsA.swift` and opts into `FieldValuesProperty`, which is a Fields declaration.
- **`TypeIndex.referenceTargets`**: it builds completions, which belong to the Is a part.
- **The one real inversion**: `FieldChecks` calls `fieldCards?.checkDidMove()` ([FieldChecks.swift:435](FieldChecks.swift:435)). That needs a small hook like `TypeIndex.onChange`, or a named exception.

I'd make these folders inside `Sources/Types`, not Swift modules. `build.sh` already globs `**/*.swift` and Canvas is laid out this way, so the move is `git mv` plus the fixes above. Real modules would break the charter rule that a module exists only when something must build without the other. They would also force every cross-part symbol to become `public`, and Form and Checks fit no layer.

Folders alone are not boundaries, though. To hold them, the audit would need a declared part order and a check against it. A text check is fuzzy; the compiler can emit exact per-file references, but I haven't verified that `build.sh` can read them on this toolchain. That check is the only piece beyond re-bucketing, and it lives in `build.sh`, not Types.

Do you want the order enforced by the audit, or folders by convention to start? Once you pick, I'll write the file-by-file plan for your OK.

[2026-10-12 20:53] USER:
confused about what order we are discussing

[2026-10-12 20:53] ASSISTANT:
By "order" I meant which part is allowed to use which: the same idea as the layers in `Package.swift`, but between folders inside Types.

The table's rows are listed in that order. A part may use anything in the rows above it and nothing in the rows below. So Rows may call into Form (a row opens a card), but Form may not call into Rows. Fields may read `TypeIndex`, but Type may not know about fields. JSON, at the top, uses none of the others.

That rule is the "boundary". Without it the folders are only a filing system, and a file in Fields could start using something from Rows with nothing to stop it.

So my question was whether `build.sh`'s audit should refuse a reference that points the wrong way, as it already refuses a surface importing a concern, or whether the folders and their order are just written down and kept by hand for now.

[2026-10-12 20:53] USER:
yeah i think that's a good idea all things being equal

[2026-10-12 20:55] ASSISTANT:
Testing whether the compiler itself can check the order: type-checking each part with only the parts it's allowed to use. The whole module checks clean in 1.5 s, so now running it part by part.

[2026-10-12 20:57] ASSISTANT:
I checked whether the build can enforce the order, and it can, using the compiler itself. Each part is type-checked together with only the parts it says it uses, so a reference pointing the wrong way fails as an ordinary compile error.

I ran that against today's sources. It costs about 9 s of CPU across ten checks, roughly 1.5 s when run in parallel, and only when Types changes.

It also corrected my earlier count: ten things sit in the wrong place, not six. The text match missed four of them.

## The folders

`TypesPlugin.swift` stays at the root and may use every part.

| Folder | Uses | Files |
|---|---|---|
| `JSON` | nothing | JSONReader, JSONCaret, JSONCompleter, JSONPointer, MetaSchema, SchemaDocument, SchemaValue |
| `Type` | JSON | TypeSchema, TypeWords, SchemaReadings, SchemaReferences, IsA, TypeGraph, TypeIndex, TypeColors, JSONCodeColors |
| `Fields` | JSON, Type | Chain, ChainBook, FieldBook, FieldKind, FieldPath, FieldName, FieldWords, FieldValues, FieldValueAccess, FieldText, FieldSummary, FieldLink, RowList, TitleSource, FieldTitling, FileFields, ReadingTypes, FieldWriter |
| `Checks` | + Fields | FieldCheck, FieldChecker, FieldChecks, FieldSchemas |
| `Sync` | JSON, Type | TypeSync, SchemaPrompts, SchemaHighlights, TypeHighlights |
| `IsA` | JSON, Type, Fields, Sync | TypeLinks, TypeChoices, TypeMenus, TypeChips, TypePanel, TypeCompletions |
| `Form` | all of the above | FieldSheet, FieldForm, FieldFormView and its seven extension files, FieldGridView, FieldCellEditor, FieldJSON, FieldJSONEditor, FieldCards, LinkPicker, FieldsPanel |
| `Rows` | + Form | RowBook, RowGeometry, RowShown, RowsDrawing, RowsValuesDrawing, RowFaces, RowEditing, RowField, RowsView, TypeRows |
| `Engines` | everything | TypeNames, FieldValuesDraw, TypeQueries, FieldFind |

## The ten fixes

1. `TypesStyle` moves out of `TypesPlugin.swift` into its own file in `Type`.
2. `PluginID.types` moves to `Type`; `TypeWords` and `TypeRows` name it as their points' owner.
3. `SchemaDirectives` moves out of `TitleSource.swift` into its own file in `JSON`.
4. The pointer media type constant gets its home in `JSON`, because the meta-schema writes it; `FieldKind.pointerMediaType` points at it.
5. `typeable()` moves from `IsA.swift` to `Fields`, since it opts into `fieldValues`.
6. `TypeIndex.referenceTargets` moves to `IsA` as an extension, rewritten over the index's own accessors because `entries` is private.
7. `TypesStyle.removeValue` moves from `FieldsPanel.swift` to `Fields`, where the writer uses it.
8. The `registerFieldsPanel` call moves out of `registerTypePanel` into `TypeDetailsPlugin.register`, right after it.
9. Six constants (`wrongInk`, `rowInk`, `neededInk`, `linkWaveInset`, `neededDotGap`, `neededDotSize`) move from Rows files to Form's style file.
10. `FieldChecks` stops calling `fieldCards?.checkDidMove()` directly and gets an `onMove` hook that `FieldCards` registers with. This is the only real code change.

A compile error can hide another in the same expression, so one or two more may surface as I go.

## The check and the docs

- **Declaring the parts:** a table in `Package.swift`, one line per part naming what it uses, read by `build.sh` as text the way the shipped list is.
- **Where it runs:** as a build job, because it needs the dependencies compiled. `./build.sh` and `./test.sh` run it; `./build.sh audit` alone does not.
- **Docs:** `build.md` gets the parts rule; `types.md`, `plugin-system.md`, three other rules files, `scripts/schema-prompts` and `THIRD_PARTY_NOTICES.md` get the new paths.
- **Verification:** full build and `./test.sh`, in a worktree off main, with a code review before landing.

Folder names are easy to change; `IsA` and `Engines` are the two I'm least sure of. OK to start?

[2026-10-12 21:07] USER:
Begin

[2026-10-12 21:07] USER:
[Request interrupted by user]

[2026-10-12 21:16] USER:
Uh, ahem. Begin

[2026-10-12 21:16] ASSISTANT:
Moved the 80 files into the nine folders; now working through the ten misplaced declarations, starting with `TypesStyle` and `PluginID.types`.

[2026-10-12 21:17] ASSISTANT:
Six of ten fixes are in; I just cut `referenceTargets` out of the index and am re-adding it in the `IsA` part, then the last four.

[2026-10-12 21:18] ASSISTANT:
Moving the six shared ink and dot constants from the Rows files into the form's style file, then the last fix (the `FieldChecks` hook) before the first full build.

[2026-10-12 21:19] ASSISTANT:
The ten fixes are in and a full build is running in the background. While it runs I'm reading `Package.swift` and `build.sh` to add the parts table and the check.

[2026-10-12 21:21] ASSISTANT:
Parts table is in `Package.swift` and `build.sh` now reads and validates it. Next I'm adding the build job that type-checks each part against only the parts it names.

[2026-10-12 21:24] ASSISTANT:
Now the path fixes in the scripts and docs.

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
(`RowsView`, `Sources/Types/Rows/RowsView.swift`)

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
The vocabulary under the rows, the card, the panel's Fields and the check is in `Sources/Types/Fields` (and the check's answer in `Checks`), so they cannot disagree.

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
reaches the forms in the same pass (`FieldCards.checkDidMove`, told through `FieldChecks.onTypingChange`, which the cards register for as they are made: the check is in a part under the form's and names nothing of it)

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
registered by `TypeDetailsPlugin` after the Types rows (`registerFieldsPanel`, right after `registerTypePanel`, which is in a part under the form's)

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
`SchemaDirectives` (`JSON/SchemaDirectives.swift`: the readings under the chain use it too)

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
(`FieldKind.pointerMediaType`, which is `MetaSchema.linkMediaType`, the constant the meta-schema is written from:

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
## The parts

Types is one module in nine parts, each a folder of `Sources/Types`, and a part names only what is in the parts its line in `Package.swift`'s table of parts says it uses: the build type-checks each with those sources alone, so a file that reaches into another part doesn't compile ([build](build.md), "The parts of a module"). The sections below follow them.

- In the table's order, each using only parts above it: `JSON` (the reader, caret, completer, pointer, meta-schema, `SchemaDocument`, `SchemaValue` and `SchemaDirectives`: it knows no type and no shape) uses nothing; `Type` (the two properties, `schema` and `is`, the readings, references, the graph and the file's `TypeIndex`, a type's colors, and `TypesStyle`) uses `JSON`; `Fields` (the chain, `FieldBook`, kinds, paths, values, text, summaries, pointers, the title from a field, `FileFields` and the one writer) uses those; `Checks` (`FieldCheck`, `FieldChecker`, `FieldChecks`, `FieldSchemas`) adds `Fields`; `Sync` (`TypeSync`, its prompts, the highlights) uses only `JSON` and `Type`; `IsA` (what a shape is, shown and changed: the commands, `/is-a`'s rows, Is a ▸, the chips, the panel's Types and Schema tabs with the JSON's completions) uses `Fields` and `Sync` and theirs; `Form` (the sheet, `FieldFormView`, the cards, `LinkPicker`, the panel's Fields) uses all of those; `Rows` (`RowBook`, the drawing, faces, editing and `RowsView`) uses `Form` too, since a row opens a card and never the other way; `Engines` (w […1126 more chars]

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/build.md:
## The parts of a module

- **What a part is.** A module too large to hold in mind is split into parts, each a folder of its directory, with the rule between them that holds between modules: a part uses only the parts its line names. They are parts and not modules by the rule at the end of Layers (nothing must build without the others, and no layer forbids an import), and because what one part shares with the next stays internal to the module: as modules, every such name would be public to every importer. Types is the one module in parts ([types](types.md), "The parts"); a module with folders and no line in the table (Canvas) has none.
- **The table** is in `Package.swift`, after what ships: `let parts: KeyValuePairs<String, [String]> = [` on a line of its own, then a line a part, `"Module/Part": ["A", "B"],`, comments on lines of their own, and `]`. `build.sh` reads it as text (`PARTED`, `PARTS`, `PART_USES`), and SwiftPM makes nothing of it. The lines are in an order the parts could be built in: a part uses only parts written above it, so there is no cycle, and names all of what those use, so a line says everything its part compiles with. Every folder directly in a module that has parts is a part; the sources beside the folders are the module's own (its plugin values, which install every part) and may use them all. Every mode refuses a table that breaks one of these, a part with no folder or no sources, and a folder that is no part.
- **The check** is the compiler's: for a  […1502 more chars]

[2026-10-12 21:25] EDIT .claude/worktrees/types-parts/.claude/rules/build.md:
How `build.sh` builds and runs; what `Package.swift` declares, the layers and what each may import; what ships and how the product is made of it; the parts a large module is split into and how the build holds them apart; and what the audit refuses.

[2026-10-12 21:25] ASSISTANT:
Code, the check and the two topic files are done; the test suite is still running. I'm finishing the docs (`CLAUDE.md` and the guide) while it runs.

[2026-10-12 21:26] EDIT .claude/worktrees/types-parts/docs/plugin-system.md:
`./build.sh graph` prints the list after the modules, and leaves what `+ shipped` links out of
each line's dependencies: what ships is membership in the product, not one module's design
depending on another's.

### The parts of a module

A module that has grown too large to hold in mind is not split into modules (nothing must build
without the rest, and every name one piece shares with the next would become public to every
importer). It is split into **parts**: folders of its directory, with the rule between them that
holds between modules. `Package.swift` has a table of them after what ships, a line a part, each
with the parts of the same module it uses:

```swift
let parts: KeyValuePairs<String, [String]> = [
    "Types/JSON": [],
    "Types/Type": ["JSON"],
    "Types/Fields": ["JSON", "Type"],
    "Types/Checks": ["JSON", "Type", "Fields"],
    "Types/Sync": ["JSON", "Type"],
    "Types/IsA": ["JSON", "Type", "Fields", "Sync"],
    "Types/Form": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA"],
    "Types/Rows": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA", "Form"],
    "Types/Engines": ["JSON", "Type", "Fields", "Checks", "Sync", "IsA", "Form", "Rows"],
]
```

The lines are in an order the parts could be built in: a part uses only parts written above it, so
there is no cycle, and names all of what those use, so a line says everything its part compiles
with. Every folder of a module that has parts is one, and the sources beside the folders (Types'
`TypesPlugin.sw […1184 more chars]

[2026-10-12 21:26] EDIT .claude/worktrees/types-parts/docs/plugin-system.md:
as the schema, which the editor's language model keeps saying the same thing (`TypeSync`, below).
It is one module in nine parts, a folder each (`JSON`, `Type`, `Fields`, `Checks`, `Sync`, `IsA`,
`Form`, `Rows`, `Engines`), and a part names only what is in the parts it uses
([The parts of a module](#the-parts-of-a-module)).
Types knows no kind.

[2026-10-12 21:26] EDIT .claude/worktrees/types-parts/.claude/rules/build.md:
[host slots](host-slots.md), [Quick Look](quick-look.md), [types](types.md) ([every topic]

[2026-10-12 21:26] EDIT .claude/worktrees/types-parts/.claude/rules/types.md:
Related: [build](build.md), [adornments](adornments.md),

[2026-10-12 21:26] ASSISTANT:
Docs are updated across the guide, `CLAUDE.md` and the topic files. Waiting on the full test run, and touching up the README's one line about Types meanwhile.

[2026-10-12 21:27] COMMIT MESSAGE FILE commit.txt:
Types is in nine parts, a folder each, and the build holds them apart: a part type-checks with only the parts its line in Package.swift names

Types had grown into one of the most complex modules: eighty files flat in one folder, 17,500
lines, and on the board the ingestion draws of it, a hairball. The owner asked for internal
modularity, sub-modules with boundaries, and was clear that it should be little more than
re-bucketing what is there.

The files already fell into nine groups that use each other in one direction, so they are now
folders of Sources/Types, in this order, each using only those before it: JSON (the reader, caret,
completer, pointer and meta-schema, which know no type), Type (the schema and `is` properties, the
readings and the file's index), Fields (the chain, the field book, kinds, values, the one writer),
Checks, Sync (the model, on JSON and Type alone), IsA (what a shape is, shown and changed), Form
(the sheet, the form, the cards, the panel's Fields), Rows, and Engines (what draw, queries and
Find are given). TypesPlugin.swift stays beside them and installs all of it.

They are parts and not modules. The layers charter says a module is its own only when something
must build without the other or a layer forbids an import, and neither holds here; as modules,
every name one part shares with the next would also have become public to every importer, and
Form and Checks fit no layer.

Folders alone are a filing system, so the owner chose to have the order enforced. Package.swift
has a table of parts after what ships, a line a part with the parts it uses, in an order they
could be built in (a part uses only parts above it, and names all of what those use). The build
runs one job more for a module that has parts, which type-checks each with only its own sources
and those its line names: a part that reaches into another doesn't compile, and the error is the
compiler's, at the name. A text match over the sources was tried first and rejected: it found six
misplaced declarations where the compiler found ten (it cannot see an interpolation in a string,
or tell a member from another of the same name). The check needs the module's dependencies built,
so it is the build's and test.sh's, not `./build.sh audit`'s; Types' nine take about seven
seconds of one core, and a part is checked again only when a source it compiles with changed.

Ten things were in the wrong place for that order, and moved: TypesStyle out of TypesPlugin.swift
into Type; PluginID.types to TypeWords, under the points that name it as their owner;
SchemaDirectives out of TitleSource.swift into JSON; the link media type's home to MetaSchema
(FieldKind.pointerMediaType is it); typeable() to Fields, since it opts a kind into fieldValues
too; TypeIndex.referenceTargets to IsA, over the index's own accessors; the Remove step's words to
the writer's file; registerFieldsPanel's call from registerTypePanel to TypeDetailsPlugin; six
inks and sizes a card and a row both draw with from the rows' files to the form's style. One was a
real inversion: FieldChecks called the cards when the caret moved. It now takes observers
(onTypingChange), as TypeIndex.onChange does, and the cards register as they are made.

Nothing else changes: no behavior, no public name removed, no test edited.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

===== [2026-10-12 21:27] commit written: Types is in nine parts, a folder each, and the build holds them apart: a part type-checks with only the parts its line in Package.swift names =====

[2026-10-12 21:27] ASSISTANT:
Full suite passes: 104 test executables, 0 failed. Committing on the branch, then running the code review before I report.

[2026-10-12 21:27] GIT:
git add -A && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/fa1b27d8-889c-415d-ab71-30240bf2ba2b/scratchpad/commit.txt && git log --oneline -1 | cut -c1-120 && git show --stat --format= HEAD | tail -1

[2026-10-12 21:28] EDIT .claude/worktrees/types-parts/docs/plugin-system.md:
else of the module doesn't compile. With a file `Probe.swift` in `Fields` that takes a `RowBook`:

```
Sources/Types/Fields/Probe.swift:1:31: error: cannot find type 'RowBook' in scope

[2026-10-12 21:28] GIT:
./build.sh audit | tail -1 && ./build.sh 2>&1 | tail -2 && git commit -qam "Fix what reviewing the parts found" && git log --oneline -2 | cut -c1-70

[2026-10-12 21:29] ASSISTANT:
Types is re-bucketed into the nine folders, the build now enforces the order, and it's ready on branch `types-parts` (not on main). The full build and `./test.sh` pass (104 test executables, 0 failed) and the code review is done. The review's three fixes were comment, doc and message edits; I rebuilt after them but did not re-run the suite.

- **The folders:** as planned — `JSON`, `Type`, `Fields`, `Checks`, `Sync`, `IsA`, `Form`, `Rows`, `Engines`, with `TypesPlugin.swift` beside them.
- **The table:** `Package.swift` has a table of parts after the shipped list, one line per part naming the parts it uses.
- **The check:** the build type-checks each part with only the sources its line names. I tried it with a file in `Fields` that took a `RowBook`: the build failed with the compiler's error at that name, plus a line saying which part reached out. It also refuses a folder that isn't in the table, and a table line that uses a part below it or leaves out one it compiles with.
- **Cost:** about 7 s of one core for all nine parts, and a part is re-checked only when a source it compiles with changes.
- **The ten moves:** all done as listed, and no more surfaced. The one real code change is `FieldChecks.onTypingChange`, which the cards register for instead of being called directly.
- **Docs:** `CLAUDE.md`, the build and types topic files, the guide, and the paths in the prompt eval scripts and third-party notices are updated.

Three things the review raised that I left alone:
- **No automated test of the check.** I only exercised its refusals by hand.
- **A blind spot.** The check proves a part compiles without the others, not that it behaves the same; a higher part could still affect a lower one through an extension the lower one finds at run time.
- **Serial and repeated.** The nine checks run one after another, and both the release and debug builds run them.

Say "land" and I'll squash it onto main and remove the worktree.

[2026-10-12 21:35] USER:
Land

[2026-10-12 21:35] GIT:
git status --short | head -5; git rev-parse --short main; git merge-base HEAD main | cut -c1-8; git log --oneline main -3 | cut -c1-90

[2026-10-12 21:35] ASSISTANT:
Main hasn't moved, so no rebase is needed. Squashing to one commit.

[2026-10-12 21:35] GIT:
git reset --soft main

[2026-10-12 21:35] GIT:
git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas/fa1b27d8-889c-415d-ab71-30240bf2ba2b/scratchpad/commit.txt

[2026-10-12 21:35] GIT:
git merge --ff-only types-parts 2>&1 | tail -2 && git log --oneline -1 | cut -c1-100

[2026-10-12 21:35] ASSISTANT:
It's on main as 80bdb19d.

The worktree and its branch are removed.
