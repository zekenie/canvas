# 05 · Shapes named in the bar: Mentions gives the bar its field

**Commit title:** The command bar types in Mentions' text where Mentions is installed, so a command that takes a shape is typed on a selection: `/move-to @Roadmap` moves the shapes selected into it as one block

**Depends on:** [04](04-the-command-bar.md).

## The ask

"i want to make them a function of selection, this will open them up to all shapes." [02](02-shipped-commands-on-several-shapes.md) made `/move-to` and `/move-near` move several shapes as one block; until the bar's field can name a shape, the bar leaves them out ([04](04-the-command-bar.md), `takesShapes: false`). Moving's own list of what's not built has "moving several selected shapes with a command" (`.claude/rules/moving.md`).

## What it looks like

```
   ┌────────┐ ┌────────┐ ┌────────┐
   │ Milk   │ │ Eggs   │ │ Coffee │          three notes selected
   └────────┘ └────────┘ └────────┘
   ┌────────────────────────────────────────┐
   │ /move-to @Roa▍               3 shapes  │
   └────────────────────────────────────────┘
               ┌──────────────────────────────────┐
               │▌▢ Roadmap                        │   the @ picker: only what takes all three,
               │ ▢ Road trip        Plans › 2026  │   nearest the selection first, on every board
               └──────────────────────────────────┘

   Return picks Roadmap, a pill in the field; Return again moves the three into it, as one block,
   kept where they are to each other.  Edit › Undo Move
```

## Justification

- **SlashCommands knows no mention.** A command that takes a shape is given one by its host's reader ("the module knows no mention, so a pill is a shape only because the host reads it so", `.claude/rules/slash-commands.md`; `SlashCommandTyping(… arguments:)`, `Sources/SlashCommands/SlashCommandTyping.swift:72`).
- **Mentions' text view is that host everywhere else.** `MentionTextView` makes its `SlashCommandTyping` with its pill reader (`Sources/Mentions/MentionTextView.swift:112`) and opens the `@` picker with the kinds and the rule of the command on the line, so it lists only what the command takes (`openPicker`, `:558`, asking `admittedShapes(at:)`).
- **Mentions imports SlashCommands** (`Package.swift:276`), so SlashCommands can't import it. The bar asks for its field through a point it declares, and Mentions fills it, as the owner of a meaning fills an engine's point everywhere else (`Package.swift`, the comment over the graph: "a word in a language is given by the module that owns its meaning, as a plugin value of its own, through the engine's points"). A plugin value of its own, so a list with Mentions needs no bar.
- **The `@` picker measures nearness from one owner**: `MentionState.candidates(matching:in:for owner:…)` (`Sources/Mentions/MentionState.swift:435`) takes its origin from the owner's bounds (`:484`) and leaves the owner out (`:495`). The bar has no owner; it has the selection, whose middle is where "near" is, and none of whose shapes is a place to move it to.

## Tactics

### Code

