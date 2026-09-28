# Infinite Canvas

A native macOS infinite canvas: a small core, with everything on it (selecting, what each key does,
sticky notes, arrows modeled on tldraw's, validation, checklists, a detail panel, a table of
contents, ports to drag arrows from) added by plugins.
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
| Pan | Two-finger scroll, or H (the hand tool) and drag; a fling slides on. V or Escape goes back to select |
| Zoom | Pinch, ⌘-scroll, or ⌘= / ⌘- / ⌘0 |
| See where you are | The minimap, in the canvas's bottom-left corner: every shape in miniature, and the part the canvas shows outlined. Click beside that part to move there, drag it to move it, double-click to center on a spot. ⌃⌘M shows or hides it |
| New note | Double-click empty space, or N (the note tool) and click |
| New rectangle | R, then click (an example plugin) |
| Draw a line | L, then drag; Escape takes back the line being drawn (an example plugin) |
| Erase | E, then click or drag across shapes (an example plugin) |
| Select | Click a shape, or drag across empty space to select what the marquee touches (⌘: only what it encloses; ⇧: add to the selection) |
| Add to or remove from the selection | ⇧-click (or ⌘-click) a shape |
| Select all | ⌘A |
| Move shapes | Drag a shape. With several selected, drag any of them, or the space between them, to move them all; Escape puts them back |
| Line shapes up | Drag near other shapes: edges and middles snap to theirs, and to even spaces between them, with red guides. Once dragging, hold ⌘ (or ⌃) to move freely |
| Edit a note | Double-click it, or select it and press Return; Escape to finish |
| Edit a shape's details | Select it; the detail panel on the right edits it. Escape gives the keyboard back to the canvas |
| Show or hide the detail panel | ⌃⌘I, or the Details button in the toolbar |
| See what's on the board | With nothing selected, the detail panel lists every shape, each arrow under the shape it starts from; with several selected, just those (Show All lists every shape again) |
| Find a shape from the list | Click its row: it's selected and the canvas zooms to it. Pointing at a row outlines its shape faintly, and pointing at a shape tints its row |
| Go back to the previous selection | The back button in the detail panel's header, or ⌘[ (Go › Back): what was selected before, and the view as it was then (from a row's details, the list) |
| Add a checklist to a note | The panel's Checklist tab: + adds an item, − or Delete removes the selected one |
| Name a note or a rectangle | Select it and click its title in the detail panel's header; Return or Escape goes back to the canvas |
| Delete shapes or arrows | Select them and press Delete |
| Cut, copy and paste shapes | ⌘X, ⌘C and ⌘V (Edit menu, or right-click a shape; right-click empty space to paste). A paste lands where the originals were if they're in view, else in the middle of the view; arrows copied with their shapes stay attached to the copies |
| Arrow tool | A (V or Escape to go back to select) |
| Draw an arrow | Drag from one shape to another with the arrow tool. Arriving quickly aims at a shape's center; arriving slowly, or pausing inside the shape, aims at that exact spot |
| Link a note to a note, or a schema card to a schema card | With the select tool, point at one: dots show just outside its sides (a note has none on top; zoomed out below 25%, none show). Drag from a dot to another of its kind: those it could link to are outlined faintly as you drag, and released anywhere else, nothing is drawn |
| Aim into a shape | Hold ⌥ while drawing or dragging an end: the arrow runs all the way to the spot |
| Don't attach | Hold ⌘ while drawing or dragging an end |
| Snap angle | Hold ⇧ while dragging an end (15° steps) |
| Re-aim an end | Select the arrow and drag its end handle |
| Bend | Select the arrow and drag its middle handle |
| Toggle an arrowhead | Double-click an end handle |

