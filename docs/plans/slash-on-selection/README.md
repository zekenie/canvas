# Slash commands on the selection: the command bar

A plan for the owner's ask of 2026-10-24, in six commits (the sixth optional). Each file here is one commit: what it answers, why it's right, and what to do. They're numbered in the order to land them. This was planned in a cloud session without the Swift toolchain, so every plan ends with what to run on the Mac (`./build.sh audit`, `./test.sh`, `./build.sh bench`, the app). Line numbers are from `d368787`.

## The ask

> I have a new direction for slash commands. currently they are only in use on stickies. this is limiting. You can't, for example, do a slash command on a sub-board or a frame, or a reference. i want to make them a function of selection, this will open them up to all shapes. But they still work in stickies.
>
> if you have a sticky selected, and you hit slash, that enters a different mode. beneath your selection you have a slash command that you're typing, similar to today. you hit enter and it executes.
>
> if you are _typing_ in the sticky, then you have the same behavior as today.
>
> That means that if have two nodes selected and you type /color blue it applies to both. If you have 10 selected you can is-a foo andthey all become foo. This will require some logic that is not in place today because some of the selection may not support all the same commands. we need to think this through.

## In short

- **`/` on the canvas, with shapes selected, opens the command bar**: a one-line field just under the selection, holding a `/` and the list today's `/` opens in a note. Return runs the command on the selection, the bar goes, and the selection stays. Typing in a note is unchanged.
- **The engine stops assuming one shape.** A command is typed *for a target*: one shape's text (today's) or the selection (new). Each command says *how it acts on several shapes*: on one only, on each, or on all together. The commands that already take several (Lock, Make Public, Make Private) do so with no change.
- **A mixed selection lists every command some of its shapes take, and a row says "3 of 5"** where it reaches fewer than all. Return acts on those it reaches, in one undo step. The other answer, listing only what every shape takes (the context menu's rule), is one line to change: decision D1 below.
- **What it opens up:** `/turn-into-subboard` on a frame (typeable nowhere today: `.claude/rules/transform.md`), `/unlock` on a locked shape (unreachable from text: `.claude/rules/locking.md`), `/color` and `/is-a` on many shapes at once, `/move-to` of a whole block (`.claude/rules/moving.md`, "Not built: moving several selected shapes with a command"), and every command on frames, subboards and references, which have no text to type in, and on an arrow without editing its label.

## What it looks like

Low fidelity: boxes are shapes, `▍` is the caret, `▌` the highlighted row. The list under the bar is the app's one caret list (TextEditing's `CaretListWindow`), as it is in a note today. They show the end state: the commands that take a shape (`move-to`, `move-near`) are listed in the bar from [05](05-shapes-named-in-the-bar.md) on.

**1. One note selected, `/` pressed.** The bar hangs under the selection, left edges together, the same size at every zoom. At its right, what it acts on.

```
   ┌──────────────────────────┐
   │ Groceries                │   a note, selected (its outline gray while the bar
   │ milk, eggs, coffee       │   has the keyboard, as for any other view)
   └──────────────────────────┘
   ┌──────────────────────────────────────┐
   │ /▍                        Groceries  │   the command bar
   └──────────────────────────────────────┘
    ┌──────────────────────────────┐
    │▌title                  title │   what the note offers, in today's order
    │ lock                         │
    │ public                       │
    │ is-a                    type │
    │ color                  color │
    │ move-to  @frame or subboard  │
    │ move-near             @shape │
    └──────────────────────────────┘
```

**2. A choice, then Return.** Exactly today's two lists, in the bar instead of on a line of the note.

```
   ┌──────────────────────────────────────┐
   │ /color bl▍                Groceries  │
   └──────────────────────────────────────┘
    ┌──────────────────────────────┐
    │▌( ● Blue )                   │   the choices, chips as /color's are today
    │ ( ● Brand Blue )             │
    └──────────────────────────────┘

   Return: the note is blue, the bar goes, the note stays selected.  Edit › Undo Change Color
```

**3. Several shapes, some of which can't.** Every command some shape takes, and how many it reaches.

```
   ┌────────┐   ┌────────┐ ┌────────┐     ┌─────────┐
   │ Milk   │──▶│ Eggs   │ │ Coffee │     │ ⧉ Pantry│   selected: three notes, the arrow
   └────────┘   └────────┘ └────────┘     └─────────┘   between two, and a reference
   ┌──────────────────────────────────────┐
   │ /▍                         5 shapes  │
   └──────────────────────────────────────┘
    ┌──────────────────────────────────────┐
    │▌lock                                 │   all five
    │ public                        3 of 5 │   an arrow and a reference can't be public
    │ is-a                   type · 4 of 5 │   a reference is of no type
    │ color                 color · 4 of 5 │   a reference has no color
    │ move-to @frame or subboard · 3 of 5  │   an arrow has no box: it rides along
    │ move-near            @shape · 3 of 5 │
    └──────────────────────────────────────┘
```

