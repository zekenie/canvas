# Infinite Canvas

A native macOS infinite canvas: a small core, with everything on it (selecting, what each key does,
sticky notes, arrows modeled on tldraw's, validation, a detail panel, a table of contents,
ports to drag arrows from) added by plugins.
The plugin system is a port, in Swift, of the one in data-canvas. Start with
[docs/plugin-system.md](docs/plugin-system.md).

## Build, test, run

```sh
./build.sh && open build/InfiniteCanvas.app
./test.sh
```

`build.sh` calls `swiftc` directly, so it only needs the Command Line Tools (and `jq`, which macOS
includes from 15 on). It builds each module separately, as many at once as there are cores, and
only what changed, and refuses to build if the code and the manifest disagree. `./build.sh graph` prints the module graph,
and `./build.sh audit` checks it without compiling.

## Boards

Each board is a file (`.canvasboard`, JSON) in its own window: File › New, Open, Open Recent, and Save,
as in any Mac document app. Boards save themselves as you work, and File › Revert To goes back to
earlier versions. The first launch opens the welcome board; Help › Welcome Board opens it again.
A board remembers, on each Mac, where you left its view, and whether its minimap and details show.
In the Finder, Quick Look (space) shows a board file's top board, and its icon is a picture of it:
the app carries Quick Look extensions, which macOS finds once the app has been opened (a Mac whose
icons for board files showed their JSON before keeps those until you log out and back in).

## Command line

`canvas` works on the boards open in the app, for agents and for people: each change shows in the
board's window as it's made. It comes with the app (`Contents/Helpers/canvas`, and `build/canvas`
links to it), and asks the running app what it can do, so `canvas help` lists the app's commands.

```sh
build/canvas status                                          # is the app running?
build/canvas boards                                          # the open boards, and which is in front
build/canvas kinds                                           # what a script can draw, and with what (--schema: every property's JSON Schema)
build/canvas draw 'sticky-note "Inbox" text: "Buy milk"'     # a note titled Inbox in the middle of the view, on the board in front
build/canvas draw --board 2 --dry-run - <<'EOF'               # a script on standard input: what it would do, changing nothing
sticky-note "Web" text: "Browser app"
sticky-note "API" right of "Web" text: "Public HTTP API"
subboard "Payments" below "API"
edge "Web" -> "API"
EOF
```

`canvas draw` reads a small language, one statement a line: what a shape is, what it's called, and
where it sits against shapes already named (`right of "API"`, `below board`), never coordinates;
the app works out the distances, keeps what's there clear, and applies the script all at once, or
not at all. A title on the board means that shape, so a script can change or move it, connect it
(`edge "A" -> "B"`) or delete it. The language is taught, for agents, by the canvas skill
([.claude/skills/canvas](.claude/skills/canvas/SKILL.md), with the whole language in
`reference/language.md`), and the plugin guide says how it's built.

Output is JSON when it's piped (as agents run it) and text in a terminal (`--format` picks), errors
come with a hint, and the exit status says what happened: 0 done, 1 the app couldn't do it, 2 the
command line is wrong, 3 the app isn't running or didn't answer in time (it may still do it, so
check before running it again). To run it as just `canvas`, put the link on your PATH:
`ln -s "$PWD/build/canvas" ~/.local/bin/canvas`.

## Controls