An empty note (no text, no checklist) gets an orange outline (the validation plugin: red for an error, orange for a
warning), says why in an Issues tab of the detail panel (the validation-details bridge), and gets an orange dot on its
row in the table of contents (the validation-contents bridge). A note with a checklist shows a done/total chip.
A titled shape shows its title in a pill above its top-left corner, and in the table of contents (the titles plugin).
Name a note or a rectangle in the detail panel's header (a rectangle's title is the rectangle-titles example). A title is
part of its shape's schema, at most 80 characters: a longer one gets a warning, as does any value outside the
bounds its schema sets (the validation plugin checks every shape against its kind's schema).
A note's dots link it only to another note, and a schema card's only to another schema card: each kind has a channel of its own
(the ports plugin), and the link is an arrow (the arrow-ports bridge) that keeps to its channel when an end is re-aimed.

## Layout

```
Package.swift           the module graph: one line per module, with its layer
Sources/
  Geometry/             vector math, arcs, Camera
  Canvas/               the core: model, plugin registry, editor, the hand tool, drawing
  CanvasRPC/            what the app and its command line say to each other: JSON-RPC over a socket
  DrawScript/           the language canvas draw reads, and the solver that places what it says: pure, beneath the plugins
  CanvasUI/             the AppKit view, the SwiftUI toolbar, CanvasFocus, and the command line's server
  CanvasCLI/            canvas, the command line
  Keyboard/             the keyboard horizontal: every shortcut, registered by the plugin whose key it is
  Selection/            the selection horizontal: the select tool, marquee, handles, Delete and ⌘A
  Arrows/               arrows (a port of tldraw's arrow geometry and binding)
  StickyNotes/          sticky notes, with in-place editing
  Schemas/              schema cards: a JSON Schema on the canvas, as a card that lists its fields, written in its
                        panel in words or as JSON, the two kept in step by Claude
  Validation/           the validation horizontal: rules, engine, outline
  DetailPanel/          the detail panel horizontal: tabs, sections, bindings, the inspector view
  ContextMenus/         the context menu horizontal: right-click items, groups, the selection's menu
  TableOfContents/      the table of contents horizontal: a row per shape, in the detail panel
  Adornments/           a horizontal: what's shown on a shape (a title's pill, a checklist's tally, a
                        lock chip), placed by any plugin, laid out so none overlap, drawn in one overlay
  Checklists/           a horizontal any kind opts into: a checklist, its panel tab, menu items, a chip
  Clipboard/            the clipboard horizontal: cut, copy and paste, which kinds may opt out of
  Titles/               a horizontal any kind opts into: a title, a property it adds (or derived), in a pill
                        and the table of contents, and a header that renames it
  Locking/              a horizontal every kind is in: a lock from the context menu, its chip and its shake
  Ports/                a horizontal any kind opts into: dots beside its sides that a drag connects from,
                        on channels that say what may connect to what
  Automation/           the command line's horizontal: every command canvas runs, draw and kinds its own
  LanguageModels/       a horizontal that lends every editor a language model (Claude Haiku), its key in Settings
  Snapping/             a horizontal: what a drag moves snaps to the shapes in view (edges, middles, even
                        spaces), with guides
  ValidationDetails/    a bridge between two horizontals: validation issues in the panel's Issues tab
  ValidationContents/   a bridge between two horizontals: a dot on the row of each shape with issues
  ArrowPorts/           a bridge: arrows are what a drag from a port draws, bound only where its channel goes
  TitleNames/           a bridge: canvas draw names shapes by their titles
  PortEdges/            a bridge: canvas draw's edges are the connector's connections, on a channel both ends take
  ValidationChecks/     a bridge: canvas draw warns about each shape it draws as validation finds it
  Composition/          the shipped plugin list, and the welcome board
  InfiniteCanvas/       the SwiftUI app
Examples/               the smallest plugin for each pattern
  Rectangles/           a vertical: a kind, how it draws, a tool
  Polylines/            a shape without a frame: its own geometry, hit test and translation
  Eraser/               a tool with no shape, and a session
  RectangleTitles/      the smallest bridge: rectangles can be named
  Reordering/           menu items for every kind with a capability: the Arrange submenu
Tests/                  test executables (the core, each plugin with logic of its own, the examples,
                        the shipped app) and their support libraries, on a small macro-free kit
scripts/                re-records the proof of concept's behavior, which the tests hold the app to; schema-prompts/
                        has the quick evals of what schema cards ask Claude
```
