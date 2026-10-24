# 02 · Each shipped command says how it acts on several shapes

**Commit title:** Every shipped slash command says how it acts on several shapes: a block moves as one, nested frames turn together, a color or a type goes to all in one step, a title stays one shape's, and a locked shape can be unlocked

**Depends on:** [01](01-targets-in-the-engine.md).

## The ask

"if have two nodes selected and you type /color blue it applies to both. If you have 10 selected you can is-a foo andthey all become foo." This commit makes each shipped command right on several shapes before any surface can run one on several ([04](04-the-command-bar.md)), so the bar never lands with `/title` renaming five shapes or `/move-near` scattering them.

## Justification

Every plural writer exists; each command only has to call it with what it's handed.

| Command | Where | Today | The writer it calls on several |
|---|---|---|---|
| `/title` | `Sources/Titles/Titles.swift:553` | `edit` over the record | (none: one shape, D4) |
| `/lock` | `Sources/Locking/Locking.swift:130` | `SlashCommand("lock", command: .lock)` | `.lock` already takes a subject of many |
| `/public`, `/private` | `Sources/Publishing/PublishMenus.swift:46` | declared, `/private` a try | `.makePublic`, `.makePrivate` already pick out what can change ("a mix makes public only what can be") |
| `/turn-into-<kind>` | `Sources/Transform/Transform.swift:211` | `perform`, `turn([id], into:)` | `TransformState.turn(_ ids:into:)` (`Sources/Transform/TransformState.swift:50`): innermost first, all or nothing, one step. Run one by one it would turn an outer frame first, and its inner frame, now on the subboard's board, would not turn |
| `/color` | `Sources/Colors/ColorCommand.swift:46` | choice, `setColor(_, of: [owner])` | `editor.setColor(_:of:)` (`Sources/Colors/ColorBook.swift:372`): one step, kinds with no colors left out |
| `/is-a` | `Sources/Types/IsA/TypeLinks.swift:235` | choice, rows for one owner | `giveType(_:to:)` (`TypeLinks.swift:154`, the role partition for many), `makeTypes(_:)`, `makeRelationshipTypes(_:)`; Is a ▸'s rows for a selection, `typeMenuChoices(for:)` (`Sources/Types/IsA/TypeChoices.swift:107`) |
| `/move-to @X` | `Sources/Moving/Moving.swift:23` | one owner (`Move`, `Sources/Moving/Move.swift:9`) | `Drop(_ ids:to:in:)` (`Sources/Moving/Dropping.swift:41`), the one Move To ▸ and the table of contents' drops move a selection with: a block, kept where its shapes are to each other |
| `/move-near @X` | `Moving.swift:33` | one owner | `Block` (`Move.swift:48`), beside X as `near` puts one shape |

And two commands that text could never reach become reachable: `/unlock` (Locking: "There is no `/unlock`: a locked shape's text can't be edited, so it couldn't be typed", `Locking.swift:128`) and `/turn-into-subboard` (Transform: "no shipped kind that has text offers the channel, so `/turn-into-subboard` is typeable nowhere in the app yet", `.claude/rules/transform.md`). Both arrive here, headless; [04](04-the-command-bar.md) gives them a surface.

## Tactics

### Code, a plugin at a time

1. **Titles** (`Titles.swift:554`): `SlashCommand("title", argument: "title", reach: .one) { … }`. A title is how a shape is told apart, and Boards warns of two shapes with one path; with several selected, `/title` isn't listed (D4).

2. **Locking** (`Locking.swift:130`):

   ```swift
   lock.slashCommands {
       SlashCommand("lock", command: .lock, when: { !$0.isLocked })
       SlashCommand("unlock", command: .unlock, when: { $0.isLocked })
   }
   ```

   `when` makes each reach exactly the shapes the command changes, so a mix counts right (`lock` and `unlock` each `1 of 2`); the rule still decides (a shape whose lock its frame holds is offered neither, `isLockedByContainer`). `/unlock` is a declared command, so it reaches a locked, read-only shape ([01](01-targets-in-the-engine.md): only declared commands do), and never a text's (a read-only shape's text offers nothing). The comment over it (`:127`) says so in place of "There is no `/unlock`".

3. **Publishing** (`PublishMenus.swift:48`): `SlashCommand("public", command: .makePublic, when: { $0[PublicProperty.self] != true })`, so its reach is the shapes it would make public; `/private` keeps its `when` and `tries:`. On a text this is what the rule said already.

