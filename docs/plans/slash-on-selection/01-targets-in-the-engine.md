# 01 · Targets in the engine: a command is typed for one shape's text or for the selection

**Commit title:** A slash command is typed for a target, one shape's text or the shapes selected, and says how it acts on several: on one, on each, or on all together

**Depends on:** nothing. Nothing in the app changes: the only target any surface makes is a text's.

## The ask

"some of the selection may not support all the same commands. we need to think this through." This commit is that thinking, in the engine: which commands a set of shapes lists, which of the shapes each acts on, and how it runs on them.

## Justification

- **Every layer of the engine assumes one shape, the owner of the text:**
  - `SlashCommandState.commands(for id:)` (`Sources/SlashCommands/SlashCommandState.swift:173`) asks one record, and offers nothing on a read-only one because its text can't be typed in.
  - `OfferedSlashCommand.init(_:owner:editor:)` (`:28`) binds the command's shape rule, its rows and its `otherwise` row to that owner.
  - `run(_:on:with:)` and `run(_:on:choosing:)` (`:199`, `:209`) run on it.
  - `ErasedSlashCommand.run` and `runChoice` take one `ShapeID` (`Sources/SlashCommands/SlashCommand.swift:217`).
  - `SlashCommandTyping(over:owner:commands:arguments:)` (`Sources/SlashCommands/SlashCommandTyping.swift:72`) holds one owner and asks for it at every keystroke.