| Action | How |
| --- | --- |
| Pan | Two-finger scroll; drag with Space held or with the middle button, whatever the tool; or H (the hand tool) and drag. A fling slides on; V or Escape goes back to select |
| Zoom | Pinch, ⌘-scroll, or ⌘= / ⌘- / ⌘0; ⇧1 fits the board, ⇧2 the selection; also the View menu and the toolbar's zoom menu. A two-finger double-tap zooms to the shape under the pointer, and again back |
| See where you are | The minimap, in the canvas's bottom-left corner: every shape in miniature, and the part the canvas shows outlined. Click beside that part to move there, drag it to move it, double-click to center on a spot. ⌃⌘M shows or hides it |
| New note | Double-click empty space, or N (the note tool) and click |
| Erase | E, then click or drag across shapes (an example plugin) |
| Select | Click a shape, or drag across empty space to select what the marquee touches (⌘: only what it encloses; ⇧: add to the selection) |
| Add to or remove from the selection | ⇧-click (or ⌘-click) a shape |
| Select all | ⌘A, or right-click empty space |
| Move shapes | Drag a shape. With several selected, drag any of them, or the space between them, to move them all; Escape puts them back |
| Nudge shapes | The arrow keys move the selection a point, ten with ⇧; a key held down is one undo step |
| Line shapes up | Drag near other shapes: edges and middles snap to theirs, and to even spaces between them, with red guides. Once dragging, hold ⌘ (or ⌃) to move freely |
| Edit a note | Double-click it (the word clicked is selected), click it once it's selected (the caret goes there), or select it and press Return; Escape or ⌘↩ to finish |
| Edit a shape's details | Select it; the detail panel on the right edits it. Escape gives the keyboard back to the canvas |
| Show or hide the detail panel | ⌃⌘I (View › Show Inspector), or the Inspector button in the toolbar |
| See what's on the board | With nothing selected, the detail panel lists every shape, each arrow under the shape it starts from; with several selected, just those (Show All lists every shape again) |
| Find a shape from the list | Click its row: it's selected and the canvas zooms to it. Pointing at a row outlines its shape faintly, and pointing at a shape tints its row |
| Go back to the previous selection | The back button in the detail panel's header, or ⌘[ (Go › Back): what was selected before, and the view as it was then (from a row's details, the list) |
| Name a note or a subboard | Select it and click its title in the detail panel's header; Return or Escape goes back to the canvas |
| Make a note a type | Type /type on a line of its text and press Return: it holds a JSON Schema (its Schema tab), which Claude keeps saying what its words say, and its words say what the schema holds once you edit the JSON |
| Turn a frame into a subboard | Right-click it and choose Turn into Subboard: the same shape, a subboard at its corner, with everything the frame held on its board; Undo brings the frame back |
| Frame shapes | Select them, right-click and choose Create Frame: a frame around them that holds them, in the frame they're in; what it mostly covers comes in, what it barely touches moves out of its way |
| Delete shapes or arrows | Select them and press Delete, or right-click and choose Delete |
| Cut, copy and paste shapes | ⌘X, ⌘C and ⌘V (Edit menu, or right-click a shape; right-click empty space to paste). ⌘V lands a paste where the originals were if they're in view, else in the middle of the view; Paste from a right-click lands it centered where you clicked. Arrows copied with their shapes stay attached to the copies |
| Link a note to a note or to a subboard | With the select tool, point at one: dots show just outside its four sides (zoomed out below 25%, none show). Drag from a dot to another note, or to a subboard (a subboard's dots link to any of them): those it could link to are outlined faintly as you drag, and released anywhere else, nothing is drawn. The link is an arrow; there's no arrow tool. Arriving quickly aims at the shape's center; arriving slowly, or pausing inside the shape, aims at that exact spot |
| Aim into a shape | Hold ⌥ while linking or dragging an end: the arrow runs all the way to the spot |
| Don't attach | Hold ⌘ while dragging an end |
| Snap angle | Hold ⇧ while dragging an end (15° steps) |
| Re-aim an end | Select the arrow and drag its end handle |
| Bend | Select the arrow and drag its middle handle |
| Toggle an arrowhead | Double-click an end handle |

A shape with an issue (a type whose schema isn't JSON, a title past 80 characters) gets an outline (the validation
plugin: red for an error, orange for a warning; none while it's being edited), says why in an Issues tab of the detail
panel (the validation-details plugin), and gets a dot of the same color on its row in the table of contents (the
validation-contents plugin).
A titled shape shows its title in a pill above its top-left corner (zoomed out below 35%, where shapes are skeletons and show no pill, on the shape itself, large), and in the table of contents (the titles plugin).
Name a note or a subboard in the detail panel's header. A title is
part of its shape's schema, at most 80 characters: a longer one gets a warning, as does any value outside the
bounds its schema sets (the validation plugin checks every shape against its kind's schema).
A note's dots link it to another note or a subboard: each kind has a
channel of its own (Connections' ports), a subboard has ports on every channel too, its own first, so its dots link to a note
or another subboard, and the link is an arrow (`ArrowPortsPlugin`) that keeps to its channel when an end is re-aimed.

## Layout

```
Package.swift           the module graph: one line per module, with its layer (a horizontal's is surface,
                        concern, language or lexicon)
Sources/
  Geometry/             vector math, arcs, Camera
  Canvas/               the core: model, plugin registry, editor, the hand tool, drawing
  CanvasRPC/            what the app and its command line say to each other: JSON-RPC over a socket
  DrawScript/           the language canvas draw reads, and the solver that places what it says: pure, beneath the plugins
  QueryLanguage/        the language canvas query reads, and the one form it prints: pure, beneath the plugins
  TextEditing/          the text view and the caret list under every editable text, beneath the plugins
  CanvasUI/             the AppKit view, the SwiftUI toolbar, CanvasFocus, and the command line's server
  CanvasCLI/            canvas, the command line
  Keyboard/             the keyboard horizontal: every shortcut, registered by the plugin whose key it is
  Selection/            the selection horizontal: the select tool, marquee, handles, Delete and ⌘A, the shake of a refused change
  StickyNotes/          sticky notes, with in-place editing
  Subboards/            subboards: a card that holds a board of its own, entered with a double-click
  Frames/               frames: a region of a board that holds shapes, which move and lock with it
  References/           references: a pill that stands for a public shape, so an arrow into it counts as an arrow
                        into the shape (the Reference tool, R)
  Moving/               /move-to and /move-near: the shape typed in moved into a frame, onto a subboard's board or
                        beside a shape, on any board, placed as canvas draw places a shape; and the table of
                        contents' rows dropped into a frame, onto a subboard's board or out of frames
  Validation/           the validation horizontal: rules, engine, outline, the Issues tab and the rows' dots
  DetailPanel/          the detail panel horizontal: tabs, sections, bindings, the inspector view
  ContextMenus/         the context menu horizontal: right-click items, groups, the selection's menu
  SlashCommands/        a horizontal: commands a shape offers, typed as /name on a line of its text (the list
                        at a slash, Return runs the line)
  TableOfContents/      the table of contents horizontal: a row per shape, front to back, in the detail panel;
                        rows dragged to restack shapes, or dropped on a frame's or a subboard's row
  Adornments/           a horizontal: what's shown on a shape (a title's pill, a lock chip), placed by
                        any plugin, laid out so none overlap, drawn in one overlay
  Clipboard/            the clipboard horizontal: cut, copy and paste, which kinds may opt out of
  Titles/               a horizontal any kind opts into: a title, a property it adds (or derived), in a pill
                        and the table of contents, and a header, or /title, that renames it
  Locking/              a horizontal every kind is in: a lock from the context menu or /lock, and its chip
  Publishing/           a horizontal: which shapes are public (another shape may stand for one), its chip and
                        count, /public and /private, and the Referenced In tab
  Connections/          a horizontal: ports (dots beside a shape's sides that a drag connects from), channels that
                        say what may connect to what, and the arrow (a port of tldraw's arrow geometry and
                        binding) a drag from a dot draws, bound only where its channel goes
  Mentions/             a horizontal: text that mentions shapes, each mention a live pill, with the @ picker and
                        a Mentioned In tab
  Boards/               a horizontal: getting around a file's boards (opening one, ⌘↑, the path over the canvas)
  Topology/             a horizontal: what connects and contains what across the file (arrows, mentions, frames
                        and boards), read from the shapes that carry it
  Automation/           the command line's horizontal: every command canvas runs, draw and kinds its own
  Queries/              a horizontal: the engine that answers canvas query about the whole file
  QueryTranslation/     a horizontal: English into a query (Claude writes it), for the command line and the app
  QueryCommands/        canvas query, query-vocabulary, and --ask (a call to the translator)
  LanguageModels/       a horizontal that lends every editor a language model (Claude Haiku), its key in Settings
  Snapping/             a horizontal: what a drag moves snaps to the shapes in view (edges, middles, even
                        spaces), with guides
  Transform/            a horizontal: turning a shape into another kind through channels (a frame into a
                        subboard: one kind offers a channel, another takes it), from its menu or /turn-into-…
  Types/                a concern: a note that holds a JSON Schema is a type, named by its title (/type), its words
                        and its schema kept in step by Claude, its words highlighted where they say a part of it
  DrawLexicon/          canvas draw's words for this app: shapes named by their titles, edges as the connector's
                        connections (on a channel both ends take), and warnings as validation finds them
  QueryLexicon/         canvas query's words for this app: titles, boards' names, mentions, validity and the
                        selection
  Composition/          the shipped plugin list, and the welcome board
  InfiniteCanvas/       the SwiftUI app
Examples/               the smallest plugin for each pattern
  Reordering/           menu items for every kind with a capability: the Arrange submenu
Tests/                  test executables (the core, each plugin with logic of its own, the examples,
                        the shipped app) and their support libraries, on a small macro-free kit
scripts/                re-records the proof of concept's behavior, which the tests hold the app to; schema-prompts/
                        has the quick evals of what types ask Claude
```