**4. Ten notes, `/is-a`.** One pick, ten notes, one step.

```
   ┌──────────────────────────────────────┐
   │ /is-a feat▍               10 shapes  │
   └──────────────────────────────────────┘
    ┌──────────────────────────────┐
    │▌( {} Feature )               │
    │ New type “Feat”              │   beside the ten, given to all of them
    └──────────────────────────────┘

   Return: all ten are Features.  Edit › Undo Add Type
```

**5. A frame, a locked note.** What has no text gets commands; a locked shape gets the one that frees it.

```
   ┌ Roadmap ─────────────────────┐                ┌──────────────────┐ 🔒
   │  ┌──────┐  ┌──────┐          │                │ Groceries        │
   │  │ Q1   │  │ Q2   │          │                └──────────────────┘
   │  └──────┘  └──────┘          │                ┌────────────────────────┐
   └──────────────────────────────┘                │ /▍          Groceries  │
   ┌────────────────────────────────┐              └────────────────────────┘
   │ /▍                    Roadmap  │               ┌──────────────────┐
   └────────────────────────────────┘               │▌unlock           │
    ┌──────────────────────────────┐                └──────────────────┘
    │▌turn-into-subboard           │
    │ title                  title │
    │ lock                         │
    │ public                       │
    │ color                  color │
    │ move-to  @frame or subboard  │
    │ move-near             @shape │
    └──────────────────────────────┘
```

**6. Typing in a note: unchanged.** The bar never opens while a shape is being edited: the `/` is the text's, as now.

```
   ┌──────────────────────────────┐
   │ Ask about the beta           │   a note being edited
   │ /lo▍                         │   a "/" on an empty line, as today
   │ ┌────────────────────┐       │
   │ │▌lock               │       │
   │ └────────────────────┘       │
   └──────────────────────────────┘
```

**7. How the bar comes and goes.**

```
                "/" with a selection that offers something
   canvas ─────────────────────────────────────────────────▶ bar: "/", the names list
     ▲  ▲                                                     │  type to narrow, ↑ ↓
     │  │   Escape (with no list open), ⌘., the "/" deleted,  │  Tab, or Return on a command
     │  │   a click elsewhere, the selection changing,        │  that takes something
     │  │   another board, an undo                            ▼
     │  └───────────────────────────────────────────── bar: "/color ", the choices
     │                                                        │  (or the text, or the @ picker)
     │                                                        │  Return on a row, or on the line
     └────────── the bar closes, then the command runs ◀──────┘  one undo step
```

## The model

### A target

`SlashTarget`: what a command line is typed for.

- `.text(owner)`: a line of one shape's text, as today (a note's words, an arrow's label, a panel's box). The shape is being written, so it is never read-only, and `commands(for:)` offers nothing on a read-only one (as now).
- `.selection(ids)`: the bar. The selected shapes, in selection order (`editor.selectedShapeIDs`): a group selected whole is its shapes, and a frame is itself, not what it holds.

### How a command acts on several shapes: its reach

`SlashReach`, the command's own, said where it is registered:

| Reach | What it does on several | Whose default |
|---|---|---|
| `one` | Nothing: it's listed only when the target is one shape (a text's line, or a selection of one). | A `perform:`, `shapes:` or `choices:` command as written today, so nothing becomes plural by accident. |
| `each` | Runs on each shape it reaches, one at a time, in one transaction and one undo step. | An `edit:` command: an edit is over one shape's value by nature. |
| `together` | Runs once, handed all the shapes it reaches. | A declared command (`SlashCommand("lock", command: .lock)`: its rule and its run already take a `CommandSubject` of many), and the new plural forms (`SlashCommand.together(…)`) for what must be done as one: a block moved, nested frames turned innermost first, one type given to many. |

### Which commands a target lists

`SlashCommandState.commands(for:)`, the one place this is decided:

1. For each shape of the target, the commands its kind offers (its own, then the scopes' in plugin order, as today), each whose `when` holds of the shape. A read-only shape (`editor.isReadOnly`: locked, in a locked frame, on a locked subboard's board) is offered declared commands only, whose rule decides: Unlock acts on a locked shape; nothing else does.
2. A command is its name. The shapes that offer it are its **reach**, in target order. Two kinds' own commands of one name are one row, each running its own on its own shapes (as a context menu item of one key is: `Sources/ContextMenus/Resolution.swift:165`). A choice command whose name is two different commands in one target is left out: two lists of rows can't be one.
3. It's listed if its reach isn't empty and: a `one` command only where the target is one shape; a declared command only while its rule can act on its reach (`editor.canPerform(_:on:)`), or by `when` alone with `tries:`.
4. In the order the first shape lists them, then what only later shapes offer, as they list it.
5. A row whose reach is fewer than the target says how many: `3 of 5`.