1. **SlashCommands: the point** (`SlashBar.swift`): `SlashBarFields`, owned by `slash-bar`, at most one contribution (keyed by one key, as `PressFocused` is: `.claude/rules/keyboard.md`; the report's word `slash bar field`):

   ```swift
   /// The field the command bar types in, from the one plugin that gives it (Mentions', whose pills are
   /// shapes a command can take); without one, the bar's own, which reads what's typed as text.
   @MainActor
   public struct SlashBarField {
       public let view: EditingTextView
       public let typing: SlashCommandTyping
       /// Whether what's typed can name a shape: the commands that take one are listed only then.
       public let namesShapes: Bool
   }

   extension PluginRegistrar {
       public mutating func slashBarField(_ make: @escaping @MainActor (CanvasEditor, SlashTarget, SlashBarFieldEvents) -> SlashBarField)
   }
   ```

   `SlashBarFieldEvents` is what the bar needs to hear from whatever field it's given (Escape with no list open, the keyboard leaving, the text emptied, and the `willRun` it hands the typing object), so Mentions' field closes the bar exactly as the bar's own does. `SlashBar.open` asks the point first; `canOpen` counts the commands that take a shape only with a field that names one.

2. **Mentions: `MentionSlashBarPlugin`** (`MentionSlashBar.swift`, id `mention-slash-bar`): fills `SlashBarFields` with a `MentionTextView<AnyMentionable>`:
   - one line, as the bar's own field (Return and Tab with nothing to pick insert nothing, line breaks pasted as spaces, every substitution off);
   - in a style of its own, `MentionStyle.barText` (the bar's 13 points, the label's color, a neutral surface, so its pills are tinted, as the panel's are);
   - no owner (no shape owns the bar's text, and it's never written to the board);
   - hosting slash commands for the bar's target: `MentionTextView.hostSlashCommands(for: SlashTarget, events:)`, beside the owner's path at `:112`, which makes its `SlashCommandTyping(over:target:commands:arguments:)` with the pill reader it has now;
   - `namesShapes: true`.

3. **The `@` picker for a set of shapes**: `MentionPicker(at:mentions:scope:owners:kinds:admitting:)` and `MentionState.candidates(matching:in:for owners: [ShapeID], …)`: the origin is the middle of the box around them, and each of them is left out; one owner is exactly today's. `MentionTextView.openPicker` passes its target's shapes (one for a text's owner, the selection for the bar).

4. **Moving**: nothing; its commands were made plural in [02](02-shipped-commands-on-several-shapes.md), and the bar now lists them.

### `Package.swift`

- What ships: `"Mentions.MentionSlashBarPlugin"` right after `"Mentions.MentionsPlugin"` (after `SlashBarPlugin`, whose point it fills, and Mentions, whose view it makes), with a comment: "Mentions' text as the command bar's field, so its pills are shapes a command takes".
- No module's dependencies change: Mentions imports SlashCommands already.

### Tests

- **MentionsTests `slashBarFieldTests`** (new; `mentionHarness`'s fixtures with `SlashBarPlugin()` and `MentionSlashBarPlugin()`, a `CanvasView` in an unshown window; `SlashFixturesPlugin`'s `stack`, one plate, and `shelve`, a plate or a token by its kinds, made `together` for the test): the bar's field is Mentions'; `/stack @` on three jots selected lists only the plates the command admits for all three, nearest the selection's middle first and none of the three; Return picks, a second Return runs on the three, one step; a token's pill put in the line some other way leaves it text (not accepted, Return does nothing); `/shelve @`'s kinds; without `MentionSlashBarPlugin()` the bar's own field, which lists neither command.
- **MentionsTests `admittingTests`**: `candidates(…for owners:)` with several owners (the origin their middle, each left out) and with one (unchanged).
- **CompositionTests `slashBarShippedTests`**, extended:
  - three notes selected, `/move-to @` lists only the titled frames and subboards that take all three, nearest first; Return picks Roadmap, Return runs: the three land in it as one block, kept where they are to each other, 40 in from its top-left, one step, Undo Move takes it back;
  - `/move-near @Milk`: the block beside Milk;
  - `/move-to @` a subboard: onto its board, the window staying on the board shown;
  - two notes and the arrow between them: `move-to · 2 of 3`, and the arrow rides along, both its ends moving;
  - a frame too small for the block isn't listed.
- **ShippedTests**' report: `mention-slash-bar  slash bar field` (and the guide's copy).
- **BenchmarkTests**: `Budget.slashBarPickerOpen`, the `@` on `/move-to`'s line with 1,000 notes selected on a board of 10,000 and five frames (the kinds' members, as the `@` picker's benchmark on a command's line has them, `.claude/rules/benchmarks.md`), set from the first quiet run.

### Docs (same commit)

- `.claude/rules/mentions.md`: the bar's field (`MentionSlashBarPlugin`), the picker over a set of owners.
- `.claude/rules/slash-commands.md`: `SlashBarFields` and `SlashBarField`; a command that takes a shape is listed in the bar only with a field that names one.
- `.claude/rules/moving.md`: typed on a selection; "Not built: moving several selected shapes with a command" goes.
- `docs/plugin-system.md`: the bar's subsection gains this plan's wireframe; Mentions' section, the bar's field.
- `.claude/rules/benchmarks.md`: `slashBarPickerOpen`.

## Verification

- `./build.sh audit` passes (no new edge).
- `./test.sh`; MentionsTests, MovingTests and CompositionTests to iterate.
- `./build.sh bench`: `slashBarPickerOpen`.
- In the app: three notes, `/move-to @`, the picker's list, a pick, Return, Undo Move; a subboard as the destination; `/move-near`.

## Risks and open questions

- **`MentionTextView` in one line.** It's a note's editor and the panel's box, both several lines; one line is what `JumpToTextView` does to an `EditingTextView` (`Sources/JumpTo/JumpToPalette.swift:194`, `:260`), and the same switches apply. If they fight Mentions' layout of pills, the bar's text can be a subclass in Mentions.
- **"Recent" in the picker** is the window's recent picks; nothing about a selection changes it.
- **The rule asked of each candidate is a block's**: `Drop(owners, to: place, in:)` reads the owners once per candidate place. Places are the few frames and subboards (its `kinds`), so it costs what they are times the selection; the budget holds it.

## Not in this commit

- The reach drawn on the canvas ([06](06-the-reach-on-the-canvas.md)).
- `/move-near @X below` (naming the side), as Moving's not-built list has it.