4. **Transform** (`Transform.swift:211`):

   ```swift
   turnable.slashCommands {
       SlashCommand.together("turn-into-\(kind.rawValue)") { ids, _, editor in editor.transforms?.turn(ids, into: kind) }
   }
   ```

5. **Colors** (`ColorCommand.swift`): `/color` becomes `SlashCommand.together`, its rows `ColorCommandRows.rows(for owners: [ShapeID], in:)`: the book's names as now, `None` while any owner holds a color of its own (`ownColor`), Edit Colors… last; its `otherwise` (a hex typed) as now; its pick `editor.setColor(ShapeColor(choice.id), of: owners)`, one step, "Change Color". One owner gets exactly today's rows.

6. **Types** (`TypeLinks.swift:235`, `TypeChoices.swift`): `/is-a` becomes `SlashCommand.together`, the step and the row ids as now:
   - **Rows** (`TypeChoices.rows(for owners:in:)`): for one owner, exactly today's (`rows(for:in:)`, `:126`, becomes the case of one). For several, as Is a ▸ lists them for a selection: `Type` while every owner can be a type and none is one (Is a ▸'s `Type` item), `Relationship Type` the same, then the types `typeMenuChoices(for: owners)` lists, less those every owner is already (the menu checks them; here they would add nothing). A type only some owners may take says how many in its row's detail, `2 of 3` (`TypesStyle.reach`, Types' words, since the row is Types').
   - **Cost**: the rows for many owners cost the distinct lists they hold and their roles (`TypeRole`), never one ask per owner per type: owners are grouped by role and `is` list before `admits` is asked. 1,000 selected notes in 20 lists over 50 types is `Budget.isAListOpenSelection` (below).
   - **New type** (`otherwise`, `TypeChoices.newRow`): offered while the owners share one role (all arrows that relate, or none of them), so it's one kind of type.
   - **A pick**: `.type` → `makeTypes(owners)`, `.relationshipType` → `makeRelationshipTypes(owners)`, `.existing(type)` → `giveType(type, to: owners)` (the role partition and `admits` decide who takes it, as Is a ▸'s pick gives it "to the rest that may take it"), `.new(name)` → `newType(named:besides: owners)`.
   - **`newType(named:besides: [ShapeID])`** (beside `newType(named:besides: ShapeID)`, `TypeLinks.swift:195`, which becomes its case of one): put down beside the box around the owners (`Surroundings.near(_ rect:avoiding:within:)`, `Sources/Draw/Surroundings.swift:95`, avoiding each owner's frame), every owner made one of it, one step "New Type" kept open while the new note is edited, as now.

7. **Moving** (`Moving.swift`, `Move.swift`):
   - `Move` takes ids (`init?(_ ids: [ShapeID], in:)`, wrapping a `Block` of them, which already moves many as one).
   - `/move-to` becomes `SlashCommand.together`, its `kinds:` as now, its rule and its run Move To ▸'s: a destination named by a shape is the place `MoveToMenu.swift` makes for it (a frame's inside, a subboard's board), and the command takes it while `Drop(owners, to: place, in:)` is not nil, runs `commit()`. So the command, the menu and the table of contents' drops refuse and land alike. For one owner this is what `Destination(of:into:in:)` (`Moving.swift:91`) says now; keep the tests that hold that.
   - `/move-near` becomes `SlashCommand.together`: its rule `admitsNear` over the owners (the target is none of them, nor what goes with any of them), its run `Move(owners)?.near(target)`.
   - Both steps stay "Move".

### `Package.swift`

Nothing.

### Tests

Each plugin's own, headless through `editor.slashCommands?.commands(for: .selection(ids))` and `run`, beside the suites that hold the command in text (which stay as they are):

- **TitlesTests** `titleSlashTests`: listed for a selection of one titled shape, not of two.
- **LockingTests** `lockSlashTests`: `/unlock` on a selection of a locked shape, one step "Unlock", undone; never on a text target; a mix lists both, each `1 of 2`; a shape in a locked frame offered neither; the report line.
- **PublishingTests** `SlashTests.swift`: a public and a private plaque, `/public` and `/private` each `1 of 2`; `/private` on a held one shakes and writes nothing, the rest go private.
- **TransformTests**: `/turn-into-pocket` on two nested corrals selected: one step, both pockets, innermost first; a corral and a box: `1 of 2`; a frozen box inside: nothing changes, no step, the box heard refused.
- **ColorsTests** `colorCommandTests`: three sheets: the rows, `None` when one holds a color, a pick colors all in one "Change Color" undone whole; a pane and a box: `1 of 2`.
- **TypesTests** `isACommandTests`: three memos: the rows, a pick to all in one "Add Type"; one memo already a Feature: Feature `2 of 3` and the pick gives it to the other two; `Type` only while all can be types and none is; New type beside the three, all of them made one, one step; a bond and a memo: the role partition, no New type; a frozen memo left out.
- **MovingTests**: three boxes selected, `/move-to` a corral: one block, 40 in, kept where they are to each other, one "Move" undone exactly; a corral too small for the block not admitted; onto a pocket's board; `/move-near` a disc: one block beside it; a box and a link: `1 of 2`.
- **CompositionTests** `slashCommandsShippedTests`, a selection target of each shipped kind: a note's list (`title`, `lock`, `public`, `is-a`, `color`, `move-to`, `move-near`), a frame's (`turn-into-subboard` first, then `title`, `lock`, `public`, `color`, `move-to`, `move-near`), a subboard's, an arrow's (`lock`, `is-a`, `color`), a reference's and a locked note's (`unlock`), each read from the app as built and pinned; a mixed selection's counts. And the shipped compositions, still headless: `/color` on two notes and a frame (`colorsShippedTests`), `/is-a` on ten notes (`typesShippedTests`), `/turn-into-subboard` on a frame and the frame inside it (`transformShippedTests`), `/move-to` three notes into a frame (`movingShippedTests`).
- **ShippedTests**' registry report: `locking … /lock /unlock → every shape holding locked`; the guide's copy (`docs/plugin-system.md:14269`) with it.
- **BenchmarkTests**: `Budget.isAListOpenSelection` (`TypeBenchmarks.swift`, beside `isAListOpen`): `/is-a`'s rows for 1,000 selected notes, asked once as the list would open. Set it from the first quiet run, as the others were.

### Docs (same commit)

- `.claude/rules/titles.md`: `/title` is one shape's.
- `.claude/rules/locking.md`: `/unlock`, offered where a locked shape can be reached (a selection, not its text); the sentence "there's no `/unlock`" goes; the report line.
- `.claude/rules/publishing.md`: `/public`'s `when`.
- `.claude/rules/transform.md`: `/turn-into-<kind>` turns every shape it's handed, as the menu's item does; "typeable nowhere in the app yet" stays until [04](04-the-command-bar.md).
- `.claude/rules/colors.md`: `/color` on several, `None` while any holds one.
- `.claude/rules/types.md`: `/is-a` on several (the rows, the count, New type beside several); `newType(named:besides:)` for several.
- `.claude/rules/moving.md`: `/move-to` and `/move-near` move several as one block, by Move To ▸'s rule; "Not built: moving several selected shapes with a command" goes once [05](05-shapes-named-in-the-bar.md) makes it typeable, and is said so here.
- `.claude/rules/slash-commands.md`: the shipped commands' sentence says each one's reach.
- `.claude/rules/benchmarks.md`: `isAListOpenSelection`.
- `docs/plugin-system.md`: the shipped commands in "Slash commands" (`:7291`), Locking's `/unlock`, Moving's and Transform's sections.

## Verification

- `./build.sh audit` passes.
- `./test.sh`, and the suites above with `TEST_FILTER` (it matches suite and test names, and fails when nothing matches).
- `./build.sh bench` holds `isAListOpenSelection`.
- In the app: nothing visible yet. `/is-a`, `/color`, `/lock` and `/title` typed in a note list and run as before (one owner gets today's rows exactly).

## Risks and open questions

- **D4, `/title`.** If the owner wants several shapes titled at once, it's `reach: .each` and the path warning says the rest.
- **`/move-to` by Move To ▸'s rule** may refuse a destination `Destination` admitted for one shape (a frame exactly the shape's size, where the block's laid-out frame is wider). One shape's block is that shape, so the tests that hold `Destination` today say whether anything moved.
- **`/is-a`'s rows for several** drop the types every owner is already, where Is a ▸ shows them checked to take them off. Taking a type off stays the menu's and the chips' (there's no `/is-not-a`).
- **`/lock`'s count** is the shapes not locked of its own; a shape held read-only by a locked frame around it is among them though Lock leaves it, which only a selection that holds such a shape and others shows.

## Not in this commit

- A surface that types for a selection ([04](04-the-command-bar.md)): everything here is reached headless.
- `/move-to @…` typed with a pill in the bar ([05](05-shapes-named-in-the-bar.md)).