### Running

As today (`SlashCommandState.run`, `Sources/SlashCommands/SlashCommandState.swift:199`): one undo step, named for the command (its title in words, its `step:`, a declared command's title, a row's `step`), on its reach as found when Return was pressed, `when` not asked again. What a command can't do as a whole it still refuses as it does today: a frame whose turn would move a locked note, a block a locked frame would take. Nothing changes, no step is left, and the refused shapes shake; a declared command's try shakes what it can't change (`/private` on a shape something stands for, as the chip's click does).

## Decisions for the owner

The plans follow the recommendation in each row. Each is isolated so that taking the alternative changes one place.

| # | Question | Recommendation | Alternative | Why |
|---|---|---|---|---|
| D1 | What a mixed selection lists | What **some** shape takes, each row counted (`3 of 5`), acting on those | What **every** shape takes, as the context menu lists (`Resolution.swift:165`); one filter in `commands(for:)` | A typed command says what you want. A marquee picks up the arrows and frames around the notes you meant, and "every" would hide `/move-to`, `/is-a` and `/public` for them. The count keeps it honest. The context menu keeps its rule: a menu shows what applies to all, unasked. |
| D2 | How a command acts on several | The command's author says (`one`, `each`, `together`); defaults by form, so nothing written today becomes plural by accident | Every command plural, by running its one-shape action on each shape | `/move-near` run on each puts shapes beside the target one by one, not as a block; `/turn-into-subboard` run on each turns an outer frame first, whose inner frame is then on another board and isn't turned. |
| D3 | Read-only shapes in a selection | Reached only by declared commands, by their rule (a locked note offers `/unlock` and nothing else) | Reach them and let the core refuse (they shake), as Color ▸ does | A row that can only be refused is noise, and the count stays exact. |
| D4 | `/title` with several selected | `one`: not listed | `each`: every shape gets the same title | A title is how a shape is told apart; Boards warns of two shapes with one path. |
| D5 | What the bar is made of | A core card (`CanvasCard`) with one new flag: shown at any zoom | A view over the canvas (`registrar.hostOverlay`), as Jump To's palette | A card already hangs under a world rect, goes over it where there's no room below, follows the camera, gives its field the keyboard and the canvas it back, closes on a press elsewhere, another board, an undo, and is named for VoiceOver. Only its refusal zoomed out is in the way (`Sources/Canvas/Editor/Cards.swift:99`, `:165`). |
| D6 | Shape arguments (`/move-to @…`) in the bar | From Mentions' field, through a point SlashCommands declares (`SlashBarFields`); without it the bar's own plain field, where commands that take a shape aren't listed | The bar's own picker of shapes | SlashCommands can't import Mentions (Mentions imports it), and the `@` picker that lists only what a command admits is Mentions' already. |
| D7 | The selection changes while the bar is open | The bar closes; it also closes when its field gives up the keyboard | It follows the new selection | A list made for one selection is wrong for another. The field losing the keyboard covers every click elsewhere: the canvas, the panel, Jump To. |
| D8 | `/` with nothing selected | Passes, as today (typing stops at the canvas) | The bar with the board's own commands | There are none yet. |
| D9 | Where the bar goes | Under the selection's bounds, left edges together, over them where there's no room below (the card's rule), at the same size at every zoom | At the pointer; or top middle, as Jump To | The owner's ask ("beneath your selection"), and it shows what it acts on. |
| D10 | A menu item for the bar | Run Command… in the selection's menu, so in the Shape menu, showing `/`: it teaches the key. Costs SlashCommands an import of ContextMenus | The Keyboard Shortcuts window alone | Nobody guesses that `/` does something on a canvas. |
| D11 | Drawing the reach on the canvas | Plan 06, after living with 05: while a partial row is highlighted, the shapes it reaches get a ring | Nothing | The count says how many; the ring says which. |
| D12 | Names | "the command bar", `SlashBar`, Run Command… | | The owner's to rename. |

## Each shipped command, on several shapes

| Command | Owner | Form today | Reach | On several shapes | Not reached |
|---|---|---|---|---|---|
| `/title` | Titles (`Titles.swift:553`) | `edit` over the record | `one` | Not listed (D4) | Kinds with no title |
| `/lock` | Locking (`Locking.swift:130`) | declared `.lock` | `together` | `when: !isLocked`, so the count is exact; Lock locks them | A locked shape |
| `/unlock` (new) | Locking | declared `.unlock` | `together` | `when: isLocked`; Unlock unlocks them. Never in text: a locked shape's text can't be typed in | A shape not locked |
| `/public`, `/private` | Publishing (`PublishMenus.swift:46`) | declared, `/private` a try | `together` | `/public` gains `when: !public` for an exact count; the commands pick out what can change | An arrow, a reference (`NeverPublic`) |
| `/turn-into-subboard` | Transform, for Subboards (`Transform.swift:211`) | `perform` on one shape | `together` | `TransformState.turn(ids, into:)`: innermost first, all or nothing, one step | Every kind but a frame |
| `/color` | Colors (`ColorCommand.swift:46`) | choice, one owner | `together` | The book's names, `None` while any holds a color of its own; `editor.setColor(_:of:)` on all | A reference |
| `/is-a` | Types (`TypeLinks.swift:235`) | choice, one owner | `together` | The rows Is a ▸ lists for a selection (`typeMenuChoices(for:)`, `TypeChoices.swift:107`), less what every one is already; a pick given to those that may take it, one step; `Type` while every one can be a type and none is; New type beside the block, given to all | Frames, subboards, references; an arrow that is an end |
| `/move-to @X` | Moving (`Moving.swift:23`) | takes one shape, for one owner | `together` | As one block, as Move To ▸ moves a selection (`Drop`, `Dropping.swift:41`): kept where they are to each other, one step | An arrow (it rides along when both its ends move) |
| `/move-near @X` | Moving | takes one shape, for one owner | `together` | As one block beside X (`Block`, `Move.swift:48`) | An arrow |

## Order

```
01 targets in the engine ── 02 shipped commands on several ─┐
                                                            ├─ 04 the command bar ─┬─ 05 shapes named in the bar
03 cards shown zoomed out (the core) ───────────────────────┘                      └─ 06 the reach on the canvas (optional)
```

- [01](01-targets-in-the-engine.md) **Targets in the engine.** `SlashTarget`, `SlashReach`, the plural forms, listing and running over a target. The text surface is `.text(owner)` and nothing in the app changes.
- [02](02-shipped-commands-on-several-shapes.md) **Each shipped command says how it acts on several.** Before any surface can run one on several, so `/title` never renames five shapes. `/unlock` arrives, reachable by no surface until 04.
- [03](03-cards-shown-zoomed-out.md) **A card that shows zoomed out.** One flag in the core, held apart because it's the core's and its tests are CanvasTests'.
- [04](04-the-command-bar.md) **The command bar.** `/`, the card, its field, its keys, VoiceOver, what ships. Commands that take a shape wait for 05.
- [05](05-shapes-named-in-the-bar.md) **Shapes named in the bar.** Mentions gives the bar its field, so `/move-to @…` and `/move-near @…` work on a selection.
- [06](06-the-reach-on-the-canvas.md) **The reach on the canvas** (optional, D11).

01 and 03 are independent; 02 needs 01; 04 needs all three; 05 and 06 need 04.

## Rules the plans write down

1. **A slash command is typed for a target**: one shape's text, or the selection. The engine knows which shapes, never which surface draws the line.
2. **How a command acts on several shapes is its author's to say**: `one`, `each` or `together`. A declared command is `together` by nature; nothing else becomes plural without saying so.
3. **A target lists what some of its shapes take, and says how many** (D1). Running acts on exactly those, in one step.
4. **A read-only shape is reached only by a declared command, by its rule.**
5. **Typing in a shape's text is unchanged**: the text surface is the one-shape target it always was.

## Considered and not planned

- **The context menu listing what some shape takes.** It stays "every" (D1): a menu shows what applies to all, unasked, and its items have checks, which "some" would make mixed everywhere.
- **One registry for menu items and slash commands.** Colors contributes Color ▸ and `/color`, Locking Lock and `/lock`, each twice. Declared commands already share their rule and run; the rest stay two contributions. The bar makes the overlap more visible, and a later plan may derive one from the other.
- **`/` with nothing selected** (D8), and **`/` in the table of contents**, whose rows are a selection too: later, once the bar has settled.
- **Recalling the last command** (keyboard navigation's P12, "the last thing done can be done again"): ↑ on an empty bar could bring back the last line run. Small, and better judged after use.
- **Renaming several shapes at once** (`/title Draft 1…n`).
- **A command across boards.** A selection is on the board shown; the commands that move shapes elsewhere (`/move-to` a subboard) already do.
- **SlashCommands in parts** (`Engine`, `Text`, `Bar`). The module grows by the bar; parts would hold the engine's sources apart from the bar's, but not its imports, which are the module's. Worth it if the module passes the size Types was split at.

## Each plan's shape

**Commit title** · **Depends on** · **The ask** (the part of it the commit answers) · **Justification** (what the code and docs show, with file:line) · **Tactics** (code, `Package.swift`, tests and docs, in order, including the topic files CLAUDE.md requires in the same commit) · **Verification** · **Risks and open questions** · **Not in this commit**.