- **The declared form is plural underneath already:** `SlashCommand(_:command:)` runs `editor.attempt(command, on: [id])` (`SlashCommand.swift:193`), and every declared command's rule and run take a `CommandSubject` of many shapes (`Sources/Canvas/Plugins/Commands.swift:13`). Lock, Make Public and Make Private already act on a selection from a key and a menu.
- **The plural writers exist for every other shipped command** ([02](02-shipped-commands-on-several-shapes.md)): `TransformState.turn(_ ids:)`, `editor.setColor(_:of: [ShapeID])`, `giveType(_:to: [ShapeID])`, `makeTypes(_:)`, Moving's `Block` and `Drop`. What's missing is the engine handing them more than one shape.
- **Running a one-shape action on each shape is not a plural.** `/move-near` run on each of five shapes lands them one by one beside the target, where a block keeps them where they are to each other (`Sources/Moving/Move.swift:48`, "they keep where they are to each other"). `/turn-into-subboard` run on an outer frame, then an inner one, finds the inner one already moved to the subboard's board, off the board shown, where `turn` doesn't reach it; handed both at once, `TransformState.turn` turns innermost first, "so a container inside another has moved what it held by the time the outer one reads what it holds" (`.claude/rules/transform.md`). So a command must say how it acts on several, and one written today must stay one-shape until it says otherwise.
- **A precedent for several shapes, and why the bar differs.** The context menu lists an item when every shape shows it, enables it when any does, runs each shape's own, in one step (`Sources/ContextMenus/Resolution.swift:165`). The bar lists what *any* shape takes and counts it (the owner's call, [README](README.md#decided)): a typed command says what you want, and the menu keeps its rule.

## Tactics

### Code: `Sources/SlashCommands`

1. **`SlashTarget.swift`** (new):

   ```swift
   /// What a command line is typed for: the one shape whose text it's on, or the shapes selected.
   public enum SlashTarget: Hashable, Sendable {
       /// A line of one shape's text (a note's words, an arrow's label, a panel's box). The shape is being
       /// written, so a read-only one offers nothing.
       case text(ShapeID)
       /// The command bar: the shapes selected, in selection order.
       case selection([ShapeID])

       /// Its shapes, in order.
       public var shapes: [ShapeID] { … }
   }
   ```

2. **`SlashReach`** (in `SlashCommand.swift`) and a `reach` on `SlashCommand`:

   ```swift
   /// How a command acts on a target of several shapes.
   public enum SlashReach: Sendable, Hashable {
       /// On one shape: listed only where the target is one (a text's line, a selection of one).
       case one
       /// On each shape it reaches, one by one, in one transaction and one undo step.
       case each
       /// On the shapes it reaches, handed together, once.
       case together
   }
   ```

   Each form says its reach, and today's forms keep their closures:

   | Form | Reach | Change |
   |---|---|---|
   | `SlashCommand(_:argument:when:accepts:step:edit:)` | `.each` by default; `reach: .one` allowed | a `reach:` parameter (a precondition refuses `.together`: an edit is over one value) |
   | `SlashCommand(_:argument:when:accepts:step:perform:)` | `.one` by default; `reach: .each` allowed (the action run on each shape, in one undo group) | a `reach:` parameter |
   | `SlashCommand(_:argument:when:kinds:shapes:step:perform:)` | `.one` | none |
   | `SlashCommand(_:argument:when:choices:otherwise:step:perform:)` | `.one` | none |
   | `SlashCommand(_:command:when:tries:)` | `.together` | none: it runs `editor.attempt(command, on:)` on the whole reach |

   and three plural forms, `together`, static so their closures never collide with a one-shape form's in a trailing closure (`{ id, arguments, editor in … }` and `{ ids, arguments, editor in … }` have the same arity):

   ```swift
   SlashCommand.together("turn-into-subboard") { ids, _, editor in editor.transforms?.turn(ids, into: kind) }

   SlashCommand.together("move-to", argument: "@frame or subboard", kinds: { $0.containingKinds.union($0.boardOwningKinds) },
                         shapes: { target, owners, editor in … }) { owners, arguments, editor in … }

   SlashCommand.together("color", argument: "color",
                         choices: { owners, editor in … }, otherwise: { typed, owners, editor in … }) { owners, choice, editor in … }
   ```

   The names are proposals; what matters is that a plural action is a form of its own, chosen by its author.

3. **`ErasedSlashCommand` keeps only plural closures and the reach** (`SlashCommand.swift:217`): `run: ([ShapeID], SlashArguments, CanvasEditor)`, `shapes: (ShapeID, [ShapeID], CanvasEditor) -> Bool`, `choices: ([ShapeID], CanvasEditor) -> [SlashChoice]`, `otherwise: (String, [ShapeID], CanvasEditor) -> SlashChoice?`, `runChoice: ([ShapeID], SlashChoice, CanvasEditor)`. A one-shape form is wrapped (`{ ids, … in perform(ids[0], …) }`, called only with one); an edit becomes one `editor.transact` that writes each shape in turn (as `write(id, &transaction)` does one now); a declared command `{ ids, _, editor in editor.attempt(command, on: ids) }`. Below this line nothing knows how many shapes a form was written for.

4. **`OfferedSlashCommand`** (`SlashCommandState.swift:7`) is found for a target and carries its reach:

   ```swift
   /// The shapes of the target it acts on, in target order: for a text's line, the shape.
   public let shapes: [ShapeID]
   /// How many shapes the target has: a list says "3 of 5" where `shapes` is fewer.
   public let targetCount: Int
   public var isPartial: Bool { shapes.count < targetCount }
   public let reach: SlashReach
   ```

   Its rule (`admits(_:)`, `SlashShapeRule`), its rows (`choices()`) and its `otherwise` row are bound to `shapes` where they were bound to the owner, the editor held weakly as now. Where one name is two kinds' own commands in one target (Lamp's `turn-on` and a card's), it holds both, each with its shapes, and runs each on its own (step 3 of the listing rule below).

5. **`SlashCommandState.commands(for target: SlashTarget)`**, the one place that decides what a target lists:
   1. For each shape of the target (gone or kept aside: skipped), the candidates of its kind (`candidates(for:)`, `:232`, unchanged: its own, then the scopes', one of each name), each whose `when` holds of the record. A read-only shape (`editor.isReadOnly`) is offered no command on a `.text` target (as now) and only declared commands on a `.selection` one.
   2. The shapes that offer a name are its reach, in target order.
   3. One name that is two different commands in one target (two kinds' own) is one row whose parts run each on their own shapes, in one step, unless it takes a shape or a choice: then it's left out (two rules, two lists of rows).
   4. Listed when its reach isn't empty, and: `.one` only where the target has one shape; a declared command while `editor.canPerform(command, on: reach)` (`Commands.swift:328`), or a plugin claims it and it `tries`.
   5. In the first shape's order, then the names only later shapes offer, in the order each lists them.
   6. Kept, for a `.selection` target, by the target and `editor.revision`: the bar asks at every keystroke for its marks (`SlashCommandTyping.marks`, `SlashCommandTyping.swift:372`), and 10,000 selected shapes are 10,000 records to read. A `.text` target asks one record, as now, and keeps nothing.

   `commands(for id:)` stays, as `commands(for: .text(id))`; `command(named:for:)` takes either.

6. **Running** (`SlashCommandState.run`, `:199`): `run(_ command: OfferedSlashCommand, with arguments:)` and `run(_:choosing:)` run on the command's reach (the shapes of it still there and not kept aside; false, doing nothing, with none left), in one `undoHistory.group(stepName)` as now, each part on its shapes. The one-shape forms (`run(_:on:with:)`, `run(_:on:choosing:)`, by name too) stay for a text's owner: they check that the command's reach is that shape. `when` is not asked again, as now.

7. **`SlashCommandTyping`** (`SlashCommandTyping.swift:72`) holds a target: `init(over:target:commands:arguments:takesShapes:)`, the `owner:` init kept as `.text(owner)`. Every `commands(for: owner)`, `command(named:for: owner)` and `run(… on: owner …)` goes through the target. Two additions for the bar ([04](04-the-command-bar.md)), inert for a text: `takesShapes: false` leaves the commands that take a shape out of its lists, its marks and its Return (a field that can't name a shape couldn't give them one); and `willRun: (@MainActor () -> Void)?`, called once the line is out of the text and before the command runs (`run`, `:309`, and `choose`, `:251`), so the bar can close first.

8. **A row's count** (`SlashCommandPicker.setRows`, `Sources/SlashCommands/SlashCommandPicker.swift:103`): a partial command's detail is its hint and its reach, `type · 4 of 5`, its spoken text `is-a, takes type, acts on 4 of 5 shapes`; `SlashCommandStyle.reach(_:of:)` writes both. A text target is never partial, so no row in a note changes.

9. **The registry's report** doesn't change: a contribution's summary is its names and its target (`/flip /grow → box`). The reach is the form's, read where it's written.

### `Package.swift`

Nothing.

### Tests: SlashCommandsTests

Fixtures only, as now (CanvasTesting's boxes, discs and cards; `Lamp`; `CardCommandsPlugin(log:)`; `ChoicePlugin(log:)`), plus:

- `CardCommandsPlugin` gains `heap` (`SlashCommand.together`, logs the ids it's handed and how many times), `nudge-each` (a `perform` with `reach: .each`), and a `turn-on` of the card's own, beside Lamp's; `grow` (an `edit`) is `.each` by its form.
- A scope's command over boxes and cards both (`forShapes(adopting: .box)`, `tag`), so a mixed target has a command every kind takes.
- `ChoicePlugin` gains `pick-all` (`together`: rows made from the owners it's handed, `CommandLog.choiceOwners`).
- `FreezingPlugin` (CanvasTesting's `Frozen`) and a declared command of the target's own that acts on frozen cards (`thaw`, beside `DeclaredCommandTests.swift`'s).

`slashTargetTests` (new, `TargetTests.swift`), driven headlessly through `editor.slashCommands`:

- A target of one lists what `commands(for: id)` listed, in its order, none partial; a `.text` target on a frozen card lists nothing, a `.selection` of it only `thaw`.
- A mixed target (two cards, a box, a disc) lists what some shape offers, the first shape's order then the rest; each command's `shapes` and `targetCount`; `when` narrowing a reach.
- `.one` left out of a target of two; listed for a target of one of its kind among others' (a selection of one card).
- `grow` on three cards: one transaction, one undo step named "Grow", undone whole; `nudge-each` run once per shape, one step; `heap` handed the reach once, in target order.
- A declared command asked over its reach (a mix it can and can't act on), `tries:` offered by `when` alone; read-only shapes reached by nothing else.
- Lamp's `turn-on` and the card's: one row, each kind's own run on its shapes, one step; a choice of one name that is two commands left out.
- `pick-all`'s rows asked once with the owners; a pick run on all, one step named by the row.
- A shape gone between finding and running: run on the rest; none left, false and no step.
- The memo: a selection target asked twice at one revision reads its records once (a debug-build count, `SlashCommandState.recordsRead`), and again after a commit.
- The picker's rows: a partial command's detail and spoken text; a whole one's unchanged.

Every existing suite stays as it is: the text surface is `.text(owner)`. Add the new suite to `Tests/SlashCommandsTests/main.swift`'s `runTests` (test.sh fails a declared suite left out).

### Docs (same commit)

- `.claude/rules/slash-commands.md`, Architecture: the first bullet's account of what a shape offers and running, around targets and reach; a bullet of its own for `SlashTarget`, `SlashReach`, the listing rule and running on a reach. Testing: `slashTargetTests` and the new fixtures.
- `docs/plugin-system.md`, "Slash commands": the forms table in "Registering commands" (`:7321`) gains the reach column and the `together` forms; a short "On several shapes" after it, with the listing rule and why a form must say (the `/move-near` and nested-frames examples).

## Verification

- `./build.sh audit` passes (no graph change).
- `./test.sh`; to iterate, `build/debug/SlashCommandsTests/SlashCommandsTests`. Every suite of SlashCommandsTests, MentionsTests' `slashTests`, TitlesTests, LockingTests, PublishingTests, TransformTests, ColorsTests, TypesTests and MovingTests unchanged and green: they all type into a text, the one target that existed.
- In the app: nothing changes. `/lock` and `/title` in a note, `/is-a` in an arrow's label, as before.

## Risks and open questions

- **`.each` as an edit's default.** A plugin's edit command becomes plural with no word from it. Every edit is over one shape's value, so running it on each is what it means; the one shipped edit, `/title`, says `.one` in [02](02-shipped-commands-on-several-shapes.md), before any surface reaches several shapes.
- **Two commands of one name in one target.** No shipped command has it (every shipped one is a scope's, one object on every kind). The rule mirrors the context menu's (each kind's own runs on its shapes) and leaves out what can't be merged.
- **The memo** is keyed by `editor.revision`, which every commit moves; a command whose `when` or rule reads something no commit changes (none does) would be stale until the next one. Its `boardDidChange` empties it.
- **The `together` factories' generic `Value`** is inferred from the builder (`SlashCommandBuilder<Value>.buildExpression`), as an `init` is now. If Swift won't infer it from a static call, they become initializers with a first label (`SlashCommand(together: "move-to", …)`).

## Not in this commit

- Any shipped command's reach ([02](02-shipped-commands-on-several-shapes.md)).
- Any surface that makes a `.selection` target ([04](04-the-command-bar.md)).
