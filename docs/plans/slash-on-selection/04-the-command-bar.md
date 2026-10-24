# 04 · The command bar: `/` on the canvas, under the selection

**Commit title:** `/` on the canvas opens the command bar under the selection, a line where a slash command is typed for the shapes selected and run on them with Return; typing in a shape's text keeps its own `/`

**Depends on:** [01](01-targets-in-the-engine.md), [02](02-shipped-commands-on-several-shapes.md), [03](03-cards-shown-zoomed-out.md).

## The ask

"if you have a sticky selected, and you hit slash, that enters a different mode. beneath your selection you have a slash command that you're typing, similar to today. you hit enter and it executes. if you are _typing_ in the sticky, then you have the same behavior as today."

## What it looks like

The README has the flows ([What it looks like](README.md#what-it-looks-like)). The bar itself:

```
   ┌──────────────────────────┐
   │ Groceries                │   the selection
   └──────────────────────────┘
   ┌────────────────────────────────────────┐
   │ /color bl▍                  Groceries  │   a card: the white box and its shadow,
   └────────────────────────────────────────┘   280 × 28 view points at every zoom,
     ╰─────── the field ───────╯ ╰─ what it      4 points under the selection's bounds,
                                    acts on       left edges together
    ┌──────────────────────────────┐
    │▌( ● Blue )                   │   the list: every caret list's, under the "/"
    │ ( ● Brand Blue )             │
    └──────────────────────────────┘
```

Where there's no room below, the card goes over the selection (the card's rule) and the list over its line (every caret list's):

```
    ┌──────────────────────────────┐
    │▌lock                         │
    │ public                       │
    └──────────────────────────────┘
   ┌────────────────────────────────────────┐
   │ /▍                          Groceries  │
   └────────────────────────────────────────┘
   ┌──────────────────────────┐
   │ Groceries                │
   └──────────────────────────┘
  ═══════════════════════════════════════════════ the window's bottom
```

Zoomed out, where shapes are skeletons, it's the same size, and works the same:

```
   ▭ ▭ ▭ ▭ ▭ ▭ ▭ ▭      forty notes selected at 20%
   ▭ ▭ ▭ ▭ ▭ ▭ ▭ ▭
   ┌────────────────────────────────────────┐
   │ /color red▍                 40 shapes  │
   └────────────────────────────────────────┘
```

What it acts on, at its right: one shape is called as VoiceOver calls it (its title, else its kind: `editor.accessibleDescription(of:)`'s name), several are counted ("40 shapes").

## Justification

- **`/` is free on the canvas.** No shortcut names it (the one menu key with it is Help › Keyboard Shortcuts, ⌥⌘/, `Sources/CanvasUI/BoardMenus.swift:139`), and typing the canvas doesn't take stops there ("typing (`insertText:`) stop[s] at the canvas, so a stray key doesn't beep", `.claude/rules/keyboard.md`). Keyboard answers a chord of punctuation held with ⇧ as the chord without it ("when ⇧ may be only what typed it"), so a German keyboard's ⇧7, which types `/`, opens the bar too.
- **Typing in a note keeps its `/`.** While a shape is edited its text view has the keyboard, so the canvas never sees the key; and the command runs `.whenIdle` (no press, nothing edited: `Sources/Canvas/Plugins/Commands.swift`, `CommandMoment`), so a `/` that reached it then would pass.
- **The text surface's machinery serves a field as it serves a note.** `SlashCommandTyping` works over any `EditingTextView` (`Sources/SlashCommands/SlashCommandTyping.swift:72`): the names list, completing, the choices list, the marks and Return. After [01](01-targets-in-the-engine.md) it types for a target. A one-line `EditingTextView` exists already in Jump To's palette (`JumpToTextView`, `Sources/JumpTo/JumpToPalette.swift:149`: one line, Return and Tab with nothing to pick insert nothing, `closesListOnTab` false, so modal).
- **The card hangs it under the selection** ([03](03-cards-shown-zoomed-out.md), decision D5): under a world rect, over it where there's no room below, inside the clear part of the view, following the camera, with the keyboard given to the field and back to the canvas, closed by a press elsewhere, another board, an undo or editing, and named for VoiceOver (`.claude/rules/editor.md`, Cards).
- **The selection is Selection's**: `editor.selectedShapeIDs`, `editor.selectionBounds` (kept by the selection's revision, `.claude/rules/selection.md`), `registrar.selectionChanged` (`SelectionObservers`), `editor.revealIfOffscreen(_:)`.
- **Where it lives.** In SlashCommands, as a plugin value of its own, `SlashBarPlugin`: the house rule for a face a plugin list should be able to leave out (`Package.swift`, the comment over the graph: "A face a plugin list should be able to leave out (Validation's Issues tab) is a plugin value of its own in its owner's module"). So the many lists that hold `SlashCommandsPlugin()` because Titles or Locking needs it (`.claude/rules/slash-commands.md`, Testing) need neither `KeyboardPlugin()` nor `SelectionPlugin()`. SlashCommands then imports Keyboard and Selection, both platform modules that import nothing of it: no cycle, no rung crossed. A module of its own would break the layers plan's fifth rule ("A module splits from another only when something must build without the other, or a layer forbids an import", `docs/plans/layers/README.md`).

## Tactics

### Code: `Sources/SlashCommands`

1. **`SlashBar.swift`** (new): the plugin.

   ```swift
   extension PluginID { public static let slashBar: PluginID = "slash-bar" }
   extension CanvasCommand { public static let runSlashCommand: CanvasCommand = "runSlashCommand" }

   /// The command bar: `/` on the canvas, with shapes selected, opens a line under them where a slash
   /// command is typed for them (`SlashTarget.selection`) and run on them with Return.
   public struct SlashBarPlugin: ListedPlugin {
       public init() {}
       public var id: PluginID { .slashBar }

       public func register(into registrar: inout PluginRegistrar) {
           registrar.service { SlashBar(editor: $0) }
           registrar.command(.runSlashCommand, title: SlashBarStyle.commandTitle, shortcut: KeyChord("/"), runs: .whenIdle,
                             isEnabled: { $0.editor.slashBar?.canOpen(on: $0.shapes) ?? false }) { $0.editor.slashBar?.open(on: $0.shapes) }
           registrar.selectionChanged { editor, _, _ in editor.slashBar?.close() }
           // D10: Run Command… in the selection's menu, so the Shape menu, showing its key.
           registrar.contextMenuForCanvas { MenuItem(command: .runSlashCommand, in: SlashBarMenuGroup.self) }
       }
   }
   ```

   `SlashBarMenuGroup` is a group of its own, `.before(SelectionMenuGroup.self)`: last before Delete, where a menu's general items go. An item for every menu, not a scope's: it shows while the command can act on the menu's shapes, so never on empty canvas, and it's in the Shape menu, since no menu bar item runs the command (`.claude/rules/context-menus.md`, the selection's menu).

2. **`SlashBar`** (`SlashBar.swift`, a service, `editor.slashBar`; conformances in extensions):
   - `canOpen(on:)`: some shapes, and `editor.slashCommands?.commands(for: .selection(shapes))` lists something the bar's field can take (no command that takes a shape while the field names none: [05](05-shapes-named-in-the-bar.md)).
   - `open(on:)`: `editor.revealIfOffscreen(shapes)` (as Delete and a nudge do, so what the key acts on is in view: P7); the field (the `SlashBarFields` point's, [05](05-shapes-named-in-the-bar.md); here always the bar's own); the card:

     ```swift
     CanvasCard(id: SlashBarCard(), anchor: editor.selectionBounds, view: SlashBarView(field: field, acting: label),
                firstResponder: field, accessibilityLabel: SlashBarStyle.accessibilityLabel(for: label),
                size: { room in CGSize(width: min(SlashBarStyle.width, room.width), height: SlashBarStyle.height) },
                showsZoomedOut: true, didClose: { [weak self] reason in self?.didClose(reason) })
     ```

     then a `/` given to the field as typed (`insertText`), which opens the names list (`SlashCommandTyping.didType`; the field is in the window by then: `CanvasView` adds the card's view as the editor tells it, `editorCardDidChange`).
   - `close()`: closes its own card (`editor.closeCard()` while `editor.card` is the bar's).
   - Following: while open, `documentDidSettle` moves the card to the selection's bounds now (`editor.moveCard(to:)`: a drag or an agent's draw that moved the selection).
   - It keeps nothing per shape, and `boardDidChange` closes it (the card hears `.board` too).

3. **The field** (`SlashBarTextView.swift`): `SlashBarTextView`, an `EditingTextView` of one line as `JumpToTextView` is (`maximumNumberOfLines = 1`, line breaks pasted as spaces, `insertNewline` and `insertNewlineIgnoringFieldEditor` nothing, `closesListOnTab` false, every substitution off: it types commands, not prose), hosting `SlashCommandTyping(over: self, target: .selection(ids), commands:, takesShapes: false, willRun:)` and handing it what it's told (`didType`, `didChange(isEdit:)`, `takesKey`, `caretListWindow`), as SlashCommandsTests' `SlashTextView` does (`Tests/SlashCommandsTests/Support.swift`). Its accessibility label is "Command". `onEscape` (with no list open: a list's Escape is the list's), the text emptied (the `/` deleted) and the keyboard leaving it (`onLeave`, as Jump To's field) close the bar.

4. **`SlashBarView`**: the field, and at its right what the bar acts on (`SlashBarStyle.label`, secondary): one shape's name (`editor.accessibleDescription(of:)`'s, its title first, else its kind), or "5 shapes".

5. **`SlashBarStyle`** (`@MainActor` enum, the module's style): `width` 280 (the list's 240 and room for what it acts on), `height` 28, the font the panel's 13 points, `commandTitle` "Run Command…", `fieldLabel` "Command", `shapes(_:)` "5 shapes", `accessibilityLabel(for:)` "Command for Groceries", `acted(on:of:)` "on 3 of 5 shapes".

6. **Running** (the field's `willRun`, [01](01-targets-in-the-engine.md)): the line is out of the field, the bar closes (the canvas has the keyboard back), then the command runs on its reach in one undo step, and VoiceOver hears the step's name, with "on 3 of 5 shapes" where it reached fewer than the selection (`editor.announce`). A command that begins editing (New type) or shows a card (an arrow's card, one day) then does so from the canvas, as from a key.

7. **`SlashCommandsPlugin`** keeps its key hint, `/ at a Line's Start, Run a Command`, under Editing Text (`Sources/SlashCommands/SlashCommands.swift:152`).

### The keys

Every caret list's keys are the list's while it's open (`Sources/TextEditing/EditingTextView.swift`, `holdsKeys`); the bar adds only what a one-line field must say.

| Key | In the bar |
|---|---|
| `/` on the canvas, with a selection that offers something | opens it, the selection brought into view first |
| `/` with nothing selected, or a selection that offers nothing, or while a shape is edited | as today: passes, or is the text's |
| typing | narrows the list: the names, then a choice's rows |
| ↑ ↓, ⌃P ⌃N, Page Up, Page Down | the list's |
| Tab | completes the highlighted row; with nothing to complete, nothing (modal, as Jump To's palette) |
| ⇧Tab | closes the list |
| Return | as today: runs the highlighted command that takes nothing, completes one that takes something; with the list closed, runs a whole line; on anything else, nothing (one line) |
| Escape, ⌘. | closes the list if one is open, else the bar: the canvas has the keyboard, the selection as it was |
| ⌫ over the `/` | closes the bar |
| ⌘Z, ⇧⌘Z | the field's own undo, as any field's while it has the keyboard |

### Closing

Any of: Escape, ⌘. or the `/` deleted; a run (before the command runs); the selection changing (`selectionChanged`), so the bar never acts on what it wasn't opened for (D7); its field giving up the keyboard (a click on the canvas, on the selection itself too, the panel, Jump To, Find: D7); and every closing a card has (`.pressedElsewhere`, `.board`, `.undo`, `.editing`, `.replaced`, `.leftView`). Opening the bar closes a card that shows (`.replaced`): one card at a time, as now.

### `Package.swift`

- `.target(name: "SlashCommands", dependencies: ["Canvas", "ContextMenus", "FuzzyMatching", "Keyboard", "Selection", "TextEditing"])` (`:265`; ContextMenus only for D10's item).
- `SlashCommandsTests` (`:349`) adds `CanvasUI` (the window, which a test of any module may use), `ContextMenus`, `Keyboard` and `Selection`, now SlashCommands' dependencies.
- What ships (`:131`): `"SlashCommands.SlashCommandsPlugin", "SlashCommands.SlashBarPlugin",`, and its comment says the bar ("Slash commands: the list at a `/` in the text views Mentions hosts it in, and the bar `/` opens under the selection"). After Keyboard, Selection and ContextMenus, whose points it fills.

### Tests

**SlashCommandsTests `slashBarTests`** (`BarTests.swift`, new): a `CanvasView` in an unshown window (as JumpToTests' `PaletteTests` and SelectionTests' `PartsTests` host one), 01's fixtures with `KeyboardPlugin()`, `SelectionPlugin()`, `ContextMenusPlugin()`, `SlashCommandsPlugin()` and `SlashBarPlugin()`, keys as the keyboard sends them (CanvasTesting's `KeyDriver`, `KeyWalk`):

- Opening: `/` with a card selected opens the bar 4 points under the selection's bounds, left edges together; nothing selected, or a disc (which offers nothing), nothing; a card being edited (its `SlashTextView`) opens its own list in its text and no bar; ⇧7 typing `/` (a German layout's event) opens it; an offscreen selection is brought into view first.
- The list: what the selection offers, counted on a mix (01's fixtures); narrowing; Tab; a choice's rows; the marks.
- Running: Return runs on the reach, one step named for the command, the bar gone, the canvas with the keyboard and the selection kept; a pick; a whole line with the list closed; Undo takes it back whole.
- Closing: Escape (the list, then the bar), ⌘., ⌫ over the `/`, a click on the canvas off and on the selection, the selection changed by a key (Tab), another board, an undo, another card shown, the keyboard given to another view.
- Following: a commit that moves the selection moves the bar; at the window's bottom the bar goes over the selection.
- Zoomed out (`skeletonZoom` above the zoom): shown, the same size.
- Read-only: a frozen card's bar lists `thaw` and nothing else.
- VoiceOver (`AccessibilityProbe`): the card's label, the field's, a partial row's spoken text, the announcement after a run.
- The walk (`KeyWalk`): `/`, a command, Escape twice, back on the canvas with the selection (P5); Tab in the bar with nothing to complete moving nothing (the stated exception, as Jump To's); every key with no use in the bar changing no document (P8).
- The Keyboard Shortcuts rows (Run Command… `/` once, under Canvas) and the report's line.

**CompositionTests `slashBarShippedTests`** (new, `SlashBarShippedTests.swift`; the shipped list in a `BoardWindow`, a pasteboard of its own):

- A note: `/`, `col`, Return, `bl`, Return: blue, the bar gone; Undo Change Color.
- Two notes and a frame: `/color` colors all three, one step. A note and a reference: `color · 1 of 2`.
- Ten notes: `/is-a feat`, New type “Feat”: ten Features, one step, the new type edited.
- A frame: `/turn-into-subboard` (typeable nowhere before): a subboard whose board holds what the frame held.
- A locked note: `/` lists `unlock` alone; Return unlocks it, one step "Unlock".
- A note being edited: a `/` on a new line opens the list in the note and no bar (beside `slashCommandsShippedTests`, unchanged).
- D10: Run Command… in a note's right-click menu and in the Shape menu, showing `/`; chosen, it opens the bar.

**Other shipped tests that move**: `keyboardShortcutsShippedTests` (`/` listed once, under Canvas); ShippedTests' registry report (`slash-bar  service SlashBar · command runSlashCommand · shortcut / → command runSlashCommand · …`, exactly as the report writes it, and the guide's copy, `docs/plugin-system.md:14249`); `reachCensusTests` (Run Command… is a context-menu item with a key); `keyMeaningsShippedTests` unchanged (`Chord.inert`, `Tests/CanvasTesting/Keys.swift:136`, holds no `/`; if it ever does, opening the bar isn't inert).

**BenchmarkTests**: `Budget.slashBarOpen` (`/` on 10,000 selected notes: the list made once and the card shown) and `Budget.slashBarKeystroke` (a keystroke in it: 01's memo and the list's ranking), held by `./build.sh bench`, each set from the first quiet run.

### Docs (same commit)

- `CLAUDE.md`, the map: "[slash commands](.claude/rules/slash-commands.md): commands typed on a line of a shape's text, and in the command bar `/` opens under the selection".
- `.claude/rules/slash-commands.md`: a bullet for the bar (all of the above), and its Testing.
- `docs/plugin-system.md`, "Slash commands": the opening paragraph, and a subsection "The command bar" with this plan's wireframes and the README's flows.
- `.claude/rules/keyboard.md`: the `/` command and where the Keyboard Shortcuts window files it.
- `.claude/rules/keyboard-navigation.md`, "How the app meets them": the bar (P1: every command on every shape by keys; P5; P8; P9), and Tab in the bar beside Jump To's in the table's named exceptions.
- `.claude/rules/context-menus.md`: Run Command… (D10).
- `.claude/rules/accessibility.md`: the bar's names and what's announced after a run.
- `.claude/rules/transform.md`: `/turn-into-subboard` is typed in the bar; "typeable nowhere in the app yet" and the not-built "`/` typed on the canvas" go.
- `.claude/rules/locking.md`: `/unlock` is typed in the bar.
- `.claude/rules/benchmarks.md`: the two budgets.

## Verification

- `./build.sh audit`: the new edges (SlashCommands to Keyboard, Selection, ContextMenus) pass, no cycle; `./build.sh graph` shows them.
- `./test.sh`; SlashCommandsTests and CompositionTests to iterate.
- `./build.sh bench`: `slashBarOpen`, `slashBarKeystroke`.
- In the app (what no test can see):
  - Select a note, `/`, `col`, Return, `bl`, Return. Two notes and a frame. Ten notes and `/is-a`.
  - The bar under the selection, and over it at the window's bottom; following a pan and a pinch; at 20%.
  - The selection's outline gray while the bar has the keyboard (P7), and the accent again after.
  - With VoiceOver (⌘F5): the bar's name as it opens, the rows, the announcement after a run.
  - A German input source: ⇧7.
  - Right-click a note: Run Command… with `/`; the Shape menu the same.

## Risks and open questions

- **A press on the selection while the bar is open.** The card treats the rect it hangs from as its own ground (`pressIsOnCard`), so that press doesn't close it as a card; the field giving up the keyboard does, if the canvas takes it on a press. The tests hold which happens; if the canvas doesn't take it, the bar closes on the press through `SlashBar` hearing the press's selection change, or not at all for a drag, and follows the selection.
- **The `/` given to the field** must be given once the field is in the window, or the list has no window to open in. `CanvasView` adds the card's view as it's told; the tests over a real `CanvasView` hold it.
- **D10** costs SlashCommands an import of ContextMenus, which every module importing SlashCommands then compiles against. Leave the item out and that import goes.
- **D7**: closing on any selection change also closes it when an agent's commit deselects a shape. Rare, and the right answer for a list made for the old selection.
- **The selection's size.** 10,000 shapes: the budgets say. A list made for 10,000 records once at the `/`, kept by 01's memo through the keystrokes.

## Not in this commit

- Commands that take a shape (`/move-to @…`), not listed until the bar's field can name one ([05](05-shapes-named-in-the-bar.md)).
- The reach drawn on the canvas ([06](06-the-reach-on-the-canvas.md)).
- `/` with nothing selected (D8), `/` in the table of contents, recalling the last command (README, Considered and not planned).
